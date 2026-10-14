import SwiftUI
import AppKit

// Ported from MacSpaces' Settings/SettingsComponents.swift (same author, MIT).

struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    let scrollAnchor: String?
    @ViewBuilder let content: Content
    @ObservedObject private var theme = ThemeStore.shared
    @ObservedObject private var navigation = SettingsNavigationModel.shared
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("reduceMotion") private var folioReduceMotion = false
    private var reduceMotion: Bool { systemReduceMotion || folioReduceMotion }

    init(title: String, subtitle: String, scrollAnchor: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.scrollAnchor = scrollAnchor
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 26, weight: .bold))
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 2)

                    content
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.notch.surface)
            .foregroundStyle(theme.nookForeground)
            .task(id: scrollAnchor ?? navigation.searchTarget) {
                guard let target = scrollAnchor ?? navigation.searchTarget.map({ "settings." + $0 }) else { return }
                await Task.yield()
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    proxy.scrollTo(target, anchor: scrollAnchor == nil ? .top : .center)
                }
            }
        }
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content
    @ObservedObject private var theme = ThemeStore.shared
    @ObservedObject private var navigation = SettingsNavigationModel.shared

    init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.notch.tile, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(theme.notch.border, lineWidth: 1)
        }
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.notch.accent.opacity(navigation.searchTarget == title ? 0.65 : 0), lineWidth: 1.5) }
        .id("settings." + title)
    }
}

/// An icon, a title with detail, and a trailing control: MacSpaces' permission row.
struct SettingsRow<Accessory: View>: View {
    let title: String
    let detail: String
    let symbol: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            accessory
        }
        .padding(.vertical, 3)
    }
}

/// A Refresh control whose arrow turns once each time it's clicked.
struct RefreshButton: View {
    var title: String?
    let action: () -> Void
    @State private var turns = 0
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("reduceMotion") private var folioReduceMotion = false
    private var reduceMotion: Bool { systemReduceMotion || folioReduceMotion }

    init(_ title: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button {
            action()
            turns += 1
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(reduceMotion ? 0 : Double(turns) * 360))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.55), value: turns)
                if let title { Text(title) }
            }
        }
        .accessibilityLabel(title ?? "Refresh")
    }
}

struct FolioMark: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: FolioIcon.image)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .shadow(color: Color.black.opacity(0.22), radius: size * 0.12, y: size * 0.06)
    }
}

/// Folio's icon from the app bundle; unbundled development runs draw the same mark.
enum FolioIcon {
    @MainActor static var image: NSImage {
        if Bundle.main.bundleURL.pathExtension == "app", Bundle.main.object(forInfoDictionaryKey:"CFBundleIconFile") != nil || Bundle.main.object(forInfoDictionaryKey:"CFBundleIconName") != nil {
            return NSApp.applicationIconImage
        }
        return mark
    }
    static let mark = NSImage(size:NSSize(width:512,height:512),flipped:true) { rect in
        let s = rect.width / 1024
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x:x*s,y:y*s,width:w*s,height:h*s) }
        NSColor.black.setFill(); NSBezierPath(roundedRect:r(64,64,896,896),xRadius:200*s,yRadius:200*s).fill()
        NSColor.white.setFill()
        for (x,y) in [(232.0,232.0),(232.0,535.0),(535.0,535.0)] { NSBezierPath(roundedRect:r(x,y,258,258),xRadius:28*s,yRadius:28*s).fill() }
        NSBezierPath(ovalIn:r(534,232,258,258)).fill()
        return true
    }
}

extension View {
    /// ↑ and ↓ in a text field, and Escape.
    func textFieldKeys(up: @escaping () -> Void, down: @escaping () -> Void, escape: @escaping () -> Void) -> some View {
        onKeyPress(.downArrow) { down(); return .handled }
            .onKeyPress(.upArrow) { up(); return .handled }
            .onKeyPress(.escape) { escape(); return .handled }
    }
}
