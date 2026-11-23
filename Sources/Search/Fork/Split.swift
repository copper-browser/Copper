import SwiftUI

// Two pages side by side. The row of tabs is unchanged: one tab is the
// active one, as ever, and a second — `side` — is shown beside it. Everything
// that acts on "the tab" (⌘L, ⌘W, find, reader) still acts on the active one;
// clicking into the other pane makes that one active, so focus follows the
// pointer without a second notion of selection anywhere.

@MainActor
final class Split: ObservableObject {
    static let shared = Split()
    @Published private(set) var side: Tab.ID?
    /// Fraction of the stage the left pane takes.
    @Published var fraction: CGFloat = 0.5
    /// The window whose stage shows the side pane. One split at a time, in
    /// one window: the rows are shared across windows (Fork: windows), and a
    /// second window on the same space must not also draw the pane — a web
    /// view has one superview. Nil between splits.
    private(set) weak var holder: Browser?

    var on: Bool { side != nil }

    /// Whether this window's stage is the one with the pane.
    func on(in browser: Browser) -> Bool { side != nil && holder === browser }

    /// Another window took the tab in the pane (Spaces.claim): the pane
    /// closes, the pair is kept for when either half is picked again.
    func release(_ id: Tab.ID) {
        guard side == id else { return }
        sleeping = nil
        side = nil
        swapped = false
        holder = nil
        landing = false
        still = nil
        picturing = false
        covering = false
        incoming = false
    }

    /// Which tabs are kept side by side, both ways round. Arc's split views
    /// are sidebar items: you leave one by picking another tab and come back
    /// to it by picking either half. A pair is made by opening a split and
    /// ends when the split is closed; it rides in the session (`Entry.split`).
    @Published private(set) var pairs: [Tab.ID: Tab.ID] = [:] {
        didSet { SplitPairs.shared.update(Set(pairs.keys)) } // Fork (motion): the column marks both halves
    }

    private func pair(_ a: Tab.ID, _ b: Tab.ID) {
        unpair(a); unpair(b)
        pairs[a] = b
        pairs[b] = a
    }

    private func unpair(_ id: Tab.ID?) {
        guard let id, let other = pairs.removeValue(forKey: id) else { return }
        pairs[other] = nil
    }

    /// The same token on both halves of a pair, for the session — nil when
    /// the tab has no partner among `alive`.
    func token(for id: Tab.ID, alive: Set<Tab.ID>) -> UUID? {
        guard let other = pairs[id], alive.contains(other) else { return nil }
        return min(id.uuidString, other.uuidString) == id.uuidString ? id : other
    }

    /// Restoring: tabs that came back carrying the same token are a pair.
    /// Only the first two of a token count; the pane holds two.
    func restore(_ tokens: [UUID: [Tab.ID]]) {
        pairs = [:]
        side = nil
        swapped = false
        holder = nil
        keep(tokens)
    }

    /// Pairs from an import, on top of the ones already kept.
    func keep(_ tokens: [UUID: [Tab.ID]]) {
        for ids in tokens.values where ids.count >= 2 { pair(ids[0], ids[1]) }
    }

    /// After a restore or a space switch: if the tab in front was kept in a
    /// split, open it again.
    func resume(in browser: Browser) {
        guard side == nil, let active = browser.activeID, let other = pairs[active],
              let tab = browser.tabs.first(where: { $0.id == other }),
              !Spaces.shared.shown(tab, outside: browser) else { return }
        side = other
        swapped = false
        holder = browser
        if !tab.wake() { tab.revive() }
    }

    /// ⌘⇧D. Splits with the tab to the right of the active one (or the
    /// left, at the end of the row); a second press closes the split.
    func toggle(in browser: Browser) {
        // The pane is this window's: a second press here closes it. A split
        // another window holds moves here instead (one split at a time).
        if side != nil, holder === browser { close(); return }
        guard let here = browser.tabs.firstIndex(where: { $0.id == browser.activeID }), browser.tabs.count > 1 else {
            browser.announce("Nothing to split with — open another tab")
            return
        }
        // The neighbour, unless another window is showing it.
        let candidates = [here + 1, here - 1].filter { browser.tabs.indices.contains($0) }.map { browser.tabs[$0] }
        guard let other = candidates.first(where: { !Spaces.shared.shown($0, outside: browser) }) else {
            browser.announce("The tab beside this one is open in another window")
            return
        }
        open(with: other, in: browser)
    }

