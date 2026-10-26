import Foundation

// The documents Copper Cloud keeps, and how two copies of one become one
// again. Pure: no browser, no network, no main actor — so the bench can
// check them with made-up inputs (`bench cloud selftest`).
//
// Every whole-document domain merges three ways: the copy last known to be
// on the server and applied here (the base), this Mac's copy now, and the
// server's copy now. Something changed on one side only takes that side;
// something changed on both takes the server's ("server wins"). Something
// missing from one side that the base had was deleted there, and stays
// deleted; something the base never had is new, and is kept. With no base
// — the first sync of a domain — it is a plain union, the server winning
// where both have the same thing.

enum CloudDocs {
    /// Spaces and the tabs kept in them (pins and Saved), not the Today row.
    struct Spaces: Codable, Equatable {
        var v = 1
        var spaces: [Space]
        var tabs: [KeptTab]
        /// The folders kept tabs are filed in (`Groups`), in their order.
        /// Optional, and new: a document from a build before folders
        /// travelled has none, and then every device keeps its own as they
        /// are — nil never means "no folders".
        var groups: [Folder]? = nil
    }

    /// A folder (`TabGroup`) as it travels: its name — nesting lives in the
    /// name, ` › ` between levels — colour, and where an empty one stands.
    /// Not whether it is open: that is each device's own business, and
    /// syncing it would have two devices fold each other's folders.
    struct Folder: Codable, Equatable {
        var id: UUID
        var name: String
        var hue: Double?
        var space: UUID?
        var slot: Int?
    }

    /// A pinned or Saved tab. `key` is how two Macs agree it is the same
    /// tab: its space, its section and its site, numbered when one space
    /// pins the same site twice. Its address and title are the ones it had
    /// when it was first synced, so browsing inside a pinned tab doesn't
    /// send a new copy of every space on every click.
    struct KeptTab: Codable, Equatable {
        var key: String
        var space: UUID
        var url: String
        var title: String
        var pinned: Bool
        /// The pin's letter, as the column draws it.
        var pin: String?
        /// The folder it is filed in (`Folder.id`), or nil for none. New;
        /// see `Spaces.groups`.
        var group: UUID? = nil
    }

    /// The safe settings, by key; see `CloudSettingsKeys`.
    struct Settings: Codable, Equatable {
        var v = 1
        var values: [String: String]
    }

    /// The bookmarks tree, ids and all.
    struct Bookmarks: Codable, Equatable {
        var v = 1
        var roots: [Bookmark]
    }

    /// One device's open tabs, for the others to look at.
    struct Tabs: Codable, Equatable {
        struct Open: Codable, Equatable {
            var url: String
            var title: String
            var space: String?
            var active: Bool?
        }
        var v = 1
        var device: String
        var updated: Double
        var tabs: [Open]
    }

    /// The key for a kept tab: space, section, host, and which of that
    /// host's tabs in the section it is.
    static func keys(for tabs: [(space: UUID, pinned: Bool, url: String)]) -> [String] {
        var seen: [String: Int] = [:]
        return tabs.map { tab in
            let host = URL(string: tab.url)?.host()?.lowercased() ?? tab.url.lowercased()
            let stem = "\(tab.space.uuidString.lowercased())|\(tab.pinned ? "pin" : "saved")|\(host)"
            let n = seen[stem, default: 0]
            seen[stem] = n + 1
            return "\(stem)|\(n)"
        }
    }
}

