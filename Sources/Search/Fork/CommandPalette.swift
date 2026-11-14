import SwiftUI
import AppKit

// ⌘K, as a card.
//
// Upstream's Omnibox is a field for addresses: one pill, a list under it, a
// small dot per row. ⌘K is a different instrument — it is the whole browser
// answering "what did you mean" — and it wants the shape Arc gives it: one
// card floating a third of the way down the window, an input you can read
// from across the room, and rows that each say, on the right, what Return
// will do with them.
//
// Nothing here knows about spaces or commands; it draws the rows the browser
// hands it. What a row *is* is decided in CommandBar.offers.

struct CommandPalette: View {
    @ObservedObject var browser: Browser
    /// A page is behind this, rather than an empty tab. The page gets dimmed;
    /// an empty tab has nothing to dim.
    let over: Bool

    /// Wide enough for a title, a host and a hint without any of the three
    /// eating the others.
    private static let width: CGFloat = 640

    /// How far down the window the top of the card sits. A card pinned to the
    /// middle floats; a card near the top reads as a toolbar. A third of the
    /// way down is where the eye already is.
    private static let drop: CGFloat = 0.3

    @State private var place = WindowRuler.Place()
    /// The site marks, arriving a moment after the rows they belong to.
    @ObservedObject private var marks = Marks.ticker
    /// The sections' headings, ⌘T's and ⌘K's alike (Fork/CardSections).
    @ObservedObject private var sections = CardSections.shared
    /// What is typed and offered. The browser no longer announces it to
    /// every view it has; see `Browser.Field`.
    @ObservedObject private var state: Browser.Field
    @Environment(\.colorScheme) private var scheme

    init(browser: Browser, over: Bool) {
        self.browser = browser
        self.over = over
        _state = ObservedObject(wrappedValue: browser.field)
    }

    /// Fixed so the card's height can be worked out before it is drawn: a
    /// scroll view left to size itself takes all the room it is offered,
    /// and a card with three rows would stand as tall as the window.
    private static let rowHeight: CGFloat = 40
    private static let headingHeight: CGFloat = 28

    var body: some View {
        ZStack(alignment: .top) {
            // The page, still there, just told to be quiet.
            Rectangle()
                .fill(Color.black.opacity(over ? 0.16 : 0.05))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { browser.dismiss() }
                .transition(.opacity)

            card
                .frame(width: CommandPalette.width)
                // The card belongs to the window, not to the page area it
                // happens to be drawn in, so it is shifted back over the
                // column of tabs by half that column's width.
                .offset(x: -inset / 2, y: top)
        }
        .background(WindowRuler { place = $0 })
        // The rows change on every letter, and as Google and history land.
        // A spring on each of those kept the card resizing for a third of a
        // second behind every keystroke — it read as lag, not as motion, and
        // redrew the card on every frame of it. Only ⌘K's resting list, with
        // nothing typed, settles in.
        .animation(browser.launching || !state.typed.isEmpty ? nil : Motion.settle, value: browser.offers)
        // Every row that names a site wants that site's mark, and most of
        // these rows have no page behind them to ask. See Fork/Marks.
        .onAppear { Marks.want(browser.offers.map(\.url)) }
        .onChange(of: browser.offers) { _, offers in Marks.want(offers.map(\.url)) }
    }

    /// Where to put the top of the card, counted from the top of the region
    /// SwiftUI handed this view — which is not the top of the window, and on
    /// a 900pt window starts some 240pt above it.
    private var top: CGFloat {
        guard place.height > 0 else { return 240 }
        return place.height * CommandPalette.drop - place.top
    }

    private var inset: CGFloat {
        browser.prefs.sidebar && !browser.folded ? browser.prefs.sideWidth : 0
    }

    private var card: some View {
        VStack(spacing: 0) {
            field
            if !browser.offers.isEmpty {
                Rectangle()
                    .fill(Palette.hairline.opacity(0.55))
                    .frame(height: 1)
                rows
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Palette.ground)
        )
        // Clip first, cast second. A .shadow draws behind whatever the view
        // is at that point in the chain, so a .clipShape after it trims the
        // shadow to the card's own bounds and leaves a flat rectangle with a
        // hard edge — which is what this was, for two rounds.
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        // No outline. A card this size separates itself by sitting above the
        // page, and the shadow is the only thing that says so — one tight
        // shadow for the edge, one wide one for the lift.
        .shadow(color: .black.opacity(0.09), radius: 3, y: 1)
        .shadow(color: .black.opacity(0.26), radius: 48, y: 20)
        .transition(.scale(scale: 0.985, anchor: .top).combined(with: .opacity))
    }

