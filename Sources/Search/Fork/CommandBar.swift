import Foundation

// ⌘K, widened. Upstream's switcher lists the pages you have open; this adds
// the pages open in other spaces, your bookmarks, and the browser's own
// commands — all in the rows it already draws, matched by what you type.
// An empty field still shows only open pages, so ⌘K-Return stays what it was.
//
// A command travels as a URL, copper://command/<id>, because a Suggestion is
// a URL with a name; submit() hands those here instead of to a page.

enum CommandBar {
    /// How many rows the card will draw before it stops. Arc shows five or
    /// six; past eight the card is taller than it is wide and stops reading
    /// as one thing you glance at.
    static let limit = 8

    struct Command {
        let id: String
        let name: String
        /// The mark on the left of the row. A command has no site to borrow
        /// an icon from, so it says what it is with a glyph.
        let glyph: String
        let run: (Browser) -> Void

        init(id: String, name: String, glyph: String = "command", run: @escaping (Browser) -> Void) {
            self.id = id
            self.name = name
            self.glyph = glyph
            self.run = run
        }
    }

    @MainActor static func commands(_ browser: Browser) -> [Command] {
        var list: [Command] = [
            .init(id: "new-tab", name: "New Tab", glyph: "plus") { $0.newTab() },
            .init(id: "new-private", name: "New Private Tab", glyph: "eyeglasses") { $0.newShyTab() },
            .init(id: "new-canvas", name: "New Canvas", glyph: "scribble.variable") { CanvasTabs.newCanvas(in: $0) }, // Fork (canvas): a local one, in front
            .init(id: "share-canvas", name: "Share Canvas", glyph: "square.and.arrow.up") { browser in
                if let id = CanvasHost.active(in: browser) { CanvasUI.shared.openShare(id, in: browser) }
            },
            .init(id: "reopen", name: "Reopen Closed Tab", glyph: "arrow.uturn.backward") { $0.reopen() },
            .init(id: "close", name: "Close Tab", glyph: "xmark") { b in if let t = b.active { b.close(t) } },
            .init(id: "clear-tabs", name: "Clear Tabs", glyph: "arrow.down") { ClearTabs.shared.clear(in: $0) },
            .init(id: "pin", name: "Pin Tab", glyph: "pin") { b in if let t = b.active { b.pin(t) } },
            .init(id: "bookmark", name: "Bookmark This Page", glyph: "bookmark") { $0.bookmarkCurrent() },
            .init(id: "sidebar", name: "Toggle Sidebar", glyph: "sidebar.left") { $0.toggleSidebar() },
            .init(id: "hard-reload", name: "Hard Reload", glyph: "arrow.clockwise") { $0.hardReload() },
            .init(id: "reader", name: "Reading Mode", glyph: "doc.plaintext") { $0.toggleReader() },
            .init(id: "inspect", name: "Inspect Element", glyph: "ladybug") { $0.inspectElement() },
            .init(id: "float", name: "Float the Video", glyph: "pip") { $0.toggleFloat() },
            .init(id: "hide", name: "Hide Something on This Page", glyph: "eye.slash") { $0.toggleHiding() },
            .init(id: "history", name: "History", glyph: "clock.arrow.circlepath") { $0.recalling = true },
            .init(id: "downloads", name: "Downloads", glyph: "arrow.down.circle") { $0.hoarding = true },
            .init(id: "downloads-folder", name: "Open Downloads Folder", glyph: "folder") { $0.openDownloadsFolder() },
            .init(id: "passwords", name: "Passwords", glyph: "key") { $0.managing = true },
            .init(id: "passkeys", name: "Passkeys", glyph: "person.badge.key") { $0.tuning = true },
            .init(id: "settings", name: "Settings", glyph: "gearshape") { $0.tuning = true },
            .init(id: "cloud", name: "Copper Cloud…", glyph: "icloud") { $0.openSettings(.cloud) },
            .init(id: "flow", name: "Flow: move in from Chrome, Safari or Arc", glyph: "arrow.right.doc.on.clipboard") { Flow.shared.present(from: $0, via: .command) },
            .init(id: "history-import", name: "Bring in Arc History", glyph: "clock.arrow.circlepath") { browser in
                Store.settings.set(true, forKey: "history.nudged")
                Flow.shared.importHistory(preferred: "Arc", in: browser)
            },
            .init(id: "update-check", name: "Check for Copper updates", glyph: "arrow.triangle.2.circlepath") { _ in Updates.shared.check(force: true) },
            .init(id: "clear-history", name: "Clear History", glyph: "trash") { $0.clearHistory() },
            .init(id: "split", name: Split.shared.on ? "Close Split View" : "Split View", glyph: "rectangle.split.2x1") { Split.shared.toggle(in: $0) },
            .init(id: "agent", name: Agent.shared.open ? "Close Agent" : "Agent", glyph: "sparkles") { _ in Agent.shared.toggle() },
            .init(id: "jev-trace", name: "Driver Timeline", glyph: "waveform.path") { _ in Agent.shared.reveal() },
            .init(id: "close-panes", name: "Close All Panes", glyph: "xmark.square") { Panes.closeAll(in: $0) },
            .init(id: "ask-page", name: "Ask About This Page", glyph: "text.bubble") { Agent.shared.askOnPage(in: $0) },
            .init(id: "new-space", name: "New Space", glyph: "square.on.square") { b in
                let id = Spaces.shared.add(in: b)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { SpaceEditing.shared.open(id) }
            },
            .init(id: "edit-space", name: "Edit Space", glyph: "slider.horizontal.3") { b in SpaceEditing.shared.open(Spaces.shared.current(in: b)) },
            .init(id: "next-space", name: "Next Space", glyph: "chevron.right") { Spaces.shared.step(1, in: $0) },
            .init(id: "prev-space", name: "Previous Space", glyph: "chevron.left") { Spaces.shared.step(-1, in: $0) },
        ]
        // Fork (cloud): a one-time code for another Mac (Fork/Cloud/CloudPairing.swift).
        if Cloud.shared.isSignedIn {
            list.append(.init(id: "cloud-pair", name: "Pair another Mac with Copper Cloud", glyph: "laptopcomputer.and.arrow.down") { CloudPairing.shared.open(in: $0) })
        }
        if FileManager.default.fileExists(atPath: Store.file("session.previous.json").path) {
            list.append(.init(id: "session-restore", name: "Restore previous session", glyph: "arrow.counterclockwise") { $0.restorePreviousSession() })
        }
        // Offered once the release is downloaded and verified: the command
        // then only swaps the bundle in and relaunches.
        if Updates.shared.ready {
            list.insert(.init(id: "update", name: "Update Copper to \(Updates.shared.latest?.version ?? "")", glyph: "arrow.down.circle") { _ in Updates.shared.upgrade() }, at: 0)
        }
        AddonCommands.add(to: &list) // Fork (addons): Install <addon>, the check, Settings › Addons
        if Spaces.shared.all.count > 1 {
            list.append(.init(id: "delete-space", name: "Delete Space…", glyph: "trash") { b in SpaceDelete.ask(Spaces.shared.current(in: b), in: b) })
        }
        // Fork (canvas): signed in, a canvas to share — the door's New, at its name field.
        if Canvases.shared.cloudReady {
            list.append(.init(id: "canvas-new-shared", name: "New Shared Canvas…", glyph: "person.2") { CanvasUI.shared.newCanvas(in: $0) })
            // Each invite waiting for an answer: join it and open it (Fork/Canvas/CanvasInvites.swift).
            for invite in Canvases.shared.invites {
                list.append(.init(id: "canvas-join-\(invite.id)", name: "Join Canvas · \(invite.canvasName)", glyph: "person.crop.circle.badge.plus") { browser in
                    Task { await CanvasInvites.join(invite, in: browser) }
                })
            }
        }
        for space in Spaces.shared.all where space.id != Spaces.shared.current(in: browser) {
            // The space's own symbol when it has one; an emoji has no place
            // in a symbol slot, so those spaces keep the generic mark.
            list.append(.init(id: "space-\(space.id)", name: "Switch to \(space.title)", glyph: space.symbol ?? "circle.grid.2x2") {
                Spaces.shared.select(space.id, in: $0)
            })
        }
        return list
    }

