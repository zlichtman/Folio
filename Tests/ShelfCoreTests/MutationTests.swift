import XCTest
@testable import ShelfCore

final class MutationTests: XCTestCase {
    func library(_ root: URL? = nil) throws -> LibraryDatabase { try LibraryDatabase(root:root ?? temporaryLibrary(self)) }

    func testTrashAndUndoRoundTrip() throws {
        let db = try library()
        let board = try db.createCollection(name:"Board")
        try db.insert([ShelfItem(id:"a",path:"/a.jpg"),ShelfItem(id:"b",path:"/b.jpg")],into:board.id)
        try db.addTags(["keep"],to:["a"]); try db.setNote("hello",for:["a"]); try db.setLiked(["a"],true)
        let original = try db.snapshot(ids:["a","b"])
        XCTAssertEqual(original.map(\.id),["a","b"])
        XCTAssertEqual(original[0].memberships.map(\.collection),[board.id])

        let trashed = try db.moveToTrash(["a","b"])
        XCTAssertEqual(trashed,original)
        XCTAssertTrue(try db.items().isEmpty)
        XCTAssertEqual(try db.items(scope:.trash).count,2)
        XCTAssertEqual(try db.items(scope:.collection(board.id)).count,0)
        let redo = try db.restore(trashed)
        XCTAssertEqual(try db.snapshot(ids:["a","b"]),original)
        XCTAssertEqual(redo.compactMap(\.trashed).count,2)

        // Any edit undoes the same way, memberships and searchable names included.
        let edits = try db.setTitle("Renamed",for:["a"]) + db.removeItems(["a"],from:board.id)
        XCTAssertEqual(try db.items(query:"board").map(\.id),["b"])
        try db.restore(Array(edits.reversed()))
        XCTAssertEqual(try db.snapshot(ids:["a"]),[original[0]])
        XCTAssertEqual(Set(try db.items(query:"board").map(\.id)),["a","b"])
        XCTAssertThrowsError(try db.setTitle("  ",for:["a"]))

        try db.moveToTrash(["b"]); try db.putBack(["b"])
        XCTAssertNil(try db.item(id:"b")?.trashed)
        XCTAssertTrue(try db.restore([ItemState(id:"gone",title:"",note:"",author:"",tags:[],autoTags:[],rejectedTags:[],liked:false,trashed:nil,position:0,memberships:[])]).isEmpty)
    }

    func testPermanentDeletionOnlyRemovesOwnedFiles() throws {
        let root = temporaryLibrary(self), db = try library(root)
        try FileManager.default.createDirectory(at:db.mediaFolder,withIntermediateDirectories:true)
        let owned = db.mediaFolder.appendingPathComponent("owned.jpg"), outside = root.appendingPathComponent("outside.jpg")
        try Data([1]).write(to:owned); try Data([2]).write(to:outside)
        try db.insert([ShelfItem(id:"owned",path:owned.path),ShelfItem(id:"outside",path:outside.path),ShelfItem.link(url:"https://example.com")])
        try db.moveToTrash(["owned","outside",ShelfItem.digest("link|https://example.com")])
        XCTAssertEqual(try db.emptyTrash(),[owned.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath:owned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:outside.path))
        XCTAssertEqual(try db.count(.trash),0)
    }

    func testOldTrashIsPurgedOnOpen() throws {
        let root = temporaryLibrary(self)
        do {
            let db = try library(root)
            try db.insert([ShelfItem(id:"old",path:"/old.jpg",trashed:Date().timeIntervalSince1970 - 31 * 86400),
                           ShelfItem(id:"recent",path:"/recent.jpg",trashed:Date().timeIntervalSince1970 - 86400)])
        }
        let db = try library(root)
        XCTAssertEqual(try db.items(scope:.trash).map(\.id),["recent"])
    }

