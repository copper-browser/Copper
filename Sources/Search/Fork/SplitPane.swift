import SwiftUI

// What a split pane looks like. The model is in Split.swift; this is the card
// it is drawn as — a rounded page with its own hairline toolbar, floating in
// the page area with the space's colour washed behind it.
//
// Arc's split is not two pages meeting at a line. It is two cards with air
// around them, and the one you are typing into is the one wearing the
// outline. Everything here exists to say which of the two is live without
// spending a word on it.
//
// Two things to know before editing.
//
// `Page` is a WKWebView in SwiftUI's clothing. It has no size of its own and
// takes whatever height it is offered, so a card built out of padding grows
// taller than the room it was given and its margins fall off both ends of the
// window — which is exactly what the first cut of this did. Every frame here
// is therefore a number, handed down from the stage's GeometryReader, not a
// padding and a hope.
//
// A web view is also a real AppKit layer: `.clipShape` does not round it, and
// wrapping the subtree that holds it in `.clipShape` or `.shadow` hands it the
// wrong frame again. So the card never clips or shadows the subtree — the
// page's bottom corners are cut on the stage's own layer (`PageCorners`,
// Fork/PageFrame.swift), the shadow belongs to the background shape alone,
// and the toolbar is an overlay, which does land on top of an AppKit layer
// where a sibling would not. (The corners used to be painted back out in the
// colour behind the card, which a picture or a gradient behind it defeats.)

enum SplitMetrics {
    /// The air between the two cards.
    static let gutter: CGFloat = 8
    /// The air around the pair, inside the page area.
    static let margin: CGFloat = 7
    /// A card's corner. Between Arc's and the window's own.
    static let corner: CGFloat = 11
    /// The strip of chrome each card carries.
    static let bar: CGFloat = 32
    /// A card never gets narrower than this, however far the handle is pulled.
    static let least: CGFloat = 220
    /// How wide the invisible line between the cards is to the pointer —
    /// the gutter is only 8, which is a hard thing to hit on purpose.
    static let grip: CGFloat = 18
}

/// One pane: its toolbar, its page, its outline.
struct SplitCard: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    /// The pane the keyboard is in.
    let live: Bool
    /// The space's colour, for the live pane's outline.
    let tint: Color
    /// The room the stage measured for this card. Not negotiable: see above.
    let size: CGSize
    /// Fork (motion): the toolbar's height — none at the start of a split's
    /// glide, growing to `SplitMetrics.bar` with it.
    var bar: CGFloat = SplitMetrics.bar
    /// Fork (motion): the pane has finished gliding in.
    var landed = true
    /// Fork (motion): the page as it was before the split narrowed it, over
    /// the page while it re-wraps (`Split.still`).
    var still: NSImage?

    var body: some View {
        Page(tab: tab)
            .environment(\.pageCorners, PageCorners(radius: SplitMetrics.corner, bottomOnly: true))
            .frame(width: size.width, height: max(size.height - bar, 1))
            .padding(.top, bar)
            .frame(width: size.width, height: size.height)
            .background(plate)
            .overlay(alignment: .topLeading) { picture }
            .overlay(alignment: .top) {
                // Fork (motion): cut to the card, so a pane still narrow
                // mid-glide shows part of its bar, never a pile of it.
                SplitBar(browser: browser, tab: tab, live: live, landed: landed)
                    .frame(width: size.width, height: bar, alignment: .bottom)
                    .clipped()
            }
            .overlay { edge }
            .animation(Motion.quick, value: live)
    }

    /// The card's own ground, and the only thing carrying the shadow — put the
    /// shadow on the subtree instead and the page inside it loses its place.
    private var plate: some View {
        PageCard.plate(lifted: live)
            .overlay { SplitWaiting(tab: tab).padding(.top, bar) }
    }

    /// Fork (motion): drawn at its own size from the page's top-left corner
    /// and cut where the card ends — the page as it was, its right side
    /// sliding under the new pane, until the page under it has re-wrapped
    /// (`Split.landed`).
    @ViewBuilder private var picture: some View {
        if let still {
            Image(nsImage: still)
                .resizable()
                .frame(width: still.size.width, height: still.size.height)
                .frame(width: size.width, height: max(size.height - bar, 1), alignment: .topLeading)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: SplitMetrics.corner, bottomTrailingRadius: SplitMetrics.corner, style: .continuous))
                .padding(.top, bar)
                .allowsHitTesting(false)
                .transition(.identity)
        }
    }

    /// The live pane is outlined in the space's colour. The other is not
    /// outlined at all — that is the whole point of the outline.
    @ViewBuilder private var edge: some View {
        if live {
            RoundedRectangle(cornerRadius: SplitMetrics.corner, style: .continuous)
                .strokeBorder(tint, lineWidth: 1.5)
                .allowsHitTesting(false)
        } else {
            PageCard.edge
        }
    }
}

