import XCTest
@testable import ShelfCore

final class QueryTests: XCTestCase {
    let day = 86400.0
    var utc: Calendar { var c = Calendar(identifier:.gregorian); c.timeZone = TimeZone(identifier:"UTC")!; return c }

    // MARK: Parser

    func testParsesTextPhrasesAndExclusions() {
        let q = SearchQuery("blue  \"dark mode\" -cat -\"stock photo\" e-mail - -- ")
        XCTAssertEqual(q.terms,[.init("blue"),.init("dark mode",phrase:true),.init("cat",negated:true),
                                .init("stock photo",phrase:true,negated:true),.init("e-mail")])
        XCTAssertTrue(q.clauses.isEmpty)
        XCTAssertEqual(q.match,"\"blue\"* AND \"dark mode\" AND \"e-mail\"*")
        XCTAssertEqual(q.exclusions,["\"cat\"","\"stock photo\""])
        XCTAssertTrue(q.hasText)
        XCTAssertFalse(SearchQuery("-cat").hasText)
        XCTAssertTrue(SearchQuery("   ").isEmpty)
        XCTAssertEqual(SearchQuery("say \u{201C}hello there\u{201D}").terms.last,.init("hello there",phrase:true))
        XCTAssertEqual(SearchQuery("a\"b").match,"\"a\"\"b\"*","Quotes inside a word are escaped, never FTS syntax")
    }
    func testParsesFilters() {
        let now = utc.date(from:DateComponents(year:2026,month:10,day:11,hour:15))!
        let q = SearchQuery("tag:\"UI kit\" type:videos kind:GIF color:#F00 colour:Blue color:grey in:\"Mood board\" is:liked -is:untagged is:missing is:trashed before:2024-01-02 after:2023 after:7d before:yesterday",now:now,calendar:utc)
        XCTAssertTrue(q.terms.isEmpty)
        XCTAssertEqual(q.clauses,[
            .init(.tag("UI kit")),.init(.kind("video")),.init(.kind("gif")),.init(.color("#ff0000")),.init(.color("blue")),.init(.color("gray")),
            .init(.collection("Mood board")),.init(.flag(.liked)),.init(.flag(.untagged),negated:true),.init(.flag(.missing)),.init(.flag(.trashed)),
            .init(.before(utc.date(from:DateComponents(year:2024,month:1,day:2))!.timeIntervalSince1970)),
            .init(.after(utc.date(from:DateComponents(year:2023,month:1,day:1))!.timeIntervalSince1970)),
            .init(.after(utc.date(from:DateComponents(year:2026,month:10,day:4))!.timeIntervalSince1970)),
            .init(.before(utc.date(from:DateComponents(year:2026,month:10,day:10))!.timeIntervalSince1970))])
    }
    func testUnknownFiltersAreText() {
        let q = SearchQuery("is:shiny before:someday foo:bar https://example.com tag: type:raw -type:png")
        XCTAssertEqual(q.terms.map(\.text),["is:shiny","before:someday","foo:bar","https://example.com"],"A bare tag: is still being typed")
        XCTAssertEqual(q.clauses,[.init(.kind("raw")),.init(.kind("png"),negated:true)])
        XCTAssertEqual(SearchQuery("color:chartreuse-ish").clauses,[.init(.color("chartreuse-ish"))])
        XCTAssertEqual(SearchQuery("#3A5AD9 poster").clauses,[.init(.color(ColorMath.target("#3a5ad9")!))])
        XCTAssertEqual(SearchQuery("#3A5AD9 poster").terms.map(\.text),["poster"])
        XCTAssertEqual(SearchQuery("#hashtag").terms.map(\.text),["#hashtag"])
        XCTAssertEqual(SearchQuery("before:2024-13-01").terms.count,1)
    }

    // MARK: Library queries

    func library() throws -> LibraryDatabase { try LibraryDatabase(root:temporaryLibrary(self)) }

