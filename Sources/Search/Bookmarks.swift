import AppKit
import SwiftUI

// Bookmarks: folders and sites, kept in a small file.
//
// Shown as the app's own kind of list rather than a system menu, on purpose:
// a menu can't be dragged into, and can't be asked a second thing by
// right-clicking it. A folder you actually keep things in wants both.

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    /// Nil for a folder.
    var url: String?
    var children: [Bookmark]?

    var isFolder: Bool { url == nil }

    var host: String? {
        url.flatMap { URL(string: $0)?.host()?.lowercased() }
    }

    static func site(_ title: String, _ url: URL) -> Bookmark {
        Bookmark(title: title.isEmpty ? Address.pretty(url) : title, url: url.absoluteString, children: nil)
    }

    static func folder(_ title: String, _ children: [Bookmark]) -> Bookmark {
        Bookmark(title: title, url: nil, children: children)
    }
}

@MainActor
final class Bookmarks: ObservableObject {
    @Published private(set) var roots: [Bookmark] = []

    init() { load() }

    var isEmpty: Bool { roots.isEmpty }

    /// How many sites, folders included.
    var count: Int { Bookmarks.count(roots) }

    static func count(_ nodes: [Bookmark]) -> Int {
        nodes.reduce(0) { $0 + ($1.isFolder ? count($1.children ?? []) : 1) }
    }

    /// Every site in the list, in order, folders opened.
    static func urls(_ nodes: [Bookmark]) -> [URL] {
        nodes.flatMap { node -> [URL] in
            if node.isFolder { return urls(node.children ?? []) }
            return node.url.flatMap(URL.init(string:)).map { [$0] } ?? []
        }
    }

