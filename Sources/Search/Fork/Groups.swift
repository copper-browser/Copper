import SwiftUI

// Tab groups: a name and a colour over a run of tabs in the column.
//
// The row stays one flat array. A group is a label some tabs carry, kept
// here by tab id rather than on the Tab, so upstream's Tab never learns the
// word. Members are kept next to each other in the row — joining a group
// moves the tab to the end of that group's run — and the column draws one
// header wherever a run starts. Which tab is in which group travels in the
// session as one optional field on each entry (see Spaces.shape/restore).

struct TabGroup: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// A hue, 0…1, or nil for the plain grey — the same wheel as a Space.
    var hue: Double?
    var collapsed = false
    /// The space a folder belongs to while it holds nothing. A folder with
    /// tabs is wherever its tabs are; an empty one Arc brought over needs
    /// telling where to stand. Nil for everything else.
    var space: UUID? = nil
    /// Where an empty folder stands: after this many of its parent's tabs
    /// (or, at the top, of its block's). Nil is at the foot. A folder with
    /// tabs is wherever they are, and this means nothing to it.
    var slot: Int? = nil

    var tint: Color { hue.map { Color(hue: $0, saturation: 0.55, brightness: 0.75) } ?? Palette.muted }
}

@MainActor
final class Groups: ObservableObject {
    static let shared = Groups()

    @Published private(set) var all: [TabGroup] = []
    /// Which group each tab is in. Tabs that have gone are pruned as the
    /// column redraws; nothing else has to remember to tell us.
    @Published private(set) var membership: [Tab.ID: UUID] = [:]

    private struct File: Codable {
        var groups: [TabGroup]
    }

    private static var file: URL { Store.file("groups.json") }

    private init() {
        if let data = try? Data(contentsOf: Groups.file),
           let saved = try? JSONDecoder().decode(File.self, from: data) {
            all = saved.groups
        }
    }

    private func save() {
        let file = Groups.file
        guard let data = try? JSONEncoder().encode(File(groups: all)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    // MARK: - reading

    func group(_ id: UUID?) -> TabGroup? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    func group(of tab: Tab) -> TabGroup? { group(membership[tab.id]) }

    func group(named name: String) -> TabGroup? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        return all.first { $0.name.lowercased() == wanted }
    }

    /// A folder by whichever half of its name you have: the whole path
    /// (`Misc › BuildrFi`) or, when only one folder answers to it, the last
    /// part on its own (`BuildrFi`).
    func group(matching name: String) -> TabGroup? {
        if let exact = group(named: name) { return exact }
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        let leaves = all.filter { Folders.leaf($0.name).lowercased() == wanted }
        return leaves.count == 1 ? leaves[0] : nil
    }

    /// The tabs in a group, in row order, across the visible row and the
    /// parked spaces.
    func members(of id: UUID, in browser: Browser) -> [Tab] {
        (browser.tabs + Spaces.shared.parkedTabs).filter { membership[$0.id] == id }
    }

    /// The space's empty folders that sit inside no other folder: nothing
    /// holds them up in the column, so the Saved block draws them last.
    func homeless(in space: UUID) -> [TabGroup] {
        let held = Set(membership.values)
        return all.filter { group in
            group.space == space && !held.contains(group.id)
                && !all.contains { Folders.below(group.name, $0.name) }
        }
    }

    /// The groups with at least one tab in this row, in the order their
    /// first tab appears.
    func present(in tabs: [Tab]) -> [TabGroup] {
        var seen: Set<UUID> = []
        var out: [TabGroup] = []
        for tab in tabs {
            guard let id = membership[tab.id], !seen.contains(id), let group = group(id) else { continue }
            seen.insert(id)
            out.append(group)
        }
        return out
    }

    // MARK: - editing

    @discardableResult
    func create(named name: String, hue: Double? = nil) -> TabGroup {
        if let existing = group(named: name) { return existing }
        let clean = name.trimmingCharacters(in: .whitespaces)
        let group = TabGroup(name: clean.isEmpty ? "Group \(all.count + 1)" : clean, hue: hue ?? Double(all.count % 8) / 8)
        all.append(group)
        save()
        return group
    }

    /// A new folder even when one already has the name — an import's, whose
    /// folders are told apart by the space they stand in.
    func adding(named name: String, hue: Double?) -> TabGroup {
        let group = TabGroup(name: name.trimmingCharacters(in: .whitespaces), hue: hue)
        all.append(group)
        save()
        return group
    }

    /// Into the group, and next to the rest of it: the tab moves to the end
    /// of the group's run in its row, so the header covers all of them. A
    /// pinned tab keeps its place in the pin block and is only labelled.
    func assign(_ tab: Tab, to group: TabGroup, in browser: Browser) {
        guard all.contains(where: { $0.id == group.id }) else { return }
        membership[tab.id] = group.id
        if let i = all.firstIndex(where: { $0.id == group.id }), all[i].collapsed { all[i].collapsed = false; save() }
        guard tab.pin == nil, let here = browser.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        // The last member that isn't this tab, in this row.
        let others = browser.tabs.enumerated().filter { $0.element.id != tab.id && membership[$0.element.id] == group.id && $0.element.pin == nil }
        guard let last = others.last?.offset else { return }
        let target = last < here ? last + 1 : last
        if target != here { browser.move(tab, to: target) }
    }

    func remove(_ tab: Tab) {
        membership[tab.id] = nil
    }

    /// Renaming a folder renames the folders inside it, since the nesting
    /// lives in the names: `Misc` → `Odds` takes `Misc › lula` with it. Not
    /// when two folders share the name, though — then there is no telling
    /// whose children they are, and only the one folder is renamed.
    func rename(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, let i = all.firstIndex(where: { $0.id == id }) else { return }
        let was = all[i].name
        let home = all[i].space
        all[i].name = clean
        // Another space's folder of the same name is no rival: its children
        // are told apart by their space. (An unmarked folder claims them all,
        // as it always has.)
        func mine(_ g: TabGroup) -> Bool { home == nil || g.space == nil || g.space == home }
        if all.filter({ $0.name == was && mine($0) }).isEmpty {
            for j in all.indices where Folders.below(all[j].name, was) && mine(all[j]) {
                all[j].name = clean + Folders.mark + String(all[j].name.dropFirst(was.count + Folders.mark.count))
            }
        }
        save()
    }

    /// A folder inside another one, which is only a name: `<parent> › <name>`.
    /// It takes the parent's colour and the parent opens to show it.
    @discardableResult
    func createInside(_ parent: TabGroup, named name: String) -> TabGroup? {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return nil }
        // Its own folder, in the parent's space: the same path may well be
        // another space's folder already, and `create` would hand that back.
        let made = adding(named: Folders.inside(parent, named: clean), hue: parent.hue)
        if let i = all.firstIndex(where: { $0.id == made.id }) { all[i].space = parent.space ?? Spaces.shared.current; save() }
        // A folder inside a plain one is plain too: both wear the space's
        // colour, and `create` would otherwise deal it one off the wheel.
        if parent.hue == nil { tint(made.id, hue: nil) }
        if let i = all.firstIndex(where: { $0.id == parent.id }), all[i].collapsed {
            all[i].collapsed = false
            save()
        }
        return group(made.id) ?? made
    }

