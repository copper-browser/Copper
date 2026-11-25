import AppKit
import Foundation
import Testing
@testable import Search

// Ardia parity, tab organisation (Fork/SavedDrop.swift `.onto`, Groups.fold,
// Fork/Cleaned.swift): a tab let go onto a tab makes a folder of the two, and
// what the sweeps take out waits a week in Recently Cleaned.

private let a = UUID(), b = UUID(), c = UUID(), work = UUID()

private func line(_ kind: SavedDrop.Line.Kind, _ top: CGFloat, depth: Int = 0, group: UUID? = nil) -> SavedDrop.Line {
    SavedDrop.Line(kind: kind, top: top, bottom: top + 37, depth: depth, group: group)
}

/// Two loose Saved rows, then an open folder with one row in it.
private let saved = SavedDrop.Layout(
    lines: [line(.tab(a), 34), line(.tab(b), 75), line(.folder(work, collapsed: false), 116), line(.tab(c), 157, depth: 1, group: work)],
    top: 32, bottom: 194, seamTop: 220, seamBottom: 257
)

private func spot(_ y: CGFloat, from: SavedDrop.Block = .today) -> SavedDrop.Spot? {
    if case .saved(let spot)? = SavedDrop.target(y: y, from: from, in: saved) { return spot }
    return nil
}

@Suite("Ardia tabs: a tab onto a tab")
struct OntoDropTests {
    @Test("The middle of a loose Saved row is the row; its top and bottom stay the gaps")
    func bands() {
        let onto = spot(52)
        #expect(onto?.anchor == .onto(a))
        #expect(onto?.group == nil)
        #expect(onto?.depth == 0)
        #expect(onto?.y == 52.5)
        #expect(spot(44)?.anchor == .before(a))    // top 30 %
        #expect(spot(64)?.anchor == .before(b))    // bottom 30 %: the gap above b
        #expect(spot(93)?.anchor == .onto(b))
    }

    @Test("A row inside a folder is never a target to fold onto")
    func notInsideFolders() {
        #expect(spot(175)?.anchor == .before(c))
        #expect(spot(178)?.anchor == .after(c))
    }

    @Test("Onto itself is its own place; onto another lands right after it")
    func ownPlaceAndIndex() throws {
        let row: [(id: Tab.ID, pinned: Bool, saved: Bool)] = [(a, false, true), (b, false, true), (c, false, true)]
        let none: (Tab.ID, UUID) -> Bool = { _, _ in false }
        let mine = try #require(spot(52, from: .saved))
        #expect(SavedDrop.stays(mine, moving: a, in: nil, row: row, inFolder: none))
        // b onto a, the row above it: it lands where it is, but the two make a folder.
        #expect(!SavedDrop.stays(mine, moving: b, in: nil, row: row, inFolder: none))
        let t = UUID()
        let today = row + [(t, false, false)]
        #expect(SavedDrop.index(for: .onto(a), moving: t, row: today, inFolder: none) == 1)
        #expect(SavedDrop.index(for: .onto(a), moving: b, row: row, inFolder: none) == 1)
        #expect(SavedDrop.index(for: .onto(b), moving: a, row: row, inFolder: none) == 1)
    }

    @Test("The folder is named by the site the two share, else by both")
    func names() {
        #expect(Groups.dropName(["mail.google.com", "calendar.google.com"]) == "Google")
        #expect(Groups.dropName(["github.com", "linear.app"]) == "Github & Linear")
        #expect(Groups.dropName(["www.github.com", ""]) == "Github")
        #expect(Groups.dropName(["", ""]) == "New Folder")
    }

    @Test("Folding makes one new folder holding both")
    @MainActor
    func fold() {
        _ = NSApplication.shared
        let one = Tab(), two = Tab()
        one.restore(url: URL(string: "https://mail.google.com/mail/u/0/")!, title: "Inbox")
        two.restore(url: URL(string: "https://calendar.google.com/")!, title: "Calendar")
        let groups = Groups.shared
        let before = groups.all.count
        let folder = groups.fold(two, onto: one)
        defer { groups.dissolve(folder.id) }
        #expect(groups.all.count == before + 1)
        #expect(folder.name == "Google")
        #expect(folder.hue == nil)
        #expect(groups.membership[one.id] == folder.id)
        #expect(groups.membership[two.id] == folder.id)
        #expect(Sections.shared.isSaved(two))
    }
}

@Suite("Ardia tabs: Recently Cleaned")
struct CleanedTests {
    let home = UUID(), work = UUID()
    let now = Date()

    func entry(_ path: String, _ hoursAgo: Double, space: UUID? = nil) -> CleanedEntry {
        CleanedEntry(url: URL(string: "https://example.com/\(path)")!, title: path, space: space ?? home,
                     when: now.addingTimeInterval(-hoursAgo * 3600))
    }

    @Test("A week, then it goes; oldest first")
    func week() {
        let kept = Cleaned.pruned([entry("new", 1), entry("old", 24 * 7 + 1), entry("mid", 24 * 6)], now: now)
        #expect(kept.map(\.title) == ["mid", "new"])
    }

    @Test("One entry a page a space, the newest")
    func onePerPage() {
        let kept = Cleaned.pruned([entry("a", 5), entry("a", 1), entry("a", 3, space: work)], now: now)
        #expect(kept.count == 2)
        #expect(kept.first { $0.space == home }?.when == now.addingTimeInterval(-3600))
    }

    @Test("At most 100 a space, the newest; another space keeps its own")
    func hundred() {
        let many = (0..<130).map { entry("p\($0)", Double($0) / 10) }
        let kept = Cleaned.pruned(many + [entry("w", 50, space: work)], now: now)
        #expect(kept.filter { $0.space == home }.count == Cleaned.most)
        #expect(kept.contains { $0.title == "p0" })
        #expect(!kept.contains { $0.title == "p100" })
        #expect(kept.contains { $0.space == work })
    }

    @Test("A private tab never goes in; Undo's drop takes entries back out")
    @MainActor
    func addAndDrop() {
        _ = NSApplication.shared
        let space = UUID()
        let open = Tab(), shy = Tab(shy: true)
        open.restore(url: URL(string: "https://example.com/open-\(space)")!, title: "Open")
        shy.restore(url: URL(string: "https://example.com/shy-\(space)")!, title: "Shy")
        let cleaned = Cleaned.shared
        let ids = cleaned.add([open, shy], space: space)
        #expect(ids.count == 1)
        #expect(cleaned.list(in: space).map(\.title) == ["Open"])
        cleaned.drop(ids)
        #expect(cleaned.list(in: space).isEmpty)
    }
}
