import AppKit
import SwiftUI

// Recently Cleaned (Ardia's, and Arc's archive): what the Today sweep, Clean
// Up (⌥⌘K) and Clear took out of a space, kept a week and at most 100 a
// space, so any of it comes back with a click: from the row at the foot of
// Today (Fork/CleanedUI.swift) or from ⌘K.
//
// Only what a row needs to come back: its address, title, space and when.
// Its mark is the site's, from the icon cache (`Marks`). One file,
// `cleaned.json`; private tabs never reach it. The closes themselves still go
// through `Browser.close`, so ⇧⌘T knows the last few as it always did.

struct CleanedEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: URL
    var title: String
    var space: UUID
    var when: Date

    var label: String { title.isEmpty ? Address.pretty(url) : title }
}

@MainActor
final class Cleaned: ObservableObject {
    static let shared = Cleaned()

    /// A week, then an entry goes (Ardia's and Dia's rule).
    nonisolated static let keep: TimeInterval = 7 * 24 * 3600
    /// The newest this many a space are kept.
    nonisolated static let most = 100

    /// Every space's, oldest first.
    @Published private(set) var all: [CleanedEntry] = []

    private struct File: Codable { var entries: [CleanedEntry] }
    private static var file: URL { Store.file("cleaned.json") }

    private init() {
        if let data = try? Data(contentsOf: Cleaned.file),
           let saved = try? JSONDecoder().decode(File.self, from: data) {
            all = Cleaned.pruned(saved.entries, now: Date())
        }
    }

