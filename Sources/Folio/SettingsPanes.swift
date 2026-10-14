import SwiftUI
import SafariServices
import AppKit
import ShelfCore

extension AppIdentity {
    static let repository = URL(string:"https://github.com/zlichtman/Folio")!
    static let license = URL(string:"https://github.com/zlichtman/Folio/blob/main/LICENSE")!
    static let copyright = Bundle.main.object(forInfoDictionaryKey:"NSHumanReadableCopyright") as? String ?? "© 2026 Zach Lichtman and contributors"
}

/// The library window Settings reads from and acts on.
@MainActor enum SettingsContext {
    static weak var app: AppController?
}

@MainActor
extension AppController {
    func openSettings(_ destination: SettingsDestination? = nil) {
        SettingsContext.app = self
        SettingsWindowController.shared.show(destination)
        // Development check: --settings-search <text> opens Settings with a search typed in.
        if let query = argument("--settings-search") { SettingsNavigationModel.shared.searchQuery = query }
        // And --settings-card <title> scrolls to one card of the pane, as a search result does.
        if let card = argument("--settings-card") { SettingsNavigationModel.shared.open(destination ?? .general,card:card) }
    }
    @objc func showSettings() { openSettings() }
    @objc func showAbout() { openSettings(.about) }
    @objc func checkForUpdates() { openSettings(.updates); UpdateService.shared.check() }
    var keepsRunning: Bool { UserDefaults.standard.bool(forKey:"general.keepRunning") }
}

struct GeneralSettingsPane: View {
    @AppStorage("general.keepRunning") private var keepRunning = false
    @AppStorage("general.menuBar") private var menuBar = false
    @AppStorage("general.dockIcon") private var dockIcon = true
    @AppStorage("videoHover") private var videoHover = "play"
    @AppStorage("videoHoverSound") private var videoSound = false
    @AppStorage("gifsAlwaysPlay") private var gifsAlwaysPlay = false
    @AppStorage("viewerHidesSidebar") private var viewerHidesSidebar = false
    @AppStorage("linkLook") private var linkLook = "preview"
    @AppStorage("linkChip") private var linkChip = "site"
    @State private var backups: [URL] = []
    @State private var chosenBackup: URL?
    @State private var confirmRestore = false

