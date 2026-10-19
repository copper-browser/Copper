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
        side = nil
        swapped = false
        holder = nil
    }

    /// Which tabs are kept side by side, both ways round. Arc's split views
    /// are sidebar items: you leave one by picking another tab and come back
    /// to it by picking either half. A pair is made by opening a split and
    /// ends when the split is closed; it rides in the session (`Entry.split`).
    @Published private(set) var pairs: [Tab.ID: Tab.ID] = [:]

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

    func open(with tab: Tab, in browser: Browser) {
        guard tab.id != browser.activeID else { return }
        // A tab on another window's stage is handed over first, as select
        // would; that window lands on another of its own.
        Spaces.shared.claim(tab, for: browser)
        if side != nil, holder !== browser { side = nil; swapped = false }
        if let active = browser.activeID { pair(active, tab.id) }
        side = tab.id
        holder = browser
        if !tab.wake() { tab.revive() }
        tab.touch()
    }

    func close() { unpair(side); side = nil; swapped = false; holder = nil }

    /// The cross on a pane's own toolbar. The tab goes, the split goes with
    /// it, and the other pane's page is what you are left looking at — which
    /// is the only outcome that doesn't need explaining.
    func dismiss(_ tab: Tab, in browser: Browser) {
        let other = tab.id == side ? browser.active : browser.tabs.first { $0.id == side }
        unpair(tab.id)
        side = nil
        swapped = false
        holder = nil
        browser.close(tab)
        if let other, other.id != tab.id, browser.tabs.contains(where: { $0.id == other.id }) {
            browser.select(other)
        }
    }

    /// The name the stage measures the handle's drag against.
    static let space = "split.stage"

    /// The space's colour, for the live pane's outline — the accent when the
    /// space has no colour of its own, because grey would say nothing.
    var tint: Color {
        Spaces.shared.space(in: holder ?? Windows.current).hue.map { Color(hue: $0, saturation: 0.62, brightness: 0.72) } ?? Color.accentColor
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
    @ObservedObject var browser: Browser
    @ObservedObject var split = Split.shared
    @ObservedObject var spaces = Spaces.shared
    let active: Tab

    /// How far the page area spills past the window's top and bottom edges.
    /// Zero in a sane layout; see `PaneSpill`.
    @State private var spill = PaneSpill.none
    @ObservedObject private var agent = Agent.shared
    @ObservedObject private var trace = Drive.shared

    /// The stage, and the agent's pane beside it when it is open — the one
    /// conversation, where whatever drives the page (Jev, an agent on the
    /// loopback server, a linked bot) shows as a card. It takes its width
    /// from the page, never from the sidebar.
    var body: some View {
        HStack(spacing: 0) {
            driven
            if agent.open {
                Rectangle().fill(Palette.hairline).frame(width: 1)
                AgentSlot(browser: browser) // Fork (addons): the slot's addon, else AgentPane (Fork/Addons/AddonUI.swift)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Motion.glide, value: agent.open)
    }

    /// The page area while something else has the wheel: the pill in the
    /// corner and a warm line just inside the edge, so it is never a surprise
    /// that the page is moving on its own. Both go the moment the run ends.
    ///
    /// Both wear the colour of the agent whose hands are on the tab in view
    /// (Hands.swift), and the bar sits top centre naming it and its thread.
    /// A run on some other tab keeps the old corner pill, so a Jev loop in a
    /// background tab still says it is going and can still be stopped.
    private var driven: some View {
        let shown = [active.id] + (split.side.map { [$0] } ?? [])
        let here = shown.flatMap { trace.hands(on: $0) }
        let ring = here.first.map { Drive.colour(for: $0.who).fill.opacity(0.6) }
            ?? DriveStyle.accent.opacity(trace.live ? 0.35 : 0)
        return stage
            .overlay {
                RoundedRectangle(cornerRadius: split.on ? SplitMetrics.corner : 0, style: .continuous)
                    .strokeBorder(ring, lineWidth: here.isEmpty ? 1.5 : 2)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                if !here.isEmpty { HandBar(tabs: shown).padding(.top, 8).transition(.move(edge: .top).combined(with: .opacity)) }
            }
            .overlay(alignment: .topTrailing) {
                if trace.live, here.isEmpty { DrivePill().padding(8).transition(.opacity) }
            }
            .animation(Motion.quick, value: trace.live)
            .animation(Motion.quick, value: here.map(\.id))
    }

    @ViewBuilder
    private var stage: some View {
        if split.on(in: browser), let id = split.side, let side = browser.tabs.first(where: { $0.id == id }) {
            let left = split.swapped ? side : active
            let right = split.swapped ? active : side
            GeometryReader { geo in
                // What the fraction divides: the width left once the margins
                // and the gutter have taken theirs.
                let span = max(geo.size.width - 2 * SplitMetrics.margin - SplitMetrics.gutter, 1)
                // And the height, once the margins and whatever the stage
                // hangs off the window have taken theirs.
                let tall = max(geo.size.height - spill.top - spill.bottom - 2 * SplitMetrics.margin, 1)
                let least = min(SplitMetrics.least, span / 2)
                let leftWidth = min(span - least, max(least, span * split.fraction))

                ZStack(alignment: .topLeading) {
                    HStack(spacing: SplitMetrics.gutter) {
                        card(left, CGSize(width: leftWidth, height: tall))
                        card(right, CGSize(width: span - leftWidth, height: tall))
                    }
                    .padding(.horizontal, SplitMetrics.margin)
                    .padding(.top, SplitMetrics.margin + spill.top)
                    .padding(.bottom, SplitMetrics.margin + spill.bottom)

                    SplitHandle(span: span, inset: SplitMetrics.margin)
                        .frame(height: tall + 2 * SplitMetrics.margin)
                        .offset(
                            x: SplitMetrics.margin + leftWidth + SplitMetrics.gutter / 2 - SplitMetrics.grip / 2,
                            y: spill.top
                        )
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .background(PaneSpill.probe { spill = $0 })
            }
            .background(backdrop)
            .coordinateSpace(name: Split.space)
            .onChange(of: browser.activeID) { was, _ in split.reconcile(browser, was: was) }
            .onChange(of: browser.tabs.map(\.id)) { _, _ in split.reconcile(browser) }
        } else {
            Page(tab: active)
        }
    }

    /// The ground the cards sit on: the window's own, with the space's colour
    /// over it — enough that a white page reads as a card laid on something
    /// rather than as the window with two lines scratched into it.
    private var backdrop: some View {
        ZStack {
            Palette.ground
            wash
        }
    }

    /// Deliberately stronger than the sidebar's wash. The sidebar's job is to
    /// stay behind the tabs; this one has to be seen in a 7pt margin.
    private var wash: Color { split.tint.opacity(0.22) }

    private func card(_ tab: Tab, _ size: CGSize) -> some View {
        SplitCard(
            browser: browser,
            tab: tab,
            live: tab.id == browser.activeID,
            tint: split.tint,
            wash: wash,
            size: CGSize(width: max(size.width, 1), height: max(size.height, 1))
        )
    }
}
