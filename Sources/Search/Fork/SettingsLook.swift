import AppKit
import SwiftUI

// Settings' own look: the colours, the section and header pieces, and the
// anchors search scrolls to. Upstream's `Line`, `Card` and `Caption`
// (Plate.swift) read `settingsLook` from the environment, so every page —
// upstream's and Copper's — is drawn the same way inside the panel without
// each one learning a new row type, and stays exactly as it was everywhere
// else (the Passwords list, the Downloads panel…).

/// Settings' greys. The panel sits a step off the page's white: the rail a
/// little deeper, the content a breath off white, and the cards white on it
/// — so a group of rows reads as a group without a heavier hairline.
enum SettingsInk {
    static let rail = Color(nsColor: pair(0.952, 0.128))
    static let content = Color(nsColor: pair(0.976, 0.108))
    static let card = Color(nsColor: pair(1.0, 0.150))
    static let cardEdge = Color(nsColor: pair(0.905, 0.205))
    /// Secondary text: darker than `Palette.muted` in light (5:1 on white
    /// rather than 3.4:1), the same in dark.
    static let detail = Color(nsColor: pair(0.40, 0.64))
    /// Section titles: between the ink and the detail.
    static let heading = Color(nsColor: pair(0.26, 0.80))
    /// The field at the top of the rail.
    static let field = Color(nsColor: pair(0.905, 0.185))
    /// A row chosen in the results, or a page in the rail.
    static let chosen = Color(nsColor: pair(1.0, 0.205))
    /// A matched letter's wash in a result.
    static let mark = Color(nsColor: pairAlpha(0.0, 1.0, 0.07, 0.12))

    private static func pair(_ light: CGFloat, _ dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let dim = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: dim ? dark : light, alpha: 1)
        }
    }

    private static func pairAlpha(_ light: CGFloat, _ dark: CGFloat, _ lightAlpha: CGFloat, _ darkAlpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let dim = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: dim ? dark : light, alpha: dim ? darkAlpha : lightAlpha)
        }
    }
}

// MARK: - the environment upstream's pieces read

private struct SettingsLookKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SettingsFlashKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

/// Fork (settings-merge): the anchor a search is on its way to, so a fold
/// holding it opens before the page scrolls.
private struct SettingsPendingKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// True inside the Settings panel: `Line`, `Card` and `Caption` take
    /// Settings' metrics and greys (Plate.swift reads it).
    var settingsLook: Bool {
        get { self[SettingsLookKey.self] }
        set { self[SettingsLookKey.self] = newValue }
    }

    /// The anchor search just landed on, for its brief highlight.
    var settingsFlash: String? {
        get { self[SettingsFlashKey.self] }
        set { self[SettingsFlashKey.self] = newValue }
    }

    var settingsPending: String? {
        get { self[SettingsPendingKey.self] }
        set { self[SettingsPendingKey.self] = newValue }
    }
}

/// Fork (settings-merge): rows most people never touch, folded at the foot
/// of a card under one Advanced row. Each folded row's index entry falls
/// back to `anchor`; a search for one of `holds` opens the fold first.
struct SettingsAdvanced<Content: View>: View {
    let anchor: String
    let holds: Set<String>
    @ViewBuilder let content: () -> Content
    @State private var open = false
    @Environment(\.settingsPending) private var pending

    init(_ anchor: String, holds: Set<String>, @ViewBuilder content: @escaping () -> Content) {
        self.anchor = anchor
        self.holds = holds
        self.content = content
    }

    var body: some View {
        Rule()
        Line("Advanced", open ? "" : "\(holds.count) more setting\(holds.count == 1 ? "" : "s")") {
            Pill(open ? "Hide" : "Show") { withAnimation(Motion.settle) { open.toggle() } }
                .accessibilityLabel(open ? "Hide advanced settings" : "Show advanced settings")
        }
        .settingsAnchor(anchor)
        .task(id: pending) { if let pending, holds.contains(pending) { open = true } }
        if open { content() }
    }
}

/// What `Line`, `Card` and `Caption` change inside Settings. One place, so
/// Plate.swift carries only the reads.
enum SettingsMetrics {
    static func detailInk(_ on: Bool) -> Color { on ? SettingsInk.detail : Palette.muted }
    static func detailSize(_ on: Bool) -> CGFloat { on ? 12 : 11.5 }
    static func lineInset(_ on: Bool) -> CGFloat { on ? 16 : 14 }
    static func lineHeight(_ on: Bool) -> CGFloat { on ? 12 : 11 }
    static func cardFill(_ on: Bool) -> Color { on ? SettingsInk.card : Palette.ground }
    static func cardEdge(_ on: Bool) -> Color { on ? SettingsInk.cardEdge : Palette.hairline }
    static func captionFont(_ on: Bool) -> Font { on ? .system(size: 12.5, weight: .semibold) : .system(size: 11.5, weight: .medium) }
    static func captionInk(_ on: Bool) -> Color { on ? SettingsInk.heading : Palette.muted }
}

// MARK: - sections

/// A titled group of rows: the title over one card, an optional note under
/// it. The unit every page is built from.
struct SettingsSection<Content: View>: View {
    let title: String?
    var note: String? = nil
    /// False when the content brings its own cards (several, or a card type
    /// of its own like Bitwarden's), so they are not boxed twice.
    var carded = true
    @ViewBuilder let content: () -> Content

    init(_ title: String?, note: String? = nil, carded: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.note = note
        self.carded = carded
        self.content = content
    }

