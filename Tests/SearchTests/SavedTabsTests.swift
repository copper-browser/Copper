import AppKit
import Foundation
import Testing
@testable import Search

// Saved tabs, Arc's way (Fork/Sections.swift, Fork/SavedDrop.swift): a close
// puts a Saved row down and only its cross takes it out — in the session, in
// Copper Cloud's kept-tabs document, and in Reopen Closed Tab — and where a
// row dragged over the column would land.

// MARK: - where a drop lands

/// Saved as the column lays it out, in the column's own space: the space's
/// name, two loose rows, an open folder of two, the hairline, New Tab, Today.
private let a = UUID(), b = UUID(), c = UUID(), d = UUID(), work = UUID()

private func line(_ kind: SavedDrop.Line.Kind, _ top: CGFloat, depth: Int = 0, group: UUID? = nil) -> SavedDrop.Line {
    SavedDrop.Line(kind: kind, top: top, bottom: top + 37, depth: depth, group: group)
}

private let saved = SavedDrop.Layout(
    lines: [
        line(.tab(a), 34),
        line(.tab(b), 75),
        line(.folder(work, collapsed: false), 116),
        line(.tab(c), 157, depth: 1, group: work),
        line(.tab(d), 198, depth: 1, group: work),
    ],
    top: 32, bottom: 235, seamTop: 260, seamBottom: 297
)

private func spot(_ target: SavedDrop.Target?) -> SavedDrop.Spot? {
    if case .saved(let spot)? = target { return spot }
    return nil
}

@Suite("Saved: where a drop lands")
struct SavedDropTargetTests {
    @Test("A Today row is over Saved the moment the pointer is over New Tab, and not before")
    func todayCrossesAtTheSeam() {
        #expect(SavedDrop.target(y: 320, from: .today, in: saved) == nil)
        #expect(SavedDrop.target(y: 298, from: .today, in: saved) == nil)
        // A short drag: from the first Today row's middle (≈ 319) to the
        // New Tab row is ~25 points, and lands at the end of Saved.
        let seam = spot(SavedDrop.target(y: 290, from: .today, in: saved))
        #expect(seam?.anchor == .end)
        #expect(seam?.group == nil)
        #expect(seam?.depth == 0)
        #expect(spot(SavedDrop.target(y: 250, from: .today, in: saved))?.anchor == .end)
    }

    @Test("Between two rows: before the lower one, after the upper one")
    func betweenRows() {
        #expect(spot(SavedDrop.target(y: 40, from: .today, in: saved))?.anchor == .before(a))
        // The lower half of a, with b a sibling below it: the same gap as above b.
        #expect(spot(SavedDrop.target(y: 60, from: .today, in: saved))?.anchor == .before(b))
        #expect(spot(SavedDrop.target(y: 80, from: .today, in: saved))?.anchor == .before(b))
        // Above the first row, over the space's name: the top of Saved.
        #expect(spot(SavedDrop.target(y: 10, from: .today, in: saved))?.anchor == .before(a))
        // The line sits in the gap, half way between the two rows.
        #expect(spot(SavedDrop.target(y: 80, from: .today, in: saved))?.y == 73)
    }

    @Test("A folder's line: above it, into it, or above its first row")
    func folders() {
        let above = spot(SavedDrop.target(y: 118, from: .today, in: saved))
        #expect(above?.anchor == .beforeFolder(work))
        #expect(above?.group == nil)
        let into = spot(SavedDrop.target(y: 134, from: .today, in: saved))
        #expect(into?.anchor == .into(work))
        #expect(into?.group == work)
        #expect(into?.depth == 1)
        let first = spot(SavedDrop.target(y: 150, from: .today, in: saved))
        #expect(first?.anchor == .before(c))
        #expect(first?.group == work)
        #expect(first?.depth == 1)
    }

