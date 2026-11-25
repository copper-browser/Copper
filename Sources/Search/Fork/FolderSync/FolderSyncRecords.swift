import Foundation

// Copper Cloud's documents (CloudDocs, Fork/Cloud/CloudMerge.swift) as sync
// records, and back. A record per thing — a space, a kept tab, a folder, a
// setting, a bookmark — so two Macs editing different things never touch the
// same record, and only what changed goes into a log. Pure, and lossless:
// `spaces(records(doc)) == doc` for any document Copper builds (checked in
// FolderSyncChecks).
//
//   sp:<id>  sp.order  kt:<key>  fd:<id>  fd.order   spaces and kept tabs
//   set:<name>                                       settings (the allowlist)
//   bm:<id>                                          bookmarks
//   h:<key>                                          history
//   tabs:<device>  dev:<device>                      each Mac's open tabs and name
//   ext:<id>                                         extensions from the Web Store

enum SyncRecords {
    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    static func decode<T: Decodable>(_ type: T.Type, _ text: String) -> T? {
        try? JSONDecoder().decode(T.self, from: Data(text.utf8))
    }

    // MARK: - which record is whose

    enum Kind: String, CaseIterable { case spaces, settings, bookmarks, history, tabs, devices, extensions }

    static func kind(of key: String) -> Kind? {
        if key.hasPrefix("sp:") || key == "sp.order" || key.hasPrefix("kt:") || key.hasPrefix("fd:") || key == "fd.order" { return .spaces }
        if key.hasPrefix("set:") { return .settings }
        if key.hasPrefix("bm:") { return .bookmarks }
        if key.hasPrefix("h:") { return .history }
        if key.hasPrefix("tabs:") { return .tabs }
        if key.hasPrefix("dev:") { return .devices }
        if key.hasPrefix("ext:") { return .extensions }
        return nil
    }

    static func of(_ kind: Kind) -> (String) -> Bool { { SyncRecords.kind(of: $0) == kind } }

    // MARK: - spaces

    static func records(_ doc: CloudDocs.Spaces) -> [String: String] {
        var out: [String: String] = [:]
        for space in doc.spaces { out["sp:\(space.id.uuidString.lowercased())"] = encode(space) }
        out["sp.order"] = encode(doc.spaces.map { $0.id.uuidString.lowercased() })
        for tab in doc.tabs { out["kt:\(tab.key)"] = encode(tab) }
        for folder in doc.groups ?? [] { out["fd:\(folder.id.uuidString.lowercased())"] = encode(folder) }
        out["fd.order"] = encode((doc.groups ?? []).map { $0.id.uuidString.lowercased() })
        return out
    }

    static func spaces(_ records: [String: String]) -> CloudDocs.Spaces {
        let spaces = ordered(records, prefix: "sp:", order: "sp.order", as: Space.self)
        let tabs = records.filter { $0.key.hasPrefix("kt:") }
            .compactMap { decode(CloudDocs.KeptTab.self, $0.value) }
            .sorted { $0.key < $1.key }
        let folders = ordered(records, prefix: "fd:", order: "fd.order", as: CloudDocs.Folder.self)
        return CloudDocs.Spaces(spaces: spaces, tabs: tabs, groups: folders)
    }

    /// Things in the order record's order; any it doesn't name (written by
    /// a Mac that hadn't seen the newest order yet) after them, by id.
    private static func ordered<T: Decodable>(_ records: [String: String], prefix: String, order: String, as type: T.Type) -> [T] {
        let ids = records[order].flatMap { decode([String].self, $0) } ?? []
        var out: [T] = []
        var placed = Set<String>()
        for id in ids where !placed.contains(id) {
            guard let text = records[prefix + id], let item = decode(T.self, text) else { continue }
            placed.insert(id)
            out.append(item)
        }
        for key in records.keys.filter({ $0.hasPrefix(prefix) }).sorted() where !placed.contains(String(key.dropFirst(prefix.count))) {
            if let item = decode(T.self, records[key]!) { out.append(item) }
        }
        return out
    }

    // MARK: - settings

    static func records(_ doc: CloudDocs.Settings) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in CloudSettingsKeys.filter(doc.values) { out["set:\(key)"] = encode(value) }
        return out
    }

    static func settings(_ records: [String: String]) -> CloudDocs.Settings {
        var values: [String: String] = [:]
        for (key, text) in records where key.hasPrefix("set:") {
            if let value = decode(String.self, text) { values[String(key.dropFirst(4))] = value }
        }
        return CloudDocs.Settings(values: CloudSettingsKeys.filter(values))
    }

    // MARK: - bookmarks

    /// A bookmark without its children: its folder, title, address, and its
    /// place among its folder's children.
    struct Mark: Codable, Equatable {
        var p: String?
        var t: String
        var u: String?
        var i: Int
    }

    // shortcut: a node's place is its index, so a move renumbers the folder's later items; use fractional positions if folders get long.
    static func records(_ doc: CloudDocs.Bookmarks) -> [String: String] {
        var out: [String: String] = [:]
        func walk(_ nodes: [Bookmark], _ parent: UUID?) {
            for (i, node) in nodes.enumerated() {
                out["bm:\(node.id.uuidString.lowercased())"] = encode(Mark(p: parent?.uuidString.lowercased(), t: node.title, u: node.url, i: i))
                if let kids = node.children { walk(kids, node.id) }
            }
        }
        walk(doc.roots, nil)
        return out
    }

    static func bookmarks(_ records: [String: String]) -> CloudDocs.Bookmarks {
        let marks = records.compactMap { key, text -> (UUID, Mark)? in
            guard key.hasPrefix("bm:"), let id = UUID(uuidString: String(key.dropFirst(3))), let mark = decode(Mark.self, text) else { return nil }
            return (id, mark)
        }
        .sorted { $0.1.i != $1.1.i ? $0.1.i < $1.1.i : $0.0.uuidString < $1.0.uuidString }
        let nodes = marks.map { id, mark in
            CloudMerge.Node(id: id, parent: mark.p.flatMap(UUID.init(uuidString:)), title: mark.t, url: mark.u)
        }
        return CloudDocs.Bookmarks(roots: CloudMerge.tree(nodes))
    }

    // MARK: - history, open tabs, devices, extensions

    /// A place visited: address, title, visits, last visit (seconds).
    struct Place: Codable, Equatable {
        var u: String
        var t: String
        var n: Int
        var l: Double
    }

    /// A Mac's open tabs, for the others to look at.
    struct Tabs: Codable, Equatable {
        var n: String
        var tabs: [CloudDocs.Tabs.Open]
    }

    /// A Mac in the chain, by name.
    struct Device: Codable, Equatable {
        var n: String
        var k = "mac"
    }

    /// An extension from the Chrome Web Store, or one the person removed —
    /// a live record, never a tombstone, so it outlives compaction.
    struct Ext: Codable, Equatable {
        var n: String
        var removed: Bool? = nil
    }
}
