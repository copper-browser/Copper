import SwiftUI

// Two or three pages side by side, or stacked. The row of tabs is unchanged:
// one tab is the active one, as ever, and the others in its split are shown
// beside (or under) it. Everything that acts on "the tab" (⌘L, ⌘W, find,
// reader) still acts on the active one; clicking into another pane makes
// that one active, so focus follows the pointer without a second notion of
// selection anywhere.
//
// Fork (ardia split): a split is up to three panes in one order on screen —
// a row or a stack — each with its share of the room. Picking a pane only
// moves the outline; the panes stay where they are.

/// One kept split: its tabs in screen order (left to right, or top to
/// bottom when stacked) and each one's share of the span, summing to 1.
struct SplitLayout: Identifiable, Equatable {
    var id = UUID()
    var tabs: [Tab.ID]
    var stacked = false
    var shares: [CGFloat]

    init(id: UUID = UUID(), tabs: [Tab.ID], stacked: Bool = false, shares: [CGFloat]? = nil) {
        self.id = id
        self.tabs = tabs
        self.stacked = stacked
        let sum = shares?.reduce(0, +) ?? 0
        self.shares = shares.flatMap { $0.count == tabs.count && sum > 0 && $0.allSatisfy { $0 > 0 } ? $0.map { $0 / sum } : nil }
            ?? Self.even(tabs.count)
    }

    static func even(_ count: Int) -> [CGFloat] { Array(repeating: 1 / CGFloat(max(count, 1)), count: count) }

    mutating func insert(_ id: Tab.ID, at index: Int) {
        tabs.insert(id, at: min(max(index, 0), tabs.count))
        shares = Self.even(tabs.count)
    }

    /// Out, its room shared by the rest in proportion.
    mutating func remove(_ id: Tab.ID) {
        guard let i = tabs.firstIndex(of: id) else { return }
        tabs.remove(at: i)
        shares.remove(at: i)
        let sum = shares.reduce(0, +)
        shares = sum > 0 ? shares.map { $0 / sum } : Self.even(tabs.count)
    }
}

/// Fork (ardia split): where a tab sits in its kept split, in the session
/// (`Session.Entry.pane`). Older files have none: their pairs come back
/// side by side, evenly.
struct SplitSlot: Codable, Equatable, Sendable {
    var at: Int
    var stacked: Bool? = nil
    var share: Double? = nil
}

@MainActor
final class Split: ObservableObject {
    static let shared = Split()
    /// Ardia's limit, and about what a laptop screen holds.
    nonisolated static let most = 3

    /// Every kept split. Arc's split views are sidebar items: you leave one by
    /// picking another tab and come back to it by picking any of its panes. A
    /// split is made by opening one and ends when it is closed (or separated);
    /// it rides in the session (`Entry.split`, `Entry.pane`).
    @Published private(set) var kept: [SplitLayout] = [] {
        didSet {
            var next: [Tab.ID: UUID] = [:]
            for layout in kept { for id in layout.tabs { next[id] = layout.id } }
            index = next
            SplitPairs.shared.update(Set(next.keys)) // Fork (motion): the column marks every pane
        }
    }
    /// Which kept split each tab is in.
    private(set) var index: [Tab.ID: UUID] = [:]

    /// The kept split on `holder`'s stage, nil between splits.
    @Published private(set) var live: UUID?
    /// The window whose stage shows the split. One split at a time, in one
    /// window: the rows are shared across windows (Fork: windows), and a
    /// second window on the same space must not also draw the panes — a web
    /// view has one superview.
    private(set) weak var holder: Browser?

    /// The live split, as kept.
    var layout: SplitLayout? { live.flatMap { id in kept.first { $0.id == id } } }
    /// The tabs on the stage, in screen order — the active one among them.
    var panes: [Tab.ID] { layout?.tabs ?? [] }
    var stacked: Bool { layout?.stacked ?? false }
    var shares: [CGFloat] { layout?.shares ?? [] }

    var on: Bool { live != nil }

    /// Whether this window's stage is the one with the panes.
    func on(in browser: Browser) -> Bool { live != nil && holder === browser }

    /// Whether `id` is in a pane on `browser`'s stage.
    func shows(_ id: Tab.ID, in browser: Browser) -> Bool { holder === browser && panes.contains(id) }

    /// Whether a tab is in one of the panes on screen.
    func has(_ id: Tab.ID?) -> Bool { id.map(panes.contains) ?? false }

    /// The first pane that isn't the live one (the bench's `side`).
    var side: Tab.ID? { panes.first { $0 != holder?.activeID } }

    func layout(of id: Tab.ID) -> SplitLayout? { index[id].flatMap { key in kept.first { $0.id == key } } }

    private func edit(_ id: UUID?, _ change: (inout SplitLayout) -> Void) {
        guard let id, let i = kept.firstIndex(where: { $0.id == id }) else { return }
        change(&kept[i])
    }

    /// A tab is in one split at most: out of any it was in. A split left
    /// with one tab ends, and leaves the stage if it was there.
    private func free(_ id: Tab.ID) {
        guard let key = index[id], let i = kept.firstIndex(where: { $0.id == key }) else { return }
        var layout = kept[i]
        layout.remove(id)
        if layout.tabs.count < 2 {
            kept.remove(at: i)
            if live == key { hide() }
        } else {
            kept[i] = layout
        }
    }