    func testScopesSortsAndCounts() throws {
        let db = try library(), now = Date().timeIntervalSince1970
        let items = [
            ShelfItem(id:"p10",path:"/a/Photo 10.jpg",added:now - 1 * day,fileDate:300,fileSize:30,width:4000,height:3000),
            ShelfItem(id:"p2",path:"/a/Photo 2.jpg",tags:["travel"],added:now - 2 * day,fileDate:100,fileSize:10,width:3000,height:4000),
            ShelfItem(id:"p1",path:"/a/photo 1.JPG",added:now - 30 * day,fileDate:200,fileSize:20,width:1200,height:1200),
            ShelfItem(id:"g",path:"/a/loop.gif",tags:["fun"],added:now - 3 * day,fileSize:5),
            ShelfItem(id:"s",path:"/a/logo.svg",added:now - 4 * day,fileSize:1),
            ShelfItem(id:"r",path:"/a/raw.CR3",added:now - 5 * day,fileSize:90),
            ShelfItem(id:"v",path:"/a/clip.mov",kind:"video",added:now - 6 * day,fileSize:100),
            ShelfItem.link(url:"https://www.dribbble.com/shots/1",title:"Shot",added:now - 7.5 * day),
            ShelfItem.color("#3366FF",added:now - 8 * day)!,
        ]
        try db.insert(items)
        let link = items[7].id, color = items[8].id
        try db.setLiked(["p2","g"],true)
        try db.moveToTrash(["s"])
        try db.setMissing(["r"],true)
        let board = try db.createCollection(name:"Board")
        try db.addItems(["p1","p2","p10"],to:board.id)

        XCTAssertEqual(try db.items().map(\.id),["p10","p2","g","r","v",link,color,"p1"])
        XCTAssertEqual(try db.items(sort:.added,ascending:true).map(\.id).first,"p1")
        XCTAssertEqual(try db.items(scope:.kind("image"),sort:.name,ascending:true).map(\.id),["g","p1","p2","p10","r"])
        XCTAssertEqual(try db.items(scope:.kind("image"),sort:.name).map(\.id),["r","p10","p2","p1","g"])
        XCTAssertEqual(try db.items(scope:.collection(board.id),sort:.fileDate,ascending:true).map(\.id),["p2","p1","p10"])
        XCTAssertEqual(try db.items(scope:.collection(board.id),sort:.size).map(\.id),["p10","p1","p2"])
        XCTAssertEqual(try db.items(scope:.collection(board.id),sort:.custom).map(\.id),["p1","p2","p10"])
        let shuffled = try db.items(sort:.random(seed:42)).map(\.id)
        XCTAssertEqual(try db.items(sort:.random(seed:42)).map(\.id),shuffled)
        XCTAssertEqual(Set(shuffled),Set(try db.items().map(\.id)))
        XCTAssertNotEqual(try db.items(sort:.random(seed:7)).map(\.id),shuffled)

        XCTAssertEqual(try db.items(scope:.inbox).count,5)
        XCTAssertEqual(try db.items(scope:.liked).map(\.id),["p2","g"])
        XCTAssertEqual(try db.items(scope:.trash).map(\.id),["s"])
        XCTAssertEqual(Set(try db.items(scope:.untagged).map(\.id)),["p10","p1","r","v",link,color])
        XCTAssertEqual(try db.items(scope:.missing).map(\.id),["r"])
        XCTAssertEqual(try db.items(scope:.recent(days:7)).map(\.id),["p10","p2","g","r","v"])
        XCTAssertEqual(try db.items(scope:.kind("gif")).map(\.id),["g"])
        XCTAssertEqual(try db.items(scope:.kind("svg")).map(\.id),[],"Trashed items stay out of every scope but the trash")
        XCTAssertEqual(try db.items(scope:.kind("raw")).map(\.id),["r"])
        XCTAssertEqual(try db.items(scope:.kind("videos")).map(\.id),["v"])
        XCTAssertEqual(try db.items(scope:.kind("link")).map(\.id),[link])
        XCTAssertEqual(try db.items(scope:.kind("color")).map(\.id),[color])
        XCTAssertEqual(try db.items(scope:.tag("TRAVEL")).map(\.id),["p2"])
        XCTAssertEqual(try db.items(scope:.smart(SmartRules(rules:[SmartRule(.orientation,.is,"portrait")]))).map(\.id),["p2"])
        XCTAssertEqual(try db.items(limit:2).count,2)

        let scopes: [Scope] = [.all,.inbox,.liked,.trash,.untagged,.missing,.recent(days:7),.kind("image"),.tag("travel"),.collection(board.id)]
        let counts = try db.counts(for:scopes)
        XCTAssertEqual(counts,try scopes.map { try db.items(scope:$0).count })
        XCTAssertEqual(try db.count(.all,query:"photo"),3)
        XCTAssertEqual(try db.counts(for:[]),[])
    }

