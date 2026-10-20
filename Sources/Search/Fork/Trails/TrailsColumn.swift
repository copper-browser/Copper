import AppKit
import SwiftUI
import UniformTypeIdentifiers

// How trails look in the column (Fork/Trails/Trails.swift says what they are).
//
// The column above the rows is untouched — the lights, the address, the
// favourites, the space's name, the rows you keep and their folders, the
// hairline and New Tab. Below New Tab, where Today's list was, are trails:
//
//   · a trail of one page is just that page's row, exactly as before;
//   · the trail you are on opens out: a header with its name, then its
//     pages as a lineage — each page under the page it was opened from, a
//     thin line from parent to child, three levels at most;
//   · every other trail is one row: its name, a little stack of the marks
//     of its pages and how many there are. A click goes to the page last
//     used; the chevron opens it without going anywhere; resting the pointer
//     on it a moment shows a Glance of its pages.
//   · under a quiet "Earlier" divider, trails Tide has carried off, slim
//     and a little faded, grouped Today / Yesterday / This Week.
//
// Same fonts, sizes, ink and tints as every other row on the column (the
// pages *are* `SideRow`s), the same pill sliding to the live page, and short
// springs that never bounce — none at all under Reduce Motion.

extension Trails {
    /// How far each level of lineage steps in: one mark's width, as folders.
    static let step: CGFloat = 16
    /// Reflow: short, settled, no bounce — and none at all under Reduce
    /// Motion, where rows simply appear where they belong.
    static var motion: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(duration: 0.24, bounce: 0)
    }
    /// A page being dragged between trails.
    static let dragType = UTType(exportedAs: "com.collinrijock.copper.trail-page", conformingTo: .data)

    static func dragging(_ tab: Tab) -> NSItemProvider {
        let provider = NSItemProvider()
        let id = tab.id.uuidString
        provider.registerDataRepresentation(forTypeIdentifier: dragType.identifier, visibility: .ownProcess) { done in
            done(id.data(using: .utf8), nil)
            return nil
        }
        provider.suggestedName = tab.label
        return provider
    }

    /// The tab a drop carried, if it was one of ours.
    static func dropped(_ providers: [NSItemProvider], in browser: Browser, then: @escaping (Tab) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(dragType.identifier) }) else { return false }
        _ = provider.loadDataRepresentation(forTypeIdentifier: dragType.identifier) { data, _ in
            guard let data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else { return }
            DispatchQueue.main.async {
                guard let tab = browser.tabs.first(where: { $0.id == id }) else { return }
                then(tab)
            }
        }
        return true
    }

    /// A trail's own colour: the space's hue, deep enough to read on paper,
    /// as a folder's glyph is (GroupHead).
    static func ink(_ tint: SpaceTint) -> Color {
        guard let hue = tint.hue else { return tint.ink.opacity(0.62) }
        return Color(hue: hue, saturation: tint.dark ? 0.52 : 0.82, brightness: tint.dark ? 0.82 : 0.62)
    }
}

/// Today's rows, as trails. Mounted by the sidebar in place of its Today
/// block while the flight is on.
struct TrailsColumn: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    let tint: SpaceTint
    let pill: Namespace.ID
    /// The Today rows, in the row's order.
    let tabs: [Tab]

    @ObservedObject private var trails = Trails.shared
    @ObservedObject private var flights = Flights.shared
    /// A page from the column is being dragged over it: the well for a new
    /// trail opens at the end of the fresh ones.
    @State private var carrying = false

    var body: some View {
        let column = trails.column(tabs, in: browser)
        VStack(alignment: .leading, spacing: SideBar.gap) {
            ForEach(column.fresh) { plan in
                TrailBlock(browser: browser, plan: plan, tint: tint, pill: pill)
            }
            if carrying {
                NewTrailWell(browser: browser, tint: tint)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
            if !column.earlier.isEmpty {
                EarlierDivider(tint: tint)
                ForEach(column.earlier, id: \.title) { bucket in
                    Text(bucket.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint.faint)
                        .padding(.leading, SideBar.rowInset)
                        .padding(.top, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(bucket.plans) { plan in
                        TrailSlimRow(browser: browser, plan: plan, tint: tint, pill: pill)
                    }
                }
            }
        }
        // A drop anywhere in the trails that isn't on a trail: a trail of its own.
        .onDrop(of: [Trails.dragType], isTargeted: Binding(get: { carrying }, set: { on in
            withAnimation(Trails.motion) { carrying = on }
        })) { providers in
            Trails.dropped(providers, in: browser) { tab in
                withAnimation(Trails.motion) { trails.reroot(tab, in: browser, keepTitle: true) }
            }
        }
        .animation(Trails.motion, value: column.fresh.map(\.id))
        .animation(Trails.motion, value: column.earlier.flatMap(\.plans).map(\.id))
        .onAppear { trails.attach(browser) }
    }
}

/// One fresh trail: a page row when it is one page, otherwise its header and
/// — while open — its pages.
private struct TrailBlock: View {
    @ObservedObject var browser: Browser
    let plan: Trails.Plan
    let tint: SpaceTint
    let pill: Namespace.ID

    @ObservedObject private var trails = Trails.shared

    var body: some View {
        if plan.single, let page = plan.pages.first {
            TrailPageRow(browser: browser, plan: plan, page: page, tint: tint, pill: pill, indent: false)
        } else {
            let open = trails.isOpen(plan)
            VStack(alignment: .leading, spacing: SideBar.gap) {
                TrailHead(browser: browser, plan: plan, open: open, tint: tint, pill: pill)
                if open {
                    ForEach(plan.pages) { page in
                        TrailPageRow(browser: browser, plan: plan, page: page, tint: tint, pill: pill, indent: true)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(y: -6)),
                                removal: .opacity
                            ))
                    }
                }
            }
        }
    }
}