    /// The rows for what was typed, in the card's sections (Fork/CardSections,
    /// the same order as ⌘T's): open pages first — this space's, then the
    /// ones parked in other spaces — then places you have been, bookmarks,
    /// canvases, the browser's own commands, and a search last, so ⌘K-Return
    /// is still "back to the page I was just on".
    ///
    /// An empty field is not empty: it is the pages you have open and a few
    /// things you might do, which is what a command bar is for.
    @MainActor static func offers(for typed: String, open: [Suggestion], in browser: Browser) -> [Suggestion] {
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return sectioned(dressed(open + resting(browser))) }
        let commandNeedle = needle.hasPrefix("/") ? String(needle.dropFirst()) : needle
        var ranked: [(row: Suggestion, score: Double)] = []

        func add(_ row: Suggestion, base: Double, against query: String = needle) {
            guard let match = matchScore(row, typed: query) else { return }
            ranked.append((row, base + match))
        }

        // Open pages are the strongest answer. The current space is already
        // sorted by recent use; kept pages in other spaces get a small lift so
        // a favourite or Saved row beats an otherwise identical parked page.
        let currentTabs = Dictionary(uniqueKeysWithValues: open.compactMap { row in
            row.tab.flatMap { id in browser.tabs.first(where: { $0.id == id }).map { (id, $0) } }
        })
        for var row in open.prefix(3) {
            if let tab = row.tab.flatMap({ currentTabs[$0] }) {
                decorate(&row, tab: tab, current: true)
                add(row, base: 1_000 + keptBoost(tab) + 20)
            } else {
                add(row, base: 1_000 + 20)
            }
        }