    @Test("Below a folder's last row: still in it; below that, the top level")
    func endOfAFolder() {
        let inside = spot(SavedDrop.target(y: 225, from: .today, in: saved))
        #expect(inside?.anchor == .after(d))
        #expect(inside?.group == work)
        #expect(inside?.depth == 1)
        let out = spot(SavedDrop.target(y: 240, from: .today, in: saved))
        #expect(out?.anchor == .end)
        #expect(out?.group == nil)
    }

    @Test("A shut folder is all one target")
    func shutFolder() {
        var shut = saved
        shut.lines = [line(.tab(a), 34), line(.folder(work, collapsed: true), 75)]
        shut.bottom = 112
        #expect(spot(SavedDrop.target(y: 108, from: .today, in: shut))?.anchor == .into(work))
        #expect(spot(SavedDrop.target(y: 92, from: .today, in: shut))?.anchor == .into(work))
        #expect(spot(SavedDrop.target(y: 77, from: .today, in: shut))?.anchor == .beforeFolder(work))
    }

    @Test("An empty Saved block still takes a drop, at its slot")
    func emptySaved() {
        let empty = SavedDrop.Layout(lines: [], top: 52, bottom: 52, seamTop: 90, seamBottom: 127)
        let slot = spot(SavedDrop.target(y: 100, from: .today, in: empty))
        #expect(slot?.anchor == .end)
        #expect(slot?.y == 52)
        #expect(SavedDrop.target(y: 140, from: .today, in: empty) == nil)
    }

    @Test("A Saved row is over Today once it is past Saved's last row")
    func savedCrossesDown() {
        #expect(SavedDrop.target(y: 200, from: .saved, in: saved) == nil)
        #expect(SavedDrop.target(y: 238, from: .saved, in: saved) == nil)
        #expect(SavedDrop.target(y: 245, from: .saved, in: saved) == .today(y: 299))
        #expect(SavedDrop.target(y: 400, from: .saved, in: saved) == .today(y: 299))
    }
}

@Suite("Saved: where in the row a drop goes")
struct SavedDropIndexTests {
    let pin = UUID(), t1 = UUID(), t2 = UUID()

    var row: [(id: Tab.ID, pinned: Bool, saved: Bool)] {
        [(pin, true, false), (a, false, true), (b, false, true), (c, false, true), (d, false, true), (t1, false, false), (t2, false, false)]
    }

    func inWork(_ id: Tab.ID, _ group: UUID) -> Bool { group == work && (id == c || id == d) }

    @Test("A Today row lands at the line")
    func todayRow() {
        #expect(SavedDrop.index(for: .before(b), moving: t2, row: row, inFolder: inWork) == 2)
        #expect(SavedDrop.index(for: .after(d), moving: t2, row: row, inFolder: inWork) == 5)
        #expect(SavedDrop.index(for: .end, moving: t2, row: row, inFolder: inWork) == 5)
        #expect(SavedDrop.index(for: .into(work), moving: t2, row: row, inFolder: inWork) == 3)
        #expect(SavedDrop.index(for: .beforeFolder(work), moving: t2, row: row, inFolder: inWork) == 3)
        #expect(SavedDrop.index(for: .before(a), moving: t1, row: row, inFolder: inWork) == 1)
    }

    @Test("A row already in Saved is counted out of its own place first")
    func savedRow() {
        #expect(SavedDrop.index(for: .end, moving: a, row: row, inFolder: inWork) == 4)
        #expect(SavedDrop.index(for: .before(a), moving: b, row: row, inFolder: inWork) == 1)
    }

    @Test("No Saved rows: after the favourites, or at the very top")
    func emptySaved() {
        let bare: [(id: Tab.ID, pinned: Bool, saved: Bool)] = [(t1, false, false), (t2, false, false)]
        #expect(SavedDrop.index(for: .end, moving: t2, row: bare, inFolder: inWork) == 0)
        let pinned: [(id: Tab.ID, pinned: Bool, saved: Bool)] = [(pin, true, false), (t1, false, false), (t2, false, false)]
        #expect(SavedDrop.index(for: .end, moving: t2, row: pinned, inFolder: inWork) == 1)
        #expect(SavedDrop.index(for: .into(work), moving: t2, row: pinned, inFolder: inWork) == 1)
    }
}