// MARK: - a page

/// One page of a trail: the column's own row, stepped in by its depth, with
/// the trail's thread drawn in the gutter beside it.
private struct TrailPageRow: View {
    @ObservedObject var browser: Browser
    let plan: Trails.Plan
    let page: Trails.Page
    let tint: SpaceTint
    let pill: Namespace.ID
    /// Inside an open trail (stepped in, threaded) or a trail of one (flush).
    let indent: Bool

    @State private var target = false
    @ObservedObject private var trails = Trails.shared

    private var lead: CGFloat { indent ? CGFloat(page.depth + 1) * Trails.step : 0 }

    var body: some View {
        let editing = browser.editingTab == page.tab.id
        SideRow(
            browser: browser,
            tab: page.tab,
            live: page.tab.id == browser.activeID,
            tint: tint,
            pill: pill,
            editing: editing,
            refusals: editing ? browser.refusals : nil,
            close: { browser.close(page.tab) }
        )
        .padding(.leading, lead)
        .background(alignment: .topLeading) {
            if indent {
                TrailThread(page: page, tint: tint)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if target {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Trails.ink(tint).opacity(0.55), lineWidth: 1.5)
                    .padding(.leading, lead)
                    .allowsHitTesting(false)
            }
        }
        .onDrag { Trails.dragging(page.tab) }
        .onDrop(of: [Trails.dragType], isTargeted: $target) { providers in
            Trails.dropped(providers, in: browser) { tab in
                guard tab.id != page.tab.id else { return }
                withAnimation(Trails.motion) { trails.move(tab, to: plan.id, in: browser) }
            }
        }
        .id("tab-\(page.tab.id.uuidString)")
    }
}

/// The thread: from the trail's header (or the page above) down to each
/// page, a hairline that turns into the page's mark — so who opened what
/// reads at a glance, and the trail looks like what it is.
private struct TrailThread: View {
    let page: Trails.Page
    let tint: SpaceTint

    private static let row = SideBar.row
    private static let gap = SideBar.gap

    /// Where a mark sits across the row, for a page at `depth` (-1 is the
    /// header's): the column inset, the steps, half a mark.
    private static func x(_ depth: Int) -> CGFloat {
        CGFloat(depth + 1) * Trails.step + SideBar.rowInset + 8
    }