    /// Fork (ui-flows): a split just made, before its pane has slid in. The
    /// stage draws the new card at no width while this is set and glides it
    /// out to the fraction (`SplitStage`); a split coming back (`resume`)
    /// is simply there.
    @Published var growing = false
    /// Fork (motion): the pane is still gliding in — its toolbar keeps its
    /// cross until it has landed, so a click mid-glide can't hit it.
    @Published var landing = false
    /// Fork (uiflows r4): the cover over the pair while the new pane slides
    /// in (`SplitStage.cover`): the old page as it was, and the new pane's
    /// card sliding over it from the right. Both pages take their final
    /// frames under it at once, so nothing on screen is cropped mid-move or
    /// re-wraps in a jump; it fades off once the left page has drawn at its
    /// new width (`landed`).
    @Published var covering = false
    /// The incoming card is still off to the right of the pair.
    @Published var incoming = false

    /// Fork (motion): the page that was on screen, as it looked before the
    /// split made it narrower — the cover's picture.
    @Published private(set) var still: (id: Tab.ID, picture: NSImage)?
    /// The picture is asked for and not back yet: the glide waits for it
    /// (`SplitStage`), since the web view takes its new width the moment the
    /// glide starts and a picture taken after that is cut to it.
    private(set) var picturing = false

