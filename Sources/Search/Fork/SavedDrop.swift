import SwiftUI

// Dragging a row into Saved, and out of it.
//
// A row picked up out of Today (GroupedRows' own drag) is over Saved as soon as the pointer is over the
// New Tab row or anything above it. A row's room opens where it would land —
// between two rows, or inside a folder, stepped in like the folder's rows —
// or, onto a folder's line, the folder lights up; the row rides above it on
// a card, and letting go there saves it at that place. A Saved row moved
// inside Saved gets the same room (none over its own place); past the middle
// of the New Tab row it is over Today, and the room opens at the top of
// Today. Inside Today a row reorders exactly as before. Any row carried up
// over the favourites becomes a pin.
//
// It used to be decided only on release, by counting rows: a row had to be
// let go a whole row and a half past the edge of its own block — past the
// middle of the New Tab row — and then landed at the bottom of Saved
// wherever it was dropped, with nothing on screen to say any of that.
//
// The geometry is worked out by `SavedDrop.target`, a pure function of the
// pointer and the column's frames, so it can be tested without a window.

enum SavedDrop {
    /// The column's own coordinate space: the scroll's content, so a frame
    /// in it doesn't move when the column scrolls.
    static let space = "sidecolumn"

    enum Block: Equatable { case saved, today }

    /// One line of the Saved block as the column draws it.
    struct Line: Equatable {
        enum Kind: Equatable {
            case tab(Tab.ID)
            case folder(UUID, collapsed: Bool)
        }
        var kind: Kind
        var top: CGFloat
        var bottom: CGFloat
        /// How many folders in it is (0 at the top level).
        var depth: Int
        /// A tab's folder; a folder's own parent folder.
        var group: UUID?
        var mid: CGFloat { (top + bottom) / 2 }
    }

    struct Layout: Equatable {
        /// The Saved block's lines, top to bottom — not the one in the hand.
        var lines: [Line]
        /// Where Saved starts: right under the space's name (or the empty
        /// block's drop slot).
        var top: CGFloat
        /// Where Saved ends. The block's own frame, not its last line's: a
        /// row in the hand still takes its place in the block.
        var bottom: CGFloat
        /// The New Tab row, the seam. Today starts under it.
        var seamTop: CGFloat
        var seamBottom: CGFloat
        var gap: CGFloat = GroupedRows.gap
    }

    /// Where a dropped row goes, relative to what is there.
    enum Anchor: Equatable {
        case before(Tab.ID)
        case after(Tab.ID)
        /// Above a folder, and so above every tab in it.
        case beforeFolder(UUID)
        /// Onto a folder's own line: in it, first.
        case into(UUID)
        /// The end of Saved, at the top level: just above the seam.
        case end
    }

    struct Spot: Equatable {
        var anchor: Anchor
        /// The folder it lands in, nil at the top level.
        var group: UUID?
        /// How far in the gap starts, in folder steps.
        var depth: Int
        /// The middle of the gap it opens, in the column's space.
        var y: CGFloat
    }

    enum Target: Equatable {
        case saved(Spot)
        /// The top of Today, where an unsaved row goes.
        case today(y: CGFloat)
        /// Up over the favourites: it becomes a pin, at the end of them.
        case pins
    }

    /// Where the row in the hand would go if let go with the pointer at `y`.
    /// Nil inside Today, where it simply reorders. Inside Saved it lands
    /// where the gap opens, as a Today row does: counting rows moved a
    /// row out of a folder by index, and a shut folder's hidden rows
    /// still counted, so it fell into whichever folder was next.
    static func target(y: CGFloat, from: Block, in layout: Layout) -> Target? {
        switch from {
        case .today:
            // Up out of Today: over the New Tab row, or anywhere above it.
            guard y < layout.seamBottom else { return nil }
            return .saved(spot(y: y, in: layout))
        case .saved:
            // Down out of Saved: past the middle of the New Tab row, the seam,
            // as a Today row crosses up onto it. Between Saved's last row and
            // there is the end of Saved at the top level: the one place to
            // leave a folder that ends the block.
            guard y > (layout.seamTop + layout.seamBottom) / 2 else { return .saved(spot(y: y, in: layout)) }
            return .today(y: layout.seamBottom + layout.gap / 2)
        }
    }