    func testSearchFilters() throws {
        let db = try library(), now = Date().timeIntervalSince1970
        let mood = try db.createCollection(name:"Mood board"), travel = try db.createCollection(name:"Travel")
        let japan = try db.createCollection(name:"Japan",parent:travel.id)
        try db.insert([
            ShelfItem(id:"red",path:"/red.jpg",title:"Sunset",tags:["dark mode"],colors:["#e53935","#202020"],added:now - 10 * day),
            ShelfItem(id:"blue",path:"/blue.png",title:"Ocean",tags:["ui kit"],colors:["#1e5aa0"],added:now - 2 * day),
            ShelfItem(id:"vid",path:"/v.mp4",title:"Ocean waves",kind:"video",added:now),
            ShelfItem(id:"temple",path:"/t.jpg",title:"Temple",note:"stock photo of kyoto",added:now - 1 * day),
        ])
        try db.addItems(["red","blue"],to:mood.id); try db.addItems(["temple"],to:japan.id)
        try db.setLiked(["blue"],true)
        try db.moveToTrash(["vid"])
        func ids(_ query: String) throws -> Set<String> { Set(try db.items(query:query).map(\.id)) }

        XCTAssertEqual(try ids("ocean"),["blue"])
        XCTAssertEqual(try ids("ocean is:trashed"),["vid"])
        XCTAssertEqual(try ids("tag:\"Dark Mode\""),["red"])
        XCTAssertEqual(try ids("dark mode"),["red"],"Multi-word tags are searchable as text")
        XCTAssertEqual(try ids("-tag:\"dark mode\""),["blue","temple"])
        XCTAssertEqual(try ids("type:png"),["blue"])
        XCTAssertEqual(try ids("type:image -type:png"),["red","temple"])
        XCTAssertEqual(try ids("color:red"),["red"])
        XCTAssertEqual(try ids("color:#ff3030"),["red"],"Close hex colours match")
        XCTAssertEqual(try ids("color:#2060a8"),["blue"])
        XCTAssertEqual(try ids("color:#00ff00"),[])
        XCTAssertEqual(try ids("color:nonsense"),[])
        XCTAssertEqual(try ids("in:\"mood board\""),["red","blue"])
        XCTAssertEqual(try ids("in:travel"),["temple"],"A parent includes its subcollections")
        XCTAssertEqual(try ids("in:nowhere"),[])
        XCTAssertEqual(try ids("travel"),["temple"],"Collection names match as text")
        XCTAssertEqual(try ids("mood"),["red","blue"])
        XCTAssertEqual(try ids("is:liked"),["blue"])
        XCTAssertEqual(try ids("is:untagged"),["temple"])
        XCTAssertEqual(try ids("-is:liked is:untagged"),["temple"])
        XCTAssertEqual(try ids("\"stock photo\""),["temple"])
        XCTAssertEqual(try ids("stock -kyoto"),[])
        XCTAssertEqual(try ids("-kyoto"),["red","blue"])
        XCTAssertEqual(try ids("after:3d"),["blue","temple"])
        XCTAssertEqual(try ids("before:3d"),["red"])
        XCTAssertEqual(try db.items(query:"ocean",rankText:false,limit:1).map(\.id),["blue"])
        try db.insert([ShelfItem(id:"long",path:"/long.JPEG",title:"Long extension")])
        XCTAssertEqual(try ids("type:jpg"),["red","temple","long"],"jpg and jpeg are one type")
        XCTAssertEqual(try ids("type:jpeg"),["red","temple","long"])
        XCTAssertEqual(try db.counts(for:[.smart(SmartRules(rules:[SmartRule(.ext,.is," , ")]))]),[0],"An empty rule matches nothing instead of failing")
        try db.deletePermanently(["long"])

        try db.insert([ShelfItem(id:"o2",path:"/o2.jpg",title:"Ocean ocean ocean",note:"ocean",added:now - 50 * day)])
        XCTAssertEqual(try db.items(query:"ocean").first?.id,"o2","Text queries rank by relevance")
        XCTAssertEqual(try db.items(query:"ocean",rankText:false).first?.id,"blue","…unless the caller asks for its sort")
    }

    // MARK: Smart rules

