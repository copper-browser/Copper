import AppKit
import SwiftUI

// The space, as the column shows it — and the ways to manage it.
//
// The foot used to read as one truncated name and seven identical dots: the
// current space's name cut to a letter, every other space an 8pt circle in
// a colour you could not name, and rename / colour / profile / delete hidden
// behind a right-click on a dot. Arc labels the space at the top of its
// column and draws icons, not dots, at the foot; this does the same, and puts
// the management two clicks away at most:
//
// - `SpaceHeader`: a title row under the traffic lights — the space's mark,
//   its name in full, a chevron. Click the mark for Settings › Spaces, the
//   rest for the space menu; hover shows how many tabs it holds.
// - `SpaceStrip`: every space a chip at the foot — emoji, symbol or a dot,
//   the current one in colour. Click another space's chip to go there, the
//   current one's for Settings › Spaces (Arc's two clicks); hover names it at
//   once; drag reorders; a plus makes a space and opens its page at once.
// - Settings › Spaces (SpacePage.swift): name, icon, look, profile — and
//   Delete, which asks first, and can keep the tabs.

// MARK: - the mark

/// What stands for a space: its emoji, its symbol, or its first letter, in
/// the space's own colour.
struct SpaceGlyph: View {
    let space: Space
    let size: CGFloat
    let dark: Bool
    /// The letter or symbol's colour; the space's own mark colour by default.
    var ink: Color?
    /// Arc's way: the icon on its own, filling its square, and a small dot
    /// for a space that has no icon — never a letter.
    var bare = false

