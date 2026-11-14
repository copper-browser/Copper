import AppKit
import SwiftUI

/// Fork (first-run): the small card under the field in a new profile's first
/// window — the browsers there are to move in from, and the three keys worth
/// knowing — so the first minute is not one empty field on white.
///
/// Only a fresh profile offers it (`Preferences.freshProfile` writes
/// `start.offer`), only while every tab in the window is blank, and it is
/// gone for good once dismissed, once Move in finishes or once a page opens.
/// Which browsers are listed comes from Launch Services (is the app here?),
/// never from their folders: reading those waits for Move in itself.
struct StartCard: View {
    @ObservedObject var browser: Browser
    @AppStorage("start.offer", store: Store.settings) private var offer = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if offer, browser.tabs.allSatisfy(\.isBlank) {
            card.onDisappear {
                // A page opened: the card has done its job.
                if !browser.tabs.allSatisfy(\.isBlank) { offer = false }
            }
        } else if browser.spaceIsEmpty {
            emptySpace
        }
    }

    /// Fork (ui-flows r3): a space with nothing open yet says whose it is and
    /// the three keys that fill it, on its own ground (Arc's empty space).
    private var emptySpace: some View {
        let space = Spaces.shared.space(in: browser)
        let tint = SpaceTint(space: space, dark: scheme == .dark)
        return VStack(spacing: 12) {
            Text(space.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint.ink)
            HStack(spacing: 18) {
                hint("⌘T", "New tab", ink: tint.ink, cap: tint.square)
                hint("⌘K", "Find a tab", ink: tint.ink, cap: tint.square)
                hint("⌃1–9", "Switch space", ink: tint.ink, cap: tint.square)
            }
        }
        .padding(.top, 18)
        .transition(.opacity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(MoveFrom.found.isEmpty ? "Getting around" : "Move in from")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
                Button { withAnimation(Motion.quick) { offer = false } } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide this")
                .accessibilityLabel("Hide the start card")
            }
            if !MoveFrom.found.isEmpty {
                MoveFromPills(browser: browser)
                Rectangle().fill(Palette.hairline).frame(height: 1)
            }
            HStack(spacing: 18) {
                hint("⌘T", "New tab")
                hint("⌘K", "Find a tab")
                hint("⌃1–9", "Switch space")
            }
        }
        .padding(16)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .transition(.opacity)
    }

    private func hint(_ keys: String, _ does: String, ink: Color = Palette.ink, cap: Color = Palette.wash) -> some View {
        HStack(spacing: 6) {
            Text(keys)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(ink)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(cap, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(does)
                .font(.system(size: 13)) // Fork (ui-flows r3): 13 pt, the page's own size
                .foregroundStyle(ink == Palette.ink ? Palette.muted : ink.opacity(0.85))
        }
        .accessibilityElement(children: .combine)
    }
}

/// Fork (ui-flows): the one list of browsers there are to move in from, and
/// the sentence that names them. The start card, Welcome, Move in, the
/// Passwords window and Settings › Passwords all read it, so no two of them
/// can name different browsers (they named five different sets in round 2).
/// Launch Services (is the app here?), never their folders: reading those
/// waits for Move in itself.
@MainActor
enum MoveFrom {
    /// Browsers Move in reads, in the order people most often leave them.
    /// A test run answers from `flow.installed` (as FlowAccess does).
    static let known: [(name: String, bundle: String)] = [
        ("Arc", "company.thebrowser.Browser"), ("Chrome", "com.google.Chrome"), ("Dia", "company.thebrowser.dia"),
        ("Brave", "com.brave.Browser"), ("Edge", "com.microsoft.edgemac"), ("Vivaldi", "com.vivaldi.Vivaldi"),
        ("Chromium", "org.chromium.Chromium"), ("Safari", "com.apple.Safari"),
    ]

    /// Looked up once a launch.
    static let found = browsers()

