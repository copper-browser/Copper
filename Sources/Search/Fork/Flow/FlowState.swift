import Foundation

// The Move-in sheet's decisions, kept apart from AppKit and SwiftUI so each
// one can be tested on its own (Tests/SearchTests/FlowStateTests.swift).
//
// The sheet used to cycle in front of people: it was presented once per
// window, torn down and presented again whenever the page area behind it
// was rebuilt, and every presentation (and every return to the app, which a
// keychain prompt causes once per item) re-listed the sources and could
// start another scan. These rules make each of those things happen once:
// the sheet is presented by one owner (`FlowPresenter`), the source list is
// read when the sheet opens and only re-checked while a source is locked, a
// selection is never switched under the person, and a stale scan never lands.

/// What a Move-in source is called and whether it can be read. The pure
/// rules below see only this much of a `FlowSource`.
struct FlowCandidate: Equatable {
    var id: String
    var readable: Bool
    /// macOS keeps its own files closed, even if something else (Safari's
    /// export) makes it readable: still worth a look on coming back.
    var locked = false
}

enum FlowMachine {
    /// What the sheet should select, and what (if anything) it should read,
    /// after the list of sources was refreshed.
    struct Decision: Equatable {
        var selected: String?
        var scan: String?
        /// The preview on screen belongs to a source that can't be read any
        /// more (or is gone): back to the picker.
        var resetPreview = false
    }

    /// - Parameters:
    ///   - sources: the sources in the picker, in order.
    ///   - selected: the source selected before the refresh.
    ///   - previewed: the source whose counts are on screen (or being read).
    ///   - busy: a move is running — nothing changes under it.
    static func reconcile(sources: [FlowCandidate], selected: String?, previewed: String?, busy: Bool) -> Decision {
        if busy { return Decision(selected: selected, scan: nil) }
        let readable = sources.filter(\.readable)
        if let selected, readable.contains(where: { $0.id == selected }) {
            // Keep it. Read it only if what is on screen is someone else's.
            return Decision(selected: selected, scan: previewed == selected ? nil : selected)
        }
        // Nothing selected, or the selection went away / got locked. Pick
        // the only readable source; with two or more, the person chooses.
        let reset = previewed != nil && !readable.contains(where: { $0.id == previewed })
        if readable.count == 1, let only = readable.first {
            return Decision(selected: only.id, scan: previewed == only.id ? nil : only.id, resetPreview: reset)
        }
        return Decision(selected: nil, scan: nil, resetPreview: reset || (selected != nil && previewed != nil))
    }

    /// Whether a refresh that produced `new` changes anything the sheet draws.
    /// Equal lists are not republished, so an app activation that finds the
    /// same browsers does not redraw the sheet.
    static func changed(_ old: [FlowCandidate], _ new: [FlowCandidate]) -> Bool { old != new }

    /// Whether a source list needs re-checking when Copper becomes active
    /// again — only while the sheet is up and something is locked: the one
    /// thing the person may have just changed in System Settings.
    static func recheckOnActivation(sources: [FlowCandidate], open: Bool) -> Bool {
        open && sources.contains { !$0.readable || $0.locked }
    }
}

/// A scan ticket. A scan's result lands only if it is the newest ticket and
/// still for the selected source; a slower earlier read never overwrites a
/// later one, and a read for a source the person has left is dropped.
struct FlowScanTicket: Equatable {
    private(set) var generation = 0
    private(set) var source: String?

    mutating func issue(for source: String) -> Int {
        generation += 1
        self.source = source
        return generation
    }

    mutating func cancel() {
        generation += 1
        source = nil
    }

    func accepts(_ ticket: Int, for source: String, selected: String?) -> Bool {
        ticket == generation && self.source == source && selected == source
    }
}

/// The record of what the sheet did, for `bench flow events` and the
/// regression check: every open and close asked for, every present and
/// dismiss of the sheet, every refresh, scan and phase. Kept in memory, at
/// most `limit` entries.
struct FlowEvents {
    struct Entry: Equatable {
        var at: Double   // seconds of system uptime
        var kind: String
        var detail: String
    }

    static let limit = 400
    private(set) var entries: [Entry] = []

