import XCTest
@testable import ShelfCore

final class ColorPasteTests: XCTestCase {
    func testFindsColorsInPastedText() {
        XCTAssertEqual(ColorMath.colors(in:"Palette: #E07A5F, #3d405b and #f2cc8f. Again #e07a5f"),["#e07a5f","#3d405b","#f2cc8f"])
        XCTAssertEqual(ColorMath.colors(in:"  1f6f5c \n"),["#1f6f5c"])
        XCTAssertEqual(ColorMath.colors(in:"#fff on #000"),["#ffffff","#000000"])
        // Not colours: anchors in addresses, entities, issue numbers, plain words.
        XCTAssertEqual(ColorMath.colors(in:"https://example.com/page#section and &#123; issue #1234 cafe"),[])
        XCTAssertNotNil(ShelfItem.color("#e07a5f"))
    }
    func testCountsRulesBeforeSaving() throws {
        let db = try LibraryDatabase(root:temporaryLibrary(self))
        try db.insert([ShelfItem(id:"a",path:"/a.png",width:800,height:400),ShelfItem(id:"b",path:"/b.png",width:300,height:600),ShelfItem(id:"c",path:"/c.mov",kind:"video")])
        XCTAssertEqual(try db.count(rules:SmartRules(rules:[SmartRule(.orientation,.is,"landscape")])),1)
        XCTAssertEqual(try db.count(rules:SmartRules(match:.any,rules:[SmartRule(.kind,.is,"video"),SmartRule(.height,.greater,"500")])),2)
        try db.moveToTrash(["c"])
        XCTAssertEqual(try db.count(rules:SmartRules(rules:[SmartRule(.kind,.is,"video")])),0)
    }
}
