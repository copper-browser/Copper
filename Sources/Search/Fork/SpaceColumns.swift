import SwiftUI

// Every space visited this launch keeps its column.
//
// A switch used to hand the column a new row of tabs, and SwiftUI built the
// space's name, its rows and their folders from nothing: about 100 ms of the
// main thread on a long column (perf/README.md), every switch, even back to
// a space left a second ago. Now each space the window has been to keeps
// its own column (`SpaceColumn`) laid out under the one on screen, hidden,
// and a switch only changes which one shows. Its scroll is its own too, so
// a space comes back where it was left.
//
// A hidden column must cost nothing while it waits, or this only moves the
// cost to every page load. So nothing in a column watches the browser: the
// sidebar, which watches it anyway, works out what each column shows — its
// rows, its live row, the row being renamed — and hands that in, and the
// column and its rows are equatable on it. A change to the browser redraws
// the column on screen where it changed and leaves the parked ones alone;
// a parked one is redrawn only when its own space's rows or folders change.
//
// Hidden means hidden to everything: no clicks, no hover, no drops, nothing
// for VoiceOver or the keyboard, and no frames for the wheel button or a
// drag to land on (SideTargets, SideDrag).
//
// With Trails on, Today is drawn by Trails, whose rows watch the browser
// row by row, so only the column on screen is kept, as before.

@MainActor
enum SpaceColumns {
    /// How many columns a window keeps laid out, the one on screen included:
    /// the most recently shown. `bench spaces columns N`; 1 is one column
    /// whose rows are rebuilt on every switch, as before.
    static var cap = 8

    /// Whether a window keeps more than the column on screen.
    static var keeps: Bool { cap > 1 && !Flights.trails }

    /// One window's columns, most recently shown first.
    final class Kept {
        private(set) var recent: [UUID] = []

        /// `current` goes to the front; spaces since deleted, and any past
        /// the cap, are let go. The answer is in the spaces' own order, so
        /// a column keeps its place among the others as the order of use
        /// changes and SwiftUI moves nothing.
        func mount(_ current: UUID, among all: [UUID]) -> [UUID] {
            recent.removeAll { $0 == current || !all.contains($0) }
            recent.insert(current, at: 0)
            if recent.count > SpaceColumns.cap { recent.removeLast(recent.count - SpaceColumns.cap) }
            return all.filter { recent.contains($0) }
        }
    }

    private static var kept: [ObjectIdentifier: Kept] = [:]

    static func kept(for browser: Browser) -> Kept {
        let key = ObjectIdentifier(browser)
        if let kept = kept[key] { return kept }
        let made = Kept()
        kept[key] = made
        return made
    }

    /// `spaces columns [N]`: which spaces this window keeps a column for,
    /// most recent first, and how many it may; N sets that.
    static func bench(_ words: [String], in browser: Browser) -> [String: Any] {
        if let word = words.first {
            guard let n = Int(word), n >= 1 else { return ["error": "spaces columns [N ≥ 1]"] }
            cap = n
            // The sidebar works out its columns as it draws; have it draw.
            Spaces.shared.objectWillChange.send()
        }
        let spaces = Spaces.shared
        return ["cap": cap, "keeps": keeps,
                "kept": kept(for: browser).recent.map { id in spaces.all.first { $0.id == id }?.name ?? "?" }]
    }
}

/// One space's column: its name, the rows you keep, New Tab and Today, in
/// one scroll — what `SideBar` drew for the current space, now drawn for
/// each space the window keeps (see above). Everything it shows is handed
/// in; it watches only the window's drag.
struct SpaceColumn: View, Equatable {
    let browser: Browser
    let prefs: Preferences
    @ObservedObject var drag: SideDrag
    let space: UUID
    /// On screen: the one that takes clicks, scrolls to the live row, and
    /// reports where its blocks are for a drag.
    let shown: Bool
    /// The space's loose rows, each with its place in the loose list.
    let kept: [(index: Int, tab: Tab)]
    let today: [(index: Int, tab: Tab)]
    /// The live row: the browser's on screen, the one this window last
    /// looked at in a parked space.
    let active: Tab.ID?
    let editing: Tab.ID?
    let refusals: Int
    let clearCount: Int
    let trails: Bool
    let tint: SpaceTint
    let pill: Namespace.ID
    /// A row or a favourite is in the hand: the column does not scroll.
    let held: Bool
    let reveal: Tab.ID?
    let holding: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var still

    static func == (a: SpaceColumn, b: SpaceColumn) -> Bool {
        func same(_ x: [(index: Int, tab: Tab)], _ y: [(index: Int, tab: Tab)]) -> Bool {
            x.count == y.count && zip(x, y).allSatisfy { $0.index == $1.index && $0.tab === $1.tab }
        }
        return a.browser === b.browser && a.prefs === b.prefs && a.drag === b.drag && a.space == b.space && a.shown == b.shown
            && a.active == b.active && a.editing == b.editing && a.refusals == b.refusals && a.clearCount == b.clearCount
            && a.trails == b.trails && a.tint == b.tint && a.pill == b.pill && a.held == b.held && a.reveal == b.reveal
            && same(a.kept, b.kept) && same(a.today, b.today)
    }