    /// Fork (ui-system): every site whose title or address has `query` in
    /// it, folders opened, in order — the panel's search.
    static func matching(_ query: String, in nodes: [Bookmark]) -> [Bookmark] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return nodes.flatMap { node -> [Bookmark] in
            if node.isFolder { return matching(needle, in: node.children ?? []) }
            return needle.isEmpty || node.title.lowercased().contains(needle) || (node.url ?? "").lowercased().contains(needle) ? [node] : []
        }
    }

    /// Every folder in the tree, each with how deep it sits — for "move to
    /// folder" lists, where a folder three deep should look like it.
    static func folders(_ nodes: [Bookmark], depth: Int = 0) -> [(node: Bookmark, depth: Int)] {
        nodes.flatMap { node -> [(Bookmark, Int)] in
            guard node.isFolder else { return [] }
            return [(node, depth)] + folders(node.children ?? [], depth: depth + 1)
        }
    }

    // MARK: - changing

    /// The page, at the end of the list. Nothing is asked: the title is the
    /// page's, and filing it into a folder is a drag or a right-click away.
    func add(_ url: URL, title: String) {
        guard !contains(url) else { return }
        roots.append(.site(title, url))
        save()
    }

    func contains(_ url: URL) -> Bool {
        func walk(_ nodes: [Bookmark]) -> Bool {
            nodes.contains { $0.url == url.absoluteString || walk($0.children ?? []) }
        }
        return walk(roots)
    }

    func remove(_ id: Bookmark.ID) {
        FlowBookmarks.relinquish(touching: [id], in: roots)
        roots = Bookmarks.prune(id, from: roots)
        save()
    }

    private static func prune(_ id: Bookmark.ID, from nodes: [Bookmark]) -> [Bookmark] {
        nodes.compactMap { node in
            if node.id == id { return nil }
            var copy = node
            if let kids = node.children { copy.children = prune(id, from: kids) }
            return copy
        }
    }

    /// Takes a bookmark or a whole folder out of wherever it currently sits
    /// and puts it at the end of another folder's children — or back at the
    /// top level when `folderID` is nil. Moving a folder into its own
    /// children is refused rather than allowed to erase it by looping it
    /// inside itself; moving it onto itself is simply nothing to do.
    func move(_ id: Bookmark.ID, into folderID: Bookmark.ID?) {
        guard id != folderID else { return }
        var working = roots
        guard let node = Bookmarks.detach(id, from: &working) else { return }
        if let folderID {
            guard !Bookmarks.holds(folderID, node) else { return }
            guard Bookmarks.insert(node, into: folderID, nodes: &working) else { return }
        } else {
            working.append(node)
        }
        FlowBookmarks.relinquish(touching: [id, folderID].compactMap { $0 }, in: roots)
        roots = working
        save()
    }

    private static func detach(_ id: Bookmark.ID, from nodes: inout [Bookmark]) -> Bookmark? {
        for i in nodes.indices {
            if nodes[i].id == id { return nodes.remove(at: i) }
            guard nodes[i].children != nil else { continue }
            var kids = nodes[i].children!
            if let found = detach(id, from: &kids) {
                nodes[i].children = kids
                return found
            }
        }
        return nil
    }

    @discardableResult
    private static func insert(_ node: Bookmark, into id: Bookmark.ID, nodes: inout [Bookmark]) -> Bool {
        for i in nodes.indices {
            if nodes[i].id == id, nodes[i].isFolder {
                nodes[i].children = (nodes[i].children ?? []) + [node]
                return true
            }
            guard nodes[i].children != nil else { continue }
            var kids = nodes[i].children!
            if insert(node, into: id, nodes: &kids) {
                nodes[i].children = kids
                return true
            }
        }
        return false
    }

    /// `id` is `node` itself, or somewhere inside it — also used by the
    /// outline to keep a folder out of its own "move to" list.
    fileprivate static func holds(_ id: Bookmark.ID, _ node: Bookmark) -> Bool {
        node.id == id || (node.children ?? []).contains { holds(id, $0) }
    }

    /// Another browser's, with the bar at the top level and source-owned
    /// roots replaced on repeat imports, without touching personal bookmarks.
    func take(_ read: FlowBookmarks.Read, from name: String) {
        FlowBookmarks.take(read, from: name, into: self)
    }

    /// Fork (cloud): the whole tree at once, ids kept — Copper Cloud's merged
    /// copy (Fork/Cloud/CloudApply.swift). One save: a run of removes and
    /// inserts is a run of snapshots racing to the file on a concurrent queue.
    func replace(_ nodes: [Bookmark]) {
        roots = nodes
        save()
    }

    // MARK: - the file

    private static var file: URL { Store.file("bookmarks.json") }

    // MARK: - for extensions

    /// A page or a folder filed under `parent`, or at the top level for nil
    /// or a folder that isn't there. What chrome.bookmarks.create does.
    @discardableResult
    func insert(_ node: Bookmark, into parent: Bookmark.ID?) -> Bookmark {
        if let parent {
            var nodes = roots
            if Bookmarks.insert(node, into: parent, nodes: &nodes) {
                FlowBookmarks.relinquish(touching: [parent], in: roots)
                roots = nodes
                save()
                return node
            }
        }
        roots.append(node)
        save()
        return node
    }

    /// A new title or address for one that is kept. chrome.bookmarks.update.
    func update(_ id: Bookmark.ID, title: String?, url: String?) {
        func walk(_ nodes: inout [Bookmark]) -> Bool {
            for i in nodes.indices {
                if nodes[i].id == id {
                    if let title { nodes[i].title = title }
                    if let url, !nodes[i].isFolder { nodes[i].url = url }
                    return true
                }
                guard var kids = nodes[i].children else { continue }
                if walk(&kids) {
                    nodes[i].children = kids
                    return true
                }
            }
            return false
        }
        var nodes = roots
        if walk(&nodes) {
            FlowBookmarks.relinquish(touching: [id], in: roots)
            roots = nodes
            save()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Bookmarks.file) else { return }
        guard let list = try? JSONDecoder().decode([Bookmark].self, from: data) else {
            Store.quarantine(Bookmarks.file)
            return
        }
        roots = list
    }

    private func save() {
        let snapshot = roots
        let file = Bookmarks.file
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}

// MARK: - the tree, drawn

/// The list itself: folders that open in place rather than to the side, each
/// row draggable into another folder or back out to the top, each row good
/// for a right-click too. Used both in the small dropdown off the button and
/// in the full manager — the interaction is the same size either way.
struct BookmarkOutline: View {
    @ObservedObject var bookmarks: Bookmarks
    /// Fork (ui-system): non-empty, the matching sites flat, folders opened.
    var query = ""
    let open: (URL) -> Void