    func tint(_ id: UUID, hue: Double?) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].hue = hue
        save()
    }

    /// An imported folder's state: open or shut, and the space and place it
    /// stands in while it holds nothing.
    func imported(_ id: UUID, collapsed: Bool, space: UUID?, slot: Int?) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].collapsed = collapsed
        all[i].space = space
        all[i].slot = slot
        save()
    }

    func toggleCollapsed(_ id: UUID) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].collapsed.toggle()
        save()
    }

    /// The label goes; the tabs stay where they are.
    func dissolve(_ id: UUID) {
        membership = membership.filter { $0.value != id }
        all.removeAll { $0.id == id }
        save()
    }

    /// Every tab in it closes, and then the group. On purpose, from the
    /// folder's menu: they leave Saved rather than being put down.
    func closeAll(_ id: UUID, in browser: Browser) {
        for tab in members(of: id, in: browser) where browser.tabs.contains(where: { $0.id == tab.id }) {
            Sections.shared.remove(tab, in: browser)
        }
        dissolve(id)
    }

    /// After a drag: between two tabs of one group means in it; out on your
    /// own means out of it.
    func settle(_ tab: Tab, in browser: Browser) {
        let loose = browser.tabs.filter { $0.pin == nil }
        guard let here = loose.firstIndex(where: { $0.id == tab.id }) else { return }
        let before = here > 0 ? membership[loose[here - 1].id] : nil
        let after = here + 1 < loose.count ? membership[loose[here + 1].id] : nil
        let mine = membership[tab.id]
        if let before, before == after, before != mine {
            membership[tab.id] = before
        } else if let mine, before != mine, after != mine {
            membership[tab.id] = nil
        }
    }

    /// Restoring a session: the entry said which group; the group has to
    /// still exist to count.
    func restore(_ tab: Tab, group id: UUID?) {
        guard let id, all.contains(where: { $0.id == id }) else { return }
        membership[tab.id] = id
    }

    // MARK: - Copper Cloud

    /// The folders another device sent (`CloudDocs.Folder`): each added or
    /// edited by id, and those the document dropped since the last sync
    /// dissolved — their tabs stay, unfiled. Open or shut stays this Mac's;
    /// a folder new here arrives shut, as an import's do.
    func cloudAdopt(_ folders: [CloudDocs.Folder], removed: Set<UUID>) {
        var next: [TabGroup] = []
        for f in folders {
            var g = all.first(where: { $0.id == f.id }) ?? TabGroup(id: f.id, name: f.name, hue: f.hue, collapsed: true)
            g.name = f.name
            g.hue = f.hue
            g.space = f.space
            g.slot = f.slot
            next.append(g)
        }
        // Folders only this Mac has (made since the sync) keep their place at the end.
        let sent = Set(folders.map(\.id))
        next += all.filter { !sent.contains($0.id) && !removed.contains($0.id) }
        guard next != all else { return }
        membership = membership.filter { !removed.contains($0.value) }
        all = next
        save()
    }

    /// File a kept tab where the document has it (nil: in no folder).
    func cloudFile(_ tab: Tab, in id: UUID?) {
        guard membership[tab.id] != id else { return }
        if let id, !all.contains(where: { $0.id == id }) { return }
        membership[tab.id] = id
    }

    /// Tabs that no longer exist anywhere drop out of the map.
    func prune(keeping tabs: [Tab]) {
        let alive = Set(tabs.map(\.id))
        let stale = membership.keys.filter { !alive.contains($0) }
        guard !stale.isEmpty else { return }
        for id in stale { membership[id] = nil }
    }

    // MARK: - the bench

    /// `./bench groups` lists; `groups new NAME`; `groups assign TAB NAME`;
    /// `groups remove TAB`; `groups dissolve NAME`;
    /// `groups toggle NAME` folds or opens a folder; `groups inside PARENT
    /// NAME` makes one inside another.
    func bench(_ request: [String: Any], in browser: Browser) -> [String: Any] {
        let arg = request["arg"] as? String ?? ""
        let words = arg.split(separator: " ", maxSplits: 1).map(String.init)
        func tab(_ key: String) -> Tab? { browser.tabs.first { $0.id.uuidString.lowercased().hasPrefix(key.lowercased()) } }
        switch request["op"] as? String ?? "" {
        case "new": create(named: arg)
        case "assign":
            guard words.count == 2, let t = tab(words[0]) else { return ["error": "assign TAB NAME"] }
            assign(t, to: create(named: words[1]), in: browser)
        case "remove":
            guard let t = tab(arg) else { return ["error": "no tab \(arg)"] }
            remove(t)
        case "dissolve":
            guard let g = group(matching: arg) else { return ["error": "no group \(arg)"] }
            dissolve(g.id)
        case "toggle":
            // `groups toggle Misc` shuts or opens a folder, by its whole
            // name or by its last part when that is unambiguous.
            guard let g = group(matching: arg) else { return ["error": "no folder \(arg)"] }
            toggleCollapsed(g.id)
        case "inside":
            guard words.count == 2, let parent = group(matching: words[0]) else { return ["error": "inside PARENT NAME"] }
            createInside(parent, named: words[1])
        case "plan":
            // `groups plan` draws the Saved block as text, one line a row,
            // two spaces a step in — what the column shows, shut folders
            // and all. `groups plan today` draws the other block.
            let today = arg == "today"
            let loose = browser.tabs.filter { $0.pin == nil && Sections.shared.isSaved($0) != today }
            let rows = FolderTree.plan(loose, homeless: today ? [] : homeless(in: Spaces.shared.current(in: browser)), groups: self, space: Spaces.shared.current(in: browser))
            let lines: [String] = rows.map { row in
                switch row {
                case .head(let g, let count, _, let depth, let label):
                    return String(repeating: "  ", count: depth) + (g.collapsed ? "▸ " : "▾ ") + label + (g.collapsed ? " (\(count))" : "")
                case .tab(let tab, _, _, let depth):
                    return String(repeating: "  ", count: depth) + "· " + tab.title
                }
            }
            return ["plan": lines, "split": Split.shared.side.map { String($0.uuidString.prefix(8)).lowercased() } ?? "",
                    "pairs": Split.shared.pairs.count / 2]
        case "list": break
        default: return ["error": "unknown groups operation \(request["op"] as? String ?? "")"]
        }
        let rows: [[String: Any]] = all.map { g in
            ["id": String(g.id.uuidString.prefix(8)).lowercased(), "name": g.name,
             "label": Folders.leaf(g.name), "collapsed": g.collapsed,
             "tabs": members(of: g.id, in: browser).map { String($0.id.uuidString.prefix(8)).lowercased() }]
        }
        return ["groups": rows]
    }
}
