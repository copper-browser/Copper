import SwiftUI

/// The tabs, down the left instead of across the top.
///
/// The column is one surface washed in the current space's theme
/// (`SpaceTint`, `SpaceTheme`), laid out the way Arc lays its own out: the
/// lights with the sidebar door and back / forward / reload, the address,
/// the favourites as a grid of soft squares, the space's name, the rows you
/// keep, a hairline, "New Tab", then whatever was opened today — all one
/// scroll, nothing pinned to the foot but the spaces themselves.
///
/// Nothing in here has a border. Separation is spacing, a single hairline,
/// and the fact that the live row is a pill in a stronger tint of the same
/// hue than everything around it.
struct SideBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject private var spaces = Spaces.shared
    @ObservedObject private var sections = Sections.shared
    @ObservedObject private var downloads = Downloads.shared
    @ObservedObject private var clearTabs = ClearTabs.shared
    @ObservedObject private var drag: SideDrag // Fork (saved-drag): the row in the hand, and where it would land

    init(browser: Browser, prefs: Preferences) { // Fork (saved-drag): picks up this window's drag
        self.browser = browser
        self.prefs = prefs
        _drag = ObservedObject(wrappedValue: SideDrag.of(browser))
    }

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var still

    @Namespace private var pill

    @State private var landing = false
    /// The width the column had when the edge was picked up.
    @State private var grabbed: CGFloat?
    @State private var onEdge = false

    /// A pin, picked up out of the grid — a separate state from the loose
    /// rows above, since the two gestures never happen at once but move on
    /// two different axes.
    @State private var pinDragging: Tab.ID?
    @State private var pinFrom = 0
    @State private var pinTravel: CGSize = .zero
    /// A loose row picked up out of either block: while it is in the hand
    /// the column does not scroll out from under it.
    @State private var rowHeld = false

    /// Arc's measures: a row every forty points, a mark eighteen in from the
    /// window's edge and ten clear of its title.
    static let row: CGFloat = GroupedRows.row
    static let gap: CGFloat = GroupedRows.gap
    /// The column's own edges. A row's mark lands at `inset + rowInset` from
    /// the window's edge.
    static let inset: CGFloat = 8
    static let rowInset: CGFloat = 10
    private static let pinGap: CGFloat = 8

    private var tint: SpaceTint { SpaceTint(space: spaces.space(in: browser), dark: scheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Fork (space-slide): the lights, the address and the strip stay
            // put when the space changes; their ink is mixed between the two
            // spaces' as the slide goes (SlideInk), so they change colour
            // with the ground under them.
            SlideInk(browser: browser) { tint in head(tint) }

            SlideInk(browser: browser) { tint in
                SideAddress(browser: browser, tint: tint)
                    .padding(.horizontal, SideBar.inset)
                    .padding(.bottom, 10)
            }

            // Fork (global-pins): the favourites are the same in every space,
            // so they stay put when the space changes, as Arc's do.
            if browser.pinnedCount > 0 || drag.target == .pins { // Fork (saved-drag): a row carried up opens the grid's next place
                pinned
                    .padding(.horizontal, SideBar.inset)
                    .padding(.bottom, 8)
            }

            // Fork (space-slide): the space's name and its rows are the part
            // of the column that travels when the space changes; the lights,
            // the address, the favourites and the strip stay put.
            column
                .modifier(SpaceSlideBand(browser: browser))

            // Fork (update-pill): Arc's update button, just above the foot,
            // only while there is a newer Copper (Fork/UpdatePill.swift).
            UpdatePillSlot(browser: browser)

            SlideInk(browser: browser) { tint in SpaceStrip(browser: browser, tint: tint) { foot(tint) } }
        }
        .frame(width: prefs.sideWidth)
        .frame(maxHeight: .infinity)
        // Fork (space-slide): the ground is one live surface that blends
        // between the two spaces of a slide (SpaceGround) — never pictured,
        // never slid, so there is no seam between two grounds.
        .background {
            ZStack {
                SpaceGroundView(browser: browser, dark: scheme == .dark)
                if landing { tint.hover }
            }
        }
        // Fork (space-slide): the previews over the column while it goes.
        .overlay(alignment: .topLeading) { SpaceSlideCurtain(browser: browser) }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { SpaceSlide.shared.place(column: $0, in: browser) }
        .onDisappear { SpaceSlide.shared.place(column: nil, in: browser) }
        .overlay(alignment: .trailing) {
            Rectangle().fill(tint.hairline.opacity(0.6)).frame(width: 1)
        }
        .overlay(alignment: .trailing) { edge }
        // Fork: the wheel button closes the favourite or row under it — one
        // listener for the column, reading where every row is from the
        // frames they hand up, rather than one per row (see SideTargets).
        .overlayPreferenceValue(SideTargets.self) { targets in
            GeometryReader { geo in
                Color.clear.onReceive(NotificationCenter.default.publisher(for: MouseButtons.middleClickedSidebar)) { note in
                    guard let point = MouseButtons.point(of: note),
                          let id = targets.hit(point, in: geo), browser.editingTab != id,
                          let tab = browser.tabs.first(where: { $0.id == id }) else { return }
                    browser.close(tab)
                }
            }
            .allowsHitTesting(false)
        }
        .onDrop(of: [.url, .text], isTargeted: $landing) { providers in
            browser.take(providers)
        }
        // Yesterday's rows have an address and no page, so nothing has ever
        // asked their sites for a mark. Ask, once per host per launch, and
        // again when a switch brings a whole new column into view.
        .task(id: spaces.current(in: browser)) { Marks.warm(browser.tabs) }
        // A row nobody has met is today's, and goes to the top of Today.
        .onChange(of: browser.tabs.map(\.id)) { _, _ in sections.arrived(in: browser) }
        .onChange(of: browser.activeID) { _, now in sections.note(now) }
        .animation(Motion.quick, value: landing)
        .animation(Motion.glide, value: browser.activeID)
        .animation(Motion.glide, value: browser.editingTab)
        .animation(Motion.settle, value: browser.tabs.map(\.id))
        .animation(Motion.settle, value: browser.pinnedCount)
    }

    // MARK: - the lights' band

    /// The band the lights sit in is this mode's title bar: the window is
    /// dragged by it and a double-click fills the screen with it, everywhere
    /// but over the three doors, which take their own clicks. Back, forward
    /// and reload sit right of the lights — the same three doors as the top
    /// bar, moved beside the lights since there's no far end of a row to put
    /// them at in this mode.
    /// Arc's row: the lights, the door that folds the column away beside
    /// them, and back / forward / reload at the far end, in the column's ink.
    private func head(_ tint: SpaceTint) -> some View { // Fork (space-slide): the ink is handed in
        ZStack(alignment: .leading) {
            DragStrip()
            HStack(spacing: 0) {
                Color.clear.frame(width: 4 + Metrics.sideLights)
                    .allowsHitTesting(false)
                Door(icon: "sidebar.left", help: "Hide Sidebar   ⌘S", size: 28, ink: tint.ink, glow: tint.hover, glyph: 15) {
                    browser.toggleFold()
                }
                Color.clear.frame(maxWidth: .infinity).allowsHitTesting(false)
                Helm(browser: browser, size: 30, glyph: 15, ink: tint.ink, glow: tint.hover)
                    .padding(.trailing, 6)
            }
        }
        .frame(height: 46)
    }

    // MARK: - the favourites

    private var pinnedTabs: [Tab] { browser.tabs.filter { $0.pin != nil } }

    /// Every loose row with its place in the loose list kept alongside it, so
    /// a row can be drawn in either block below and still know where a drag
    /// would put it.
    private var looseRows: [(index: Int, tab: Tab)] {
        browser.tabs.filter { $0.pin == nil }.enumerated().map { (index: $0.offset, tab: $0.element) }
    }

    /// Three squares to a row, four once the column is wide enough to hold
    /// four without shrinking them below a comfortable mark. Never more:
    /// past four the grid stops being a grid of buttons and starts being a
    /// row of tiny icons, and an eighteenth favourite should wrap onto a new
    /// row rather than squeeze the seventeen above it.
    private func pinColumns(_ count: Int) -> Int {
        prefs.sideWidth >= 400 ? 4 : 3
    }

    /// However many columns the count calls for, they split the column's own
    /// width between them.
    private var pinWidth: CGFloat {
        let cols = pinColumns(browser.pinnedCount)
        let available = prefs.sideWidth - 2 * SideBar.inset - CGFloat(cols - 1) * SideBar.pinGap
        return max(20, available / CGFloat(cols))
    }

    /// A favourite is a wide, short button, not a big square: past three
    /// columns' worth of room the cell stops growing taller and the mark
    /// inside it stays where the eye expects it.
    private var pinHeight: CGFloat {
        min(48, max(34, pinWidth * 0.52))
    }

    /// The grid itself: fixed-size cells, left-aligned, so a half-empty last
    /// row holds its ground rather than stretching to fill it.
    private var pinned: some View {
        let tabs = pinnedTabs
        let cols = pinColumns(tabs.count)
        let width = pinWidth
        let height = pinHeight
        let columns = Array(repeating: GridItem(.fixed(width), spacing: SideBar.pinGap), count: cols)
        // Measured in the grid's own space, not the square's: a square that
        // has just been moved to a new cell would otherwise report the drag
        // from where it now is, the target would jump back, and the square
        // would shuttle between two cells for as long as the finger stayed.
        return VStack(spacing: 0) { LazyVGrid(columns: columns, alignment: .leading, spacing: SideBar.pinGap) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                let held = pinDragging == tab.id
                PinSquare(
                    browser: browser,
                    tab: tab,
                    live: tab.id == browser.activeID,
                    tint: tint,
                    pill: pill,
                    width: width,
                    height: height
                )
                .offset(pinOffset(held: held, index: index, columns: cols))
                .zIndex(held ? 1 : 0)
                .shadow(color: .black.opacity(held ? 0.16 : 0), radius: 10, y: 3)
                .gesture(pinReorder(tab: tab, index: index, columns: cols, width: width, height: height))
            }
            // Fork (saved-drag): where a row carried up over the favourites lands.
            if drag.target == .pins, let id = drag.carrying, let tab = browser.tabs.first(where: { $0.id == id }) {
                PinDropGhost(browser: browser, tab: tab, tint: tint, width: width, height: height)
            }
        } }
        .coordinateSpace(name: "pins")
    }

    /// The one square actually held stays glued to the fingers; every other
    /// square is already exactly where it belongs, because `browser.move`
    /// put it there — this only cancels out the bit of that same movement
    /// the held square already got for free by changing index underneath
    /// its own drag.
    private func pinOffset(held: Bool, index: Int, columns: Int) -> CGSize {
        guard held else { return .zero }
        let stepX = pinWidth + SideBar.pinGap
        let stepY = pinHeight + SideBar.pinGap
        let from = (row: pinFrom / columns, col: pinFrom % columns)
        let now = (row: index / columns, col: index % columns)
        return CGSize(
            width: pinTravel.width - CGFloat(now.col - from.col) * stepX,
            height: pinTravel.height - CGFloat(now.row - from.row) * stepY
        )
    }

    /// How many cells the drag has moved, in the grid's own row-major order
    /// — a straight line through the array a column-major offset would get
    /// wrong the moment it crossed a row. Row and column travel each measure
    /// themselves against that axis's own step now that a cell's width and
    /// height aren't the same number.
    private func pinDelta(columns: Int, stepX: CGFloat, stepY: CGFloat) -> Int {
        let col = Int((pinTravel.width / stepX).rounded())
        let row = Int((pinTravel.height / stepY).rounded())
        return row * columns + col
    }

    private func pinTarget(from: Int, moved: Int) -> Int {
        min(max(0, from + moved), max(0, pinnedTabs.count - 1))
    }

    /// Pick a square up and the others make way — across a row, and down
    /// into the next, exactly as far as the fingers actually moved.
    private func pinReorder(tab: Tab, index: Int, columns: Int, width: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("pins"))
            .onChanged { value in
                if pinDragging != tab.id {
                    pinDragging = tab.id
                    pinFrom = index
                }
                pinTravel = value.translation
                let stepX = width + SideBar.pinGap
                let stepY = height + SideBar.pinGap
                let target = pinTarget(from: pinFrom, moved: pinDelta(columns: columns, stepX: stepX, stepY: stepY))
                if target != index {
                    withAnimation(Motion.settle) {
                        browser.move(tab, to: target)
                    }
                }
            }
            .onEnded { _ in
                withAnimation(Motion.settle) {
                    pinDragging = nil
                    pinTravel = .zero
                }
            }
    }

    // MARK: - the rows

    /// Everything below the favourites, in one scroll, the way Arc has it:
    /// the space's name, the rows you keep and their folders, a hairline
    /// once there is anything open today, "New Tab", and today's rows right
    /// under it — never parked at the foot of the window.
    private var column: some View {
        let kept = looseRows.filter { sections.isSaved($0.tab) }
        let today = looseRows.filter { !sections.isSaved($0.tab) }
        let clearCount = clearTabs.clearable(in: browser).count
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: SideBar.gap) {
                    SpaceHeader(browser: browser)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SavedDrop.space)) } action: { SideDrag.of(browser).header = $0 } // Fork (saved-drag)
                    if drag.slot { SavedDropSlot(drag: drag, tint: tint) } // Fork (saved-drag): an empty Saved block's drop target
                    rows(kept, homeless: true, block: .saved)
                    if !today.isEmpty {
                        if clearCount > 0 {
                            ClearTabsDivider(browser: browser, tint: tint, count: clearCount)
                        } else {
                            divider
                        }
                    }
                    newTab
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SavedDrop.space)) } action: { SideDrag.of(browser).seam = $0 } // Fork (saved-drag)
                    TodayDropGap(drag: drag, tint: tint) // Fork (saved-drag): a Saved row on its way out lands here
                    rows(today, block: .today)
                }
                // Fork (saved-drag): one space for every frame a drop is
                // worked out from, a folder lit for a drop onto it, and the
                // card in the hand (Fork/SavedDrop.swift).
                .coordinateSpace(name: SavedDrop.space)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { drag.contentTop = $0 } // Fork (saved-drag)
                .overlay(alignment: .topLeading) { SavedDropMark(drag: drag, tint: tint) }
                .overlay(alignment: .topLeading) { SideDragCard(drag: drag, browser: browser, tint: tint) }
                .padding(.horizontal, SideBar.inset)
                .padding(.top, 2)
                .padding(.bottom, 12)
                // Fork (scroll-bounce): elastic up and down, never sideways.
                .background(SideScrollElasticity())
            }
            .scrollBounceBehavior(.always, axes: .vertical)
            .frame(maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { drag.pinLine = $0 } // Fork (saved-drag): above it, the favourites
            .mask(SideBar.fade)
            // Fork: the rows are only under the pointer inside the scroll —
            // one scrolled off the top still has a frame, under the favourites.
            .transformAnchorPreference(key: SideTargets.self, value: .bounds) { $0.window = $1 }
            // A row saved from far down Today lands at the end of the kept
            // rows, which may be well above. Go and show it — once it has
            // finished moving, and without an animation of its own: a scroll
            // that overlaps the move's leaves the grid above blank.
            .onChange(of: sections.reveal) { _, id in
                guard let id else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    proxy.scrollTo("tab-\(id.uuidString)", anchor: .bottom)
                }
            }
            .onAppear { show(browser.activeID, in: proxy, gliding: false) }
            .onChange(of: browser.activeID) { _, id in show(id, in: proxy) }
        }
        .frame(maxHeight: .infinity)
    }

    /// Wherever the live row is, the column keeps it in sight: ⌘1–9, ⌃Tab,
    /// a link that opens a tab, a space switch, the restore at launch. Only
    /// as far as it takes to bring the row in, and not while a row or a
    /// favourite is in the hand.
    private func show(_ id: Tab.ID?, in proxy: ScrollViewProxy, gliding: Bool = true) {
        guard let id, pinDragging == nil, !rowHeld else { return }
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
    /// header and the drag knows about groups; `only` keeps it to this block.
    /// A row carried over the other block crosses the seam where a room
    /// opens for it: up into Saved saves it there, down into Today lets it
    /// go (Fork/SavedDrop.swift).
    private func rows(_ list: [(index: Int, tab: Tab)], homeless: Bool = false, block: SavedDrop.Block) -> some View {
        GroupedRows(
            browser: browser,
            prefs: prefs,
            pill: pill,
            tint: tint,
            only: Set(list.map(\.tab.id)),
            homeless: homeless,
            offset: list.first?.index ?? 0,
            block: block,
            holding: { rowHeld = $0 }
        )
    }

    /// A long column runs out under a soft edge rather than a hard one — the
    /// top and bottom few points of either block fade into the ground, so a
    /// row half-scrolled off doesn't look sliced.
    /// A few points at each end, whatever the column's height — a
    /// proportional fade would eat the space's name on a tall window.
    static var fade: some View { // Fork: SpacePreview masks its rows with it too
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 6)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 14)
        }
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

    // MARK: - the edge and the foot

    /// The column's edge: pull it to make the column wider or narrower,
    /// double-click it to put it back. The hairline darkens under the pointer
    /// so the edge says it can be taken before it is.
    private var edge: some View {
        Rectangle()
            .fill(tint.ink.opacity(onEdge || grabbed != nil ? 0.18 : 0))
            .frame(width: onEdge || grabbed != nil ? 2 : 1)
            .frame(width: 9)
            .contentShape(Rectangle())
            .onHover { over in
                onEdge = over
                if over { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if grabbed == nil { grabbed = prefs.sideWidth }
                        let wanted = (grabbed ?? prefs.sideWidth) + value.translation.width
                        prefs.sideWidth = min(Metrics.sideMax, max(Metrics.sideMin, wanted))
                    }
                    .onEnded { _ in grabbed = nil }
            )
            .modifier(OneClick(double: true) {
                withAnimation(Motion.settle) { prefs.sideWidth = Metrics.side }
            })
            .animation(Motion.quick, value: onEdge)
    }

    /// Fork (lean-foot): the foot is for spaces — only the canvas door
    /// shares it. Bookmarks live in the menu bar, the Accounts key and the
    /// extensions in the address pill, under the pointer.
    private func foot(_ tint: SpaceTint) -> some View { // Fork (space-slide): the ink is handed in
        CanvasDoor(browser: browser, tint: tint) // Fork (canvas)
    }

}

