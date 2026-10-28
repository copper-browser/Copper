import Foundation

/// `./bench sections check`: closing against removing a Saved row, end to
/// end on the real objects — `Browser.close` (⌘W's path), the row's cross
/// (`Sections.remove`), Reopen Closed Tab, the session file's shape and the
/// Copper Cloud "Spaces and kept tabs" document and merge. Test worlds only;
/// it adds two rows of its own and takes them away again.
@MainActor
enum SavedChecks {
    static func run(in browser: Browser) -> [String] {
        guard Store.testing else { return ["only in a probe world"] }
        var failures: [String] = []
        let sections = Sections.shared
        let groups = Groups.shared
        func fail(_ what: String) { failures.append(what) }
        func index(_ tab: Tab) -> Int? { browser.tabs.firstIndex { $0.id == tab.id } }
        func keyed(_ doc: CloudDocs.Spaces, _ url: String) -> String? { doc.tabs.first { $0.url == url }?.key }

        let urlA = "https://example.com/?saved-close-check"
        let urlB = "https://example.org/?saved-remove-check"
        func make(_ url: String) -> Tab {
            let tab = Tab()
            browser.prepare(tab)
            tab.restore(url: URL(string: url)!, title: url)
            sections.restore(tab, saved: true, seen: nil)
            return tab
        }
        let a = make(urlA)
        let b = make(urlB)
        let folder = groups.create(named: "Saved check", hue: nil)
        groups.restore(b, group: folder.id)
        let end = browser.pinnedCount + browser.tabs.filter { $0.pin == nil && sections.isSaved($0) }.count
        var row = browser.tabs
        row.insert(contentsOf: [a, b], at: end)
        browser.tabs = row
        let was = browser.activeID
        browser.select(a)
        let base = CloudApply.spaces(browser, base: nil)
        guard let keyA = keyed(base, urlA), let keyB = keyed(base, urlB) else {
            return ["the cloud document did not list the two new Saved rows"]
        }

        // ⌘W on a Saved row: put down, not closed.
        let placeA = index(a)
        let titleA = a.title
        let addressA = a.address
        let ghostsBefore = browser.ghosts.map(\.id)
        browser.close(a)
        if browser.ghosts.map(\.id) != ghostsBefore { fail("⌘W on a Saved row made a Reopen Closed Tab entry") }
        if index(a) == nil { fail("⌘W took the Saved row out of the row") }
        if index(a) != placeA { fail("⌘W moved the Saved row") }
        if !sections.isSaved(a) { fail("⌘W unsaved the row") }
        if !a.asleep || a.built != nil { fail("⌘W left the Saved row's page loaded") }
        if browser.activeID == a.id { fail("⌘W left the selection on the Saved row") }
        if a.title != titleA || a.pending == nil || a.pending != addressA { fail("⌘W lost the row's title or address") }
        let shape = Spaces.shared.shape(visible: browser.tabs, active: browser.activeID)
        let entry = shape.tabs.first { $0.url == urlA }
        if entry == nil { fail("the session file lost the put-down Saved row") }
        if entry?.saved != true { fail("the session file wrote the put-down row as not saved") }
        let afterClose = CloudApply.spaces(browser, base: base)
        if keyed(afterClose, urlA) != keyA { fail("the cloud document dropped the put-down kept tab") }
        let merged = CloudMerge.spaces(base: base, local: afterClose, server: base)
        if !merged.tabs.contains(where: { $0.key == keyA }) { fail("the merge deleted the put-down kept tab") }

        // Clicking it again brings the page back.
        browser.select(a)
        if a.asleep { fail("selecting the put-down row did not wake it") }

        // ⌘W again lands somewhere else, and not on a row put down earlier.
        browser.close(a)

        // The cross on a Saved row: out of Saved, closed, and back with Reopen.
        browser.select(b)
        let placeB = index(b)
        let ghosts = Set(browser.ghosts.map(\.id))
        sections.remove(b, in: browser)
        if index(b) != nil { fail("the cross left the Saved row in the row") }
        // The list keeps the newest twelve: a new entry, not a longer list.
        if browser.ghosts.last.map({ ghosts.contains($0.id) }) != false { fail("the cross left nothing in Reopen Closed Tab") }
        let afterRemove = CloudApply.spaces(browser, base: base)
        if keyed(afterRemove, urlB) != nil { fail("the cloud document still lists the removed kept tab") }
        if keyed(afterRemove, urlA) != keyA { fail("removing one kept tab dropped another") }
        let mergedRemove = CloudMerge.spaces(base: base, local: afterRemove, server: base)
        if mergedRemove.tabs.contains(where: { $0.key == keyB }) { fail("the merge kept the removed kept tab") }
        if !mergedRemove.tabs.contains(where: { $0.key == keyA }) { fail("the merge lost the put-down kept tab") }

        browser.reopen()
        let back = browser.tabs.first { ($0.pending ?? $0.address)?.absoluteString == urlB }
        if let back {
            if !sections.isSaved(back) { fail("Reopen Closed Tab brought the removed row back into Today") }
            if index(back) != placeB { fail("Reopen Closed Tab put the row somewhere else (\(index(back) ?? -1), was \(placeB ?? -1))") }
            if groups.membership[back.id] != folder.id { fail("Reopen Closed Tab left the row out of its folder") }
        } else {
            fail("Reopen Closed Tab did not bring the removed row back")
        }

        // Tidy up: both rows out for good, the folder gone, the selection back.
        for tab in [a, back].compactMap({ $0 }) where index(tab) != nil { sections.closeForGood(tab, in: browser) }
        groups.dissolve(folder.id)
        if let was, let tab = browser.tabs.first(where: { $0.id == was }) { browser.select(tab) }
        return failures + pinChecks(in: browser)
    }