    /// A Saved row let go at `spot` would stay where it is (same folder,
    /// same place): no gap opens for it, and it is carried as it was.
    static func stays(_ spot: Spot, moving: Tab.ID, in group: UUID?,
                      row: [(id: Tab.ID, pinned: Bool, saved: Bool)],
                      inFolder: (Tab.ID, UUID) -> Bool) -> Bool {
        if spot.anchor == .before(moving) || spot.anchor == .after(moving) { return true }
        guard spot.group == group, let here = row.firstIndex(where: { $0.id == moving }) else { return false }
        return index(for: spot.anchor, moving: moving, row: row, inFolder: inFolder) == here
    }

    /// The place in Saved nearest the pointer.
    static func spot(y: CGFloat, in layout: Layout) -> Spot {
        let lines = layout.lines
        let half = layout.gap / 2
        guard let first = lines.first, let last = lines.last else {
            return Spot(anchor: .end, group: nil, depth: 0, y: layout.top)
        }
        if y < first.top { return before(first, half) }
        // Below the last line — the hairline, the New Tab row: the end of
        // Saved, at the top level, whatever folder the last line is in.
        if y >= last.bottom + half { return Spot(anchor: .end, group: nil, depth: 0, y: last.bottom + half) }
        // The line under the pointer, counting the gap below it as its own.
        let i = lines.firstIndex { y < $0.bottom + half } ?? lines.count - 1
        let line = lines[i]
        let next = i + 1 < lines.count ? lines[i + 1] : nil
        switch line.kind {
        case .folder(let id, let collapsed):
            let rel = (y - line.top) / max(1, line.bottom - line.top)
            // The top quarter is the gap above the folder; the rest is the
            // folder itself — except the bottom quarter of an open one, which
            // is the gap above its first row (the same place, in the folder,
            // shown where it will be).
            if rel < 0.25 { return before(line, half) }
            if rel > 0.75, !collapsed, let next, next.depth > line.depth { return before(next, half) }
            return Spot(anchor: .into(id), group: id, depth: line.depth + 1, y: line.mid)
        case .tab(let id):
            if y < line.mid { return before(line, half) }
            // The lower half: after this row, in its folder. When the next
            // line is a sibling that is the same place as above it.
            if let next, case .tab = next.kind, next.group == line.group, next.depth == line.depth {
                return before(next, half)
            }
            return Spot(anchor: .after(id), group: line.group, depth: line.depth, y: line.bottom + half)
        }
    }

    private static func before(_ line: Line, _ half: CGFloat) -> Spot {
        switch line.kind {
        case .tab(let id):
            return Spot(anchor: .before(id), group: line.group, depth: line.depth, y: line.top - half)
        case .folder(let id, _):
            return Spot(anchor: .beforeFolder(id), group: line.group, depth: line.depth, y: line.top - half)
        }
    }

    /// Where in the whole row a tab dropped at `spot` goes, as `Browser.move`
    /// counts: its index once it is there. `row` is the browser's tabs,
    /// `moving` the one being dropped, `saved` says which rows are Saved and
    /// `inFolder` whether a tab is in a folder (or one inside it).
    static func index(for anchor: Anchor, moving: Tab.ID, row: [(id: Tab.ID, pinned: Bool, saved: Bool)],
                      inFolder: (Tab.ID, UUID) -> Bool) -> Int {
        let rest = row.filter { $0.id != moving }
        let endOfSaved = (rest.lastIndex { !$0.pinned && $0.saved } ?? (rest.lastIndex { $0.pinned } ?? -1)) + 1
        switch anchor {
        case .before(let id):
            return rest.firstIndex { $0.id == id } ?? endOfSaved
        case .after(let id):
            return rest.firstIndex { $0.id == id }.map { $0 + 1 } ?? endOfSaved
        case .beforeFolder(let group), .into(let group):
            return rest.firstIndex { !$0.pinned && inFolder($0.id, group) } ?? endOfSaved
        case .end:
            return endOfSaved
        }
    }