    static func browsers() -> [(name: String, icon: NSImage?)] {
        let ws = NSWorkspace.shared
        let listed = Store.testing ? Store.settings.string(forKey: "flow.installed").map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } } : nil
        return known.compactMap { entry in
            let app = ws.urlForApplication(withBundleIdentifier: entry.bundle)
            if let listed { return listed.contains(entry.name) ? (entry.name, app.map { ws.icon(forFile: $0.path) }) : nil }
            return app.map { (entry.name, ws.icon(forFile: $0.path)) }
        }
    }

    /// "Arc or Safari": the browsers found, for a sentence.
    static var names: String { phrase(found.map(\.name)) }

    /// The app's own icon, for Move in's cards; nil when it isn't here.
    static func icon(_ name: String) -> NSImage? {
        if let hit = found.first(where: { $0.name == name }) { return hit.icon }
        guard let bundle = known.first(where: { $0.name == name })?.bundle,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        return NSWorkspace.shared.icon(forFile: app.path)
    }

    /// "A", "A or B", "A, B or C"; "another browser" for none.
    nonisolated static func phrase(_ names: [String]) -> String {
        switch names.count {
        case 0: return "another browser"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " or " + names[names.count - 1]
        }
    }
}

/// Fork (ui-flows): the found browsers as pills, each opening Move in on
/// itself — the start card's and Welcome's, the same row.
struct MoveFromPills: View {
    let browser: Browser
    var via: Flow.Door = .start

    var body: some View {
        HStack(spacing: 8) {
            ForEach(MoveFrom.found, id: \.name) { found in
                BrowserPill(name: found.name, icon: found.icon) {
                    Flow.shared.present(from: browser, via: via, prefer: found.name)
                }
            }
        }
    }
}

/// One browser to move in from: its own icon and name, outlined.
struct BrowserPill: View {
    let name: String
    let icon: NSImage?
    var help: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.ink)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(hovering ? Palette.hover : Palette.ground, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? "Bring your tabs, bookmarks and passwords over from \(name)")
        .accessibilityLabel("Move in from \(name)")
    }
}

extension Browser {
    /// Fork (ui-flows r3): nothing open in this space but the favourites
    /// (which every space shows) and blank tabs.
    var spaceIsEmpty: Bool { tabs.allSatisfy { $0.pin != nil || $0.isBlank } }
}

extension Preferences {
    /// Fork (first-run): nothing written yet — no layout chosen, no welcome
    /// walked through, no glyph (the mark of a profile from before the
    /// welcome existed). Asked once, in `init`, before anything is written.
    static func freshProfile(_ store: UserDefaults) -> Bool {
        store.object(forKey: "sidebar") == nil && store.object(forKey: "manner") == nil
            && !store.bool(forKey: "welcomed") && store.object(forKey: "glyph") == nil
    }
}

/// Fork (ui-flows r3): a new profile's favourites row before it has any —
/// three dashed places in the grid, and a site dropped on them is kept there.
/// Gone with the start card, or once there is a favourite.
struct GhostFavourites: View {
    @ObservedObject var browser: Browser
    let tint: SpaceTint
    let width: CGFloat
    let height: CGFloat
    let gap: CGFloat
    @AppStorage("start.offer", store: Store.settings) private var offer = false
    @State private var landing = false

    var body: some View {
        if offer, browser.pinnedCount == 0 {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: gap) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(tint.ink.opacity(landing ? 0.5 : 0.22), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .background(landing ? tint.hover : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .frame(width: width, height: height)
                    }
                }
                Text("Drop a site here to keep it")
                    .font(.system(size: 11))
                    .foregroundStyle(tint.ink.opacity(0.8))
                    .padding(.leading, 2)
            }
            .contentShape(Rectangle())
            .onDrop(of: [.url, .text], isTargeted: $landing) { providers in
                guard let provider = providers.first else { return false }
                let keep: (URL) -> Void = { url in
                    DispatchQueue.main.async { browser.pin(browser.open(url, foreground: true)) }
                }
                if provider.canLoadObject(ofClass: URL.self) {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { keep(url) } }
                } else {
                    _ = provider.loadObject(ofClass: String.self) { text, _ in if let text, let url = Address.url(from: text) { keep(url) } }
                }
                return true
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("No favourites yet. Drop a site here to keep it.")
            .animation(Motion.quick, value: landing)
        }
    }
}