/// A site's mark, or the letter that stands in for one until it arrives.
///
/// Upstream's `Mark` draws its letter on a grey chip, which on a tinted
/// column reads as a hole punched through it. This is the same thing with
/// the chip borrowed from the space instead.
struct RowMark: View {
    let icon: NSImage?
    let letter: String
    let tint: SpaceTint
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            } else {
                Text(letter)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(tint.ink.opacity(0.6))
                    .frame(width: size, height: size)
                    .background(
                        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                            .fill(tint.chip)
                    )
            }
        }
        .transition(.opacity)
        .animation(Motion.quick, value: icon == nil)
    }
}

/// Fork (saved-drag): the place a row carried up over the favourites will
/// take, ringed in the space's colour as a folder lit for a drop is.
private struct PinDropGhost: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    let tint: SpaceTint
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(12, min(width, height) * 0.28), style: .continuous)
        SideGlyphMark(prefs: browser.prefs, icon: tab.icon, letter: tab.monogram, tint: tint,
                      size: max(14, min(20, height * 0.46)))
            .opacity(0.7)
            .frame(width: width, height: height)
            .background(shape.fill(tint.hover))
            .overlay(shape.strokeBorder(tint.bar, lineWidth: 1.5))
            .transition(.opacity)
            .allowsHitTesting(false)
    }
}