    /// The live row's pill is matched across the favourites and the column
    /// on screen as "live", so it glides between them; a parked column's
    /// live row wears its space's own, so there is one source for each.
    private var pillID: String { shown ? "live" : "live-\(space.uuidString)" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: SideBar.gap) {
                    SpaceHeader(browser: browser, space: space)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SavedDrop.space)) } action: { drag.place(header: $0, in: space) } // Fork (saved-drag)
                    if shown, drag.slot { SavedDropSlot(drag: drag, tint: tint) } // Fork (saved-drag): an empty Saved block's drop target
                    rows(kept, homeless: true, block: .saved)
                    if !today.isEmpty {
                        if clearCount > 0 {
                            ClearTabsDivider(browser: browser, tint: tint, count: clearCount)
                        } else {
                            divider
                        }
                    }
                    newTab
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SavedDrop.space)) } action: { drag.place(seam: $0, in: space) } // Fork (saved-drag)
                    TodayDropGap(drag: drag, tint: tint) // Fork (saved-drag): a Saved row on its way out lands here
                    // Fork (trails): with the flight on, Today is drawn as
                    // trails (Fork/Trails/); off, exactly as before.
                    if trails {
                        TrailsColumn(browser: browser, prefs: prefs, tint: tint, pill: pill, tabs: today.map(\.tab))
                    } else {
                        rows(today, block: .today)
                    }
                }
                // Fork (saved-drag): one space for every frame a drop is
                // worked out from, a folder lit for a drop onto it, the card
                // in the hand, and the column's drop target for a trail's
                // page (Fork/SavedDrop.swift).
                .coordinateSpace(name: SavedDrop.space)
                .overlay(alignment: .topLeading) { if shown { SavedDropMark(drag: drag, tint: tint) } }
                .overlay(alignment: .topLeading) { if shown { SideDragCard(drag: drag, browser: browser, tint: tint) } }
                .onDrop(of: shown ? [Trails.dragType] : [], delegate: SavedTrailDrop(browser: browser, drag: drag))
                .padding(.horizontal, SideBar.inset)
                .padding(.top, 2)
                .padding(.bottom, 12)
                // Fork (scroll-bounce): elastic up and down, never sideways.
                .background(SideScrollElasticity(space: space))
            }
            .scrollBounceBehavior(.always, axes: .vertical)
            .frame(maxHeight: .infinity)
            .mask(SideBar.fade)
            // Fork: the rows are only under the pointer inside the scroll —
            // one scrolled off the top still has a frame, under the favourites.
            .transformAnchorPreference(key: SideTargets.self, value: .bounds) { $0.window = $1 }
            // A row saved from far down Today lands at the end of the kept
            // rows, which may be well above. Go and show it — once it has
            // finished moving, and without an animation of its own: a scroll
            // that overlaps the move's leaves the grid above blank.
            .onChange(of: reveal) { _, id in
                guard shown, let id else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    proxy.scrollTo("tab-\(id.uuidString)", anchor: .bottom)
                }
            }
            .onAppear { if shown { show(active, in: proxy, gliding: false) } }
            .onChange(of: active) { _, id in if shown { show(id, in: proxy) } }
            // Back on screen: kept where it was left, the live row brought
            // into view if it is not, as a new column's is.
            .onChange(of: shown) { _, now in if now { show(active, in: proxy, gliding: false) } }
        }
        .frame(maxHeight: .infinity)
    }

    /// Wherever the live row is, the column keeps it in sight: ⌘1–9, ⌃Tab,
    /// a link that opens a tab, a space switch, the restore at launch. Only
    /// as far as it takes to bring the row in, and not while a row or a
    /// favourite is in the hand.
    private func show(_ id: Tab.ID?, in proxy: ScrollViewProxy, gliding: Bool = true) {
        guard let id, !held else { return }
        // A turn of the run loop later, so a row that has only just arrived
        // has been laid out before it is looked for. A column sliding in
        // (Fork: SpaceSlide) is already where it should be, not gliding to it.
        DispatchQueue.main.async {
            withAnimation(gliding && !still && !SpaceSlide.shared.moving(in: browser) ? Motion.glide : nil) {
                proxy.scrollTo("tab-\(id.uuidString)", anchor: nil)
            }
        }
    }

    /// One block's rows, drawn by the groups' view so each run wears its
    /// header and the drag knows about groups.
    /// A row carried over the other block crosses the seam where a room
    /// opens for it: up into Saved saves it there, down into Today lets it
    /// go (Fork/SavedDrop.swift).
    private func rows(_ list: [(index: Int, tab: Tab)], homeless: Bool = false, block: SavedDrop.Block) -> some View {
        GroupedRows(
            browser: browser,
            prefs: prefs,
            pill: pill,
            tint: tint,
            tabs: list.map(\.tab),
            space: space,
            active: active,
            editing: editing,
            refusals: refusals,
            pillID: pillID,
            homeless: homeless,
            offset: list.first?.index ?? 0,
            block: block,
            holding: holding
        )
        .equatable()
    }

    /// The quiet line between what you keep and what you opened today. Half
    /// a hairline, inset from both edges, and nothing else — Arc captions
    /// neither block, and a column this quiet is worse for a word in it.
    private var divider: some View {
        Rectangle()
            .fill(tint.hairline)
            .frame(height: 1)
            .padding(.horizontal, SideBar.rowInset)
            .padding(.vertical, 6)
    }

    /// Arc's New Tab: a plus and the words, as quiet as the rows around it,
    /// right under the rows you keep.
    private var newTab: some View {
        Quiet(icon: "plus", title: "New Tab", height: SideBar.row, inset: SideBar.rowInset, glow: tint.hover, ink: tint.muted) {
            browser.launch() // Fork: the ⌘T card, as Arc's New Tab row opens it
        }
        .contextMenu { NewItemMenu(browser: browser) } // Fork (canvas): New Tab / New Canvas, Arc's new-item menu
    }
}
