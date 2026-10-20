import SwiftUI

// How groups look in the column: Arc's folders. A header where a run of
// grouped tabs starts — chevron, folder glyph in the group's colour, the
// name, and the count only while it is shut — its rows stepped in under it.
// Which folder sits inside which is read out of the names by
// `FolderTree` (Fork/Folders.swift). The rows themselves are upstream's
// SideRow, untouched; this only decides what goes between them and how far
// in each one starts.

struct GroupedRows: View, Equatable {
    /// Read, not watched (Fork: space-columns): what the rows show of the
    /// browser is handed in below, so a parked space's column — and the
    /// column on screen, for a change that is not about its rows — is not
    /// redrawn by every change to the browser.
    let browser: Browser
    let prefs: Preferences
    @ObservedObject var groups = Groups.shared
    let pill: Namespace.ID
    let tint: SpaceTint
    /// The sidebar draws the loose list as two blocks (Saved, Today); each
    /// hands in its own rows, in order, and this draws only those.
    let tabs: [Tab]
    /// The space the rows are in: its folders, and its column (SpaceColumns).
    let space: UUID
    /// The live row, the row being renamed and its refusals, and the id the
    /// live row's pill wears — the browser's, for the column on screen.
    var active: Tab.ID? = nil
    var editing: Tab.ID? = nil
    var refusals = 0
    var pillID = "live"
    /// The Saved block also draws the space's empty top-level folders.
    var homeless = false
    /// Where this block starts in the whole loose list, so a drag inside it
    /// moves the tab to the right place in the row and not to the row's top.
    var offset = 0
    /// Which of the sidebar's two blocks this is. A row picked up in one is
    /// over the other as soon as the pointer is (Fork/SavedDrop.swift), and
    /// let go there it crosses the seam, at the place that opened for it.
    var block: SavedDrop.Block? = nil
    /// Told when a row is picked up and put down, so the column knows not
    /// to scroll out from under the hand.
    var holding: ((Bool) -> Void)? = nil

    @State private var dragging: Tab.ID?
    @State private var from = 0
    @State private var travel: CGFloat = 0

    private var drag: SideDrag { SideDrag.of(browser) }

    static let row: CGFloat = 37
    static let gap: CGFloat = 4

    private var loose: [Tab] { tabs }

    /// Everything the body reads but the groups, which it watches itself.
    /// `holding` is the same column's hook every time.
    static func == (a: GroupedRows, b: GroupedRows) -> Bool {
        a.browser === b.browser && a.pill == b.pill && a.tint == b.tint && a.space == b.space
            && a.active == b.active && a.editing == b.editing && a.refusals == b.refusals && a.pillID == b.pillID
            && a.homeless == b.homeless && a.offset == b.offset && a.block == b.block
            && a.tabs.count == b.tabs.count && zip(a.tabs, b.tabs).allSatisfy { $0 === $1 }
    }

    /// What the column draws, top to bottom: a header at the start of each
    /// run, then the run's rows — none of them, nor any folder inside it,
    /// while the folder is shut. Worked out by `FolderTree`.
    private var rows: [FolderRow] {
        FolderTree.plan(loose, homeless: homeless ? groups.homeless(in: space) : [], space: space)
    }

    /// Rows the column shows beyond one per tab: a header for each folder,
    /// less the rows a folded one hides. For sizing a block before it is
    /// drawn (see SideBar.today).
    static func extraRows(in tabs: [Tab]) -> Int {
        let loose = tabs.filter { $0.pin == nil }
        return FolderTree.plan(loose).count - loose.count
    }