/// A favourite: a wide, soft square holding the site's mark. Arc's grid, and
/// the same cell Copper's pins have always been, only with the icon in front
/// and the letter behind it.
private struct PinSquare: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    let live: Bool
    let tint: SpaceTint
    let pill: Namespace.ID
    var width: CGFloat = 34
    var height: CGFloat = 34

    @State private var pointing = false
    @ObservedObject private var benchHover = SideRowHover.shared // Fork (calendar-peek): `bench sections hover ID` peeks too
    private var hovering: Bool { pointing || benchHover.forced == tab.id }
    @State private var peeking = false // Fork (calendar-peek)
    @State private var overCard = false

    private var radius: CGFloat { min(12, min(width, height) * 0.28) }
    /// A mark big enough to recognise at a glance, and no bigger than the
    /// cell can hold with air around it.
    private var mark: CGFloat { max(14, min(20, height * 0.46)) }

    var body: some View {
        Group {
            if browser.editingPin == tab.id {
                PinField(browser: browser, tab: tab)
            } else {
                SideGlyphMark(prefs: browser.prefs, icon: tab.icon, letter: tab.pin ?? tab.monogram, tint: tint, size: mark) // Fork (settings-browse): Tabs show Letters / Site icons
            }
        }
        .frame(width: width, height: height)
        .background {
            if live {
                // The live row's paper, ring and lift, without its bar: a
                // square in a grid of squares is found by its edge alone.
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(tint.pill)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(tint.rim, lineWidth: 1)
                    }
                    .shadow(color: tint.lift, radius: 5, y: 1.5)
                    .matchedGeometryEffect(id: "live", in: pill)
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(hovering ? tint.hover : tint.square)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .modifier(OneClick(double: live) {
            if live { browser.editLetter(tab) } else { browser.select(tab) }
        })
        .onHover { pointing = $0 }
        // Fork (calendar-peek): a Calendar pin shows the next meetings while
        // the pointer rests on it or on the card.
        .task(id: hovering || overCard) { await settlePeek() }
        .popover(isPresented: $peeking, arrowEdge: .trailing) {
            CalendarPeekCard(browser: browser).onHover { overCard = $0 }
        }
        .contextMenu { TabMenu(browser: browser, tab: tab, close: { browser.close(tab) }) }
        .anchorPreference(key: SideTargets.self, value: .bounds) { SideTargets(pins: [tab.id: $0]) } // Fork: wheel click closes, see SideBar
        .help(CalendarPeek.peeks(tab.pending ?? tab.address) ? "" : tab.label)
        .animation(Motion.quick, value: hovering)
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }

    /// Open the card once the pointer has rested half a second (passing over
    /// the grid opens nothing); close it a moment after the pointer leaves
    /// both the pin and the card, so it can cross the gap between them.
    private func settlePeek() async {
        guard CalendarPeek.peeks(tab.pending ?? tab.address), browser.editingPin != tab.id else { return }
        let resting = hovering || overCard
        guard resting != peeking else { return }
        try? await Task.sleep(for: .milliseconds(resting ? 500 : 250))
        guard !Task.isCancelled else { return }
        if resting { CalendarPeek.shared.refresh() }
        peeking = resting
    }
}

