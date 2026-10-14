import XCTest
import Vision
import ImageIO
import CSQLite
@testable import ShelfCore

final class AnalysisTests: XCTestCase {
    func testMasonryVisibilityIncludesEveryIntersectingTile() {
        let items = (0..<10000).map { ShelfItem(id:String($0),path:"/\($0)",width:900,height:Double([600,1200,900,1800][$0%4])) }
        let layout = MasonryLayout(items:items,width:1110,tileSize:190)
        XCTAssertEqual(layout.columns,5)
        XCTAssertTrue(zip(layout.frames,layout.frames.dropFirst()).allSatisfy { $0.minY <= $1.minY })
        for y in stride(from:0.0,to:layout.height,by:1537) {
            let viewport = CGRect(x:0,y:y,width:1110,height:740)
            let candidates = layout.visibleRange(y:y,height:740)
            for i in layout.frames.indices where layout.frames[i].intersects(viewport) { XCTAssertTrue(candidates.contains(i),"Missing visible tile \(i)") }
            XCTAssertLessThan(candidates.count,70)
        }
        let frame=layout.frame(index:100)
        XCTAssertEqual(layout.index(x:frame.midX,y:frame.midY),100)
        XCTAssertNil(layout.index(x:0,y:0))
        XCTAssertTrue(layout.visibleRange(y:layout.height+100,height:700).isEmpty)
    }
    func testMasonryKeepsAspectRatiosAndCaptions() {
        let items=[ShelfItem(path:"/wide",width:1200,height:700),ShelfItem(path:"/portrait",width:800,height:1200)]
        let layout=MasonryLayout(items:items,width:600,tileSize:190)
        XCTAssertEqual(layout.frames[0].height/layout.frames[0].width,700.0/1200,accuracy:0.001)
        XCTAssertEqual(layout.frames[1].height/layout.frames[1].width,1.5,accuracy:0.001)
        let caption=MasonryLayout(items:items,width:600,tileSize:190,captions:true)
        XCTAssertEqual(caption.frames[0].height-layout.frames[0].height,24)
    }
    func testRowsFillTheWidthAndKeepShapes() {
        let items = (0..<2000).map { ShelfItem(id:String($0),path:"/\($0)",width:Double([1600,900,1200,700][$0%4]),height:Double([900,1600,1200,1400][$0%4])) }
        let layout = MasonryLayout(items:items,width:1200,tileSize:220,style:.rows)
        XCTAssertTrue(zip(layout.frames,layout.frames.dropFirst()).allSatisfy { $0.minY <= $1.minY })
        let rows = Dictionary(grouping:layout.frames.indices) { layout.frames[$0].minY }
        for (y,row) in rows where y < layout.frames.last!.minY {
            let right = row.map { layout.frames[$0].maxX }.max()!
            XCTAssertEqual(right,1200-24,accuracy:0.5)
            for i in row { XCTAssertEqual(layout.frames[i].width/layout.frames[i].height,items[i].width/items[i].height,accuracy:0.01) }
        }
        for y in stride(from:0.0,to:layout.height,by:977) {
            let viewport = CGRect(x:0,y:y,width:1200,height:800), candidates = layout.visibleRange(y:y,height:800)
            for i in layout.frames.indices where layout.frames[i].intersects(viewport) { XCTAssertTrue(candidates.contains(i)) }
        }
        let below = layout.neighbor(of:0,dx:0,dy:1)!
        XCTAssertGreaterThan(layout.frames[below].minY,layout.frames[0].minY)
        XCTAssertEqual(layout.neighbor(of:below,dx:0,dy:-1).map { layout.frames[$0].minY },layout.frames[0].minY)
        XCTAssertNil(layout.neighbor(of:0,dx:0,dy:-1))
        XCTAssertEqual(layout.indices(in:layout.frames[5].insetBy(dx:2,dy:2)),[5])
    }
    func testAutomaticTagsRespectEvidenceAndThresholds() {
        let analysis=ImageAnalysis(suggestions:[.init(label:"cat",confidence:0.8),.init(label:"guess",confidence:0.19),.init(label:"blue",confidence:0.3,evidence:"color"),.init(label:"small-color",confidence:0.1,evidence:"color"),.init(label:"typography",confidence:0.8,evidence:"ocr")],colors:[],text:"",engine:"test",elapsedMS:1)
        XCTAssertEqual(analysis.automaticTags,["cat","blue","typography"])
    }
    func testAnalysisPersistsIndexesTagsAndKeepsManualMetadata() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let item=ShelfItem(path:"/neutral.jpg",tags:["Favorite Cat"],note:"Keep me")
        let value=ImageAnalysis(suggestions:[.init(label:"cat",confidence:0.8),.init(label:"blue",confidence:0.4,evidence:"color")],colors:["#0000ff"],text:"Hidden headline",engine:"test",elapsedMS:2)
        do {
            let db=try LibraryDatabase(root:root)
            let personal=try db.createCollection(name:"Personal"); try db.insert([item],into:personal.id)
            try db.saveAnalysis(id:item.id,signature:"signature",value:value,dimensions:CGSize(width:800,height:1200),applyTags:true)
            let saved=try XCTUnwrap(db.items().first)
            XCTAssertEqual(saved.tags,["Favorite Cat"]); XCTAssertEqual(saved.autoTags,["cat","blue"]); XCTAssertEqual(saved.colors,["#0000ff"])
            XCTAssertEqual(saved.note,"Keep me"); XCTAssertEqual(saved.collections,[personal.id])
            XCTAssertEqual(saved.width,800);XCTAssertEqual(try db.items(query:"blue").count,1);XCTAssertEqual(try db.items(query:"hidden headline").count,1)
            XCTAssertEqual(try db.allTags().map(\.name),["Favorite Cat"],"Machine tags stay out of the tag list")
        }
        let reopened=try LibraryDatabase(root:root)
        XCTAssertEqual(try reopened.analysisSignatures()[item.id],"signature")
        XCTAssertEqual(try reopened.analysis(id:item.id)?.suggestions,value.suggestions)
        try reopened.deletePermanently([item.id]); XCTAssertNil(try reopened.analysis(id:item.id))
        XCTAssertTrue(try reopened.items(query:"blue").isEmpty)
    }
    func testVersionOneDatabaseMigration() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        var handle:OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("index.sqlite").path,&handle),SQLITE_OK)
        let sql="CREATE TABLE items(id TEXT PRIMARY KEY,path TEXT UNIQUE NOT NULL,title TEXT NOT NULL,source TEXT NOT NULL,collection TEXT NOT NULL,tags TEXT NOT NULL,note TEXT NOT NULL,ocr TEXT NOT NULL,kind TEXT NOT NULL,added REAL NOT NULL); INSERT INTO items VALUES('old','/old','Old','','Inbox','manual','saved','','image',1);"
        XCTAssertEqual(sqlite3_exec(handle,sql,nil,nil,nil),SQLITE_OK); sqlite3_close(handle)
        let db=try LibraryDatabase(root:root)
        let old=try XCTUnwrap(db.items().first);XCTAssertEqual(old.id,"old");XCTAssertEqual(old.note,"saved");XCTAssertEqual(old.width,0);XCTAssertEqual(old.tags,["manual"])
        XCTAssertTrue(db.snapshots().contains { $0.lastPathComponent.hasSuffix("-v1.sqlite") })
        try db.insert([ShelfItem(path:"/new",width:400,height:600)]);XCTAssertEqual(try db.count(),2)
    }
    func testSimilarImagesRankFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        func image(_ name: String, _ draw: (CGContext) -> Void) throws -> URL {
            let context = CGContext(data:nil,width:256,height:256,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            draw(context)
            let url = root.appendingPathComponent(name)
            let destination = CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil)!
            CGImageDestinationAddImage(destination,context.makeImage()!,nil); CGImageDestinationFinalize(destination)
            return url
        }
        let stripes = { (shift: CGFloat) in { (c: CGContext) in
            c.setFillColor(red:1,green:1,blue:1,alpha:1); c.fill(CGRect(x:0,y:0,width:256,height:256))
            c.setFillColor(red:0.1,green:0.2,blue:0.8,alpha:1)
            for x in stride(from:shift,to:256,by:32) { c.fill(CGRect(x:x,y:0,width:12,height:256)) }
        } }
        let a = try image("a.png",stripes(0)), b = try image("b.png",stripes(6))
        let c = try image("c.png") { c in
            c.setFillColor(red:0.9,green:0.3,blue:0.1,alpha:1); c.fill(CGRect(x:0,y:0,width:256,height:256))
            c.setFillColor(red:1,green:0.9,blue:0.2,alpha:1); c.fillEllipse(in:CGRect(x:60,y:60,width:140,height:140))
        }
        var prints: [String:VNFeaturePrintObservation] = [:]
        for (id,url) in [("a",a),("b",b),("c",c)] { prints[id] = VisualSimilarity.observation(try VisualSimilarity.featurePrint(url:url)) }
        XCTAssertEqual(VisualSimilarity.nearest(to:"a",in:prints).first?.id,"b")
    }
    func testVectorFilesGetThumbnails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let svg = root.appendingPathComponent("mark.svg")
        try ##"<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><rect width="200" height="100" fill="#3060f0"/></svg>"##.write(to:svg,atomically:true,encoding:.utf8)
        let pdf = root.appendingPathComponent("page.pdf")
        var box = CGRect(x:0,y:0,width:300,height:400)
        let context = CGContext(pdf as CFURL,mediaBox:&box,nil)!
        context.beginPDFPage(nil); context.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1)); context.fill(CGRect(x:50,y:50,width:100,height:100)); context.endPDFPage(); context.closePDF()
        XCTAssertEqual(MediaFiles.kind(svg),"image"); XCTAssertEqual(MediaFiles.kind(pdf),"image")
        XCTAssertEqual(MediaFiles.dimensions(pdf),CGSize(width:300,height:400))
        XCTAssertEqual(MediaFiles.dimensions(svg),CGSize(width:200,height:100))
        let page = try XCTUnwrap(MediaFiles.thumbnail(url:pdf,pixels:256)), mark = try XCTUnwrap(MediaFiles.thumbnail(url:svg,pixels:256))
        XCTAssertEqual(page.height,256); XCTAssertEqual(mark.width,256)
        XCTAssertEqual(MediaFiles.scan([root]).count,2)
    }
}