// MARK: - closing against removing

/// A tab draws its mark from the app's appearance: the test process needs
/// an NSApplication for that, as the app has.
@MainActor
private func newTab() -> Tab {
    _ = NSApplication.shared
    return Tab()
}

@MainActor
private func restored(_ url: String, saved on: Bool) -> Tab {
    let tab = newTab()
    tab.restore(url: URL(string: url)!, title: "Title of \(url)")
    Sections.shared.restore(tab, saved: on, seen: nil)
    return tab
}

@Suite("Saved: close puts down, the cross removes")
@MainActor
struct SavedCloseTests {
    @Test("Only a Saved row on a page is put down by a close")
    func whoIsPutDown() {
        let sections = Sections.shared
        #expect(sections.putsDown(restored("https://example.com/kept", saved: true)))
        #expect(!sections.putsDown(restored("https://example.com/today", saved: false)))
        let favourite = restored("https://example.com/pin", saved: true)
        favourite.pin = "P"
        #expect(!sections.putsDown(favourite))
        let blank = newTab()
        sections.restore(blank, saved: true, seen: nil)
        #expect(!sections.putsDown(blank))
    }

    @Test("A put-down Saved row is still written to the session, saved, and still kept in the cloud")
    func putDownStaysKept() throws {
        let tab = restored("https://example.com/put-down", saved: true)
        tab.rest()
        #expect(tab.asleep)
        #expect(Sections.shared.isSaved(tab))
        let entry = try #require(Session.Entry(tab))
        #expect(entry.url == "https://example.com/put-down")
        #expect(entry.title == "Title of https://example.com/put-down")
        // The flag Spaces.shape writes for it, and back.
        var written = entry
        written.saved = Sections.shared.isSaved(tab)
        let read = try JSONDecoder().decode(Session.Entry.self, from: JSONEncoder().encode(written))
        #expect(read.saved == true)
        #expect(CloudApply.keptURL(of: tab, saved: Sections.shared.isSaved(tab))?.absoluteString == "https://example.com/put-down")
        // Today's rows were never kept; a favourite always is.
        let today = restored("https://example.com/loose", saved: false)
        #expect(CloudApply.keptURL(of: today, saved: false) == nil)
        let favourite = restored("https://example.com/favourite", saved: false)
        favourite.pin = "F"
        #expect(CloudApply.keptURL(of: favourite, saved: false) != nil)
    }

    @Test("The cloud merge keeps a put-down kept tab and deletes a removed one")
    func cloudOps() {
        let home = Space(name: "Home")
        func kept(_ name: String) -> CloudDocs.KeptTab {
            CloudDocs.KeptTab(key: "\(home.id.uuidString.lowercased())|saved|example.com|\(name)", space: home.id,
                              url: "https://example.com/\(name)", title: name, pinned: false, pin: nil)
        }
        let base = CloudDocs.Spaces(spaces: [home], tabs: [kept("closed"), kept("crossed")])
        // ⌘W on "closed": the row is still kept, so this Mac's document is unchanged.
        let afterClose = CloudMerge.spaces(base: base, local: base, server: base)
        #expect(afterClose.tabs.map(\.key) == base.tabs.map(\.key))
        // The cross on "crossed": gone from this Mac's document, and so from the merge.
        let local = CloudDocs.Spaces(spaces: [home], tabs: [kept("closed")])
        let afterCross = CloudMerge.spaces(base: base, local: local, server: base)
        #expect(afterCross.tabs.map(\.key) == [kept("closed").key])
    }

