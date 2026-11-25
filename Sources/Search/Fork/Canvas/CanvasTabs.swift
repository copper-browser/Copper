import AppKit
import SwiftUI
import WebKit

// Canvas tabs: how a board is made, opened and kept, wherever Copper offers
// one. A canvas tab is an ordinary Tab at `copper://canvas/<id>` built from
// CanvasHost's configuration (the `canvas` handler is on it before the view
// exists). Everything else a tab does — the row, sleep and wake, session
// restore, split view, moving between spaces — it does as any tab, because
// it is one. What this file adds:
//
// - The ways in. ⌘K and ⌘T (New Canvas, Open Canvas · <name>), File › New
//   Canvas ⌃⇧E, the New Tab row's right-click, the foot plus's right-click,
//   a space's New Canvas in Space, and the Canvas door at the foot. Each new
//   one from these is a local canvas called "Untitled canvas" (the door's
//   New is the way to a shared one); every one of them ends in `show`.
// - One tab per board. `show` goes to the tab already holding a canvas — in
//   this row, another window, or a space no window is showing — before it
//   makes one; `already` (Browser.open) and `reroute` (Tab.go) send every
//   other way of opening one there too.
// - Its place. A canvas's tab, the first time it loads, joins its space's
//   Saved block at the bottom and is selected; Today's sweep passes over it
//   even if somebody drags it down into Today (Sections.sweep).
// - Its face. The row wears the Canvas mark (CanvasPage.icon) where a site
//   wears its icon, its title is the canvas's name (a sleeping or restored
//   row says the registry's name), and the address pill says "Canvas · <name>".
// - What it shows. A canvas tab shows its own board and nothing else: an
//   address typed into its field opens in a tab of its own beside it.

@MainActor
enum CanvasTabs {
    /// What a canvas made from ⌘K, the menus or the sidebar is called until
    /// somebody calls it something else.
    static let untitled = "Untitled canvas"

    // MARK: - which tab holds which board

    /// The canvas a tab holds, awake or asleep; the bench's own tabs don't count.
    static func showing(_ tab: Tab) -> String? {
        guard !tab.bench else { return nil }
        return (tab.pending ?? tab.address).flatMap(CanvasLinks.id(from:))
    }

    /// Every tab holding a canvas, in any window or space.
    static func tabs(showing id: String) -> [Tab] {
        var seen = Set<Tab.ID>()
        return (Windows.all.flatMap(\.tabs) + Spaces.shared.parkedTabs)
            .filter { seen.insert($0.id).inserted && showing($0) == id }
    }

    /// The tab a canvas is in, wherever it is.
    static func tab(showing id: String) -> Tab? { tabs(showing: id).first }

    /// The window a tab is in — the row that holds it, else whoever shows its space.
    static func owner(of tab: Tab) -> Browser {
        Windows.all.first { $0.tabs.contains { $0 === tab } } ?? Windows.owner(of: tab) ?? Windows.current
    }

    // MARK: - the ways in

    /// ⌘K's and ⌘T's New Canvas, File › New Canvas, the sidebar's menus: a
    /// local canvas, opened in front (a blank tab in front takes it, the way
    /// ⌘T reuses one) at the bottom of the space's Saved block.
    static func newCanvas(in browser: Browser) {
        let entry = Canvases.shared.createLocal(named: untitled)
        show(entry.id, in: browser)
    }