    @State private var expanded: Set<Bookmark.ID> = []
    @State private var dragging: Bookmark.ID?
    @State private var overRoot = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            rows(query.isEmpty ? bookmarks.roots : Bookmarks.matching(query, in: bookmarks.roots), depth: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(overRoot ? Palette.wash : .clear)
        .onDrop(of: [.text], isTargeted: $overRoot) { providers in drop(providers, into: nil) }
    }

    @ViewBuilder
    private func rows(_ nodes: [Bookmark], depth: Int) -> some View {
        ForEach(nodes) { node in
            Row(
                node: node,
                depth: depth,
                open: node.isFolder ? nil : { open(URL(string: node.url!)!) },
                isOpen: expanded.contains(node.id),
                dragging: dragging == node.id,
                toggle: node.isFolder ? { toggle(node.id) } : nil,
                moveTargets: Bookmarks.folders(bookmarks.roots).filter { !Bookmarks.holds($0.node.id, node) },
                moveTo: { bookmarks.move(node.id, into: $0) },
                remove: { bookmarks.remove(node.id) }
            )
            .onDrag {
                dragging = node.id
                return NSItemProvider(object: node.id.uuidString as NSString)
            }
            .modifier(DropOnto(active: node.isFolder) { providers in drop(providers, into: node.id) })

            if node.isFolder, expanded.contains(node.id) {
                if let kids = node.children, !kids.isEmpty {
                    // Type-erased: a view that calls itself can't let Swift
                    // infer its own opaque return type from its own body.
                    AnyView(rows(kids, depth: depth + 1))
                } else {
                    Text("Empty")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .padding(.leading, indent(depth + 1) + 26)
                        .padding(.vertical, 5)
                }
            }
        }
    }

    private func toggle(_ id: Bookmark.ID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func drop(_ providers: [NSItemProvider], into folderID: Bookmark.ID?) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: String.self) }) else { return false }
        _ = provider.loadObject(ofClass: String.self) { text, _ in
            guard let text, let id = UUID(uuidString: text) else { return }
            DispatchQueue.main.async {
                self.bookmarks.move(id, into: folderID)
                self.dragging = nil
            }
        }
        return true
    }

    private func indent(_ depth: Int) -> CGFloat { CGFloat(depth) * 18 }

    /// Lets a row's own onDrop only run for folders — a bookmark isn't a
    /// place to file something else into — while every row still fires the
    /// same one onDrag above.
    private struct DropOnto: ViewModifier {
        let active: Bool
        let action: ([NSItemProvider]) -> Bool
        @State private var targeted = false

        func body(content: Content) -> some View {
            if active {
                content
                    .background(targeted ? Palette.hover : .clear)
                    .onDrop(of: [.text], isTargeted: $targeted, perform: action)
            } else {
                content
            }
        }
    }

    private struct Row: View {
        let node: Bookmark
        let depth: Int
        /// Nil for a folder — folders open in place, not out to a page.
        let open: (() -> Void)?
        let isOpen: Bool
        let dragging: Bool
        let toggle: (() -> Void)?
        let moveTargets: [(node: Bookmark, depth: Int)]
        let moveTo: (Bookmark.ID?) -> Void
        let remove: () -> Void

        @State private var hovering = false

        var body: some View {
            HStack(spacing: 8) {
                if node.isFolder {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.faint)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 10)
                    Mark(icon: nil, letter: "", size: 15)
                        .overlay(
                            Image(systemName: "folder.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Palette.muted)
                        )
                } else {
                    Spacer().frame(width: 10)
                    Mark(icon: Favicons.shared.cached(node.host ?? ""), letter: String((node.host ?? "•").prefix(1)).uppercased(), size: 15)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    // Fork (ui-system): where it goes, under what it's called.
                    if let host = node.host, host != node.title.lowercased() {
                        Text(host)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if node.isFolder, let kids = node.children, !kids.isEmpty {
                    Text("\(Bookmarks.count(kids))")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(.leading, CGFloat(depth) * 18 + 10)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.wash : .clear))
            .contentShape(Rectangle())
            .opacity(dragging ? 0.35 : 1)
            .onTapGesture { open?() ?? toggle?() }
            .onHover { hovering = $0 }
            .contextMenu {
                if let open {
                    Button("Open", action: open)
                    Divider()
                }
                Menu("Move to") {
                    Button("Top Level", action: { moveTo(nil) })
                    if !moveTargets.isEmpty {
                        Divider()
                        ForEach(moveTargets, id: \.node.id) { target in
                            Button(String(repeating: "   ", count: target.depth) + target.node.title) {
                                moveTo(target.node.id)
                            }
                        }
                    }
                }
                Divider()
                Button("Remove", role: .destructive, action: remove)
            }
            .animation(Motion.quick, value: hovering)
            .animation(Motion.quick, value: dragging)
        }
    }
}