    func testMultiWordTags() throws {
        let db = try library()
        try db.insert([ShelfItem(id:"a",path:"/a.jpg"),ShelfItem(id:"b",path:"/b.jpg"),ShelfItem(id:"c",path:"/c.jpg")])
        try db.addTags(["dark mode","  UI   kit ","dark MODE",""],to:["a","b"])
        try db.addTags(["Dark Mode"],to:["c"]); try db.moveToTrash(["c"])
        XCTAssertEqual(try db.item(id:"a")?.tags,["dark mode","UI kit"])
        XCTAssertEqual(try db.items(scope:.tag("DARK MODE")).map(\.id).sorted(),["a","b"])
        XCTAssertEqual(try db.items(scope:.tag("dark")).count,0,"Tags match whole, not by word")
        XCTAssertEqual(try db.allTags().map { "\($0.name)=\($0.count)" },["dark mode=2","UI kit=2"])
        try db.removeTags(["ui kit"],from:["b"])
        XCTAssertEqual(try db.item(id:"b")?.tags,["dark mode"])

        let renamed = try db.renameTag("Dark Mode",to:"Night")
        XCTAssertEqual(Set(renamed.map(\.id)),["a","b","c"])
        XCTAssertEqual(try db.item(id:"a")?.tags,["Night","UI kit"])
        try db.addTags(["night"],to:["b"])
        try db.renameTag("UI kit",to:"night")
        XCTAssertEqual(try db.item(id:"a")?.tags,["Night"],"Renaming onto an existing tag merges")
        try db.restore(renamed)
        XCTAssertEqual(try db.item(id:"a")?.tags,["dark mode","UI kit"])
        let deleted = try db.deleteTag("dark mode")
        XCTAssertEqual(try db.allTags().map(\.name),["UI kit"])
        XCTAssertEqual(deleted.count,3)
        XCTAssertEqual(Tags.parse("dark mode, ui kit,,  "),["dark mode","ui kit"])
        XCTAssertEqual(Tags.parse("one two"),["one two"])
        try db.setTags(["x y"],for:["a"])
        XCTAssertEqual(try db.items(query:"tag:\"x y\"").map(\.id),["a"])
    }

    func testRejectedMachineTagsNeverReturn() throws {
        let db = try library()
        try db.insert([ShelfItem(id:"a",path:"/a.jpg",tags:["mine"])])
        let analysis = ImageAnalysis(suggestions:[.init(label:"cat",confidence:0.9),.init(label:"sofa",confidence:0.5),.init(label:"red",confidence:0.4,evidence:"color")],
                                     colors:["#d02020"],text:"",engine:"test",elapsedMS:1)
        try db.saveAnalysis(id:"a",signature:"1",value:analysis,dimensions:.zero,applyTags:true)
        XCTAssertEqual(try db.item(id:"a")?.autoTags,["cat","sofa","red"])
        XCTAssertEqual(try db.item(id:"a")?.tags,["mine"])
        let before = try db.removeTags(["Cat"],from:["a"])
        XCTAssertEqual(try db.item(id:"a")?.autoTags,["sofa","red"])
        XCTAssertEqual(try db.snapshot(ids:["a"]).first?.rejectedTags,["cat"])
        try db.saveAnalysis(id:"a",signature:"2",value:analysis,dimensions:.zero,applyTags:true)
        XCTAssertEqual(try db.item(id:"a")?.autoTags,["sofa","red"],"A removed machine tag is not added back")
        XCTAssertEqual(try db.items(query:"cat").count,0)
        try db.restore(before)
        XCTAssertEqual(try db.item(id:"a")?.autoTags,["cat","sofa","red"])
        try db.removeTags(["cat"],from:["a"]); try db.addTags(["cat"],to:["a"])
        XCTAssertEqual(try db.item(id:"a")?.tags,["mine","cat"])
        XCTAssertEqual(try db.snapshot(ids:["a"]).first?.rejectedTags,[],"Adding it by hand lifts the block")
        try db.saveAnalysis(id:"missing",signature:"x",value:analysis,dimensions:.zero,applyTags:true)
    }