/// Fork (ui-flows): what a pane shows under its page until the page first
/// paints — the site's mark and title on the wash, never a white card. The
/// page covers it the moment WebKit has a frame (`PageView.showFirstFrame`).
private struct SplitWaiting: View {
    @ObservedObject var tab: Tab
    /// Fork (motion): the page has painted. Gone then (in 80 ms), so it can't
    /// show through wherever a page mid-resize hasn't drawn yet.
    @State private var painted: Bool

    init(tab: Tab) {
        self.tab = tab
        _painted = State(initialValue: tab.built.map { !$0.unpainted } ?? false)
    }

    var body: some View {
        waiting
            .opacity(painted ? 0 : 1)
            .onAppear(perform: watch)
            .onChange(of: tab.loading) { _, _ in watch() }
    }

    private func watch() {
        guard !painted, let web = tab.built else { return }
        web.whenPainted { withAnimation(.easeOut(duration: 0.08)) { painted = true } }
    }

    private var waiting: some View {
        VStack(spacing: 10) {
            Mark(icon: tab.icon, letter: tab.monogram, size: 28)
            Text(tab.title.isEmpty ? (tab.address.map(Address.pretty) ?? "New Tab") : tab.title)
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.wash)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: SplitMetrics.corner, bottomTrailingRadius: SplitMetrics.corner, style: .continuous))
        .allowsHitTesting(false)
    }
}

