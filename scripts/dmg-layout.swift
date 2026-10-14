import Foundation
// Writes the Finder window layout (.DS_Store) for the mounted, writable installer volume: a 720 × 500
// window without toolbar or sidebar, the background picture, and the app beside an Applications link
// at the spots render-dmg-background.swift draws for them. MacSpaces, Tape and Folio ship identical
// copies of this file. Usage: swift dmg-layout.swift /Volumes/Folio\ 1.1.0 Folio.app
let volume = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
let appName = CommandLine.arguments[2]
let background = volume.appendingPathComponent(".background.tiff")
let volumeName = try volume.resourceValues(forKeys:[.volumeNameKey]).volumeName!

func be<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of:v.bigEndian) { Data($0) } }
func utf16(_ s: String) -> Data { s.utf16.reduce(into:Data()) { $0 += be($1) } }
func pascal(_ s: String, _ size: Int) -> Data {
    let bytes = Data(s.utf8.prefix(size-1))
    return Data([UInt8(bytes.count)]) + bytes + Data(count:size-1-bytes.count)
}
func hfsDate(_ url: URL) throws -> UInt32 { UInt32(try url.resourceValues(forKeys:[.creationDateKey]).creationDate!.timeIntervalSince1970 + 2_082_844_800) }
func inode(_ url: URL) -> UInt32 { var s = stat(); stat(url.path,&s); return UInt32(truncatingIfNeeded:s.st_ino) }

// Finder stores the background picture as a classic version 2 alias record. HFS+ file IDs and the
// volume's creation date survive `hdiutil convert`, so the alias resolves in the compressed image.
func alias(_ file: URL) throws -> Data {
    let name = file.lastPathComponent, volumeDate = try hfsDate(volume), fileDate = try hfsDate(file)
    var d = Data(count:4) + be(UInt16(0)) + be(UInt16(2)) + be(UInt16(0))
    d += pascal(volumeName,28) + be(volumeDate) + Data("H+".utf8) + be(UInt16(0)) + be(inode(volume))
    d += pascal(name,64) + be(inode(file)) + be(fileDate) + Data(count:8) + be(Int16(-1)) + be(Int16(-1))
    d += be(UInt32(0)) + Data(count:12)
    func tag(_ t: Int16, _ v: Data) { d += be(t) + be(UInt16(v.count)) + v; if v.count % 2 == 1 { d.append(0) } }
    tag(0,Data(volumeName.utf8))
    tag(16,be(UInt64(volumeDate) << 16)); tag(17,be(UInt64(fileDate) << 16))
    tag(2,Data("\(volumeName):\(name)".utf8))
    tag(14,be(UInt16(name.utf16.count)) + utf16(name))
    tag(15,be(UInt16(volumeName.utf16.count)) + utf16(volumeName))
    tag(18,Data("/\(name)".utf8))
    tag(19,Data("/Volumes/\(volumeName)".utf8))
    d += be(Int16(-1)) + be(UInt16(0))
    d.replaceSubrange(4..<6,with:be(UInt16(d.count)))
    return d
}
let backgroundAlias = try alias(background)

func plist(_ p: [String:Any]) throws -> Data { try PropertyListSerialization.data(fromPropertyList:p,format:.binary,options:0) }
func iloc(_ x: UInt32, _ y: UInt32) -> Data { be(x) + be(y) + Data([0xff,0xff,0xff,0xff,0xff,0xff,0,0]) }
let window: [String:Any] = ["ContainerShowSidebar":false,"PreviewPaneVisibility":false,"ShowPathbar":false,"ShowSidebar":false,
    "ShowStatusBar":false,"ShowTabView":false,"ShowToolbar":false,"SidebarWidth":180,"WindowBounds":"{{200, 260}, {720, 500}}"]
// The bounds include the title bar. The colour is the paper, for anyone who switches to a colour background.
let icons: [String:Any] = ["arrangeBy":"none","backgroundColorRed":0.953,"backgroundColorGreen":0.941,"backgroundColorBlue":0.922,
    "backgroundImageAlias":backgroundAlias,"backgroundType":2,"gridOffsetX":0.0,"gridOffsetY":0.0,"gridSpacing":100.0,
    "iconSize":96.0,"labelOnBottom":true,"scrollPositionX":0.0,"scrollPositionY":0.0,"showIconPreview":false,
    "showItemInfo":false,"textSize":13.0,"viewOptionsVersion":1]
func blob(_ d: Data) -> Data { be(UInt32(d.count)) + d }
// Icon positions are centres. Support files sit outside the window even when Finder shows hidden files.
var records: [(name: String, code: String, value: Data)] = [
    (".","bwsp",Data("blob".utf8) + blob(try plist(window))),
    (".","icvl",Data("type".utf8) + Data("icnv".utf8)),
    (".","icvp",Data("blob".utf8) + blob(try plist(icons))),
    (".","vSrn",Data("long".utf8) + be(UInt32(1))),
    (".background.tiff","Iloc",Data("blob".utf8) + blob(iloc(1000,1000))),
    (".VolumeIcon.icns","Iloc",Data("blob".utf8) + blob(iloc(1000,1000))),
    ("Applications","Iloc",Data("blob".utf8) + blob(iloc(520,296))),
    (appName,"Iloc",Data("blob".utf8) + blob(iloc(200,296))),
]
records.sort { ($0.name.lowercased(),$0.code) < ($1.name.lowercased(),$1.code) }

// One leaf node in a buddy-allocated file, laid out like Finder's own: header and table at 0x0,
// the B-tree descriptor at 0x20, the allocator's root block at 0x800 and the node at 0x2000.
var node = be(UInt32(0)) + be(UInt32(records.count))
for r in records { node += be(UInt32(r.name.utf16.count)) + utf16(r.name) + Data(r.code.utf8) + r.value }
precondition(node.count <= 0x2000,"Layout records exceed one node")
var store = Data(count:0x4000)
func put(_ d: Data, at offset: Int) { store.replaceSubrange(offset..<offset+d.count,with:d) }
put(Data("Bud1".utf8) + be(UInt32(0x800)) + be(UInt32(0x800)) + be(UInt32(0x800))
    + Data([0,0,0x10,0x0c,0,0,0,0x87,0,0,0x20,0x0b,0,0,0,0]),at:0)
put(be(UInt32(2)) + be(UInt32(0)) + be(UInt32(records.count)) + be(UInt32(1)) + be(UInt32(0x1000)),at:0x20)
var allocator = be(UInt32(3)) + be(UInt32(0)) + be(UInt32(0x80b)) + be(UInt32(0x25)) + be(UInt32(0x200d)) + Data(count:253*4)
allocator += be(UInt32(1)) + Data([4]) + Data("DSDB".utf8) + be(UInt32(1))
for size in 0..<32 {
    let free = (6...10).contains(size) || size == 12 || (14...30).contains(size)
    allocator += free ? be(UInt32(1)) + be(UInt32(1) << size) : be(UInt32(0))
}
put(allocator,at:0x800)
put(node,at:0x2000)
try (be(UInt32(1)) + store).write(to:volume.appendingPathComponent(".DS_Store"))