    func open(with tab: Tab, in browser: Browser) {
        guard tab.id != browser.activeID else { return }
        Pace.step("split.open")
        growing = !on(in: browser)
        landing = growing || landing
        // Fork (polish r5): Reduce Motion takes no picture — the split cuts
        // straight to its final layout (`SplitStage.slide`).
        if growing, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let left = browser.active, let web = left.built, !web.unpainted, web.bounds.width > 1 {
            let id = left.id
            picturing = true
            web.takeSnapshot(with: nil) { [weak self] image, _ in
                MainActor.assumeIsolated {
                    guard let self, self.picturing, self.growing else { return } // Fork (polish r5): late, the pages have re-wrapped
                    self.picturing = false
                    if let image, self.landing { self.still = (id, image) }
                }
            }
        }
        // A tab on another window's stage is handed over first, as select
        // would; that window lands on another of its own.
        Spaces.shared.claim(tab, for: browser)
        if side != nil, holder !== browser { side = nil; swapped = false }
        if let active = browser.activeID { pair(active, tab.id) }
        side = tab.id
        holder = browser
        tab.touch()
        // Fork (r7 motion): a split that slides in builds the new pane's page
        // once the card has landed (`wakeSide`), under the cover — built in
        // the key's pass, it held the slide's first frame back ~70 ms.
        // The cover goes up with the stage, its card off to the right, so the
        // slide can start as the stage first draws (`SplitStage.slide`).
        if growing, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            sleeping = tab.id
            covering = true
            incoming = true
        } else if !tab.wake() {
            tab.revive()
        }
    }

    /// The new pane's tab, its page not built yet: the card is still sliding.
    private var sleeping: Tab.ID?

    /// The card has landed (or Reduce Motion cut straight there): the new
    /// pane's page is built and loads under the cover.
    func wakeSide(in browser: Browser) {
        guard let id = sleeping else { return }
        sleeping = nil
        guard id == side, let tab = browser.tabs.first(where: { $0.id == id }) else { return }
        Pace.step("split.wake")
        if !tab.wake() { tab.revive() }
    }

    func close() { unpair(side); side = nil; swapped = false; holder = nil; landing = false; still = nil; picturing = false; covering = false; incoming = false; sleeping = nil }

    /// Fork (motion): the pane has slid in. Its cross can show, and the
    /// cover comes off once the page under it has drawn at its new width —
    /// it took that width when the slide began, so by now it has.
    /// WebKit says when through a name outside the public framework; one
    /// that doesn't answer gets a fixed beat.
    func landed(in browser: Browser) {
        wakeSide(in: browser)
        landing = false
        picturing = false
        incoming = false
        // Fork (polish r5): the pages still at their old widths (the picture
        // is late) — they take the new ones when it is back, and the cover
        // comes off once the left page has re-wrapped (`watchRewrap`).
        if growing { return }
        if rewrapped || still == nil { uncover(); return }
        let id = still?.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            MainActor.assumeIsolated { if self?.still?.id == id { self?.uncover() } }
        }
    }

    /// The left page has drawn at its new width since the slide began.
    private var rewrapped = false

    /// Fork (uiflows r4): asked as the slide begins, the moment the left
    /// page takes its new width — the next frame WebKit presents is the
    /// re-wrapped page. Asked at the end instead, an idle page has nothing
    /// to present and the cover waited out its fixed beat.
    func watchRewrap(in browser: Browser) {
        rewrapped = false
        let next = NSSelectorFromString("_doAfterNextPresentationUpdate:")
        guard let id = still?.id, let web = browser.tabs.first(where: { $0.id == id })?.built, web.responds(to: next) else {
            rewrapped = true
            return
        }
        let block: @convention(block) () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.still?.id == id else { return }
                self.rewrapped = true
                if !self.landing { self.uncover() }
            }
        }
        web.perform(next, with: block)
    }

    /// At once once the card has landed — one swap of the left page's wrap
    /// reads better than two wraps of one text crossing (and keeps the whole
    /// move under 300 ms). Fork (polish r5): the cover and its card's label
    /// go in one transaction with animations off — an inherited fade left
    /// the label ghosting over the painted page for two frames.
    private func uncover() {
        guard covering else { return }
        Pace.step("split.uncover")
        var now = Transaction()
        now.disablesAnimations = true
        withTransaction(now) { covering = false; still = nil }
    }

    /// The cross on a pane's own toolbar. The tab goes, the split goes with
    /// it, and the other pane's page is what you are left looking at — which
    /// is the only outcome that doesn't need explaining.
    func dismiss(_ tab: Tab, in browser: Browser) {
        let other = tab.id == side ? browser.active : browser.tabs.first { $0.id == side }
        unpair(tab.id)
        side = nil
        sleeping = nil
        swapped = false
        holder = nil
        landing = false
        still = nil
        picturing = false
        covering = false
        incoming = false
        browser.close(tab)
        if let other, other.id != tab.id, browser.tabs.contains(where: { $0.id == other.id }) {
            browser.select(other)
        }
    }

    /// The name the stage measures the handle's drag against.
    static let space = "split.stage"

    /// The space's colours, for the live pane's outline (its mark, the
    /// colour its chip and header already wear) and the ground the cards sit
    /// on — never the system's blue, which belongs to no space.
    func tint(dark: Bool) -> SpaceTint {
        SpaceTint(space: Spaces.shared.space(in: holder ?? Windows.current), dark: dark)
    }

    /// Which pane a tab is in: left (active), right (side), or nowhere.
    func has(_ id: Tab.ID?) -> Bool { id != nil && id == side }

    /// Called when a tab's page is clicked, and by a pane's own toolbar.
    /// Nothing to do but select it: selecting is what trades the panes over.
    func touched(_ tab: Tab, in browser: Browser) {
        guard tab.id == side else { return }
        browser.select(tab)
    }

    /// `tab` is about to become the live one. If it is the tab already in the
    /// side pane, the panes trade places here — in the same breath as the
    /// selection, before anything redraws.
    ///
    /// Doing it afterwards, off the stage's `onChange`, leaves one frame in
    /// which the active tab and the side tab are the same tab. Both panes ask
    /// for that one page, a web view can only live in one of them, and the
    /// pane that loses the fight is blank from then on. That is the whole
    /// reason this is called from `Browser.select` rather than from the view.
    func arriving(_ tab: Tab, in browser: Browser) {
        guard tab.id == side, holder === browser, let was = browser.activeID, was != tab.id,
              browser.tabs.contains(where: { $0.id == was })
        else { return partner(of: tab, in: browser) }
        side = was
        swapped.toggle()
    }

    /// Picking a tab that is not in the side pane: its own partner comes up
    /// beside it, or, with none, it is shown on its own — the split it left
    /// is still there for when either half is picked again. Another
    /// window's pane is left alone, and a partner on another window's stage
    /// stays there.
    private func partner(of tab: Tab, in browser: Browser) {
        guard !pairs.isEmpty else { return }
        if side != nil, holder !== browser { return }
        var other = pairs[tab.id].flatMap { id in browser.tabs.first { $0.id == id } }
        if let found = other, Spaces.shared.shown(found, outside: browser) { other = nil }
        guard other?.id != side else { return }
        swapped = false
        side = other?.id
        holder = other == nil ? nil : browser
        if let other, !other.wake() { other.revive() }
    }

    /// The side pane sits right unless a swap put the old active there.
    @Published private(set) var swapped = false

    /// Selecting a third tab replaces the active pane, as it always did.
    /// Closing either pane's tab ends the split.
    ///
    /// Selecting the tab that is *already* in the side pane doesn't end the
    /// split — it moves the focus into that pane. The two trade places as it
    /// happens, so the outline moves across the window and neither page does.
    /// That is what a click into the other pane does, and `⌘⌥→` and
    /// `bench select` come down the same road, so they behave the same way
    /// without knowing anything about panes.
    func reconcile(_ browser: Browser, was: Tab.ID? = nil) {
        guard let side, holder === browser else { return }
        guard browser.tabs.contains(where: { $0.id == side }) else { self.side = nil; holder = nil; return }
        guard side == browser.activeID else {
            // A tab made active without `select` (a close, a new tab): the
            // pane beside it is its partner's or nobody's.
            if !pairs.isEmpty, let active = browser.activeID, pairs[active] != side {
                self.side = pairs[active].flatMap { id in browser.tabs.contains { $0.id == id } ? id : nil }
                swapped = false
            }
            return
        }
        if let was, was != side, browser.tabs.contains(where: { $0.id == was }) {
            self.side = was
            swapped.toggle()
        } else {
            self.side = nil
        }
    }
}