    func testCollectionsNestCountAndUndo() throws {
        let db = try library()
        let travel = try db.createCollection(name:"Travel"), japan = try db.createCollection(name:"Japan",parent:travel.id)
        let kyoto = try db.createCollection(name:"Kyoto",parent:japan.id), food = try db.createCollection(name:"Food")
        try db.insert((1...5).map { ShelfItem(id:"i\($0)",path:"/\($0).jpg") })
        try db.addItems(["i1"],to:travel.id); try db.addItems(["i1","i2"],to:japan.id)
        try db.addItems(["i3"],to:kyoto.id); try db.addItems(["i3","i4"],to:food.id)
        XCTAssertThrowsError(try db.createCollection(name:"  ")) { XCTAssertEqual($0 as? LibraryError,.emptyName) }
        XCTAssertThrowsError(try db.createCollection(name:"x",parent:"nope")) { XCTAssertEqual($0 as? LibraryError,.collectionNotFound) }

        XCTAssertEqual(Set(try db.items(scope:.collection(travel.id)).map(\.id)),["i1","i2","i3"])
        XCTAssertEqual(try db.items(scope:.collection(travel.id,includeDescendants:false)).map(\.id),["i1"])
        XCTAssertEqual(try db.items(scope:.inbox).map(\.id),["i5"])
        XCTAssertEqual(try db.item(id:"i3")?.collections.sorted(),[food.id,kyoto.id].sorted())
        func counts() throws -> [String:Int] {
            var out: [String:Int] = [:]
            func walk(_ nodes: [CollectionNode]) { for n in nodes where !n.collection.isSmart { out[n.collection.name] = n.count; walk(n.children) } }
            walk(try db.collectionTree()); return out
        }
        XCTAssertEqual(try counts(),["Travel":3,"Japan":3,"Kyoto":1,"Food":2],"Items in several subcollections count once")
        XCTAssertEqual(try db.items(query:"travel").count,3,"Parent names are searchable on child items")

        XCTAssertThrowsError(try db.moveCollection(travel.id,to:kyoto.id)) { XCTAssertEqual($0 as? LibraryError,.invalidMove) }
        let moved = try db.moveCollection(kyoto.id,to:nil,before:travel.id)
        let roots = try db.collectionTree().map(\.collection.name)
        XCTAssertEqual(roots.firstIndex(of:"Kyoto").map { $0 + 1 },roots.firstIndex(of:"Travel"))
        XCTAssertEqual(try db.items(query:"travel").count,2)
        try db.restore(moved)
        XCTAssertEqual(try db.collection(id:kyoto.id)?.parent,japan.id)
        XCTAssertEqual(try db.items(query:"travel").count,3)

        let renamed = try db.renameCollection(japan.id,to:"Nippon")
        XCTAssertEqual(try db.items(query:"nippon").count,3)
        XCTAssertEqual(try db.items(query:"japan").count,0)
        try db.restore(renamed)
        XCTAssertEqual(try db.items(query:"japan").count,3)

        try db.addConnectedFolder(path:"/tmp/folio-test-folder",collection:kyoto.id)
        let archive = try db.deleteCollection(travel.id)
        XCTAssertEqual(archive.collections.map(\.name),["Travel","Japan","Kyoto"])
        XCTAssertNil(try db.collection(id:kyoto.id))
        XCTAssertEqual(try db.count(),5,"Items stay when their collection goes")
        XCTAssertEqual(Set(try db.items(scope:.inbox).map(\.id)),["i1","i2","i5"])
        XCTAssertEqual(try db.items(query:"travel").count,0)
        XCTAssertNil(try db.connectedFolders().first?.collection)
        try db.restore(archive)
        XCTAssertEqual(try counts(),["Travel":3,"Japan":3,"Kyoto":1,"Food":2])
        XCTAssertEqual(try db.items(query:"kyoto").map(\.id),["i3"])
        XCTAssertEqual(try db.connectedFolders().first?.collection,kyoto.id)

        let copy = try db.duplicateCollection(travel.id)
        XCTAssertEqual(copy.name,"Travel copy")
        XCTAssertEqual(try counts()["Travel copy"],3)
        XCTAssertEqual(try db.collections().filter { $0.name == "Kyoto" }.count,2)
        XCTAssertEqual(try db.items(scope:.collection(copy.id)).count,3)

        XCTAssertEqual(try db.collection(named:"food")?.id,food.id)
        XCTAssertNil(try db.collection(named:"Inbox",createIfMissing:true))
        XCTAssertNil(try db.collection(named:"New"))
        let created = try XCTUnwrap(db.collection(named:" New ",createIfMissing:true))
        XCTAssertEqual(try db.collection(named:"new",createIfMissing:true)?.id,created.id)

        let smart = try db.createCollection(name:"Big",kind:.smart,rules:SmartRules(rules:[SmartRule(.collection,.is,food.id)]))
        XCTAssertEqual(Set(try db.items(scope:.collection(smart.id)).map(\.id)),["i3","i4"])
        XCTAssertThrowsError(try db.addItems(["i1"],to:smart.id)) { XCTAssertEqual($0 as? LibraryError,.smartCollection) }
        try db.updateRules(smart.id,SmartRules(rules:[SmartRule(.collection,.is,travel.id)]))
        XCTAssertEqual(try db.items(scope:.collection(smart.id)).count,3)
        try db.setArchived(food.id,true)
        XCTAssertEqual(try db.collection(id:food.id)?.archived,true)
    }

