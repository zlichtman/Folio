import Foundation

/// Where the library lives: `~/Library/Application Support/Folio`. Libraries made before 1.8 sat in
/// `LumaShelf`, Folio's working name; the first launch of 1.8 renames that folder in place.
enum LibraryLocation {
    /// `--support-folder` stands in for Application Support in development checks of the move.
    static var support: URL {
        argument("--support-folder").map { URL(fileURLWithPath:$0,isDirectory:true) }
            ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
    }
    static var folder: URL { support.appendingPathComponent("Folio",isDirectory:true) }
    static var legacy: URL { support.appendingPathComponent("LumaShelf",isDirectory:true) }
    /// Thumbnails are a cache that can always be rebuilt, so they live in Caches rather than with the library.
    static var previews: URL {
        FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "org.lumashelf.app",isDirectory:true)
            .appendingPathComponent("Previews",isDirectory:true)
    }
    /// Another library chosen in File ▸ Library, when it still exists; nil means the main one.
    static var chosen: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey:"library.current"), FileManager.default.fileExists(atPath:path) else { return nil }
            return URL(fileURLWithPath:path,isDirectory:true)
        }
        set { UserDefaults.standard.set(newValue?.path,forKey:"library.current") }
    }
    /// Libraries opened before, most recent first, without the main one.
    static var others: [URL] {
        get { (UserDefaults.standard.stringArray(forKey:"library.others") ?? []).filter { FileManager.default.fileExists(atPath:$0) }.map { URL(fileURLWithPath:$0,isDirectory:true) } }
        set { UserDefaults.standard.set(newValue.map(\.path),forKey:"library.others") }
    }
    static func name(_ root: URL) -> String { root.standardizedFileURL == folder.standardizedFileURL ? "Main Library" : root.deletingPathExtension().lastPathComponent }
    /// The library folder to open, and the old path when this launch moved it (so stored paths can follow).
    static func resolve() -> (root: URL, movedFrom: String?) {
        if let chosen { return (chosen,nil) }
        let manager = FileManager.default
        guard manager.fileExists(atPath:legacy.path) else { return (folder,nil) }
        // Both exist only if an older Folio ran after the move; the renamed library is the real one.
        guard !manager.fileExists(atPath:folder.path) else { return (folder,nil) }
        do { try manager.moveItem(at:legacy,to:folder) } catch { return (legacy,nil) }
        tidy(folder)
        return (folder,legacy.path)
    }
    /// Removes what never belonged in the library folder: the old thumbnail cache and an empty stray database file.
    static func tidy(_ root: URL) {
        let manager = FileManager.default
        try? manager.removeItem(at:root.appendingPathComponent("previews",isDirectory:true))
        let stray = root.appendingPathComponent("library.sqlite")
        if (try? stray.resourceValues(forKeys:[.fileSizeKey]))?.fileSize == 0 { try? manager.removeItem(at:stray) }
    }
}