    /// Off the stage, kept.
    private func hide() {
        guard live != nil || holder != nil else { return }
        live = nil
        holder = nil
        landing = false
        still = nil
        picturing = false
        covering = false
        incoming = false
        sleeping = nil
    }

    private func show(_ layout: SplitLayout, in browser: Browser) {
        live = layout.id
        holder = browser
        for id in layout.tabs where id != browser.activeID {
            if let tab = browser.tabs.first(where: { $0.id == id }), !tab.wake() { tab.revive() }
        }
    }

    /// Every pane of `layout` is in this window's row and on no other
    /// window's stage — else the split isn't drawn and the tab shows alone.
    private func showable(_ layout: SplitLayout, in browser: Browser) -> Bool {
        layout.tabs.allSatisfy { id in
            guard let tab = browser.tabs.first(where: { $0.id == id }) else { return false }
            return id == browser.activeID || !Spaces.shared.shown(tab, outside: browser)
        }
    }

    /// Another window took a tab in the panes (Spaces.claim): the split
    /// leaves the stage, kept for when one of its tabs is picked again.
    func release(_ id: Tab.ID) {
        guard panes.contains(id) else { return }
        hide()
    }

    /// The same token on every pane of a kept split, and the tab's place in
    /// it, for the session — nil when it has no partner among `alive`.
    func session(for id: Tab.ID, alive: Set<Tab.ID>) -> (token: UUID?, slot: SplitSlot?) {
        guard let layout = layout(of: id) else { return (nil, nil) }
        let living = layout.tabs.indices.filter { alive.contains(layout.tabs[$0]) }
        guard living.count >= 2, let at = living.firstIndex(where: { layout.tabs[$0] == id }) else { return (nil, nil) }
        let sum = living.reduce(0) { $0 + layout.shares[$1] }
        let share = sum > 0 ? Double(layout.shares[living[at]] / sum) : 1 / Double(living.count)
        return (layout.id, SplitSlot(at: at, stacked: layout.stacked ? true : nil, share: (share * 1000).rounded() / 1000))
    }

    /// Restoring: tabs that came back carrying the same token are a split,
    /// in the order and shape their slots say.
    func restore(_ tokens: [UUID: [Tab.ID]], slots: [Tab.ID: SplitSlot] = [:]) {
        hide()
        kept = []
        keep(tokens, slots: slots)
    }

    /// Splits from an import (or a restore), on top of the ones already kept.
    func keep(_ tokens: [UUID: [Tab.ID]], slots: [Tab.ID: SplitSlot] = [:]) {
        for (token, found) in tokens where found.count >= 2 {
            var ids = found
            let placed = ids.compactMap { slots[$0] }
            if placed.count == ids.count { ids.sort { slots[$0]!.at < slots[$1]!.at } }
            ids = Array(ids.prefix(Self.most))
            let shares = ids.compactMap { slots[$0]?.share }.map { CGFloat($0) }
            for id in ids { free(id) }
            kept.append(SplitLayout(id: token, tabs: ids, stacked: placed.contains { $0.stacked == true },
                                    shares: shares.count == ids.count ? shares : nil))
        }
    }

    /// After a restore or a space switch: if the tab in front was kept in a
    /// split, open it again.
    func resume(in browser: Browser) {
        guard live == nil, let active = browser.activeID, let layout = layout(of: active), showable(layout, in: browser) else { return }
        show(layout, in: browser)
    }