/// One tab, as a line in the column.
struct SideRow: View { // Fork: was private; GroupedRows draws it
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    let live: Bool
    let tint: SpaceTint
    let pill: Namespace.ID
    let close: () -> Void

    @State private var pointing = false
    @ObservedObject private var benchHover = SideRowHover.shared // Fork (saved-close): `bench sections hover ID`
    /// Under the pointer — or, for a picture, under the bench's.
    private var hovering: Bool { pointing || benchHover.forced == tab.id }
    @State private var shake: CGFloat = 0
    @ObservedObject private var heat = Heat.shared

    private var editing: Bool { browser.editingTab == tab.id }

    var body: some View {
        HStack(spacing: 10) {
            if editing {
                TabAddressField(browser: browser)
                    .frame(height: 18)
            } else {
                if !tab.isBlank {
                    SideGlyphMark(prefs: browser.prefs, icon: tab.icon, letter: tab.monogram, tint: tint, size: 16) // Fork (settings-browse): Tabs show Letters / Site icons
                        .opacity(live ? 1 : 0.9)
                }
                if tab.bench {
                    // A script's tab, not yours.
                    Image(systemName: "flask")
                        .font(.system(size: 9))
                        .foregroundStyle(colour.opacity(0.7))
                }
                if tab.shy {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 9))
                        .foregroundStyle(colour.opacity(0.7))
                }
                Text(tab.label)
                    .font(.system(size: 15, weight: live ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(colour)
            }

            Spacer(minLength: 2)

            if !editing { HandBadges(tab: tab.id) } // Fork: agents' hands (Hands.swift)

            ZStack {
                if hovering, !editing {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(tint.muted)
                        .frame(width: 15, height: 15)
                        .background(tint.ink.opacity(0.07), in: Circle())
                        .transition(.opacity)
                } else if tab.loading {
                    Ring().transition(.opacity)
                } else if tab.noisy {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(tint.muted)
                        .transition(.opacity)
                } else if heat.isHot(tab), let reading = heat.reading(for: tab) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.orange.opacity(0.9))
                        .help("Using \(Int(reading.cpu))% CPU")
                        .transition(.opacity)
                }
            }
            .frame(width: editing ? 0 : 15, height: 15)
            .opacity(editing ? 0 : 1)
            .overlay {
                if !editing {
                    Color.clear
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                        .onTapGesture { if hovering { close() } }
                }
            }
            .animation(Motion.quick, value: hovering)
            .animation(Motion.quick, value: tab.loading)
            .animation(Motion.quick, value: tab.noisy)
        }
        .padding(.leading, SideBar.rowInset)
        .padding(.trailing, editing ? 10 : 8)
        .frame(height: SideBar.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ground }
        .modifier(Shake(travel: shake))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .modifier(OneClick(double: false) {
            if live { browser.beginTabEdit(tab) } else { browser.select(tab) }
        })
        .onHover { pointing = $0 }
        .contextMenu { TabMenu(browser: browser, tab: tab, close: close) }
        .modifier(CanvasTabRow(tab: tab)) // Fork (canvas): a canvas's rename field hangs from its row
        // The wheel button over a row closes it, as in Arc and Chrome. SwiftUI
        // never sees that button; the app's monitor does and says where
        // (Fork: MouseButtons). The row's own frame decides, not its hover
        // state, which a synthetic pointer never sets — handed up to the
        // column, which has the one listener (Fork: SideTargets).
        .anchorPreference(key: SideTargets.self, value: .bounds) { SideTargets(rows: [tab.id: $0]) }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.glide, value: editing)
        .onChange(of: browser.refusals) { _, _ in
            guard editing else { return }
            shake = 0
            withAnimation(.easeOut(duration: 0.5)) { shake = 1 }
        }
        .transition(.scale(scale: 0.94, anchor: .leading).combined(with: .opacity))
    }

    /// The live row is Arc's: paper half-way to white, lifting off the
    /// column on a soft shadow inside a one-point ring, its title a weight
    /// heavier than the rest.
    @ViewBuilder
    private var ground: some View {
        if live {
            ZStack(alignment: .leading) {
                Rectangle().fill(tint.pill)
                GeometryReader { geo in
                    Rectangle()
                        .fill(tint.ink.opacity(0.055))
                        .frame(width: geo.size.width * tab.reading)
                        .animation(.easeOut(duration: 0.15), value: tab.reading)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(tint.rim, lineWidth: 1)
            }
            .shadow(color: tint.lift, radius: 4, y: 1)
            .matchedGeometryEffect(id: "live", in: pill)
        } else if hovering {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.hover)
        }
    }

    /// Arc's sidebar is quiet because of its spacing and its tint, never
    /// because its titles are greyed out: a resting title there is nearly as
    /// legible as the live one, and a sleeping tab is not dimmed at all. A
    /// muted resting state makes the whole list read as disabled, which is
    /// the one thing a list of twenty-five things you keep must not do.
    private var colour: Color {
        tint.ink
    }
}

