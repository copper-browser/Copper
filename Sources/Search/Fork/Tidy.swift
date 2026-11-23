import AppKit
import SwiftUI

// Tidy: the loose tabs of the space in front, filed into a few named folders
// in one click, with Undo right after (Ask's "Tidy" on the divider).
//
// No storage of its own. The tabs it takes are the ones Clear would take
// (`ClearTabs.clearable`: unpinned, unsaved, in no folder), and filing is
// `Groups.assign`, so a tidied tab is a Saved row in a folder like any
// other. Which folder: the configured model, shown each tab's title and host
// (never the page), names a few and may reuse a folder this space already
// has; without a model, or when it fails or is slow, tabs are filed by site,
// two or more to a folder. A tab that fits nowhere stays loose.

/// The pure half: what the model is asked, how its answer is read, the
/// by-site fallback and the row Undo puts back. No tabs, no windows.
enum TidyPlan {
    struct Folder: Equatable {
        var name: String
        /// Indexes into the tabs the plan was made for.
        var tabs: [Int]
    }

    /// A tab's host as the model and the fallback see it: lowercased, no `www.`.
    static func host(_ url: URL?) -> String {
        guard var host = url?.host()?.lowercased() else { return "" }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    static let instructions = """
    You file a person's open browser tabs into a few sidebar folders. You get JSON: "existing" (folder names \
    this space already has) and "tabs" (each with "i", "title", "host"). Answer with JSON only, no prose: \
    {"folders":[{"name":"Folder name","tabs":[0,2]}]}. Rules: 2 to 5 folders; a name is 1 to 3 plain words \
    in Title Case, no emoji; use an existing folder's exact name when tabs fit it; a new folder needs at least \
    2 tabs; a tab goes in at most one folder; leave out tabs that fit no folder well. Group by what the tabs \
    are for (a project, a topic, a task), not only by site.
    """

    /// The question: titles (cut to 100 characters) and hosts, nothing else.
    static func question(titles: [String], hosts: [String], existing: [String]) -> String {
        let tabs: [[String: Any]] = zip(titles, hosts).enumerated().map { i, pair in
            ["i": i, "title": String(pair.0.prefix(100)), "host": pair.1]
        }
        let body: [String: Any] = ["existing": existing, "tabs": tabs]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// An existing folder the name means: the whole path or its last part,
    /// any case.
    static func reuse(_ name: String, _ existing: [String]) -> String? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        return existing.first { $0.lowercased() == key } ?? existing.first { Folders.leaf($0).lowercased() == key }
    }

    /// A new folder's name: one line, at most 32 characters, and no ` › `,
    /// which would make it a folder inside another (Fork/Folders.swift).
    static func clean(_ name: String) -> String {
        let flat = name.replacingOccurrences(of: "›", with: "-")
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        return String(flat.prefix(32)).trimmingCharacters(in: .whitespaces)
    }

    /// The model's answer, read strictly: indexes in range and each used
    /// once, a new folder only with two tabs or more (an existing one takes
    /// one), at most six folders. Anything else is left out.
    static func parse(_ json: [String: Any], count: Int, existing: [String]) -> [Folder] {
        guard let raw = json["folders"] as? [[String: Any]] else { return [] }
        var used: Set<Int> = []
        var out: [Folder] = []
        for entry in raw {
            guard let said = entry["name"] as? String else { continue }
            let old = reuse(said, existing)
            let name = old ?? clean(said)
            guard !name.isEmpty else { continue }
            var tabs: [Int] = []
            for value in entry["tabs"] as? [Any] ?? [] {
                guard let i = (value as? NSNumber)?.intValue, (0..<count).contains(i),
                      !used.contains(i), !tabs.contains(i) else { continue }
                tabs.append(i)
            }
            if let same = out.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
                out[same].tabs += tabs
                used.formUnion(tabs)
                continue
            }
            guard tabs.count >= (old == nil ? 2 : 1), out.count < 6 else { continue }
            used.formUnion(tabs)
            out.append(Folder(name: name, tabs: tabs))
        }
        return out
    }

    /// No model: one folder per site with two tabs or more, named by the
    /// site (`Fork.brand`) or by the existing folder of that name.
    static func bySite(hosts: [String], existing: [String], least: Int = 2) -> [Folder] {
        var order: [String] = []
        var buckets: [String: [Int]] = [:]
        for (i, host) in hosts.enumerated() where !host.isEmpty {
            let name = Fork.brand(host)
            if buckets[name] == nil { order.append(name) }
            buckets[name, default: []].append(i)
        }
        return order.compactMap { name in
            guard let tabs = buckets[name], tabs.count >= least else { return nil }
            return Folder(name: reuse(name, existing) ?? name, tabs: tabs)
        }
    }

