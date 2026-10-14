import XCTest
import CSQLite
@testable import ShelfCore

final class PerformanceTests: XCTestCase {
    func median<T>(_ body: () throws -> T) rethrows -> (seconds: Double, value: T) {
        var times: [Double] = [], value: T?
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            value = try body()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
        return (times.sorted()[2],value!)
    }

    func testTenThousandItemsListAndSearchQuickly() throws {
        let db = try LibraryDatabase(root:temporaryLibrary(self))
        let words = ["warm","blue","interface","green","landscape","poster","mono","typography","kitchen","night","street","portrait"]
        let boards = try (0..<20).map { try db.createCollection(name:"Board \($0)").id }
        let text = String(repeating:"Lorem ipsum dolor sit amet consectetur adipiscing elit ",count:40)
        try db.transaction {
            let item = try db.statement("""
                INSERT INTO items(id,path,title,kind,ext,added,file_date,file_size,width,height,tags,auto_tags,colors,note,ocr)
                VALUES(?,?,?,'image','jpg',?,?,?,640,?,?,?,?,?,?)
                """)
            defer { sqlite3_finalize(item) }
            let member = try db.statement("INSERT INTO item_collections(item,collection,position,added) VALUES(?,?,?,?)")
            defer { sqlite3_finalize(member) }
            for i in 0..<10_000 {
                let id = String(format:"%064x",i), a = words[i % words.count], b = words[(i / 7) % words.count]
                db.bind([.text(id),.text("/fixtures/\(a)-\(i).jpg"),.text("\(a) \(b) \(i)"),.real(Double(i)),.real(Double(i)),.int(Int64(1000 + i)),
                         .real(Double(480 + i % 400)),.text(Tags.encode([a,"\(b) mood"])),.text(Tags.encode([b])),.text("#3366ff #ffffff"),
                         .text(i % 4 == 0 ? "saved for later" : ""),.text(i % 5 == 0 ? text : "")],to:item)
                try db.step(item)
                if i % 3 == 0 { db.bind([.text(id),.text(boards[i % boards.count]),.real(Double(i)),.real(Double(i))],to:member); try db.step(member) }
            }
        }
        try db.refreshNames(inCollections:boards)

        // 50 ms on a Mac; shared CI runners are slower and noisier, so they only catch large regressions.
        let budget = ProcessInfo.processInfo.environment["CI"] == nil ? 0.05 : 0.25
        let all = try median { try db.items(scope:.all) }
        XCTAssertEqual(all.value.count,10_000)
        XCTAssertTrue(all.value.allSatisfy { $0.ocr.isEmpty })
        XCTAssertLessThan(all.seconds,budget,"Listing 10k items took \(Int(all.seconds * 1000)) ms")

        let search = try median { try db.items(query:"blue") }
        XCTAssertGreaterThan(search.value.count,1000)
        XCTAssertLessThan(search.seconds,budget,"Searching 10k items took \(Int(search.seconds * 1000)) ms")

        let scopes: [Scope] = [.all,.inbox,.liked,.trash,.untagged,.missing,.recent(days:7)] + boards.map { .collection($0) }
        let counts = try median { try db.counts(for:scopes) }
        XCTAssertEqual(counts.value[0],10_000)
        XCTAssertLessThan(counts.seconds,budget,"Counting \(scopes.count) sidebar rows took \(Int(counts.seconds * 1000)) ms")
        let named = try median { try db.items(sort:.name,ascending:true) }
        XCTAssertEqual(named.value.first?.title,"blue blue 13")
        let filtered = try median { try db.items(query:"color:blue type:jpg tag:\"night mood\" -warm") }
        XCTAssertGreaterThan(filtered.value.count,0)
        print("10k items: list \(Int(all.seconds * 1000)) ms, search \(Int(search.seconds * 1000)) ms (\(search.value.count) results),",
              "counts \(Int(counts.seconds * 1000)) ms, by name \(Int(named.seconds * 1000)) ms, filters \(Int(filtered.seconds * 1000)) ms")
    }
}
