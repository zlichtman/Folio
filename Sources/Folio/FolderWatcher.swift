import Foundation
import CoreServices
import ShelfCore

/// Keeps watched folders in step with the disk: a scan at launch, then one shortly after anything inside changes.
final class FolderWatcher {
    private let database: LibraryDatabase
    private let queue = DispatchQueue(label:"org.lumashelf.folders",qos:.utility)
    private var stream: FSEventStreamRef?
    private var pending: [String:DispatchWorkItem] = [:]
    var didChange: (() -> Void)?
    init(database: LibraryDatabase) { self.database = database }
    deinit { stop() }

    static func displayName(_ path: String) -> String {
        let url = URL(fileURLWithPath:path)
        if path == screenshotFolder.path, path != desktop.path { return "Screenshots" }
        return FileManager.default.displayName(atPath:url.path)
    }
    /// The path events report: symlinks resolved the way the kernel does (/tmp becomes /private/tmp).
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path,nil) else { return path }
        defer { free(resolved) }
        return String(cString:resolved)
    }
    static var desktop: URL { FileManager.default.urls(for:.desktopDirectory,in:.userDomainMask)[0] }
    static var downloads: URL { FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask)[0] }
    /// Where macOS saves screenshots: the Desktop unless changed in the Screenshot app's options.
    static var screenshotFolder: URL {
        let saved = UserDefaults(suiteName:"com.apple.screencapture")?.string(forKey:"location")
        let path = (saved as NSString?)?.expandingTildeInPath
        var folder: ObjCBool = false
        if let path, FileManager.default.fileExists(atPath:path,isDirectory:&folder), folder.boolValue { return URL(fileURLWithPath:path,isDirectory:true) }
        return desktop
    }
    /// Suggested folders for the first run, without duplicates.
    static var suggestions: [(title: String, url: URL)] {
        var out: [(String,URL)] = [("Desktop",desktop),("Downloads",downloads)]
        if screenshotFolder.standardizedFileURL != desktop.standardizedFileURL { out.append(("Screenshots",screenshotFolder)) }
        return out
    }

    func start() {
        queue.async { [weak self] in
            guard let self, let folders = try? self.database.connectedFolders() else { return }
            for folder in folders { self.scan(folder) }
            DispatchQueue.main.async { self.restartStream() }
        }
    }
    func watch(_ url: URL, completion: @escaping (Result<ConnectedFolder,Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let folder = try self.database.addConnectedFolder(path:url.path)
                self.scan(folder)
                DispatchQueue.main.async { self.restartStream(); completion(.success(folder)) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }
    func unwatch(_ id: String, completion: @escaping () -> Void) {
        queue.async { [weak self] in
            try? self?.database.removeConnectedFolder(id)
            DispatchQueue.main.async { self?.restartStream(); completion() }
        }
    }
    func rescan(_ id: String) {
        queue.async { [weak self] in
            guard let self, let folder = try? self.database.connectedFolders().first(where:{ $0.id == id }) else { return }
            self.scan(folder)
        }
    }
    private func scan(_ folder: ConnectedFolder) {
        let found = MediaFiles.scan([URL(fileURLWithPath:folder.path,isDirectory:true)])
        guard let changes = try? database.applyScan(folderID:folder.id,found:found) else { return }
        if !(changes.added.isEmpty && changes.updated.isEmpty && changes.moved.isEmpty && changes.removed.isEmpty) || folder.lastScan == nil {
            DispatchQueue.main.async { [weak self] in self?.didChange?() }
        }
    }
    private func changed(_ paths: [String]) {
        guard let folders = try? database.connectedFolders() else { return }
        for folder in folders {
            let root = Self.realPath(folder.path)
            guard paths.contains(where:{ $0 == root || $0.hasPrefix(root + "/") || $0 == folder.path || $0.hasPrefix(folder.path + "/") }) else { continue }
            pending[folder.id]?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.pending[folder.id] = nil; self?.scan(folder) }
            pending[folder.id] = work
            queue.asyncAfter(deadline:.now() + 1.2,execute:work)
        }
    }
    private func restartStream() {
        stop()
        guard let paths = try? database.connectedFolders().map(\.path), !paths.isEmpty else { return }
        var context = FSEventStreamContext(version:0,info:Unmanaged.passUnretained(self).toOpaque(),retain:nil,release:nil,copyDescription:nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths,to:NSArray.self) as? [String] ?? []).prefix(count).map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            watcher.changed(Array(list))
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagIgnoreSelf)
        guard let created = FSEventStreamCreate(nil,callback,&context,paths as CFArray,FSEventStreamEventId(kFSEventStreamEventIdSinceNow),0.8,flags) else { return }
        FSEventStreamSetDispatchQueue(created,queue)
        FSEventStreamStart(created)
        stream = created
    }
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        self.stream = nil
    }
}