    /// The row as it was: `now` without the moved ids, each put back at its
    /// old index, lowest first. Exactly the old row when nothing else moved;
    /// a tab closed since is skipped, and one opened since keeps its place
    /// among the others.
    static func restored<ID: Equatable>(_ now: [ID], moved: [(id: ID, at: Int)]) -> [ID] {
        var row = now.filter { id in !moved.contains { $0.id == id } }
        for m in moved.sorted(by: { $0.at < $1.at }) where now.contains(m.id) {
            row.insert(m.id, at: min(m.at, row.count))
        }
        return row
    }
}

@MainActor
final class Tidy: ObservableObject {
    static let shared = Tidy()

    /// The divider offers Tidy from this many loose tabs.
    static let least = 3
    /// The model's whole budget, after which the tabs are filed by site.
    nonisolated static let patience: Double = 8

    /// Windows whose tidy is waiting on the model.
    @Published private(set) var working: Set<ObjectIdentifier> = []
    /// Bumped (inside an animation) whenever an Undo comes or goes.
    @Published private(set) var generation = 0

    private struct Undo {
        let moved: [(id: Tab.ID, at: Int)]
        /// Folders this tidy made, and existing ones it opened.
        let made: [UUID]
        let opened: [UUID]
        let space: UUID
        let folders: Int
        let expires: Date
    }

    private var undos: [ObjectIdentifier: Undo] = [:]
    private var expiry: [ObjectIdentifier: DispatchWorkItem] = [:]

