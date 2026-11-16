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
    let browser: Browser
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

    @State private var place = CommandPalette.lastPlace
    /// Fork (perf, r4): the rows laid out so far, by id. A keystroke that
    /// brings a list of new rows lays out the first `slice` of them in its own
    /// pass and the rest in the next, each pass under a frame; a row already
    /// on the card stays drawn. The card's height counts them all from the start.
    @State private var laid: Set<String> = []
    /// Fork (perf, r4; polish r5): the card opens at its full height in the
    /// key's own pass and its rows are laid out in the next one. Drawing the
    /// first rows in the key's pass cost ⌘K +10 ms and ⌘T +16 ms of commit
    /// (keylat p50, paired vs r4), so they stay a pass behind — but land
    /// at once, with no fade of their own.
    @State private var filled = false
    static let slice = 4
    /// Fork (perf): where the last card stood. A card measures its window a
    /// moment after it is drawn; starting from the last answer, it opens in
    /// its place instead of at a guess for one frame and moving in a second.
    private static var lastPlace = WindowRuler.Place()
    /// The site marks, arriving a moment after the rows they belong to.
    @ObservedObject private var marks = Marks.ticker
    /// The sections' headings, ⌘T's and ⌘K's alike (Fork/CardSections).
    @ObservedObject private var sections = CardSections.shared
    /// What is typed and offered. The browser no longer announces it to
    /// every view it has; see `Browser.Field`.
    @ObservedObject private var state: Browser.Field
    /// Fork (perf): ⌘T's card or ⌘K's — see `Browser.Bar`.
    @ObservedObject private var bar: Browser.Bar
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    init(browser: Browser, over: Bool) {
        self.browser = browser
        self.over = over
        _state = ObservedObject(wrappedValue: browser.field)
        _bar = ObservedObject(wrappedValue: browser.bar)
    }

    /// Fixed so the card's height can be worked out before it is drawn: a
    /// scroll view left to size itself takes all the room it is offered,
    /// and a card with three rows would stand as tall as the window.
    private static let rowHeight: CGFloat = 40
    /// Fork (uitype): a page's row, its host on a second line under the title.
    private static let pageRowHeight: CGFloat = 46

    /// A row that goes somewhere (an open tab, a visit, a bookmark) and has a
    /// host to show: two lines. Commands and searches stay one.
    static func twoLine(_ offer: Suggestion) -> Bool {
        guard !offer.detail.isEmpty else { return false }
        switch offer.kind {
        case .open, .visited, .known, .bookmark: return true
        case .search, .command: return false
        }
    }
    private static let headingHeight: CGFloat = 28
    /// Fork (polish r5): a command is one short line — 36 pt, as Arc's
    /// command rows, not a page row's 40.
    private static let commandRowHeight: CGFloat = 36

    static func height(_ offer: Suggestion) -> CGFloat {
        if twoLine(offer) { return pageRowHeight }
        return offer.kind == .command ? commandRowHeight : rowHeight
    }

    var body: some View {
        ZStack(alignment: .top) {
            // The page, still there, just told to be quiet.
            // Fork (ux, r4): a lighter hush in the light, a deeper one in the dark.
            Rectangle()
                .fill(Color.black.opacity(over ? (scheme == .dark ? 0.30 : 0.13) : 0.05))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { browser.dismiss() }
                // Fork (hc6): no fade of its own — the dim lands in the card's frame, one step, not three.

            card
                // Fork (perf): a slide, no scale — a scale redraws every glyph at
                // each new size on a 1× screen (see the field's transition, App.swift).
                // Fork (ui-motion): no travel under Reduce Motion.
                .modifier(Arrive(travel: reduceMotion ? 0 : 6))
                .frame(width: CommandPalette.width)
                // Fork (r4): the first card after launch waits the one frame
                // its window takes to be measured, rather than open at a guess
                // and move.
                .opacity(place.height > 0 ? 1 : 0)
                // The card belongs to the window, not to the page area it
                // happens to be drawn in, so it is shifted back over the
                // column of tabs by half that column's width.
                .offset(x: -inset / 2, y: top)
        }
        .background(WindowRuler { place = $0; CommandPalette.lastPlace = $0 })
        // The rows change on every letter, and as Google and history land.
        // A spring on each of those kept the card resizing for a third of a
        // second behind every keystroke — it read as lag, not as motion, and
        // redrew the card on every frame of it. Only ⌘K's resting list, with
        // nothing typed, settles in.
        .animation(bar.launching || !state.typed.isEmpty ? nil : Motion.settle, value: browser.offers)
        // Every row that names a site wants that site's mark, and most of
        // these rows have no page behind them to ask. See Fork/Marks.
        .onAppear {
            Marks.want(browser.offers.map(\.url))
            Launcher.afterCommit {
                // Fork (hc6): after the key's pass, the rows fade in over 60 ms rather than pop.
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.06)) { filled = true }
                laid = Set(CommandPalette.keyed(browser.offers).map(\.id))
            }
        }
        .onChange(of: browser.offers) { _, offers in
            Marks.want(offers.map(\.url))
            Launcher.afterCommit { laid = Set(CommandPalette.keyed(browser.offers).map(\.id)) }
        }
    }

    /// Fork (ui-flows): the card arrives the way Arc's does — solid at once,
    /// a hair high, settling in under 120 ms while only the dim behind it
    /// fades. Fork (perf): the state that starts it lives here, so the pass
    /// it costs redraws this modifier and not the card's rows under it.
    private struct Arrive: ViewModifier {
        var travel: CGFloat = 0
        @State private var shown = false

        func body(content: Content) -> some View {
            content
                .offset(y: shown ? 0 : -travel)
                .onAppear { withAnimation(.easeOut(duration: 0.11)) { shown = true } }
        }
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

    /// Fork (ux): ⌘K's empty field's import nudge, as a quiet line at the
    /// card's foot rather than a row ahead of the doors (CommandBar.resting).
    private var nudge: Suggestion? {
        bar.launching || !state.typed.isEmpty || browser.offers.isEmpty ? nil : CommandBar.nudge
    }

    private var card: some View {
        VStack(spacing: 0) {
            field
            if !browser.offers.isEmpty {
                Rectangle()
                    .fill(Palette.hairline.opacity(0.55))
                    .frame(height: 1)
                if filled {
                    rows.transition(.opacity)
                } else {
                    Color.clear.frame(height: min(natural, room))
                }
            }
            if let nudge {
                Rectangle()
                    .fill(Palette.hairline.opacity(0.55))
                    .frame(height: 1)
                Button {
                    if CommandBar.run(nudge.url, in: browser) { browser.dismiss() }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: nudge.glyph.isEmpty ? "clock.arrow.circlepath" : nudge.glyph)
                        Text(nudge.key).lineLimit(1)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .frame(height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
        // No outline in the light. A card this size separates itself by
        // sitting above the page, and the shadow is the only thing that says
        // so — one tight shadow for the edge, one wide one for the lift.
        // Fork (ux): in the dark the card's ground and the dimmed page are
        // near the same grey and a shadow barely shows: a pixel of light
        // edge and a deeper shadow hold it.
        .overlay {
            if scheme == .dark {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1 / max(displayScale, 1))
                    .allowsHitTesting(false)
            }
        }
        // Fork (perf, r4): Core Animation shadows with their path given, not
        // SwiftUI's: a 48 pt shadow of the card's whole content was drawn
        // off-screen on every frame the card moved or changed.
        .background(CardShadow(dark: scheme == .dark, radius: 13))
    }

    /// The card's two shadows — one tight for the edge, one wide for the
    /// lift — as layers whose shape is said up front (`shadowPath`), so the
    /// render server blurs a rounded rectangle instead of the card's pixels.
    struct CardShadow: NSViewRepresentable {
        let dark: Bool
        let radius: CGFloat

        func makeNSView(context: Context) -> NSView { Lift() }
        func updateNSView(_ view: NSView, context: Context) {
            guard let lift = view as? Lift else { return }
            lift.corner = radius
            lift.dark = dark
        }

        final class Lift: NSView {
            var corner: CGFloat = 13 { didSet { needsLayout = true } }
            var dark = false { didSet { if dark != oldValue { needsLayout = true } } }
            private let edge = CALayer(), wide = CALayer()

            init() {
                super.init(frame: .zero)
                wantsLayer = true
                layer?.masksToBounds = false
                for shadow in [wide, edge] {
                    shadow.shadowColor = NSColor.black.cgColor
                    layer?.addSublayer(shadow)
                }
            }

            required init?(coder: NSCoder) { fatalError("no coder") }

            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            override func layout() {
                super.layout()
                let path = CGPath(roundedRect: bounds, cornerWidth: corner, cornerHeight: corner, transform: nil)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                // Unflipped: a negative height is down the screen.
                for (shadow, opacity, blur, drop) in [(edge, dark ? 0.32 : 0.09, 3.0, 1.0), (wide, dark ? 0.5 : 0.26, 48.0, 20.0)] {
                    shadow.frame = bounds
                    shadow.shadowPath = path
                    shadow.shadowOpacity = Swift.Float(opacity)
                    shadow.shadowRadius = blur // SwiftUI's .shadow radius, 1:1
                    shadow.shadowOffset = CGSize(width: 0, height: -drop)
                }
                CATransaction.commit()
            }
        }
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
        let keyed = CommandPalette.keyed(browser.offers)
        let tint = self.tint
        return ScrollViewReader { reader in
            ScrollView(.vertical, showsIndicators: false) {
                // Fork (perf): each row keyed by what it is rather than where
                // it is, and drawn again only when it changed (Row is
                // Equatable): a letter typed lays out the rows that are new,
                // not the dozen under the field. Fork (perf, r4): a plain
                // stack for a short list (the resting card's seven rows), laid
                // out in one go; lazy past it.
                Group {
                    if keyed.count <= CommandPalette.plainRows {
                        VStack(alignment: .leading, spacing: 1) { list(keyed, tint: tint) }
                    } else {
                        LazyVStack(alignment: .leading, spacing: 1) { list(keyed, tint: tint) }
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
                guard let picked, keyed.indices.contains(picked) else { return }
                withAnimation(Motion.quick) { reader.scrollTo(keyed[picked].id) }
            }
        }
    }

    /// At most this many rows are laid out at once rather than lazily.
    static let plainRows = 8

    @ViewBuilder
    private func list(_ keyed: [(id: String, index: Int, offer: Suggestion)], tint: SpaceTint) -> some View {
        ForEach(keyed, id: \.id) { item in
            let index = item.index, offer = item.offer
            // A section's heading and its first row scroll as
            // one, so Tab back round to the top shows the label
            // too, not just the row under it.
            VStack(alignment: .leading, spacing: 1) {
                if let heading = sections.headings[index] {
                    Text(heading)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 12)
                        .frame(height: CommandPalette.headingHeight, alignment: .bottomLeading)
                        .padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                }
                if index < CommandPalette.slice || laid.contains(item.id) {
                    Row(offer: offer, picked: browser.picked == index, tint: tint.mark, fill: tint.dot, stamp: marks.landed,
                        aside: bar.launching && browser.picked == index ? Launcher.aside(for: offer, in: browser) : "")
                        .equatable()
                        .contentShape(Rectangle())
                        .onTapGesture { browser.take(offer) }
                } else {
                    // Its place, until the next pass lays it out.
                    Color.clear.frame(height: CommandPalette.height(offer))
                }
            }
        }
    }

    /// Fork (perf): each row's identity — the tab, the address and the kind
    /// of row — so a row that only moved keeps its view; the rare repeat
    /// gets a count.
    static func keyed(_ offers: [Suggestion]) -> [(id: String, index: Int, offer: Suggestion)] {
        var seen: [String: Int] = [:]
        return offers.enumerated().map { index, offer in
            let base = "\(offer.kind)|\(offer.tab?.uuidString ?? "")|\(offer.url.absoluteString)"
            let count = seen[base, default: 0]
            seen[base] = count + 1
            return (count == 0 ? base : "\(base)#\(count)", index, offer)
        }
    }

    /// Fork (ux): a title that says its site twice or more — "GitHub · …
    /// · GitHub · GitHub" — says it once: a " · " part already said earlier
    /// in the title is dropped.
    /// Fork (polish r5): and a title ending in a bare separator ("Copper -")
    /// loses it.
    static func tidy(_ title: String) -> String {
        let bare = trimSeparators(title)
        let parts = bare.components(separatedBy: " · ")
        guard parts.count > 1 else { return bare }
        var seen: Set<String> = []
        let kept = parts.filter { seen.insert($0.trimmingCharacters(in: .whitespaces).lowercased()).inserted }
        return kept.count == parts.count ? bare : kept.joined(separator: " · ")
    }

    private static let separators: [String] = [" - ", " — ", " – ", " | ", " · "]

    private static func trimSeparators(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespaces)
        while let last = text.last, "-—–|·".contains(last), text.count > 1 {
            text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// Fork (polish r5): a title's first part, before its first separator —
    /// what a narrow tab shows ("Copper — Wikipedia" → "Copper").
    static func head(_ title: String) -> String {
        let cut = separators.compactMap { title.range(of: $0)?.lowerBound }.min()
        guard let cut, cut > title.startIndex else { return title }
        return String(title[..<cut])
    }

    /// As tall as the rows.
    private var natural: CGFloat {
        let offers = browser.offers, resting = state.typed.isEmpty
        // Fork (observe): the resting rows come a pass after the card
        // (Browser.fillSoon); until then it is as tall as the last one was.
        if offers.isEmpty, resting, let held = CommandPalette.resting[bar.launching] { return held }
        let rows = offers.reduce(CGFloat(0)) { $0 + CommandPalette.height($1) + 1 }
        let headings = CGFloat(sections.headings.keys.filter { $0 < offers.count }.count)
        let height = rows + headings * (CommandPalette.headingHeight + 3) + 16
        if resting, !offers.isEmpty { CommandPalette.resting[bar.launching] = height }
        return height
    }

    /// Fork (observe): the resting card's height, ⌘T's (true) and ⌘K's apart.
    static var resting: [Bool: CGFloat] = [:]

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

    private struct Row: View, Equatable {
        static func == (a: Row, b: Row) -> Bool {
            a.offer == b.offer && a.picked == b.picked && a.tint == b.tint && a.fill == b.fill && a.stamp == b.stamp && a.aside == b.aside
        }

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

        private var twoLine: Bool { CommandPalette.twoLine(offer) }

        var body: some View {
            HStack(spacing: 11) {
                Mark(offer: offer, tint: tint, picked: picked, stamp: stamp)
                    .frame(width: 18, height: 18)

                // One weight, picked or not. Going semibold on the selected
                // row widened it enough to squeeze the muted half out of the
                // row — the pill and the tinted ↩ say "selected" without
                // moving anything.
                //
                // Fork (uitype): a page's host goes on a line of its own under
                // the title, so neither cuts the other short; the title is the
                // first thing given room.
                VStack(alignment: .leading, spacing: 1) {
                    Text(CommandPalette.tidy(offer.key))
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if twoLine {
                        HStack(spacing: 6) {
                            Text(offer.detail)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            // Last to give way: see Suggestion.badge.
                            if !offer.badge.isEmpty {
                                Text(offer.badge).lineLimit(1).fixedSize()
                            }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                    }
                }
                .layoutPriority(1)

                // A command's or a search's one line keeps its quiet half beside it.
                if !twoLine {
                    if !offer.detail.isEmpty {
                        Text(offer.detail)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                    if !offer.badge.isEmpty {
                        Text(offer.badge)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }

                Spacer(minLength: 14)

                // Fork (uitype): one column at the right, and only on the row
                // Return would take (or the one under the pointer) — laid out
                // on every row it held the titles short of room they had.
                if picked || hovering {
                    HStack(spacing: 10) {
                        if !aside.isEmpty {
                            Text(aside)
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.muted)
                        }
                        if !offer.hint.isEmpty {
                            Text(offer.hint)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(picked ? tint : Palette.muted)
                        }
                        // The key that does it, as a key: on the row Return takes.
                        if picked {
                            Text("↩")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(tint)
                                .frame(width: 22, height: 18)
                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Palette.ground.opacity(0.7)))
                                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1))
                                .accessibilityHidden(true)
                        }
                    }
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: CommandPalette.height(offer))
            .background {
                if picked {
                    // The space's colour, not a grey: a pale grey on a white
                    // card read as hover, not as "Return takes this".
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(fill.opacity(scheme == .dark ? 0.12 : 0.22)) // Fork (uitype): 0.24 was a heavy brown in the dark
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
            case .open where AgentTabs.find(offer.tab)?.pin != nil:
                // Fork (hc6): a pin wears the mark its pin square wears (Gmail's M, not the sign-in page's G).
                RowMark(icon: AgentTabs.find(offer.tab)?.pinMark, tint: SpaceTint(scheme).offColumn)
            default:
                // The same mark the sidebar row wears — icon, or a globe until
                // it lands — so a site looks like itself on both surfaces. On
                // the card's ground, not the column's: a toned-dark column's
                // light letter would vanish on a white card.
                RowMark(icon: Marks.key(for: offer.url).flatMap { Favicons.shared.cached($0) },
                        tint: SpaceTint(scheme).offColumn)
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