    /// ⌘⇧D. Splits with the tab to the right of the active one (or the
    /// left, at the end of the row); a second press closes the split.
    func toggle(in browser: Browser) {
        // The panes are this window's: a second press here closes them. A
        // split another window holds moves here instead (one split at a time).
        if on(in: browser) { close(); return }
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
    /// out to its share (`SplitStage`); a split coming back (`resume`) is
    /// simply there.
    @Published var growing = false
    /// Fork (motion): the pane is still gliding in — its toolbar keeps its
    /// cross until it has landed, so a click mid-glide can't hit it.
    @Published var landing = false
    /// Fork (uiflows r4): the cover over the pair while the new pane slides
    /// in (`SplitStage.cover`): the old page as it was, and the new pane's
    /// card sliding over it from its edge. Both pages take their final
    /// frames under it at once, so nothing on screen is cropped mid-move or
    /// re-wraps in a jump; it fades off once the old page has drawn at its
    /// new size (`landed`).
    @Published var covering = false
    /// The incoming card is still off the edge of the pair.
    @Published var incoming = false

    /// Fork (motion): the page that was on screen, as it looked before the
    /// split made it smaller — the cover's picture.
    @Published private(set) var still: (id: Tab.ID, picture: NSImage)?
    /// The picture is asked for and not back yet: the glide waits for it
    /// (`SplitStage`), since the web view takes its new size the moment the
    /// glide starts and a picture taken after that is cut to it.
    private(set) var picturing = false

    /// A split made with `tab` beside the page in front — at `edge` of it
    /// (Fork: ardia split; a sidebar row let go at the page's left edge goes
    /// left, at its bottom edge under it). With a split already on this
    /// window's stage, the tab joins it as one more pane at that end.
    func open(with tab: Tab, in browser: Browser, at edge: Edge = .trailing) {
        guard tab.id != browser.activeID else { return }
        let first = edge == .leading || edge == .top
        if on(in: browser) { return join(tab, at: first ? 0 : panes.count, in: browser) }
        guard let anchor = browser.active else { return }
        Pace.step("split.open")
        // A tab on another window's stage is handed over first, as select
        // would; that window lands on another of its own. Another window's
        // split leaves its stage (one split at a time).
        Spaces.shared.claim(tab, for: browser)
        if live != nil, holder !== browser { hide() }
        growing = true
        landing = true
        // Fork (polish r5): Reduce Motion takes no picture — the split cuts
        // straight to its final layout (`SplitStage.slide`).
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let web = anchor.built, !web.unpainted, web.bounds.width > 1 {
            let id = anchor.id
            picturing = true
            web.takeSnapshot(with: nil) { [weak self] image, _ in
                MainActor.assumeIsolated {
                    guard let self, self.picturing, self.growing else { return } // Fork (polish r5): late, the pages have re-wrapped
                    self.picturing = false
                    if let image, self.landing { self.still = (id, image) }
                }
            }
        }
        free(anchor.id)
        free(tab.id)
        let layout = SplitLayout(tabs: first ? [tab.id, anchor.id] : [anchor.id, tab.id], stacked: edge == .top || edge == .bottom)
        kept.append(layout)
        live = layout.id
        holder = browser
        gather(tab, beside: anchor, after: !first, in: browser)
        tab.touch()
        // Fork (r7 motion): a split that slides in builds the new pane's page
        // once the card has landed (`wakeSide`), under the cover — built in
        // the key's pass, it held the slide's first frame back ~70 ms.
        // The cover goes up with the stage, its card off the edge, so the
        // slide can start as the stage first draws (`SplitStage.slide`).
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            sleeping = tab.id
            covering = true
            incoming = true
        } else if !tab.wake() {
            tab.revive()
        }
    }

    /// Fork (ardia split): one more pane in the split on this window's
    /// stage, at `position` — no slide, the panes take even shares.
    private func join(_ tab: Tab, at position: Int, in browser: Browser) {
        guard let layout, !layout.tabs.contains(tab.id) else { return }
        guard layout.tabs.count < Self.most else {
            browser.announce("A split holds three panes")
            return
        }
        Pace.step("split.join")
        Spaces.shared.claim(tab, for: browser)
        free(tab.id)
        let at = min(max(position, 0), layout.tabs.count)
        edit(layout.id) { $0.insert(tab.id, at: at) }
        let anchorID = at > 0 ? layout.tabs[at - 1] : layout.tabs[0]
        if let anchor = browser.tabs.first(where: { $0.id == anchorID }) { gather(tab, beside: anchor, after: at > 0, in: browser) }
        tab.touch()
        if !tab.wake() { tab.revive() }
    }

    /// Fork (ardia split): ⌥-click on a link — it opens in a new pane beside
    /// the page it was clicked in (a background tab once the split is full).
    func openLink(_ url: URL, from source: Tab, in browser: Browser) {
        let tab = browser.open(url, foreground: false)
        if on(in: browser), let at = panes.firstIndex(of: source.id) {
            guard panes.count < Self.most else { return browser.announce("Opened in a new tab — a split holds three panes") }
            join(tab, at: at + 1, in: browser)
        } else if source.id == browser.activeID {
            open(with: tab, in: browser)
        } else {
            browser.announce("Opened in the background")
        }
    }

    /// Fork (ardia split): a split is one row in the column
    /// (`GroupedRows.merged`) — a tab joining it moves in beside the pane it
    /// joins, into the same block and folder. A pin stays in the grid; its
    /// split is marked on the rows instead.
    private func gather(_ tab: Tab, beside anchor: Tab, after: Bool, in browser: Browser) {
        guard tab.pin == nil, anchor.pin == nil,
              let from = browser.tabs.firstIndex(where: { $0.id == tab.id }),
              let to = browser.tabs.firstIndex(where: { $0.id == anchor.id }),
              abs(from - to) != 1 || Sections.shared.isSaved(tab) != Sections.shared.isSaved(anchor)
        else { return }
        let sections = Sections.shared
        let groups = Groups.shared
        let saved = sections.isSaved(anchor)
        if sections.isSaved(tab) != saved { sections.set(tab, saved: saved, in: browser) }
        if groups.membership[tab.id] != groups.membership[anchor.id] {
            if let folder = groups.membership[anchor.id] { groups.restore(tab, group: folder) } else { groups.remove(tab) }
        }
        guard let here = browser.tabs.firstIndex(where: { $0.id == tab.id }),
              let there = browser.tabs.firstIndex(where: { $0.id == anchor.id }) else { return }
        let target = after ? (here < there ? there : there + 1) : (here < there ? there - 1 : there)
        if target != here { browser.move(tab, to: target) }
    }

    /// The new pane's tab, its page not built yet: the card is still sliding.
    private var sleeping: Tab.ID?