    private var field: some View {
        HStack(spacing: 13) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.muted)
            AddressField(
                browser: browser,
                literal: true,
                size: 17.5,
                placeholder: "Search or enter address"
            )
            .frame(height: 24)
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }

    /// The rows, in their sections, each under a small heading — ⌘T's and
    /// ⌘K's the same way, so Tab means the same thing in both. Taller than
    /// the window allows, the list scrolls, and follows the arrow keys.
    private var rows: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(browser.offers.enumerated()), id: \.offset) { index, offer in
                        // A section's heading and its first row scroll as
                        // one, so Tab back round to the top shows the label
                        // too, not just the row under it.
                        VStack(alignment: .leading, spacing: 1) {
                            if let heading = sections.headings[index] {
                                Text(heading)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(Palette.ink.opacity(0.6))
                                    .padding(.horizontal, 12)
                                    .frame(height: CommandPalette.headingHeight, alignment: .bottomLeading)
                                    .padding(.bottom, 2)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            Row(offer: offer, picked: browser.picked == index, tint: tint.mark, fill: tint.dot, stamp: marks.landed,
                                aside: browser.launching && browser.picked == index ? Launcher.aside(for: offer, in: browser) : "")
                                .contentShape(Rectangle())
                                .onTapGesture { browser.take(offer) }
                        }
                        .id(index)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            // Taller than the room, the list runs out under a soft edge, and
            // the arrows stop short of it: the row Return takes is never the
            // one half-faded.
            .safeAreaPadding(.bottom, overflowing ? CommandPalette.fade : 0)
            .mask {
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .black.opacity(overflowing ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                        .frame(height: CommandPalette.fade)
                }
            }
            .frame(height: min(natural, room))
            .onChange(of: browser.picked) { _, picked in
                guard let picked else { return }
                withAnimation(Motion.quick) { reader.scrollTo(picked) }
            }
        }
    }

    /// As tall as the rows.
    private var natural: CGFloat {
        let rows = CGFloat(browser.offers.count)
        let headings = CGFloat(sections.headings.keys.filter { $0 < browser.offers.count }.count)
        return rows * (CommandPalette.rowHeight + 1) + headings * (CommandPalette.headingHeight + 3) + 16
    }

    /// No taller than the window below the card, less a margin that keeps
    /// the card's foot well clear of the window's (window − 160 at most).
    private var room: CGFloat {
        guard place.height > 0 else { return 480 }
        return max(min(place.height * (1 - CommandPalette.drop) - 80, place.height - 160) - 56, 200)
    }

    private var overflowing: Bool { natural > room }

    private static let fade: CGFloat = 28

    /// The space's own colour, deep enough to read as text in the light and
    /// pale enough in the dark, so the selected row belongs to where you are.
    private var tint: SpaceTint { SpaceTint(space: Spaces.shared.space(in: browser), dark: scheme == .dark).offColumn }

    private struct Row: View {
        let offer: Suggestion
        let picked: Bool
        let tint: Color
        /// The selected row's ground: the space's colour at full strength.
        let fill: Color
        /// Changes when a site mark lands, which is the only thing that can
        /// make a row draw differently without the row itself changing.
        let stamp: Int
        /// ⌘T: the other ways to take this row — "⇧↩ Background" — said
        /// only on the row Return would take.
        var aside: String = ""

        @State private var hovering = false
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            HStack(spacing: 11) {
                Mark(offer: offer, tint: tint, picked: picked, stamp: stamp)
                    .frame(width: 18, height: 18)

                // One weight, picked or not. Going semibold on the selected
                // row widened it enough to squeeze the muted half out of the
                // row — so the one row you were about to press Return on was
                // the one that stopped telling you which space it lived in.
                // The pill and the tinted hint say "selected" without moving
                // anything.
                Text(offer.key)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                // A host cut down to "mail.go…" has stopped being an answer
                // to anything, so it is shown whole and the title — still
                // readable from its first two thirds — is what gives way
                // when the row runs out of width.
                if !offer.detail.isEmpty {
                    Text(offer.detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .fixedSize()
                        .layoutPriority(2)
                }

                // Last to give way: see Suggestion.badge.
                if !offer.badge.isEmpty {
                    Text(offer.badge)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .fixedSize()
                        .layoutPriority(3)
                }

                Spacer(minLength: 14)

                // Shown only on the row Return would take — "Switch to Tab"
                // set down the right of six rows is a column of grey noise
                // saying the same thing six times — but laid out on every
                // row, so selecting one changes what the row looks like and
                // never what it is shaped like.
                if !aside.isEmpty {
                    Text(aside)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted.opacity(0.85))
                        .lineLimit(1)
                        .fixedSize()
                }
                if !offer.hint.isEmpty {
                    Text(offer.hint)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(picked ? tint : Palette.muted.opacity(0.8))
                        .lineLimit(1)
                        .fixedSize()
                        .opacity(picked || hovering ? 1 : 0)
                }
                // The key that does it, as a key: on the row Return takes.
                Text("↩")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 18)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Palette.ground.opacity(0.7)))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1))
                    .opacity(picked ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(height: CommandPalette.rowHeight)
            .background {
                if picked {
                    // The space's colour, not a grey: a pale grey on a white
                    // card read as hover, not as "Return takes this".
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(fill.opacity(scheme == .dark ? 0.24 : 0.22))
                } else if hovering {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Palette.hover)
                }
            }
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
            .animation(Motion.quick, value: picked)
        }
    }

    /// The thing on the left. A site wears its own icon; a command and a
    /// search wear a glyph; a site whose icon hasn't arrived wears its first
    /// letter, the way the tabs do.
    private struct Mark: View {
        let offer: Suggestion
        let tint: Color
        let picked: Bool
        let stamp: Int

        @Environment(\.colorScheme) private var scheme

        var body: some View {
            switch offer.kind {
            case .command:
                glyph(offer.glyph.isEmpty ? "command" : offer.glyph)
            case .search:
                glyph("magnifyingglass")
            case _ where CanvasLinks.isCanvas(offer.url):
                glyph("scribble.variable") // Fork (canvas): an open canvas wears the Canvas mark here too
            default:
                // The same mark the sidebar row wears — icon or tinted letter
                // chip — so a site looks like itself on both surfaces. On
                // the card's ground, not the column's: a toned-dark column's
                // light letter would vanish on a white card.
                RowMark(icon: Marks.key(for: offer.url).flatMap { Favicons.shared.cached($0) },
                        letter: initial, tint: SpaceTint(scheme).offColumn)
            }
        }

        /// Bare, the way Arc draws its magnifier: no chip, no plate. A grey
        /// rounded square behind the glyph reads as a different kind of row
        /// from the ones wearing a favicon, and the search is the same kind
        /// of row as all the others.
        private func glyph(_ name: String) -> some View {
            Image(systemName: name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(picked ? tint : Palette.muted)
                .frame(width: 18, height: 18)
        }

        private var source: String {
            let host = offer.url.host() ?? offer.key
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }

        private var initial: String { String(source.prefix(1)).uppercased() }
    }
}