    mutating func record(_ kind: String, _ detail: String = "", at: Double) {
        entries.append(Entry(at: at, kind: kind, detail: detail))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    mutating func clear() { entries.removeAll() }

    func count(_ kind: String) -> Int { entries.filter { $0.kind == kind }.count }

    /// Presents minus dismisses never goes above one: one sheet at a time.
    var overlapping: Bool {
        var shown = 0
        for entry in entries {
            if entry.kind == "present" { shown += 1 }
            if entry.kind == "dismiss" { shown -= 1 }
            if shown > 1 { return true }
        }
        return false
    }

    /// The most scans started between one open and the next. A sheet that
    /// re-reads a browser behind the person's back shows up here.
    var scansPerOpen: Int {
        var most = 0
        var current = 0
        for entry in entries {
            if entry.kind == "open" { current = 0 }
            if entry.kind == "scan" { current += 1; most = max(most, current) }
        }
        return most
    }
}

// MARK: - moving in again

/// How a move's spaces land in Copper, decided before anything is built so
/// it can be tested on its own.
///
/// Moving in a second time used to make every space again ("Work (Arc)",
/// "Chrome (Chrome)") with every tab in it twice, and a Chrome window
/// holding only new-tab pages became an empty space. Now each source keeps
/// a registry (`flow.spaces.<source>`): the key a space is known by in that
/// browser → the Copper space it became. A space that is still there is
/// filled with the tabs it doesn't have yet; one the person deleted is made
/// again; a space with nothing to open is never made.
enum FlowAdopt {
    /// Each source's registry, kept in the world's settings.
    static func registry(for source: String) -> [String: UUID] {
        let stored = Store.settings.dictionary(forKey: "flow.spaces.\(source.lowercased())") as? [String: String] ?? [:]
        return stored.compactMapValues(UUID.init(uuidString:))
    }

    static func keep(_ registry: [String: UUID], for source: String) {
        Store.settings.set(registry.mapValues(\.uuidString), forKey: "flow.spaces.\(source.lowercased())")
    }

    /// The addresses each of a source's spaces brought, move after move
    /// ("#pins" for its pins). A page that redirected once it was opened, or
    /// that the person closed, was still brought: the next move doesn't
    /// bring it again. Only what is new in the other browser comes.
    static func brought(for source: String) -> [String: Set<String>] {
        let stored = Store.settings.dictionary(forKey: "flow.brought.\(source.lowercased())") as? [String: [String]] ?? [:]
        return stored.mapValues(Set.init)
    }

    static func keep(brought: [String: Set<String>], for source: String) {
        Store.settings.set(brought.mapValues { $0.sorted() }, forKey: "flow.brought.\(source.lowercased())")
    }

    static let pinsKey = "#pins"

    /// The record after a move: what it brought added to each space's —
    /// except a space it made afresh (the person had deleted the old one),
    /// whose record starts again.
    static func merged(_ old: [String: Set<String>], _ run: FlowAdoption) -> [String: Set<String>] {
        var out = old
        for key in run.fresh { out[key] = [] }
        for (key, addresses) in run.brought { out[key, default: []].formUnion(addresses) }
        return out.filter { !$0.value.isEmpty }
    }

    /// The record after Undo: what that move brought taken out again.
    static func without(_ old: [String: Set<String>], _ run: FlowAdoption) -> [String: Set<String>] {
        var out = old
        for (key, addresses) in run.brought { out[key]?.subtract(addresses) }
        return out.filter { !$0.value.isEmpty }
    }

    /// A Copper space as the planner sees it.
    struct Existing: Equatable {
        var id: UUID
        var name: String
        /// `address(_:)` of every loose tab in its row.
        var addresses: Set<String>
    }

    enum Target: Equatable {
        /// Add to this space, which an earlier move made.
        case fill(UUID)
        /// Make a space with this (already unique) name.
        case make(String)
        /// Nothing to open in it: no space (its pins, if any, still come).
        case none
    }

    struct Step: Equatable {
        /// Index into the imported spaces.
        var index: Int
        var key: String
        var target: Target
        /// Indices of the incoming space's loose tabs to add.
        var loose: [Int]
        /// Indices of its pinned tabs to add to the pins.
        var pins: [Int]
        /// Tabs left out because Copper already has them.
        var skipped: Int
    }