    /// The card has landed (or Reduce Motion cut straight there): the new
    /// pane's page is built and loads under the cover.
    func wakeSide(in browser: Browser) {
        guard let id = sleeping else { return }
        sleeping = nil
        guard panes.contains(id), let tab = browser.tabs.first(where: { $0.id == id }) else { return }
        Pace.step("split.wake")
        if !tab.wake() { tab.revive() }
    }

    /// ⇧⌘D on a split, Close Split View, Separate All Panes: the split ends
    /// and its tabs go back to being tabs. The one in front stays in front.
    func close() {
        let key = live
        hide()
        kept.removeAll { $0.id == key }
    }

    /// Fork (ardia split): one pane out of the split, its tab kept. The pane
    /// you are in leaving means you go with it: it shows alone, and the rest
    /// stay kept together.
    func separate(_ tab: Tab, in browser: Browser) {
        guard shows(tab.id, in: browser) else { return }
        if panes.count <= 2 { return close() }
        free(tab.id)
        if tab.id == browser.activeID { hide() }
    }

    /// Fork (ardia split): the panes in the other order.
    func flip() { edit(live) { $0.tabs.reverse(); $0.shares.reverse() } }

    /// Fork (ardia split): side by side ↔ stacked.
    func rotate() { edit(live) { $0.stacked.toggle() } }

    /// Fork (ardia split): every pane the same size (a double-click on a divider).
    func even() { edit(live) { $0.shares = SplitLayout.even($0.tabs.count) } }

    /// The divider after pane `divider` pulled to `at` points along the span
    /// (gutters taken out), each pane kept at least `least` points.
    func pull(_ divider: Int, to at: CGFloat, span: CGFloat, least: CGFloat) {
        let span = max(span, 1)
        let next = Self.pulled(shares, divider: divider, to: at / span, least: least / span)
        guard next != shares else { return }
        edit(live) { $0.shares = next }
    }

    /// The shares once the divider after pane `i` is at `at` (a fraction of
    /// the span from its start). Only the two panes it parts change, and
    /// neither gets less than `least`.
    nonisolated static func pulled(_ shares: [CGFloat], divider i: Int, to at: CGFloat, least: CGFloat) -> [CGFloat] {
        guard i >= 0, shares.indices.contains(i + 1) else { return shares }
        let before = shares[..<i].reduce(0, +)
        let pair = shares[i] + shares[i + 1]
        let least = min(least, pair / 2)
        let cut = min(before + pair - least, max(before + least, at))
        var out = shares
        out[i] = cut - before
        out[i + 1] = before + pair - cut
        return out
    }

    /// Each pane's length along a span: its share, but never under `least`
    /// (taken from the panes with room to spare, in proportion) — a window
    /// made small doesn't squeeze one pane to nothing.
    nonisolated static func lengths(_ shares: [CGFloat], span: CGFloat, least: CGFloat) -> [CGFloat] {
        guard !shares.isEmpty else { return [] }
        let sum = shares.reduce(0) { $0 + max($1, 0) }
        let fair = sum > 0 ? shares.map { max($0, 0) / sum } : SplitLayout.even(shares.count)
        let least = min(least, span / CGFloat(shares.count))
        var out = fair.map { $0 * span }
        let short = Set(out.indices.filter { out[$0] < least })
        guard !short.isEmpty else { return out }
        let need = short.reduce(0) { $0 + least - out[$1] }
        let room = out.indices.filter { !short.contains($0) }.reduce(0) { $0 + out[$1] - least }
        for i in out.indices {
            out[i] = short.contains(i) ? least : out[i] - (out[i] - least) / max(room, 0.0001) * need
        }
        return out
    }

