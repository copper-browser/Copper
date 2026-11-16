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
    /// The strip of chrome each card carries — over the page's top, and only
    /// while the pointer is in the pane's top `reach` (Fork: uiflows r4).
    static let bar: CGFloat = 32
    static let reach: CGFloat = 36
    /// A card never gets narrower than this, however far the handle is pulled.
    static let least: CGFloat = 220
    /// How wide the invisible line between the cards is to the pointer —
    /// the gutter is only 8, which is a hard thing to hit on purpose.
    static let grip: CGFloat = 18
}

/// One pane: its toolbar, its page, its outline.
struct SplitCard: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    /// The pane the keyboard is in.
    let live: Bool
    /// The space's colour, for the live pane's outline.
    let tint: Color
    /// The room the stage measured for this card. Not negotiable: see above.
    let size: CGSize
    /// Fork (motion): the pane has finished sliding in.
    var landed = true
    /// Fork (uiflows r4): the pointer is in the pane's top `reach`: its bar
    /// shows over the page (120 ms in and out). At rest the page has the
    /// whole card, as Arc's split panes do.
    @State private var near = false

    var body: some View {
        Page(tab: tab)
            .environment(\.pageCorners, PageCorners(radius: SplitMetrics.corner))
            .frame(width: size.width, height: size.height)
            .background(plate)
            .overlay(alignment: .top) {
                HoverZone { inside in withAnimation(.easeOut(duration: 0.12)) { near = inside } }
                    .frame(width: size.width, height: SplitMetrics.reach)
                    .allowsHitTesting(false) // a tracking area needs no hits; the page keeps its clicks
            }
            .overlay(alignment: .top) {
                SplitBar(browser: browser, tab: tab, live: live, landed: landed)
                    .frame(width: size.width)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: SplitMetrics.corner, topTrailingRadius: SplitMetrics.corner, style: .continuous))
                    .opacity(near ? 1 : 0)
                    .allowsHitTesting(near)
            }
            .overlay { edge }
            .animation(Motion.quick, value: live)
    }

    /// The card's own ground, and the only thing carrying the shadow — put the
    /// shadow on the subtree instead and the page inside it loses its place.
    private var plate: some View {
        PageCard.plate(lifted: live)
            .overlay { SplitWaiting(tab: tab) }
    }

    /// The live pane is outlined in the space's colour. The other is not
    /// outlined at all — that is the whole point of the outline.
    @ViewBuilder private var edge: some View {
        if live {
            RoundedRectangle(cornerRadius: SplitMetrics.corner, style: .continuous)
                .strokeBorder(tint, lineWidth: 1) // Fork (polish r5): 1 pt (the stage passes ~60%), Arc's weight
                .allowsHitTesting(false)
        } else {
            PageCard.edge
        }
    }
}

/// Fork (ui-flows): what a pane shows under its page until the page first
/// paints — the site's mark and title on the wash, never a white card. The
/// page covers it the moment WebKit has a frame (`PageView.showFirstFrame`).
struct SplitWaiting: View { // Fork (covers): also under a lone page card (PageFrame.swift)
    @ObservedObject var tab: Tab
    /// Fork (motion): the page has painted. Gone then, so it can't show
    /// through wherever a page mid-resize hasn't drawn yet. Fork (polish r5):
    /// at once — the page fades in over 120 ms (`showFirstFrame`), and an
    /// 80 ms fade of this under it read as the label ghosting over the page.
    @State private var painted: Bool
    /// Fork (r7 space): the page is whole — its fade-in is over. The wash
    /// stays under it until then: gone with the label, the card's white
    /// plate showed through the page for those 120 ms (grey, white, page).
    @State private var whole: Bool

    init(tab: Tab) {
        self.tab = tab
        let painted = tab.built.map { !$0.unpainted } ?? false
        _painted = State(initialValue: painted)
        _whole = State(initialValue: painted)
    }

    var body: some View {
        SplitGhost(tab: tab, labelled: !painted)
            .opacity(whole ? 0 : 1)
            .onAppear(perform: watch)
            .onChange(of: tab.loading) { _, _ in watch() }
    }

    private func watch() {
        guard !painted, let web = tab.built else { return }
        web.whenPainted {
            var now = Transaction()
            now.disablesAnimations = true
            withTransaction(now) { painted = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + PageView.fadeIn + 0.03) {
                withTransaction(now) { whole = true }
            }
        }
    }
}

/// A pane before its page paints: the site's mark and title on the wash.
/// Also the card that slides in when a split is made (`SplitStage.cover`).
struct SplitGhost: View {
    @ObservedObject var tab: Tab
    /// Off: the wash alone, under a page that is fading in (SplitWaiting).
    var labelled = true

    var body: some View {
        VStack(spacing: 10) {
            Mark(icon: tab.icon, size: 28)
            Text(tab.title.isEmpty ? (tab.address.map(Address.pretty) ?? "New Tab") : tab.title)
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .padding(.horizontal, 24)
        }
        .opacity(labelled ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.wash)
        .clipShape(RoundedRectangle(cornerRadius: SplitMetrics.corner, style: .continuous))
        .allowsHitTesting(false)
    }
}

/// A pane's own hairline toolbar: where it has been, what it is, and the
/// cross that ends it.
struct SplitBar: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    let live: Bool
    /// Fork (motion): the cross waits until the pane has slid in.
    var landed = true

    var body: some View {
        // The doors are PaneDoor, the same square the agent's and Jev's
        // headers draw, at 24 here since the bar is only 32 tall. The whole
        // bar shows under the pointer only (SplitCard), so they need no
        // hover of their own.
        HStack(spacing: 1) {
            doors

            Spacer(minLength: 2)

            HStack(spacing: 5) {
                Mark(icon: tab.icon, size: 13)
                Text(name)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // Fork (uiflows r4): the other pane's mark and address dim as
            // one (the mark was at 45%, its words at 70%); 0.8 × 0.82 ink
            // keeps the words at AA on the band.
            .opacity(live ? 1 : 0.82)
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

/// Fork (uiflows r4): says when the pointer comes over it and leaves, and
/// takes nothing from the page under it — a tracking area, no hit test — so
/// the page keeps its own clicks and hovers.
struct HoverZone: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> Zone { Zone() }
    func updateNSView(_ view: Zone, context: Context) { view.changed = changed }

    final class Zone: NSView {
        var changed: (Bool) -> Void = { _ in }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { changed(true) }
        override func mouseExited(with event: NSEvent) { changed(false) }
    }
}