    /// A pin another Mac sends is a pin here — in the pins, written to the
    /// session's pins (the only ones a launch restores) — and a second copy
    /// of a pinned site, however it got in, folds away on the next sync.
    private static func pinChecks(in browser: Browser) -> [String] {
        var failures: [String] = []
        func fail(_ what: String) { failures.append(what) }
        let shelf = Spaces.shared
        let space = shelf.current(in: browser)
        let site = "https://pin-check.example.net/"
        let pinsBefore = shelf.pins.map(\.id)
        guard let sent = shelf.cloudOpen(URL(string: site + "a")!, title: "pin check", pin: "P", in: space, browser: browser) else {
            return ["cloudOpen made no tab for a pin from another Mac"]
        }
        if !shelf.pins.contains(where: { $0.id == sent.id }) { fail("a pin from another Mac is not among the pins") }
        if shelf.row(space).contains(where: { $0.id == sent.id }) { fail("a pin from another Mac sits in the space's row") }
        let written = shelf.shape(visible: browser.tabs, active: browser.activeID).pins ?? []
        if !written.contains(where: { $0.url == site + "a" }) { fail("a pin from another Mac is not in the session's pins") }
        let doc = CloudApply.spaces(browser, base: nil)
        if doc.tabs.filter({ $0.pinned && $0.url.hasPrefix(site) }).count != 1 { fail("the cloud document does not list the pin once") }

        // A second pin on the same site (what older builds opened): the next
        // document closes it and keeps the first.
        let copy = shelf.cloudOpen(URL(string: site + "b")!, title: "pin check copy", pin: "P", in: space, browser: browser)
        if copy == nil { fail("cloudOpen made no tab for the copy") }
        let folded = CloudApply.spaces(browser, base: doc)
        if let copy, shelf.pins.contains(where: { $0.id == copy.id }) { fail("a second pin for a pinned site was kept") }
        if !shelf.pins.contains(where: { $0.id == sent.id }) { fail("folding closed the first pin, not the copy") }
        if folded.tabs.filter({ $0.pinned && $0.url.hasPrefix(site) }).count != 1 { fail("the folded document lists the site's pin more than once") }

        // Tidy up: the pins are as they were.
        shelf.cloudClose(sent, browser: browser)
        if shelf.pins.map(\.id) != pinsBefore { fail("the pins did not come back to how they were") }
        return failures
    }
}