    /// The target as the bench prints it.
    @MainActor
    static func describe(_ target: Target?) -> [String: Any] {
        guard let target else { return ["block": "own"] }
        switch target {
        case .today(let y): return ["block": "today", "y": y]
        case .pins: return ["block": "pins"]
        case .saved(let spot):
            var out: [String: Any] = ["block": "saved", "depth": spot.depth, "y": spot.y,
                                      "group": spot.group.flatMap { Groups.shared.group($0)?.name } ?? ""]
            switch spot.anchor {
            case .before(let id): out["before"] = String(id.uuidString.prefix(8)).lowercased()
            case .after(let id): out["after"] = String(id.uuidString.prefix(8)).lowercased()
            case .beforeFolder(let id): out["beforeFolder"] = Groups.shared.group(id)?.name ?? ""
            case .into(let id): out["into"] = Groups.shared.group(id)?.name ?? ""
            case .end: out["end"] = true
            }
            return out
        }
    }
}

/// One window's drag: what is in the hand, where it would land, and the
/// frames of everything it could land on. Frames are plain properties — they
/// change as the column lays out and must not redraw it — and only what the
/// column shows is published: where it would land (`target`, rarely), the
/// empty block's slot, and the pointer itself on an object of its own, so a
/// move redraws the card in the hand and nothing else.
@MainActor
final class SideDrag: ObservableObject {
    private static var all: [ObjectIdentifier: SideDrag] = [:]

    static func of(_ browser: Browser) -> SideDrag {
        let key = ObjectIdentifier(browser)
        if let drag = all[key] { return drag }
        let drag = SideDrag()
        all[key] = drag
        return drag
    }

    /// The pointer, in the column's space.
    final class Hand: ObservableObject {
        @Published var y: CGFloat = 0
    }
    let hand = Hand()

    /// The row in the hand; nil for a trail's page, whose id arrives only
    /// with the drop (and whose card the system draws).
    private(set) var carrying: Tab.ID?
    private(set) var from: SavedDrop.Block?
    @Published private(set) var target: SavedDrop.Target?
    /// The empty Saved block's drop slot is showing.
    @Published private(set) var slot = false
    /// Where the row was when it was picked up, and how far down it the
    /// pointer took it: the card in the hand keeps that grip.
    private(set) var picked: CGRect = .zero
    private(set) var grip: CGFloat = 0

    var rows: [Tab.ID: CGRect] = [:]
    var heads: [UUID: CGRect] = [:]
    var saved: CGRect = .zero
    var header: CGRect = .zero
    var seam: CGRect = .zero
    var slotFrame: CGRect = .zero
    /// In the window's space: the top of the scrolling column (above it are
    /// the favourites) and the top of its content, to tell from a pointer
    /// in the column's space whether it has gone up over the favourites.
    var pinLine: CGFloat = 0
    var contentTop: CGFloat = 0

    private var closing: DispatchWorkItem?

    var active: Bool { from != nil }

    /// A row picked up, the pointer at `y`.
    func carry(_ id: Tab.ID?, from block: SavedDrop.Block, at y: CGFloat? = nil, in browser: Browser) {
        closing?.cancel()
        carrying = id
        from = block
        if let id, let y, let frame = rows[id] {
            picked = frame
            grip = y - frame.minY
            hand.y = y
        }
    }

    /// The pointer has moved. Where it would land is worked out against the
    /// column as it is laid out now — a gap already open where it would land
    /// included, which is what keeps that gap from chasing the pointer. A gap
    /// opens and moves with the column's own spring; back over its own
    /// block, it shuts at once, so the row in the hand is under the pointer
    /// again the moment it reappears.
    ///
    /// An empty Saved block has nothing to open a gap between: over it, the
    /// block's own drop place opens above the hairline instead (`slot`).
    func move(to y: CGFloat, in browser: Browser) {
        hand.y = y
        guard let from else { return }
        let layout = layout(in: browser)
        var next = SavedDrop.target(y: y, from: from, in: layout)
        if let id = carrying, let tab = browser.tabs.first(where: { $0.id == id }) {
            if y + contentTop < pinLine {
                next = tab.pin == nil && !tab.isBlank ? .pins : nil
            } else if case .saved(let spot)? = next, from == .saved,
                      SavedDrop.stays(spot, moving: id, in: Groups.shared.membership[id],
                                      row: browser.tabs.map { (id: $0.id, pinned: $0.pin != nil, saved: Sections.shared.isSaved($0)) },
                                      inFolder: Sections.shared.inFolder) {
                next = nil
            }
        }
        guard next != target else { return }
        if next == nil {
            target = nil
            slot = false
            return
        }
        withAnimation(Motion.settle) {
            if case .saved? = next, layout.lines.isEmpty { slot = true }
            target = next
        }
    }