    func testCustomOrderAndMoves() throws {
        let db = try library()
        let board = try db.createCollection(name:"Board"), other = try db.createCollection(name:"Other")
        try db.insert(["a","b","c","d"].map { ShelfItem(id:$0,path:"/" + $0 + ".jpg") },into:board.id)
        XCTAssertEqual(try db.items(scope:.collection(board.id),sort:.custom).map(\.id),["a","b","c","d"])
        let undo = try db.reorder(["d","b"],before:"a",in:board.id)
        XCTAssertEqual(try db.items(scope:.collection(board.id),sort:.custom).map(\.id),["d","b","a","c"])
        try db.restore(undo)
        XCTAssertEqual(try db.items(scope:.collection(board.id),sort:.custom).map(\.id),["a","b","c","d"])
        try db.reorder(["a"],before:nil,in:board.id)
        XCTAssertEqual(try db.items(scope:.collection(board.id),sort:.custom).map(\.id),["b","c","d","a"])
        try db.reorder(["c"],before:"a")
        XCTAssertEqual(try db.items(sort:.custom).map(\.id).firstIndex(of:"c")! + 1,try db.items(sort:.custom).map(\.id).firstIndex(of:"a")!)
        XCTAssertTrue(try db.reorder(["zzz"],before:nil,in:board.id).isEmpty)

        try db.moveItems(["a","b"],from:board.id,to:other.id)
        XCTAssertEqual(try db.items(scope:.collection(other.id),sort:.custom).map(\.id),["a","b"])
        try db.moveItems(["a"],from:nil,to:nil)
        XCTAssertEqual(try db.items(scope:.inbox).map(\.id),["a"])
    }