/// A row that is an action rather than a page. Quiet until the pointer is on it.
struct Quiet: View {
    let icon: String
    let title: String
    var height: CGFloat = 28
    var inset: CGFloat = 10
    /// What it wears under the pointer, and what it says — a tinted column
    /// hands its own in, so this row belongs to the same surface.
    var glow: Color?
    var ink: Color?
    /// What it wears at rest. Nothing, for a row that should disappear into
    /// the column; the favourites' soft square for the one row Arc lets you
    /// see from across the room.
    var fill: Color?
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 15))
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? (ink ?? Palette.faint).opacity(1) : (ink ?? Palette.faint).opacity(0.82))
            .padding(.leading, inset)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovering ? (glow ?? Palette.hover) : (fill ?? .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

/// A small square holding one symbol. Lit when what it opens is open.
struct Door: View {
    let icon: String
    var on = false
    var help = ""
    /// The door's square. Smaller where it shares a row with something else.
    var size: CGFloat = 26
    /// Fork: a tinted column hands its own ink, hover and glyph size in, so
    /// the doors on it are the column's colour rather than the app's grey.
    var ink: Color? = nil
    var glow: Color? = nil
    var glyph: CGFloat = 11
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Image(systemName: icon)
                .font(.system(size: glyph, weight: .medium))
                .foregroundStyle(ink.map { on || hovering ? $0 : $0.opacity(0.72) }
                                 ?? (on ? Palette.ink : (hovering ? Palette.ink.opacity(0.7) : Palette.muted)))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                        .fill(on ? Palette.wash : (hovering ? (glow ?? Palette.hover) : .clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: on)
    }
}

/// The address, at the top of the column where Arc keeps it: the site's host
/// on a soft field, and the doors for downloads, accounts and extensions at its end.
/// A click is ⌘L — the omnibox, with the whole address to change.
///
/// The Accounts key and the extensions come out only under the pointer, as
/// Arc's do: the key, the pinned ones, then the puzzle piece last, which goes to the Extensions page.
/// The host gives them its room and truncates, rather than sitting under
/// them. Downloads, while there are any, stay put ahead of them.
struct SideAddress: View {
    @ObservedObject var browser: Browser
    let tint: SpaceTint
    @ObservedObject private var downloads = Downloads.shared
    @ObservedObject private var bench = SideAddressHover.shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button { browser.edit() } label: {
                Group {
                    if let tab = browser.active {
                        Host(tab: tab, tint: tint)
                    } else {
                        Placeholder(tint: tint)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Change the address   ⌘L")
            if downloads.doorShowing {
                DownloadsDoor(browser: browser, size: 24, arrowEdge: .bottom)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            // Fork (lean-foot): the Accounts key, out with the extensions — and kept while its popup is up.
            if hovering || bench.forced || browser.vaultOpen {
                Door(icon: "key.horizontal", help: "Accounts   ⇧⌘Y", ink: tint.ink, glow: tint.hover) {
                    browser.vaultOpen.toggle()
                }
                .popover(isPresented: $browser.vaultOpen, arrowEdge: .bottom) { VaultPopup(browser: browser) }
                .transition(.opacity.combined(with: .offset(x: 6)))
            }
            ExtensionSlot(edge: .bottom, reveal: hovering || bench.forced, ink: tint.ink, glow: tint.hover) {
                browser.openSettings(.extensions)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovering || bench.forced ? tint.hover : tint.square)
        )
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: bench.forced)
        .animation(Motion.quick, value: browser.vaultOpen)
        .animation(Motion.settle, value: downloads.doorShowing)
    }

    private struct Host: View {
        @ObservedObject var tab: Tab
        let tint: SpaceTint

        var body: some View {
            if let url = tab.address, !tab.isBlank {
                Text(SideAddress.host(url))
                    .font(.system(size: 14.5))
                    .foregroundStyle(tint.ink.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Placeholder(tint: tint)
            }
        }
    }

    private struct Placeholder: View {
        let tint: SpaceTint
        var body: some View {
            Text("Search or Enter URL…")
                .font(.system(size: 14.5))
                .foregroundStyle(tint.faint)
                .lineLimit(1)
        }
    }

    /// `https://www.calendar.google.com/x` → `calendar.google.com`.
    static func host(_ url: URL) -> String {
        if let canvas = CanvasLinks.label(url) { return canvas } // Fork (canvas): "Canvas · <name>", not a host
        guard let host = url.host(), !host.isEmpty else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// The pointer over the address pill, as the bench fakes it: `ui
/// addressHover on` for a picture of what comes out under it. (Fork)
@MainActor
final class SideAddressHover: ObservableObject {
    static let shared = SideAddressHover()
    @Published var forced = false
}
