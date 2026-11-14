import AppKit
import Foundation
import os

// ⌘T, the way Arc has it.
//
// Upstream's ⌘T makes a blank tab and puts the cursor in its field, so every
// ⌘T you regret is a tab you have to close again. Arc's asks first: the same
// card as ⌘K, a question, and a handful of answers in groups — search for it,
// what Google thinks you are typing, the tab you already have open, the page
// you were on last week — and no tab exists until you pick one. Escape and
// you are exactly where you were.
//
// The card is CommandPalette's; this decides what goes in it and what picking
// a row does. Browser keeps the flat list of rows (so the arrow keys, Return
// and the pointer work the way they already do) and asks here for it on every
// keystroke. The rows come in sections, always in the same order — open tabs,
// history, bookmarks, canvases, commands, then the search — and Tab and ⇧Tab
// jump between them (Fork/CardSections). The two slow sources — Google's completions and a ranking of all
// of history — are worked out away from the keystroke and handed back through
// `Browser.relaunch` when they land.

@MainActor
final class Launcher: ObservableObject {
    static let shared = Launcher()

    /// The titled groups: the row a heading sits above, and what it says.
    /// Kept in `CardSections`, which the card draws them from.
    var headings: [Int: String] { CardSections.shared.headings }

    /// What Return does to a row, and the two other things it can do.
    enum How: String { case open, background, split }

    /// How many rows each group may bring. Enough that the answer you meant
    /// is usually on screen; few enough that the card stays one thing you
    /// glance at rather than a page you scroll.
    private enum Cap {
        static let suggestions = 4
        static let tabs = 4
        static let history = 4
        static let bookmarks = 2
        static let commands = 2
        static let recent = 6
        static let elsewhere = 2
        static let closed = 2
    }

    /// The question now on screen. Anything that lands for another one is
    /// late and is dropped (or kept, for when you backspace to it).
    private var asked = ""
    private weak var browser: Browser?

    /// Google's completions, by query, so backspacing asks nobody anything.
    private var completions: [String: [String]] = [:]
    private var remembered: [String] = []
    /// The last completions that landed, for any query. Until the answer to
    /// this keystroke arrives, the answer to the previous one — whittled to
    /// what still fits — holds the group's place, so the rows under it do not
    /// jump up and back down on every letter.
    private var lastCompletions: [String] = []
    private var fetch: URLSessionDataTask?
    private var waiting: DispatchWorkItem?

    /// History's best rows for the question they answer.
    private var visited: (query: String, rows: [Hit]) = ("", [])
    private let ranking = DispatchQueue(label: "copper.launcher.history", qos: .userInitiated)