    private func save() {
        let file = Cleaned.file
        guard let data = try? JSONEncoder().encode(File(entries: all)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// The rules, pure: nothing older than a week; one entry a page per
    /// space (the newest); the newest `most` a space. Oldest first.
    nonisolated static func pruned(_ entries: [CleanedEntry], now: Date) -> [CleanedEntry] {
        var seen: Set<String> = []
        var count: [UUID: Int] = [:]
        var kept: [CleanedEntry] = []
        for entry in entries.sorted(by: { $0.when > $1.when }) where now.timeIntervalSince(entry.when) < keep {
            guard seen.insert(entry.space.uuidString + " " + entry.url.absoluteString).inserted,
                  count[entry.space, default: 0] < most else { continue }
            count[entry.space, default: 0] += 1
            kept.append(entry)
        }
        return kept.reversed()
    }

    // MARK: - reading

    /// A space's, newest first. Entries past their week drop out here too,
    /// so a list left open across a day never shows a stale one.
    func list(in space: UUID) -> [CleanedEntry] {
        let now = Date()
        return all.reversed().filter { $0.space == space && now.timeIntervalSince($0.when) < Cleaned.keep }
    }

    // MARK: - adding

    /// For the Arc import's archived tabs (B7) as much as for the sweeps here.
    func add(_ entries: [CleanedEntry]) {
        guard !entries.isEmpty else { return }
        all = Cleaned.pruned(all + entries, now: Date())
        save()
    }

    /// Rows about to be closed, as entries of `space`. Answers the ids it
    /// made, so Clear's Undo can take them back out.
    @discardableResult
    func add(_ tabs: [Tab], space: UUID) -> Set<UUID> {
        let now = Date()
        let entries = tabs.compactMap { tab -> CleanedEntry? in
            guard !tab.shy, let url = tab.address ?? tab.pending else { return nil }
            return CleanedEntry(url: url, title: tab.title, space: space, when: now)
        }
        add(entries)
        return Set(entries.map(\.id))
    }

    func drop(_ ids: Set<UUID>) {
        guard all.contains(where: { ids.contains($0.id) }) else { return }
        all.removeAll { ids.contains($0.id) }
        save()
    }

    // MARK: - bringing back

    /// Back as Today rows at the top of Today, newest first, asleep until
    /// looked at — in their own space (switched to first) if it is still
    /// there, else in the one on screen. `select` goes to the first.
    @discardableResult
    func restore(_ entries: [CleanedEntry], in browser: Browser, select: Bool) -> [Tab] {
        guard let first = entries.first else { return [] }
        let spaces = Spaces.shared
        if first.space != spaces.current(in: browser), spaces.all.contains(where: { $0.id == first.space }) {
            spaces.select(first.space, in: browser)
        }
        let back = entries.filter { $0.space == first.space }
        let sections = Sections.shared
        let now = Date().timeIntervalSince1970
        let made = back.map { entry -> Tab in
            let tab = Tab()
            browser.prepare(tab)
            tab.restore(url: entry.url, title: entry.title)
            sections.restore(tab, saved: false, seen: now) // known, so `arrived` leaves its place alone
            return tab
        }
        var row = browser.tabs
        let top = browser.pinnedCount + row.filter { $0.pin == nil && sections.isSaved($0) }.count
        row.insert(contentsOf: made, at: min(top, row.count))
        browser.tabs = row
        Marks.warm(made)
        drop(Set(back.map(\.id)))
        if select, let tab = made.first { browser.select(tab) }
        return made
    }

    /// ⌥⌘K, Clean Up (Ardia's key): the Today sweep now, against the archive
    /// window, or Ardia's 12 hours while that is Never.
    @discardableResult
    func cleanUp(in browser: Browser) -> Int {
        let sections = Sections.shared
        let n = sections.sweep(in: browser, olderThan: sections.archive.hours ?? 12)
        browser.announce(n == 0 ? "Nothing to clean up" : "Cleaned up \(n) tab\(n == 1 ? "" : "s") into Recently Cleaned")
        return n
    }

    /// ⌘K's rows: Clean Up, Restore All, and each of this space's entries.
    static func commands(_ browser: Browser) -> [CommandBar.Command] {
        let list = Cleaned.shared.list(in: Spaces.shared.current(in: browser))
        var out: [CommandBar.Command] = [
            .init(id: "clean-up", name: "Clean Up Tabs", glyph: "archivebox") { Cleaned.shared.cleanUp(in: $0) },
        ]
        guard !list.isEmpty else { return out }
        out.append(.init(id: "cleaned-all", name: "Restore All Recently Cleaned (\(list.count))", glyph: "arrow.uturn.backward") { b in
            Cleaned.shared.restore(Cleaned.shared.list(in: Spaces.shared.current(in: b)), in: b, select: false)
        })
        for entry in list {
            out.append(.init(id: "cleaned-\(entry.id)", name: "Recently Cleaned · \(entry.label)", glyph: "archivebox") { b in
                Cleaned.shared.restore([entry], in: b, select: true)
            })
        }
        return out
    }

    // MARK: - the bench

    /// The space on screen's entries, for every `./bench sections` answer.
    func describe(in browser: Browser) -> [[String: Any]] {
        list(in: Spaces.shared.current(in: browser)).map { entry in
            ["id": String(entry.id.uuidString.prefix(8)).lowercased(), "title": entry.title,
             "url": entry.url.absoluteString, "minutes": Int(Date().timeIntervalSince(entry.when) / 60)]
        }
    }

    /// `sections cleaned PATH [dark]`: the list as its popover draws it, off
    /// screen, to a PNG (the popover itself is a window a probe can't picture).
    func bench(picture path: String, dark: Bool, in browser: Browser) -> [String: Any] {
        let host = NSHostingView(rootView: CleanedList(browser: browser) {}
            .background(Palette.ground)
            .environment(\.colorScheme, dark ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return ["error": "no picture"] }
        host.cacheDisplay(in: host.bounds, to: picture)
        guard let png = picture.representation(using: .png, properties: [:]) else { return ["error": "no png"] }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { return ["error": "\(error)"] }
        return ["path": path]
    }

    /// `sections restore ID|all`.
    func bench(restore key: String, in browser: Browser) -> [String: Any] {
        let list = list(in: Spaces.shared.current(in: browser))
        let chosen = key == "all" ? list : list.filter { $0.id.uuidString.lowercased().hasPrefix(key.lowercased()) }
        guard !chosen.isEmpty, !key.isEmpty else { return ["error": "no cleaned entry \(key)"] }
        let made = restore(chosen, in: browser, select: key != "all")
        return ["restored": made.map { String($0.id.uuidString.prefix(8)).lowercased() }]
    }
}
