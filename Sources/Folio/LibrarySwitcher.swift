import AppKit
import ShelfCore

/// Several libraries, one open at a time: File ▸ Library lists them, makes new ones and opens others. Switching
/// reopens Folio on the chosen library, so nothing from the last one lingers.
extension AppController {
    var libraryMenuItem: NSMenuItem {
        let item = NSMenuItem(title:"Library",action:nil,keyEquivalent:"")
        let menu = NSMenu(title:"Library")
        MainActor.assumeIsolated { menu.delegate = LibraryMenu.shared; LibraryMenu.shared.app = self }
        item.submenu = menu
        return item
    }
    /// Every library to offer, the open one included: the main one first, then others by when they were last opened.
    var libraries: [URL] { [LibraryLocation.folder] + LibraryLocation.others.filter { $0.standardizedFileURL != LibraryLocation.folder.standardizedFileURL } }

    @objc func newLibraryPanel() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "New Library"; panel.prompt = "Create"
        panel.message = "A library is a folder that holds its own collections, tags and the files Folio keeps."
        panel.beginSheetModal(for:window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true); self?.switchLibrary(to:url) }
            catch { self?.showError(error) }
        }
    }
    @objc func openLibraryPanel() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Open"
        panel.message = "Choose a Folio library folder."
        panel.beginSheetModal(for:window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard FileManager.default.fileExists(atPath:url.appendingPathComponent("index.sqlite").path) else {
                let alert = NSAlert(); alert.messageText = "“\(url.lastPathComponent)” isn't a Folio library"
                alert.informativeText = "Choose a folder made with File ▸ Library ▸ New Library, or use Import Library to bring in pictures from another app."
                alert.beginSheetModal(for:window); return
            }
            switchLibrary(to:url)
        }
    }
    @objc func chooseLibrary(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { switchLibrary(to:url) } }
    @objc func revealLibrary() { NSWorkspace.shared.activateFileViewerSelecting([database.root]) }

    /// Remembers the choice and reopens Folio on it.
    func switchLibrary(to url: URL) {
        guard url.standardizedFileURL != database.root.standardizedFileURL else { return }
        let main = url.standardizedFileURL == LibraryLocation.folder.standardizedFileURL
        LibraryLocation.chosen = main ? nil : url
        if !main { LibraryLocation.others = [url] + LibraryLocation.others.filter { $0.standardizedFileURL != url.standardizedFileURL } }
        relaunch()
    }
    /// The other libraries, for Copy and Move to Library.
    var otherLibraries: [URL] { libraries.filter { $0.standardizedFileURL != database.root.standardizedFileURL } }
    /// Copies items into another library, or moves them (they go to this library's Trash, so Undo brings them back).
    func send(_ items: [ShelfItem], to library: URL, move: Bool) {
        let ids = items.map(\.id), name = LibraryLocation.name(library)
        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                let other = try LibraryDatabase(root:library)
                let arrived = try self.database.copy(ids,to:other)
                DispatchQueue.main.async {
                    if move { self.remove(items) }
                    let noun = items.count == 1 ? "“\(items[0].title)”" : "\(items.count) items"
                    self.notify(arrived.isEmpty ? "\(name) already has \(items.count == 1 ? "it" : "them")" : "\(move ? "Moved" : "Copied") \(noun) to \(name)")
                }
            } catch { DispatchQueue.main.async { self.showError(error) } }
        }
    }
    func libraryMenu(for items: [ShelfItem], move: Bool) -> NSMenu {
        let menu = NSMenu()
        for url in otherLibraries {
            let entry = NSMenuItem(title:LibraryLocation.name(url),action:#selector(sendToLibrary(_:)),keyEquivalent:""); entry.target = self
            entry.representedObject = (url,move); menu.addItem(entry)
        }
        return menu
    }
    /// File ▸ Copy or Move to Library for a whole collection, from its right-click menu.
    func collectionLibraryMenu(_ id: String, move: Bool) -> NSMenu {
        let menu = NSMenu()
        for url in otherLibraries {
            let entry = NSMenuItem(title:LibraryLocation.name(url),action:#selector(sendCollectionToLibrary(_:)),keyEquivalent:""); entry.target = self
            entry.representedObject = (id,url,move); menu.addItem(entry)
        }
        return menu
    }
    /// Copies a collection to another library. A move then takes the collection out of this one, and puts its items
    /// in the Trash unless another collection here still holds them.
    @objc func sendCollectionToLibrary(_ sender: NSMenuItem) {
        guard let (id,library,move) = sender.representedObject as? (String,URL,Bool) else { return }
        let destination = LibraryLocation.name(library)
        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                let sent = try self.database.copyCollection(id,to:try LibraryDatabase(root:library))
                DispatchQueue.main.async {
                    if move {
                        self.perform("Move Collection") { db in try db.deleteCollection(id) }
                        if !sent.onlyHere.isEmpty { self.edit("Move to Trash") { try $0.moveToTrash(sent.onlyHere) } }
                    }
                    self.notify("\(move ? "Moved" : "Copied") “\(sent.name)” (\(sent.count == 1 ? "1 item" : "\(sent.count.formatted()) items")) to \(destination)")
                }
            } catch { DispatchQueue.main.async { self.showError(error) } }
        }
    }
    @objc func sendToLibrary(_ sender: NSMenuItem) {
        guard let (url,move) = sender.representedObject as? (URL,Bool) else { return }
        send(selection,to:url,move:move)
    }
    /// Keeps the library as it is now, then reopens Folio on an earlier backup of it.
    func restoreBackup(_ snapshot: URL) {
        do {
            _ = try database.snapshot(before:"Restore")
            try LibraryDatabase.scheduleRestore(snapshot,root:database.root)
            relaunch()
        } catch { showError(error) }
    }
    /// Opens Folio again once this copy has quit, so the new one can take the browser connection.
    func relaunch() {
        let bundle = Bundle.main.bundleURL, pid = ProcessInfo.processInfo.processIdentifier
        let open = bundle.pathExtension == "app" ? "/usr/bin/open \"$1\"" : "\"$2\" &"
        let task = Process(); task.executableURL = URL(fileURLWithPath:"/bin/sh")
        task.arguments = ["-c","while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done; \(open)","folio",bundle.path,Bundle.main.executablePath ?? ""]
        do { try task.run(); NSApp.terminate(nil) } catch { showError(error) }
    }
}

/// Fills File ▸ Library each time it opens, so the list and the check mark are current.
@MainActor final class LibraryMenu: NSObject, NSMenuDelegate {
    static let shared = LibraryMenu()
    weak var app: AppController?
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let app else { return }
        menu.removeAllItems()
        let open = app.database.root.standardizedFileURL
        for url in app.libraries {
            let item = NSMenuItem(title:LibraryLocation.name(url),action:#selector(AppController.chooseLibrary(_:)),keyEquivalent:"")
            item.target = app; item.representedObject = url; item.state = url.standardizedFileURL == open ? .on : .off
            item.toolTip = (url.path as NSString).abbreviatingWithTildeInPath
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title,action) in [("New Library…",#selector(AppController.newLibraryPanel)),("Open Library…",#selector(AppController.openLibraryPanel)),
                               ("Show Library in Finder",#selector(AppController.revealLibrary))] {
            let item = NSMenuItem(title:title,action:action,keyEquivalent:""); item.target = app; menu.addItem(item)
        }
    }
}