    func testConnectedFolderScanDiff() throws {
        let db = try library()
        let shots = try db.createCollection(name:"Shots")
        let base = temporaryLibrary(self).appendingPathComponent("Shots").path
        try FileManager.default.createDirectory(atPath:base,withIntermediateDirectories:true)
        let folder = try db.addConnectedFolder(path:base + "/",collection:shots.id)
        XCTAssertEqual(folder.path,base)
        XCTAssertEqual(try db.addConnectedFolder(path:base).id,folder.id)
        func file(_ name: String, size: Int64, date: Double) -> ShelfItem { ShelfItem(path:base + "/" + name,fileDate:date,fileSize:size,width:100,height:100) }

        let first = try db.applyScan(folderID:folder.id,found:[file("a.png",size:10,date:1),file("b.png",size:20,date:2),file("c.png",size:30,date:3)])
        XCTAssertEqual(first.added.count,3); XCTAssertTrue(first.updated.isEmpty && first.removed.isEmpty && first.moved.isEmpty)
        XCTAssertEqual(try db.items(scope:.folder(folder.id)).count,3)
        XCTAssertEqual(try db.items(scope:.collection(shots.id)).count,3)
        XCTAssertNotNil(try db.connectedFolders().first?.lastScan)
        let b = ShelfItem.digest(base + "/b.png"), c = ShelfItem.digest(base + "/c.png")
        try db.addTags(["keeper"],to:[b])

        let second = try db.applyScan(folderID:folder.id,found:[file("a.png",size:11,date:1),file("renamed.png",size:20,date:2),file("d.png",size:40,date:4)])
        XCTAssertEqual(second.updated,[ShelfItem.digest(base + "/a.png")])
        XCTAssertEqual(second.moved,[b])
        XCTAssertEqual(second.removed,[c])
        XCTAssertEqual(second.added,[ShelfItem.digest(base + "/d.png")])
        let renamed = try XCTUnwrap(db.item(id:b))
        XCTAssertEqual(renamed.path,base + "/renamed.png"); XCTAssertEqual(renamed.title,"renamed"); XCTAssertEqual(renamed.tags,["keeper"])
        let gone = try XCTUnwrap(db.item(id:c), "A vanished file goes to the trash, not away for good")
        XCTAssertTrue(gone.missing); XCTAssertNotNil(gone.trashed)
        XCTAssertEqual(try db.item(id:ShelfItem.digest(base + "/a.png"))?.fileSize,11)

        let third = try db.applyScan(folderID:folder.id,found:[file("a.png",size:11,date:1),file("renamed.png",size:20,date:2),file("d.png",size:40,date:4)])
        XCTAssertEqual(third,ScanChanges(),"An unchanged folder changes nothing")
        XCTAssertThrowsError(try db.applyScan(folderID:"nope",found:[])) { XCTAssertEqual($0 as? LibraryError,.folderNotFound) }
        let back = try db.applyScan(folderID:folder.id,found:[file("a.png",size:11,date:1),file("renamed.png",size:20,date:2),file("d.png",size:40,date:4),file("c.png",size:30,date:3)])
        XCTAssertEqual(back.updated,[c]); XCTAssertNil(try db.item(id:c)?.trashed, "A file that returns leaves the trash")
        XCTAssertFalse(try XCTUnwrap(db.item(id:c)).missing)

        let reused = try db.applyScan(folderID:folder.id,found:[file("a.png",size:11,date:1),file("renamed.png",size:20,date:2),file("d.png",size:40,date:4),
                                                               file("c.png",size:30,date:3),file("b.png",size:60,date:6)])
        XCTAssertEqual(reused.added.count,1); XCTAssertNotEqual(reused.added.first,b, "A new file at a renamed file's old path is a new item")
        XCTAssertEqual(try db.item(id:reused.added[0])?.path,base + "/b.png"); XCTAssertEqual(try db.item(id:b)?.path,base + "/renamed.png")

        let offline = try db.addConnectedFolder(path:base + "-unplugged")
        try db.applyScan(folderID:offline.id,found:[ShelfItem(path:base + "-unplugged/e.png",fileDate:5,fileSize:50)])
        let e = ShelfItem.digest(base + "-unplugged/e.png")
        XCTAssertEqual(try db.applyScan(folderID:offline.id,found:[]).removed,[e])
        XCTAssertEqual(try db.applyScan(folderID:offline.id,found:[]),ScanChanges(),"Missing items are reported once")
        XCTAssertNil(try db.item(id:e)?.trashed, "Nothing is trashed while the folder can't be reached")
        XCTAssertEqual(try db.item(id:e)?.missing,true)
        try db.removeConnectedFolder(offline.id,keepItems:false)

        try db.removeConnectedFolder(folder.id)
        XCTAssertTrue(try db.connectedFolders().isEmpty)
        XCTAssertEqual(try db.count(),5,"Disconnecting keeps items by default")
        XCTAssertNil(try db.item(id:b)?.folder)
        let again = try db.addConnectedFolder(path:base)
        try db.applyScan(folderID:again.id,found:[file("a.png",size:11,date:1)])
        try db.removeConnectedFolder(again.id,keepItems:false)
        XCTAssertEqual(try db.count(),4)
    }

