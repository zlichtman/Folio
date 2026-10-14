import Foundation
import CSQLite

/// Where an item sits on a collection's board: its top-left corner, its width (height follows its shape)
/// and its stacking order.
public struct BoardPlacement: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var z: Double
    public init(x: Double, y: Double, width: Double, z: Double = 0) { self.x = x; self.y = y; self.width = width; self.z = z }
}

/// Boards: a place in the library laid out by hand on a canvas. Items keep their place; ones without one are laid out
/// in rows below the rest when the board opens. A collection's board is keyed by its id; any other place (a tag,
/// All Items, a watched folder) by a key with a colon, such as `tag:sunset` or `scope:all`, kept apart so it
/// needs no collection behind it.
extension LibraryDatabase {
    private func boardTable(_ key: String) -> (table: String, column: String) { key.contains(":") ? ("board_spaces","board") : ("board_items","collection") }
    public func boardPlacements(collection: String) throws -> [String:BoardPlacement] {
        try sync {
            var out: [String:BoardPlacement] = [:]
            let t = boardTable(collection)
            try rows("SELECT item,x,y,width,z FROM \(t.table) WHERE \(t.column)=?",[.text(collection)]) { p in
                out[text(p,0)] = BoardPlacement(x:sqlite3_column_double(p,1),y:sqlite3_column_double(p,2),width:sqlite3_column_double(p,3),z:sqlite3_column_double(p,4))
            }
            return out
        }
    }
    /// Saves placements and returns the ones they replaced (nil where an item had none), for undo.
    @discardableResult public func setBoardPlacements(collection: String, _ placements: [String:BoardPlacement?]) throws -> [String:BoardPlacement?] {
        try transaction {
            let before = try boardPlacements(collection:collection)
            var previous: [String:BoardPlacement?] = [:]
            let t = boardTable(collection)
            for (item,placement) in placements {
                previous[item] = .some(before[item])
                if let placement {
                    try run("INSERT OR REPLACE INTO \(t.table)(\(t.column),item,x,y,width,z) SELECT ?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM items WHERE id=?)",
                            [.text(collection),.text(item),.real(placement.x),.real(placement.y),.real(placement.width),.real(placement.z),.text(item)])
                } else {
                    try run("DELETE FROM \(t.table) WHERE \(t.column)=? AND item=?",[.text(collection),.text(item)])
                }
            }
            return previous
        }
    }
    /// Forgets every placement, so the board lays itself out again in the collection's order.
    @discardableResult public func resetBoard(collection: String) throws -> [String:BoardPlacement?] {
        try transaction {
            let before = try boardPlacements(collection:collection)
            let t = boardTable(collection)
            try run("DELETE FROM \(t.table) WHERE \(t.column)=?",[.text(collection)])
            return before.mapValues { .some($0) }
        }
    }
}

/// Lays out items that have no place on a board yet: rows of equal height below everything already placed.
public enum BoardLayout {
    public static func place(_ items: [ShelfItem], around existing: [String:BoardPlacement], rowWidth: Double = 1600, height: Double = 220,
                             gap: Double = 24, margin: Double = 48) -> [String:BoardPlacement] {
        var out: [String:BoardPlacement] = [:]
        let placed = items.filter { existing[$0.id] != nil }
        var y = placed.map { item -> Double in
            let p = existing[item.id]!
            return p.y + p.width / aspect(item)
        }.max().map { $0 + gap * 2 } ?? margin
        var x = margin, z = (existing.values.map(\.z).max() ?? 0) + 1
        for item in items where existing[item.id] == nil {
            let width = height * aspect(item)
            if x > margin, x + width > rowWidth + margin { x = margin; y += height + gap }
            out[item.id] = BoardPlacement(x:x,y:y,width:width,z:z); x += width + gap; z += 1
        }
        return out
    }
    /// Width over height, as the grid draws the item.
    public static func aspect(_ item: ShelfItem) -> Double { MasonryLayout.aspect(item) }
}