    var body: some View {
        let tint = SpaceTint(space: space, dark: dark)
        Group {
            if let emoji = space.emoji {
                Text(emoji).font(.system(size: size * (bare ? 0.9 : 0.6)))
            } else if let symbol = space.symbol {
                Image(systemName: symbol)
                    .font(.system(size: size * (bare ? 0.78 : 0.48), weight: .semibold))
                    .foregroundStyle(ink ?? tint.mark)
            } else if bare {
                Circle()
                    .fill(ink ?? tint.mark)
                    .frame(width: size * 0.42, height: size * 0.42)
            } else {
                Text(space.letter)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(ink ?? tint.mark)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Which space Settings › Spaces shows, and the door every "edit this
/// space" click goes through.
@MainActor
final class SpaceEditing: ObservableObject {
    static let shared = SpaceEditing()
    /// The space picked on the page; nil is the one you are in.
    @Published var selected: UUID?

    /// The space whose page is up: Settings open on Spaces in the window in
    /// front, or nil. What the bench reads back as `page`.
    var space: UUID? {
        let browser = Windows.current
        guard browser.tuning, browser.settingsPage == .spaces else { return nil }
        return selected ?? Spaces.shared.current(in: browser)
    }

    /// Settings, on Spaces, with this space picked.
    func open(_ id: UUID, in browser: Browser? = nil) {
        selected = id
        (browser ?? Windows.current).openSettings(.spaces)
    }

    /// Settings put away, if it is on Spaces.
    func close() {
        let browser = Windows.current
        if browser.tuning, browser.settingsPage == .spaces { browser.tuning = false }
        selected = nil
    }

    /// A space deleted: the page goes back to the one you are in rather
    /// than closing under you.
    func forget(_ id: UUID) {
        if selected == id { selected = nil }
    }

    /// A chip at the foot, clicked — and `bench spaces tap`, by the same
    /// door. Arc's rule: another space's icon takes you there; the icon of
    /// the space you are in opens its page, so a second click on a chip
    /// you just switched to is the way in.
    func pressed(_ id: UUID, in browser: Browser) {
        let spaces = Spaces.shared
        if id == spaces.current(in: browser) { open(id, in: browser) } else { spaces.select(id, in: browser) }
    }

    /// Settings › Spaces for a space, drawn off screen at the page's width
    /// and laid out whole — for the bench, which gets the whole page at once
    /// this way rather than the top of a scroll. `dark` nil is the app's own
    /// appearance.
    static func picture(of id: UUID, in browser: Browser, dark: Bool? = nil) -> NSBitmapImageRep? {
        let dark = dark ?? (NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        let was = shared.selected
        shared.selected = id
        defer { shared.selected = was }
        return SettingsPicture.draw(SpacesSettingsPage(browser: browser), dark: dark)
    }
}

// MARK: - the header

/// The title row: which space this column is. Under the lights, above the
/// favourites — the one label the column was missing.
struct SpaceHeader: View {
    /// Read, not watched: every space's column has its own header, and a
    /// parked one must not be redrawn by the browser (SpaceColumns).
    let browser: Browser
    /// Whose column this heads.
    let space: UUID
    @ObservedObject private var spaces = Spaces.shared
    @Environment(\.colorScheme) private var scheme
    @State private var over = false
    @State private var overMark = false

    var body: some View {
        let space = spaces.all.first { $0.id == self.space } ?? spaces.space(in: browser)
        let tint = SpaceTint(space: space, dark: scheme == .dark)
        // Arc's: the space's icon where a row's mark goes and its name in
        // the theme's own colour, first thing under the favourites. The
        // icon is its own door, to Settings › Spaces; the rest is the menu.
        HStack(spacing: 0) {
            Button { SpaceEditing.shared.open(space.id) } label: {
                SpaceGlyph(space: space, size: 16, dark: scheme == .dark, ink: tint.muted, bare: true)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(overMark ? tint.hover : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { overMark = $0 }
            .help("Customize \(space.title)…")
            // The mark's centre stays where a row's mark is.
            .padding(.leading, -4)
            .padding(.trailing, 6)
            Menu {
                SpaceMenu(browser: browser, space: space)
            } label: {
                header(space, tint: tint)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        }
        .padding(.leading, SideBar.rowInset)
        .padding(.trailing, 8)
        .frame(height: SideBar.row)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(over ? tint.hover : .clear))
        .onHover { over = $0 }
        .help("\(space.title) — click for the space menu")
        .animation(Motion.quick, value: over)
        .animation(Motion.quick, value: overMark)
    }

    private func header(_ space: Space, tint: SpaceTint) -> some View {
        HStack(spacing: 10) {
            Text(space.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint.muted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if over {
                let n = spaces.count(of: space.id, in: browser)
                Text("\(n) tab\(n == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(tint.faint)
                    .transition(.opacity)
            }
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint.muted)
                .frame(width: 16)
                .opacity(over ? 1 : 0)
        }
        .frame(height: SideBar.row)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

// MARK: - the strip at the foot of the column

struct SpaceStrip<Tools: View>: View {
    @ObservedObject var browser: Browser
    /// The column's ink as the slide mixes it (SlideInk), or nil for the
    /// current space's own.
    var tint: SpaceTint? = nil
    /// The column's own small doors — bookmarks, extensions. They share the
    /// strip's row, the way Arc's do.
    @ViewBuilder var tools: () -> Tools
    @ObservedObject private var spaces = Spaces.shared
    @Environment(\.colorScheme) private var scheme
    @State private var hovering: UUID?
    /// How wide the row of chips actually is, against how wide it wants to
    /// be — when the second is larger the row scrolls, and says so with a
    /// soft edge instead of a chip cut in half.
    @State private var roomForChips: CGFloat = 0

    /// A chip picked up to be moved — the same shape as the favourites' drag.
    @State private var dragging: UUID?
    @State private var from = 0
    @State private var travel: CGFloat = 0

    private var step: CGFloat { SpaceChip.size + SpaceChip.gap }

    private var ink: SpaceTint { tint ?? SpaceTint(space: spaces.space(in: browser), dark: scheme == .dark) }

    /// Every space as a chip, the current one lifted; a plus; the doors.
    /// When the chips outgrow the room, the row of them scrolls sideways
    /// with the current one kept in view — no chip ever shrinks to a dot
    /// and no name is ever cut to a letter.
    /// Arc's foot: the library door at the left, every space's icon in the
    /// middle — the current one in colour, the rest quiet — and a plus at
    /// the right.
    var body: some View {
        HStack(spacing: 0) {
            tools()
            Spacer(minLength: 4)
            chips
            Spacer(minLength: 4)
            plus
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .overlayPreferenceValue(ChipFrames.self) { frames in label(frames) }
    }

    private var chips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: SpaceChip.gap) {
                    ForEach(Array(spaces.all.enumerated()), id: \.element.id) { index, space in
                        chip(space, index: index)
                    }
                }
                .padding(.vertical, 1)
                .coordinateSpace(name: "chips")
                .animation(Motion.settle, value: spaces.all.map(\.id))
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: CGFloat(spaces.all.count) * step)
            .background(GeometryReader { geo in
                Color.clear.preference(key: StripRoom.self, value: geo.size.width)
            })
            .onPreferenceChange(StripRoom.self) { roomForChips = $0 }
            .mask(overflowing ? AnyView(SpaceStrip.fade) : AnyView(Rectangle()))
            .onChange(of: spaces.current(in: browser)) { _, id in
                withAnimation(Motion.glide) { proxy.scrollTo(id, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(spaces.current(in: browser), anchor: .center) }
        }
    }

    private var overflowing: Bool { roomForChips + 1 < CGFloat(spaces.all.count) * step }

    /// The row runs out under a soft edge at both ends, the way the column's
    /// two blocks of rows do.
    private static var fade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func chip(_ space: Space, index: Int) -> some View {
        let held = dragging == space.id
        return SpaceChip(space: space, current: space.id == spaces.current(in: browser), dark: scheme == .dark,
                         over: hovering == space.id, ink: ink.ink, glow: ink.hover)
            .id(space.id)
            .anchorPreference(key: ChipFrames.self, value: .bounds) { [space.id: $0] }
            .offset(x: held ? travel - CGFloat(index - from) * step : 0)
            .zIndex(held ? 1 : 0)
            .shadow(color: .black.opacity(held ? 0.16 : 0), radius: 8, y: 2)
            .contentShape(Rectangle())
            .onTapGesture { SpaceEditing.shared.pressed(space.id, in: browser) }
            .gesture(reorder(space, index: index))
            .onHover { over in hovering = over ? space.id : (hovering == space.id ? nil : hovering) }
            .help(space.id == spaces.current(in: browser) ? "\(space.title) — click to customize" : space.title)
            .contextMenu { SpaceMenu(browser: browser, space: space) }
    }

    /// Pick a chip up and the others make way, one step per chip's width —
    /// `pinReorder` in Side.swift, along one axis.
    private func reorder(_ space: Space, index: Int) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("chips"))
            .onChanged { value in
                if dragging != space.id {
                    dragging = space.id
                    from = index
                }
                travel = value.translation.width
                let moved = Int((travel / step).rounded())
                let target = min(max(0, from + moved), spaces.all.count - 1)
                if target != index {
                    withAnimation(Motion.settle) { spaces.move(space.id, to: target) }
                }
            }
            .onEnded { _ in
                withAnimation(Motion.settle) {
                    dragging = nil
                    travel = 0
                }
            }
    }

    /// The hovered space's name, at once, above its chip — not a tooltip a
    /// second later. Kept inside the column's edges.
    @ViewBuilder
    private func label(_ frames: [UUID: Anchor<CGRect>]) -> some View {
        GeometryReader { geo in
            if let id = hovering, dragging == nil, let anchor = frames[id],
               let space = spaces.all.first(where: { $0.id == id }) {
                let rect = geo[anchor]
                let text = Text(space.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ink.ink)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(ink.pill))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.12), radius: 6, y: 2)
                    .fixedSize()
                // Roughly half the label's width, so it stays in the column.
                let half = CGFloat(min(space.title.count, 28)) * 3.4 + 10
                text
                    .position(x: min(max(half, rect.midX), geo.size.width - half), y: rect.minY - 16)
                    .transition(.opacity.combined(with: .offset(y: 3)))
                    .allowsHitTesting(false)
            }
        }
        .animation(Motion.quick, value: hovering)
    }

    /// A space, and its page open at once, so it gets a name, an icon and
    /// a colour instead of being "Space 9". Right-click for the other new
    /// things — a canvas, in this space's Saved block (Fork/Canvas).
    private var plus: some View {
        Button(action: newSpace) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(ink.muted)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New Space — right-click for New Canvas")
        .contextMenu {
            Button("New Space", action: newSpace)
                .keyboardShortcut("n", modifiers: [.control])
            Button("New Canvas") { CanvasTabs.newCanvas(in: browser) }
                .keyboardShortcut("e", modifiers: [.control, .shift])
        }
    }

    private func newSpace() {
        let id = spaces.add(in: browser)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { SpaceEditing.shared.open(id) }
    }
}

/// How much room the row of chips was given.
private struct StripRoom: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Where each chip is, for the hover label.
private struct ChipFrames: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// One space at the foot: its mark on a soft square of its own colour. The
/// current one sits on the column's paper-white pill instead — the same
/// thing the live row wears, so the column has one word for "this one".
struct SpaceChip: View {
    let space: Space
    let current: Bool
    let dark: Bool
    let over: Bool
    /// The column's ink, for the dot a space without an icon wears.
    var ink: Color? = nil
    /// The column's hover, for the square under the pointer — the column's
    /// and not the window's, so it shows on a column toned dark.
    var glow: Color? = nil

    static let size: CGFloat = 28
    static let gap: CGFloat = 5

    /// Arc's: the current space's icon in full colour, every other one
    /// greyed and thinned until the pointer lands on it.
    var body: some View {
        SpaceGlyph(space: space, size: 17, dark: dark, ink: ink, bare: true)
            .saturation(current || over ? 1 : 0)
            .opacity(current ? 1 : (over ? 0.8 : 0.42))
            .frame(width: SpaceChip.size, height: SpaceChip.size)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(over && !current ? (glow ?? Color.black.opacity(dark ? 0 : 0.05)) : .clear)
            )
            .animation(Motion.quick, value: over)
            .animation(Motion.quick, value: current)
    }
}

// MARK: - the menu

/// The space menu — from the header, the chip's right-click, and ⌘K.
struct SpaceMenu: View {
    @ObservedObject var browser: Browser
    let space: Space
    @ObservedObject private var spaces = Spaces.shared

    private var index: Int { spaces.all.firstIndex { $0.id == space.id } ?? 0 }

    var body: some View {
        Button("Edit Space…") { SpaceEditing.shared.open(space.id) }
        Button("New Tab in Space") {
            if space.id != spaces.current(in: browser) { spaces.select(space.id, in: browser) }
            browser.launch()
        }
        Button("New Canvas in Space") {
            if space.id != spaces.current(in: browser) { spaces.select(space.id, in: browser) }
            CanvasTabs.newCanvas(in: browser)
        }
        // A pin is already in every space, so it has nowhere to move to.
        if let tab = browser.active, tab.pin == nil, space.id != spaces.current(in: browser) {
            Button("Move Current Tab Here") { spaces.move(tab, to: space.id, in: browser) }
        }
        Divider()
        Button("Move Left") { withAnimation(Motion.settle) { spaces.nudge(space.id, by: -1) } }
            .disabled(index == 0)
        Button("Move Right") { withAnimation(Motion.settle) { spaces.nudge(space.id, by: 1) } }
            .disabled(index == spaces.all.count - 1)
        Divider()
        Menu("Colour") {
            ForEach(SpaceColour.allCases) { colour in
                Button { spaces.tint(space.id, hue: colour.hue) } label: {
                    Label {
                        Text(colour.name)
                    } icon: {
                        Image(systemName: SpaceColour.nearest(space.hue) == colour ? "checkmark.circle.fill" : "circle.fill")
                            .foregroundStyle(SpaceTint(hue: colour.hue, dark: false).swatch)
                    }
                }
            }
        }
        Menu("Profile") {
            Button { spaces.profile(space.id, named: nil) } label: {
                Label("Shared", systemImage: space.profile == nil ? "checkmark" : "")
            }
            ForEach(spaces.profiles, id: \.self) { name in
                Button { spaces.profile(space.id, named: name) } label: {
                    Label(name, systemImage: space.profile == name ? "checkmark" : "")
                }
            }
            Divider()
            Button("New Profile…") { SpaceEditing.shared.open(space.id) }
        }
        if spaces.all.count > 1 {
            Divider()
            Button("Delete Space…", role: .destructive) { SpaceDelete.ask(space.id, in: browser) }
        }
    }
}

// MARK: - delete

/// Deleting asks first — and offers to keep the tabs.
@MainActor
enum SpaceDelete {
    /// What the sheet last did, for the bench.
    private(set) static var last = ""
    /// The sheet while it is up, so `bench spaces answer` can press a button.
    private(set) static var asking: NSAlert?

    /// The sheet's words, for the bench — a picture of a sheet needs the
    /// screen-recording grant the window picture does not.
    static var describe: [String: Any] {
        guard let alert = asking else { return [:] }
        return ["message": alert.messageText, "detail": alert.informativeText, "buttons": alert.buttons.map(\.title)]
    }

    /// `bench spaces answer close|move|cancel`: the sheet's button of that
    /// meaning, pressed. False when no sheet is up or it has no such button.
    static func answer(_ choice: String) -> Bool {
        guard let alert = asking else { return false }
        let titles = alert.buttons.map(\.title)
        let index: Int?
        switch choice {
        case "close", "delete": index = titles.firstIndex { $0.hasPrefix("Close Tabs") || $0 == "Delete" }
        case "move", "keep": index = titles.firstIndex { $0.hasPrefix("Move Tabs") }
        default: index = titles.firstIndex { $0 == "Cancel" }
        }
        guard let index else { return false }
        // Held for the bench in a headless test run: no sheet to click (X-13).
        if TestConfirm.holds { return TestConfirm.answer(String(index + 1))["answered"] != nil }
        alert.buttons[index].performClick(nil)
        return true
    }

    static func ask(_ id: UUID, in browser: Browser) {
        let spaces = Spaces.shared
        guard spaces.all.count > 1, let space = spaces.all.first(where: { $0.id == id }) else { return }
        let count = spaces.count(of: id, in: browser)
        let neighbour = spaces.neighbour(of: id)
        // Settings › Spaces stays up under the sheet: Cancel goes back to it,
        // and after a delete it shows the space you are in.

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(space.title)”?"
        switch count {
        case 0: alert.informativeText = "It has no tabs."
        case 1: alert.informativeText = "Its one tab will close."
        default: alert.informativeText = "Its \(count) tabs will close."
        }
        if count > 0 {
            alert.addButton(withTitle: "Close Tabs & Delete").hasDestructiveAction = true
            if let neighbour {
                alert.addButton(withTitle: "Move Tabs to “\(neighbour.title)” & Delete")
            }
        } else {
            alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        }
        alert.addButton(withTitle: "Cancel")

        let decide: (NSApplication.ModalResponse) -> Void = { response in
            asking = nil
            switch response {
            case .alertFirstButtonReturn:
                spaces.remove(id, in: browser)
                last = "deleted"
                SpaceEditing.shared.forget(id)
            case .alertSecondButtonReturn where count > 0 && neighbour != nil:
                spaces.remove(id, in: browser, movingTabsTo: neighbour?.id)
                last = "moved"
                SpaceEditing.shared.forget(id)
            default:
                last = "cancelled"
            }
        }
        asking = alert
        // A sheet on the window — or, in a test run, a question the bench
        // can answer too (X-13).
        TestConfirm.present(alert, kind: "spaces.delete", window: Links.window, decide: decide)
    }
}
