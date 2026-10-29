import AppKit
import Combine
import SwiftUI

// Trails (a flight — Settings › Tabs › Previews, docs/trails.md).
//
// Arc made tabs spatial; a trail makes them intentional. A trail is one line
// of intent: it starts where something was typed — a search, an address, a
// link that came in from another app — and grows as pages are opened from
// it. A page opened from a page (⌘-click, target=_blank, window.open) joins
// its opener's trail, under it; anything else starts a trail of its own. The
// column stops being forty rows and becomes a handful of trails.
//
// What this file keeps is lineage and nothing else: for every Today row (a
// loose, unsaved tab), which trail it is in and which page it came from; for
// every trail, its name, the search it began with and when it was last used.
// The rows themselves are still `Browser.tabs` — nothing here moves, closes
// or reorders a tab except the actions a person asks for (Close Trail).
//
// Off, none of it runs: no observers, no timer, no file. On, it watches each
// window's `tabs` and `activeID`, and writes `trails.json` beside the session
// on the same serial-writer pattern as `windows.json`. `session.json` is never
// touched. A tab's id is new every launch, so on disk a page is found again
// by its space, its address and which of that space's same-address rows it
// is — the same things the session restores it from.

@MainActor
final class Trails: ObservableObject {
    static let shared = Trails()

    /// One page's place: its trail, the page it was opened from, when it
    /// joined and when it was last in front.
    struct Node: Equatable {
        var trail: UUID
        var parent: Tab.ID?
        var opened: Date
        var used: Date
    }

    /// One trail: the page that started it, a name given by hand, the search
    /// it began with, and where it sits in the column (`rank`, newest first —
    /// bumped when Tide gives a trail back).
    struct Meta: Equatable {
        var founder: Tab.ID?
        var title: String?
        var query: String?
        /// The founder has left its results page: the query is the trail's
        /// for good, and later searches in that tab don't rename it.
        var settled = false
        /// What it was called when its first page closed, so a trail coming
        /// back with ⌘⇧T keeps its name until that page is back too.
        var caption: String?
        var created: Date
        var used: Date
        var rank: Date
    }

    @Published private(set) var nodes: [Tab.ID: Node] = [:]
    @Published private(set) var metas: [UUID: Meta] = [:]
    /// A trail opened or shut by hand against its default (open while it
    /// holds the page you are on). Reset for both trails when you cross
    /// from one to the other.
    @Published private(set) var disclosure: [UUID: Bool] = [:]
    /// The trail whose name is being typed.
    @Published var renaming: UUID?
    /// The trail whose Glance is up (one at a time, app-wide). The bench
    /// sets it too, for a picture.
    @Published var glancing: UUID?
    /// Tide's clock: the column re-reads the time every few minutes, so a
    /// trail left alone drifts under Earlier without anything else changing.
    @Published private(set) var clock = Date()

    /// The last address each page had, for the graveyard: a closed page is
    /// remembered by where it was, so ⌘⇧T puts it back on its trail.
    private var lastURL: [Tab.ID: URL] = [:]
    /// Pages whose tab has gone, and when. Kept a few minutes: Clear's Undo
    /// brings the same Tab objects back, lineage and all.
    private var gone: [Tab.ID: Date] = [:]
    private struct Grave {
        let url: String
        let trail: UUID
        let meta: Meta?
        let parentURL: String?
        let founder: Bool
        let opened: Date
        let at: Date
    }
    private var graveyard: [Grave] = []
    /// Addresses Reopen Closed Tab has just taken out of a window's list:
    /// only a page arriving at one of these goes back to its old trail — the
    /// same address typed or opened afresh starts a trail of its own.
    private var expected: [(url: String, at: Date)] = []
    /// Pages back from the graveyard whose parent isn't back yet: the
    /// address they hang from, so they move under it when it returns.
    private var orphans: [Tab.ID: String] = [:]
    /// Each page's title the last time the rows changed — the name a trail
    /// keeps when its first page closes.
    private var labels: [Tab.ID: String] = [:]

    private var started = false
    private var watching: [ObjectIdentifier: [AnyCancellable]] = [:]
    private var addresses: [Tab.ID: AnyCancellable] = [:]
    private var timer: Timer?
    private var terminating: NSObjectProtocol?
    private var settling: Set<ObjectIdentifier> = []
    private var writing = false
    /// Yesterday's trails, read and waiting for the restored rows to bind to.
    private var unbound: Disk?
    /// Trails Tide has already put to sleep, so it does so once per ebb.
    private var ebbed: Set<UUID> = []

    private init() {}

    // MARK: - the flight

    func flightChanged(_ on: Bool) {
        if on {
            ensure()
        } else {
            stop()
        }
    }

