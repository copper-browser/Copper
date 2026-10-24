import SwiftUI

// Folders, out of the groups that are already there.
//
// Arc's sidebar folders nest. Copper's groups are flat — one name, one run
// of tabs — but the name carries the nesting: `arc-import` writes a folder
// inside a folder as `Misc › BuildrFi`, and a group whose name starts with
// another group's name and the separator *is* that group's child. So the
// tree is read back out of the names rather than kept twice, and a rename
// carries its children with it (see `Groups.rename`).
//
// Nothing here owns anything. It reads a block's tabs and its groups and
// says what the column should draw, in order, with a depth on every line:
// headers for the folders, rows for the tabs, nothing at all under a folded
// folder — its children's headers included.

enum Folders {
    /// What `arc-import` puts between a folder and the one inside it.
    static let mark = " › "
    /// One step in. A tab in a top-level folder is one step; its folder's
    /// header is none; a folder inside it is one, and its tabs are two.
    static let step: CGFloat = 20

    /// `Misc › BuildrFi › Notes` → `Notes`.
    static func leaf(_ name: String) -> String {
        name.components(separatedBy: mark).last ?? name
    }

    /// Is `name` somewhere below `other`?
    static func below(_ name: String, _ other: String) -> Bool {
        name.count > other.count && name.hasPrefix(other + mark)
    }

    /// The row with every folder's tabs side by side, nesting and all, and
    /// nothing else moved: a folder's tabs follow its first one, in the order
    /// they had. The column draws a header for each run of a folder's tabs,
    /// so a folder split by other rows (an import, a hand edit, a merge)
    /// showed up two or three times. Gathering again changes nothing.
    static func gathered<T>(_ items: [T], name: (T) -> String?) -> [T] {
        func gather(_ items: [(T, [String])], depth: Int) -> [T] {
            var order: [String] = []
            var buckets: [String: [(T, [String])]] = [:]
            var out: [(one: T?, folder: String?)] = []
            for item in items {
                guard item.1.count > depth else { out.append((item.0, nil)); continue }
                let key = item.1[depth]
                if buckets[key] == nil { order.append(key); out.append((nil, key)) }
                buckets[key, default: []].append(item)
            }
            return out.flatMap { piece -> [T] in
                if let key = piece.folder { return gather(buckets[key] ?? [], depth: depth + 1) }
                return piece.one.map { [$0] } ?? []
            }
        }
        return gather(items.map { ($0, name($0)?.components(separatedBy: mark) ?? []) }, depth: 0)
    }

    /// The name a folder made inside `parent` carries.
    static func inside(_ parent: TabGroup, named name: String) -> String {
        parent.name + mark + name.trimmingCharacters(in: .whitespaces)
    }
}

/// What one block of the column draws.
enum FolderRow: Identifiable {
    /// A folder's line. `depth` is how far in it sits, `label` the part of
    /// the name below its parent, `count` the tabs it hides while folded.
    case head(TabGroup, count: Int, at: Int, depth: Int, label: String)
    /// A tab's line. `depth` is how far in it sits: 0 loose, 1 in a
    /// top-level folder, 2 in a folder inside that one.
    case tab(Tab, index: Int, group: TabGroup?, depth: Int)

    var id: String {
        switch self {
        case .head(let group, _, let at, _, _): return "head-\(group.id.uuidString)-\(at)"
        case .tab(let tab, _, _, _): return "tab-\(tab.id.uuidString)"
        }
    }

    var indent: CGFloat {
        switch self {
        case .head(_, _, _, let depth, _): return CGFloat(depth) * Folders.step
        case .tab(_, _, _, let depth): return CGFloat(depth) * Folders.step
        }
    }
}

/// The nesting the groups of one block make, worked out once per draw.
///
/// "Of one block": two spaces can both hold a folder called `Misc`, and the
/// one that matters is the one whose tabs are in front of you. Only groups
/// with a tab in these rows are nodes — plus the empty folders under them,
/// so a folder you have just made inside one has somewhere to appear before
/// it holds anything.
@MainActor
struct FolderTree {
    /// Ancestors of each node, shallowest first.
    private var above: [UUID: [TabGroup]] = [:]
    /// The tabs each node holds in this block, its own only.
    private var own: [UUID: Int] = [:]
    /// The folders inside each node, in the order their names sort.
    private var inside: [UUID: [TabGroup]] = [:]
    private(set) var nodes: [TabGroup] = []

    init(tabs: [Tab], homeless: [TabGroup] = [], groups: Groups = Groups.shared, space: UUID? = nil) {
        var here: [TabGroup] = []
        var seen: Set<UUID> = []
        for tab in tabs {
            guard let id = groups.membership[tab.id], let group = groups.group(id) else { continue }
            own[id, default: 0] += 1
            if seen.insert(id).inserted { here.append(group) }
        }
        // A folder with no tabs anywhere belongs to whichever tree claims
        // its name; one with tabs elsewhere is another space's folder and
        // has no business in this block.
        let held = Set(groups.membership.values)
        let roots = here + homeless
        let empties = groups.all.filter { group in
            !held.contains(group.id) && !homeless.contains(group)
                && (group.space == nil || group.space == (space ?? Spaces.shared.current))
                && roots.contains { Folders.below(group.name, $0.name) }
        }
        nodes = here + homeless + empties

        for node in nodes {
            let ancestors = nodes.filter { Folders.below(node.name, $0.name) }
                .sorted { $0.name.count < $1.name.count }
            above[node.id] = ancestors
            if let parent = ancestors.last {
                inside[parent.id, default: []].append(node)
            }
        }
        for key in inside.keys { inside[key]?.sort { $0.name < $1.name } }
    }