/// A pane's own hairline toolbar: where it has been, what it is, and the
/// cross that ends it.
struct SplitBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    let live: Bool
    /// Fork (motion): the cross waits until the pane has glided in.
    var landed = true
    /// Fork (motion): back, forward and reload show under the pointer only —
    /// at rest the bar is the page's address and its cross.
    @State private var over = false

    var body: some View {
        // The doors are PaneDoor, the same square the agent's and Jev's
        // headers draw, at 24 here since the bar is only 32 tall.
        HStack(spacing: 1) {
            doors
                .opacity(over ? 1 : 0)
                .allowsHitTesting(over)

            Spacer(minLength: 2)

            HStack(spacing: 5) {
                Mark(icon: tab.icon, letter: tab.monogram, size: 13, dim: !live)
                Text(name)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink.opacity(live ? 0.8 : 0.7)) // Fork (page-frame): the other pane's title at AA (muted was 2.7:1)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .fixedSize(horizontal: !landed, vertical: false) // Fork (motion): mid-glide the mark and the address never squeeze over each other
            .layoutPriority(1)

            Spacer(minLength: 2)

            HStack(spacing: 1) {
                if Agent.shared.open {
                    PaneDoor(icon: "xmark.square", help: "Close all panes (⌘⌥E)", tint: Palette.ink.opacity(0.65), size: 24) {
                        Panes.closeAll(in: browser)
                    }
                }
                PaneDoor(icon: "xmark", help: "Close this pane", tint: Palette.ink.opacity(0.65), size: 24) {
                    Split.shared.dismiss(tab, in: browser)
                }
            }
            .opacity(landed ? 1 : 0)
            .allowsHitTesting(landed)
        }
        .animation(Motion.quick, value: over)
        .animation(Motion.quick, value: landed)
        .padding(.horizontal, 7)
        .frame(height: SplitMetrics.bar)
        .background(alignment: .bottom) {
            // The bar is a band a shade off the page, the way Arc's is, so
            // chrome still reads as chrome over a white page; the hairline
            // where the two meet does the rest.
            ZStack(alignment: .bottom) {
                Palette.ground
                Palette.ink.opacity(0.05)
                Rectangle().fill(Palette.hairline).frame(height: 1)
            }
        }
        // A click anywhere on the bar is a click into the pane.
        .contentShape(Rectangle())
        .onTapGesture { Split.shared.touched(tab, in: browser) }
        .onHover { over = $0 }
    }

    private var doors: some View {
        HStack(spacing: 1) {
            PaneDoor(icon: "arrow.left", help: "Back", on: tab.canGoBack, tint: Palette.ink.opacity(0.65), size: 24) { tab.back() }
            PaneDoor(icon: "arrow.right", help: "Forward", on: tab.canGoForward, tint: Palette.ink.opacity(0.65), size: 24) { tab.forward() }
            PaneDoor(
                icon: tab.loading ? "xmark" : "arrow.clockwise",
                help: tab.loading ? "Stop" : "Reload",
                tint: Palette.ink.opacity(0.65),
                size: 24
            ) {
                tab.loading ? tab.stop() : tab.reload()
            }
        }
    }

    /// Where the pane is, not what it is called: the tab in the column already
    /// says the title, and with no address row anywhere else in the window
    /// this strip is the one place the address can be read.
    private var name: String {
        // A canvas's address is an id nobody reads; it says what it is instead.
        if let address = tab.address, let canvas = CanvasLinks.label(address) { return canvas }
        if let address = tab.address { return Address.pretty(address) }
        if !tab.title.isEmpty { return tab.title }
        return "New Tab"
    }
}

/// The line between the panes: nothing at all until the pointer finds it,
/// then a short soft bar you can pull. Double-click puts it back in the
/// middle.
struct SplitHandle: View {
    @ObservedObject var split = Split.shared
    /// The width the fraction is measured against, and where it starts.
    let span: CGFloat
    let inset: CGFloat

    @State private var over = false
    @State private var dragging = false

    var body: some View {
        let showing = over || dragging
        ZStack {
            Color.clear
            Capsule(style: .continuous)
                .fill(Palette.ink.opacity(showing ? 0.3 : 0))
                .frame(width: 4, height: 54)
        }
        .frame(width: SplitMetrics.grip)
        .contentShape(Rectangle())
        .onHover { inside in
            over = inside
            inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop()
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(Split.space))
                .onChanged { drag in
                    dragging = true
                    let least = SplitMetrics.least / max(span, 1)
                    let want = (drag.location.x - inset) / max(span, 1)
                    split.fraction = min(1 - least, max(least, want))
                }
                .onEnded { _ in dragging = false }
        )
        // Double-click is the way back to even. SwiftUI hands the two-click
        // tap to this gesture before the drag sees it, so the two do not
        // fight over the same pointer.
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                withAnimation(Motion.glide) { split.fraction = 0.5 }
            }
        )
        .animation(Motion.quick, value: showing)
    }
}

/// Fork (motion): the column's mark on both rows of a kept split — a 2 pt
/// bar in the space's colour down each row's leading edge.
struct SplitBracket: View {
    let tint: SpaceTint

    var body: some View {
        Capsule(style: .continuous)
            .fill(tint.bar)
            .frame(width: 2)
            .padding(.vertical, 7)
            .padding(.leading, 3)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
