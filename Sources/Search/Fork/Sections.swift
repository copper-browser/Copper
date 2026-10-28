import SwiftUI

// The sidebar's three sections, as Arc has them.
//
//   Favourites   the pin grid at the top — upstream's pins, untouched.
//   Saved        the tabs you keep. Above the hairline and the New Tab row.
//   Today        everything else, newest first, under that row.
//
// Which of the two lower sections a tab is in is a fact about the tab, not a
// guess about when it arrived: `saved` is an explicit set, written into the
// session as one optional flag per entry and read back the same way. An
// upstream-shaped file has no flag, so everything in it restores as saved and
// nothing regresses.
//
// Today is swept: a row nobody has looked at for the archive window (a day,
// by default) is closed through `Browser.close`, the same path the cross on
// the row takes, so it lands in Reopen Closed Tab rather than disappearing.

@MainActor
final class Sections: ObservableObject {
    static let shared = Sections()

    /// How long a Today row may sit unlooked-at before it is archived.
    enum Archive: String, Codable, CaseIterable, Identifiable {
        case h12, h24, h48, never

        var id: String { rawValue }

        var title: String {
            switch self {
            case .h12: return "12h"
            case .h24: return "24h"
            case .h48: return "48h"
            case .never: return "Never"
            }
        }

        var hours: Double? {
            switch self {
            case .h12: return 12
            case .h24: return 24
            case .h48: return 48
            case .never: return nil
            }
        }
    }

    /// The tabs you keep. Pins are not in here — they are their own section.
    @Published private(set) var saved: Set<Tab.ID> = []

    @Published var archive: Archive {
        didSet { Store.settings.set(archive.rawValue, forKey: "sections.archive") }
    }

    /// When each tab was last looked at. Kept here rather than on `Tab`,
    /// which starts every restored row's clock at launch and so would make
    /// the whole of yesterday look like this minute.
    private var seen: [Tab.ID: Date] = [:]

    private var sweeper: Timer?

    /// How many rows the last sweep took, for the bench.
    private(set) var lastSwept = 0

    /// The row that has just been saved. Saved lands at the bottom of a
    /// block that may be scrolled far above it, so the column brings it into
    /// view rather than letting the tab appear to vanish.
    @Published private(set) var reveal: Tab.ID?

    private init() {
        archive = Store.settings.string(forKey: "sections.archive").flatMap(Archive.init(rawValue:)) ?? .h24
    }

    // MARK: - reading

    /// A grouped tab is saved whatever its flag says: folders live in Saved,
    /// so a Today row dragged into one comes up with it.
    func isSaved(_ tab: Tab) -> Bool {
        saved.contains(tab.id) || Groups.shared.membership[tab.id] != nil
    }

    /// A tab the sections have never met — a ⌘T tab, a link opened in the
    /// background, a bench tab. It belongs at the top of Today.
    func knows(_ tab: Tab) -> Bool { seen[tab.id] != nil || saved.contains(tab.id) }

    /// When the row was last in front. A tab that is awake has been looked
    /// at this session whatever the file said, so its own clock wins.
    func lastSeen(_ tab: Tab) -> Date {
        guard let stored = seen[tab.id] else { return Date() }
        return tab.asleep ? stored : max(stored, tab.touched)
    }

    // MARK: - moving between the two

    func note(_ id: Tab.ID?) {
        guard let id else { return }
        seen[id] = Date()
        down.remove(id)
    }

    /// Save a row or let it go. Saving parks it at the end of the Saved run;
    /// unsaving puts it at the top of Today, where the newest rows are.
    func set(_ tab: Tab, saved on: Bool, in browser: Browser) {
        guard tab.pin == nil else { return }
        if on {
            saved.insert(tab.id)
        } else {
            saved.remove(tab.id)
            // Folders live in Saved. A row that leaves Saved leaves its
            // folder with it, or it would be pulled straight back up.
            if Groups.shared.membership[tab.id] != nil { Groups.shared.remove(tab) }
            seen[tab.id] = Date()
        }
        let kept = browser.tabs.filter { $0.pin == nil && isSaved($0) }.count
        browser.move(tab, to: browser.pinnedCount + max(0, on ? kept - 1 : kept))
        reveal = on ? tab.id : nil
    }