    /// Put down, or carried out of the column. The slot waits a moment: a
    /// system drag leaves the column's drop target for a trail's own and
    /// comes back, and the slot must not flicker on the way.
    func end(soon: Bool = false) {
        target = nil
        carrying = nil
        from = nil
        closing?.cancel()
        guard slot else { return }
        if soon {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { if self?.from == nil { self?.slot = false } }
            }
            closing = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        } else {
            slot = false
        }
    }

    /// The Saved block as it is laid out now, minus the row in the hand.
    func layout(in browser: Browser) -> SavedDrop.Layout {
        let sections = Sections.shared
        let groups = Groups.shared
        let space = Spaces.shared.current(in: browser)
        let kept = browser.tabs.filter { $0.pin == nil && sections.isSaved($0) }
        var lines: [SavedDrop.Line] = []
        var open: [UUID] = []
        for row in FolderTree.plan(kept, homeless: groups.homeless(in: space), space: space) {
            switch row {
            case .head(let group, _, _, let depth, _):
                open = Array(open.prefix(depth))
                if let frame = heads[group.id] {
                    lines.append(.init(kind: .folder(group.id, collapsed: group.collapsed), top: frame.minY, bottom: frame.maxY,
                                       depth: depth, group: depth > 0 ? open.last : nil))
                }
                open.append(group.id)
            case .tab(let tab, _, _, let depth):
                // A Saved row in the hand keeps its own line: over it, it stays.
                guard tab.id != carrying || from == .saved, let frame = rows[tab.id] else { continue }
                lines.append(.init(kind: .tab(tab.id), top: frame.minY, bottom: frame.maxY,
                                   depth: depth, group: groups.membership[tab.id]))
            }
        }
        let top = slot && lines.isEmpty ? slotFrame.midY : header.maxY + GroupedRows.gap / 2
        return SavedDrop.Layout(lines: lines, top: top, bottom: max(saved.maxY, top),
                                seamTop: seam.minY, seamBottom: seam.maxY)
    }

    /// Let go over Saved or Today: the row goes where the gap was.
    func drop(_ tab: Tab, at target: SavedDrop.Target, in browser: Browser) {
        switch target {
        case .saved(let spot): Sections.shared.place(tab, at: spot, in: browser)
        case .today: Sections.shared.set(tab, saved: false, in: browser)
        case .pins: browser.pin(tab)
        }
    }

    /// Whether the gap for `anchor` is the one open now.
    func opens(_ anchor: SavedDrop.Anchor) -> SavedDrop.Spot? {
        guard case .saved(let spot)? = target, spot.anchor == anchor else { return nil }
        if case .end = anchor, slot { return nil }
        return spot
    }

    var overToday: Bool { if case .today? = target { return true } else { return false } }
}

/// Where the row would land: a row's room opens there, as the rows make way
/// for one another inside a block, and a soft place is laid in it, stepped
/// in like the rows of the folder it would join. It is drawn in the
/// favourites' resting square — the column's own quiet surface.
struct SavedDropGap: View {
    @ObservedObject var drag: SideDrag
    let anchor: SavedDrop.Anchor
    let tint: SpaceTint

    var body: some View {
        if let spot = drag.opens(anchor) {
            SavedDropPlace(tint: tint, depth: spot.depth)
        }
    }
}

/// Above Today's first row, for a Saved row on its way out.
struct TodayDropGap: View {
    @ObservedObject var drag: SideDrag
    let tint: SpaceTint

    var body: some View {
        if drag.overToday { SavedDropPlace(tint: tint, depth: 0) }
    }
}