    var body: some View {
        VStack(spacing: GroupedRows.gap) {
            ForEach(rows) { row in
                switch row {
                case .head(let group, let count, _, let depth, let label):
                    if block == .saved { SavedDropGap(drag: drag, anchor: .beforeFolder(group.id), tint: tint) }
                    GroupHead(browser: browser, group: group, count: count, label: label, tint: tint)
                        .padding(.leading, CGFloat(depth) * Folders.step)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SavedDrop.space)) } action: { frame in
                            if block == .saved { drag.heads[group.id] = frame }
                        }
                    // Onto the folder: its first place opens under it, open or shut.
                    if block == .saved { SavedDropGap(drag: drag, anchor: .into(group.id), tint: tint) }
                case .tab(let tab, let index, let group, let depth):
                    let step = GroupedRows.row + GroupedRows.gap
                    let held = dragging == tab.id
                    if block == .saved { SavedDropGap(drag: drag, anchor: .before(tab.id), tint: tint) }
                    VStack(spacing: GroupedRows.gap) {
                        let renaming = tab.id == editing
                        SideRow(
                            browser: browser,
                            tab: tab,
                            live: tab.id == active,
                            tint: tint,
                            pill: pill,
                            editing: renaming,
                            refusals: renaming ? refusals : nil,
                            pillID: tab.id == active ? pillID : "live",
                            // Fork (saved-close): the cross (and Close Tab on the
                            // row's menu) is the one close that takes a Saved row
                            // out of Saved; ⌘W only puts it down.
                            close: { Sections.shared.remove(tab, in: browser) }
                        )
                        .equatable()
                        .padding(.leading, CGFloat(depth) * Folders.step)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { SideHand.frames[tab.id] = $0 }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SavedDrop.space)) } action: { frame in
                            if dragging != tab.id { drag.rows[tab.id] = frame }
                        }
                        // A hair of the folder's colour down the middle of
                        // its header's glyph, under the rows it holds. The
                        // step in is what says they are inside it; this
                        // only says which folder, once two are open at once.
                        .overlay(alignment: .leading) {
                            if let group, depth > 0 {
                                RoundedRectangle(cornerRadius: 0.5)
                                    .fill(folderTint(group).opacity(0.2))
                                    .frame(width: 1)
                                    .padding(.vertical, 3)
                                    .offset(x: CGFloat(depth - 1) * Folders.step + SideBar.rowInset + 7.5)
                            }
                        }
                    }
                    // In the hand, the row is a card lifted off the column: it
                    // passes over other rows, and its title must stay its own.
                    .background {
                        if held { SideDragCardGround(tint: tint).padding(.leading, CGFloat(depth) * Folders.step) }
                    }
                    // Over the other block its card is drawn by the column
                    // (SideDragCard) and its own place here is left empty.
                    .modifier(SideDragHidden(drag: drag, held: held))
                    .offset(y: held ? travel - CGFloat(index - from) * step : 0)
                    .zIndex(held ? 1 : 0)
                    .shadow(color: .black.opacity(held ? 0.14 : 0), radius: 12, y: 4)
                    .gesture(reorder(tab: tab, index: index, step: step))
                    if block == .saved { SavedDropGap(drag: drag, anchor: .after(tab.id), tint: tint) }
                }
            }
            if block == .saved { SavedDropGap(drag: drag, anchor: .end, tint: tint) }
        }
        .coordinateSpace(name: "rows")
        // The Saved block's own frame: where it ends, for a row on its way
        // down out of it, whatever is in the hand.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SavedDrop.space)) } action: { frame in
            if block == .saved { drag.place(saved: frame, in: space) }
        }
    }

    /// A folder with no colour of its own wears the space's, as Arc's do.
    private func folderTint(_ group: TabGroup) -> Color {
        group.hue.map { Color(hue: $0, saturation: 0.55, brightness: 0.75) } ?? tint.dot
    }

    /// Upstream's reorder, unchanged inside the block but for the drop: a
    /// row let go inside another group's run joins it, and one dragged clear
    /// of its own leaves. With the pointer over the other block it stops
    /// reordering here and a row's room opens where it would land there
    /// (Fork/SavedDrop.swift); let go, it goes there.
    private func reorder(tab: Tab, index: Int, step: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named(SavedDrop.space))
            .onChanged { value in
                if dragging != tab.id {
                    dragging = tab.id
                    from = index
                    holding?(true)
                    if let block { drag.carry(tab.id, from: block, at: value.startLocation.y, in: browser) }
                }
                travel = value.translation.height
                drag.move(to: value.location.y, in: browser)
                guard drag.target == nil else { return }
                let moved = Int((travel / step).rounded())
                let target = min(max(0, from + moved), loose.count - 1)
                if target != index {
                    withAnimation(Motion.settle) {
                        browser.move(tab, to: offset + target + browser.pinnedCount)
                    }
                }
            }
            .onEnded { _ in
                let target = drag.target
                drag.end()
                withAnimation(Motion.settle) {
                    dragging = nil
                    travel = 0
                }
                holding?(false)
                if let target {
                    withAnimation(Motion.settle) { drag.drop(tab, at: target, in: browser) }
                } else {
                    groups.settle(tab, in: browser)
                }
            }
    }
}