    /// Everything the flight needs, once: yesterday's file, the windows, the
    /// clock and the last write on the way out. Called by every way in, so it
    /// starts whichever is first — the column appearing, a hook, the bench.
    func ensure() {
        guard Flights.trails, !started else { return }
        started = true
        unbound = Trails.read()
        let tick = Timer(timeInterval: 300, repeats: true) { _ in
            MainActor.assumeIsolated { Trails.shared.tick() }
        }
        tick.tolerance = 60
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
        terminating = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Trails.shared.write(now: true) }
        }
        for browser in Windows.all { attach(browser) }
    }

    /// Off: every observer and the clock go; what is in memory stays, so
    /// switching back on in the same session picks up where it was.
    private func stop() {
        guard started else { return }
        write(now: false, force: true)
        started = false
        timer?.invalidate()
        timer = nil
        if let terminating { NotificationCenter.default.removeObserver(terminating) }
        terminating = nil
        watching.removeAll()
        addresses.removeAll()
        glancing = nil
        renaming = nil
    }

    /// A window's rows and its front tab, watched from now on. `$tabs` speaks
    /// before the new rows land, so lineage is in place before the column
    /// draws them.
    func attach(_ browser: Browser) {
        guard Flights.trails else { return }
        ensure()
        let key = ObjectIdentifier(browser)
        guard watching[key] == nil else { return }
        var bag: [AnyCancellable] = []
        browser.$tabs.sink { [weak self, weak browser] tabs in
            guard let self, let browser else { return }
            self.sync(tabs, in: browser)
        }.store(in: &bag)
        browser.$activeID.sink { [weak self, weak browser] id in
            guard let self, let browser else { return }
            self.activated(id, from: browser.activeID, in: browser)
        }.store(in: &bag)
        // A ghost taken out of the list (and none put in) is a page being
        // reopened. Thirteen before is the list trimming itself to twelve.
        var ghosts = browser.ghosts
        browser.$ghosts.sink { [weak self] now in
            let before = ghosts
            ghosts = now
            guard let self, before.count <= 12 else { return }
            let ids = Set(now.map(\.id))
            let old = Set(before.map(\.id))
            guard !now.contains(where: { !old.contains($0.id) }) else { return }
            let at = Date()
            for ghost in before where !ids.contains(ghost.id) { self.expected.append((ghost.url.absoluteString, at)) }
            self.expected.removeAll { at.timeIntervalSince($0.at) > 15 }
        }.store(in: &bag)
        watching[key] = bag
    }

    // MARK: - who is in a trail

    /// A Today row: loose and not kept. Pins, Saved rows and folders keep
    /// their own places and never join a trail.
    static func member(_ tab: Tab) -> Bool {
        tab.pin == nil && !Sections.shared.isSaved(tab)
    }

    /// The page's place, recorded or — for a row that has only just arrived
    /// — the one it is about to get: under its opener when there is one in
    /// Today, back on its old trail when it is a page just closed, otherwise
    /// a trail of its own. Pure, so the column can draw a new row in the
    /// right place in the same frame it appears.
    func node(of tab: Tab, among rows: [Tab.ID: Tab], now: Date = Date(), depth: Int = 0) -> Node {
        if let known = nodes[tab.id] { return known }
        if depth < 32, let up = tab.opener, let parent = rows[up], Trails.member(parent) {
            let above = node(of: parent, among: rows, now: now, depth: depth + 1)
            return Node(trail: above.trail, parent: up, opened: now, used: now)
        }
        if let grave = grave(for: tab) {
            let parent = grave.parentURL.flatMap { url in
                nodes.first { $0.value.trail == grave.trail && lastURL[$0.key]?.absoluteString == url && rows[$0.key] != nil }?.key
            }
            return Node(trail: grave.trail, parent: parent, opened: grave.opened, used: now)
        }
        let seen = Sections.shared.knows(tab) ? Sections.shared.lastSeen(tab) : now
        return Node(trail: tab.id, parent: nil, opened: seen, used: seen)
    }

    func trail(of id: Tab.ID?) -> UUID? {
        id.flatMap { nodes[$0]?.trail }
    }

    /// The pages of one trail in this window, in the row's order.
    func pages(of trail: UUID, in browser: Browser) -> [Tab] {
        let rows = Dictionary(browser.tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return browser.tabs.filter { Trails.member($0) && node(of: $0, among: rows).trail == trail }
    }

    // MARK: - keeping up

    /// New rows: yesterday's trails bound to them on the first pass, and a
    /// place for each one that has none — a moment later, once whoever made
    /// the tab has finished saying where it came from (`opener` is set after
    /// the row is in).
    private func sync(_ tabs: [Tab], in browser: Browser) {
        guard started else { return }
        bind()
        for tab in tabs where Trails.member(tab) {
            gone[tab.id] = nil
            watch(tab)
            if !tab.title.isEmpty { labels[tab.id] = tab.label }
        }
        // `$tabs` speaks before the row (and the space's) has changed: what
        // has gone and what is new are read a moment later, once both have.
        settleSoon(browser)
    }

    /// Once per window per turn of the run loop, however many times its
    /// rows change in it.
    private func settleSoon(_ browser: Browser) {
        let key = ObjectIdentifier(browser)
        guard settling.insert(key).inserted else { return }
        DispatchQueue.main.async { [weak self, weak browser] in
            guard let self else { return }
            self.settling.remove(key)
            if let browser { self.settle(browser) }
        }
    }

    /// Pages that have gone go to the graveyard first — so one coming back
    /// with ⌘⇧T in the same moment finds its grave — then every row without
    /// a place gets the one `node(of:)` says, for good.
    private func settle(_ browser: Browser) {
        guard started else { return }
        prune(keeping: browser.tabs, in: browser)
        let now = Date()
        let rows = Dictionary(browser.tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Parents before children: an opener settles first so its child
        // reads a recorded trail, not a guess.
        var pending = browser.tabs.filter { Trails.member($0) && nodes[$0.id] == nil }
        var rounds = 0
        while !pending.isEmpty, rounds < 8 {
            rounds += 1
            var later: [Tab] = []
            for tab in pending {
                if let up = tab.opener, let parent = rows[up], Trails.member(parent), nodes[up] == nil, pending.contains(where: { $0.id == up }) {
                    later.append(tab)
                    continue
                }
                place(tab, node(of: tab, among: rows, now: now), now: now)
            }
            pending = later
        }
        for tab in pending { place(tab, node(of: tab, among: rows, now: now), now: now) }
        dirty()
    }

    /// Record a page's place and, for a trail that is new, the trail itself.
    private func place(_ tab: Tab, _ node: Node, now: Date) {
        nodes[tab.id] = node
        if let url = tab.pending ?? tab.address { lastURL[tab.id] = url }
        if let index = graveIndex(for: tab, trail: node.trail) {
            revive(tab, from: graveyard.remove(at: index), now: now)
        }
        if metas[node.trail] == nil {
            var meta = Meta(founder: tab.id, created: node.opened, used: node.used, rank: node.opened)
            if let url = tab.pending ?? tab.address {
                // Named after its search only if it began with one.
                if let query = Trails.query(in: url) { meta.query = query } else if !Trails.isSearchHost(url) { meta.settled = true }
            }
            metas[node.trail] = meta
        }
    }

    /// The front tab moved: both trails were just used, the one left behind
    /// has its picture taken for Glance, and a trail Tide had carried off is
    /// back at the top of the column.
    private func activated(_ new: Tab.ID?, from old: Tab.ID?, in browser: Browser) {
        guard started else { return }
        let now = Date()
        if let old, old != new, let tab = browser.tabs.first(where: { $0.id == old }) {
            touch(old, now)
            TrailThumbs.shared.take(tab)
        }
        if let new { touch(new, now) }
        let before = trail(of: old)
        let after = trail(of: new)
        if before != after {
            if let before { disclosure[before] = nil }
            if let after { disclosure[after] = nil }
        }
        dirty()
    }

    private func touch(_ id: Tab.ID, _ now: Date) {
        guard var node = nodes[id] else { return }
        node.used = now
        nodes[id] = node
        guard var meta = metas[node.trail] else { return }
        // Tide gives it back: a trail picked out of Earlier goes to the top.
        if ebbs(meta.used, now: now) { meta.rank = now }
        meta.used = now
        metas[node.trail] = meta
        ebbed.remove(node.trail)
    }

    private func ebbs(_ used: Date, now: Date) -> Bool {
        guard let hours = Flights.shared.tide.hours else { return false }
        return now.timeIntervalSince(used) > hours * 3600
    }

    /// One page's address, watched: the trail's founder on a results page
    /// names the trail after its search; a page just reopened finds its way
    /// back to the trail it was closed from.
    private func watch(_ tab: Tab) {
        guard addresses[tab.id] == nil else { return }
        addresses[tab.id] = tab.$address.dropFirst().sink { [weak self, weak tab] url in
            guard let self, let tab, let url else { return }
            DispatchQueue.main.async { self.moved(tab, to: url) }
        }
    }

    private func moved(_ tab: Tab, to url: URL) {
        guard started, let node = nodes[tab.id] else { return }
        let first = lastURL[tab.id] == nil
        lastURL[tab.id] = url
        // A row that arrived with no address and has only now been sent
        // somewhere — ⌘⇧T builds the tab first and loads it after.
        if first, node.trail == tab.id, node.parent == nil,
           !nodes.contains(where: { $0.key != tab.id && $0.value.trail == node.trail }),
           let grave = grave(for: tab) {
            regraft(tab, onto: grave)
            return
        }
        guard var meta = metas[node.trail], meta.founder == tab.id, !meta.settled, meta.title == nil else { return }
        if let query = Trails.query(in: url) {
            if meta.query != query { meta.query = query; metas[node.trail] = meta; dirty() }
        } else if !Trails.isSearchHost(url) {
            meta.settled = true
            metas[node.trail] = meta
            dirty()
        }
    }

    private func regraft(_ tab: Tab, onto grave: Grave) {
        guard let index = graveyard.firstIndex(where: { $0.url == grave.url && $0.at == grave.at }) else { return }
        graveyard.remove(at: index)
        let now = Date()
        let old = nodes[tab.id]?.trail
        nodes[tab.id] = Node(trail: grave.trail, parent: nil, opened: grave.opened, used: now)
        if let old, old != grave.trail { metas[old] = nil }
        revive(tab, from: grave, now: now)
        dirty()
    }

    /// A page back from the graveyard, on its trail again: in its old place
    /// in the order, under its parent if that is back (or as soon as it is),
    /// over the pages that hang from it, and — if it began the trail — its
    /// founder again. A trail that had gone entirely comes back to the top.
    private func revive(_ tab: Tab, from grave: Grave, now: Date) {
        guard var node = nodes[tab.id] else { return }
        let url = (tab.pending ?? tab.address)?.absoluteString ?? grave.url
        if let used = expected.firstIndex(where: { $0.url == url || $0.url == grave.url }) { expected.remove(at: used) }
        node.opened = grave.opened
        if node.parent == nil, let want = grave.parentURL {
            if let parent = nodes.first(where: { $0.key != tab.id && $0.value.trail == grave.trail && gone[$0.key] == nil
                && lastURL[$0.key]?.absoluteString == want })?.key {
                node.parent = parent
            } else {
                orphans[tab.id] = want
            }
        }
        nodes[tab.id] = node
        for (id, want) in orphans where want == url && id != tab.id && nodes[id]?.trail == grave.trail {
            nodes[id]?.parent = tab.id
            orphans[id] = nil
        }
        let held = nodes.contains { $0.key != tab.id && $0.value.trail == grave.trail && gone[$0.key] == nil }
        var meta = metas[grave.trail] ?? grave.meta ?? Meta(created: grave.opened, used: now, rank: now)
        if !held { meta.rank = now }
        meta.used = now
        if grave.founder { meta.founder = tab.id }
        metas[grave.trail] = meta
    }

    // MARK: - the graveyard

    private func grave(for tab: Tab) -> Grave? {
        guard let url = (tab.pending ?? tab.address)?.absoluteString, expecting(url) else { return nil }
        let fresh = Date().addingTimeInterval(-3600)
        return graveyard.last { $0.url == url && $0.at > fresh }
    }

    private func graveIndex(for tab: Tab, trail: UUID) -> Int? {
        guard let url = (tab.pending ?? tab.address)?.absoluteString, expecting(url) else { return nil }
        return graveyard.lastIndex { $0.url == url && $0.trail == trail }
    }

    private func expecting(_ url: String) -> Bool {
        let now = Date()
        return expected.contains { $0.url == url && now.timeIntervalSince($0.at) < 15 }
    }

    /// Pages whose tab has gone from every window and every space: kept for
    /// a few minutes (Undo), then remembered by address for an hour (⌘⇧T),
    /// then forgotten.
    private func prune(keeping tabs: [Tab], in browser: Browser) {
        // Every row of every space, and every window's: a page parked in
        // another space, or shown in another window, has not gone anywhere.
        let spaces = Spaces.shared
        var alive = Set(tabs.map(\.id))
        for other in Windows.all where other !== browser { alive.formUnion(other.tabs.map(\.id)) }
        for space in spaces.all { alive.formUnion(spaces.row(space.id).map(\.id)) }
        alive.formUnion(spaces.parkedTabs.map(\.id))
        let now = Date()
        for (id, node) in nodes where !alive.contains(id) && gone[id] == nil {
            gone[id] = now
            addresses[id] = nil
            orphans[id] = nil
            let founder = metas[node.trail]?.founder == id
            if founder, metas[node.trail]?.caption == nil { metas[node.trail]?.caption = labels[id] }
            if let url = lastURL[id], url.scheme?.hasPrefix("http") == true {
                graveyard.append(Grave(url: url.absoluteString, trail: node.trail, meta: metas[node.trail],
                                       parentURL: node.parent.flatMap { lastURL[$0]?.absoluteString },
                                       founder: founder, opened: node.opened, at: now))
            }
        }
        if graveyard.count > 60 { graveyard.removeFirst(graveyard.count - 60) }
    }

    /// Forget what has been gone long enough, and any trail left with no page.
    private func forget(now: Date) {
        for (id, when) in gone where now.timeIntervalSince(when) > 600 {
            gone[id] = nil
            nodes[id] = nil
            lastURL[id] = nil
            labels[id] = nil
        }
        graveyard.removeAll { now.timeIntervalSince($0.at) > 3600 }
        let held = Set(nodes.values.map(\.trail))
        for id in metas.keys where !held.contains(id) { metas[id] = nil; disclosure[id] = nil }
    }

    // MARK: - Tide

    /// Every five minutes while on: the clock moves, trails that have just
    /// crossed into Earlier let their pages sleep (the ordinary sleep, with
    /// every reason a page has to stay awake still heard), and anything long
    /// gone is let go.
    private func tick() {
        let now = Date()
        clock = now
        forget(now: now)
        for browser in Windows.all {
            let column = self.column(browser.tabs.filter(Trails.member), in: browser, now: now)
            for plan in column.earlier.flatMap(\.plans) where !ebbed.contains(plan.id) {
                ebbed.insert(plan.id)
                guard browser.prefs.sleepsTabs else { continue }
                for page in plan.pages where !page.tab.asleep { browser.sleep(page.tab) }
            }
        }
    }

    /// The bench's way to make an afternoon pass: a trail's last use set
    /// `hours` back, so Tide can be watched without waiting for it.
    func backdate(_ trail: UUID, hours: Double) {
        let when = Date().addingTimeInterval(-hours * 3600)
        if var meta = metas[trail] {
            meta.used = when
            metas[trail] = meta
        }
        for (id, var node) in nodes where node.trail == trail {
            node.used = min(node.used, when)
            nodes[id] = node
        }
        ebbed.remove(trail)
        tick()
        dirty()
    }

    // MARK: - asking for things

    /// Open or shut, as drawn: open by default while it holds the page you
    /// are on.
    func isOpen(_ plan: Plan) -> Bool { disclosure[plan.id] ?? plan.live }

    func toggle(_ plan: Plan) {
        disclosure[plan.id] = !isOpen(plan)
    }

    /// The page the hooks say a new tab came from (⌘-click, middle-click):
    /// recorded straight away, so the row is drawn under its opener.
    func adopt(_ child: Tab, parent: Tab, in browser: Browser) {
        attach(browser)
        guard Trails.member(child), Trails.member(parent) else { return }
        let rows = Dictionary(browser.tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let now = Date()
        if nodes[parent.id] == nil { place(parent, node(of: parent, among: rows, now: now), now: now) }
        guard let above = nodes[parent.id] else { return }
        let old = nodes[child.id]?.trail
        nodes[child.id] = Node(trail: above.trail, parent: parent.id, opened: now, used: now)
        if let url = child.pending ?? child.address { lastURL[child.id] = url }
        if let old, old != above.trail, !nodes.contains(where: { $0.value.trail == old }) { metas[old] = nil }
        watch(child)
        dirty()
    }

    /// Something typed into this tab: a new line of intent. A tab alone on
    /// its trail simply starts the trail over; one among others leaves it,
    /// and the pages it had opened stay behind under the page it came from.
    func reroot(_ tab: Tab, in browser: Browser? = nil, keepTitle: Bool = false) {
        if let browser { attach(browser) }
        guard started, Trails.member(tab) else { return }
        let now = Date()
        if nodes[tab.id] == nil, let browser {
            let rows = Dictionary(browser.tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            place(tab, node(of: tab, among: rows, now: now), now: now)
        }
        guard var node = nodes[tab.id] else { return }
        let old = node.trail
        let others = nodes.contains { $0.key != tab.id && $0.value.trail == old && gone[$0.key] == nil }
        for (id, var child) in nodes where child.parent == tab.id {
            child.parent = node.parent
            nodes[id] = child
        }
        let trail = others ? UUID() : old
        node.trail = trail
        node.parent = nil
        node.opened = now
        node.used = now
        nodes[tab.id] = node
        if others, var meta = metas[old], meta.founder == tab.id {
            meta.founder = nil
            meta.settled = true
            metas[old] = meta
        }
        var fresh = Meta(founder: tab.id, created: now, used: now, rank: now)
        if keepTitle, !others { fresh.title = metas[old]?.title }
        metas[trail] = fresh
        disclosure[trail] = nil
        dirty()
    }

    /// A row dropped on another trail joins it, at the top level; the pages
    /// it had opened stay where they were.
    func move(_ tab: Tab, to trail: UUID, in browser: Browser) {
        attach(browser)
        guard Trails.member(tab), metas[trail] != nil || nodes.values.contains(where: { $0.trail == trail }) else { return }
        let now = Date()
        let rows = Dictionary(browser.tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if nodes[tab.id] == nil { place(tab, node(of: tab, among: rows, now: now), now: now) }
        guard var node = nodes[tab.id], node.trail != trail else { return }
        let old = node.trail
        for (id, var child) in nodes where child.parent == tab.id {
            child.parent = node.parent
            nodes[id] = child
        }
        node.trail = trail
        node.parent = nil
        node.used = now
        nodes[tab.id] = node
        if var meta = metas[old], meta.founder == tab.id { meta.founder = nil; metas[old] = meta }
        if !nodes.contains(where: { $0.value.trail == old }) { metas[old] = nil }
        dirty()
    }

    /// The name a trail keeps while its pages wait in Reopen Closed Tab.
    func caption(_ trail: UUID, _ text: String) {
        metas[trail]?.caption = text
    }

    func rename(_ trail: UUID, to text: String) {
        guard var meta = metas[trail] else { return }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        meta.title = name.isEmpty ? nil : String(name.prefix(120))
        metas[trail] = meta
        renaming = nil
        dirty()
    }

    // MARK: - the search a trail began with

    /// `q=` (and its cousins) on a results page: Google, Bing, DuckDuckGo,
    /// Kagi, Brave, Ecosia, Startpage, Yahoo, Baidu, Yandex, Perplexity, and
    /// the searches inside GitHub, YouTube, Wikipedia and Amazon.
    static func query(in url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.host?.isEmpty == false, url.scheme?.hasPrefix("http") == true else { return nil }
        let path = parts.path.lowercased()
        // Form-encoded: a `+` is a space, which URLComponents leaves alone.
        let items = parts.percentEncodedQueryItems ?? []
        func value(_ names: [String]) -> String? {
            for name in names {
                if let raw = items.first(where: { $0.name == name })?.value,
                   let text = raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding?
                       .trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    return String(text.prefix(140))
                }
            }
            return nil
        }
        let engine = isSearchHost(url)
        let searchy = path.contains("search") || path.hasPrefix("/results") || path == "/s" || path.hasPrefix("/s/")
        guard engine || searchy else { return nil }
        if engine, path == "/" || path.isEmpty || searchy || path == "/html" || path == "/html/" {
            return value(["q", "query", "p", "wd", "text", "search_query"])
        }
        return value(["q", "query", "search_query", "search", "k", "p", "text", "wd"])
    }

    static func isSearchHost(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if bare.hasPrefix("google.") || bare.hasPrefix("bing.") || bare.hasPrefix("yandex.") { return true }
        return ["duckduckgo.com", "html.duckduckgo.com", "kagi.com", "search.brave.com", "ecosia.org",
                "startpage.com", "search.yahoo.com", "baidu.com", "perplexity.ai"].contains(bare)
    }

    // MARK: - the file

    fileprivate struct Disk: Codable {
        var version = 1
        var trails: [Trail]
        var pages: [Page]

        struct Trail: Codable {
            var id: UUID
            var founder: String?
            var title: String?
            var query: String?
            var settled: Bool?
            var caption: String?
            var created: Double
            var used: Double
            var rank: Double
        }

        /// `key` is the tab's id when it was written, which `parent` and a
        /// trail's `founder` refer to; `space`, `url` and `ordinal` are how
        /// it is found again among the rows the session restores.
        struct Page: Codable {
            var key: String
            var space: UUID?
            var url: String
            var ordinal: Int
            var trail: UUID
            var parent: String?
            var opened: Double
            var used: Double
        }
    }

    private static var file: URL { Store.file("trails.json") }
    private static let writer = DispatchQueue(label: "copper.trails.write", qos: .utility)

    private static func read() -> Disk? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard let disk = try? JSONDecoder().decode(Disk.self, from: data) else {
            Store.quarantine(file)
            return nil
        }
        return disk
    }

    /// Yesterday's trails onto the rows the session brought back, once
    /// there are rows: the same space, address and place among that space's
    /// rows with the same address — or, for a page moved to another space,
    /// the same address and place anywhere.
    private func bind() {
        guard let disk = unbound else { return }
        let spaces = Spaces.shared
        guard spaces.all.contains(where: { !spaces.row($0.id).isEmpty }) else { return }
        unbound = nil
        var exact: [String: Disk.Page] = [:]
        var loose: [String: Disk.Page] = [:]
        for page in disk.pages {
            exact["\(page.space?.uuidString ?? "")|\(page.url)|\(page.ordinal)"] = page
            if loose["\(page.url)|\(page.ordinal)"] == nil { loose["\(page.url)|\(page.ordinal)"] = page }
        }
        var claimed = Set<String>()
        var map: [String: Tab.ID] = [:]
        var found: [(Tab, Disk.Page)] = []
        for space in spaces.all {
            var ordinals: [String: Int] = [:]
            for tab in spaces.row(space.id) {
                guard let entry = Session.Entry(tab) else { continue }
                let ordinal = ordinals[entry.url, default: 0]
                ordinals[entry.url] = ordinal + 1
                guard nodes[tab.id] == nil, Trails.member(tab) else { continue }
                let page = exact["\(space.id.uuidString)|\(entry.url)|\(ordinal)"] ?? loose["\(entry.url)|\(ordinal)"]
                guard let page, claimed.insert(page.key).inserted else { continue }
                map[page.key] = tab.id
                found.append((tab, page))
            }
        }
        for (tab, page) in found {
            nodes[tab.id] = Node(trail: page.trail, parent: page.parent.flatMap { map[$0] },
                                 opened: Date(timeIntervalSince1970: page.opened), used: Date(timeIntervalSince1970: page.used))
            if let url = tab.pending ?? tab.address { lastURL[tab.id] = url }
        }
        let held = Set(found.map(\.1.trail))
        for trail in disk.trails where held.contains(trail.id) && metas[trail.id] == nil {
            metas[trail.id] = Meta(founder: trail.founder.flatMap { map[$0] }, title: trail.title, query: trail.query,
                                   settled: trail.settled ?? false, caption: trail.caption, created: Date(timeIntervalSince1970: trail.created),
                                   used: Date(timeIntervalSince1970: trail.used), rank: Date(timeIntervalSince1970: trail.rank))
        }
        // A page whose trail record didn't survive gets a plain one.
        for (tab, page) in found where metas[page.trail] == nil {
            metas[page.trail] = Meta(founder: tab.id, created: Date(timeIntervalSince1970: page.opened),
                                     used: Date(timeIntervalSince1970: page.used), rank: Date(timeIntervalSince1970: page.opened))
        }
    }

    /// The trails as they stand, keyed the way `bind` finds them again.
    private func snapshot() -> Disk {
        let spaces = Spaces.shared
        let live = Set(Windows.all.compactMap(\.activeID))
        let now = Date()
        var pages: [Disk.Page] = []
        var inUse = Set<UUID>()
        for space in spaces.all {
            var ordinals: [String: Int] = [:]
            for tab in spaces.row(space.id) {
                guard let entry = Session.Entry(tab) else { continue }
                let ordinal = ordinals[entry.url, default: 0]
                ordinals[entry.url] = ordinal + 1
                guard let node = nodes[tab.id], Trails.member(tab) else { continue }
                if live.contains(tab.id) { inUse.insert(node.trail) }
                pages.append(Disk.Page(key: tab.id.uuidString, space: space.id, url: entry.url, ordinal: ordinal,
                                       trail: node.trail, parent: node.parent?.uuidString,
                                       opened: node.opened.timeIntervalSince1970,
                                       used: (live.contains(tab.id) ? now : node.used).timeIntervalSince1970))
            }
        }
        let held = Set(pages.map(\.trail))
        let trails = metas.filter { held.contains($0.key) }.map { id, meta in
            Disk.Trail(id: id, founder: meta.founder?.uuidString, title: meta.title, query: meta.query,
                       settled: meta.settled ? true : nil, caption: meta.caption, created: meta.created.timeIntervalSince1970,
                       used: (inUse.contains(id) ? now : meta.used).timeIntervalSince1970,
                       rank: meta.rank.timeIntervalSince1970)
        }
        return Disk(trails: trails.sorted { $0.rank > $1.rank }, pages: pages)
    }

    private func dirty() {
        guard started, !writing else { return }
        writing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.writing = false
            self.write(now: false)
        }
    }

    /// One queue, in order, as `windows.json` does: an older snapshot never
    /// lands after a newer one. `now` at quit, on the thread asking to quit.
    func write(now: Bool, force: Bool = false) {
        guard started || force, Flights.trails || force, unbound == nil else { return }
        let disk = snapshot()
        let file = Trails.file
        let put: @Sendable () -> Void = {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(disk) else { return }
            try? data.write(to: file, options: .atomic)
        }
        if now { Trails.writer.sync(execute: put) } else { Trails.writer.async(execute: put) }
    }
}

// MARK: - the column, worked out

extension Trails {
    /// One page as the column draws it: how far in (0…2; deeper pages are
    /// drawn at the third level), which of the lines to its left carry on
    /// past it, whether its own line carries on below it, and whether pages
    /// hang from it.
    struct Page: Identifiable {
        let tab: Tab
        let depth: Int
        let rails: [Bool]
        let more: Bool
        let kids: Bool
        var id: Tab.ID { tab.id }
    }

    struct Plan: Identifiable {
        let id: UUID
        let title: String
        /// It began with a search: it wears the glass, not the path.
        let searched: Bool
        let pages: [Page]
        let used: Date
        let rank: Date
        /// Holds this window's front tab.
        let live: Bool
        /// On a stage somewhere — any window's front tab or the split's other
        /// pane — and so never under Earlier.
        let busy: Bool
        /// Where a click on the folded row goes: the page used last.
        let recent: Tab
        var single: Bool { pages.count == 1 }
    }

    struct Column {
        var fresh: [Plan] = []
        var earlier: [(title: String, plans: [Plan])] = []
        var count: Int { fresh.count + earlier.reduce(0) { $0 + $1.plans.count } }
    }

    /// The Today rows of one window, as trails: the fresh ones newest first,
    /// then — under the Earlier divider — the ones Tide has carried off,
    /// grouped by when they were last used.
    func column(_ tabs: [Tab], in browser: Browser, now: Date = Date()) -> Column {
        let rows = Dictionary(browser.tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var order: [UUID] = []
        var groups: [UUID: [(tab: Tab, node: Node, index: Int)]] = [:]
        for (index, tab) in tabs.enumerated() {
            let node = node(of: tab, among: rows, now: now)
            if groups[node.trail] == nil { order.append(node.trail) }
            groups[node.trail, default: []].append((tab, node, index))
        }
        var staged = Set(Windows.all.compactMap(\.activeID))
        for tab in tabs where Split.shared.has(tab.id) { staged.insert(tab.id) }
        let plans = order.compactMap { id in groups[id].map { plan(id, $0, browser: browser, staged: staged, now: now) } }

        var column = Column()
        var earlier: [Plan] = []
        for plan in plans {
            if !plan.busy, ebbs(plan.used, now: now) { earlier.append(plan) } else { column.fresh.append(plan) }
        }
        column.fresh.sort { $0.rank > $1.rank }
        earlier.sort { $0.used > $1.used }
        let calendar = Calendar.current
        var buckets: [(title: String, plans: [Plan])] = []
        for plan in earlier {
            let title: String
            if calendar.isDateInToday(plan.used) { title = "Today" }
            else if calendar.isDateInYesterday(plan.used) { title = "Yesterday" }
            else if now.timeIntervalSince(plan.used) < 7 * 86_400 { title = "This Week" }
            else { title = "Older" }
            if buckets.last?.title == title { buckets[buckets.count - 1].plans.append(plan) } else { buckets.append((title, [plan])) }
        }
        column.earlier = buckets
        return column
    }

    private func plan(_ id: UUID, _ members: [(tab: Tab, node: Node, index: Int)], browser: Browser, staged: Set<Tab.ID>, now: Date) -> Plan {
        let byID = Dictionary(members.map { ($0.tab.id, $0) }, uniquingKeysWith: { a, _ in a })
        func earlier(_ a: (tab: Tab, node: Node, index: Int), _ b: (tab: Tab, node: Node, index: Int)) -> Bool {
            a.node.opened == b.node.opened ? a.index > b.index : a.node.opened < b.node.opened
        }
        var children: [Tab.ID: [(tab: Tab, node: Node, index: Int)]] = [:]
        var top: [(tab: Tab, node: Node, index: Int)] = []
        for member in members {
            if let up = member.node.parent, up != member.tab.id, byID[up] != nil {
                children[up, default: []].append(member)
            } else {
                top.append(member)
            }
        }
        // Depth-first, deeper than the third level drawn at the third.
        var flat: [(tab: Tab, depth: Int, parent: Tab.ID?)] = []
        var visited = Set<Tab.ID>()
        func walk(_ member: (tab: Tab, node: Node, index: Int), depth: Int, ancestors: [Tab.ID]) {
            guard visited.insert(member.tab.id).inserted else { return }
            let parent: Tab.ID? = depth == 0 ? nil : (depth <= 2 ? ancestors.last : ancestors[1])
            flat.append((member.tab, min(depth, 2), parent))
            for kid in (children[member.tab.id] ?? []).sorted(by: earlier) {
                walk(kid, depth: depth + 1, ancestors: ancestors + [member.tab.id])
            }
        }
        for member in top.sorted(by: earlier) { walk(member, depth: 0, ancestors: []) }
        // A loop in the lineage (it shouldn't happen) still draws every page.
        for member in members where !visited.contains(member.tab.id) { walk(member, depth: 0, ancestors: []) }

        var pages: [Page] = []
        var open: [Bool] = []
        for (i, item) in flat.enumerated() {
            let more = flat[(i + 1)...].contains { $0.parent == item.parent }
            let kids = i + 1 < flat.count && flat[i + 1].parent == item.tab.id
            let rails = Array(open.prefix(item.depth)) + Array(repeating: false, count: max(0, item.depth - open.count))
            pages.append(Page(tab: item.tab, depth: item.depth, rails: rails, more: more, kids: kids))
            open = Array(rails.prefix(item.depth)) + [more]
        }

        let meta = metas[id]
        let founder = meta?.founder.flatMap { f in members.first { $0.tab.id == f }?.tab }
            ?? (meta == nil ? members.first { $0.tab.id == id }?.tab : nil)
        var query = meta?.query
        if query == nil, meta?.settled != true, let tab = founder ?? pages.first?.tab, let url = tab.pending ?? tab.address {
            query = Trails.query(in: url)
        }
        let named = meta?.title
        let title = named ?? query ?? founder?.label ?? meta?.caption ?? pages.first?.tab.label ?? "Trail"
        let used = max(meta?.used ?? .distantPast, members.map(\.node.used).max() ?? now)
        let rank = meta?.rank ?? (members.map(\.node.opened).min() ?? now)
        let recent = members.max { a, b in a.node.used == b.node.used ? a.index > b.index : a.node.used < b.node.used }?.tab ?? members[0].tab
        return Plan(id: id, title: title, searched: query != nil, pages: pages, used: used, rank: rank,
                    live: members.contains { $0.tab.id == browser.activeID },
                    busy: members.contains { staged.contains($0.tab.id) }, recent: recent)
    }
}

// MARK: - the hooks (one line each in Browser.swift; nothing while the flight is off)

extension Trails {
    /// `decidePolicyFor`: a ⌘-click or middle-click opened `child` beside
    /// the page it was clicked in.
    static func opened(_ child: Tab, from opener: @autoclosure () -> Tab?, in browser: Browser) {
        // The opener is only looked up with the flight on.
        guard Flights.trails, let parent = opener(), parent.id != child.id else { return }
        shared.adopt(child, parent: parent, in: browser)
    }

    /// `submit()` and `commitTabEdit()`: an address or a search typed into a
    /// tab that already has a page — a new line of intent.
    static func typed(into tab: Tab?, in browser: Browser) {
        guard Flights.trails, let tab else { return }
        shared.reroot(tab, in: browser)
    }
}
