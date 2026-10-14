import SwiftUI
import AppKit

// Ported from MacSpaces' DesignSystem/ThemeStore.swift (same author, MIT).

struct ThemeTokens {
    let surface: Color
    let tile: Color
    let selected: Color
    let border: Color
    let accent: Color
    let colorScheme: ColorScheme
}

/// The chosen theme family and System/Light/Dark. Settings and the library window both
/// follow it: SwiftUI reads `notch`, AppKit reads the `Theme` colours.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    @Published var family: ThemeFamily {
        didSet { if persistsMode { defaults.set(family.rawValue, forKey: Keys.family) }; apply() }
    }
    /// Shares the "appearance" preference with View ▸ Appearance.
    @Published var appearanceMode: AppearanceMode {
        didSet { if persistsMode { defaults.set(appearanceMode.rawValue, forKey: Keys.appearanceMode) }; apply() }
    }
    /// Custom theme colours, stored as hex.
    @Published var customThemeBackground: String = CustomThemeColors.background {
        didSet { defaults.set(customThemeBackground, forKey: CustomThemeColors.backgroundKey); apply() }
    }
    @Published var customThemeAccent: String = CustomThemeColors.accent {
        didSet { defaults.set(customThemeAccent, forKey: CustomThemeColors.accentKey); apply() }
    }
    /// Tinted glass colours, stored as hex, and how much the tint covers the desktop.
    @Published var tintedGlassTint: String = TintedGlassColors.tint {
        didSet { defaults.set(tintedGlassTint, forKey: TintedGlassColors.tintKey); apply() }
    }
    @Published var tintedGlassAccent: String = TintedGlassColors.accent {
        didSet { defaults.set(tintedGlassAccent, forKey: TintedGlassColors.accentKey); apply() }
    }
    @Published var tintedGlassStrength: Double = TintedGlassColors.strength {
        didSet { defaults.set(tintedGlassStrength, forKey: TintedGlassColors.strengthKey); apply() }
    }
    @Published var tintedGlassBlurs: Bool = TintedGlassColors.blurs {
        didSet { defaults.set(tintedGlassBlurs, forKey: TintedGlassColors.blurKey); apply() }
    }
    @Published private(set) var systemIsDark = false
    var resolvedScheme: ColorScheme { appearanceMode.scheme(systemIsDark: systemIsDark) }

    private enum Keys {
        static let family = "theme.family"
        static let appearanceMode = "appearance"
    }
    private let defaults: UserDefaults
    private var persistsMode = true
    private var appearanceObservation: NSKeyValueObservation?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearanceMode = defaults.string(forKey: Keys.appearanceMode).flatMap(AppearanceMode.init(rawValue:)) ?? .system
        family = defaults.string(forKey: Keys.family).flatMap(ThemeFamily.init(saved:)) ?? .noir
        Theme.family = family
        systemIsDark = Self.isDark(NSApp.effectiveAppearance)
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] app, _ in
            Task { @MainActor [weak self] in
                guard let self, NSApp.appearance == nil else { return }
                self.systemIsDark = Self.isDark(app.effectiveAppearance)
            }
        }
    }

    /// A launch-time override (--appearance) that isn't saved.
    func override(_ mode: AppearanceMode) {
        persistsMode = false; appearanceMode = mode; persistsMode = true
    }
    /// A launch-time theme (--theme, for checks) that isn't saved.
    func override(_ family: ThemeFamily) {
        persistsMode = false; self.family = family; persistsMode = true
    }

    var nookForeground: Color {
        let palette = family.palette(family.fixedScheme ?? resolvedScheme)
        return palette.color(palette.foreground)
    }

    var notch: ThemeTokens {
        let resolvedScheme = family.fixedScheme ?? self.resolvedScheme
        let colors = family.palette(resolvedScheme)
        let accent = colors.color(colors.accent)
        let foreground = colors.color(colors.foreground)
        return ThemeTokens(
            surface: colors.color(colors.background),
            tile: colors.color(colors.surface),
            selected: accent.opacity(0.20),
            border: foreground.opacity(0.16),
            accent: accent, colorScheme: resolvedScheme
        )
    }

    func selectFamily(_ selection: ThemeFamily) { family = selection }

    /// Sets the app's appearance for this theme and redraws every window.
    func apply() {
        Theme.family = family
        let scheme: ColorScheme? = family.fixedScheme ?? (appearanceMode == .system ? nil : resolvedScheme)
        let appearance = scheme.map { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua) } ?? nil
        if NSApp.appearance?.name != appearance?.name { NSApp.appearance = appearance }
        if appearance == nil { systemIsDark = Self.isDark(NSApp.effectiveAppearance) }
        Theme.redraw()
        NotificationCenter.default.post(name: .folioThemeChanged, object: nil)
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

extension Notification.Name {
    /// Posted after the theme or appearance changes, so windows can switch Glass on or off.
    static let folioThemeChanged = Notification.Name("org.lumashelf.theme-changed")
}

extension Color {
    init?(themeHex: String) {
        guard let value = Theme.rgb(themeHex) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