    func depth(of group: TabGroup) -> Int { above[group.id]?.count ?? 0 }

    /// What the header says: the part of the name below the deepest folder
    /// actually on screen. A child whose parent is not here keeps enough of
    /// its path to be told apart.
    func label(of group: TabGroup) -> String {
        guard let parent = above[group.id]?.last else { return group.name }
        return String(group.name.dropFirst(parent.name.count + Folders.mark.count))
    }

    /// Folded above: the folder is inside one that is shut, so neither it
    /// nor anything it holds is drawn.
    func hidden(_ group: TabGroup) -> Bool {
        above[group.id]?.contains { $0.collapsed } ?? false
    }

    /// Everything below it, its own rows and its children's — what a folded
    /// folder is holding back.
    func weight(of group: TabGroup) -> Int {
        (own[group.id] ?? 0) + (inside[group.id] ?? []).reduce(0) { $0 + weight(of: $1) }
    }

    func children(of group: TabGroup) -> [TabGroup] { inside[group.id] ?? [] }

    /// Folders inside this one with nothing in them, anywhere below. They
    /// have no run of tabs to hang a header off, so the plan puts each where
    /// its `slot` says, or at the foot of its parent.
    fileprivate func emptyChildren(of group: TabGroup) -> [TabGroup] {
        children(of: group).filter { weight(of: $0) == 0 }
    }

    fileprivate func ancestors(of group: TabGroup) -> [TabGroup] { above[group.id] ?? [] }

    /// The whole block, top to bottom. `homeless` are the space's folders
    /// that hold nothing and sit inside nothing — Arc keeps an empty folder
    /// where you made it, so it goes back where its `slot` says.
    static func plan(_ tabs: [Tab], homeless: [TabGroup] = [], groups: Groups = Groups.shared, space: UUID? = nil) -> [FolderRow] {
        let tree = FolderTree(tabs: tabs, homeless: homeless, groups: groups, space: space)
        var out: [FolderRow] = []
        // The folders whose headers are up, outermost first. Arc lets a
        // folder's tabs sit either side of a folder inside it; a run that
        // comes back to a folder still open here carries on under its
        // header rather than drawing it a second time.
        var open: [TabGroup] = []
        // Tabs so far under each open folder, and in the whole block: what
        // an empty folder's `slot` is counted against.
        var under: [UUID: Int] = [:]
        var before = 0
        var placed: Set<UUID> = []

        func head(_ group: TabGroup, at index: Int) {
            placed.insert(group.id)
            guard !tree.hidden(group) else { return }
            out.append(.head(group, count: tree.weight(of: group), at: index,
                             depth: tree.depth(of: group), label: tree.label(of: group)))
        }
        /// An empty folder, and the empty ones inside it.
        func empty(_ group: TabGroup, at index: Int) {
            head(group, at: index)
            for child in tree.emptyChildren(of: group) { empty(child, at: index) }
        }
        /// The empty folders inside `group` whose turn has come: `slot` of
        /// its tabs are down already — or, closing it, every one left, at
        /// its foot.
        func due(_ group: TabGroup, at index: Int, closing: Bool) {
            for child in tree.emptyChildren(of: group) where !placed.contains(child.id)
                && (closing || (child.slot ?? .max) <= under[group.id, default: 0]) {
                empty(child, at: index)
            }
        }
        func shut(down to: Int, at index: Int) {
            while open.count > to { due(open.removeLast(), at: index, closing: true) }
        }
        func homes(at index: Int, closing: Bool) {
            for group in homeless where tree.depth(of: group) == 0 && !placed.contains(group.id)
                && (closing || (group.slot ?? .max) <= before) {
                empty(group, at: index)
            }
        }

        for (index, tab) in tabs.enumerated() {
            let group = groups.group(of: tab)
            var keep = 0
            if let group {
                if let at = open.firstIndex(where: { $0.id == group.id }) {
                    keep = at + 1
                } else {
                    keep = open.count
                    while keep > 0, !Folders.below(group.name, open[keep - 1].name) { keep -= 1 }
                }
            }
            shut(down: keep, at: index)
            if open.isEmpty { homes(at: index, closing: false) }
            for folder in open { due(folder, at: index, closing: false) }
            if let group, open.last?.id != group.id {
                // A folder whose own parent holds no tabs of its own has had
                // no header drawn for that parent yet; draw it on the way in.
                for folder in tree.ancestors(of: group) + [group] where !open.contains(where: { $0.id == folder.id }) {
                    if let last = open.last { due(last, at: index, closing: false) }
                    open.append(folder)
                    head(folder, at: index)
                    due(folder, at: index, closing: false)
                }
            }
            for folder in open { under[folder.id, default: 0] += 1 }
            before += 1
            if let group, group.collapsed || tree.hidden(group) { continue }
            out.append(.tab(tab, index: index, group: group,
                            depth: group.map { tree.depth(of: $0) + 1 } ?? 0))
        }
        shut(down: 0, at: tabs.count)
        homes(at: tabs.count, closing: true)
        return out
    }
}