enum CloudMerge {
    /// Three-way merge of keyed lists. Order: the server's, unless only
    /// this Mac reordered since the base; things new here go after.
    static func list<T: Equatable>(base: [T]?, local: [T], server: [T], id: (T) -> String) -> [T] {
        let baseBy = base.map { Dictionary($0.map { (id($0), $0) }, uniquingKeysWith: { a, _ in a }) }
        let localBy = Dictionary(local.map { (id($0), $0) }, uniquingKeysWith: { a, _ in a })
        let serverBy = Dictionary(server.map { (id($0), $0) }, uniquingKeysWith: { a, _ in a })

        var chosen: [String: T] = [:]
        for key in Set(localBy.keys).union(serverBy.keys) {
            let mine = localBy[key], theirs = serverBy[key], was = baseBy?[key]
            switch (mine, theirs) {
            case let (mine?, theirs?):
                // Both have it: mine only if the server's is still the base's.
                if let was, theirs == was, mine != was { chosen[key] = mine } else { chosen[key] = theirs }
            case let (mine?, nil):
                // Only here: new here, or deleted there.
                if was == nil { chosen[key] = mine }
                else if mine != was { chosen[key] = mine } // edited here after the delete — keep the edit
            case let (nil, theirs?):
                // Only there: new there, or deleted here.
                if was == nil { chosen[key] = theirs }
                else if theirs != was { chosen[key] = theirs } // edited there after the delete
            case (nil, nil):
                break
            }
        }

        let baseOrder = base?.map(id) ?? []
        let localOrder = local.map(id), serverOrder = server.map(id)
        let localMoved = base != nil && localOrder.filter { baseBy?[$0] != nil } != baseOrder.filter { localBy[$0] != nil }
        let serverMoved = base == nil || serverOrder.filter { baseBy?[$0] != nil } != baseOrder.filter { serverBy[$0] != nil }
        let first = localMoved && !serverMoved ? localOrder : serverOrder
        let second = localMoved && !serverMoved ? serverOrder : localOrder
        var out: [T] = []
        var placed = Set<String>()
        for key in first + second where !placed.contains(key) {
            guard let item = chosen[key] else { continue }
            placed.insert(key)
            out.append(item)
        }
        return out
    }

    static func spaces(base: CloudDocs.Spaces?, local: CloudDocs.Spaces, server: CloudDocs.Spaces) -> CloudDocs.Spaces {
        // The first sync of a second Mac: both have a "Home" (each made its
        // own on first launch). Same name, never synced here — the same space.
        let local = base == nil ? rekeyed(local, to: server) : local
        let spaces = list(base: base?.spaces, local: local.spaces, server: server.spaces) { $0.id.uuidString }
        let alive = Set(spaces.map(\.id))
        var tabs = list(base: base?.tabs, local: local.tabs, server: server.tabs) { $0.key }
            .filter { alive.contains($0.space) }
        // A server document without folders is an older build's: its blank
        // `group`s say nothing, so each tab stays filed where it is here.
        if server.groups == nil, local.groups != nil {
            let mine = Dictionary(local.tabs.map { ($0.key, $0.group) }, uniquingKeysWith: { a, _ in a })
            for i in tabs.indices where tabs[i].group == nil { tabs[i].group = mine[tabs[i].key] ?? nil }
        }
        return CloudDocs.Spaces(spaces: spaces, tabs: tabs, groups: groups(base: base?.groups, local: local.groups, server: server.groups))
    }

    /// The folders, merged like the spaces. A side that sent none (a build
    /// from before folders travelled) has said nothing about them: the other
    /// side's stand, rather than every folder reading as deleted.
    static func groups(base: [CloudDocs.Folder]?, local: [CloudDocs.Folder]?, server: [CloudDocs.Folder]?) -> [CloudDocs.Folder]? {
        guard let server else { return local }
        guard let local else { return server }
        return list(base: base, local: local, server: server) { $0.id.uuidString }
    }

    /// Local spaces the server doesn't know, matched by name (ignoring case)
    /// to server spaces this Mac doesn't have: old id → server id.
    static func sameNamed(local: [Space], server: [Space]) -> [UUID: UUID] {
        let localIDs = Set(local.map(\.id)), serverIDs = Set(server.map(\.id))
        var out: [UUID: UUID] = [:]
        var taken = Set<UUID>()
        for space in local where !serverIDs.contains(space.id) {
            let name = space.name.trimmingCharacters(in: .whitespaces).lowercased()
            if let match = server.first(where: {
                !localIDs.contains($0.id) && !taken.contains($0.id) && $0.name.trimmingCharacters(in: .whitespaces).lowercased() == name
            }) {
                out[space.id] = match.id
                taken.insert(match.id)
            }
        }
        return out
    }

    static func rekeyed(_ doc: CloudDocs.Spaces, to server: CloudDocs.Spaces) -> CloudDocs.Spaces {
        let map = sameNamed(local: doc.spaces, server: server.spaces)
        guard !map.isEmpty else { return doc }
        var doc = doc
        for i in doc.spaces.indices { if let to = map[doc.spaces[i].id] { doc.spaces[i].id = to } }
        for i in doc.tabs.indices {
            guard let to = map[doc.tabs[i].space] else { continue }
            let old = doc.tabs[i].space.uuidString.lowercased()
            doc.tabs[i].space = to
            if doc.tabs[i].key.hasPrefix(old) { doc.tabs[i].key = to.uuidString.lowercased() + doc.tabs[i].key.dropFirst(old.count) }
        }
        return doc
    }

