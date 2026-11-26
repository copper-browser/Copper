import AppKit
import SwiftUI

// Fork (ardia polish): What's New after an update. The first launch of a
// newer Copper than the one that ran last puts a card in the column, above
// its foot: the release's own words (the feed's notes, NOTES.md's first
// paragraph, once the check five seconds after launch has them), the full
// changelog a click away, and ✕. It is shown that launch only; a first
// install, a downgrade or a relaunch of the same version shows nothing.

@MainActor
final class UpdateNews: ObservableObject {
    static let shared = UpdateNews()

    /// The version the card is up for; nil is no card.
    @Published private(set) var version: String?
    /// The bench's words in place of the feed's.
    @Published private(set) var forcedNotes: String?
    private var started = false

    private static let key = "whatsnew.seen"

    /// Whether `current` is worth the card after `seen` ran last.
    nonisolated static func due(seen: String?, current: String) -> Bool {
        guard let seen, !seen.isEmpty, !current.isEmpty, current != "dev" else { return false }
        return Updates.compare(current, seen) > 0
    }

    /// Once a process (Updates.start, every window calls it).
    func launched(as current: String) {
        guard !started else { return }
        started = true
        let seen = Store.settings.string(forKey: Self.key)
        Store.settings.set(current, forKey: Self.key)
        if Self.due(seen: seen, current: current) { version = current }
    }

    func close() { version = nil }

    /// The feed's notes, when the feed's latest is the version the card is for.
    func notes(_ updates: Updates) -> String? {
        if let forcedNotes { return forcedNotes }
        guard let latest = updates.latest, latest.version == version else { return nil }
        return latest.notes
    }

    /// `updates whatsnew` what it shows · `launch PREVIOUS` a launch as if
    /// PREVIOUS ran last · `show [VERSION] [NOTES…]` · `close` · `reset`.
    func bench(_ words: [String]) -> [String: Any] {
        var words = words
        let op = words.isEmpty ? "state" : words.removeFirst()
        let current = Updates.shared.current
        switch op {
        case "launch":
            Store.settings.set(words.first ?? "", forKey: Self.key)
            started = false
            version = nil
            launched(as: current)
        case "show":
            version = words.isEmpty ? current : words.removeFirst()
            forcedNotes = words.isEmpty ? nil : words.joined(separator: " ")
        case "close": close()
        case "reset":
            Store.settings.removeObject(forKey: Self.key)
            version = nil
            forcedNotes = nil
        default: break
        }
        return ["showing": version != nil, "version": version ?? "", "current": current,
                "seen": Store.settings.string(forKey: Self.key) ?? "", "notes": notes(Updates.shared) ?? ""]
    }
}

/// Above the column's foot (Side.swift).
struct UpdateNewsSlot: View {
    let browser: Browser
    @ObservedObject private var news = UpdateNews.shared
    @ObservedObject private var updates = Updates.shared
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        VStack(spacing: 0) {
            if let version = news.version {
                SlideInk(browser: browser) { tint in
                    UpdateNewsCard(browser: browser, version: version, notes: news.notes(updates), tint: tint)
                }
                .padding(.horizontal, SideBar.inset)
                .padding(.top, 6)
                .transition(still ? .opacity : .offset(y: 10).combined(with: .opacity))
            }
        }
        .animation(still ? .easeOut(duration: 0.2) : Motion.glide, value: news.version)
    }
}

/// With the tabs across the top, or the column folded away: the same card
/// in the window's bottom-left corner, over the page (App.swift).
struct UpdateNewsCorner: View {
    let browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject private var news = UpdateNews.shared
    @ObservedObject private var updates = Updates.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        let off = !prefs.sidebar || (browser.folded && !browser.peeking)
        return ZStack(alignment: prefs.sidebar && prefs.sideRight ? .bottomTrailing : .bottomLeading) { // Fork (ardia layout): the column's corner
            if off, let version = news.version {
                UpdateNewsCard(browser: browser, version: version, notes: news.notes(updates),
                               tint: SpaceTint(space: Spaces.shared.space(in: browser), dark: scheme == .dark), solid: true)
                    .frame(width: 280)
                    .padding(12)
                    .transition(still ? .opacity : .offset(y: 10).combined(with: .opacity))
            }
        }
        .animation(still ? .easeOut(duration: 0.2) : Motion.glide, value: off && news.version != nil)
    }
}

private struct UpdateNewsCard: View {
    let browser: Browser
    let version: String
    let notes: String?
    let tint: SpaceTint
    /// Over the page rather than on the column: the window's own ground and ink.
    var solid = false

    private var ink: Color { solid ? Palette.ink : tint.ink }
    private var muted: Color { solid ? Palette.muted : tint.muted }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
                Text("What’s new in Copper")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Button { UpdateNews.shared.close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(muted)
                .help("Close")
                .accessibilityLabel("Close")
            }
            .foregroundStyle(ink)
            Text(notes ?? "You're on \(version) now.")
                .font(.system(size: 11.5))
                .foregroundStyle(muted)
                .lineSpacing(1.5)
                .lineLimit(6)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if let url = UpdatePill.changelog(for: Updates.shared.latest?.version == version ? Updates.shared.latest : nil) {
                    browser.open(url, foreground: true)
                }
                UpdateNews.shared.close()
            } label: {
                Text("Everything that changed")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(ink)
                    .underline()
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(solid ? Palette.ground : tint.pill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { if solid { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1) } }
        .shadow(color: solid ? .black.opacity(0.12) : tint.lift, radius: solid ? 16 : 2, y: solid ? 5 : 1)
        .accessibilityElement(children: .contain)
    }
}
