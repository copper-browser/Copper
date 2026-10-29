import Foundation

// Reading this Mac's state into Cloud documents, and writing merged ones
// back — through the same objects the rest of the app edits (Spaces,
// Preferences, Bookmarks, History), never behind their backs into their
// files. Called by CloudSync on the main actor.

@MainActor
enum CloudApply {
    // MARK: - spaces

    /// Which kept-tab key a live tab answers to. Kept for the run: a tab
    /// that navigates keeps its key, and a tab opened for another Mac's
    /// entry has that entry's key from the start.
    private static var tabKeys: [Tab.ID: String] = [:]

    private struct Kept {
        let tab: Tab
        let space: UUID
        let pinned: Bool
        let url: URL
    }

    /// The pinned and Saved tabs of every space, in row order.
    private static func kept(_ browser: Browser) -> [Kept] {
        let spaces = Spaces.shared
        var out: [Kept] = []
        // Pins belong to no space: key them once, under the first space, not
        // under whichever one the window shows — switching spaces re-keyed
        // every pin, and a document still holding the old keys opened them
        // all again as new pins.
        if let anchor = spaces.all.first?.id {
            for tab in spaces.pins {
                guard let url = keptURL(of: tab, saved: false) else { continue }
                out.append(Kept(tab: tab, space: anchor, pinned: true, url: url))
            }
        }
        for space in spaces.all {
            let row = space.id == spaces.current ? browser.tabs : (spaces.parkedRow(space.id) ?? [])
            for tab in row where !spaces.pins.contains(where: { $0.id == tab.id }) {
                guard let url = keptURL(of: tab, saved: Sections.shared.isSaved(tab)) else { continue }
                out.append(Kept(tab: tab, space: space.id, pinned: tab.pin != nil, url: url))
            }
        }
        return out
    }

    /// The address a row is kept under in the document, or nil for one that
    /// isn't kept: a favourite or a Saved row on a web page, asleep or awake
    /// — a Saved tab closed with ⌘W is put down, not closed, and stays kept
    /// (Fork/Sections.swift); only taking it out of Saved deletes it.
    static func keptURL(of tab: Tab, saved: Bool) -> URL? {
        guard !tab.shy, !tab.bench, tab.pin != nil || saved,
              let url = tab.pending ?? tab.address, url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }

    private static func stem(space: UUID, pinned: Bool, url: URL) -> String {
        "\(space.uuidString.lowercased())|\(pinned ? "pin" : "saved")|\(url.host()?.lowercased() ?? "")"
    }

    /// The key `tab` is kept under now, or nil: this run's, else the synced
    /// document's entry at its address — or at its site, when the document
    /// keeps only one there. For `CloudIntents`, before an edit changes it.
    static func key(of tab: Tab, base: @autoclosure () -> CloudDocs.Spaces?) -> String? {
        if let key = tabKeys[tab.id] { return key }
        let pinned = tab.pin != nil
        guard let space = pinned ? Spaces.shared.all.first?.id : Spaces.shared.spaceID(of: tab),
              let url = keptURL(of: tab, saved: Sections.shared.isSaved(tab)) else { return nil }
        let s = stem(space: space, pinned: pinned, url: url)
        let entries = base()?.tabs.filter { $0.key.hasPrefix(s + "|") } ?? []
        return (entries.first { $0.url == url.absoluteString } ?? (entries.count == 1 ? entries[0] : nil))?.key
    }

    /// This Mac's spaces document as it may be sent: its live state, held to
    /// what was changed here by hand (`CloudMerge.intended`).
    static func spaces(_ browser: Browser, base: CloudDocs.Spaces?) -> CloudDocs.Spaces {
        let doc = live(browser, base: base)
        let intents = CloudIntents.shared
        intents.resolve(tabKeys)
        return CloudMerge.intended(doc, base: base, tabs: Set(intents.keys.keys), folders: Set(intents.folders.keys))
    }