    func testLinksAndColorsNeedNoFile() throws {
        let db = try library()
        let link = ShelfItem.link(url:"https://www.are.na/block/1",title:"",preview:nil,source:"https://www.are.na/")
        let color = try XCTUnwrap(ShelfItem.color("#3366ff",title:"Cornflower"))
        XCTAssertNil(ShelfItem.color("blue-ish"))
        try db.insert([link,color,link])
        XCTAssertEqual(try db.count(),2)
        let savedLink = try XCTUnwrap(db.item(id:link.id))
        XCTAssertEqual(savedLink.kind,"link"); XCTAssertEqual(savedLink.site,"are.na"); XCTAssertEqual(savedLink.title,"are.na"); XCTAssertEqual(savedLink.path,link.url)
        XCTAssertEqual(try db.items(query:"are.na").map(\.id),[link.id])
        XCTAssertEqual(try db.items(query:"cornflower").map(\.id),[color.id])
        XCTAssertEqual(try db.items(query:"color:#3060f0").map(\.id),[color.id])
        XCTAssertEqual(try db.items(query:"type:color").map(\.id),[color.id])
        let preview = ShelfItem.link(url:"https://example.com/a",title:"A page",preview:"/lib/media/a.jpg")
        XCTAssertEqual(preview.path,"/lib/media/a.jpg"); XCTAssertEqual(preview.url,"https://example.com/a"); XCTAssertEqual(preview.ext,"")
    }

    func testFeaturePrints() throws {
        let db = try library()
        try db.insert([ShelfItem(id:"a",path:"/a.jpg"),ShelfItem(id:"b",path:"/b.jpg")])
        try db.saveFeaturePrint(id:"a",version:1,data:Data([1,2,3]))
        try db.saveFeaturePrint(id:"b",version:2,data:Data([4]))
        try db.saveFeaturePrint(id:"missing",version:1,data:Data([9]))
        XCTAssertEqual(try db.featurePrints(version:1).map(\.id),["a"])
        XCTAssertEqual(try db.featurePrints(version:1).first?.data,Data([1,2,3]))
        try db.saveFeaturePrint(id:"a",version:2,data:Data([5,6]))
        XCTAssertEqual(Set(try db.featurePrints(version:2).map(\.id)),["a","b"])
        XCTAssertTrue(try db.featurePrints(version:1).isEmpty)
        try db.moveToTrash(["b"])
        XCTAssertEqual(try db.featurePrints(version:2).map(\.id),["a"])
    }

    func testExportIncludesCollectionsMembershipsAndTags() throws {
        let root = temporaryLibrary(self), db = try library(root)
        let board = try db.createCollection(name:"Board")
        try db.insert([ShelfItem(id:"a",path:"/a.jpg",tags:["one"],ocr:"words")],into:board.id)
        let file = root.appendingPathComponent("export.json")
        try db.exportJSON(to:file)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any])
        XCTAssertEqual(json["version"] as? Int,LibraryDatabase.schemaVersion)
        let items = try XCTUnwrap(json["items"] as? [[String:Any]])
        XCTAssertEqual(items.first?["ocr"] as? String,"words")
        XCTAssertEqual(items.first?["tags"] as? [String],["one"])
        XCTAssertTrue((json["collections"] as? [[String:Any]])?.contains { $0["name"] as? String == "Board" } == true)
        XCTAssertEqual((json["memberships"] as? [[String:Any]])?.first?["collection"] as? String,board.id)
        XCTAssertEqual((json["tags"] as? [[String:Any]])?.first?["name"] as? String,"one")
    }

    func testBackfillFileInfo() throws {
        let root = temporaryLibrary(self), db = try library(root)
        let file = root.appendingPathComponent("real.jpg"); try Data(count:1234).write(to:file)
        try db.insert([ShelfItem(id:"real",path:file.path),ShelfItem(id:"gone",path:"/nowhere/gone.jpg"),ShelfItem.link(url:"https://example.com")])
        XCTAssertEqual(try db.backfillFileInfo(limit:1),1)
        XCTAssertEqual(try db.backfillFileInfo(limit:10),1)
        XCTAssertEqual(try db.backfillFileInfo(),0)
        XCTAssertEqual(try db.item(id:"real")?.fileSize,1234)
        XCTAssertGreaterThan(try db.item(id:"real")?.fileDate ?? 0,0)
        XCTAssertEqual(try db.items(scope:.missing).map(\.id),["gone"])
        XCTAssertEqual(try db.items(query:"is:missing").map(\.id),["gone"])
    }
    func testTagCountsCoverAutomaticTagsOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let db = try LibraryDatabase(root:root)
        try db.insert([ShelfItem(path:"/a.jpg",tags:["Poster"],autoTags:["poster","blue"]),ShelfItem(path:"/b.jpg",autoTags:["blue"]),
                       ShelfItem(path:"/c.jpg",tags:["Kept"]),ShelfItem(path:"/d.jpg",autoTags:["gone"])])
        try db.moveToTrash([ShelfItem(path:"/d.jpg").id])
        let counts = try db.tagCounts().map { "\($0.name)=\($0.count)\($0.automatic ? "*" : "")" }
        XCTAssertEqual(counts,["blue=2*","Kept=1","Poster=1"])
    }
    func testRebasePathsAfterTheLibraryMoves() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let db = try LibraryDatabase(root:root)
        let kept = ShelfItem(path:"/Users/a/Library/Application Support/LumaShelf/media/x.png"), other = ShelfItem(path:"/Users/a/Pictures/y.png")
        try db.insert([kept,other])
        XCTAssertEqual(try db.rebasePaths(from:"/Users/a/Library/Application Support/LumaShelf",to:"/Users/a/Library/Application Support/Folio"),1)
        XCTAssertEqual(try db.item(id:kept.id)?.path,"/Users/a/Library/Application Support/Folio/media/x.png")
        XCTAssertEqual(try db.item(id:other.id)?.path,"/Users/a/Pictures/y.png")
        XCTAssertEqual(try db.items(query:"x").count,1)
    }
}