/// Fork (motion): which tabs are kept in a split, for the column's rows. An
/// object of its own: a row watching `Split` would redraw on every point of
/// a handle drag (`fraction`).
@MainActor
final class SplitPairs: ObservableObject {
    static let shared = SplitPairs()
    @Published private(set) var ids: Set<Tab.ID> = []

    func update(_ next: Set<Tab.ID>) { if next != ids { ids = next } }
}

extension Tab {
    /// The stage tells the split when a page was clicked.
    static var touched: ((Tab) -> Void)?
}

/// The page area: one page, or two cards with air between them.
///
/// The pair floats — a margin around, a gutter down the middle, the space's
/// colour washed behind so the cards read as cards rather than as a window
/// sawn in half. Only the live one is outlined.
struct SplitStage: View {
    let browser: Browser
    @ObservedObject var split = Split.shared
    @ObservedObject var spaces = Spaces.shared
    let active: Tab
    /// Fork (page-frame): the sidebar layout, where the stage is a card (or
    /// two) inset in the space's ground, which the window draws behind it.
    var inset = false
    /// Fork (uitype): the top-tab layout, page on screen (not immersed): the
    /// page is the same card there, on the split's ground, a margin all round.
    var framed = false
    @Environment(\.colorScheme) private var scheme

    /// The page is a card: beside the column, or alone under the strip (a
    /// pair there keeps its own cards, margin and ground).
    private var card: Bool { inset || (framed && !paired) }

    /// How far the page area spills past the window's top and bottom edges.
    /// Zero in a sane layout; see `PaneSpill`.
    @State private var spill = PaneSpill.none
    @ObservedObject private var agent = Agent.shared
    @ObservedObject private var trace = Drive.shared
    @ObservedObject private var sheer = Sheer.shared

