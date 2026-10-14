import AppKit
import ShelfCore

/// Brings in a library from another app (an Eagle library) or any folder of folders, as a collection named after it.
extension AppController {
    @objc func importLibraryPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false; panel.prompt = "Import"
        panel.message = "Choose an Eagle library or any folder. Its folders become collections inside one named after it."
        let tags = NSButton(checkboxWithTitle:"Keep tags",target:nil,action:nil), notes = NSButton(checkboxWithTitle:"Keep notes and source links",target:nil,action:nil)
        tags.state = .on; notes.state = .on
        let options = NSStackView(views:[tags,notes]); options.orientation = .vertical; options.alignment = .leading; options.spacing = 6
        options.edgeInsets = NSEdgeInsets(top:10,left:20,bottom:10,right:20)
        panel.accessoryView = options; panel.isAccessoryViewDisclosed = true
        panel.beginSheetModal(for:window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.importLibrary(at:url,tags:tags.state == .on,sources:notes.state == .on)
        }
    }
    func importLibrary(at url: URL, tags: Bool = true, sources: Bool = true) {
        guard (try? url.resourceValues(forKeys:[.isDirectoryKey]))?.isDirectory == true else { notify("Choose a library or a folder to import"); return }
        notify("Reading “\(url.deletingPathExtension().lastPathComponent)”…")
        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                let library = try LibraryImport.read(url)
                guard !library.items.isEmpty else { DispatchQueue.main.async { self.notify("No images or videos in “\(library.name)”") }; return }
                let total = library.items.count
                _ = try? self.database.snapshot(before:"Import " + library.name)
                let result = try self.database.importLibrary(library,tags:tags,sources:sources) { done in
                    DispatchQueue.main.async { if done < total { self.notify("Importing “\(library.name)”… \(done.formatted()) of \(total.formatted())") } }
                }
                DispatchQueue.main.async {
                    self.pendingScope = .collection(result.collection); self.reload()
                    let added = result.added == 1 ? "1 item" : "\(result.added.formatted()) items"
                    self.notify(result.updated == 0 ? "Imported \(added) from “\(library.name)”"
                                : result.added == 0 ? "“\(library.name)” is up to date" : "Added \(added) from “\(library.name)”; the rest were already here")
                }
            } catch { DispatchQueue.main.async { self.showError(error) } }
        }
    }
}