        let parked = Spaces.shared.parkedTabs
            .filter { !$0.isBlank && $0.address != nil }
            .sorted {
                let left = keptBoost($0)
                let right = keptBoost($1)
                return left == right ? $0.touched > $1.touched : left > right
            }
        var parkedCount = 0
        for tab in parked {
            guard parkedCount < 5, let url = tab.address else { continue }
            var row = Suggestion(
                key: tab.title.isEmpty ? Address.pretty(url) : tab.title,
                title: Address.pretty(url), url: url, kind: .open, tab: tab.id
            )
            decorate(&row, tab: tab, current: false)
            guard matchScore(row, typed: needle) != nil else { continue }
            add(row, base: 1_000 + keptBoost(tab))
            parkedCount += 1
        }

        var marks: [Suggestion] = []
        for (title, url) in bookmarks(browser.bookmarks.roots) {
            let row = Suggestion(key: title.isEmpty ? Address.pretty(url) : title,
                                 title: Address.pretty(url), url: url, kind: .bookmark)
            guard matchScore(row, typed: needle) != nil else { continue }
            marks.append(row)
            if marks.count == 3 { break }
        }
        marks.forEach { add($0, base: 700) }

        // Canvases, by name (Fork/Canvas), matched their own way: "canvas"
        // alone lists them, "canvas plan" narrows to names with "plan" in
        // them. Below bookmarks; a canvas already open is the open-page row
        // above and this one folds into it.
        for (index, row) in CanvasTabs.offers(for: typed).enumerated() {
            ranked.append((row, 650 - Double(index)))
        }

        // History has already combined match position, visit count and
        // recency; its four best rows, in that order, under the open pages.
        // Four, not six, now that the section sits above bookmarks: the
        // card's eight rows still have room for the shelves below it.
        let been = browser.history.suggestions(for: typed, limit: 4).map { row in
            Suggestion(key: row.title.isEmpty ? row.key : row.title,
                       title: row.key, url: row.url, kind: row.kind)
        }
        for (index, row) in been.enumerated() {
            add(row, base: 500 + Double(been.count - index))
        }