    /// The stage, and the agent's pane beside it when it is open — the one
    /// conversation, where whatever drives the page (Jev, an agent on the
    /// loopback server, a linked bot) shows as a card. It takes its width
    /// from the page, never from the sidebar.
    var body: some View {
        HStack(spacing: card ? SplitMetrics.gutter : 0) {
            driven
            if agent.open {
                if !card { Rectangle().fill(Palette.hairline).frame(width: 1) }
                AgentSlot(browser: browser) // Fork (addons): the slot's addon, else AgentPane (Fork/Addons/AddonUI.swift)
                    .modifier(PaneCard(on: card))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        // Fork (page-frame): inset, the page and the pane are cards on the
        // space's ground, with the margin round them (not left of them: the
        // column is the margin there).
        .padding(inset ? EdgeInsets(top: SplitMetrics.margin, leading: 0, bottom: SplitMetrics.margin, trailing: SplitMetrics.margin) : EdgeInsets())
        // Fork (uitype): framed, the one page (or page and pane) sits in the
        // split's own margin and ground — the pair keeps its own (below).
        .padding(card && !inset ? SplitMetrics.margin : 0)
        .background { if card && !inset { backdrop } }
        .animation(Motion.glide, value: agent.open)
    }

    /// The page area while something else has the wheel: the pill in the
    /// corner and a warm line just inside the edge, so it is never a surprise
    /// that the page is moving on its own. Both go the moment the run ends.
    ///
    /// Both wear the colour of the agent whose hands are on the tab in view
    /// (Hands.swift), and the bar sits top right naming it and its thread.
    /// A run on some other tab is the corner pill alone (no ring: this page
    /// is not the one moving), naming that tab and going to it on a click.
    private var driven: some View {
        let shown = [active.id] + (split.side.map { [$0] } ?? [])
        let here = shown.flatMap { trace.hands(on: $0) }
        // Fork (agent-ux): only the tab being driven wears the ring; another
        // tab's run is the pill alone, naming that tab.
        let onShown = trace.live && trace.run.map { shown.contains($0.tabID) } == true
        let ring = here.first.map { Drive.colour(for: $0.who).fill.opacity(0.6) }
            ?? DriveStyle.accent.opacity(onShown ? 0.35 : 0)
        return stage
            .overlay {
                RoundedRectangle(cornerRadius: split.on || card ? SplitMetrics.corner : 0, style: .continuous)
                    .strokeBorder(ring, lineWidth: here.isEmpty ? 1.5 : 2)
                    .allowsHitTesting(false)
            }
            // Fork (agent-ux): one place for either, top right, 8 pt in — and
            // none while the agent pane is open: its live band has the Stop.
            // Fork (ui-flows): in the sidebar layout it sits in the column's
            // foot instead (DriveSlot), off the site's own top right.
            .overlay(alignment: .topTrailing) {
                if agent.open || inset {
                    EmptyView()
                } else if !here.isEmpty {
                    HandBar(tabs: shown).padding(8).transition(.opacity)
                } else if trace.live {
                    DrivePill(browser: browser, elsewhere: !onShown).padding(8).transition(.opacity)
                }
            }
            .animation(Motion.quick, value: trace.live)
            .animation(Motion.quick, value: here.map(\.id))
    }

    /// Two pages on the stage.
    private var paired: Bool { split.on(in: browser) && split.side.map { id in browser.tabs.contains { $0.id == id } } == true }

    @ViewBuilder
    private var stage: some View {
        if split.on(in: browser), let id = split.side, let side = browser.tabs.first(where: { $0.id == id }) {
            let left = split.swapped ? side : active
            let right = split.swapped ? active : side
            // Inset, the window's margin is the pair's: no second one inside it.
            let margin = inset ? 0 : SplitMetrics.margin
            GeometryReader { geo in
                // What the fraction divides: the width left once the margins
                // and the gutter have taken theirs.
                let span = max(geo.size.width - 2 * margin - SplitMetrics.gutter, 1)
                // And the height, once the margins and whatever the stage
                // hangs off the window have taken theirs.
                let tall = max(geo.size.height - spill.top - spill.bottom - 2 * margin, 1)
                let least = min(SplitMetrics.least, span / 2)
                // Growing (the old page's picture not back yet), the old page
                // keeps the whole width: a web view resized before its picture
                // is taken is pictured at the new width (Fork: uiflows r4).
                let leftWidth = split.growing ? span : min(span - least, max(least, span * split.fraction))

                ZStack(alignment: .topLeading) {
                    HStack(spacing: SplitMetrics.gutter) {
                        card(left, CGSize(width: leftWidth, height: tall))
                        card(right, CGSize(width: span - leftWidth, height: tall))
                    }
                    // An overlay, not a sibling: only an overlay lands over the pages' AppKit layers.
                    .overlay(alignment: .topLeading) {
                        if split.covering {
                            // The card at its landed width: while growing the pages keep their old ones.
                            cover(left: min(span - least, max(least, span * split.fraction)), span: span, tall: tall, incoming: right)
                        }
                    }
                    .padding(.horizontal, margin)
                    .padding(.top, margin + spill.top)
                    .padding(.bottom, margin + spill.bottom)

                    SplitHandle(span: span, inset: margin)
                        .frame(height: tall + 2 * margin)
                        .offset(
                            x: margin + leftWidth + SplitMetrics.gutter / 2 - SplitMetrics.grip / 2,
                            y: spill.top
                        )
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .background(PaneSpill.probe { spill = $0 })
            }
            .background { if !inset { backdrop } }
            .coordinateSpace(name: Split.space)
            .onAppear(perform: slide)
            .onChange(of: browser.activeID) { was, _ in split.reconcile(browser, was: was) }
            .onChange(of: browser.tabs.map(\.id)) { _, _ in split.reconcile(browser) }
        } else if card {
            PageCard(tab: active)
        } else {
            Page(tab: active)
        }
    }

    /// Fork (uiflows r4, polish r5): the new pane's card slides in over the
    /// old page the moment the split is made (160 ms, an ease-out) while the
    /// old page's picture is taken alongside. Only the cover moves, a card
    /// drawn by SwiftUI, so no web view is resized mid-move.
    /// Fork (r7 motion): nothing else runs while it moves. The pages take
    /// their final frames, and the new pane's page is built, once the card
    /// has landed (`settle`) — re-framed mid-slide (the picture landing, or
    /// a 120 ms beat), the pass that did it froze the slide and it cut.
    /// Reduce Motion: no slide and no cover, a cut to the final layout.
    private func slide() {
        guard split.growing else { return }
        var now = Transaction()
        now.disablesAnimations = true
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            withTransaction(now) { split.growing = false }
            split.landed(in: browser)
            return
        }
        Pace.step("split.slide")
        // Fork (r7 motion): in the stage's own first pass — the cover came up
        // with it, its card off to the right (`Split.open`); a pass later, the
        // slide's first frame waited for a second layout of the whole stage.
        if !split.covering || !split.incoming {
            withTransaction(now) {
                split.covering = true
                split.incoming = true
            }
        }
        withAnimation(.easeOut(duration: 0.16), completionCriteria: .logicallyComplete) {
            split.incoming = false
        } completion: {
            settle()
        }
    }

    /// The card has landed: both pages take their final frames under the
    /// cover (the new one's page is built now), and it comes off once the
    /// left one has re-wrapped. A picture still out by now is not waited for.
    private func settle() {
        guard split.growing, split.covering else { return split.landed(in: browser) }
        Pace.step("split.settle")
        var now = Transaction()
        now.disablesAnimations = true
        withTransaction(now) { split.growing = false }
        split.wakeSide(in: browser)
        DispatchQueue.main.async {
            split.watchRewrap(in: browser)
            split.landed(in: browser)
        }
    }

    /// The cover: the page as it was, across the pair, and the new pane's
    /// card (its ground, mark and title, as it looks before its page paints)
    /// sliding from the right edge to its place. Never hit-tested.
    private func cover(left: CGFloat, span: CGFloat, tall: CGFloat, incoming tab: Tab) -> some View {
        let width = max(span - left, 1)
        return ZStack(alignment: .topLeading) {
            if let picture = split.still?.picture {
                Image(nsImage: picture)
                    .resizable()
                    .frame(width: picture.size.width, height: picture.size.height)
                    .frame(width: span + SplitMetrics.gutter, height: tall, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: SplitMetrics.corner, style: .continuous))
            }
            SplitGhost(tab: tab)
                .background(PageCard.plate(lifted: false))
                .overlay { PageCard.edge }
                .frame(width: width, height: tall)
                .offset(x: left + SplitMetrics.gutter + (split.incoming ? width : 0))
        }
        // The pair's own width: the card waits just past its right edge.
        .frame(width: span + SplitMetrics.gutter, height: tall, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The ground the cards sit on: the window's own, with the space's colour
    /// over it — enough that a white page reads as a card laid on something
    /// rather than as the window with two lines scratched into it.
    private var backdrop: some View {
        ZStack {
            if !sheer.on(in: browser) { Palette.ground } // Fork (sheer): over the window's glass, the wash alone
            wash
        }
    }

    /// The top-tab layout's ground for the pair: the space's own colour
    /// half over the window's, so the gutter is the space's and not a blue
    /// nobody chose. (Inset, the window draws the space's ground itself.)
    private var wash: Color { SpaceTint(space: spaces.space(in: browser), dark: scheme == .dark).ground.opacity(0.5) } // Fork (uitype): this window's space, split or not

    private func card(_ tab: Tab, _ size: CGSize) -> some View {
        SplitCard(
            browser: browser,
            tab: tab,
            live: tab.id == browser.activeID,
            tint: split.tint(dark: scheme == .dark).mark.opacity(0.6), // Fork (polish r5): was 0.85 at 1.5 pt
            size: CGSize(width: max(size.width, 1), height: max(size.height, 1)),
            landed: !split.landing
        )
    }
}
