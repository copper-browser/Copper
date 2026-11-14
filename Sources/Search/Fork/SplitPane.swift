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

    var body: some View {
        Page(tab: tab)
            .environment(\.pageCorners, PageCorners(radius: SplitMetrics.corner, bottomOnly: true))
            .frame(width: size.width, height: max(size.height - SplitMetrics.bar, 1))
            .padding(.top, SplitMetrics.bar)
            .frame(width: size.width, height: size.height)
            .background(plate)
            .overlay(alignment: .top) { SplitBar(browser: browser, tab: tab, live: live) }
            .overlay { edge }
            .animation(Motion.quick, value: live)
    }

    /// The card's own ground, and the only thing carrying the shadow — put the
    /// shadow on the subtree instead and the page inside it loses its place.
    private var plate: some View { PageCard.plate(lifted: live) }

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

/// A pane's own hairline toolbar: where it has been, what it is, and the
/// cross that ends it.
struct SplitBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    let live: Bool

    var body: some View {
        // The doors are PaneDoor, the same square the agent's and Jev's
        // headers draw, at 24 here since the bar is only 32 tall.
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

            Spacer(minLength: 2)

            HStack(spacing: 5) {
                Mark(icon: tab.icon, letter: tab.monogram, size: 13, dim: !live)
                Text(name)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink.opacity(live ? 0.8 : 0.62)) // Fork (page-frame): the other pane's title at AA (muted was 2.7:1)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
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
        }
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