private struct SavedDropPlace: View {
    let tint: SpaceTint
    let depth: Int

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(tint.square)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(tint.hairline, lineWidth: 1)
            }
            .frame(height: SideBar.row)
            .padding(.leading, CGFloat(depth) * Folders.step)
            .transition(.opacity)
            .allowsHitTesting(false)
    }
}

/// Onto a folder's line: the folder lit as if under the pointer, ringed in
/// the space's colour — the colour of the live row's bar.
struct SavedDropMark: View {
    @ObservedObject var drag: SideDrag
    let tint: SpaceTint

    var body: some View {
        GeometryReader { _ in
            if case .saved(let spot)? = drag.target, case .into(let id) = spot.anchor, let frame = drag.heads[id] {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.hover)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(tint.bar, lineWidth: 1.5)
                    }
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .allowsHitTesting(false)
        .animation(Motion.quick, value: drag.target)
    }
}

/// The row in the hand while it is over the other block: a card lifted off
/// the column, under the pointer, while its own place is left empty. (Inside
/// its own block the row itself is carried, as it always was.)
struct SideDragCard: View {
    @ObservedObject var drag: SideDrag
    @ObservedObject var hand: SideDrag.Hand
    @ObservedObject var browser: Browser
    let tint: SpaceTint

    init(drag: SideDrag, browser: Browser, tint: SpaceTint) {
        self.drag = drag
        self.hand = drag.hand
        self.browser = browser
        self.tint = tint
    }

    private var depth: Int { if case .saved(let spot)? = drag.target { return spot.depth } else { return 0 } }

    var body: some View {
        GeometryReader { _ in
            if drag.target != nil, let id = drag.carrying, let tab = browser.tabs.first(where: { $0.id == id }) {
                // Stepped in as far as the place it would take, so a row on
                // its way into a folder already sits like the folder's rows.
                let inset = CGFloat(depth) * Folders.step
                SideDragCardRow(browser: browser, tab: tab, tint: tint)
                    .frame(width: max(40, drag.picked.width - inset), height: drag.picked.height)
                    .offset(x: drag.picked.minX + inset, y: hand.y - drag.grip)
            }
        }
        .allowsHitTesting(false)
        .animation(Motion.quick, value: depth)
    }
}

/// The card itself: the row's mark and title on the column's paper, with
/// the lift the live row wears and a shadow a step deeper.
struct SideDragCardRow: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    let tint: SpaceTint

    var body: some View {
        HStack(spacing: 10) {
            SideGlyphMark(prefs: browser.prefs, icon: tab.icon, letter: tab.monogram, tint: tint, size: 16)
            Text(tab.label)
                .font(.system(size: 15))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(tint.ink)
            Spacer(minLength: 2)
        }
        .padding(.leading, SideBar.rowInset)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(SideDragCardGround(tint: tint))
        .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
    }
}

/// Paper a row is carried on: the material under the live row's own
/// paper and ring, so whatever it passes over stays behind it.
struct SideDragCardGround: View {
    let tint: SpaceTint

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.regularMaterial)
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.pill) }
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.rim, lineWidth: 1) }
    }
}

/// The held row hides while its card is over the other block.
struct SideDragHidden: ViewModifier {
    @ObservedObject var drag: SideDrag
    let held: Bool

    func body(content: Content) -> some View {
        content.opacity(held && drag.target != nil ? 0 : 1)
    }
}

/// An empty Saved block, once a Today row is carried over it: one row's
/// room above the hairline to drop it in, saying what it is for.
struct SavedDropSlot: View {
    @ObservedObject var drag: SideDrag
    let tint: SpaceTint

    private var over: Bool { if case .saved? = drag.target { return true } else { return false } }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16)
            Text("Drop here to save")
                .font(.system(size: 13.5))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(over ? tint.ink : tint.muted)
        .padding(.leading, SideBar.rowInset)
        .frame(height: SideBar.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(over ? tint.hover : tint.square)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(over ? tint.bar : tint.hairline, lineWidth: over ? 1.5 : 1)
                }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SavedDrop.space)) } action: { drag.slotFrame = $0 }
        .animation(Motion.quick, value: over)
        .transition(.opacity)
        .accessibilityLabel("Drop here to save")
    }
}