    /// Let go over Saved (Fork/SavedDrop.swift): saved, at that place, in
    /// that folder. Unlike `set`, the column does not scroll to it — it is
    /// already where the pointer is.
    /// Whether a tab is in `folder`, or in a folder inside it.
    func inFolder(_ id: Tab.ID, _ folder: UUID) -> Bool {
        let groups = Groups.shared
        guard let mine = groups.membership[id] else { return false }
        guard mine != folder else { return true }
        guard let outer = groups.group(folder), let inner = groups.group(mine) else { return false }
        return Folders.below(inner.name, outer.name)
    }

    func place(_ tab: Tab, at spot: SavedDrop.Spot, in browser: Browser) {
        guard tab.pin == nil, !tab.isBlank else { return }
        saved.insert(tab.id)
        seen[tab.id] = seen[tab.id] ?? Date()
        let groups = Groups.shared
        // The folder first, so the session written by the move has it.
        if let folder = spot.group, groups.group(folder) != nil {
            groups.restore(tab, group: folder)
            if case .into = spot.anchor, groups.group(folder)?.collapsed == true { groups.toggleCollapsed(folder) }
        } else if groups.membership[tab.id] != nil {
            groups.remove(tab)
        }
        let row = browser.tabs.map { (id: $0.id, pinned: $0.pin != nil, saved: isSaved($0)) }
        let index = SavedDrop.index(for: spot.anchor, moving: tab.id, row: row, inFolder: inFolder)
        browser.move(tab, to: min(index, browser.tabs.count - 1))
        reveal = nil
    }

    // MARK: - closing a Saved row (Arc's rule)

    // Closing a Saved tab — ⌘W, Close Tab in the File menu, the wheel button,
    // an agent's close, Close Other Tabs, a window's last tab — never takes it
    // out of Saved: `Browser.close` asks `putsDown` first and, for a Saved
    // row, lets its page go (`Tab.rest`, as ⌘W on a favourite does) and moves
    // on. The row keeps its place, its title and its mark. Only `remove` —
    // the cross on the row, Close Tab on its menu, Close Tabs in Group, a
    // kept tab deleted on another Mac, a deleted canvas — takes it out, and
    // Reopen Closed Tab brings it back into Saved where it was.

    /// Rows the close in progress takes out for good.
    private var forGood: Set<Tab.ID> = []
    /// Saved rows put down by a close and not looked at since. A close
    /// never lands on one: they are closed, as far as ⌘W is concerned.
    private var down: Set<Tab.ID> = []
    /// Where each removed Saved row stood, by the Reopen Closed Tab entry it
    /// left (`Browser.Ghost.id`).
    private var removed: [UUID: Removed] = [:]

    struct Removed: Equatable {
        var group: UUID?
    }

    /// Whether `Browser.close` should put this tab down rather than close it.
    func putsDown(_ tab: Tab) -> Bool {
        tab.pin == nil && !tab.isBlank && isSaved(tab) && !forGood.contains(tab.id)
    }

    /// Said by `Browser.close` once it has put the row down.
    func wentDown(_ tab: Tab) { down.insert(tab.id) }

    /// Put down and still asleep: looked at again (or woken by anything),
    /// it is an open row like any other.
    func isDown(_ tab: Tab) -> Bool { down.contains(tab.id) && tab.asleep }

    /// Where a close of `tab` lands, as a close would — the neighbour on the
    /// right, else on the left, one no other window is showing first — among
    /// the rows that are still open. Nil when none is.
    func landing(after tab: Tab, in browser: Browser) -> Tab? {
        guard let index = browser.tabs.firstIndex(where: { $0.id == tab.id }) else { return nil }
        let rest = browser.tabs.filter { $0.id != tab.id }
        let order = Array(index..<rest.count) + Array(stride(from: index - 1, through: 0, by: -1))
        let open = order.map { rest[$0] }.filter { !isDown($0) }
        return open.first { !Spaces.shared.shown($0, outside: browser) } ?? open.first
    }