/// A folder's line: fold it, name it, colour it, make another inside it,
/// or let it go.
///
/// A folder is a row like any other row, and that is the whole of its
/// layout: the glyph sits in the row's own 16pt mark column and the name
/// starts where every title on the column starts, so a folder at the top
/// level is flush with the saved tabs around it and only the tabs *inside*
/// it step in — one mark's width, once per level. The chevron costs no
/// width at all: it takes the glyph's place under the pointer, which is
/// where Arc keeps its own, and rotates as the folder opens.
struct GroupHead: View {
    let browser: Browser // Fork (space-columns): only its menu's Close acts on it
    @ObservedObject var groups = Groups.shared
    let group: TabGroup
    let count: Int
    /// The part of the name below the folder it is in — `BuildrFi`, not
    /// `Misc › BuildrFi`.
    var label: String? = nil
    let tint: SpaceTint

    @State private var hovering = false
    @State private var renaming = false
    @State private var adding = false
    @State private var draft = ""

    /// A folder with no colour of its own wears the space's, as Arc's do.
    /// Deeper than the column it sits on, either way round: the folder is
    /// the one drawn thing in a row of photographed ones, and a wash of the
    /// ground's own hue would leave it a smudge among real favicons.
    private var colour: Color {
        guard let hue = group.hue ?? tint.hue else { return Palette.muted }
        return Color(hue: hue, saturation: tint.dark ? 0.52 : 0.82, brightness: tint.dark ? 0.82 : 0.66)
    }

    /// What the folder is made of: paper, not paint. Arc's folder is a pale
    /// near-white card with the space's colour around it, which is what
    /// lets it sit in a column of real favicons without shouting over them.
    private var paper: Color {
        tint.dark ? Color(hue: group.hue ?? tint.hue ?? 0, saturation: 0.10, brightness: 0.90)
                  : Color.white.opacity(0.92)
    }