    var body: some View {
        let h = TrailThread.row, g = TrailThread.gap
        let width = TrailThread.x(page.depth) + 12
        Canvas { context, _ in
            let top: CGFloat = -g / 2 - 0.5
            let bottom: CGFloat = h + g / 2 + 0.5
            let mid = h / 2
            var path = Path()
            // Lines from further up that carry on past this page.
            for (level, passes) in page.rails.enumerated() where passes && level < page.depth {
                let x = TrailThread.x(level - 1)
                path.move(to: CGPoint(x: x, y: top))
                path.addLine(to: CGPoint(x: x, y: bottom))
            }
            // This page's own line: down from its parent and into its mark.
            let from = TrailThread.x(page.depth - 1)
            let to = TrailThread.x(page.depth) - 10
            let bend: CGFloat = 6
            path.move(to: CGPoint(x: from, y: top))
            path.addLine(to: CGPoint(x: from, y: mid - bend))
            path.addQuadCurve(to: CGPoint(x: from + bend, y: mid), control: CGPoint(x: from, y: mid))
            if to > from + bend { path.addLine(to: CGPoint(x: to, y: mid)) }
            // …and on down, for the pages after it at the same level.
            if page.more {
                path.move(to: CGPoint(x: from, y: mid - bend))
                path.addLine(to: CGPoint(x: from, y: bottom))
            }
            // A page with pages under it starts their line below its mark.
            if page.kids {
                let x = TrailThread.x(page.depth)
                path.move(to: CGPoint(x: x, y: mid + 11))
                path.addLine(to: CGPoint(x: x, y: bottom))
            }
            context.stroke(path, with: .color(tint.ink.opacity(tint.dark ? 0.22 : 0.17)),
                           style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
        }
        .frame(width: width, height: h)
    }
}

// MARK: - a trail's header, open or folded

/// A trail of more than one page, as one row: its mark (the search glass, or
/// a path), its name, and — folded — the marks of its pages stacked, and how
/// many. Under the pointer the mark becomes the chevron and the count the
/// cross. Open, it heads its pages and its thread starts under its mark.
private struct TrailHead: View {
    @ObservedObject var browser: Browser
    let plan: Trails.Plan
    let open: Bool
    let tint: SpaceTint
    let pill: Namespace.ID

    @ObservedObject private var trails = Trails.shared
    @State private var hovering = false
    @State private var overChevron = false
    @State private var target = false
    @State private var draft = ""
    /// When a click last opened or shut the trail, so a double-click can
    /// take its first click back.
    @State private var folded: Date?
    @FocusState private var typing: Bool

    private var renaming: Bool { trails.renaming == plan.id }
    /// Folded while holding the page you are on: it wears the live pill, so
    /// you can always see where you are.
    private var liveFolded: Bool { plan.live && !open }

