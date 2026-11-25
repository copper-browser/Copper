import Foundation

/// Chromium's account and local files have the same tree shape. Account wins
/// each duplicate; local-only sites and folders follow it, profile by profile.
enum FlowBookmarks {
    static func count(_ nodes: [Bookmark]) -> Int {
        nodes.reduce(0) { $0 + ($1.isFolder ? count($1.children ?? []) : 1) }
    }

    /// Every site in a tree, in order, folders opened.
    static func urls(_ nodes: [Bookmark]) -> [URL] {
        var out: [URL] = []
        func walk(_ nodes: [Bookmark]) {
            for node in nodes {
                if node.isFolder { walk(node.children ?? []) } else if let url = node.url.flatMap(URL.init(string:)) { out.append(url) }
            }
        }
        walk(nodes)
        return out
    }

    /// The sites in a tree as `FlowAdopt` compares addresses: a re-read that
    /// replaces an earlier import is not "new".
    static func addresses(_ nodes: [Bookmark]) -> Set<String> {
        Set(urls(nodes).map(FlowAdopt.address))
    }

    struct Read {
        let nodes: [Bookmark]
        let failedFiles: [URL]
        var complete: Bool { failedFiles.isEmpty }
    }

    static func bookmarks(in profiles: [URL]) -> Read {
        var bar: [Bookmark] = []
        var other: [Bookmark] = []
        var mobile: [Bookmark] = []
        var failed: [URL] = []
        for profile in profiles {
            for filename in ["AccountBookmarks", "Bookmarks"] {
                let file = profile.appendingPathComponent(filename)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                guard let data = try? Data(contentsOf: file),
                      let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let roots = top["roots"] as? [String: Any],
                      roots.keys.contains(where: { ["bookmark_bar", "other", "synced"].contains($0) }),
                      let barNodes = children(of: "bookmark_bar", roots: roots),
                      let otherNodes = children(of: "other", roots: roots),
                      let mobileNodes = children(of: "synced", roots: roots),
                      let parsedBar = nodes(in: barNodes),
                      let parsedOther = nodes(in: otherNodes),
                      let parsedMobile = nodes(in: mobileNodes)
                else { failed.append(file); continue }
                merge(parsedBar, into: &bar)
                merge(parsedOther, into: &other)
                merge(parsedMobile, into: &mobile)
            }
        }
        if !other.isEmpty { bar.append(.folder("Other", other)) }
        if !mobile.isEmpty { bar.append(.folder("Mobile", mobile)) }
        return Read(nodes: bar, failedFiles: failed)
    }

    private static func children(of key: String, roots: [String: Any]) -> [[String: Any]]? {
        guard roots[key] != nil else { return [] }
        guard let root = roots[key] as? [String: Any],
              let children = root["children"] as? [[String: Any]] else { return nil }
        return children
    }

    private static func nodes(in raw: [[String: Any]]) -> [Bookmark]? {
        var found: [Bookmark] = []
        for entry in raw {
            guard let name = entry["name"] as? String else { return nil }
            switch entry["type"] as? String {
            case "folder":
                guard let rawChildren = entry["children"] as? [[String: Any]],
                      let children = nodes(in: rawChildren) else { return nil }
                found.append(.folder(name, children))
            case "url":
                guard let text = entry["url"] as? String else { return nil }
                guard let url = URL(string: text), (url.scheme == "http" || url.scheme == "https"),
                      url.host != nil else { continue }
                found.append(.site(name, url))
            default: return nil
            }
        }
        return found
    }

    /// What makes two sites at one level the same bookmark: the address and
    /// the title (a different title for the same address is kept apart).
    private struct SiteKey: Hashable {
        var url: String?
        var title: String
        init(_ node: Bookmark) { url = node.url; title = node.title }
    }

