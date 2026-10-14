import AppKit
import SwiftUI

/// Your own keyboard shortcuts for menu commands, Settings ▸ Shortcuts. Each is kept by "Menu/Title" and applied
/// to the menu item itself, so the menus, the command menu and Settings all show the same keys.
enum Shortcuts {
    struct Keys: Codable, Equatable { var key: String; var modifiers: UInt }
    /// Menus whose commands can be given keys; the app menu's Quit and Hide stay as the Mac has them.
    static let menus = ["File","Edit","Item","View","Window"]
    private(set) static var original: [String:Keys] = [:]
    static var overrides: [String:Keys] {
        get { (UserDefaults.standard.data(forKey:"shortcuts")).flatMap { try? JSONDecoder().decode([String:Keys].self,from:$0) } ?? [:] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue),forKey:"shortcuts") }
    }
    struct Command: Identifiable { let id: String; let menu: String; let title: String; var keys: Keys }
    static func commands() -> [Command] {
        guard let main = NSApp.mainMenu else { return [] }
        return main.items.filter { menus.contains($0.title) }.flatMap { section in
            (section.submenu?.items ?? []).filter { !$0.isSeparatorItem && !$0.isAlternate && $0.submenu == nil && $0.action != nil && !$0.title.isEmpty }.map {
                Command(id:section.title + "/" + $0.title,menu:section.title,title:$0.title,keys:Keys(key:$0.keyEquivalent,modifiers:$0.keyEquivalentModifierMask.rawValue))
            }
        }
    }
    /// Puts the saved keys on the menu items, remembering what each had first so Reset can bring it back.
    static func apply() {
        guard let main = NSApp.mainMenu else { return }
        let saved = overrides
        for section in main.items where menus.contains(section.title) {
            for item in section.submenu?.items ?? [] where !item.isSeparatorItem && !item.isAlternate && item.submenu == nil && !item.title.isEmpty {
                let id = section.title + "/" + item.title
                if original[id] == nil { original[id] = Keys(key:item.keyEquivalent,modifiers:item.keyEquivalentModifierMask.rawValue) }
                let keys = saved[id] ?? original[id]!
                item.keyEquivalent = keys.key; item.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue:keys.modifiers)
            }
        }
    }
    /// Gives a command new keys (empty for none). Any other command that had them gives them up; returns its title.
    @discardableResult static func set(_ id: String, _ keys: Keys?) -> String? {
        var saved = overrides, took: String?
        if let keys, !keys.key.isEmpty {
            for command in commands() where command.id != id && same(command.keys,keys) { saved[command.id] = Keys(key:"",modifiers:0); took = command.title }
        }
        saved[id] = keys
        overrides = saved; apply()
        return took
    }
    /// Keys the Mac keeps for itself (quit, hide, minimize, close, Settings, switching apps and windows, Spotlight).
    static func reserved(_ keys: Keys) -> Bool {
        let flags = NSEvent.ModifierFlags(rawValue:keys.modifiers).intersection([.command,.shift,.option,.control])
        let key = keys.key.lowercased()
        if flags == .command, ["q","h","m","w",",","`","\t"," "].contains(key) { return true }
        return flags == [.command,.option] && ["h","m","w","esc"].contains(key)
    }
    static func reset(_ id: String) { var saved = overrides; saved[id] = nil; overrides = saved; apply() }
    static func resetAll() { overrides = [:]; apply() }
    static func isChanged(_ id: String) -> Bool { overrides[id] != nil }
    static func same(_ a: Keys, _ b: Keys) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.command,.shift,.option,.control]
        return a.key.lowercased() == b.key.lowercased() && NSEvent.ModifierFlags(rawValue:a.modifiers).intersection(relevant) == NSEvent.ModifierFlags(rawValue:b.modifiers).intersection(relevant)
    }
    /// The keys a menu command has right now, for hints elsewhere (the command menu).
    static func current(_ id: String) -> String {
        commands().first { $0.id == id }.map { display($0.keys) } ?? ""
    }
    /// "⇧⌘K", as the Mac writes shortcuts.
    static func display(_ keys: Keys) -> String {
        guard !keys.key.isEmpty else { return "" }
        let flags = NSEvent.ModifierFlags(rawValue:keys.modifiers)
        var text = ""
        if flags.contains(.control) { text += "⌃" }; if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }; if flags.contains(.command) { text += "⌘" }
        let names: [String:String] = ["\u{8}":"⌫","\u{7F}":"⌫","\r":"↩","\u{1B}":"⎋"," ":"Space","\t":"⇥","\u{F700}":"↑","\u{F701}":"↓","\u{F702}":"←","\u{F703}":"→",
                                      "\u{F728}":"⌦","\u{F729}":"↖","\u{F72B}":"↘","\u{F72C}":"⇞","\u{F72D}":"⇟"]
        return text + (names[keys.key] ?? keys.key.uppercased())
    }
}