    private var motion: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : Motion.glide
    }

    func candidates(in browser: Browser) -> [Tab] { ClearTabs.shared.clearable(in: browser) }

    /// The space's folders a tidy may reuse: those with a tab in this row
    /// and its empty top-level ones.
    private func folders(in browser: Browser, space: UUID) -> [TabGroup] {
        let groups = Groups.shared
        return groups.present(in: browser.tabs) + groups.homeless(in: space)
    }

    func undoLine(in browser: Browser) -> (tabs: Int, folders: Int)? {
        guard let undo = undos[ObjectIdentifier(browser)], undo.expires > Date() else { return nil }
        return (undo.moved.count, undo.folders)
    }

    /// File the loose tabs. `local` skips the model (the bench's by-site
    /// check). Answers what it did, for the bench.
    @discardableResult
    func tidy(in browser: Browser, local: Bool = false) async -> [String: Any] {
        let key = ObjectIdentifier(browser)
        guard !working.contains(key) else { return ["tidied": 0, "error": "already tidying"] }
        let tabs = candidates(in: browser)
        guard tabs.count >= 2 else { return ["tidied": 0] }
        working.insert(key)
        defer { working.remove(key) }
        let space = Spaces.shared.current(in: browser)
        let existing = folders(in: browser, space: space).map(\.name)
        let hosts = tabs.map { TidyPlan.host($0.address) }
        var plan: [TidyPlan.Folder] = []
        var by = "site"
        let intelligence = Intelligence.shared
        if !local, intelligence.modelReady {
            let keys = intelligence.effective
            let model = keys.textModel.isEmpty ? nil : keys.textModel
            let user = TidyPlan.question(titles: tabs.map(\.title), hosts: hosts, existing: existing)
            if let text = await Tidy.ask(user, keys: keys, model: model) {
                plan = TidyPlan.parse(Router.json(in: text), count: tabs.count, existing: existing)
                if !plan.isEmpty { by = "model" }
            }
        }
        if plan.isEmpty { plan = TidyPlan.bySite(hosts: hosts, existing: existing) }
        // The row may have moved on while the model thought: only tabs that
        // are still loose here are filed.
        guard Spaces.shared.current(in: browser) == space else { return ["tidied": 0, "error": "the space changed"] }
        let still = Set(candidates(in: browser).map(\.id))
        let filed = plan.map { folder in (name: folder.name, tabs: folder.tabs.map { tabs[$0] }.filter { still.contains($0.id) }) }
            .filter { !$0.tabs.isEmpty }
        let count = apply(filed, in: browser, space: space)
        let said: [[String: Any]] = filed.map { folder in
            ["name": folder.name, "tabs": folder.tabs.map { String($0.id.uuidString.prefix(8)).lowercased() }]
        }
        return ["tidied": count, "by": by, "folders": said]
    }

    /// One model call with a hard budget: the reply's text, or nil when it
    /// failed or took longer than `patience`.
    private nonisolated static func ask(_ user: String, keys: Intelligence.Keys, model: String?) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                try? await Router.ask(system: TidyPlan.instructions, user: user, keys: keys,
                                      timeout: patience, maxTokens: 600, model: model).text
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(patience * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func apply(_ plan: [(name: String, tabs: [Tab])], in browser: Browser, space: UUID) -> Int {
        guard !plan.isEmpty else { return 0 }
        let key = ObjectIdentifier(browser)
        let groups = Groups.shared
        let sections = Sections.shared
        let order = browser.tabs.map(\.id)
        let mine = folders(in: browser, space: space)
        var moved: [(id: Tab.ID, at: Int)] = []
        var made: [UUID] = []
        var opened: [UUID] = []
        withAnimation(motion) {
            for folder in plan {
                let group: TabGroup
                if let old = mine.first(where: { $0.name == folder.name }) {
                    group = old
                    if old.collapsed { opened.append(old.id) }
                } else {
                    // Plain, so it wears the space's colour, as Arc's folders do.
                    group = groups.adding(named: folder.name, hue: nil)
                    made.append(group.id)
                }
                for tab in folder.tabs {
                    guard let at = order.firstIndex(of: tab.id) else { continue }
                    moved.append((tab.id, at))
                    let first = !browser.tabs.contains { $0.id != tab.id && $0.pin == nil && groups.membership[$0.id] == group.id }
                    groups.assign(tab, to: group, in: browser)
                    // A folder's first tab goes to the foot of Saved, where a
                    // new folder stands; the rest follow it (`assign`).
                    if first {
                        let kept = browser.tabs.filter { $0.pin == nil && sections.isSaved($0) }.count
                        browser.move(tab, to: browser.pinnedCount + max(0, kept - 1))
                    }
                }
            }
        }
        guard !moved.isEmpty else { return 0 }
        withAnimation(Motion.settle) {
            undos[key] = Undo(moved: moved, made: made, opened: opened, space: space,
                              folders: plan.count, expires: Date().addingTimeInterval(8))
            generation += 1
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.undos[key]?.expires ?? .distantPast <= Date() else { return }
            withAnimation(Motion.settle) {
                self.undos[key] = nil
                self.generation += 1
            }
        }
        expiry[key]?.cancel()
        expiry[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
        return moved.count
    }

    /// Every tidied tab out of its folder and back where it stood, the
    /// folders it made gone and the ones it opened shut again.
    @discardableResult
    func undo(in browser: Browser) -> Int {
        let key = ObjectIdentifier(browser)
        guard let undo = undos[key], undo.expires > Date() else { return 0 }
        expiry[key]?.cancel()
        expiry[key] = nil
        if Spaces.shared.current(in: browser) != undo.space { Spaces.shared.select(undo.space, in: browser) }
        let groups = Groups.shared
        let ids = Set(undo.moved.map(\.id))
        withAnimation(motion) {
            for tab in browser.tabs where ids.contains(tab.id) { groups.remove(tab) }
            for id in undo.made where groups.members(of: id, in: browser).isEmpty { groups.dissolve(id) }
            for id in undo.opened where groups.group(id)?.collapsed == false { groups.toggleCollapsed(id) }
            // Asked for in so many words: the cloud's brake lets the unfiling through.
            CloudIntents.shared.confirm()
            let target = TidyPlan.restored(browser.tabs.map(\.id), moved: undo.moved)
            for (i, id) in target.enumerated() where i < browser.tabs.count && browser.tabs[i].id != id {
                guard let tab = browser.tabs.first(where: { $0.id == id }), tab.pin == nil else { continue }
                browser.move(tab, to: i)
            }
        }
        withAnimation(Motion.settle) {
            undos[key] = nil
            generation += 1
        }
        return undo.moved.count
    }
}

/// "Tidy" on the seam above Today: a word and a glyph, always shown while
/// there is enough to tidy, drawn in the seam's own 1 pt so nothing moves.
struct TidyButton: View {
    let browser: Browser
    let tint: SpaceTint
    @ObservedObject private var tidy = Tidy.shared
    @State private var over = false

    var body: some View {
        let busy = tidy.working.contains(ObjectIdentifier(browser))
        Button {
            Task { await tidy.tidy(in: browser) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9, weight: .semibold))
                    .symbolEffect(.pulse, isActive: busy)
                Text(busy ? "Tidying…" : "Tidy")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(over || busy ? tint.ink : tint.muted)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(over ? tint.hover : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .fixedSize()
        .onHover { over = $0 }
        .animation(Motion.quick, value: over)
        .help("Sort these tabs into folders")
        .accessibilityLabel("Tidy tabs")
        .accessibilityHint("Files loose tabs in this space into folders")
    }
}

/// The pill after a tidy, with Undo (also ⌘Z while it is up).
struct TidyToast: View {
    let browser: Browser
    @ObservedObject private var tidy = Tidy.shared

    var body: some View {
        if let line = tidy.undoLine(in: browser) {
            HStack(spacing: 10) {
                Text("Tidied \(line.tabs) tab\(line.tabs == 1 ? "" : "s") into \(line.folders) folder\(line.folders == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink)
                Button("Undo") { tidy.undo(in: browser) }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DriveStyle.accent)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background(Palette.ground, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.10), radius: 18, y: 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