    /// This Mac's spaces document, as it is here. `base` is the last one
    /// synced: a tab it already had keeps that entry's key, address and title.
    static func live(_ browser: Browser, base: CloudDocs.Spaces?) -> CloudDocs.Spaces {
        // Pins sync one per site (CloudMerge.onePinPerSite); copies an older
        // build opened here close before this Mac says what it has.
        Spaces.shared.cloudFoldPins(browser: browser)
        let list = kept(browser)
        let baseBy = Dictionary((base?.tabs ?? []).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var used = Set<String>()
        var keyFor: [Tab.ID: String] = [:]
        // 1. Keys this run already knows, while they still describe the tab.
        // Same space and section is enough: a pinned tab that wandered off
        // to another site is still the same pin.
        for item in list {
            if let key = tabKeys[item.tab.id], !used.contains(key),
               key.hasPrefix("\(item.space.uuidString.lowercased())|\(item.pinned ? "pin" : "saved")|") {
                keyFor[item.tab.id] = key
                used.insert(key)
            }
        }
        // 2. The base's entries: same address first, then same site.
        for exact in [true, false] {
            for item in list where keyFor[item.tab.id] == nil {
                let s = stem(space: item.space, pinned: item.pinned, url: item.url)
                if let entry = base?.tabs.first(where: { entry in
                    !used.contains(entry.key) && entry.key.hasPrefix(s + "|")
                        && (!exact || entry.url == item.url.absoluteString)
                }) {
                    keyFor[item.tab.id] = entry.key
                    used.insert(entry.key)
                }
            }
        }
        // 3. New ones: the site and the address.
        for item in list where keyFor[item.tab.id] == nil {
            var key = stem(space: item.space, pinned: item.pinned, url: item.url) + "|" + item.url.absoluteString
            var n = 2
            while used.contains(key) { key = stem(space: item.space, pinned: item.pinned, url: item.url) + "|\(item.url.absoluteString)#\(n)"; n += 1 }
            keyFor[item.tab.id] = key
            used.insert(key)
        }
        tabKeys = keyFor
        let tabs = list.compactMap { item -> CloudDocs.KeptTab? in
            guard let key = keyFor[item.tab.id] else { return nil }
            let group = Groups.shared.membership[item.tab.id]
            if let was = baseBy[key] {
                return CloudDocs.KeptTab(key: key, space: item.space, url: was.url, title: was.title, pinned: item.pinned, pin: item.tab.pin ?? was.pin, group: group)
            }
            return CloudDocs.KeptTab(key: key, space: item.space, url: item.url.absoluteString,
                                     title: item.tab.title, pinned: item.pinned, pin: item.tab.pin, group: group)
        }
        // Sorted, not in row order: dragging a pin along the row is this
        // Mac's business, and two Macs that order a row differently must
        // not take turns sending their order back and forth.
        let folders = Groups.shared.all.map {
            CloudDocs.Folder(id: $0.id, name: $0.name, hue: $0.hue, space: $0.space, slot: $0.slot)
        }
        return CloudDocs.Spaces(spaces: Spaces.shared.all, tabs: CloudMerge.onePinPerSite(tabs).sorted { $0.key < $1.key }, groups: folders)
    }

    /// Make this Mac's spaces the merged document's: spaces added, edited,
    /// ordered, and those gone removed (their Today tabs move to a
    /// neighbour); kept tabs opened, asleep, or closed.
    static func apply(spaces doc: CloudDocs.Spaces, base: CloudDocs.Spaces?, in browser: Browser) {
        guard browser.primary else { return }
        var doc = doc
        doc.tabs = CloudMerge.onePinPerSite(doc.tabs)
        let shelf = Spaces.shared
        let wanted = Set(doc.spaces.map(\.id))
        // A space this Mac made and never synced, named like one in the
        // document that isn't here, is that space: it takes the document's
        // id (the merge already counted it so), its tabs and all.
        if base == nil {
            for (old, new) in CloudMerge.sameNamed(local: shelf.all, server: doc.spaces) where wanted.contains(new) {
                shelf.cloudRekey(old, to: new)
                tabKeys = tabKeys.mapValues { key in
                    let prefix = old.uuidString.lowercased()
                    return key.hasPrefix(prefix) ? new.uuidString.lowercased() + key.dropFirst(prefix.count) : key
                }
            }
        }
        // As it is here, not as it may be sent: a kept tab missing here
        // that the document still has opens again.
        let local = live(browser, base: base)
        let localKeys = Dictionary(local.tabs.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let docKeys = Set(doc.tabs.map(\.key))

        if !doc.spaces.isEmpty { shelf.cloudAdopt(doc.spaces) }

        // Kept tabs gone from the document: close them here.
        let byKey = Dictionary(tabKeys.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        var live: [Tab.ID: Tab] = [:]
        for item in kept(browser) { live[item.tab.id] = item.tab }
        // Only ones the base had: a tab kept here since the last sync is new,
        // not deleted, and never closed by a document that hasn't seen it.
        let baseKeys = Set(base?.tabs.map(\.key) ?? [])
        // A pin whose site the document still pins under another key is not
        // gone: it takes that key below rather than closing and reopening.
        let docPinSites = Set(doc.tabs.filter(\.pinned).map { CloudMerge.site($0.url) })
        for (key, entry) in localKeys where !docKeys.contains(key) && baseKeys.contains(key)
            && !(entry.pinned && docPinSites.contains(CloudMerge.site(entry.url))) {
            if let id = byKey[key], let tab = live[id] { shelf.cloudClose(tab, browser: browser) }
        }
        // Kept tabs new in the document: open them, asleep.
        for entry in doc.tabs where localKeys[entry.key] == nil {
            guard let url = URL(string: entry.url), url.scheme?.hasPrefix("http") == true else { continue }
            // A pin for a site already pinned here is that pin under another
            // key (an older build keyed pins by the space on screen): adopt
            // the key rather than pin the site a second time.
            // Never a second pin for a site: it takes the key if it has none
            // the document still holds.
            if entry.pinned {
                let site = CloudMerge.site(entry.url)
                let same = kept(browser).filter { $0.pinned && CloudMerge.site($0.url.absoluteString) == site }.map(\.tab)
                if !same.isEmpty {
                    if let free = same.first(where: { tab in tabKeys[tab.id].map { !docKeys.contains($0) } ?? true }) {
                        tabKeys[free.id] = entry.key
                    }
                    continue
                }
            }
            let pin = entry.pinned ? (entry.pin ?? Address.pretty(url).prefix(1).uppercased()) : nil
            if let tab = shelf.cloudOpen(url, title: entry.title, pin: pin, in: entry.space, browser: browser) {
                tabKeys[tab.id] = entry.key
            }
        }

        // Folders, then which folder each kept tab is filed in — only when
        // the document says (one from an older build has no folders at all,
        // and must not empty this Mac's).
        if let folders = doc.groups {
            let gone = Set(base?.groups?.map(\.id) ?? []).subtracting(folders.map(\.id))
            Groups.shared.cloudAdopt(folders, removed: gone)
            let byKey = Dictionary(doc.tabs.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            for item in kept(browser) {
                guard let key = tabKeys[item.tab.id], let entry = byKey[key] else { continue }
                Groups.shared.cloudFile(item.tab, in: entry.group)
            }
        }

        // Spaces gone from the document, last: their kept tabs are already
        // closed, and whatever is left in Today goes next door.
        let synced = Set(base?.spaces.map(\.id) ?? [])
        for space in shelf.all where !wanted.contains(space.id) && synced.contains(space.id) && !doc.spaces.isEmpty {
            guard shelf.all.count > 1 else { break }
            let neighbour = shelf.neighbour(of: space.id)?.id
            shelf.remove(space.id, in: browser, movingTabsTo: neighbour)
        }
    }

    // MARK: - settings

    static func settings(_ browser: Browser) -> CloudDocs.Settings {
        let p = browser.prefs
        let values: [String: String] = [
            "look": p.look.rawValue,
            "sidebar": String(p.sidebar),
            "glyph": p.glyph.rawValue,
            "tabs.switching": p.tabSwitching.rawValue,
            "tabs.sleep": String(p.sleepsTabs),
            "spaces.swipe": p.swipeDirection.rawValue,
            "shield": String(p.shielded),
            "autocorrect": String(p.autocorrect),
            "sections.archive": Sections.shared.archive.rawValue,
        ]
        return CloudDocs.Settings(values: CloudSettingsKeys.filter(values))
    }

    static func apply(settings doc: CloudDocs.Settings, in browser: Browser) {
        let p = browser.prefs
        let values = CloudSettingsKeys.filter(doc.values)
        func bool(_ key: String) -> Bool? { values[key].map { $0 == "true" } }
        if let v = values["look"].flatMap(Look.init(rawValue:)), v != p.look { p.look = v }
        if let v = bool("sidebar"), v != p.sidebar { p.sidebar = v }
        if let v = values["glyph"].flatMap(Glyph.init(rawValue:)), v != p.glyph { p.glyph = v }
        if let v = values["tabs.switching"].flatMap(TabSwitching.init(rawValue:)), v != p.tabSwitching { p.tabSwitching = v }
        if let v = bool("tabs.sleep"), v != p.sleepsTabs { p.sleepsTabs = v }
        if let v = values["spaces.swipe"].flatMap(SwipeDirection.init(rawValue:)), v != p.swipeDirection { p.swipeDirection = v }
        if let v = bool("shield"), v != p.shielded { p.shielded = v }
        if let v = bool("autocorrect"), v != p.autocorrect { p.autocorrect = v }
        if let v = values["sections.archive"].flatMap(Sections.Archive.init(rawValue:)), v != Sections.shared.archive { Sections.shared.archive = v }
    }

    // MARK: - bookmarks

    static func bookmarks(_ browser: Browser) -> CloudDocs.Bookmarks {
        CloudDocs.Bookmarks(roots: browser.bookmarks.roots)
    }

    /// The whole tree, ids kept, in one write (`Bookmarks.replace`): a
    /// remove-and-insert per node would be a save per node, and those race
    /// each other to the file — the last to land, not the last made, wins.
    static func apply(bookmarks doc: CloudDocs.Bookmarks, in browser: Browser) {
        let bookmarks = browser.bookmarks
        guard bookmarks.roots != doc.roots else { return }
        bookmarks.replace(doc.roots)
    }

    // MARK: - open tabs

    /// Every window's ordinary tabs, and the parked rows' — not pins, not
    /// private or bench tabs, not blank ones.
    static func openTabs(device: String) -> CloudDocs.Tabs {
        var out: [CloudDocs.Tabs.Open] = []
        let names = Dictionary(Spaces.shared.all.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        func add(_ tabs: [Tab], space: String?, active: Tab.ID?) {
            for tab in tabs where tab.pin == nil && !tab.shy && !tab.bench {
                guard let url = tab.pending ?? tab.address, url.scheme?.hasPrefix("http") == true else { continue }
                out.append(.init(url: url.absoluteString, title: tab.title, space: space, active: tab.id == active ? true : nil))
            }
        }
        for window in Windows.all {
            add(window.tabs, space: window.primary ? names[Spaces.shared.current] : nil, active: window.activeID)
        }
        for space in Spaces.shared.all where space.id != Spaces.shared.current {
            add(Spaces.shared.parkedRow(space.id) ?? [], space: names[space.id], active: nil)
        }
        return CloudDocs.Tabs(device: device, updated: Date().timeIntervalSince1970, tabs: Array(out.prefix(500)))
    }

    // MARK: - history

    /// A place as history.json keeps it. Read from the file, which History
    /// writes a moment after each visit: History keeps its own records
    /// private, and the file is the published form of them.
    struct Visit: Codable {
        var url: String
        var key: String
        var title: String
        var count: Int
        var last: Date
    }

    static var historyFile: URL { Store.file("history.json") }

    static func visits() -> [Visit] {
        guard let data = try? Data(contentsOf: historyFile) else { return [] }
        return (try? JSONDecoder().decode([Visit].self, from: data)) ?? []
    }

    /// Nonisolated: a delete matches cloud rows against it off the main
    /// thread (CloudHistoryDelete).
    nonisolated static func historyKey(_ url: URL) -> String { Address.pretty(url).lowercased() }
}