/// Settings ▸ Shortcuts: every command with its keys; click one and press new keys.
/// The single keys that act on the selection in the grid, on boards and in the viewer: each has a default letter
/// and can take another (Settings ▸ Shortcuts). They never fire while typing in a field.
enum SingleKeys {
    static let actions: [(id: String, title: String, key: String)] = [
        ("tags","Add Tags","t"),("collect","Add to Collection","c"),("move","Move to Collection","m"),("note","Edit Note","n"),
        ("author","Edit Author","a"),("source","Edit Source","u"),("like","Like","l"),("similar","Find Similar","s"),
        ("details","Show Details","i"),("shuffle","Shuffle","r")]
    static let changed = Notification.Name("org.lumashelf.single-keys")
    private static var overrides: [String:String] {
        get { UserDefaults.standard.dictionary(forKey:"singleKeys") as? [String:String] ?? [:] }
        set { UserDefaults.standard.set(newValue,forKey:"singleKeys"); NotificationCenter.default.post(name:changed,object:nil) }
    }
    static func key(_ id: String) -> String { overrides[id] ?? actions.first { $0.id == id }?.key ?? "" }
    static func action(for key: String) -> String? { actions.first { self.key($0.id) == key }?.id }
    static var isChanged: Bool { !overrides.isEmpty }
    /// Gives an action a key; an action that had it swaps to this one's old key. Returns that action's title.
    @discardableResult static func set(_ id: String, _ key: String) -> String? {
        var saved = overrides
        let other = actions.first { $0.id != id && self.key($0.id) == key }
        if let other { saved[other.id] = self.key(id) }
        saved[id] = key
        // Keys back on their defaults aren't overrides.
        for action in actions where saved[action.id] == action.key { saved[action.id] = nil }
        overrides = saved
        return other?.title
    }
    static func resetAll() { overrides = [:] }
}

struct ShortcutsSettingsPane: View {
    @State private var commands = Shortcuts.commands()
    @State private var recording: String?
    @State private var monitor: Any?
    @State private var query = ""
    @State private var notice = ""
    @State private var singleKeys = SingleKeys.actions.map { SingleKeys.key($0.id) }
    @State private var recordingSingle: String?