    /// The key each imported space is known by: its name as the browser's
    /// files give it, numbered when the same name comes twice in one read.
    static func keys(_ spaces: [FlowModel.Space], source: String) -> [String] {
        var count: [String: Int] = [:]
        return spaces.map { space in
            var base = space.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if base.isEmpty { base = source.lowercased() }
            count[base, default: 0] += 1
            let n = count[base]!
            return n == 1 ? base : "\(base)#\(n)"
        }
    }

    /// What makes two tabs the same page here: the address without its
    /// fragment or a trailing slash, scheme and host in lower case.
    static func address(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.fragment = nil
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        var text = parts.string ?? url.absoluteString
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// A name no other space has: the browser's own, or — when Copper has
    /// one by that name — "Name (Source)", then "Name (Source) 2", ….
    static func name(_ wanted: String, source: String, taken: Set<String>) -> String {
        var base = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = source }
        guard taken.contains(base.lowercased()) else { return base }
        let suffixed = "\(base) (\(source))"
        var name = suffixed
        var n = 2
        while taken.contains(name.lowercased()) {
            name = "\(suffixed) \(n)"
            n += 1
        }
        return name
    }

    /// When an imported tab counts as last seen. The browser's own date can
    /// be weeks old, and Today closes what nobody has looked at in a day —
    /// so a fresh import would be swept away the first time its space was
    /// shown. It counts as seen when it was moved in.
    static func seen(_ original: Double?, movedAt: Date) -> Double {
        max(original ?? 0, movedAt.timeIntervalSince1970)
    }

    static func plan(
        _ imported: [FlowModel.Space], source: String, registry: [String: UUID],
        existing: [Existing], pinned: Set<String>, brought: [String: Set<String>] = [:]
    ) -> [Step] {
        let keys = keys(imported, source: source)
        var taken = Set(existing.map { $0.name.lowercased() })
        let pinnedBefore = pinned.union(brought[pinsKey] ?? [])
        // Pins are Copper-wide, and Arc gives every space the same
        // favourites: a pin is added or counted as already here once per
        // move, never once per space it came with.
        var seenPins = Set<String>()
        var steps: [Step] = []
        for (index, space) in imported.enumerated() {
            var skipped = 0
            var pins: [Int] = []
            var loose: [Int] = []
            for (i, tab) in space.tabs.enumerated() where tab.pinned {
                let key = address(tab.url)
                guard seenPins.insert(key).inserted else { continue }
                if pinnedBefore.contains(key) { skipped += 1 } else { pins.append(i) }
            }
            let target: Target
            if let id = registry[keys[index]], let there = existing.first(where: { $0.id == id }) {
                target = .fill(id)
                var have = there.addresses.union(brought[keys[index]] ?? [])
                for (i, tab) in space.tabs.enumerated() where !tab.pinned {
                    if have.insert(address(tab.url)).inserted { loose.append(i) } else { skipped += 1 }
                }
            } else {
                loose = space.tabs.indices.filter { !space.tabs[$0].pinned }
                if loose.isEmpty {
                    target = .none
                } else {
                    let name = name(space.name, source: source, taken: taken)
                    taken.insert(name.lowercased())
                    target = .make(name)
                }
            }
            steps.append(Step(index: index, key: keys[index], target: target, loose: loose, pins: pins, skipped: skipped))
        }
        return steps
    }
}

/// What one move did to the spaces: enough to report it and to undo it.
struct FlowAdoption: Equatable {
    /// Spaces made by this move.
    var made: [UUID] = []
    /// Spaces an earlier move made that this one added tabs to.
    var filled: [UUID] = []
    /// Tabs added, pins included.
    var tabs = 0
    var pins = 0
    /// Tabs left out because Copper already had them.
    var skipped = 0
    /// Spaces not made: nothing of their own to open (an Arc space of only
    /// favourites, say).
    var leftOut = 0
    var groups = 0
    /// The source's registry after this move.
    var registry: [String: UUID] = [:]
    /// What this move brought, by space key (`FlowAdopt.pinsKey` for pins).
    var brought: [String: Set<String>] = [:]
    /// Keys of spaces this move made (anew, or again after a delete).
    var fresh: Set<String> = []
    /// The first space the move landed in (made or filled).
    var landing: UUID?
    /// Loose tabs added to spaces that were already there.
    var addedTabs: [UUID] = []
    var addedPins: [UUID] = []
    var madeGroups: [UUID] = []
}

// MARK: - what the summary says

/// One line per thing the person chose: what arrived, or why it didn't.
/// The old summary was one string of counts ("0 tabs in 1 spaces · 0
/// bookmarks · …") that never said why a zero was a zero.
enum FlowSummary {
    enum Category: String, CaseIterable {
        case tabs, bookmarks, history, passwords, passkeys, cookies, localStorage, extensions