    /// Every other row is a Saved tab already put down: `tab` is the last
    /// open one, and closing it is closing a window's last tab.
    func lastOpen(_ tab: Tab, in browser: Browser) -> Bool {
        let others = browser.tabs.filter { $0.id != tab.id }
        return !others.isEmpty && others.allSatisfy { isDown($0) }
    }

    /// Closed for good, Saved or not, with no way back into Saved — the
    /// ordinary close's Reopen Closed Tab entry is all it leaves.
    func closeForGood(_ tab: Tab, in browser: Browser) {
        forGood.insert(tab.id)
        defer { forGood.remove(tab.id) }
        browser.close(tab)
        down.remove(tab.id)
    }

    /// The cross on a row: a Today row closes as it always has; a Saved row
    /// leaves Saved and closes, and Reopen Closed Tab puts it back.
    func remove(_ tab: Tab, in browser: Browser) {
        let place = tab.pin == nil && isSaved(tab) ? Removed(group: Groups.shared.membership[tab.id]) : nil
        let before = Set(browser.ghosts.map(\.id))
        closeForGood(tab, in: browser)
        guard let place, let ghost = browser.ghosts.last(where: { !before.contains($0.id) }) else { return }
        remember(place, for: ghost.id, keeping: Set(browser.ghosts.map(\.id)))
    }

    /// The Saved place a Reopen Closed Tab entry stands for. Entries the
    /// browser no longer lists are let go.
    func remember(_ place: Removed, for ghost: UUID, keeping alive: Set<UUID>) {
        removed = removed.filter { alive.contains($0.key) }
        removed[ghost] = place
    }

    func removedPlace(_ ghost: UUID) -> Removed? { removed[ghost] }

    /// Reopen Closed Tab has put `tab` back where the entry said; a removed
    /// Saved row comes back saved, in its folder if that is still there.
    /// Before the column next draws, so it never counts as a new Today row.
    func reopened(_ ghost: UUID, as tab: Tab) {
        guard let place = removed.removeValue(forKey: ghost) else { return }
        saved.insert(tab.id)
        seen[tab.id] = Date()
        Groups.shared.restore(tab, group: place.group)
    }

    /// A row that has just appeared: it is today's, it has been seen now,
    /// and Arc puts it at the top of the block rather than the bottom.
    /// Called as the column redraws, so nothing else has to remember to.
    func arrived(in browser: Browser) {
        let fresh = browser.tabs.filter { $0.pin == nil && !knows($0) }
        guard !fresh.isEmpty else { return }
        for tab in fresh { seen[tab.id] = Date() }
        let top = browser.pinnedCount + browser.tabs.filter { $0.pin == nil && isSaved($0) }.count
        // Newest first: the last one to arrive ends up above the rest.
        for tab in fresh { browser.move(tab, to: top) }
    }

    // MARK: - the sweep

    /// Everything in Today nobody has looked at inside the window, closed the
    /// ordinary way. The row you are on is never taken out from under you,
    /// and neither is a canvas (Fork/Canvas): it lives in Saved, and one
    /// dragged into Today is still a board, not a page to tidy away.
    @discardableResult
    func sweep(in browser: Browser, olderThan override: Double? = nil) -> Int {
        guard let hours = override ?? archive.hours else { lastSwept = 0; return 0 }
        let cutoff = Date().addingTimeInterval(-hours * 3600)
        // Nor a row on another window's stage (Fork: windows — the row is shared).
        let stale = browser.tabs.filter {
            $0.pin == nil && !isSaved($0) && $0.id != browser.activeID && !$0.isBlank && lastSeen($0) < cutoff
                && CanvasTabs.showing($0) == nil
                && !Spaces.shared.shown($0, outside: browser)
        }
        for tab in stale { browser.close(tab) }
        lastSwept = stale.count
        return stale.count
    }