    var body: some View {
        HStack(spacing: 0) {
            mark
                .padding(.trailing, 10)
            if renaming {
                TextField("Trail name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint.ink)
                    .focused($typing)
                    .onSubmit { trails.rename(plan.id, to: draft) }
                    .onExitCommand { trails.renaming = nil }
                    .onAppear {
                        draft = plan.title
                        DispatchQueue.main.async { typing = true }
                    }
                    .onChange(of: typing) { _, now in if !now, renaming { trails.rename(plan.id, to: draft) } }
            } else {
                Text(plan.title)
                    .font(.system(size: 15, weight: open || plan.live ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(tint.ink)
            }
            Spacer(minLength: 4)
            if !renaming {
                if !open {
                    TrailStack(tabs: plan.pages.map(\.tab), tint: tint)
                        .opacity(hovering ? 0.55 : 1)
                        .padding(.trailing, 6)
                        .transition(.opacity)
                }
                ZStack {
                    if hovering {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(tint.muted)
                            .frame(width: 15, height: 15)
                            .background(tint.ink.opacity(0.07), in: Circle())
                            .transition(.opacity)
                    } else {
                        Text("\(plan.pages.count)")
                            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(tint.faint)
                            .transition(.opacity)
                    }
                }
                .frame(width: 15, height: 15)
                .overlay {
                    Color.clear
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                        .onTapGesture { if hovering { trails.close(plan, in: browser) } }
                }
                .help(hovering ? "Close Trail" : "\(plan.pages.count) pages")
            }
        }
        .padding(.leading, SideBar.rowInset)
        .padding(.trailing, 8)
        .frame(height: SideBar.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ground
                if open {
                    // The thread starts under the header's mark.
                    Canvas { context, _ in
                        var path = Path()
                        let x = SideBar.rowInset + 8
                        path.move(to: CGPoint(x: x, y: SideBar.row / 2 + 11))
                        path.addLine(to: CGPoint(x: x, y: SideBar.row + SideBar.gap / 2 + 0.5))
                        context.stroke(path, with: .color(tint.ink.opacity(tint.dark ? 0.22 : 0.17)),
                                       style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
                    }
                    .frame(width: SideBar.rowInset + 20, height: SideBar.row)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
        }
        .overlay {
            if target {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Trails.ink(tint).opacity(0.55), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            guard !renaming else { return }
            // The second click of a double-click names the trail. The first
            // has already done what a click does: a fold it made is undone,
            // a jump to the trail stands — you rename the trail you are on.
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                if let folded, Date().timeIntervalSince(folded) < NSEvent.doubleClickInterval + 0.1 {
                    withAnimation(Trails.motion) { trails.toggle(plan) }
                }
                folded = nil
                trails.renaming = plan.id
                return
            }
            if plan.live {
                folded = Date()
                withAnimation(Trails.motion) { trails.toggle(plan) }
            } else {
                folded = nil
                browser.select(plan.recent)
            }
        }
        .onHover { over in
            hovering = over
            Glance.hover(plan.id, over && !open && !renaming)
        }
        .popover(isPresented: Binding(
            get: { trails.glancing == plan.id && !open },
            set: { if !$0, trails.glancing == plan.id { trails.glancing = nil } }
        ), arrowEdge: .trailing) {
            TrailGlance(browser: browser, plan: plan, tint: tint)
        }
        .contextMenu { TrailMenu(browser: browser, plan: plan, open: open) }
        .onDrop(of: [Trails.dragType], isTargeted: $target) { providers in
            Trails.dropped(providers, in: browser) { tab in
                withAnimation(Trails.motion) { trails.move(tab, to: plan.id, in: browser) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Trail \(plan.title), \(plan.pages.count) pages")
        .accessibilityHint(open ? "Shows its pages below" : "Goes to the page you used last")
        .animation(Motion.quick, value: hovering)
        .animation(Trails.motion, value: open)
        .transition(.opacity)
    }

    /// The trail's mark — or, under the pointer, the chevron that opens and
    /// shuts it without going anywhere.
    private var mark: some View {
        ZStack {
            Image(systemName: plan.searched ? "magnifyingglass" : "point.topleft.down.curvedto.point.bottomright.up")
                .font(.system(size: plan.searched ? 13 : 13.5, weight: .semibold))
                .foregroundStyle(Trails.ink(tint))
                .opacity(hovering ? 0 : 1)
            Image(systemName: "chevron.right")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(overChevron ? tint.ink : tint.muted)
                .rotationEffect(.degrees(open ? 90 : 0))
                .opacity(hovering ? 1 : 0)
        }
        .frame(width: 16, height: 16)
        .contentShape(Rectangle().inset(by: -7))
        .onHover { overChevron = $0 }
        .onTapGesture { withAnimation(Trails.motion) { trails.toggle(plan) } }
        .help(open ? "Fold this trail" : "Open this trail here")
    }

    @ViewBuilder
    private var ground: some View {
        if liveFolded {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.pill)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(tint.rim, lineWidth: 1)
                }
                .shadow(color: tint.lift, radius: 4, y: 1)
                .matchedGeometryEffect(id: "live", in: pill)
                .frame(height: SideBar.row)
        } else if hovering || target {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.hover)
                .frame(height: SideBar.row)
        }
    }
}

/// The marks of a trail's pages, overlapping like a hand of cards: three at
/// most, newest in front, each ringed so it reads against the one behind.
struct TrailStack: View {
    let tabs: [Tab]
    let tint: SpaceTint
    var size: CGFloat = 13

    /// One mark per site: a trail through five Wikipedia pages is one W,
    /// not five.
    private var shown: [Tab] {
        var seen = Set<String>()
        var marks: [Tab] = []
        for tab in tabs {
            let key = (tab.pending ?? tab.address)?.host() ?? tab.id.uuidString
            guard seen.insert(key).inserted else { continue }
            marks.append(tab)
            if marks.count == 3 { break }
        }
        return marks
    }

    var body: some View {
        let shown = shown
        HStack(spacing: -size * 0.38) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, tab in
                StackMark(tab: tab, tint: tint, size: size)
                    .zIndex(Double(shown.count - index))
            }
        }
        .accessibilityHidden(true)
    }

    private struct StackMark: View {
        @ObservedObject var tab: Tab
        let tint: SpaceTint
        let size: CGFloat

        var body: some View {
            RowMark(icon: tab.icon, letter: tab.monogram, tint: tint, size: size)
                .padding(1.5)
                .background(
                    RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                        .fill(tint.dark ? Color(white: 0.22) : Color.white)
                        .shadow(color: .black.opacity(tint.dark ? 0.35 : 0.10), radius: 1.2, y: 0.5)
                )
        }
    }
}

// MARK: - Earlier

/// The quiet line Tide's trails drift under: a hairline either side of one
/// small word.
private struct EarlierDivider: View {
    let tint: SpaceTint

    var body: some View {
        HStack(spacing: 7) {
            Rectangle().fill(tint.hairline).frame(height: 1)
            HStack(spacing: 4) {
                Image(systemName: "water.waves")
                    .font(.system(size: 9, weight: .semibold))
                Text("Earlier")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(tint.faint)
            .fixedSize()
            Rectangle().fill(tint.hairline).frame(height: 1)
        }
        .padding(.horizontal, SideBar.rowInset)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Earlier trails")
    }
}

/// A trail Tide has carried off: one slim row at less emphasis. A click
/// brings it back to the top, where it opens on the page used last.
private struct TrailSlimRow: View {
    @ObservedObject var browser: Browser
    let plan: Trails.Plan
    let tint: SpaceTint
    let pill: Namespace.ID

    @ObservedObject private var trails = Trails.shared
    @State private var hovering = false
    @State private var target = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if plan.single, let tab = plan.pages.first?.tab {
                    SlimMark(tab: tab, tint: tint)
                } else {
                    Image(systemName: plan.searched ? "magnifyingglass" : "point.topleft.down.curvedto.point.bottomright.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Trails.ink(tint).opacity(0.8))
                }
            }
            .frame(width: 16, height: 16)
            Text(plan.single ? (plan.pages.first?.tab.label ?? plan.title) : plan.title)
                .font(.system(size: 13.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(tint.ink.opacity(hovering ? 0.9 : 0.66))
            Spacer(minLength: 4)
            if hovering {
                Image(systemName: "xmark")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(tint.muted)
                    .frame(width: 14, height: 14)
                    .background(tint.ink.opacity(0.07), in: Circle())
                    .contentShape(Circle().inset(by: -6))
                    .onTapGesture { trails.close(plan, in: browser) }
                    .help(plan.single ? "Close Tab" : "Close Trail")
                    .transition(.opacity)
            } else if !plan.single {
                Text("\(plan.pages.count)")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(tint.faint.opacity(0.8))
                    .transition(.opacity)
            }
        }
        .padding(.leading, SideBar.rowInset)
        .padding(.trailing, 9)
        .frame(height: 29)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering || target ? tint.hover : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture { withAnimation(Trails.motion) { browser.select(plan.recent) } }
        .onHover { over in
            hovering = over
            Glance.hover(plan.id, over)
        }
        .popover(isPresented: Binding(
            get: { trails.glancing == plan.id },
            set: { if !$0, trails.glancing == plan.id { trails.glancing = nil } }
        ), arrowEdge: .trailing) {
            TrailGlance(browser: browser, plan: plan, tint: tint)
        }
        .contextMenu { TrailMenu(browser: browser, plan: plan, open: false) }
        .onDrag { Trails.dragging(plan.recent) }
        .onDrop(of: [Trails.dragType], isTargeted: $target) { providers in
            Trails.dropped(providers, in: browser) { tab in
                withAnimation(Trails.motion) { trails.move(tab, to: plan.id, in: browser) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Earlier trail \(plan.title), \(plan.pages.count) pages")
        .animation(Motion.quick, value: hovering)
    }

    private struct SlimMark: View {
        @ObservedObject var tab: Tab
        let tint: SpaceTint
        var body: some View {
            RowMark(icon: tab.icon, letter: tab.monogram, tint: tint, size: 14)
                .saturation(0.7)
                .opacity(0.85)
        }
    }
}

// MARK: - the new-trail well and the menu

/// Shown while a page is carried over the trails: let go here and it starts
/// a trail of its own.
private struct NewTrailWell: View {
    @ObservedObject var browser: Browser
    let tint: SpaceTint

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 16)
            Text("New trail")
                .font(.system(size: 14))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Trails.ink(tint))
        .padding(.leading, SideBar.rowInset)
        .frame(height: SideBar.row - 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Trails.ink(tint).opacity(0.45), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
        )
        .allowsHitTesting(false)
    }
}

/// A trail's row menu: name it, ask about it, put it on the canvas, fold
/// it, close it.
struct TrailMenu: View {
    @ObservedObject var browser: Browser
    let plan: Trails.Plan
    let open: Bool

    var body: some View {
        let trails = Trails.shared
        if !plan.single {
            Button("Rename Trail…") { trails.renaming = plan.id }
            Button(open ? "Fold Trail" : "Open Trail Here") {
                withAnimation(Trails.motion) { trails.toggle(plan) }
            }
            Divider()
        }
        Button("Ask About This Trail") { trails.ask(plan, in: browser) }
        Button("Send Trail to Canvas") { trails.sendToCanvas(plan, in: browser) }
        Divider()
        Button(plan.single ? "Close Tab" : "Close Trail · \(plan.pages.count) Pages", role: .destructive) {
            trails.close(plan, in: browser)
        }
    }
}