    /// Fork (motion): the pane has slid in. Its cross can show, and the
    /// cover comes off once the page under it has drawn at its new size —
    /// it took that size when the slide began, so by now it has.
    /// WebKit says when through a name outside the public framework; one
    /// that doesn't answer gets a fixed beat.
    func landed(in browser: Browser) {
        wakeSide(in: browser)
        landing = false
        picturing = false
        incoming = false
        // Fork (polish r5): the pages still at their old sizes (the picture
        // is late) — they take the new ones when it is back, and the cover
        // comes off once the old page has re-wrapped (`watchRewrap`).
        if growing { return }
        if rewrapped || still == nil { uncover(); return }
        let id = still?.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            MainActor.assumeIsolated { if self?.still?.id == id { self?.uncover() } }
        }
    }

    /// The old page has drawn at its new size since the slide began.
    private var rewrapped = false

    /// Fork (uiflows r4): asked as the slide begins, the moment the old
    /// page takes its new size — the next frame WebKit presents is the
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

    /// At once once the card has landed — one swap of the old page's wrap
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

    /// The cross on a pane's own toolbar. The tab goes, and with it the
    /// split if only one pane is left — whose page is what you are left
    /// looking at, the only outcome that doesn't need explaining.
    func dismiss(_ tab: Tab, in browser: Browser) {
        let rest = panes.filter { $0 != tab.id }
        let wasActive = tab.id == browser.activeID
        if panes.count <= 2 { close() } else { free(tab.id) }
        browser.close(tab)
        if wasActive, let next = rest.compactMap({ id in browser.tabs.first { $0.id == id } }).first {
            browser.select(next)
        }
    }

    /// The name the stage measures the handles' drags against.
    static let space = "split.stage"

    /// The space's colours, for the live pane's outline (its mark, the
    /// colour its chip and header already wear) and the ground the cards sit
    /// on — never the system's blue, which belongs to no space.
    func tint(dark: Bool) -> SpaceTint {
        SpaceTint(space: Spaces.shared.space(in: holder ?? Windows.current), dark: dark)
    }

    /// Called when a tab's page is clicked, and by a pane's own toolbar.
    /// Nothing to do but select it: the outline moves, the panes don't.
    func touched(_ tab: Tab, in browser: Browser) {
        guard shows(tab.id, in: browser), tab.id != browser.activeID else { return }
        browser.select(tab)
    }

    /// `tab` is about to become the live one (`Browser.select`). A pane of
    /// the split on screen: nothing moves but the outline. Any other tab:
    /// its own split comes up around it, or, with none, it is shown on its
    /// own — the split it left is kept for when one of its tabs is picked
    /// again. Another window's split is left alone, and a split with a pane
    /// on another window's stage stays off this one.
    func arriving(_ tab: Tab, in browser: Browser) {
        guard !shows(tab.id, in: browser), !kept.isEmpty else { return }
        if live != nil, holder !== browser { return }
        guard let layout = layout(of: tab.id), showable(layout, in: browser) else { return hide() }
        show(layout, in: browser)
    }

    /// The window's tabs or its active tab changed without `select` (a
    /// close, a new tab, a space switch). A pane's tab that was closed
    /// leaves the split (two left, the split stays); a pane gone to another
    /// space, or an active tab outside the split, takes it off the stage.
    func reconcile(_ browser: Browser, was: Tab.ID? = nil) {
        guard live != nil, holder === browser else { return }
        let missing = panes.filter { id in !browser.tabs.contains { $0.id == id } }
        if !missing.isEmpty {
            let alive = Set(Spaces.shared.everyTab.map(\.id))
            for id in missing where !alive.contains(id) { free(id) }
            if live != nil, panes.contains(where: { id in !browser.tabs.contains { $0.id == id } }) { hide() }
        }
        guard live != nil, let active = browser.activeID, !panes.contains(active) else { return }
        if let layout = layout(of: active), showable(layout, in: browser) { show(layout, in: browser) } else { hide() }
    }
}

/// Fork (motion): which tabs are kept in a split, for the column's rows. An
/// object of its own: a row watching `Split` would redraw on every point of
/// a handle drag (`shares`).
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

/// The page area: one page, or two or three cards with air between them.
///
/// The cards float — a margin around, a gutter between, the space's colour
/// washed behind so they read as cards rather than as a window sawn in
/// pieces. Only the live one is outlined.
struct SplitStage: View {
    let browser: Browser
    @ObservedObject var split = Split.shared
    @ObservedObject var spaces = Spaces.shared
    let active: Tab
    /// Fork (page-frame): the sidebar layout, where the stage is a card (or
    /// several) inset in the space's ground, which the window draws behind it.
    var inset = false
    /// Fork (uitype): the top-tab layout, page on screen (not immersed): the
    /// page is the same card there, on the split's ground, a margin all round.
    var framed = false
    @Environment(\.colorScheme) private var scheme