        /// What the sheet calls it, in its rows, while moving and in the
        /// summary.
        var title: String {
            switch self {
            case .tabs: return "Tabs"
            case .bookmarks: return "Bookmarks"
            case .history: return "History"
            case .passwords: return "Passwords"
            case .passkeys: return "Passkeys"
            case .cookies: return "Sign-ins"
            case .localStorage: return "Site data"
            case .extensions: return "Extensions"
            }
        }
    }

    struct Line: Equatable {
        var category: Category
        /// Something arrived.
        var ok: Bool
        var text: String

        /// As the bench prints it.
        var plain: String { (ok ? "✓ " : "— ") + text }

        /// The text after the category's own name ("2 tabs in 1 space"),
        /// for a row that shows the name in a column of its own.
        var detail: String {
            let prefix = category.title + ": "
            return text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
        }
    }

    /// What one move came to, category by category. Nil counts mean the
    /// category was not chosen.
    struct Facts: Equatable {
        var source: String
        // Tabs
        var tabsChosen = false
        var tabsAdded = 0
        var tabsSkipped = 0
        var pinsAdded = 0
        var spacesMade = 0
        var spacesFilled = 0
        /// Windows/spaces the browser had, and how many held no page Copper opens.
        var windowsRead = 0
        var windowsEmpty = 0
        /// The browser groups tabs in spaces (Arc), not windows.
        var windowsAreSpaces = false
        var tabsWhy: String?
        // Bookmarks
        var bookmarksChosen = false
        var bookmarksRead = 0
        var bookmarksNew = 0
        /// Of `bookmarksRead`, how many came from Safari's Reading List.
        var readingListRead = 0
        var bookmarksWhy: String?
        // History
        var historyChosen = false
        var placesRead = 0
        var placesNew = 0
        // Secrets: nil found = not read (then `why` says why)
        var passwordsChosen = false
        var passwordsFound: Int?
        var passwordsKept = 0
        var passwordsNew: Int?
        var passwordsWhy: String?
        var passkeysChosen = false
        var passkeysFound: Int?
        var passkeysNew = 0
        var passkeysWhy: String?
        var cookiesChosen = false
        var cookiesFound: Int?
        var cookiesSet = 0
        /// Set cookies the store didn't already have with that value.
        var cookiesNew = 0
        var cookieSites = 0
        var cookiesWhy: String?
        // Local storage
        var storageChosen = false
        var storageSites = 0
        var storageWhy: String?
        // Extensions
        var extensionsChosen = false
        var extensionsFound = 0
        var extensionsQueued = 0
        var extensionsWhy: String?
    }

