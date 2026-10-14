import Foundation

// Ported from MacSpaces' Settings/SettingsSearch.swift (same author, MIT).

enum SettingsDestination: String, CaseIterable, Identifiable {
    case general, appearance, shortcuts, tagging, extensions, developers, updates, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .shortcuts: return "Shortcuts"
        case .tagging: return "Tagging"
        case .extensions: return "Extensions"
        case .developers: return "Developers"
        case .updates: return "Updates"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .shortcuts: return "keyboard"
        case .tagging: return "tag"
        case .extensions: return "puzzlepiece.extension"
        case .developers: return "terminal"
        case .updates: return "arrow.triangle.2.circlepath"
        case .about: return "info.circle"
        }
    }
}

struct SettingsSearchEntry: Identifiable {
    let destination: SettingsDestination
    let card: String
    let keywords: String
    var id: String { destination.rawValue + "." + card }
}

enum SettingsSearch {
    static let entries: [SettingsSearchEntry] = [
        .init(destination: .general, card: "Window", keywords: "keep running open close window quit dock background menu"),
        .init(destination: .general, card: "Menu bar and Dock", keywords: "menu bar status item pin dock icon hide accessory tray"),
        .init(destination: .general, card: "Viewer", keywords: "viewer full size sidebar hide room picture open expand"),
        .init(destination: .general, card: "Links", keywords: "link links bookmark url preview snapshot page title card web"),
        .init(destination: .general, card: "Videos", keywords: "video hover play scrub sound audio mute loop preview"),
        .init(destination: .general, card: "Collections", keywords: "collections smart folders archive unarchive delete tidy manage size list bulk"),
        .init(destination: .general, card: "Backups", keywords: "backup backups restore snapshot undo recover history copy earlier version"),
        .init(destination: .general, card: "Library", keywords: "library location folder storage database previews show in finder application support"),
        .init(destination: .appearance, card: "Theme", keywords: "themes appearance light dark system colors colours custom background accent folio everforest nord solarized gruvbox tokyo night catppuccin monokai rose pine ayu noir terminal core bloom forest earth water sky tech"),
        .init(destination: .shortcuts, card: "Shortcuts", keywords: "keyboard shortcuts keys hotkeys commands customize change menu key equivalent single letter tag like note author source similar shuffle"),
        .init(destination: .appearance, card: "Motion", keywords: "motion reduce animation accessibility slide lift spring calm still"),
        .init(destination: .appearance, card: "Grid", keywords: "grid spacing gap gutter tight airy corners radius rounded square soft tiles zoom scroll command pinch size"),
        .init(destination: .appearance, card: "Selection", keywords: "selection color colour ring highlight accent graphite grey gray light ink"),
        .init(destination: .tagging, card: "Automatic tagging", keywords: "auto tag tags automatically analyze analysis vision objects colors colours text ocr background private"),
        .init(destination: .developers, card: "Terminal command", keywords: "cli command line terminal shell script folio search add tag install"),
        .init(destination: .developers, card: "Assistants", keywords: "mcp claude assistant ai model context protocol server tools connect"),
        .init(destination: .tagging, card: "Search by meaning", keywords: "semantic search meaning related natural language describe find similar words describe description apple intelligence sees picture vision"),
        .init(destination: .tagging, card: "Re-analyze library", keywords: "reanalyze re-analyze rescan analyze again refresh tags library"),
        .init(destination: .extensions, card: "Browser connection", keywords: "capture service status ready connected browser save extension port"),
        .init(destination: .extensions, card: "Connection key", keywords: "copy connection key pair paste extension token password"),
        .init(destination: .extensions, card: "Install the extension", keywords: "install safari firefox chrome browser extension add-on zip save to folio"),
        .init(destination: .updates, card: "Updates", keywords: "version software update check now install download automatically last checked"),
        .init(destination: .updates, card: "Release notes", keywords: "release notes what's new whats new changes github"),
        .init(destination: .about, card: "Folio", keywords: "about version build license mit source code github copyright"),
    ]

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    static func matches(_ query: String) -> [SettingsSearchEntry] {
        let words = normalized(query).split(separator: " ")
        guard !words.isEmpty else { return [] }
        return entries.filter { entry in
            let text = normalized(entry.destination.title + " " + entry.card + " " + entry.keywords)
            return words.allSatisfy { text.contains($0) }
        }.sorted {
            let a = normalized($0.card).hasPrefix(normalized(query)), b = normalized($1.card).hasPrefix(normalized(query))
            if a != b { return a }
            if $0.destination != $1.destination { return SettingsDestination.allCases.firstIndex(of: $0.destination)! < SettingsDestination.allCases.firstIndex(of: $1.destination)! }
            return $0.card.localizedStandardCompare($1.card) == .orderedAscending
        }
    }
}