    /// Once the session is back, and every half hour after. Switching space
    /// sweeps the row that just came on screen (see `Spaces.select`), so the
    /// spaces you are not looking at are not swept behind your back.
    func begin(in browser: Browser) {
        sweeper?.invalidate()
        sweeper = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak browser] _ in
            MainActor.assumeIsolated { if let browser { Sections.shared.sweep(in: browser) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak browser] in
            if let browser { self.sweep(in: browser) }
        }
    }

    // MARK: - the session

    func restore(_ tab: Tab, saved on: Bool, seen when: Double?) {
        if on { saved.insert(tab.id) }
        seen[tab.id] = when.map { Date(timeIntervalSince1970: $0) } ?? Date()
    }

    func forget(_ id: Tab.ID) {
        saved.remove(id)
        seen[id] = nil
        down.remove(id)
    }

    func clear() {
        saved.removeAll()
        seen.removeAll()
    }

    // MARK: - the bench

    /// `./bench sections` counts each space's two blocks; `sections save ID`,
    /// `sections unsave ID`, `sections archive` (the sweep, now),
    /// `sections window 12h|24h|48h|never`.
    func bench(_ request: [String: Any], in browser: Browser) -> [String: Any] {
        let arg = request["arg"] as? String ?? ""
        func find(_ key: String) -> Tab? {
            guard !key.isEmpty else { return nil }
            return browser.tabs.first { $0.id.uuidString.lowercased().hasPrefix(key.lowercased()) }
        }
        var note: [String: Any] = [:]
        switch request["op"] as? String ?? "" {
        case "save":
            guard let tab = find(arg) else { return ["error": "no tab \(arg)"] }
            set(tab, saved: true, in: browser)
        case "unsave":
            guard let tab = find(arg) else { return ["error": "no tab \(arg)"] }
            set(tab, saved: false, in: browser)
        case "drag":
            // drag ID DY [STEPS] [hold] [post|window|view]: the row picked up
            // and moved DY points (negative is up) by real mouse events
            // (Fork/SideHand.swift). Answers at once; the drag takes `ms`.
            let words = arg.split(separator: " ").map(String.init)
            guard words.count >= 2, let tab = find(words[0]), let dy = Double(words[1]) else {
                return ["error": "sections drag ID DY [STEPS] [hold]"]
            }
            let steps = words.count > 2 ? Int(words[2]) ?? 12 : 12
            SideHand.how = words.first { ["post", "window", "view"].contains($0) } ?? "view"
            note = SideHand.drag(tab, dy: dy, steps: steps, hold: words.contains("hold"), in: browser)
        case "click":
            // click ID [cross]: a real click on the row, or on its cross.
            let words = arg.split(separator: " ").map(String.init)
            guard let tab = find(words.first ?? "") else { return ["error": "no tab \(arg)"] }
            note = SideHand.click(tab, cross: words.contains("cross"), in: browser)
        case "hover":
            // hover ID | hover off: the pointer onto the row's middle, so its
            // cross shows, or away from every row.
            note = SideHand.hover(arg == "off" ? nil : find(arg), in: browser)
        case "release":
            note = SideHand.release(in: browser)
        case "picture":
            // picture PATH [EXTRA]: the window to a PNG without bringing it
            // forward, cut to the column and EXTRA points of the page.
            let words = arg.split(separator: " ").map(String.init)
            guard let path = words.first else { return ["error": "sections picture PATH [EXTRA]"] }
            note = SideHand.picture(to: path, extra: words.count > 1 ? CGFloat(Double(words[1]) ?? 0) : 0, in: browser)
        case "target":
            // Where the row in the hand would land now, and the frames it is
            // worked out from.
            let drag = SideDrag.of(browser)
            let layout = drag.layout(in: browser)
            note["drop"] = SavedDrop.describe(drag.target)
            note["layout"] = ["top": layout.top, "bottom": layout.bottom, "seamTop": layout.seamTop, "seamBottom": layout.seamBottom,
                              "lines": layout.lines.map { ["top": $0.top, "bottom": $0.bottom, "depth": $0.depth] }]
            // Every loose row's middle, in the column's space: for working out a DY.
            note["rows"] = Dictionary(uniqueKeysWithValues: browser.tabs.filter { $0.pin == nil }.compactMap { tab in
                drag.rows[tab.id].map { (String(tab.id.uuidString.prefix(8)).lowercased(), $0.midY) }
            })
        case "drop":
            // drop ID Y [hold]: a trail's page let go over the column at Y (the
            // column's space) — what Trails' system drag hands the column's
            // drop target, through the same model; `hold` stops before the
            // drop, with the gap open, and `drop end` puts it away.
            let drag = SideDrag.of(browser)
            let words = arg.split(separator: " ").map(String.init)
            if words.first == "end" { drag.end(); break }
            guard words.count >= 2, let tab = find(words[0]), let y = Double(words[1]) else { return ["error": "sections drop ID Y [hold]"] }
            drag.carry(nil, from: .today, in: browser)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            drag.move(to: y, in: browser)
            note["drop"] = SavedDrop.describe(drag.target)
            if !words.contains("hold") {
                let target = drag.target
                drag.end()
                if let target, case .saved = target { withAnimation(Motion.settle) { drag.drop(tab, at: target, in: browser) } }
            }
        case "close":
            // ⌘W on the row, through `Browser.close` itself.
            guard let tab = find(arg) else { return ["error": "no tab \(arg)"] }
            browser.close(tab)
        case "remove":
            // The cross on the row (and Close Tab on its menu).
            guard let tab = find(arg) else { return ["error": "no tab \(arg)"] }
            remove(tab, in: browser)
        case "reopen":
            browser.reopen()
        case "seed":
            // Test worlds: real rows (not the bench's) asleep, as a session
            // brings them back — four Saved, two of them in a folder, and
            // three in Today. `seed empty`: Today only.
            guard Store.testing else { return ["error": "only in a test run"] }
            note["seeded"] = seed(empty: arg == "empty", in: browser)
        case "check":
            // Close against remove on a Saved row, end to end on real objects.
            guard Store.testing else { return ["error": "only in a test run"] }
            note["failures"] = SavedChecks.run(in: browser)
        case "archive":
            // A bare `archive` runs the sweep the clock would have run; an
            // age in hours runs it against that instead, for a test that
            // doesn't want to wait a day for something to go stale.
            note["archived"] = sweep(in: browser, olderThan: Double(arg))
        case "age":
            // age TAB HOURS: the row was last looked at that long ago, so a
            // bare `archive` afterwards proves the window itself (test runs only).
            let words = arg.split(separator: " ").map(String.init)
            guard Store.testing else { return ["error": "only in a test run"] }
            guard words.count == 2, let tab = find(words[0]), let hours = Double(words[1]) else {
                return ["error": "sections age TAB HOURS"]
            }
            let then = Date().addingTimeInterval(-hours * 3600)
            seen[tab.id] = then
            tab.backdate(touched: then)
            note["aged"] = ["tab": tab.id.uuidString, "hours": hours]
        case "window":
            // 24, 24h, h24 and never all say the same thing.
            let key = arg.lowercased().trimmingCharacters(in: .whitespaces)
            guard let window = Archive(rawValue: key == "never" ? key : "h" + key.filter(\.isNumber)) else {
                return ["error": "window 12h|24h|48h|never"]
            }
            archive = window
        default: break
        }
        // A space's row holds its loose tabs only; the favourites are one
        // set every space shows, so they are counted once, on their own.
        func counts(_ tabs: [Tab]) -> [String: Any] {
            ["saved": tabs.filter { isSaved($0) }.count,
             "today": tabs.filter { !isSaved($0) }.count]
        }
        let spaces = Spaces.shared
        note["window"] = archive.rawValue
        note["oldest"] = oldestToday(in: browser)
        note["favourites"] = spaces.pins.count
        note["spaces"] = spaces.all.map { space -> [String: Any] in
            var row = counts(spaces.row(space.id))
            row["name"] = space.name
            row["current"] = space.id == spaces.current(in: browser)
            return row
        }
        note["today"] = browser.tabs.filter { $0.pin == nil && !isSaved($0) }.map { tab -> [String: Any] in
            ["id": String(tab.id.uuidString.prefix(8)).lowercased(), "title": tab.title,
             "seen": Int(Date().timeIntervalSince(lastSeen(tab)) / 3600)]
        }
        // The Saved block of the row on screen, in order: what a drag or a
        // close did to it, readable without a picture.
        note["saved"] = browser.tabs.filter { $0.pin == nil && isSaved($0) }.map { tab -> [String: Any] in
            ["id": String(tab.id.uuidString.prefix(8)).lowercased(), "title": tab.title, "asleep": tab.asleep,
             "live": tab.id == browser.activeID,
             "group": Groups.shared.membership[tab.id].flatMap { Groups.shared.group($0)?.name } ?? ""]
        }
        return note
    }

    /// Rows for a test world to look at: brought back asleep, the way a
    /// session restores them, with real addresses and titles.
    private func seed(empty: Bool, in browser: Browser) -> [String] {
        let kept: [(String, String, String?)] = empty ? [] : [
            ("https://mail.google.com/mail/u/0/", "Inbox — Gmail", nil),
            ("https://calendar.google.com/", "Google Calendar", nil),
            ("https://github.com/copper-browser/Copper", "copper-browser/Copper", "Work"),
            ("https://linear.app/", "Linear", "Work"),
        ]
        let today: [(String, String)] = [
            ("https://news.ycombinator.com/", "Hacker News"),
            ("https://en.wikipedia.org/wiki/Copper", "Copper — Wikipedia"),
            ("https://www.apple.com/", "Apple"),
        ]
        var made: [String] = []
        func add(_ url: String, _ title: String, saved on: Bool) -> Tab? {
            guard let address = URL(string: url) else { return nil }
            let tab = Tab()
            browser.prepare(tab)
            tab.restore(url: address, title: title)
            restore(tab, saved: on, seen: Date().timeIntervalSince1970)
            made.append(String(tab.id.uuidString.prefix(8)).lowercased())
            return tab
        }
        var row = browser.tabs
        let top = browser.pinnedCount + browser.tabs.filter { $0.pin == nil && isSaved($0) }.count
        var savedTabs: [Tab] = []
        for (url, title, folder) in kept {
            guard let tab = add(url, title, saved: true) else { continue }
            savedTabs.append(tab)
            if let folder { Groups.shared.restore(tab, group: Groups.shared.create(named: folder, hue: nil).id) }
        }
        row.insert(contentsOf: savedTabs, at: top)
        row.insert(contentsOf: today.compactMap { add($0.0, $0.1, saved: false) }, at: top + savedTabs.count)
        browser.tabs = row
        Marks.warm(browser.tabs)
        return made
    }

    /// How old the oldest Today row is, in hours — so a sweep that took
    /// nothing can say there was nothing to take.
    func oldestToday(in browser: Browser) -> Int {
        let ages = browser.tabs.filter { $0.pin == nil && !isSaved($0) }.map { Date().timeIntervalSince(lastSeen($0)) }
        return Int((ages.max() ?? 0) / 3600)
    }
}

/// Save / Unsave, on a tab's context menu in both layouts.
struct SaveMenu: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject var sections = Sections.shared

    var body: some View {
        if tab.pin == nil {
            Divider()
            if sections.isSaved(tab) {
                Button("Unsave") { sections.set(tab, saved: false, in: browser) }
            } else {
                Button("Save") { sections.set(tab, saved: true, in: browser) }
                    .disabled(tab.isBlank)
            }
        }
    }
}

/// The one Settings line the sections add, on the Tabs page next to sleep.
struct ArchiveLine: View {
    @ObservedObject var sections = Sections.shared

    var body: some View {
        Line("Archive Today after", "Untouched rows below the New Tab line close themselves, and wait in Reopen Closed Tab.") {
            Segmented(options: Sections.Archive.allCases.map { ($0, $0.title) }, selection: $sections.archive)
        }
    }
}
