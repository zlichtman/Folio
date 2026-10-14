import Foundation

/// How the grid arranges items: justified rows of equal height, or columns of equal width.
/// `infinity` is drawn by the app's endless wall; the grid lays it out as columns underneath.
public enum GridStyle: String, CaseIterable, Sendable { case rows, columns, list, infinity }

/// Frames are computed once when data/width/zoom changes. Scroll queries use binary search.
public struct MasonryLayout {
    public let columns: Int
    public let frames: [CGRect]
    public let height: Double
    private let maxTileHeight: Double
    /// `spacing` scales the gaps between pictures: 1 is the standard 12 points in columns and 10 in rows.
    public init(items: [ShelfItem], width: Double, tileSize: Double, captions: Bool = false, style: GridStyle = .columns, spacing: Double = 1) {
        switch style {
        case .rows: self.init(rows:items,width:width,tileSize:tileSize,captions:captions,gap:10 * spacing)
        case .columns, .infinity: self.init(columns:items,width:width,tileSize:tileSize,captions:captions,gap:12 * spacing)
        case .list: self.init(list:items,width:width,tileSize:tileSize)
        }
    }
    /// A list: one full-width row per item, as tall as a small thumbnail (the size slider sets it).
    private init(list items: [ShelfItem], width: Double, tileSize: Double) {
        let padding = 24.0, row = max(40,min(120,tileSize * 0.28)).rounded(), gap = 2.0
        frames = items.indices.map { CGRect(x:padding,y:padding + Double($0) * (row + gap),width:max(1,width - padding * 2),height:row) }
        columns = 1; height = max(1,padding * 2 + Double(items.count) * (row + gap) - gap); maxTileHeight = row
    }
    private init(columns items: [ShelfItem], width: Double, tileSize: Double, captions: Bool, gap: Double) {
        let padding = 24.0
        columns = max(1,Int((max(1,width-padding*2)+gap)/(max(90,tileSize)+gap)))
        let cell = max(1,(width-padding*2-Double(columns-1)*gap)/Double(columns))
        var ends = [Double](repeating:padding,count:columns), result: [CGRect] = []
        result.reserveCapacity(items.count)
        let caption = captions ? 24.0 : 0
        for item in items {
            let column = ends.indices.min(by:{ ends[$0] < ends[$1] }) ?? 0
            let aspect = 1 / MasonryLayout.aspect(item)
            let h = cell * max(0.55,min(1.65,aspect)) + caption
            result.append(CGRect(x:padding+Double(column)*(cell+gap),y:ends[column],width:cell,height:h))
            ends[column] += h + gap
        }
        frames = result; height = max(1,(ends.max() ?? 0)+padding-gap)
        maxTileHeight = cell*1.65+caption
    }
    /// Justified rows: each full row fills the width at close to `tileSize` × 0.8 high, and every image keeps its shape.
    private init(rows items: [ShelfItem], width: Double, tileSize: Double, captions: Bool, gap: Double) {
        let padding = 24.0, caption = captions ? 24.0 : 0
        let usable = max(1,width-padding*2), target = max(72,tileSize*0.8)
        var result: [CGRect] = [], y = padding, row: [Double] = [], tallest = 0.0
        result.reserveCapacity(items.count)
        func place(_ aspects: [Double], height h: Double) {
            var x = padding
            for aspect in aspects { result.append(CGRect(x:x,y:y,width:aspect*h,height:h+caption)); x += aspect*h+gap }
            y += h+caption+gap; tallest = max(tallest,h+caption)
        }
        var sum = 0.0
        for item in items {
            let aspect = MasonryLayout.aspect(item)
            row.append(aspect); sum += aspect
            let h = (usable-Double(row.count-1)*gap)/sum
            if h <= target { place(row,height:h); row.removeAll(keepingCapacity:true); sum = 0 }
        }
        if !row.isEmpty { place(row,height:target) }
        frames = result; columns = 1
        height = max(1,y+padding-gap); maxTileHeight = max(tallest,1)
    }
    public func frame(index: Int) -> CGRect { frames.indices.contains(index) ? frames[index] : .zero }
    /// Width over height. Link cards are 4:3 and colours are portrait paint chips; media keeps its own shape.
    public static func aspect(_ item: ShelfItem) -> Double {
        if item.kind == "link", !(item.width > 0 && item.height > 0) || !item.path.hasPrefix("/") { return 4.0/3 }
        if item.kind == "color" { return 0.8 }
        return item.width > 0 && item.height > 0 ? max(0.3,min(3.5,item.width/item.height)) : 1
    }
    /// The item next to `index` in a direction (arrow keys), nearest by position rather than by list order.
    public func neighbor(of index: Int, dx: Int, dy: Int) -> Int? {
        guard frames.indices.contains(index) else { return frames.isEmpty ? nil : 0 }
        if dy == 0 { let next = index+dx; return frames.indices.contains(next) ? next : nil }
        let current = frames[index], window = dy > 0 ? (index+1)..<min(frames.count,index+400) : max(0,index-400)..<index
        let candidates = window.filter { dy > 0 ? frames[$0].minY >= current.maxY - 1 : frames[$0].maxY <= current.minY + 1 }
        let overlapping = candidates.filter { frames[$0].minX < current.maxX && frames[$0].maxX > current.minX }
        func gap(_ i: Int) -> Double { (dy > 0 ? frames[i].minY - current.maxY : current.minY - frames[i].maxY).rounded() }
        return (overlapping.isEmpty ? candidates : overlapping).min { (gap($0),abs(frames[$0].midX-current.midX)) < (gap($1),abs(frames[$1].midX-current.midX)) }
    }
    /// Items whose frames intersect `rect`, for rubber-band selection.
    public func indices(in rect: CGRect) -> [Int] {
        visibleRange(y:rect.minY,height:rect.height).filter { frames[$0].intersects(rect) }
    }
    private func lowerBound(_ y: Double) -> Int {
        var low=0, high=frames.count
        while low<high { let middle=(low+high)/2; if frames[middle].minY < y { low=middle+1 } else { high=middle } }
        return low
    }
    public func visibleRange(y: Double, height: Double, marginRows: Int = 0) -> Range<Int> {
        let margin = Double(marginRows)*maxTileHeight
        return lowerBound(max(0,y)-maxTileHeight-margin)..<lowerBound(max(0,y)+max(0,height)+margin)
    }
    public func index(x: Double, y: Double) -> Int? {
        visibleRange(y:y,height:1).first { frames[$0].contains(CGPoint(x:x,y:y)) }
    }
}

