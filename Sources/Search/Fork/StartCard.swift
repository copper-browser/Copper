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

    var body: some View {
        if offer, browser.tabs.allSatisfy(\.isBlank) {
            card.onDisappear {
                // A page opened: the card has done its job.
                if !browser.tabs.allSatisfy(\.isBlank) { offer = false }
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(StartCard.found.isEmpty ? "Getting around" : "Move in from")
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
            if !StartCard.found.isEmpty {
                HStack(spacing: 8) {
                    ForEach(StartCard.found, id: \.name) { found in
                        BrowserPill(name: found.name, icon: found.icon) {
                            Flow.shared.present(from: browser, via: .start, prefer: found.name)
                        }
                    }
                }
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

    private func hint(_ keys: String, _ does: String) -> some View {
        HStack(spacing: 6) {
            Text(keys)
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(does)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
        }
        .accessibilityElement(children: .combine)
    }

    /// Browsers Move in reads, in the order people most often leave them.
    /// A test run answers from `flow.installed` (as FlowAccess does).
    static let known: [(name: String, bundle: String)] = [
        ("Arc", "company.thebrowser.Browser"), ("Chrome", "com.google.Chrome"), ("Dia", "company.thebrowser.dia"),
        ("Brave", "com.brave.Browser"), ("Edge", "com.microsoft.edgemac"), ("Safari", "com.apple.Safari"),
    ]

    /// Looked up once a launch: Launch Services, not a folder read.
    @MainActor static let found = browsers()

    static func browsers() -> [(name: String, icon: NSImage?)] {
        let ws = NSWorkspace.shared
        let listed = Store.testing ? Store.settings.string(forKey: "flow.installed").map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } } : nil
        return known.compactMap { entry in
            let app = ws.urlForApplication(withBundleIdentifier: entry.bundle)
            if let listed { return listed.contains(entry.name) ? (entry.name, app.map { ws.icon(forFile: $0.path) }) : nil }
            return app.map { (entry.name, ws.icon(forFile: $0.path)) }
        }
        .prefix(3).map { $0 }
    }
}

/// One browser to move in from: its own icon and name, outlined.
private struct BrowserPill: View {
    let name: String
    let icon: NSImage?
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
        .help("Bring your tabs, bookmarks and passwords over from \(name)")
        .accessibilityLabel("Move in from \(name)")
    }
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