    /// A canvas, wherever it already is — this row, another window, a space
    /// no window is showing — or a tab of its own. Never a second tab.
    @discardableResult
    static func show(_ id: String, in browser: Browser, foreground: Bool = true, replacing given: Tab? = nil) -> Tab {
        if let tab = browser.tabs.first(where: { showing($0) == id }) {
            if foreground { browser.select(tab); browser.landed() }
            return tab
        }
        for other in Windows.all where other !== browser {
            guard let tab = other.tabs.first(where: { showing($0) == id }) else { continue }
            if foreground {
                other.select(tab)
                other.landed()
                Windows.window(of: other)?.makeKeyAndOrderFront(nil)
            }
            return tab
        }
        if let tab = Spaces.shared.parkedTabs.first(where: { showing($0) == id }) {
            if foreground {
                _ = Spaces.shared.reveal(tab.id, in: browser)
                browser.landed()
            }
            return tab
        }
        let url = CanvasLinks.url(id)
        let blank = given ?? (foreground ? browser.active.flatMap { $0.isBlank && !$0.floating ? $0 : nil } : nil)
        if let blank, browser.tabs.contains(where: { $0 === blank }) {
            browser.replaceBlank(blank, with: url)
            if foreground { browser.landed() }
            return browser.tabs.first { showing($0) == id } ?? blank
        }
        let tab = browser.open(url, foreground: foreground)
        if foreground { browser.landed() }
        return tab
    }

    /// `Browser.open`, before it makes a tab: a canvas that already has one is
    /// that tab, brought forward when the open was meant to be in front. Every
    /// way of opening an address by hand ends there (⌘T, a dropped link, ⌘D,
    /// an agent's new tab), so this is where a second tab for a board is
    /// refused. An easel's old address is its canvas's (CanvasImport).
    static func already(_ url: URL, in browser: Browser, foreground: Bool) -> Tab? {
        if CanvasImport.isLegacy(url) {
            guard let moved = CanvasImport.translate(url) else {
                browser.announce("That easel isn't in Canvas yet")
                return browser.active ?? browser.tabs.first
            }
            return show(CanvasLinks.id(from: moved) ?? Canvases.personalID, in: browser, foreground: foreground)
        }
        guard let id = CanvasLinks.id(from: url), tab(showing: id) != nil else { return nil }
        return show(id, in: browser, foreground: foreground)
    }

    /// `Tab.go(to:)`, before it loads anything. True when the address was
    /// taken somewhere else and the tab should do nothing more.
    static func reroute(_ tab: Tab, to given: URL) -> Bool {
        guard !tab.bench else { return false }
        let board = CanvasHost.isBoard(tab.web)
        var url = given
        if CanvasImport.isLegacy(given) {
            guard let moved = CanvasImport.translate(given) else {
                let owner = owner(of: tab)
                owner.announce("That easel isn't in Canvas yet")
                if tab.isBlank { DispatchQueue.main.async { if owner.tabs.count > 1, owner.tabs.contains(where: { $0 === tab }) { owner.close(tab) } } }
                return true
            }
            url = moved
        }
        guard let wanted = CanvasLinks.id(from: url) else {
            // A canvas tab only ever shows its board; a page typed into its
            // field gets a tab of its own beside it.
            guard board, showing(tab) != nil else { return false }
            owner(of: tab).open(url, foreground: true)
            return true
        }
        if board {
            let current = showing(tab)
            if current == nil || current == wanted {
                // Its own board, already up: a ⌘K row for the canvas in front
                // is not a reload.
                if current == wanted, CanvasHost.host(for: tab)?.canvasId == wanted, CanvasPage.isPage(tab.built?.url) { return true }
                if let other = self.tab(showing: wanted), other !== tab {
                    show(wanted, in: owner(of: tab))
                    return true
                }
                if url != given { tab.go(to: url); return true }
                keep(tab)
                return false
            }
        }
        show(wanted, in: owner(of: tab), replacing: tab.isBlank ? tab : nil)
        return true
    }

    /// A canvas's tab joining the sidebar for the first time: Saved, at the
    /// bottom of the block. Tabs the sections already know (restored, dragged
    /// into Today by hand) are left where they are.
    static func keep(_ tab: Tab) {
        guard tab.pin == nil, !tab.bench, !Sections.shared.knows(tab) else { return }
        let owner = owner(of: tab)
        guard owner.tabs.contains(where: { $0 === tab }) else { return }
        Sections.shared.set(tab, saved: true, in: owner)
    }

    // MARK: - its face