final class BoardTests: XCTestCase {
    func testPlacementsSaveRestoreAndReset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let db = try LibraryDatabase(root:root)
        let a = ShelfItem(path:"/a.jpg",width:400,height:200), b = ShelfItem(path:"/b.jpg",width:200,height:200)
        let board = try db.createCollection(name:"Board")
        try db.insert([a,b],into:board.id)
        let previous = try db.setBoardPlacements(collection:board.id,[a.id:BoardPlacement(x:10,y:20,width:300,z:1)])
        XCTAssertEqual(previous[a.id],.some(nil))
        XCTAssertEqual(try db.boardPlacements(collection:board.id)[a.id],BoardPlacement(x:10,y:20,width:300,z:1))
        try db.setBoardPlacements(collection:board.id,previous)
        XCTAssertTrue(try db.boardPlacements(collection:board.id).isEmpty)
        try db.setBoardPlacements(collection:board.id,[a.id:BoardPlacement(x:0,y:0,width:300)])
        let fresh = BoardLayout.place([a,b],around:try db.boardPlacements(collection:board.id))
        XCTAssertNil(fresh[a.id])
        XCTAssertEqual(fresh[b.id]?.y ?? 0,150 + 48,accuracy:0.01)
        XCTAssertEqual(try db.resetBoard(collection:board.id).count,1)
        XCTAssertTrue(try db.boardPlacements(collection:board.id).isEmpty)
        try db.deletePermanently([a.id])
        XCTAssertTrue(try db.boardPlacements(collection:board.id).isEmpty)
    }
}

final class SourceEditTests: XCTestCase {
    func testSourceAndAuthorEditsUndo() throws {
        let db = try LibraryDatabase(root:temporaryLibrary(self))
        try db.insert([ShelfItem(id:"a",path:"/a.jpg"),ShelfItem.link(url:"https://github.com/x",title:"Repo",site:"GitHub")])
        let link = try XCTUnwrap(try db.items().first { $0.kind == "link" })
        let before = try db.setSource("https://www.example.com/page",for:["a"]) + db.setAuthor("Ada",for:["a"])
        XCTAssertEqual(try db.item(id:"a")?.source,"https://www.example.com/page")
        XCTAssertEqual(try db.item(id:"a")?.site,"example.com")
        XCTAssertEqual(try db.item(id:"a")?.author,"Ada")
        try db.restore(Array(before.reversed()))
        XCTAssertEqual(try db.item(id:"a")?.source,""); XCTAssertEqual(try db.item(id:"a")?.author,"")
        // A link keeps the site name its page gave it, through edits and undo alike.
        let edit = try db.setNote("hi",for:[link.id]); try db.restore(edit)
        XCTAssertEqual(try db.item(id:link.id)?.site,"GitHub")
    }
}