    /// The mark column: the folder, or — under the pointer, in its place —
    /// the chevron that says which way a click will go.
    private var mark: some View {
        ZStack {
            // Arc's pair: shut, a solid folder in the space's colour; open,
            // a paper one in an outline of it, showing it holds something.
            ZStack {
                if group.collapsed {
                    Image(systemName: "folder.fill").foregroundStyle(colour)
                } else {
                    Image(systemName: "folder.fill").foregroundStyle(paper)
                    Image(systemName: "folder").foregroundStyle(colour)
                    Image(systemName: "ellipsis")
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(colour)
                        .offset(y: 1.5)
                }
            }
            .font(.system(size: 15))
            .opacity(hovering ? 0 : 1)

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint.muted)
                .rotationEffect(.degrees(group.collapsed ? 0 : 90))
                .opacity(hovering ? 1 : 0)
        }
        .frame(width: 16, height: 16)
    }

    var body: some View {
        HStack(spacing: 0) {
            mark
                .padding(.trailing, 10)
            Text(label ?? group.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(tint.ink)
            Spacer(minLength: 2)
            // Arc shows no count; a shut folder says how much it holds only
            // when the pointer asks.
            if group.collapsed, count > 0, hovering {
                Text("\(count)")
                    .font(.system(size: 11))
                    .foregroundStyle(tint.faint)
                    .padding(.trailing, 9)
                    .transition(.opacity)
            }
        }
        .padding(.leading, SideBar.rowInset)
        .frame(height: GroupedRows.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovering ? tint.hover : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { withAnimation(Motion.settle) { groups.toggleCollapsed(group.id) } }
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .popover(isPresented: $renaming) {
            TextField("Name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .padding(8)
                .onSubmit { groups.rename(group.id, to: draft); renaming = false }
        }
        .popover(isPresented: $adding) {
            TextField("Folder name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .padding(8)
                .onSubmit {
                    groups.createInside(group, named: draft)
                    adding = false
                }
        }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.settle, value: group.collapsed)
        .transition(.opacity)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Rename…") { draft = group.name; renaming = true }
        Menu("Colour") {
            Button("Grey") { groups.tint(group.id, hue: nil) }
            ForEach(Array(stride(from: 0.0, to: 1.0, by: 0.125)), id: \.self) { hue in
                Button { groups.tint(group.id, hue: hue) } label: {
                    Label { Text(String(format: "%.0f°", hue * 360)) } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(Color(hue: hue, saturation: 0.55, brightness: 0.75))
                    }
                }
            }
        }
        Button(group.collapsed ? "Expand" : "Collapse") { groups.toggleCollapsed(group.id) }
        Button("New Folder Inside…") { draft = ""; adding = true }
        Divider()
        Button("Ungroup") { groups.dissolve(group.id) }
        Button("Close Tabs in Group", role: .destructive) { groups.closeAll(group.id, in: browser) }
    }
}

/// The Group submenu on a tab's context menu, in both layouts.
struct GroupMenu: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject var groups = Groups.shared

    var body: some View {
        Divider()
        Menu("Group") {
            Button("New Group from Tab") {
                let group = groups.create(named: Fork.brand(tab.address?.host()))
                groups.assign(tab, to: group, in: browser)
            }
            .disabled(tab.isBlank)
            if !groups.all.isEmpty { Divider() }
            ForEach(groups.all) { group in
                Button { groups.assign(tab, to: group, in: browser) } label: {
                    Label { Text(group.name) } icon: {
                        Image(systemName: groups.membership[tab.id] == group.id ? "checkmark" : "circle.fill")
                            .foregroundStyle(groups.membership[tab.id] == group.id ? Palette.ink : group.tint)
                    }
                }
            }
            if groups.group(of: tab) != nil {
                Divider()
                Button("Remove from Group") { groups.remove(tab) }
            }
        }
    }
}

/// The Groups menu in the menu bar; ⌃G is the one key to learn.
struct GroupCommands: Commands {
    @ObservedObject var browser: Browser
    @ObservedObject var groups = Groups.shared

    var body: some Commands {
        CommandMenu("Groups") {
            Button("New Group from This Tab") {
                guard let tab = browser.active else { return }
                let group = groups.create(named: Fork.brand(tab.address?.host()))
                groups.assign(tab, to: group, in: browser)
            }
            .keyboardShortcut("g", modifiers: [.control, .shift])
            .disabled(browser.active?.isBlank ?? true)
            Button("Remove from Group") {
                if let tab = browser.active { groups.remove(tab) }
            }
            .disabled(browser.active.map { groups.group(of: $0) == nil } ?? true)
            if !groups.all.isEmpty {
                Divider()
                ForEach(groups.all) { group in
                    Button("Move to \(group.name)") {
                        if let tab = browser.active { groups.assign(tab, to: group, in: browser) }
                    }
                }
            }
        }
    }
}