/// Where the card's region sits inside the window, and how tall the window is.
///
/// SwiftUI will happily measure the region it gives you, but the region the
/// field overlay gets is stretched past the window's edges by the views
/// beneath it that ignore the safe area — on a 900pt window it comes out
/// around 1390, starting well above the title bar. Placing a card "a third of
/// the way down" against that number puts it above the top of the window. So
/// the card is placed against the window, measured through an AppKit view
/// that is in both.
struct WindowRuler: NSViewRepresentable {
    struct Place: Equatable {
        /// The window's own height.
        var height: CGFloat = 0
        /// How far below the top of the window this region begins — negative
        /// when it starts above it, which is the usual case here.
        var top: CGFloat = 0
    }

    let report: (Place) -> Void

    func makeNSView(context: Context) -> NSView { Ruler(report: report) }
    func updateNSView(_ view: NSView, context: Context) { (view as? Ruler)?.report = report }

    final class Ruler: NSView {
        var report: (Place) -> Void
        private var last = Place()

        init(report: @escaping (Place) -> Void) {
            self.report = report
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("no coder") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            measure()
        }

        override func layout() {
            super.layout()
            measure()
        }

        private func measure() {
            guard let root = window?.contentView, root !== self else { return }
            let mine = convert(bounds, to: root)
            // AppKit counts from the bottom left unless a view says otherwise.
            let top = root.isFlipped ? mine.minY : root.bounds.maxY - mine.maxY
            let place = Place(height: root.bounds.height, top: top)
            guard place.height > 0, place != last else { return }
            last = place
            // Not from inside a layout pass: this drives a SwiftUI state
            // change, and changing state while AppKit is laying the same
            // views out is how you get a view that never settles.
            DispatchQueue.main.async { [report] in report(place) }
        }
    }
}