    var body: some View {
        let _ = SettingsPerf.tick("section") // Fork (settings-perf)
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                SettingsSectionTitle(title)
            }
            if carded {
                Card { content() }
            } else {
                VStack(alignment: .leading, spacing: 12) { content() }
            }
            if let note {
                SettingsNote(note)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsSectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(SettingsInk.heading)
            .padding(.leading, 16)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A sentence under a section: where something is kept, what it costs.
struct SettingsNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(SettingsInk.detail)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - anchors

/// Every anchor a page drew, collected up to the panel so the bench can
/// check the index against what is really on screen.
struct SettingsAnchorsKey: PreferenceKey {
    static let defaultValue: Set<String> = []
    static func reduce(value: inout Set<String>, nextValue: () -> Set<String>) {
        value.formUnion(nextValue())
    }
}

/// A row (or a card) search can land on: an id the page's scroll can reach,
/// a mark the index check can see, and the calm highlight when search lands
/// here — a soft wash and a ring that fade in and back out.
struct SettingsAnchor: ViewModifier {
    let id: String
    /// A whole card: the ring follows the card's corners rather than sitting
    /// inside a row.
    var card = false
    @Environment(\.settingsFlash) private var flash
    @Environment(\.accessibilityReduceMotion) private var still

    /// The anchors that are whole cards. A card can be taller than the page
    /// column, so search lands it by its top edge (`land`), never by a
    /// point inside it that would push its title under the header.
    @MainActor static var cards: Set<String> = []
    /// How far under the page header a card's top edge lands: room for the
    /// section title above it (`SettingsSection`, 8 pt over the card).
    static let cardMargin: CGFloat = 36
    /// The id of the mark just above a card's top edge.
    nonisolated static func top(_ id: String) -> String { id + "#top" }

    /// Scrolls the open page to `id`: a row a fifth of the way down (`spot`),
    /// a card with its top edge just under the header, so its title shows.
    @MainActor static func land(_ proxy: ScrollViewProxy, on id: String, spot: UnitPoint) {
        if cards.contains(id) { proxy.scrollTo(top(id), anchor: .top) } else { proxy.scrollTo(id, anchor: spot) }
    }

    /// Whether a landing glides there: only in a window that is in view. A
    /// parked (headless) or covered window gets none of the frames a glide
    /// runs on, so search there would never land at all; it jumps instead.
    @MainActor static var glides: Bool {
        guard let window = Links.window else { return true }
        return window.occlusionState.contains(.visible)
    }

    func body(content: Content) -> some View {
        SettingsPerf.tick("anchor")
        if card, !Self.cards.contains(id) { Self.cards.insert(id) }
        let lit = flash == id
        let radius: CGFloat = card ? 11 : 8
        let marked = content
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Palette.ink.opacity(0.045))
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Palette.ink.opacity(0.22), lineWidth: 1.25)
                    )
                    .padding(card ? 0 : 3)
                    .opacity(lit ? 1 : 0)
                    .animation(still ? nil : (lit ? .easeOut(duration: 0.18) : .easeInOut(duration: 0.9)), value: lit)
                    .allowsHitTesting(false)
            }
            .id(id)
            .transformPreference(SettingsAnchorsKey.self) { $0.insert(id) }
        return Group {
            if card {
                // A mark `cardMargin` tall just above the card, for `land`;
                // the negative padding keeps the card where it was.
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(width: 1, height: Self.cardMargin)
                        .id(Self.top(id))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    marked
                }
                .padding(.top, -Self.cardMargin)
            } else {
                marked
            }
        }
    }
}

extension View {
    /// Marks a row search can land on. `id` must have an entry in
    /// `SettingsIndex` — `bench settings index check` says so if not.
    func settingsAnchor(_ id: String, card: Bool = false) -> some View {
        modifier(SettingsAnchor(id: id, card: card))
    }
}

// MARK: - the page header

/// Whether the open page has scrolled under its header (settings-perf): its
/// own object, watched only by the hairline, so the moment a scroll crosses
/// the edge redraws one line rather than the whole panel and its page.
@MainActor
final class SettingsScrollEdge: ObservableObject {
    @Published var scrolled = false
}

/// The hairline under the page header, shown once the page has scrolled.
struct SettingsHeaderRule: View {
    @ObservedObject var edge: SettingsScrollEdge
    /// The results are showing: they have no header edge.
    let hidden: Bool

    var body: some View {
        Rectangle()
            .fill(SettingsInk.cardEdge)
            .frame(height: 1)
            .opacity(edge.scrolled && !hidden ? 1 : 0)
            .animation(Motion.quick, value: edge.scrolled)
    }
}

/// Is Copper the default browser — asked of LaunchServices once per opening
/// of Settings (settings-perf). `SettingsPanel` is made anew on every redraw
/// of the window while it is open, and its `isDefault` starting value was a
/// LaunchServices round trip each time, though only the first is ever used.
@MainActor
enum SettingsDefaultBrowser {
    private static var cached: Bool?

    static var isDefault: Bool {
        if let cached { return cached }
        let now = Links.isDefault
        cached = now
        return now
    }

    /// Settings closed: the next opening asks again.
    static func forget() { cached = nil }
}

/// The page's title and what it is for, in a sentence.
struct SettingsHeader<Trailing: View>: View {
    let title: String
    let blurb: String
    var icon: String? = nil
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(blurb)
                    .font(.system(size: 13))
                    .foregroundStyle(SettingsInk.detail)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}