    static func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n.formatted()) \(n == 1 ? one : (many ?? one + "s"))"
    }

    /// "the one", "both", "all 12".
    static func every(_ n: Int) -> String {
        n == 1 ? "the one" : n == 2 ? "both" : "all \(n.formatted())"
    }

    static func lines(_ f: Facts) -> [Line] {
        var out: [Line] = []
        let s = f.source
        if f.tabsChosen {
            let spaces = f.spacesMade + f.spacesFilled
            if f.tabsAdded > 0 {
                var text = "Tabs: \(plural(f.tabsAdded, "tab")) in \(plural(max(spaces, 1), "space"))"
                if f.pinsAdded > 0 { text = "Tabs: \(plural(f.tabsAdded, "tab")) (\(f.pinsAdded.formatted()) pinned)" + (spaces > 0 ? " in \(plural(spaces, "space"))" : "") }
                // An empty window or space makes no space in Copper; say so,
                // so a space that didn't come over isn't a mystery.
                var also: [String] = []
                if f.tabsSkipped > 0 { also.append("\(f.tabsSkipped.formatted()) already here") }
                if f.windowsEmpty > 0 {
                    also.append(f.windowsAreSpaces
                        ? "\(plural(f.windowsEmpty, "empty space")) left out"
                        : "\(plural(f.windowsEmpty, "window")) of only new-tab pages left out")
                }
                if !also.isEmpty { text += " — " + also.joined(separator: ", ") }
                out.append(Line(category: .tabs, ok: true, text: text))
            } else if f.tabsSkipped > 0 {
                out.append(Line(category: .tabs, ok: false, text: "Tabs: nothing new — \(f.tabsSkipped == 1 ? "the one tab was" : "\(every(f.tabsSkipped)) were") already here"))
            } else if let why = f.tabsWhy {
                out.append(Line(category: .tabs, ok: false, text: "Tabs: \(why)"))
            } else if f.windowsRead > 0, f.windowsEmpty == f.windowsRead {
                let which = f.windowsRead == 1 ? "\(s)'s last window" : "\(s)'s open windows"
                out.append(Line(category: .tabs, ok: false, text: "Tabs: \(which) had only new-tab pages"))
            } else {
                out.append(Line(category: .tabs, ok: false, text: "Tabs: \(s) had no open windows"))
            }
        }
        if f.bookmarksChosen {
            if let why = f.bookmarksWhy {
                out.append(Line(category: .bookmarks, ok: false, text: "Bookmarks: \(why)"))
            } else if f.bookmarksRead == 0 {
                out.append(Line(category: .bookmarks, ok: false, text: "Bookmarks: \(s) has none"))
            } else if f.bookmarksNew == 0 {
                out.append(Line(category: .bookmarks, ok: false, text: "Bookmarks: nothing new — \(every(f.bookmarksRead)) from \(s) \(f.bookmarksRead == 1 ? "was" : "were") already here"))
            } else {
                var text = "Bookmarks: \(plural(f.bookmarksRead, "bookmark"))"
                if f.readingListRead > 0 { text += " (\(f.readingListRead.formatted()) from the Reading List)" }
                if f.bookmarksNew < f.bookmarksRead { text += ", \(f.bookmarksNew.formatted()) new" }
                out.append(Line(category: .bookmarks, ok: true, text: text))
            }
        }
        if f.historyChosen {
            if f.placesRead == 0 {
                out.append(Line(category: .history, ok: false, text: "History: \(s) has none"))
            } else if f.placesNew == 0 {
                out.append(Line(category: .history, ok: false, text: "History: nothing new — \(plural(f.placesRead, "place")) already here"))
            } else {
                // Copper keeps one entry per page, so `placesNew` (entries
                // added) can be fewer than the rows read even on a first
                // move; it only tells "something" from "nothing".
                out.append(Line(category: .history, ok: true, text: "History: \(plural(f.placesRead, "place"))"))
            }
        }
        if f.passwordsChosen {
            if let why = f.passwordsWhy {
                out.append(Line(category: .passwords, ok: false, text: "Passwords: \(why)"))
            } else if (f.passwordsFound ?? 0) == 0 {
                out.append(Line(category: .passwords, ok: false, text: "Passwords: \(s) has none saved"))
            } else if f.passwordsKept == 0 {
                out.append(Line(category: .passwords, ok: false, text: "Passwords: none of \(f.passwordsFound ?? 0) could be kept in Copper"))
            } else if let new = f.passwordsNew, new == 0 {
                out.append(Line(category: .passwords, ok: false, text: "Passwords: nothing new — \(plural(f.passwordsKept, "password")) already here"))
            } else if let new = f.passwordsNew, new < f.passwordsKept {
                out.append(Line(category: .passwords, ok: true, text: "Passwords: \(plural(f.passwordsKept, "password")), \(new.formatted()) new"))
            } else {
                out.append(Line(category: .passwords, ok: true, text: "Passwords: \(plural(f.passwordsKept, "password"))"))
            }
        }
        if f.passkeysChosen {
            if let why = f.passkeysWhy {
                out.append(Line(category: .passkeys, ok: false, text: "Passkeys: \(why)"))
            } else if (f.passkeysFound ?? 0) == 0 {
                out.append(Line(category: .passkeys, ok: false, text: "Passkeys: \(s) has none"))
            } else if f.passkeysNew == 0 {
                out.append(Line(category: .passkeys, ok: false, text: "Passkeys: nothing new — \(plural(f.passkeysFound ?? 0, "passkey")) already here"))
            } else {
                out.append(Line(category: .passkeys, ok: true, text: "Passkeys: \(plural(f.passkeysNew, "passkey"))"))
            }
        }
        if f.cookiesChosen {
            if let why = f.cookiesWhy {
                out.append(Line(category: .cookies, ok: false, text: "Sign-ins: \(why)"))
            } else if (f.cookiesFound ?? 0) == 0 {
                out.append(Line(category: .cookies, ok: false, text: "Sign-ins: \(s) has none"))
            } else if f.cookiesSet > 0, f.cookiesNew == 0 {
                out.append(Line(category: .cookies, ok: false, text: "Sign-ins: nothing new — already signed in to \(plural(f.cookieSites, "site"))"))
            } else {
                out.append(Line(category: .cookies, ok: f.cookiesSet > 0, text: "Sign-ins: \(plural(f.cookieSites, "site")) (\(plural(f.cookiesSet, "cookie")))"))
            }
        }
        if f.storageChosen {
            if let why = f.storageWhy {
                out.append(Line(category: .localStorage, ok: false, text: "Site data: \(why)"))
            } else if f.storageSites == 0 {
                out.append(Line(category: .localStorage, ok: false, text: "Site data: \(s) has none"))
            } else {
                out.append(Line(category: .localStorage, ok: true, text: "Site data: \(plural(f.storageSites, "site"))"))
            }
        }
        if f.extensionsChosen {
            if let why = f.extensionsWhy {
                out.append(Line(category: .extensions, ok: false, text: "Extensions: \(why)"))
            } else if f.extensionsFound == 0 {
                out.append(Line(category: .extensions, ok: false, text: "Extensions: none from the Chrome Web Store"))
            } else if f.extensionsQueued == 0 {
                out.append(Line(category: .extensions, ok: false, text: "Extensions: none could be installed"))
            } else {
                out.append(Line(category: .extensions, ok: true, text: "Extensions: \(plural(f.extensionsQueued, "extension")) installing from the Chrome Web Store"))
            }
        }
        return out
    }

    /// The heading over the lines.
    static func title(_ lines: [Line], source: String) -> String {
        if lines.contains(where: \.ok) { return "Moved in from \(source)" }
        if lines.contains(where: { $0.text.contains("nothing new") }) { return "Nothing new from \(source)" }
        return "Nothing came over from \(source)"
    }
}