    /// Merge matching folders in place and identical URL + title at the same
    /// level; a different title for the same URL is a separate bookmark.
    ///
    /// One pass per level, with an index of that level's folders and sites:
    /// the old per-node search made thousands of loose bookmarks quadratic.
    /// Every incoming folder bound for the same folder is gathered first and
    /// merged into it once, which is the same as merging them one by one.
    static func merge(_ incoming: [Bookmark], into result: inout [Bookmark]) {
        guard !incoming.isEmpty else { return }
        var folders: [String: Int] = [:]
        var sites = Set<SiteKey>()
        for (index, node) in result.enumerated() {
            if node.isFolder {
                if folders[node.title] == nil { folders[node.title] = index }
            } else {
                sites.insert(SiteKey(node))
            }
        }
        var pending: [Int: [Bookmark]] = [:]
        var order: [Int] = []
        for node in incoming {
            if node.isFolder {
                if let index = folders[node.title] {
                    if pending[index] == nil { order.append(index) }
                    pending[index, default: []].append(contentsOf: node.children ?? [])
                } else {
                    folders[node.title] = result.count
                    result.append(node)
                }
            } else if sites.insert(SiteKey(node)).inserted {
                result.append(node)
            }
        }
        for index in order {
            var children = result[index].children ?? []
            merge(pending[index] ?? [], into: &children)
            result[index].children = children
        }
    }

    /// A direct user mutation relinquishes its top-level root, even when a
    /// move back to the top changes only position (not Bookmark's value).
    @MainActor static func relinquish(touching ids: [Bookmark.ID], in roots: [Bookmark]) {
        let touched = Set(roots.filter { root in ids.contains { contains($0, in: root) } }.map(\.id))
        guard !touched.isEmpty else { return }
        // Every source that keeps a record: the Chromium family, Firefox's and Safari.
        for name in (Chromium.known + FlowFirefox.known).map(\.name) + [FlowSafari.name] {
            let file = Store.file("flow-bookmarks-\(name.lowercased()).json")
            guard let data = try? Data(contentsOf: file),
                  var owned = try? JSONDecoder().decode([Bookmark].self, from: data) else { continue }
            let before = owned.count
            owned.removeAll { touched.contains($0.id) }
            if owned.count != before, let data = try? JSONEncoder().encode(owned) {
                try? data.write(to: file, options: .atomic)
            }
        }
    }

    private static func contains(_ id: Bookmark.ID, in node: Bookmark) -> Bool {
        node.id == id || (node.children ?? []).contains { contains(id, in: $0) }
    }

    /// What `take` comes to: the new top level, and the roots this source
    /// now owns (its record, `flow-bookmarks-<source>.json`).
    struct Taken: Equatable {
        var roots: [Bookmark]
        var imported: [Bookmark]
    }