    /// The page is a card: beside the column, or alone under the strip (a
    /// split there keeps its own cards, margin and ground).
    private var card: Bool { inset || (framed && panes == nil) }

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
        // split's own margin and ground — the split keeps its own (below).
        .padding(card && !inset ? SplitMetrics.margin : 0)
        .background { if card && !inset { backdrop } }
        .animation(Motion.glide, value: agent.open)
        // Fork (ardia split): watched whether or not the panes are drawn, so
        // a split whose active tab left it (a close, a new tab) is put right.
        .onChange(of: browser.activeID) { was, _ in if split.on(in: browser) { split.reconcile(browser, was: was) } }
        .onChange(of: split.on(in: browser) ? browser.tabs.map(\.id) : []) { _, _ in split.reconcile(browser) }
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
        let shown = panes?.map(\.id) ?? [active.id]
        let here = shown.flatMap { trace.hands(on: $0) }
        // Fork (agent-ux): only the tab being driven wears the ring; another
        // tab's run is the pill alone, naming that tab.
        let onShown = trace.live && trace.run.map { shown.contains($0.tabID) } == true
        let ring = here.first.map { Drive.colour(for: $0.who).fill.opacity(0.6) }
            ?? DriveStyle.accent.opacity(onShown ? 0.35 : 0)
        return stage
            // Fork (ardia split): a sidebar row carried over the page shows
            // where its pane would go (SplitDrop), and the page area says
            // where it is, for the drag to measure against.
            .overlay { SplitDropPreview(browser: browser, tint: split.tint(dark: scheme == .dark)) }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { SplitDrop.shared.stages[ObjectIdentifier(browser)] = $0 }
            .overlay {
                RoundedRectangle(cornerRadius: panes != nil || card ? SplitMetrics.corner : 0, style: .continuous)
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

    /// The panes on this window's stage, in screen order — nil when it
    /// shows one page (no split here, or one not yet put right).
    private var panes: [Tab]? {
        guard split.on(in: browser) else { return nil }
        let tabs = split.panes.compactMap { id in browser.tabs.first { $0.id == id } }
        return tabs.count >= 2 && tabs.contains { $0.id == active.id } ? tabs : nil
    }

    @ViewBuilder
    private var stage: some View {
        if let tabs = panes {
            let stacked = split.stacked
            // Inset, the window's margin is the split's: no second one inside it.
            let margin = inset ? 0 : SplitMetrics.margin
            GeometryReader { geo in
                // What the shares divide: the room left once the margins, the
                // gutters and whatever the stage hangs off the window have
                // taken theirs.
                let width = max(geo.size.width - 2 * margin, 1)
                let tall = max(geo.size.height - spill.top - spill.bottom - 2 * margin, 1)
                let span = max((stacked ? tall : width) - SplitMetrics.gutter * CGFloat(tabs.count - 1), 1)
                let least = stacked ? SplitMetrics.leastTall : SplitMetrics.least
                let landed = Split.lengths(split.shares, span: span, least: least)
                // Growing (the old page's picture not back yet), the old page
                // keeps the whole span: a web view resized before its picture
                // is taken is pictured at the new size (Fork: uiflows r4).
                let lengths = split.growing ? tabs.map { $0.id == active.id ? span : 0 } : landed
                let row = stacked ? AnyLayout(VStackLayout(spacing: SplitMetrics.gutter)) : AnyLayout(HStackLayout(spacing: SplitMetrics.gutter))

                ZStack(alignment: .topLeading) {
                    // One layout either way round, so a rotate keeps each
                    // card (and its page) where SwiftUI has it.
                    row {
                        ForEach(Array(tabs.enumerated()), id: \.element.id) { i, tab in
                            let length = lengths.indices.contains(i) ? lengths[i] : 0
                            card(tab, stacked ? CGSize(width: width, height: length) : CGSize(width: length, height: tall))
                        }
                    }
                    .frame(width: width, height: tall, alignment: .topLeading)
                    // An overlay, not a sibling: only an overlay lands over the pages' AppKit layers.
                    .overlay(alignment: .topLeading) {
                        if split.covering, let incoming = tabs.firstIndex(where: { $0.id != active.id }) {
                            // The card at its landed size: while growing the pages keep their old ones.
                            cover(tabs[incoming], at: incoming, lengths: landed, width: width, tall: tall, stacked: stacked)
                        }
                    }
                    .padding(.horizontal, margin)
                    .padding(.top, margin + spill.top)
                    .padding(.bottom, margin + spill.bottom)

                    ForEach(0..<(tabs.count - 1), id: \.self) { i in
                        // The middle of the gutter after pane i.
                        let at = margin + lengths.prefix(i + 1).reduce(0, +) + CGFloat(i) * SplitMetrics.gutter + SplitMetrics.gutter / 2 - SplitMetrics.grip / 2
                        SplitHandle(divider: i, span: span, inset: margin + (stacked ? spill.top : 0), stacked: stacked, least: least)
                            .frame(width: stacked ? width + 2 * margin : nil, height: stacked ? nil : tall + 2 * margin)
                            .offset(x: stacked ? 0 : at, y: stacked ? spill.top + at : spill.top)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .background(PaneSpill.probe { spill = $0 })
            }
            .background { if !inset { backdrop } }
            .coordinateSpace(name: Split.space)
            .onAppear(perform: slide)
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
        // with it, its card off the edge (`Split.open`); a pass later, the
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
    /// old one has re-wrapped. A picture still out by now is not waited for.
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

    /// The cover: the page as it was, across the split, and the new pane's
    /// card (its ground, mark and title, as it looks before its page paints)
    /// sliding in from its own edge — the right (or the bottom), or the left
    /// (the top) for a pane put first. Never hit-tested.
    private func cover(_ tab: Tab, at index: Int, lengths: [CGFloat], width: CGFloat, tall: CGFloat, stacked: Bool) -> some View {
        let length = max(lengths.indices.contains(index) ? lengths[index] : 1, 1)
        let start = lengths.prefix(index).reduce(0, +) + CGFloat(index) * SplitMetrics.gutter
        // Just past the split's edge until it slides: the first pane's card waits off the leading edge.
        let away = split.incoming ? (index == 0 ? -length - SplitMetrics.gutter : length + SplitMetrics.gutter) : 0
        return ZStack(alignment: .topLeading) {
            if let picture = split.still?.picture {
                Image(nsImage: picture)
                    .resizable()
                    .frame(width: picture.size.width, height: picture.size.height)
                    .frame(width: width, height: tall, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: SplitMetrics.corner, style: .continuous))
            }
            SplitGhost(tab: tab)
                .background(PageCard.plate(lifted: false))
                .overlay { PageCard.edge }
                .frame(width: stacked ? width : length, height: stacked ? length : tall)
                .offset(x: stacked ? 0 : start + away, y: stacked ? start + away : 0)
        }
        // The split's own size: the card waits just past its edge.
        .frame(width: width, height: tall, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The ground the cards sit on: the window's own, with the space's colour
    /// over it — enough that a white page reads as a card laid on something
    /// rather than as the window with lines scratched into it.
    private var backdrop: some View {
        ZStack {
            if !sheer.on(in: browser) { Palette.ground } // Fork (sheer): over the window's glass, the wash alone
            wash
        }
    }

    /// The top-tab layout's ground for the split: the space's own colour
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

/// Fork (ardia split): a sidebar row carried over the page. Near the page's
/// left, right or bottom edge — along a split's own axis once there is one —
/// the place the new pane would take lights up; let go there and the tab
/// joins the split at that end. Over the page anywhere else, the drop is
/// nobody's and the row goes back.
@MainActor
final class SplitDrop: ObservableObject {
    static let shared = SplitDrop()

    /// Each window's page area, in SwiftUI's global space (`SplitStage`).
    var stages: [ObjectIdentifier: CGRect] = [:]
    /// Where the row in the hand would land, and the panes it would join.
    @Published private(set) var zone: Edge?
    @Published private(set) var count = 1
    private(set) weak var over: Browser?
    private var carrying: Tab.ID?
    private var inside = false

    /// How far in from an edge counts as at it, as a fraction of the page.
    nonisolated static let reach: CGFloat = 0.3

    /// The edge of `frame` a point is at, among those a split of `count`
    /// panes (1: none yet) can still grow from — nil in the middle, or when
    /// the split is full.
    nonisolated static func zone(at point: CGPoint, in frame: CGRect, count: Int, stacked: Bool) -> Edge? {
        guard frame.contains(point), count < Split.most, frame.width > 0, frame.height > 0 else { return nil }
        let edges: [Edge] = count <= 1 ? [.leading, .trailing, .bottom] : stacked ? [.top, .bottom] : [.leading, .trailing]
        func near(_ edge: Edge) -> CGFloat {
            switch edge {
            case .leading: return (point.x - frame.minX) / frame.width
            case .trailing: return (frame.maxX - point.x) / frame.width
            case .top: return (point.y - frame.minY) / frame.height
            case .bottom: return (frame.maxY - point.y) / frame.height
            }
        }
        guard let edge = edges.min(by: { near($0) < near($1) }), near(edge) <= reach else { return nil }
        return edge
    }

    /// The new pane's place in a page area of `size`: an even share along
    /// the axis, at that edge.
    nonisolated static func place(_ edge: Edge, in size: CGSize, count: Int) -> CGRect {
        let n = CGFloat(max(count, 1) + 1)
        switch edge {
        case .leading: return CGRect(x: 0, y: 0, width: size.width / n, height: size.height)
        case .trailing: return CGRect(x: size.width - size.width / n, y: 0, width: size.width / n, height: size.height)
        case .top: return CGRect(x: 0, y: 0, width: size.width, height: size.height / n)
        case .bottom: return CGRect(x: 0, y: size.height - size.height / n, width: size.width, height: size.height / n)
        }
    }

    /// The pointer moved, at `point` in SwiftUI's global space. True while
    /// it is over the page: the column then leaves the row alone.
    func hover(_ tab: Tab, at point: CGPoint, in browser: Browser) -> Bool {
        guard let frame = stages[ObjectIdentifier(browser)], frame.contains(point), tab.pin == nil else {
            clear()
            return false
        }
        let split = Split.shared
        let mine = split.on(in: browser)
        let panes = mine ? split.panes.count : 1
        let next = tab.id == browser.activeID || (mine && split.panes.contains(tab.id)) ? nil
            : Self.zone(at: point, in: frame, count: panes, stacked: mine && split.stacked)
        over = browser
        carrying = tab.id
        inside = true
        if count != panes { count = panes }
        if next != zone { withAnimation(Motion.quick) { zone = next } }
        return true
    }

    /// Let go. True when it was over the page — the drop is the split's,
    /// whether or not it made a pane.
    func drop(_ tab: Tab, in browser: Browser) -> Bool {
        let edge = zone
        let mine = inside && over === browser && carrying == tab.id
        clear()
        guard mine else { return false }
        if let edge { Split.shared.open(with: tab, in: browser, at: edge) }
        return true
    }

    func clear() {
        inside = false
        carrying = nil
        over = nil
        if zone != nil { withAnimation(Motion.quick) { zone = nil } }
    }
}

/// Fork (ardia split): where a row carried over the page would land — the
/// new pane's place, washed and ringed in the space's colour.
struct SplitDropPreview: View {
    let browser: Browser
    let tint: SpaceTint
    @ObservedObject private var drop = SplitDrop.shared

    var body: some View {
        GeometryReader { geo in
            if drop.over === browser, let edge = drop.zone {
                let place = SplitDrop.place(edge, in: geo.size, count: drop.count).insetBy(dx: SplitMetrics.margin, dy: SplitMetrics.margin)
                RoundedRectangle(cornerRadius: SplitMetrics.corner, style: .continuous)
                    .fill(tint.mark.opacity(0.16))
                    .overlay {
                        RoundedRectangle(cornerRadius: SplitMetrics.corner, style: .continuous)
                            .strokeBorder(tint.mark.opacity(0.75), lineWidth: 2)
                    }
                    .frame(width: max(place.width, 1), height: max(place.height, 1))
                    .offset(x: place.minX, y: place.minY)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(Motion.quick, value: drop.zone)
    }
}

// MARK: - the bench

extension Split {
    /// `./bench split` toggles (⇧⌘D); `split ID [left|right|top|bottom]`
    /// opens with tab ID at that edge (joins the split on screen as one more
    /// pane); `split off` / `separate` ends it, `separate ID` takes one pane
    /// out; `flip`, `rotate`, `even`, `shares A,B[,C]`; `hover ID X Y` (X, Y
    /// fractions of the page area) carries a row there as a drag from the
    /// column would, `drop ID` lets go; `link URL` is a ⌥-click on a link in
    /// the page in front; `state` only reports.
    func bench(_ arg: String, in browser: Browser) -> [String: Any] {
        let words = arg.split(separator: " ").map(String.init)
        func tab(_ key: String?) -> Tab? {
            guard let key = key?.lowercased(), !key.isEmpty else { return nil }
            return browser.tabs.first { $0.id.uuidString.lowercased().hasPrefix(key) }
        }
        var out: [String: Any] = [:]
        switch words.first ?? "" {
        case "": toggle(in: browser)
        case "state": break
        case "off": close()
        case "separate":
            if let pane = tab(words.dropFirst().first) { separate(pane, in: browser) } else { close() }
        case "flip": flip()
        case "rotate": rotate()
        case "even": even()
        case "shares":
            let values = (words.dropFirst().first ?? "").split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) }
            guard values.count == panes.count else { return ["error": "\(panes.count) shares wanted"] }
            edit(live) { $0 = SplitLayout(id: $0.id, tabs: $0.tabs, stacked: $0.stacked, shares: values) }
        case "hover":
            guard words.count >= 4, let row = tab(words[1]), let fx = Double(words[2]), let fy = Double(words[3]),
                  let frame = SplitDrop.shared.stages[ObjectIdentifier(browser)] else { return ["error": "hover ID X Y, with a page on screen"] }
            let point = CGPoint(x: frame.minX + frame.width * fx, y: frame.minY + frame.height * fy)
            out["over"] = SplitDrop.shared.hover(row, at: point, in: browser)
        case "drop":
            guard let row = tab(words.dropFirst().first) else { return ["error": "drop ID"] }
            out["dropped"] = SplitDrop.shared.drop(row, in: browser)
        case "drag":
            // drag ID X Y [hold]: real mouse events (SideHand) carry row ID from
            // the column to X,Y on the page; `sections release` lets go of a held one.
            guard words.count >= 4, let row = tab(words[1]), let fx = Double(words[2]), let fy = Double(words[3]),
                  let frame = SplitDrop.shared.stages[ObjectIdentifier(browser)], let from = SideHand.frame(of: row, in: browser)
            else { return ["error": "drag ID X Y [hold], with the row laid out"] }
            let to = CGPoint(x: frame.minX + frame.width * fx, y: frame.minY + frame.height * fy)
            SideHand.how = "view"
            out["drag"] = SideHand.drag(row, dy: to.y - from.midY, dx: to.x - from.midX, steps: 24, hold: words.contains("hold"), in: browser)
        case "link":
            guard let url = words.dropFirst().first.flatMap(URL.init(string:)), let source = browser.active else { return ["error": "link URL"] }
            openLink(url, from: source, in: browser)
        default:
            guard let other = tab(words[0]) else { return ["error": "no tab \(words[0])"] }
            let edges: [String: Edge] = ["left": .leading, "right": .trailing, "top": .top, "bottom": .bottom]
            open(with: other, in: browser, at: words.count > 1 ? edges[words[1]] ?? .trailing : .trailing)
        }
        func short(_ id: Tab.ID?) -> String { id.map { String($0.uuidString.prefix(8)).lowercased() } ?? "" }
        out["active"] = short(browser.activeID)
        out["side"] = on(in: browser) ? short(side) : ""
        out["panes"] = on(in: browser) ? panes.map(short) : []
        out["stacked"] = stacked
        out["shares"] = shares.map { (Double($0) * 1000).rounded() / 1000 }
        out["kept"] = kept.map { $0.tabs.map(short) }
        out["zone"] = SplitDrop.shared.zone.map { "\($0)" } ?? "" // a row in the hand over the page: where it would land
        // Where each pane's page is in the window (AppKit's points, from the bottom left).
        out["frames"] = panes.compactMap { id -> [String: Any]? in
            guard let web = browser.tabs.first(where: { $0.id == id })?.built, web.window != nil else { return nil }
            let r = web.convert(web.bounds, to: nil)
            return ["tab": short(id), "x": Int(r.minX.rounded()), "y": Int(r.minY.rounded()), "w": Int(r.width.rounded()), "h": Int(r.height.rounded())]
        }
        return out
    }
}

extension Split {
    /// Fork (ardia split): ⌘K's rows for a split on screen.
    static var commands: [CommandBar.Command] {
        [
            .init(id: "split-flip", name: "Flip Split Panes", glyph: "arrow.left.arrow.right") { _ in Split.shared.flip() },
            .init(id: "split-rotate", name: Split.shared.stacked ? "Put Split Panes Side by Side" : "Stack Split Panes", glyph: "rectangle.split.1x2") { _ in Split.shared.rotate() },
            .init(id: "split-even", name: "Make Split Panes Even", glyph: "equal.square") { _ in withAnimation(Motion.glide) { Split.shared.even() } },
            .init(id: "split-separate", name: "Separate All Split Panes", glyph: "rectangle.split.3x1") { _ in Split.shared.close() },
        ]
    }
}