    static func settings(base: CloudDocs.Settings?, local: CloudDocs.Settings, server: CloudDocs.Settings) -> CloudDocs.Settings {
        var out = local.values
        for (key, value) in server.values {
            // Server wins, except where only this Mac changed it since the base.
            if let base, base.values[key] == value, let mine = local.values[key], mine != value { continue }
            out[key] = value
        }
        return CloudDocs.Settings(values: out)
    }

    // MARK: - bookmarks

    /// A bookmark without its children, and where it hangs.
    struct Node: Equatable {
        var id: UUID
        var parent: UUID?
        var title: String
        var url: String?
    }

    static func flatten(_ roots: [Bookmark]) -> [Node] {
        var out: [Node] = []
        func walk(_ nodes: [Bookmark], _ parent: UUID?) {
            for node in nodes {
                out.append(Node(id: node.id, parent: parent, title: node.title, url: node.url))
                if let kids = node.children { walk(kids, node.id) }
            }
        }
        walk(roots, nil)
        return out
    }

    /// The tree again: each node under its parent, in list order. A node
    /// whose parent is gone, or not a folder, or would make a loop, goes to
    /// the top level rather than disappearing.
    static func tree(_ nodes: [Node]) -> [Bookmark] {
        let by = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func homed(_ node: Node) -> UUID? {
            guard let parent = node.parent, let folder = by[parent], folder.url == nil else { return nil }
            // Walk up: a loop puts this node at the top.
            var seen: Set<UUID> = [node.id]
            var at: UUID? = parent
            while let here = at {
                if seen.contains(here) { return nil }
                seen.insert(here)
                at = by[here]?.parent
            }
            return parent
        }
        var kids: [UUID?: [Node]] = [:]
        for node in nodes { kids[homed(node), default: []].append(node) }
        func build(_ parent: UUID?, _ depth: Int) -> [Bookmark] {
            guard depth < 64 else { return [] }
            return (kids[parent] ?? []).map { node in
                Bookmark(id: node.id, title: node.title, url: node.url,
                         children: node.url == nil ? build(node.id, depth + 1) : nil)
            }
        }
        return build(nil, 0)
    }

    static func bookmarks(base: CloudDocs.Bookmarks?, local: CloudDocs.Bookmarks, server: CloudDocs.Bookmarks) -> CloudDocs.Bookmarks {
        let merged = list(base: base.map { flatten($0.roots) }, local: flatten(local.roots), server: flatten(server.roots)) { $0.id.uuidString }
        // A folder deleted on one side takes the things filed in it along,
        // unless they were changed on the other side — then they surface at
        // the top level (tree() rehomes them).
        return CloudDocs.Bookmarks(roots: tree(merged))
    }

    // MARK: - history

    /// Whether a visit from elsewhere is one this Mac already has: the
    /// same place within a second.
    static func sameVisit(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) < 1 }
}

// MARK: - settings that may travel

/// The settings that sync: how Copper looks and behaves, nothing else. Not
/// passwords or passkeys, not where downloads go, not the script socket, not
/// keys, accounts, agents or anything with a path in it. See docs/cloud.md.
enum CloudSettingsKeys {
    static let allowed: [String] = [
        "look",             // light / dark / system
        "sidebar",          // tabs down the left
        "glyph",            // letters or site icons
        "tabs.switching",   // ⌃Tab: the row or most recent
        "tabs.sleep",       // put idle tabs to sleep
        "spaces.swipe",     // which way a swipe moves the column
        "shield",           // block ads and trackers
        "autocorrect",      // correct spelling in pages
        "sections.archive", // when Today rows are archived
    ]

    /// Only the allowed keys, and only values of the expected shape.
    static func filter(_ values: [String: String]) -> [String: String] {
        values.filter { key, value in
            guard allowed.contains(key) else { return false }
            switch key {
            case "look": return ["light", "dark", "system"].contains(value)
            case "glyph": return ["letters", "icons"].contains(value)
            case "tabs.switching": return ["row", "recent"].contains(value)
            case "spaces.swipe": return ["system", "natural", "inverted"].contains(value)
            case "sections.archive": return ["h12", "h24", "h48", "never"].contains(value)
            default: return value == "true" || value == "false"
            }
        }
    }
}