    var body: some View {
        SettingsPage(title: "Shortcuts", subtitle: "Give any menu command the keys you like. Click a shortcut, then press the new keys; Delete clears it and Esc keeps it.") {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a command", text: $query).textFieldStyle(.plain)
                if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            ForEach(Shortcuts.menus, id: \.self) { menu in
                let rows = commands.filter { $0.menu == menu && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || Shortcuts.display($0.keys).localizedCaseInsensitiveContains(query)) }
                if !rows.isEmpty {
                    SettingsCard(menu, systemImage: symbol(menu)) {
                        VStack(spacing: 0) {
                            ForEach(rows) { command in
                                HStack {
                                    Text(command.title)
                                    Spacer()
                                    if Shortcuts.isChanged(command.id) {
                                        Button("Reset") { Shortcuts.reset(command.id); refresh() }.buttonStyle(.link).font(.caption)
                                    }
                                    Button { start(command.id) } label: {
                                        Text(recording == command.id ? "Type keys…" : Shortcuts.display(command.keys).isEmpty ? "None" : Shortcuts.display(command.keys))
                                            .font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
                                            .foregroundStyle(Shortcuts.display(command.keys).isEmpty && recording != command.id ? .secondary : .primary)
                                            .frame(minWidth: 72).padding(.vertical, 3).padding(.horizontal, 8)
                                            .background(RoundedRectangle(cornerRadius: 6).fill(recording == command.id ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
                                    }
                                    .buttonStyle(.plain).accessibilityLabel("Shortcut for \(command.title)")
                                }
                                .padding(.vertical, 5)
                                if command.id != rows.last?.id { Divider() }
                            }
                        }
                    }
                }
            }
            let singles = SingleKeys.actions.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
            if !singles.isEmpty {
                SettingsCard("With Items Selected", systemImage: "character.cursor.ibeam") {
                    VStack(spacing: 0) {
                        ForEach(singles, id: \.id) { action in
                            HStack {
                                Text(action.title)
                                Spacer()
                                Button { startSingle(action.id) } label: {
                                    Text(recordingSingle == action.id ? "Type a letter…" : SingleKeys.key(action.id).uppercased())
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .frame(minWidth: 72).padding(.vertical, 3).padding(.horizontal, 8)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(recordingSingle == action.id ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
                                }
                                .buttonStyle(.plain).accessibilityLabel("Key for \(action.title)")
                            }
                            .padding(.vertical, 5)
                            if action.id != singles.last?.id { Divider() }
                        }
                        Text("One letter, pressed with nothing else held, while the grid, a board or the viewer is in front.")
                            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                    }
                    .id(singleKeys)
                }
            }
            HStack {
                Spacer()
                Button("Reset All Shortcuts") { Shortcuts.resetAll(); SingleKeys.resetAll(); refresh() }.disabled(Shortcuts.overrides.isEmpty && !SingleKeys.isChanged)
            }
        }
        .onDisappear { stop() }
    }
    private func symbol(_ menu: String) -> String {
        ["File":"doc","Edit":"pencil","Item":"photo","View":"eye","Window":"macwindow"][menu] ?? "command"
    }
    private func refresh() { commands = Shortcuts.commands(); singleKeys = SingleKeys.actions.map { SingleKeys.key($0.id) } }
    /// Records one plain letter for a single-key action. Z stays the viewer's zoom.
    private func startSingle(_ id: String) {
        stop(); recordingSingle = id
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let current = recordingSingle else { return event }
            if event.keyCode == 53 { stop(); return nil }
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            guard event.modifierFlags.intersection([.command,.control,.option]).isEmpty, key.count == 1, key.first!.isLetter, key != "z" else {
                NSSound.beep(); notice = "Choose a letter other than Z"; return nil
            }
            let previous = SingleKeys.key(current)
            notice = SingleKeys.set(current, key).map { "\($0) now uses \(previous.uppercased())" } ?? ""
            stop(); refresh(); return nil
        }
    }
    private func start(_ id: String) {
        stop(); recording = id
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let current = recording else { return event }
            let flags = event.modifierFlags.intersection([.command,.shift,.option,.control])
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if event.keyCode == 53 { stop(); return nil }
            if flags.isEmpty, event.keyCode == 51 || event.keyCode == 117 { Shortcuts.set(current, Shortcuts.Keys(key: "", modifiers: 0)); stop(); refresh(); return nil }
            // A shortcut needs ⌘, ⌃ or ⌥, so typing in fields never fires it.
            guard !flags.intersection([.command,.control,.option]).isEmpty, !key.isEmpty else { NSSound.beep(); return nil }
            let keys = Shortcuts.Keys(key: event.keyCode == 51 ? "\u{8}" : key, modifiers: flags.rawValue)
            if Shortcuts.reserved(keys) { NSSound.beep(); notice = "\(Shortcuts.display(keys)) belongs to macOS"; return nil }
            let took = Shortcuts.set(current, keys)
            notice = took.map { "\(Shortcuts.display(keys)) moved here from \($0)" } ?? ""
            stop(); refresh(); return nil
        }
    }
    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; recording = nil; recordingSingle = nil
    }
}