    var body: some View {
        SettingsPage(title: "General", subtitle: "Choose what happens when you close Folio's window, where Folio shows up, and see where your library is kept.") {
            SettingsCard("Window", systemImage: "macwindow") {
                Toggle("Keep Folio open when its window is closed", isOn: $keepRunning)
                Text("Browser extensions can still save to your library. Click Folio in the Dock or the menu bar to bring the window back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SettingsCard("Menu bar and Dock", systemImage: "menubar.dock.rectangle") {
                Toggle("Show Folio in the menu bar", isOn: Binding(get: { menuBar || !dockIcon }, set: { menuBar = $0 }))
                    .disabled(!dockIcon)
                Toggle("Show Dock icon", isOn: $dockIcon)
                Text(dockIcon ? "The menu bar pin opens Folio, pastes into it and adds files from anywhere."
                              : "Folio lives in the menu bar. Choose Show Dock Icon there to bring the icon back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: menuBar) { MenuBarPin.shared.update() }
            .onChange(of: dockIcon) { MenuBarPin.shared.update() }
            SettingsCard("Viewer", systemImage: "photo") {
                Toggle("Hide the sidebar while viewing a picture", isOn: $viewerHidesSidebar)
                Text("The picture gets the whole window; the sidebar comes back when you return to the grid.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SettingsCard("Links", systemImage: "link") {
                Picker("New links show as", selection: $linkLook) {
                    Text("Preview image").tag("preview"); Text("Page snapshot").tag("snapshot"); Text("Title card").tag("title")
                }
                Text(linkLook == "preview" ? "The picture the page offers for sharing, or a snapshot of the page when it has none."
                     : linkLook == "snapshot" ? "A picture of the page itself, as it looks in a browser."
                     : "The page's title on a plain card, with no picture.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Right-click any link and choose Show Link As to change just that one.").font(.caption).foregroundStyle(.secondary)
                Picker("Label on a link's picture", selection: $linkChip) {
                    Text("Site name").tag("site"); Text("Page title").tag("title"); Text("None").tag("none")
                }
                .onChange(of: linkChip) { NotificationCenter.default.post(name: ShelfGridView.shapeChanged, object: nil) }
            }
            SettingsCard("Videos", systemImage: "play.rectangle") {
                Picker("When the pointer rests on a video or GIF", selection: $videoHover) {
                    Text("Play it").tag("play"); Text("Scrub through it").tag("scrub")
                }
                Toggle("Play sound", isOn: $videoSound).disabled(videoHover != "play")
                Toggle("Keep GIFs playing", isOn: $gifsAlwaysPlay)
                    .onChange(of: gifsAlwaysPlay) { NotificationCenter.default.post(name: ShelfGridView.shapeChanged, object: nil) }
                Text(videoHover == "play" ? "Videos and GIFs play in the grid while the pointer rests on them, from the start and on a loop."
                                          : "Move the pointer across a video or GIF to see it from start to end.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SettingsCard("Library", systemImage: "folder") {
                if let root = SettingsContext.app?.database?.root {
                    HStack(spacing: 12) {
                        Text((root.path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 13)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                    }
                }
                Text("Your library, previews and browser connection key are kept here. Original files stay in their own folders.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            CollectionsCard()
            SettingsCard("Backups", systemImage: "clock.arrow.circlepath") {
                if backups.isEmpty {
                    Text("Folio keeps a copy of your library each day and before anything that can't be undone.").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 12) {
                        Picker("Backup", selection: $chosenBackup) {
                            ForEach(backups, id: \.self) { Text(Self.describe($0)).tag(Optional($0)) }
                        }
                        Button("Restore…") { confirmRestore = true }.disabled(chosenBackup == nil)
                    }
                    Text("A copy is kept each day and before emptying the Trash, deleting for good or importing. Restoring keeps the library as it is now as a backup too, and Folio reopens.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onAppear { backups = SettingsContext.app?.database?.snapshots() ?? []; chosenBackup = backups.first }
            .confirmationDialog("Restore the library from \(chosenBackup.map(Self.describe) ?? "this backup")?", isPresented: $confirmRestore) {
                Button("Restore and Reopen") { if let chosenBackup { SettingsContext.app?.restoreBackup(chosenBackup) } }
            } message: { Text("Tags, notes, collections and boards go back to how they were then. Your files are not touched.") }
        }
    }
}

extension GeneralSettingsPane {
    /// "Today at 9:12 · Before emptying the Trash", from a snapshot's name.
    static func describe(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator:"-")
        var when = ""
        if parts.count >= 3 {
            let parse = DateFormatter(); parse.locale = Locale(identifier:"en_US_POSIX"); parse.dateFormat = "yyyyMMddHHmmss"
            if let date = parse.date(from:String(parts[1]) + String(parts[2])) {
                let day = Calendar.current.isDateInToday(date) ? "Today" : Calendar.current.isDateInYesterday(date) ? "Yesterday" : date.formatted(date:.abbreviated,time:.omitted)
                when = day + " at " + date.formatted(date:.omitted,time:.shortened)
            }
        }
        let reason: String
        if let range = name.range(of:"-before-") {
            let what = name[range.upperBound...].replacingOccurrences(of:"-",with:" ")
            reason = what == "empty trash" ? "Before emptying the Trash" : what == "delete immediately" ? "Before deleting for good"
                : what == "restore" ? "Before restoring a backup" : what.hasPrefix("import") ? "Before an import" : "Before " + what
        } else { reason = "Daily backup" }
        return when.isEmpty ? reason : when + " · " + reason
    }
}

struct AppearanceSettingsPane: View {
    @AppStorage("selectionColor") private var selection = "accent"
    @AppStorage("gridSpacing") private var spacing = "standard"
    @AppStorage("gridCorners") private var corners = "soft"
    @AppStorage("commandScrollZooms") private var commandScrollZooms = true
    @AppStorage("reduceMotion") private var reduceMotion = false
    private let choices: [(id: String, name: String)] = [("accent","Accent"),("graphite","Graphite"),("lightGrey","Light grey"),("ink","Ink")]

    var body: some View {
        SettingsPage(title: "Appearance", subtitle: "Choose a theme for Folio's library and Settings, and how selected items are marked.") {
            FolioThemePicker()
            SettingsCard("Selection", systemImage: "checkmark.rectangle") {
                HStack(spacing: 18) {
                    ForEach(choices, id: \.id) { choice in
                        Button { selection = choice.id } label: {
                            VStack(spacing: 6) {
                                Circle().fill(Color(nsColor: swatch(choice.id))).frame(width: 22, height: 22)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(selection == choice.id ? 0.9 : 0.12), lineWidth: selection == choice.id ? 2 : 1).padding(-4))
                                Text(choice.name).font(.caption).foregroundStyle(selection == choice.id ? .primary : .secondary)
                            }
                        }
                        .buttonStyle(.plain).accessibilityLabel(choice.name).accessibilityAddTraits(selection == choice.id ? .isSelected : [])
                    }
                }
                Text("The ring around selected items in the grid and on boards. Accent follows the colour chosen in System Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: selection) { NotificationCenter.default.post(name: Theme.selectionChanged, object: nil) }
            SettingsCard("Grid", systemImage: "square.grid.3x3") {
                Picker("Spacing", selection: $spacing) { Text("Tight").tag("tight"); Text("Standard").tag("standard"); Text("Airy").tag("airy") }
                    .pickerStyle(.segmented)
                Picker("Corners", selection: $corners) { Text("Square").tag("square"); Text("Soft").tag("soft"); Text("Round").tag("round") }
                    .pickerStyle(.segmented)
                Text("How far apart pictures sit in the grid, and how round their corners are.").font(.caption).foregroundStyle(.secondary)
                Toggle("Zoom with ⌘ and scrolling", isOn: $commandScrollZooms)
                Text("Holding ⌘ while scrolling makes pictures bigger or smaller, in the grid, on boards and in Infinity. Pinching always zooms.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: spacing) { NotificationCenter.default.post(name: ShelfGridView.shapeChanged, object: nil) }
            .onChange(of: corners) { NotificationCenter.default.post(name: ShelfGridView.shapeChanged, object: nil) }
            SettingsCard("Motion", systemImage: "figure.walk.motion") {
                Toggle("Reduce motion in Folio", isOn: $reduceMotion)
                Text("Panels appear without sliding, and pictures don't lift or spring. The Mac's own Reduce Motion (in Accessibility ▸ Display) does this for every app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func swatch(_ id: String) -> NSColor { Theme.selection(id, appearance: NSApp.effectiveAppearance) }
}

struct TaggingSettingsPane: View {
    @AppStorage("automaticTagging") private var automaticTagging = true
    @AppStorage("semanticSearch") private var semanticSearch = true
    @AppStorage("describePictures") private var describePictures = true
    @State private var reanalyzing = false

    var body: some View {
        SettingsPage(title: "Tagging", subtitle: "Folio finds objects, colours and text in your images with Apple's built-in analysis. Nothing is uploaded.") {
            SettingsCard("Automatic tagging", systemImage: "tag") {
                Toggle("Tag new images automatically", isOn: Binding(get: { automaticTagging }, set: { on in
                    automaticTagging = on; SettingsContext.app?.setAutomaticTagging(on)
                }))
                Text("New and changed images are tagged in the background while you work.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SettingsCard("Search by meaning", systemImage: "text.magnifyingglass") {
                Toggle("Include related images in search results", isOn: $semanticSearch)
                Text("Searching “dogs on the beach” also finds images tagged dog and beach, after the exact matches, worked out on your Mac.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if PictureDescriber.isAvailable {
                    Divider()
                    Toggle("Describe pictures with Apple Intelligence", isOn: Binding(get: { describePictures }, set: { on in
                        describePictures = on; if on { SettingsContext.app?.scheduleClassification() }
                    }))
                    Text("Your Mac looks at each picture and notes what's in it, so searching “a calm blue pattern” or “people at a table” finds it without tags. It happens on your Mac, in the background; the details panel shows what it saw.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            SettingsCard("Re-analyze library", systemImage: "arrow.triangle.2.circlepath") {
                HStack(spacing: 12) {
                    Text(reanalyzing ? "Re-analyzing in the background. Progress shows at the bottom of the library sidebar."
                                     : "Analyzes every image again. Tags you added yourself are kept.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Re-analyze Library") { SettingsContext.app?.tagAllImages(); reanalyzing = true }
                        .disabled(SettingsContext.app == nil)
                }
            }
        }
    }
}

/// The `folio` command and the MCP server, both the helper inside the app.
struct DevelopersSettingsPane: View {
    @State private var installed = DevelopersSettingsPane.installedPath
    @State private var message = ""
    @State private var copied = ""
    static var helper: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/folio").path }
    static let links = ["/usr/local/bin/folio",NSString(string:"~/.local/bin/folio").expandingTildeInPath]
    static var installedPath: String? {
        links.first { (try? FileManager.default.destinationOfSymbolicLink(atPath:$0)) == helper }
    }
    var claudeCommand: String { "claude mcp add folio -- \"\(Self.helper)\" mcp" }
    var desktopConfig: String { "\"folio\": { \"command\": \"\(Self.helper)\", \"args\": [\"mcp\"] }" }

    var body: some View {
        SettingsPage(title: "Developers", subtitle: "Use your library from Terminal and scripts, or let an assistant search and organise it.") {
            SettingsCard("Terminal command", systemImage: "terminal") {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(installed.map { "Installed at \($0)" } ?? "folio search, add, tag, collect, similar and open")
                            .font(.system(size: 13, weight: .medium))
                        Text(message.isEmpty ? "Run folio help to see every command." : message).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(installed == nil ? "Install Command" : "Reinstall") { install() }
                        .disabled(!FileManager.default.isExecutableFile(atPath: Self.helper))
                }
            }
            SettingsCard("Assistants", systemImage: "sparkles") {
                Text("Folio includes an MCP server, so an assistant like Claude can search your library, read what's in an image, tag items and file them in collections. It runs on this Mac and never deletes anything.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                row("Claude Code", claudeCommand)
                row("Claude Desktop and others (mcpServers)", desktopConfig)
            }
        }
    }
    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(value).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
            }
            Spacer()
            Button(copied == title ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string); copied = title
                Task { try? await Task.sleep(for: .seconds(2)); if copied == title { copied = "" } }
            }
        }
    }
    /// Links the helper into /usr/local/bin when that's writable, otherwise ~/.local/bin.
    private func install() {
        for link in Self.links {
            let folder = (link as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            guard FileManager.default.isWritableFile(atPath: folder) else { continue }
            try? FileManager.default.removeItem(atPath: link)
            if (try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: Self.helper)) != nil {
                installed = link
                let onPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains { String($0) == folder }
                message = onPath || folder == "/usr/local/bin" ? "Open a new Terminal window and run folio help." : "Add \(folder) to your PATH, then run folio help."
                return
            }
        }
        message = "Couldn't install the command. Link \(Self.helper) into a folder on your PATH."
    }
}

struct ExtensionsSettingsPane: View {
    private enum Connection { case checking, ready, off, failed }
    @State private var connection = Connection.checking
    @State private var copied = false
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        SettingsPage(title: "Extensions", subtitle: "Save images, videos and pages to Folio from Safari, Firefox or Chrome with the Save to Folio extension.") {
            SettingsCard("Browser connection", systemImage: "network") {
                HStack(spacing: 8) {
                    Circle().fill(connection == .ready ? Color.green : Color.secondary).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 13, weight: .medium))
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    RefreshButton("Refresh") { Task { await probe() } }
                        .buttonStyle(.borderless)
                }
            }
            SettingsCard("Connection key", systemImage: "key") {
                HStack(spacing: 12) {
                    Text("Paste it into the extension's settings to connect your browser. The key keeps web pages and other apps out.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(copied ? "Copied" : "Copy Connection Key") {
                        SettingsContext.app?.copyKey(); copied = true
                        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                    }
                    .disabled(SettingsContext.app?.server == nil)
                }
            }
            SettingsCard("Install the extension", systemImage: "puzzlepiece.extension") {
                Text("Save to Folio talks only to Folio on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                SettingsRow(title: "Safari", detail: "Comes with Folio. Turn on Save to Folio in Safari ▸ Settings ▸ Extensions, then allow it on 127.0.0.1.", symbol: "safari") {
                    Button("Open Safari Extensions") {
                        SFSafariApplication.showPreferencesForExtension(withIdentifier: "org.lumashelf.app.safari-extension") { _ in }
                    }
                }
                extensionRow("Firefox", file: "folio-firefox.zip", symbol: "flame",
                             detail: "In Firefox, open about:debugging ▸ This Firefox ▸ Load Temporary Add-on, then choose folio-firefox.zip.")
                extensionRow("Chrome", file: "folio-chrome.zip", symbol: "globe",
                             detail: "Unzip folio-chrome.zip. In chrome://extensions, turn on Developer mode, click Load unpacked and choose the folder.")
            }
        }
        .task { await probe() }
    }

    private var title: String {
        switch connection { case .checking: "Checking…"; case .ready: "Ready"; case .off: "Off"; case .failed: "Not connected" }
    }
    private var detail: String {
        switch connection {
        case .checking: "Looking for Folio's browser connection on this Mac."
        case .ready: "Folio is listening for the extension on this Mac."
        case .off: "Saving from the browser is turned off for this session."
        case .failed: "Another copy of Folio or another app may be using the connection. Quit it, then reopen Folio."
        }
    }

    private func extensionRow(_ browser: String, file: String, symbol: String, detail: String) -> some View {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Extensions/" + file)
        let exists = bundled.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        return SettingsRow(title: browser, detail: detail, symbol: symbol) {
            if let bundled, exists {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([bundled]) }
            } else {
                Link(destination: UpdateService.releasesPage) { Label("Get on GitHub", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(.borderless).foregroundStyle(theme.notch.accent)
            }
        }
    }

    private func probe() async {
        guard !CommandLine.arguments.contains("--no-capture"), let server = SettingsContext.app?.server else { connection = .off; return }
        connection = .checking
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/health")!, timeoutInterval: 2)
        request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        let ok = (try? await URLSession.shared.data(for: request)).map { ($0.1 as? HTTPURLResponse)?.statusCode == 200 } ?? false
        connection = ok ? .ready : .failed
    }
}

struct UpdatesSettingsPane: View {
    @ObservedObject private var updater = UpdateService.shared
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        SettingsPage(title: "Updates", subtitle: "Folio checks GitHub for new versions and always asks before it restarts to install.") {
            SettingsCard("Updates", systemImage: "arrow.triangle.2.circlepath") {
                HStack(spacing: 12) {
                    FolioMark(size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Folio \(AppIdentity.version)").font(.system(size: 14, weight: .semibold))
                        Text(updater.status == .idle ? "Stable release" : updater.status.label)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if updater.isBusy { ProgressView().controlSize(.small) }
                    Button(updater.actionLabel) { updater.performPrimaryAction() }
                        .buttonStyle(.bordered).disabled(updater.isBusy)
                }
                Divider()
                Toggle("Check automatically", isOn: $updater.automaticallyCheckForUpdates)
                if updater.automaticallyCheckForUpdates {
                    Toggle("Download updates when available", isOn: $updater.automaticallyInstallUpdates)
                }
                Text("Last checked: " + (updater.lastCheck.map { $0.formatted(.relative(presentation: .named)) } ?? "Never"))
                    .font(.caption).foregroundStyle(.secondary)
                Text("Updates come from GitHub and are signature-verified. Folio asks before restarting to install.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SettingsCard("Release notes", systemImage: "doc.text") {
                if !updater.releaseNotes.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(updater.releaseNotes.enumerated()), id: \.offset) { _, section in
                            VStack(alignment: .leading, spacing: 4) {
                                if !section.title.isEmpty { Text(section.title).font(.system(size: 12, weight: .semibold)) }
                                ForEach(section.points, id: \.self) { point in
                                    HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•").foregroundStyle(.secondary); Text(point).fixedSize(horizontal: false, vertical: true) }
                                        .font(.system(size: 12))
                                }
                            }
                        }
                    }
                    Divider()
                }
                SettingsRow(title: updater.releasePage == nil ? "What's new" : "What's new in \(updater.status.version ?? "this update")",
                            detail: "Every Folio release and its notes are on GitHub.", symbol: "sparkles") {
                    Link(destination: updater.releasePage ?? UpdateService.releasesPage) {
                        Label(updater.releasePage == nil ? "All Releases" : "Release Notes", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderless).foregroundStyle(theme.notch.accent)
                }
            }
        }
    }
}

extension UpdateService.Status {
    var version: String? {
        switch self { case .available(let v), .downloading(let v), .installing(let v): v; default: nil }
    }
}

struct AboutSettingsPane: View {
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        SettingsPage(title: "About", subtitle: "A fast, private visual library for your Mac.") {
            SettingsCard("Folio", systemImage: "info.circle") {
                HStack(spacing: 14) {
                    FolioMark(size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Folio").font(.system(size: 20, weight: .bold))
                        Text("Version \(AppIdentity.version)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                }
                Text("Your images stay in their folders, and tagging and search run on this Mac.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Divider()
                link("License", "MIT License", AppIdentity.license, symbol: "doc.plaintext")
                link("Source code", "github.com/zlichtman/Folio", AppIdentity.repository, symbol: "chevron.left.forwardslash.chevron.right")
                link("Release notes", "All releases", UpdateService.releasesPage, symbol: "sparkles")
                Text(AppIdentity.copyright + ". Folio is free and open source.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func link(_ title: String, _ label: String, _ url: URL, symbol: String) -> some View {
        SettingsRow(title: title, detail: label, symbol: symbol) {
            Link(destination: url) { Label("Open", systemImage: "arrow.up.forward.app") }
                .buttonStyle(.borderless).foregroundStyle(theme.notch.accent)
        }
    }
}

/// Every collection and smart folder in one list, with how many items each holds, to tidy up several at once:
/// archive, bring back or delete. Each change can be undone in the library window.
struct CollectionsCard: View {
    struct Row: Identifiable, Hashable { let id: String; let name: String; let count: Int; let smart: Bool; let archived: Bool }
    @State private var rows: [Row] = []
    @State private var chosen = Set<String>()
    @State private var order = "name"
    @State private var confirmDelete = false

    var body: some View {
        SettingsCard("Collections", systemImage: "rectangle.stack") {
            if rows.isEmpty {
                Text("Collections and smart folders you make are listed here.").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Picker("Order", selection: $order) { Text("Name").tag("name"); Text("Size").tag("size") }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    Text("\(rows.count) in all").font(.caption).foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    let shown = sorted
                    ForEach(shown) { row in
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(get: { chosen.contains(row.id) }, set: { if $0 { chosen.insert(row.id) } else { chosen.remove(row.id) } }))
                                .labelsHidden().toggleStyle(.checkbox)
                            Image(systemName: row.archived ? "archivebox" : row.smart ? AppController.smartSymbol(row.name) : "rectangle.stack")
                                .foregroundStyle(.secondary).frame(width: 18)
                            Text(row.name).lineLimit(1).truncationMode(.tail)
                            if row.archived { Text("Archived").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text(row.count == 1 ? "1 item" : "\(row.count.formatted()) items").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(.vertical, 5)
                        if row.id != shown.last?.id { Divider() }
                    }
                }
                HStack {
                    Text(chosen.isEmpty ? "Tick collections to change several at once." : "\(chosen.count) chosen").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Archive") { change("Archive Collections") { db, id in try db.setArchived(id,true) } }
                        .disabled(!rows.contains { chosen.contains($0.id) && !$0.archived })
                    Button("Unarchive") { change("Unarchive Collections") { db, id in try db.setArchived(id,false) } }
                        .disabled(!rows.contains { chosen.contains($0.id) && $0.archived })
                    Button("Delete…") { confirmDelete = true }.disabled(chosen.isEmpty)
                }
            }
        }
        .onAppear(perform: load)
        .confirmationDialog("Delete \(chosen.count == 1 ? "this collection" : "\(chosen.count) collections")?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { change("Delete Collections") { db, id in try db.deleteCollection(id) } }
        } message: { Text("Their items stay in your library. You can undo this in the library window.") }
    }
    private var sorted: [Row] {
        order == "size" ? rows.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                        : rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private func load() {
        guard let tree = try? SettingsContext.app?.database?.collectionTree() else { rows = []; return }
        var out: [Row] = []
        func walk(_ nodes: [CollectionNode]) {
            for node in nodes {
                out.append(Row(id: node.id, name: node.collection.name, count: node.count, smart: node.collection.isSmart, archived: node.collection.archived))
                walk(node.children)
            }
        }
        walk(tree)
        rows = out; chosen = chosen.intersection(out.map(\.id))
    }
    /// One undoable change for every chosen collection, then the list reads the library again.
    private func change(_ name: String, _ work: @escaping (LibraryDatabase, String) throws -> CollectionArchive) {
        let ids = Array(chosen)
        SettingsContext.app?.performMany(name,ids,work) { load() }
        if name == "Delete Collections" { chosen = [] }
    }
}