        var doing: [Suggestion] = []
        for command in commands(browser) where commandMatch(command.name, typed: commandNeedle) {
            var row = Suggestion(key: command.name, title: "",
                                 url: URL(string: "copper://command/\(command.id)")!, kind: .command)
            row.glyph = command.glyph
            doing.append(row)
            if doing.count == 2 { break }
        }
        doing.forEach { add($0, base: 200, against: commandNeedle) }

        var list: [Suggestion] = []
        var seen = Set<String>()
        // Section first, in the card's fixed order; the score orders the rows
        // within one. A page open and visited both is the open tab.
        let ordered = ranked.sorted { a, b in
            let (left, right) = (CardSection.of(a.row), CardSection.of(b.row))
            if left != right { return left < right }
            return a.score == b.score ? a.row.key < b.row.key : a.score > b.score
        }
        for candidate in ordered {
            let url = canonical(candidate.row.url)
            guard seen.insert(url).inserted else { continue }
            list.append(candidate.row)
            if list.count == limit - 1 { break }
        }
        // Search is deliberately last. A Google answer should not displace a
        // page Copper already knows, but it is always available as the exit.
        if let asked = Google.url(for: typed) {
            list.append(Suggestion(key: typed, title: Google.name, url: asked, kind: .search))
        }
        return sectioned(dressed(Array(list.prefix(limit))))
    }

    /// The rows cut into the card's sections, their headings handed to the
    /// card (Fork/CardSections) — which Tab and ⇧Tab jump between.
    @MainActor private static func sectioned(_ rows: [Suggestion]) -> [Suggestion] {
        let laid = CardSections.group(rows, by: CardSection.of)
        CardSections.shared.show(laid.headings)
        return laid.rows
    }

    @MainActor private static func keptBoost(_ tab: Tab) -> Double {
        (tab.pin != nil || Sections.shared.isSaved(tab)) ? 2 : 0
    }

    @MainActor private static func decorate(_ row: inout Suggestion, tab: Tab, current: Bool) {
        row.detail = shortDetail(row)
        let space = short(Spaces.shared.name(of: tab))
        if tab.pin != nil {
            // A pin is in every space, so naming one would be wrong.
            row.badge = "· ✦"
        } else if Sections.shared.isSaved(tab) {
            row.badge = current ? "· saved" : "· \(space) · saved"
        } else if !current {
            row.badge = "· \(space)"
        }
    }

    private static func canonical(_ url: URL) -> String {
        var text = Address.pretty(url).lowercased()
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// Match addresses by their whole prefix first, then by host labels. A
    /// host-segment match keeps `linear` useful for linear.app and `exo`
    /// useful for cloud-ems.dev.exowatt.com without making every path word a
    /// candidate.
    private static func matchScore(_ row: Suggestion, typed: String) -> Double? {
        let needle = strip(typed)
        guard !needle.isEmpty else { return nil }
        let address = strip(Address.pretty(row.url))
        let key = strip(row.key)
        let title = row.title.lowercased()
        if address.hasPrefix(needle) { return 100 }
        if key.hasPrefix(needle) { return 96 }
        let host = address.split(separator: "/").first.map(String.init) ?? address
        if host.split(separator: ".").contains(where: { $0.hasPrefix(needle) }) { return 82 }
        if title.hasPrefix(needle) { return 72 }
        if host.contains(needle) { return 62 }
        if key.contains(needle) || title.contains(needle) { return 45 }
        if address.contains(needle) { return 38 }
        return nil
    }

    private static func commandMatch(_ text: String, typed: String) -> Bool {
        let needle = strip(typed)
        guard !needle.isEmpty else { return false }
        return text.lowercased().contains(needle)
    }

    private static func strip(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces).lowercased()
        for scheme in ["https://", "http://"] where value.hasPrefix(scheme) {
            value = String(value.dropFirst(scheme.count))
        }
        if value.hasPrefix("www.") { value = String(value.dropFirst(4)) }
        return value
    }

    /// The empty field: what is open, and a few doors.
    @MainActor private static func resting(_ browser: Browser) -> [Suggestion] {
        let wanted = ["new-tab", "split", "new-space", "history"]
        let all = commands(browser)
        var rows = wanted.compactMap { id -> Suggestion? in
            guard let command = all.first(where: { $0.id == id }) else { return nil }
            var row = Suggestion(key: command.name, title: "", url: URL(string: "copper://command/\(command.id)")!, kind: .command)
            row.glyph = command.glyph
            return row
        }
        if browser.history.visitCount < 500,
           Flow.hasHistorySource(),
           !Store.settings.bool(forKey: "history.nudged"),
           let command = all.first(where: { $0.id == "history-import" }) {
            var nudge = Suggestion(
                key: "Bring in your Arc history so addresses complete →", title: "",
                url: URL(string: "copper://command/\(command.id)")!, kind: .command
            )
            nudge.glyph = command.glyph
            rows.insert(nudge, at: 0)
        }
        return rows
    }


    /// One row per URL, carrying what Return would do with it. A bookmark,
    /// page and history entry for the same address collapse to the strongest
    /// row before this point; different paths on one host remain useful rows.
    private static func dressed(_ list: [Suggestion]) -> [Suggestion] {
        var seen: Set<String> = []
        var out: [Suggestion] = []
        for row in list {
            guard seen.insert(canonical(row.url)).inserted else { continue }
            var row = row
            if row.detail.isEmpty { row.detail = shortDetail(row) }
            row.hint = hint(for: row)
            out.append(row)
            if out.count == limit { break }
        }
        return out
    }

    /// A space can be called anything, and a long name on the right of a row
    /// pushes the title out of its own row.
    private static func short(_ name: String) -> String {
        name.count <= 24 ? name : String(name.prefix(23)) + "…"
    }

    private static func hint(for row: Suggestion) -> String {
        if row.kind != .open, CanvasLinks.isCanvas(row.url) { return "Open" } // Fork (canvas): "Open Canvas · <name>"
        switch row.kind {
        case .open: return "Switch to Tab"
        case .command: return "Run"
        case .search: return "Search \(Google.name)"
        case .bookmark: return "Open Bookmark"
        default: return "Open"
        }
    }

    /// The quiet half of a row: the host, which is the part of an address
    /// anyone actually reads.
    private static func shortDetail(_ row: Suggestion) -> String {
        switch row.kind {
        case .command, .search: return ""
        case _ where CanvasLinks.isCanvas(row.url): return "Canvas" // Fork (canvas): not its address's "host"
        default:
            let full = row.url.host() ?? row.title
            let host = full.hasPrefix("www.") ? String(full.dropFirst(4)) : full
            // A row with no title of its own is already showing its host as
            // its name. Saying it twice is not saying it louder.
            guard host.caseInsensitiveCompare(row.key) != .orderedSame else { return "" }
            return short(host)
        }
    }

    private static func bookmarks(_ nodes: [Bookmark]) -> [(String, URL)] {
        nodes.flatMap { node -> [(String, URL)] in
            if let children = node.children { return bookmarks(children) }
            guard let url = node.url.flatMap(URL.init(string:)) else { return [] }
            return [(node.title, url)]
        }
    }

    /// True when the URL was a command and has been run.
    @MainActor static func run(_ url: URL, in browser: Browser) -> Bool {
        // copper://canvas/<id>: the canvas's tab, switched to or opened.
        if let id = CanvasLinks.id(from: url) {
            CanvasHost.show(id, in: browser)
            return true
        }
        guard url.scheme == "copper", url.host() == "command" else { return false }
        let id = url.lastPathComponent
        commands(browser).first { $0.id == id }?.run(browser)
        return true
    }
}

extension Spaces {
    func name(of tab: Tab) -> String {
        for space in all where row(space.id).contains(where: { $0.id == tab.id }) { return space.name }
        return space(in: Windows.current).name
    }

    /// Bring a tab open in another space to the front, switching to it.
    func reveal(_ id: Tab.ID, in browser: Browser) -> Bool {
        guard let space = all.first(where: { row($0.id).contains { $0.id == id } }) else { return false }
        select(space.id, in: browser)
        if let tab = browser.tabs.first(where: { $0.id == id }) { browser.select(tab) }
        return true
    }
}