// MARK: - while it moves

/// One row of the moving view, per chosen category, made when the move
/// starts and changed in place as it goes: waiting, working, then what it
/// came to. Nothing is added below, so nothing grows or pushes the footer.
struct FlowStep: Equatable {
    enum State: Equatable {
        case waiting, working
        /// Done, and something came (✓) or nothing did, with why (—).
        case arrived, missed
    }
    var category: FlowSummary.Category
    var state: State = .waiting
    /// What it is doing, or what it came to.
    var text = ""

    /// The rows for a move, in the summary's order.
    static func steps(for choice: FlowModel.Choice) -> [FlowStep] {
        var chosen: [FlowSummary.Category] = []
        if choice.tabs { chosen.append(.tabs) }
        if choice.bookmarks { chosen.append(.bookmarks) }
        if choice.history { chosen.append(.history) }
        if choice.passwords { chosen.append(.passwords) }
        if choice.passkeys { chosen.append(.passkeys) }
        if choice.cookies { chosen.append(.cookies) }
        if choice.localStorage { chosen.append(.localStorage) }
        if choice.extensions { chosen.append(.extensions) }
        return chosen.map { FlowStep(category: $0) }
    }

    /// `steps` with one category's row changed; a category that wasn't
    /// chosen changes nothing.
    static func set(_ category: FlowSummary.Category, _ state: State, _ text: String, in steps: [FlowStep]) -> [FlowStep] {
        steps.map { step in
            guard step.category == category else { return step }
            return FlowStep(category: category, state: state, text: text)
        }
    }

    /// A category's row once it is done: the summary's own line for it, so
    /// the moving view ends on exactly what the summary will say.
    static func finished(_ category: FlowSummary.Category, _ facts: FlowSummary.Facts, in steps: [FlowStep]) -> [FlowStep] {
        guard let line = FlowSummary.lines(facts).first(where: { $0.category == category }) else { return steps }
        return set(category, line.ok ? .arrived : .missed, line.detail, in: steps)
    }

    /// As the bench prints a row that has started.
    var line: String { "\(category.title): \(text)" }
}