    /// A cookie-less, cache-less session: a query completion is a question
    /// about words, and nothing about it needs to be remembered by anyone.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.timeoutIntervalForRequest = 2.5
        return URLSession(configuration: config)
    }()

    /// Bench counters: completions asked for, and asks cancelled by a later
    /// keystroke before they were sent.
    private(set) var sent = 0
    private(set) var dropped = 0

    // MARK: - asking

    /// Fork (perf): `body` in the main run loop's next pass, once this pass's
    /// Core Animation commit has gone out. A block queued with
    /// `DispatchQueue.main.async` still runs in this pass (the run loop drains
    /// the queue before it commits), so its redraw would join this one's.
    static func afterCommit(_ body: @escaping () -> Void) {
        // Ordered after Core Animation's own before-waiting observer (2,000,000).
        let after = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { _, _ in
            DispatchQueue.main.async(execute: body)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), after, .commonModes)
    }

    /// A fresh card. The last question's leftovers are not this one's.
    func begin() {
        waiting?.cancel()
        fetch?.cancel()
        asked = ""
        lastCompletions = []
        visited = ("", [])
        CardSections.shared.show([:])
        shelved = nil
        standing = nil
        verbs = nil
    }

    /// The rows for what is in the field, now — from what is at hand — with
    /// the slower answers sent for.
    func rows(for typed: String, in browser: Browser) -> [Suggestion] {
        self.browser = browser
        let query = typed.trimmingCharacters(in: .whitespaces)
        asked = query
        guard !query.isEmpty else {
            waiting?.cancel()
            fetch?.cancel()
            return resting(in: browser)
        }
        rank(query, in: browser)
        complete(query)
        return assemble(query, in: browser)
    }

    /// Everything that has landed so far, laid out for `query`, in the card's
    /// fixed order (Fork/CardSections): open tabs, history, bookmarks,
    /// canvases, commands, and the search last. Return takes the first row —
    /// the best place you already know — and only asks Google when nothing
    /// you know answers. An address typed in full is the exception: it leads
    /// the card, under no heading, so Return still goes straight there.
    private func assemble(_ query: String, in browser: Browser) -> [Suggestion] {
        var sections: [CardSection: [Suggestion]] = [:]
        var seen = Set<String>()
        func keep(_ row: Suggestion) -> Bool { seen.insert(Launcher.canonical(row.url)).inserted }

        let top = Launcher.top(query, in: browser)
        let address = top.kind != .search
        let needle = query.lowercased()
        // "/" asks for the browser's own commands, and only for them: the
        // places that happen to have "/split" in their path are not the answer.
        let commanding = needle.hasPrefix("/")
        // Readied once for the tabs, the bookmarks and history's stand-ins.
        let probe = commanding ? nil : Needle(needle)
        // Open tabs are claimed first: "github.com" typed with GitHub open
        // should still offer the switch, not only a second copy.
        // Every match is claimed, the rows are built for the few shown.
        // This space's first, then the ones parked in others, each wearing
        // its space so you know a switch is coming.
        var open: [Suggestion] = []
        for match in tabs(matching: probe, in: browser) where seen.insert(match.canonical).inserted {
            if open.count < Cap.tabs, let row = Launcher.row(for: match.tab, current: match.current, browser: browser) { open.append(row) }
        }
        sections[.tabs] = open
        // What Return does with the words themselves is claimed before
        // history, so a visit to the same address is not offered twice.
        _ = keep(top)

        // History, ranked away from the keystroke. Until this query's ranking
        // is in, the last one's rows that still match stand in for it, so the
        // section does not blink out and back on every letter.
        if let probe {
            let hits = visited.query == needle ? visited.rows
                : visited.rows.filter { probe.score(key: $0.key, title: $0.title.lowercased()) != nil }
            // A site's untitled front door is the credit its deeper pages give
            // it; beside one of those pages it is the same answer said twice.
            let titledHosts = Set(hits.filter { !$0.title.isEmpty }.compactMap { URL(string: $0.url)?.host() })
            var been: [Suggestion] = []
            for hit in hits {
                guard let url = URL(string: hit.url) else { continue }
                if hit.title.isEmpty, !hit.key.contains("/"), let host = url.host(), titledHosts.contains(host) { continue }
                var row = Suggestion(key: hit.title.isEmpty ? hit.key : hit.title, title: hit.key, url: url, kind: .visited)
                row.detail = Launcher.host(url, besides: row.key)
                row.hint = pageHint(browser)
                guard keep(row) else { continue }
                been.append(row)
                if been.count == Cap.history { break }
            }
            sections[.history] = been

            var marks: [Suggestion] = []
            for mark in shelf(browser) {
                guard probe.score(key: mark.address, title: mark.lowered) != nil else { continue }
                let (title, url) = (mark.title, mark.url)
                var row = Suggestion(key: title.isEmpty ? Address.pretty(url) : title, title: Address.pretty(url), url: url, kind: .bookmark)
                row.detail = Launcher.host(url, besides: row.key)
                row.hint = pageHint(browser)
                guard keep(row) else { continue }
                marks.append(row)
                if marks.count == Cap.bookmarks { break }
            }
            sections[.bookmarks] = marks

            // Fork (canvas): canvases by name — "canvas" alone, all of them.
            var boards: [Suggestion] = []
            for row in CanvasTabs.offers(for: query) where keep(row) {
                boards.append(row)
                if boards.count == 3 { break }
            }
            sections[.canvases] = boards
        }

        // The browser's own commands, few: ⌘T is for going somewhere, and
        // ⌘K is where commands live. "/" asks for them alone.
        let commandNeedle = commanding ? String(needle.dropFirst()) : needle
        var doing: [Suggestion] = []
        if !commandNeedle.isEmpty {
            for command in commands(browser) where command.name.lowercased().contains(commandNeedle) {
                var row = Suggestion(key: command.name, title: "", url: URL(string: "copper://command/\(command.id)")!, kind: .command)
                row.glyph = command.glyph
                row.hint = "Run"
                doing.append(row)
                if doing.count == Cap.commands { break }
            }
        }
        sections[.commands] = doing

        // The search, last: the words as a Google search, then what Google
        // thinks you are typing — the ones for this query if they are in, the
        // last ones that still carry on from it if not. Google answers after
        // everything else; at the foot of the card its rows land without
        // pushing anything you were reading.
        var searches: [Suggestion] = []
        if address, !needle.contains("://"), let url = Google.url(for: query) {
            // An address can still be words you meant to look up: "node.js".
            // One pasted with its scheme is not.
            var row = Suggestion(key: "Search \(Google.name) for “\(query)”", title: Google.name, url: url, kind: .search)
            row.hint = pageHint(browser)
            if keep(row) { searches.append(row) }
        }
        let words = completions[needle] ?? lastCompletions.filter { $0.lowercased().hasPrefix(needle) }
        var phrases = 0
        for phrase in words where phrase.lowercased() != needle {
            guard let url = Google.url(for: phrase) else { continue }
            var row = Suggestion(key: phrase, title: Google.name, url: url, kind: .search)
            row.hint = "Search \(Google.name)"
            guard keep(row) else { continue }
            searches.append(row)
            phrases += 1
            if phrases == Cap.suggestions { break }
        }
        sections[.search] = searches

        let laid = Launcher.layout(top: top, sections)
        CardSections.shared.show(laid.headings)
        return laid.rows
    }

    /// Where the row for the words themselves goes. A search is the first
    /// row of the Search section, below everything you already know; an
    /// address typed in full leads the card under no heading, so Return goes
    /// to it as it always has (Tests/SearchTests/CardSectionsTests).
    nonisolated static func layout(top: Suggestion, _ sections: [CardSection: [Suggestion]]) -> (rows: [Suggestion], headings: [Int: String]) {
        guard top.kind == .search else { return CardSections.lay(lead: [top], sections: sections) }
        var sections = sections
        sections[.search] = [top] + (sections[.search] ?? [])
        return CardSections.lay(sections: sections)
    }

    /// The first row: what Return does with the words as they stand.
    static func top(_ query: String, in browser: Browser) -> Suggestion {
        if let url = Address.url(from: query) {
            // Fork (canvas): a canvas address reads as its name.
            var row = Suggestion(key: "Open \(CanvasLinks.label(url) ?? Launcher.spoken(url))", title: "", url: url, kind: .known)
            row.hint = pageHint(browser)
            return row
        }
        var row = Suggestion(key: "Search \(Google.name) for “\(query)”", title: Google.name,
                             url: Google.url(for: query) ?? URL(string: "https://www.google.com")!, kind: .search)
        row.hint = pageHint(browser)
        return row
    }

    /// An address as the row says it: `Address.pretty`, with the port kept —
    /// "Open localhost:3000", not "Open localhost", is where Return goes.
    nonisolated static func spoken(_ url: URL) -> String {
        let pretty = Address.pretty(url)
        guard let port = url.port, let full = url.host() else { return pretty }
        let host = full.hasPrefix("www.") ? String(full.dropFirst(4)) : full
        guard pretty.hasPrefix(host) else { return pretty }
        return host + ":\(port)" + pretty.dropFirst(host.count)
    }

    /// Said on the right of a row that opens a page. A blank tab under the
    /// card takes the page itself, so there it is not a new tab.
    static func pageHint(_ browser: Browser) -> String {
        browser.active?.isBlank == true ? "Open" : "Open in New Tab"
    }

    private func pageHint(_ browser: Browser) -> String { Launcher.pageHint(browser) }

    // MARK: - the empty card

    /// Nothing typed: the tabs you were just on, most recent first — the
    /// same order Control-Tab walks — with the first of them highlighted, so
    /// ⌘T, Return goes back one and each ↓ before it goes back one more.
    /// Then the tabs you closed, a Tab away.
    private func resting(in browser: Browser) -> [Suggestion] {
        let here = Dictionary(browser.tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let parked = Dictionary(Spaces.shared.parkedTabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // The trail first — where you actually were, across space switches —
        // then the row's own order for tabs not looked at since launch.
        var recent: [Suggestion] = []
        var listed = Set<Tab.ID>()
        for id in Recent.shared.trail + Recent.shared.order where id != browser.activeID && !listed.contains(id) {
            guard let tab = here[id], !tab.isBlank, let row = Launcher.row(for: tab, current: true, browser: browser) else { continue }
            listed.insert(id)
            recent.append(row)
            if recent.count == Cap.recent { break }
        }
        // Then a couple from other spaces: the ones you left most recently
        // by the trail, or by when they were last looked at.
        let away = Recent.shared.trail.compactMap { parked[$0] }
            + Spaces.shared.parkedTabs.sorted { $0.touched > $1.touched }
        var others = 0
        for tab in away where others < Cap.elsewhere && !tab.isBlank && !listed.contains(tab.id) {
            guard let row = Launcher.row(for: tab, current: false, browser: browser) else { continue }
            listed.insert(tab.id)
            recent.append(row)
            others += 1
        }

        let closed = browser.ghosts.reversed().prefix(Cap.closed).map { ghost -> Suggestion in
            var row = Suggestion(key: "Reopen “\(ghost.label)”", title: "",
                                 url: URL(string: "copper://reopen/\(ghost.id.uuidString)")!, kind: .command)
            row.glyph = "arrow.uturn.backward"
            row.detail = Launcher.host(ghost.url, besides: ghost.label)
            row.hint = "Reopen"
            return row
        }
        let laid = CardSections.lay([(title: "Recent Tabs", rows: recent), (title: "Recently Closed", rows: Array(closed))])
        CardSections.shared.show(laid.headings)
        return laid.rows
    }

    // MARK: - open tabs

    /// An open tab as it is matched, read once when the card opens. Reading
    /// a tab's published properties goes through Combine and is slow enough
    /// that two hundred tabs read afresh on every keystroke — and again on
    /// every answer that landed — were most of what a letter cost.
    struct Open {
        let tab: Tab
        let current: Bool
        let address: String
        let title: String
        let canonical: String
        let touched: Date
        /// Pinned or Saved: ⌘K lifts these a little over a loose tab.
        let kept: Bool
    }

    private var standing: [Open]?

    /// Every open tab but the one in front, read once a card (⌘T's or ⌘K's).
    func openTabs(_ browser: Browser) -> [Open] {
        if let standing { return standing }
        var list: [Open] = []
        func add(_ tab: Tab, current: Bool) {
            guard tab.id != browser.activeID, !tab.isBlank, let url = tab.address else { return }
            list.append(Open(tab: tab, current: current, address: Launcher.strip(Address.pretty(url)),
                             title: tab.label.lowercased(), canonical: Launcher.canonical(url), touched: tab.touched,
                             kept: tab.pin != nil || Sections.shared.isSaved(tab)))
        }
        browser.tabs.forEach { add($0, current: true) }
        Spaces.shared.parkedTabs.forEach { add($0, current: false) }
        standing = list
        return list
    }

    /// The open tabs that match, best first. This space's tabs above every
    /// other space's: the one you can switch to without the column changing
    /// under you comes first.
    private func tabs(matching needle: Needle?, in browser: Browser) -> [Open] {
        guard let needle else { return [] }
        var scored: [(open: Open, rank: Double)] = []
        for open in openTabs(browser) {
            guard let match = needle.score(key: open.address, title: open.title) else { continue }
            scored.append((open, match + (open.current ? 1_000 : 0)))
        }
        return scored
            .sorted { $0.rank == $1.rank ? $0.open.touched > $1.open.touched : $0.rank > $1.rank }
            .map(\.open)
    }

    private static func row(for tab: Tab, current: Bool, browser: Browser) -> Suggestion? {
        guard let url = tab.address else { return nil }
        var row = Suggestion(key: tab.label, title: Address.pretty(url), url: url, kind: .open, tab: tab.id)
        row.detail = host(url, besides: tab.label)
        row.hint = "Switch to Tab"
        if !current, let space = Spaces.shared.all.first(where: { Spaces.shared.parkedRow($0.id)?.contains { $0.id == tab.id } == true }) {
            let name = space.title.count <= 22 ? space.title : String(space.title.prefix(21)) + "…"
            row.badge = "· " + (space.emoji.map { "\($0) " } ?? "") + name
        }
        return row
    }

    // MARK: - history, off the main thread

    /// One ranked place from history, carried back from the ranking queue.
    struct Hit: Sendable {
        let key: String
        let title: String
        let url: String
    }

    private let ranker = Ranker()

    /// ⌘K's history: this query's ranked places if they are in, else the
    /// last query's that still match, with the ranking sent for. When it
    /// lands, `refresh` lays ⌘K's card out again — so a keystroke on ⌘K, as
    /// on ⌘T, never ranks history on the main thread.
    func history(for typed: String, in browser: Browser) -> [Hit] {
        self.browser = browser
        let query = typed.trimmingCharacters(in: .whitespaces)
        asked = query
        let needle = query.lowercased()
        guard let probe = Needle(needle) else { return [] }
        rank(query, in: browser)
        return visited.query == needle ? visited.rows
            : visited.rows.filter { probe.score(key: $0.key, title: $0.title.lowercased()) != nil }
    }

    private func rank(_ query: String, in browser: Browser) {
        let needle = query.lowercased()
        guard visited.query != needle else { return }
        // History as it stands, handed over by reference: flattening it and
        // ranking it both happen on the queue, so however long the history,
        // a keystroke costs the main thread nothing here.
        let history = browser.history.snapshot
        let now = Date()
        // Each keystroke calls off the ranking before it. A word typed at
        // speed is ranked for the word, not once per letter in a line.
        let ask = ranker.ask()
        ranking.async { [weak self, ranker] in
            guard let rows = ranker.rank(history, needle: needle, now: now, limit: 8, ask: ask) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                // A ranking for an older question is no use to this one.
                guard self.asked.lowercased() == needle else { return }
                self.visited = (needle, rows)
                // Fork (perf): drawn in a pass of its own, not on top of the
                // keystroke's (whose rows are being drawn as it lands).
                Launcher.afterCommit { self.refresh() }
            }
        }
    }

    /// The ranking queue's own state: history flattened once per change to
    /// it rather than once per keystroke, and the places the last question
    /// matched — typing on only ever narrows them, so "gith" looks through
    /// what "git" found rather than through all of history again.
    private final class Ranker: @unchecked Sendable {
        /// The newest ask. Bumped on the main thread, read on the queue.
        private let latest = OSAllocatedUnfairLock(initialState: 0)
        // The rest is only ever touched on the ranking queue.
        private var generation = -1
        private var places: [History.Place] = []
        private var last: (needle: Needle, matched: [Int])?

        func ask() -> Int { latest.withLock { $0 += 1; return $0 } }

        private func stale(_ ask: Int) -> Bool { latest.withLock { $0 } != ask }

        /// Where the words match first, then how often and how lately you
        /// went. A month-old habit counts for about a third of a fresh one,
        /// as it does for the address field's own completion. Nil when a
        /// later keystroke has already made the question moot.
        func rank(_ history: History.Snapshot, needle text: String, now: Date, limit: Int, ask: Int) -> [Hit]? {
            guard !stale(ask) else { return nil }
            if history.generation != generation {
                places = history.places()
                generation = history.generation
                last = nil
            }
            guard let needle = Needle(text) else { return [] }
            let candidates = last.flatMap { needle.narrows($0.needle) ? $0.matched : nil } ?? Array(places.indices)
            var matched: [Int] = []
            var scored: [(index: Int, score: Double)] = []
            for (step, index) in candidates.enumerated() {
                if step & 4095 == 4095, stale(ask) { return nil }
                let place = places[index]
                guard let match = needle.score(key: place.key, title: place.lowered) else { continue }
                matched.append(index)
                let days = max(0, now.timeIntervalSince(place.last) / 86_400)
                let frecency = Double(place.count) * exp(-days / 30)
                // A bare domain with no title is a credit every deeper visit
                // gives its front door; it is still a good answer to its own name.
                let door = place.key.utf8.contains(Needle.slash) ? 0.0 : 4.0
                scored.append((index, match + door + 12 * log1p(frecency)))
            }
            last = (needle, matched)
            return scored
                .sorted { $0.score == $1.score ? places[$0.index].key.count < places[$1.index].key.count : $0.score > $1.score }
                .prefix(limit)
                .map { Hit(key: places[$0.index].key, title: places[$0.index].title, url: places[$0.index].url) }
        }
    }

    /// What was typed, made ready once for matching against thousands of
    /// places: stripped the way addresses are, and held as UTF-8, so a match
    /// is a run of byte comparisons rather than a string search that
    /// allocates. Both sides are lowercased already; the one difference from
    /// matching letter by letter is that an accent spelled as a separate
    /// mark ("i" + "◌́") now also answers to the bare letter.
    struct Needle: Sendable {
        static let slash = UInt8(ascii: "/")
        private static let dot = UInt8(ascii: ".")
        private static let space = UInt8(ascii: " ")

        private let bytes: [UInt8]
        private let words: [[UInt8]]
        /// In letters, not bytes: the two- and three-letter thresholds below
        /// count what was typed.
        private let length: Int
        private let spaced: Bool
        private let dotted: Bool

        init?(_ typed: String) {
            let text = Launcher.strip(typed)
            guard !text.isEmpty else { return nil }
            bytes = Array(text.utf8)
            words = text.split(separator: " ").map { Array($0.utf8) }
            length = text.count
            spaced = text.contains(" ")
            dotted = text.contains(".")
        }

        /// This is `shorter` typed further, so whatever this matches, it
        /// matched too. Not under three letters: below that a match in the
        /// middle of a word is not allowed yet, and a longer needle can find
        /// places the shorter one could not.
        func narrows(_ shorter: Needle) -> Bool {
            shorter.length >= 3 && bytes.starts(with: shorter.bytes)
        }

        /// How well this fits a place: its address from the start, one of
        /// its host's labels, a word of its title, and — past two letters —
        /// anywhere in its host or title. Several words must each be found.
        func score(key: String, title: String) -> Double? {
            var key = key, title = title
            return key.withUTF8 { key in title.withUTF8 { title in score(key, title) } }
        }

        private func score(_ key: UnsafeBufferPointer<UInt8>, _ title: UnsafeBufferPointer<UInt8>) -> Double? {
            if spaced {
                for word in words where Needle.find(word, in: title) == nil && Needle.find(word, in: key) == nil { return nil }
                return Needle.starts(title, with: words[0]) ? 70 : 55
            }
            if Needle.starts(key, with: bytes) { return 100 }
            let host = key.firstIndex(of: Needle.slash) ?? key.count
            // A label of the host: "linear" finds linear.app, "exo" finds
            // cloud-ems.dev.exowatt.com. A label holds no dot, so a needle
            // with one never starts a label.
            if !dotted {
                for start in 0..<host where (start == 0 || key[start - 1] == Needle.dot) && key[start] != Needle.dot {
                    if Needle.starts(key, with: bytes, at: start, before: host) { return 85 }
                }
            }
            if Needle.starts(title, with: bytes) { return 75 }
            var from = 0
            while let at = Needle.find(bytes, in: title, from: from) {
                if at > 0, title[at - 1] == Needle.space { return 75 }
                from = at + 1
            }
            guard length >= 2 else { return nil }
            if Needle.find(bytes, in: key, before: host) != nil { return 60 }
            if Needle.find(bytes, in: title) != nil { return 50 }
            if length >= 3, Needle.find(bytes, in: key) != nil { return 35 }
            return nil
        }

        private static func starts(_ hay: UnsafeBufferPointer<UInt8>, with needle: [UInt8], at start: Int = 0, before end: Int? = nil) -> Bool {
            guard (end ?? hay.count) - start >= needle.count else { return false }
            for offset in needle.indices where hay[start + offset] != needle[offset] { return false }
            return true
        }

        private static func find(_ needle: [UInt8], in hay: UnsafeBufferPointer<UInt8>, from start: Int = 0, before end: Int? = nil) -> Int? {
            let end = end ?? hay.count
            guard let first = needle.first, end - start >= needle.count else { return nil }
            for at in start...(end - needle.count) where hay[at] == first {
                if starts(hay, with: needle, at: at, before: end) { return at }
            }
            return nil
        }
    }

    // MARK: - Google's completions

    /// Asked for a beat after the last keystroke rather than on every one,
    /// and the ask before it called off: a word typed at speed is one
    /// question, not seven.
    private func complete(_ query: String) {
        let needle = query.lowercased()
        waiting?.cancel()
        if fetch != nil { fetch?.cancel(); fetch = nil; dropped += 1 }
        // A command is not a search, and a pasted address with its scheme is
        // not a query anyone completes.
        guard completions[needle] == nil, !needle.hasPrefix("/"), !needle.contains("://") else { return }
        let work = DispatchWorkItem { [weak self] in self?.ask(needle) }
        waiting = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func ask(_ needle: String) {
        guard asked.lowercased() == needle else { return }
        var parts = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
        parts.queryItems = [
            URLQueryItem(name: "client", value: "firefox"),
            URLQueryItem(name: "ie", value: "utf-8"),
            URLQueryItem(name: "oe", value: "utf-8"),
            URLQueryItem(name: "q", value: needle),
        ]
        guard let url = parts.url else { return }
        sent += 1
        // Offline, refused or slow: the group simply never appears. There is
        // nothing to tell anyone — the search row above it still works.
        let task = Launcher.session.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let list = Launcher.parse(data) else { return }
            DispatchQueue.main.async { self?.landed(needle, list) }
        }
        fetch = task
        task.resume()
    }

    /// `["query", ["completion", …], …]`, as Firefox's search box is sent.
    nonisolated static func parse(_ data: Data) -> [String]? {
        let body = (try? JSONSerialization.jsonObject(with: data))
            ?? String(data: data, encoding: .isoLatin1).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
        guard let array = body as? [Any], array.count > 1, let list = array[1] as? [String] else { return nil }
        return list
    }

    private func landed(_ needle: String, _ list: [String]) {
        fetch = nil
        completions[needle] = list
        remembered.append(needle)
        if remembered.count > 64 { completions[remembered.removeFirst()] = nil }
        guard asked.lowercased() == needle else { return }
        lastCompletions = list
        refresh()
    }

    /// Something landed for the question on screen: lay the card out again —
    /// ⌘T's, or ⌘K's when it was ⌘K that asked.
    private func refresh() {
        guard let browser, browser.summoning, !asked.isEmpty else { return }
        browser.relaunch(browser.launching ? assemble(asked, in: browser) : CommandBar.offers(for: browser.typed, in: browser))
    }

    // MARK: - picking

    /// A row, taken. Return opens it in a new tab (or in the blank tab the
    /// card is over); ⇧Return opens it behind the tab you are on; ⌥Return
    /// opens it beside it, in a split. An open tab is switched to — across
    /// spaces — rather than opened a second time.
    func take(_ row: Suggestion, in browser: Browser, how asked: How? = nil) {
        let how = asked ?? Launcher.how(from: NSApp.currentEvent)
        if row.url.scheme == "copper" {
            browser.landed()
            if row.url.host() == "reopen" {
                if let id = UUID(uuidString: row.url.lastPathComponent), let ghost = browser.ghosts.first(where: { $0.id == id }) {
                    browser.reopen(ghost)
                }
            } else {
                _ = CommandBar.run(row.url, in: browser)
            }
            return
        }
        if let id = row.tab {
            if let tab = browser.tabs.first(where: { $0.id == id }) {
                if how == .split, tab.id != browser.activeID { Split.shared.open(with: tab, in: browser) }
                else { browser.select(tab) }
            } else {
                _ = Spaces.shared.reveal(id, in: browser)
            }
            browser.landed()
            return
        }
        switch how {
        case .open:
            if let active = browser.active, active.isBlank, !active.floating {
                active.go(to: row.url)
                browser.editing = false
            } else {
                browser.open(row.url, foreground: true)
            }
        case .background:
            browser.open(row.url, foreground: false)
            browser.announce("Opened in the background")
        case .split:
            let tab = browser.open(row.url, foreground: false)
            Split.shared.open(with: tab, in: browser)
        }
        browser.landed()
    }

    /// Return with nothing picked: the words themselves.
    func take(typed: String, in browser: Browser, how: How? = nil) {
        let query = typed.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        take(Launcher.top(query, in: browser), in: browser, how: how)
    }

    private static func how(from event: NSEvent?) -> How {
        let flags = event?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        if flags.contains(.option) { return .split }
        if flags.contains(.shift) { return .background }
        return .open
    }

    /// The other ways to take the row you are on, said quietly beside what
    /// Return does. Empty for a row that has only one thing to do.
    static func aside(for row: Suggestion, in browser: Browser) -> String {
        if row.url.scheme == "copper" { return "" }
        if let id = row.tab {
            return browser.tabs.contains(where: { $0.id == id }) ? "⌥↩ Split" : ""
        }
        return "⇧↩ Background   ⌥↩ Split"
    }

    // MARK: - keys

    /// The keys the card answers before the field does. Plain Return and
    /// the arrows are the field's already; these are the ones it has no word
    /// for. True when the key was used.
    static func key(_ event: NSEvent, in browser: Browser) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 53:
            // One press, all the way out. ⌘K's first Escape lets go of the
            // row; here nothing has happened yet, so there is nothing to undo
            // step by step.
            browser.dismiss()
            return true
        case 36, 76:
            // Plain Return is the field's, and goes through Browser.submit.
            guard !flags.contains(.command), flags.contains(.shift) || flags.contains(.option) else { return false }
            // An input method still composing gets its Return.
            if let editor = event.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
            let how: How = flags.contains(.option) ? .split : .background
            if let picked = browser.picked, browser.offers.indices.contains(picked) {
                shared.take(browser.offers[picked], in: browser, how: how)
            } else {
                shared.take(typed: browser.typed, in: browser, how: how)
            }
            return true
        default:
            // ⌘1–⌘9: the row with that number, without walking to it.
            guard flags == .command, let digit = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(digit) else { return false }
            if browser.offers.indices.contains(digit - 1) { shared.take(browser.offers[digit - 1], in: browser, how: .open) }
            return true
        }
    }

    // MARK: - small pieces

    /// One address however it was written. The query stays: two Google
    /// searches differ only in theirs, and `Address.pretty` drops it.
    static func canonical(_ url: URL) -> String {
        var text = strip(url.absoluteString)
        if let hash = text.firstIndex(of: "#") { text = String(text[..<hash]) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    nonisolated static func strip(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces).lowercased()
        for scheme in ["https://", "http://"] where value.hasPrefix(scheme) {
            value = String(value.dropFirst(scheme.count))
        }
        if value.hasPrefix("www.") { value = String(value.dropFirst(4)) }
        return value
    }

    /// The host, which is the part of an address anyone reads — unless the
    /// row is already called by it.
    static func host(_ url: URL, besides name: String) -> String {
        let full = url.host() ?? ""
        let host = full.hasPrefix("www.") ? String(full.dropFirst(4)) : full
        return host.caseInsensitiveCompare(name) == .orderedSame ? "" : host
    }

    /// Every bookmark, flat, with the address and title it is matched by.
    /// Worked out once a card, not on every keystroke and every answer that
    /// lands: bookmarks do not change while the card is up.
    private var shelved: [(title: String, lowered: String, url: URL, address: String)]?

    func shelf(_ browser: Browser) -> [(title: String, lowered: String, url: URL, address: String)] {
        if let shelved { return shelved }
        let flat = Launcher.bookmarks(browser.bookmarks.roots).map { title, url in
            (title: title, lowered: title.lowercased(), url: url, address: Launcher.strip(Address.pretty(url)))
        }
        shelved = flat
        return flat
    }

    private static func bookmarks(_ nodes: [Bookmark]) -> [(String, URL)] {
        nodes.flatMap { node -> [(String, URL)] in
            if let children = node.children { return bookmarks(children) }
            guard let url = node.url.flatMap(URL.init(string:)) else { return [] }
            return [(node.title, url)]
        }
    }

    /// The browser's commands, built once a card: building them checks
    /// files and walks the spaces, and none of it changes while the card is up.
    private var verbs: [CommandBar.Command]?

    func commands(_ browser: Browser) -> [CommandBar.Command] {
        if let verbs { return verbs }
        let list = CommandBar.commands(browser)
        verbs = list
        return list
    }

    // MARK: - bench

    /// `bench newtab TEXT`: the card as ⌘T would draw it for TEXT, by group,
    /// after the slow answers have had `settle` seconds to land. `go` takes
    /// the first row (or the row `pick` names) the way `how` says; `keep`
    /// leaves the card up for a picture.
    func bench(_ request: [String: Any], in browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        if request["type"] as? Bool == true { return typing(request, in: browser, answer: answer) }
        let started = DispatchTime.now().uptimeNanoseconds
        browser.launch()
        browser.typed = request["text"] as? String ?? ""
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        let settle = request["settle"] as? Double ?? 0.8
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [self] in
            // `--keys "⇥⇧⇥↓"`: pressed in the card's field once it has settled
            // (Fork/CardSections.press), the highlight after each reported.
            let openedOn = browser.picked ?? -1
            let pressed = (request["keys"] as? String).map { CardSections.press($0, in: browser) }
            var groups: [[String: Any]] = []
            var current: [String: Any] = ["heading": "", "rows": [[String: Any]]()]
            for (index, row) in browser.offers.enumerated() {
                if let heading = headings[index] {
                    if !((current["rows"] as? [Any])?.isEmpty ?? true) || !(current["heading"] as? String ?? "").isEmpty { groups.append(current) }
                    current = ["heading": heading, "rows": [[String: Any]]()]
                }
                var rows = current["rows"] as? [[String: Any]] ?? []
                rows.append(["index": index, "key": row.key, "kind": "\(row.kind)", "url": row.url.absoluteString,
                             "detail": row.detail, "badge": row.badge, "hint": row.hint,
                             "aside": Launcher.aside(for: row, in: browser), "tab": row.tab.map { String($0.uuidString.prefix(8)).lowercased() } ?? ""])
                current["rows"] = rows
            }
            if !((current["rows"] as? [Any])?.isEmpty ?? true) { groups.append(current) }
            var out: [String: Any] = ["groups": groups, "picked": browser.picked ?? -1, "milliseconds": milliseconds,
                                      "openedOn": openedOn, "keys": pressed?.steps ?? [], "keysVia": pressed?.via ?? "",
                                      "suggestAsks": sent, "suggestCancelled": dropped, "launching": browser.launching]
            let before = browser.tabs.count
            if request["go"] as? Bool == true {
                let how = How(rawValue: request["how"] as? String ?? "") ?? .open
                let index = request["pick"] as? Int ?? browser.picked ?? 0
                out["t0"] = (Date().timeIntervalSince1970 * 1000).rounded() // the load clock (perf/perf.py), as `open`'s
                if browser.offers.indices.contains(index) { take(browser.offers[index], in: browser, how: how) }
                out["tookIndex"] = index
            } else if request["keep"] as? Bool != true {
                browser.dismiss()
            }
            out["tabsBefore"] = before
            out["tabsAfter"] = browser.tabs.count
            out["active"] = browser.active.map { ["title": $0.label, "url": $0.address?.absoluteString ?? ""] } ?? [:]
            out["space"] = Spaces.shared.space.name
            answer(out)
        }
    }

    /// `bench newtab TEXT --type`: ⌘T (⌘K with `summon`, `bench bar TEXT --type`), then TEXT a letter at a time, `every`
    /// seconds apart, the way a person types it. What it reports is what
    /// "slow" means here: how long the main thread was too busy to draw —
    /// in all, and at worst in one go — and how long after the last letter
    /// the history rows for the whole word were on the card.
    private func typing(_ request: [String: Any], in browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        let text = request["text"] as? String ?? ""
        let every = request["every"] as? Double ?? 0.08
        let settle = request["settle"] as? Double ?? 3
        let meter = Meter()
        meter.start()
        let summon = request["summon"] as? Bool == true
        let opening = Launcher.clock { summon ? browser.summon() : browser.launch() }
        var keys: [Double] = []
        var lastKey: UInt64 = 0
        var landed: UInt64?
        var opened: [Double] = []

        func type(_ count: Int) {
            if count == 1 { opened = meter.take() }
            keys.append(Launcher.clock { browser.typed = String(text.prefix(count)) })
            lastKey = DispatchTime.now().uptimeNanoseconds
            if count >= text.count { return wait(lastKey + UInt64(settle * 1e9)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + every) { type(count + 1) }
        }
        // Until this word's history is on the card and another letter's
        // worth of time has passed, or `settle` runs out.
        func wait(_ deadline: UInt64) {
            let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
            let now = DispatchTime.now().uptimeNanoseconds
            if landed == nil, visited.query == needle { landed = now }
            guard landed == nil || now < lastKey + UInt64(every * 1e9), now < deadline else {
                let history = landed.map { Double($0 - lastKey) / 1e6 } ?? -1
                let stretches = meter.take()
                meter.stop()
                let rows = browser.offers.count
                browser.dismiss()
                answer(["typed": text, "every": every, "rows": rows,
                        "openMs": opening, "openBusyMs": opened.reduce(0, +), "openLongestMs": opened.max() ?? 0,
                        "keyMs": keys, "keyMaxMs": keys.max() ?? 0,
                        "busyMs": stretches.reduce(0, +), "longestMs": stretches.max() ?? 0,
                        "over16": stretches.filter { $0 > 16.7 }.count, "over50": stretches.filter { $0 > 50 }.count,
                        "historyMs": history, "suggestAsks": sent, "suggestCancelled": dropped])
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { wait(deadline) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { type(1) }
    }

    private static func clock(_ body: () -> Void) -> Double {
        let started = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
    }

    /// How long each turn of the main run loop kept it from sleeping — from
    /// waking for an event to waiting for the next. A turn longer than a
    /// frame is a frame the card did not draw.
    private final class Meter {
        private var observer: CFRunLoopObserver?
        private var woke: UInt64 = 0
        private var stretches: [Double] = []

        func start() {
            let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
            observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { [weak self] _, activity in
                guard let self else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                if activity == .afterWaiting { self.woke = now; return }
                if self.woke > 0 { self.stretches.append(Double(now - self.woke) / 1e6) }
                self.woke = 0
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }

        /// The stretches so far, and a clean slate.
        func take() -> [Double] {
            defer { stretches = [] }
            return stretches
        }

        func stop() {
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            observer = nil
        }
    }
}