    func testSmartRulesCompileToParameters() {
        let c = Compiler([ShelfCollection(id:"x",name:"X"),ShelfCollection(id:"y",name:"Y",parent:"x"),
                          ShelfCollection(id:"s",name:"S",kind:.smart,rules:SmartRules(rules:[SmartRule(.collection,.is,"s")]))],now:1000)
        let rules = SmartRules(match:.any,rules:[SmartRule(.name,.contains,"50%_off'; DROP TABLE items"),SmartRule(.tag,.is,"a,b"),
                                                 SmartRule(.added,.within,"2"),SmartRule(.liked,.is,"false")],
                               groups:[SmartRules(rules:[SmartRule(.ext,.isNot,".PNG"),SmartRule(.collection,.is,"x"),SmartRule(.domain,.is,"www.Example.com")])])
        let sql = c.rules(rules)
        XCTAssertFalse(sql.sql.contains("DROP"))
        XCTAssertEqual(sql.sql.filter { $0 == "?" }.count,sql.args.count)
        guard case .text(let like) = sql.args[0], case .real(let since) = sql.args[5] else { return XCTFail() }
        XCTAssertEqual(like,"%50\\%\\_off'; DROP TABLE items%")
        XCTAssertEqual(since,1000 - 2 * 86400)
        XCTAssertTrue(sql.sql.contains(" OR ") && sql.sql.contains(" AND ") && sql.sql.contains("NOT (i.liked=1)") && sql.sql.contains("NOT (i.ext IN (?))"))
        XCTAssertEqual(c.rules(SmartRules()).sql,"1")
        XCTAssertEqual(c.collection("s",descendants:true,visiting:[]).sql,"(0)","Smart collections that refer to themselves match nothing")
        XCTAssertEqual(c.collection("missing",descendants:true,visiting:[]).sql,"0")
        XCTAssertEqual(c.subtree("x"),["x","y"])
        let decoded = try? JSONDecoder().decode(SmartRules.self,from:Data(#"{"rules":[{"field":"kind","op":"is","value":"gif"}]}"#.utf8))
        XCTAssertEqual(decoded,SmartRules(rules:[SmartRule(.kind,.is,"gif")]))
    }

    func testAutoSortCollections() throws {
        let db = try library(), now = Date().timeIntervalSince1970
        try db.insert([
            ShelfItem(id:"shot",path:"/s/Screenshot 2026-01-01 at 10.00.00.png",width:2880,height:1800),
            ShelfItem(id:"tagged-shot",path:"/s/IMG_1.png",autoTags:["screenshot"]),
            ShelfItem(id:"photo",path:"/s/IMG_2.HEIC",added:now - 30 * day,width:4032,height:3024),
            ShelfItem(id:"thumb",path:"/s/tiny.jpg",added:now - 30 * day,width:120,height:90),
            ShelfItem(id:"art",path:"/s/drawing.jpg",autoTags:["illustrations"],added:now - 30 * day,width:2000,height:2000),
            ShelfItem(id:"vector",path:"/s/logo.svg",added:now - 30 * day),
            ShelfItem(id:"text",path:"/s/menu.jpg",ocr:"Soup of the day",added:now - 30 * day,width:10,height:10),
            ShelfItem(id:"video",path:"/s/a.mp4",kind:"video",added:now - 30 * day),
            ShelfItem(id:"gif",path:"/s/a.gif",added:now - 30 * day),
            ShelfItem.link(url:"https://example.com",added:now - 30 * day),
            ShelfItem.color("#ff8800",added:now - 30 * day)!,
        ])
        let smart = Dictionary(uniqueKeysWithValues:try db.collections().filter(\.isSmart).map { ($0.name,$0.id) })
        func ids(_ name: String) throws -> Set<String> { Set(try db.items(scope:.collection(smart[name]!)).map(\.id)) }
        XCTAssertEqual(try ids("Screenshots"),["shot","tagged-shot"])
        XCTAssertEqual(try ids("Photos"),["photo"])
        XCTAssertEqual(try ids("Graphics"),["art","vector"])
        XCTAssertEqual(try ids("With Text"),["text"])
        XCTAssertEqual(try ids("Videos"),["video"])
        XCTAssertEqual(try ids("GIFs"),["gif"])
        XCTAssertEqual(try ids("Links"),[ShelfItem.digest("link|https://example.com")])
        XCTAssertEqual(try ids("Colors"),[ShelfItem.digest("color|#ff8800")])
        XCTAssertEqual(try ids("Recently Added"),["shot","tagged-shot"])
        let tree = try db.collectionTree()
        XCTAssertEqual(tree.first { $0.collection.name == "Screenshots" }?.count,2)
        XCTAssertEqual(tree.first { $0.collection.name == "Graphics" }?.count,2)
    }

    // MARK: Colours and names

    func testColorMath() {
        let a = ColorMath.Lab(l:50,a:2.6772,b:-79.7751), b = ColorMath.Lab(l:50,a:0,b:-82.7485)
        XCTAssertEqual(ColorMath.deltaE(a,b),2.0425,accuracy:0.0001)
        XCTAssertEqual(ColorMath.deltaE(ColorMath.Lab(l:50,a:2.5,b:0),ColorMath.Lab(l:73,a:25,b:-18)),27.1492,accuracy:0.0001)
        XCTAssertEqual(ColorMath.hex("F80"),"#ff8800")
        XCTAssertNil(ColorMath.hex("#12345"))
        XCTAssertEqual(ColorMath.target("Grey"),"gray")
        XCTAssertEqual(ColorMath.target("brown"),"#8b5a2b")
        XCTAssertTrue(ColorMath.matches(palette:"#ffffff #ff1010",target:"red"))
        XCTAssertFalse(ColorMath.matches(palette:"#ffffff",target:"#000000"))
    }
    func testNaturalNameOrder() throws {
        let db = try library()
        let names = ["file 10","File 2","file 1","Été","ete 3","alpha","Zulu","file 02b","b"]
        try db.insert(names.map { ShelfItem(path:"/n/\($0).jpg") })
        XCTAssertEqual(try db.items(sort:.name,ascending:true).map(\.title),["alpha","b","Été","ete 3","file 1","File 2","file 02b","file 10","Zulu"])
    }
}

final class LinkMetadataTests: XCTestCase {
    func testReadsOpenGraphFirst() {
        let html = """
        <html><head><title> Fallback  title </title>
        <meta property="og:title" content="Quiet &amp; calm rooms">
        <meta name='description' content='A study of light'>
        <meta property="og:site_name" content="Folio Studio"/>
        <meta property="og:image" content="/images/cover.jpg">
        <link rel="icon" href="/favicon.ico"><link rel="apple-touch-icon" href="https://cdn.example.com/touch.png">
        </head><body>…</body></html>
        """
        let meta = LinkMetadata.parse(html:html,base:URL(string:"https://example.com/post/1")!)
        XCTAssertEqual(meta.title,"Quiet & calm rooms")
        XCTAssertEqual(meta.site,"Folio Studio")
        XCTAssertEqual(meta.summary,"A study of light")
        XCTAssertEqual(meta.image?.absoluteString,"https://example.com/images/cover.jpg")
        XCTAssertEqual(meta.icon?.absoluteString,"https://cdn.example.com/touch.png")
        XCTAssertEqual(LinkMetadata.parse(html:"<title>Only\ntitle</title>",base:URL(string:"https://a.com")!).title,"Only title")
    }
    func testFindsURLsInPastedText() {
        let urls = LinkMetadata.urls(in:"see https://a.com/x and\nhttp://b.org/y.png, (https://a.com/x) mailto:me@c.d notaurl")
        XCTAssertEqual(urls.map(\.absoluteString),["https://a.com/x","http://b.org/y.png"])
        XCTAssertTrue(LinkMetadata.isMedia(urls[1])); XCTAssertFalse(LinkMetadata.isMedia(urls[0]))
    }
    func testLinkCardsAreFourByThree() {
        let layout = MasonryLayout(items:[ShelfItem.link(url:"https://a.com"),ShelfItem.color("#ff0000")!],width:1000,tileSize:200,style:.rows)
        XCTAssertEqual(layout.frames[0].width/layout.frames[0].height,4.0/3,accuracy:0.01)
        XCTAssertEqual(layout.frames[1].width/layout.frames[1].height,0.8,accuracy:0.01)
    }
}

final class SemanticSearchTests: XCTestCase {
    func testWordsPointToLabels() {
        let vocabulary = ["dog","beach","prairie-dog","cat","mountain","snow","red","orange","interior-room","bar"]
        let dogs = SemanticSearch.expand("dogs on the beach",vocabulary:vocabulary)
        XCTAssertEqual(dogs["dog"],1); XCTAssertEqual(dogs["beach"],1)
        XCTAssertLessThan(dogs["prairie-dog"] ?? 0,1)
        XCTAssertNil(dogs["mountain"])
        let warm = SemanticSearch.expand("warm bar interior",vocabulary:vocabulary)
        XCTAssertEqual(warm["bar"],1); XCTAssertNotNil(warm["red"]); XCTAssertNotNil(warm["interior-room"])
        XCTAssertEqual(SemanticSearch.expand("mountains with snow",vocabulary:vocabulary)["mountain"],1)
        XCTAssertEqual(SemanticSearch.expand("skies",vocabulary:["sky"])["sky"],1)
        XCTAssertEqual(SemanticSearch.expand("beaches",vocabulary:["beach"])["beach"],1)
        XCTAssertEqual(SemanticSearch.singular("glass"),"glass")
        let item = ShelfItem(path:"/a.jpg",autoTags:["dog","beach"])
        XCTAssertEqual(SemanticSearch.score(item,dogs),2,accuracy:0.001)
    }
}