/// The button's dropdown: the tree, and the two things that aren't in it.
struct BookmarksDropdown: View {
    @ObservedObject var browser: Browser
    @ObservedObject var bookmarks: Bookmarks

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if bookmarks.isEmpty {
                Text("No bookmarks yet")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .padding(14)
            } else {
                ScrollView {
                    BookmarkOutline(bookmarks: bookmarks) { url in
                        browser.bookmarking = false
                        browser.visit(url)
                    }
                    .padding(6)
                }
                .frame(maxHeight: 360)
            }
            Divider().overlay(Palette.hairline)
            VStack(spacing: 1) {
                Foot("bookmark", "Add This Page") { browser.bookmarkCurrent() }
                Foot(nil, "Manage Bookmarks…") { browser.bookmarking = true }
            }
            .padding(6)
        }
        .frame(width: 280)
        .background(Palette.ground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private struct Foot: View {
        let symbol: String?
        let title: String
        let act: () -> Void
        @State private var hovering = false

        init(_ symbol: String?, _ title: String, act: @escaping () -> Void) {
            self.symbol = symbol
            self.title = title
            self.act = act
        }

        var body: some View {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Palette.muted).frame(width: 14)
                } else {
                    Spacer().frame(width: 14)
                }
                Text(title).font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.wash : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: act)
            .onHover { hovering = $0 }
        }
    }
}

/// The full list, for taking things out of it or bringing more in.
struct BookmarksPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var bookmarks: Bookmarks
    @State private var query = "" // Fork (ui-system)
    @FocusState private var hunting: Bool

    var body: some View {
        // Fork (ui-system): a search field like the other panels, a list as
        // tall as it is, and empty said as a state with the one way to fill it.
        Plate("Bookmarks", width: 600, footed: !bookmarks.isEmpty, close: { browser.bookmarking = false }) {
            if bookmarks.isEmpty {
                EmptyState("bookmark", "No bookmarks yet", "Press ⇧⌘B on any page to keep it here.") { bringIn }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Hunt(text: $query, prompt: "Search bookmarks", focus: $hunting)
                    if !query.isEmpty, Bookmarks.matching(query, in: bookmarks.roots).isEmpty {
                        EmptyState("magnifyingglass", "No matches", "No bookmark matches “\(query)”.")
                    } else {
                        Fitted {
                            Card {
                                BookmarkOutline(bookmarks: bookmarks, query: query) { url in
                                    browser.bookmarking = false
                                    browser.visit(url)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 6)
                            }
                            .padding(.bottom, 2)
                        }
                    }
                }
            }
        } foot: {
            HStack(spacing: 8) {
                bringIn
                Spacer()
                Text(bookmarks.count == 1 ? "1 bookmark" : "\(bookmarks.count) bookmarks")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
        }
        .onAppear { hunting = !bookmarks.isEmpty }
    }

    /// Only the browsers actually on this Mac.
    @ViewBuilder private var bringIn: some View {
        let sources = Chromium.installed()
        if !sources.isEmpty {
            HStack(spacing: 8) {
                Text("Bring in from")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                ForEach(sources) { source in
                    Pill(source.name) { browser.takeBookmarks(from: source) }
                }
            }
        }
    }
}