    @Test("Pins sync one per site: copies under other keys or spaces fold into the lowest key")
    func onePinPerSite() {
        let casual = Space(name: "Casual"), work = Space(name: "Work")
        func pin(_ space: Space, _ url: String, _ n: String = "") -> CloudDocs.KeptTab {
            let host = URL(string: url)?.host() ?? ""
            return CloudDocs.KeptTab(key: "\(space.id.uuidString.lowercased())|pin|\(host)|\(url)\(n)", space: space.id,
                                     url: url, title: host, pinned: true, pin: "X")
        }
        let saved = CloudDocs.KeptTab(key: "\(casual.id.uuidString.lowercased())|saved|x.com|https://x.com/a", space: casual.id,
                                      url: "https://x.com/a", title: "a", pinned: false, pin: nil)
        let x = pin(casual, "https://x.com/home"), y = pin(casual, "https://www.youtube.com/watch?v=1")
        let tabs = [pin(work, "https://x.com/home"), x, pin(casual, "https://x.com/home", "#2"), y,
                    pin(casual, "https://www.youtube.com/watch?v=1", "#3"), saved]
        let kept = CloudMerge.onePinPerSite(tabs)
        let low = [x, pin(work, "https://x.com/home")].map(\.key).min()!
        #expect(kept.filter(\.pinned).count == 2)
        #expect(kept.contains { $0.key == low })
        #expect(kept.contains { $0.key == y.key })
        #expect(kept.contains(saved)) // a Saved row on a pinned site stays
        // The merge folds too, whatever either side sent.
        let doc = CloudDocs.Spaces(spaces: [casual, work], tabs: tabs)
        #expect(CloudMerge.spaces(base: nil, local: doc, server: doc).tabs.filter(\.pinned).count == 2)
    }

    @Test("A launch keeps a pin written only in a row, once, and not the rows' copy of the pins")
    func strayPinsComeBack() {
        func entry(_ url: String, _ pin: String?) -> Session.Entry { Session.Entry(url: url, title: url, pin: pin) }
        let github = entry("https://github.com/", "G")
        let rows = [github, entry("https://mail.google.com/mail/u/0/#inbox", "M"),
                    entry("https://mail.google.com/mail/u/0/#sent", "M"), entry("https://example.com/", nil)]
        // github.com is the rows' copy of `pins`; #inbox and #sent are one
        // pin (pinKey drops the fragment); example.com is no pin at all.
        let shape = Session.Shape(tabs: rows, active: 0, pins: [github])
        #expect(Spaces.strayPins(shape).map(\.entry.url) == ["https://mail.google.com/mail/u/0/#inbox"])
        #expect(Spaces.strayPins(Session.Shape(tabs: rows, active: 0, pins: [])).map(\.entry.url)
            == ["https://github.com/", "https://mail.google.com/mail/u/0/#inbox"])
    }

    @Test("Reopen Closed Tab brings a removed Saved row back into Saved, in its folder")
    func reopenIntoSaved() {
        let sections = Sections.shared
        let folder = Groups.shared.create(named: "Reopen test \(UUID().uuidString.prefix(6))", hue: nil)
        defer { Groups.shared.dissolve(folder.id) }
        let ghost = UUID()
        sections.remember(.init(group: folder.id), for: ghost, keeping: [ghost])
        #expect(sections.removedPlace(ghost) == .init(group: folder.id))
        let back = newTab()
        back.restore(url: URL(string: "https://example.com/back")!, title: "Back")
        sections.reopened(ghost, as: back)
        #expect(sections.isSaved(back))
        #expect(Groups.shared.membership[back.id] == folder.id)
        // Used once: the same entry again changes nothing.
        #expect(sections.removedPlace(ghost) == nil)
        // An entry the browser no longer lists is let go.
        let old = UUID(), new = UUID()
        sections.remember(.init(group: nil), for: old, keeping: [old])
        sections.remember(.init(group: nil), for: new, keeping: [new])
        #expect(sections.removedPlace(old) == nil)
        #expect(sections.removedPlace(new) != nil)
    }

    @Test("A Today row reopened is not made Saved")
    func reopenToday() {
        let tab = newTab()
        tab.restore(url: URL(string: "https://example.com/today-back")!, title: "Today")
        Sections.shared.reopened(UUID(), as: tab)
        #expect(!Sections.shared.isSaved(tab))
    }
}