public struct GridGeometry: Sendable {
    public var count: Int
    public var width: Double
    public var tileSize: Double
    public let gap: Double = 14
    public let padding: Double = 20
    public let caption: Double = 24
    public init(count: Int, width: Double, tileSize: Double) {
        self.count = max(0, count); self.width = max(1, width); self.tileSize = max(60, tileSize)
    }
    public var columns: Int { max(1, Int((max(1, width - 2 * padding) + gap) / (tileSize + gap))) }
    public var actualWidth: Double { max(1, (width - 2 * padding - Double(columns - 1) * gap) / Double(columns)) }
    public var rowStride: Double { actualWidth + caption + gap }
    public var rows: Int { (count + columns - 1) / columns }
    public var height: Double { max(1, 2 * padding + Double(rows) * rowStride) }
    public func visibleRange(y: Double, height: Double, marginRows: Int = 0) -> Range<Int> {
        let first = max(0, min(rows, Int(floor((max(0, y) - padding) / rowStride)) - marginRows))
        let last = max(first, min(rows, Int(ceil((max(0, y) + max(0, height) - padding) / rowStride)) + marginRows))
        return min(count, first * columns)..<min(count, last * columns)
    }
    public func frame(index: Int) -> CGRect {
        CGRect(x: padding + Double(index % columns) * (actualWidth + gap),
               y: padding + Double(index / columns) * rowStride,
               width: actualWidth, height: actualWidth + caption)
    }
    public func index(x: Double, y: Double) -> Int? {
        guard x >= padding, y >= padding else { return nil }
        let col = Int((x - padding) / (actualWidth + gap)), row = Int((y - padding) / rowStride)
        let i = row * columns + col
        guard col < columns, i < count, frame(index: i).contains(CGPoint(x: x, y: y)) else { return nil }
        return i
    }
}

public struct Distribution: Codable, Sendable {
    public var count: Int
    public var medianMS: Double
    public var p95MS: Double
    public var maxMS: Double
    public init(seconds: [Double]) {
        let s = seconds.sorted().map { $0 * 1000 }
        count = s.count
        medianMS = s.isEmpty ? 0 : s[s.count / 2]
        p95MS = s.isEmpty ? 0 : s[min(s.count - 1, Int(ceil(Double(s.count) * 0.95)) - 1)]
        maxMS = s.last ?? 0
    }
}