    /// The title a canvas's row comes back with: the registry's name, when it
    /// has the canvas — a rename made while the tab slept may not have
    /// reached the session file yet.
    static func rowTitle(for url: URL, kept: String) -> String {
        guard let id = CanvasLinks.id(from: url) else { return kept }
        if let entry = Canvases.shared.entry(id) { return CanvasLinks.title(entry.name) }
        return id == Canvases.personalID ? CanvasLinks.title("Personal") : kept
    }

    /// A canvas renamed (here, or by someone on the cloud): every row that
    /// holds it says so now. An awake page is told by CanvasHost.renamed; a
    /// sleeping row has nobody to tell it, so it is retitled here.
    static func retitle(_ id: String) {
        guard let entry = Canvases.shared.entry(id) else { return }
        for tab in tabs(showing: id) where tab.asleep {
            if let url = tab.pending { tab.restore(url: url, title: CanvasLinks.title(entry.name)) }
        }
    }

    /// Tab.adoptIcon's answer for a canvas: the Canvas mark, never a site's.
    static func mark(for url: URL?) -> NSImage? {
        CanvasLinks.isCanvas(url) ? CanvasPage.icon : nil
    }

    // MARK: - ⌘K and ⌘T

    /// Canvases whose names match what was typed, as rows that open them (or
    /// switch to the tab already holding one): three at most. "canvas" alone
    /// (or "canvases", or "canv…") lists them all, newest first; "canvas plan"
    /// narrows to names with "plan" in them.
    static func offers(for typed: String) -> [Suggestion] {
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        let word = needle.hasPrefix("canvases") ? "canvases" : needle.hasPrefix("canvas") ? "canvas" : nil
        let rest = word.map { String(needle.dropFirst($0.count)).trimmingCharacters(in: .whitespaces) } ?? needle
        let everything = (word != nil && rest.isEmpty) || (needle.count >= 4 && "canvases".hasPrefix(needle))
        func matches(_ name: String) -> Bool {
            let name = name.lowercased()
            if rest.count >= 3 { return name.contains(rest) }
            // One or two letters: the start of the name or of one of its words.
            return name.hasPrefix(rest) || name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix(rest) }
        }
        var rows: [Suggestion] = []
        for entry in Canvases.shared.visible.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            guard everything || matches(entry.name) else { continue }
            var row = Suggestion(key: "Open Canvas · \(entry.name)", title: "Canvas", url: CanvasLinks.url(entry.id), kind: .command)
            row.glyph = entry.isShared ? "person.2" : "scribble.variable"
            row.detail = entry.isShared ? "Shared" : entry.isPersonal ? "Private" : ""
            row.hint = "Open"
            rows.append(row)
            if !everything, rows.count == 3 { break }
        }
        return rows
    }

    // MARK: - leaving

    /// Quitting (`Windows.flush`, from applicationWillTerminate): every canvas
    /// page that is up writes its whole document as the snapshot, a second at
    /// most, then the logs are flushed. Every update is already on disk as it
    /// happens; this only makes the next open one read instead of a replay.
    static func flushAll() {
        let hosts = CanvasHost.all.filter(\.isReady)
        var left = hosts.count
        for host in hosts { Task { await host.checkpoint(within: 0.8); left -= 1 } }
        let deadline = Date().addingTimeInterval(1)
        while left > 0, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        CanvasStore.flushAll()
    }
}

// MARK: - the menus that make one

/// "New Tab" and "New Canvas": the New Tab row's right-click, Arc's new-item menu.
struct NewItemMenu: View {
    let browser: Browser

    var body: some View {
        Button("New Tab") { browser.launch() }
            .keyboardShortcut("t")
        Button("New Canvas") { CanvasTabs.newCanvas(in: browser) }
            .keyboardShortcut("e", modifiers: [.control, .shift])
        Divider()
        Button("New Live Folder: GitHub Pull Requests") { LiveFolders.addFromMenu(in: browser) } // Fork (ardia folders)
        Button("Add Shared Folder…") { AddSharedFolderSheet.show(browser: browser) }
    }
}
