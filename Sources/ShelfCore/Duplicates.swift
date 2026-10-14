import Foundation
import CryptoKit

/// Exact copies: the same bytes under different names or places. Only files that share a size are read, so a large
/// library is checked quickly.
public enum Duplicates {
    /// Groups of item ids holding identical files, each oldest first (the one to keep), largest groups first.
    public static func groups(_ items: [ShelfItem]) -> [[String]] {
        let files = items.filter { $0.path.hasPrefix("/") && !$0.missing && $0.trashed == nil && $0.fileSize > 0 }
        var groups: [[ShelfItem]] = []
        for sameSize in Dictionary(grouping:files,by:\.fileSize).values where sameSize.count > 1 {
            let byHash = Dictionary(grouping:sameSize.compactMap { item in digest(item.path).map { (item,$0) } },by:\.1)
            groups += byHash.values.filter { $0.count > 1 }.map { $0.map(\.0) }
        }
        return groups.map { $0.sorted { ($0.added,$0.id) < ($1.added,$1.id) }.map(\.id) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0[0] < $1[0] }
    }
    static func digest(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath:path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount:1 << 20), !chunk.isEmpty { hasher.update(data:chunk) }
        return hasher.finalize().map { String(format:"%02x",$0) }.joined()
    }
}