    /// A complete (including empty) read replaces only untouched owned roots.
    /// An unreadable present file cannot authorize deleting any old roots.
    ///
    /// Pure, and linear in the size of the trees: every "is this one of
    /// ours", "is that title taken", "is that site here" is an index lookup,
    /// so it can run off the main actor and thousands of loose bookmarks
    /// don't stall anything.
    nonisolated static func taking(_ read: Read, from source: String, roots current: [Bookmark],
                                   previous: [Bookmark]) -> Taken {
        let previousByID = Dictionary(grouping: previous, by: \.id)
        /// Untouched since this source brought it (same id, same contents).
        func owned(_ root: Bookmark) -> Bool { previousByID[root.id]?.contains(root) == true }

        var roots = current.filter { root in !read.complete || !owned(root) }
        var imported: [Bookmark] = []
        var importedAt: [Bookmark.ID: Int] = [:]
        if !read.complete {
            var rootsByID: [Bookmark.ID: [Bookmark]] = [:]
            for root in roots { rootsByID[root.id, default: []].append(root) }
            for old in previous where rootsByID[old.id]?.contains(old) == true {
                importedAt[old.id] = imported.count
                imported.append(old)
            }
        }

        // An incomplete read folds a folder into the root it made before:
        // the same title, or that title with the source's suffix (and a
        // number). Each candidate root is listed under every title that
        // would find it, in top-level order.
        var candidates: [String: [Int]] = [:]
        var stale = Set<Int>()
        if !read.complete {
            let suffix = " (\(source))"
            for (index, root) in roots.enumerated() where root.isFolder && owned(root) {
                let title = root.title
                var keys: Set<String> = [title]
                if title.hasSuffix(suffix) { keys.insert(String(title.dropLast(suffix.count))) }
                var from = title.startIndex
                while let hit = title.range(of: suffix + " ", range: from..<title.endIndex) {
                    keys.insert(String(title[..<hit.lowerBound]))
                    from = title.index(after: hit.lowerBound)
                }
                for key in keys { candidates[key, default: []].append(index) }
            }
        }

        var folderTitles = Set(roots.filter(\.isFolder).map(\.title))
        var sites = Set(roots.filter { !$0.isFolder }.map(SiteKey.init))
        var nextNumber: [String: Int] = [:]
        for var node in read.nodes {
            if !read.complete, node.isFolder,
               let index = candidates[node.title]?.first(where: { !stale.contains($0) }) {
                var children = roots[index].children ?? []
                merge(node.children ?? [], into: &children)
                roots[index].children = children
                // A root whose contents changed is no longer the one this
                // source left there, so nothing else folds into it.
                if !owned(roots[index]) { stale.insert(index) }
                if let at = importedAt[roots[index].id] { imported[at] = roots[index] }
                continue
            }
            if node.isFolder {
                if folderTitles.contains(node.title) {
                    node.title += " (\(source))"
                }
                // A person's same-named folder is still theirs, even if a
                // past imported folder with that name was moved or edited.
                var name = node.title
                var number = nextNumber[node.title] ?? 2
                while folderTitles.contains(name) {
                    name = "\(node.title) \(number)"
                    number += 1
                }
                nextNumber[node.title] = number
                node.title = name
                folderTitles.insert(name)
            } else if !sites.insert(SiteKey(node)).inserted {
                continue
            }
            roots.append(node)
            importedAt[node.id] = imported.count
            imported.append(node)
        }
        return Taken(roots: roots, imported: imported)
    }

    private static func record(for source: String) -> URL {
        Store.file("flow-bookmarks-\(source.lowercased()).json")
    }

    private nonisolated static func owned(in file: URL) -> [Bookmark] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Bookmark].self, from: $0) } ?? []
    }

    private nonisolated static func keep(_ imported: [Bookmark], in file: URL) {
        guard let data = try? JSONEncoder().encode(imported) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private static func note(_ read: Read, from source: String) {
        guard !read.complete else { return }
        NSLog("Copper: Flow %@ bookmarks: %d unreadable file(s); keeping previous roots: %@",
              source, read.failedFiles.count, read.failedFiles.map(\.path).joined(separator: ", "))
    }

    /// Takes a read here and now. Linear (`taking`), so even a large one is
    /// quick; Move in itself uses `takeInBackground`.
    @MainActor static func take(_ read: Read, from source: String, into bookmarks: Bookmarks) {
        note(read, from: source)
        let file = record(for: source)
        let taken = taking(read, from: source, roots: bookmarks.roots, previous: owned(in: file))
        bookmarks.replace(taken.roots)
        keep(taken.imported, in: file)
    }

    /// The same, worked out off the main actor: only the swap of the new
    /// top level happens here. If the person changed their bookmarks while
    /// it was being worked out, it is worked out again from theirs.
    @MainActor static func takeInBackground(_ read: Read, from source: String, into bookmarks: Bookmarks) async {
        note(read, from: source)
        let file = record(for: source)
        for _ in 0..<3 {
            let snapshot = bookmarks.roots
            let taken = await Task.detached(priority: .userInitiated) {
                taking(read, from: source, roots: snapshot, previous: owned(in: file))
            }.value
            guard bookmarks.roots == snapshot else { continue }
            bookmarks.replace(taken.roots)
            await Task.detached(priority: .utility) { keep(taken.imported, in: file) }.value
            return
        }
        take(read, from: source, into: bookmarks)
    }
}
