import AppKit
import SwiftUI
import Testing
@testable import Search

// Fork (ardia split): a split is up to three panes, side by side or stacked,
// each with its share; it is one row in the column and comes back after a
// relaunch in the same order and shape. A sidebar row carried to the page's
// edge shows where its pane would go.

@Suite("Split view: three panes, stacked, kept")
@MainActor
struct SplitPanesTests {
    @Test("Lengths follow the shares, and a small window never squeezes a pane under its least")
    func lengths() {
        #expect(Split.lengths([0.5, 0.5], span: 1000, least: 220) == [500, 500])
        let squeezed = Split.lengths([0.05, 0.95], span: 1000, least: 220)
        #expect(abs(squeezed[0] - 220) < 0.001 && abs(squeezed[1] - 780) < 0.001)
        let small = Split.lengths([0.1, 0.45, 0.45], span: 500, least: 220)
        #expect(small.allSatisfy { $0 >= 500.0 / 3 - 0.001 }, "three panes in 500 pt: a third each at worst")
        #expect(abs(small.reduce(0, +) - 500) < 0.001)
        #expect(Split.lengths([], span: 500, least: 220).isEmpty)
    }

    @Test("A divider moves only the two panes it parts, and stops at their least")
    func pulled() {
        let third: CGFloat = 1.0 / 3
        let moved = Split.pulled([third, third, third], divider: 0, to: 0.5, least: 0.1)
        #expect(abs(moved[0] - 0.5) < 0.0001 && abs(moved[1] - (2 * third - 0.5)) < 0.0001 && moved[2] == third)
        let stopped = Split.pulled([third, third, third], divider: 1, to: 0.99, least: 0.2)
        #expect(abs(stopped[2] - 0.2) < 0.0001 && stopped[0] == third)
        #expect(abs(stopped.reduce(0, +) - 1) < 0.0001)
        #expect(Split.pulled([0.5, 0.5], divider: 1, to: 0.3, least: 0.1) == [0.5, 0.5], "no pane after the last")
    }

    @Test("A row over the page lands at the edge it is near, along the split's own axis, and not once there are three")
    func zones() {
        let page = CGRect(x: 100, y: 50, width: 1000, height: 800)
        #expect(SplitDrop.zone(at: CGPoint(x: 150, y: 450), in: page, count: 1, stacked: false) == .leading)
        #expect(SplitDrop.zone(at: CGPoint(x: 1050, y: 450), in: page, count: 1, stacked: false) == .trailing)
        #expect(SplitDrop.zone(at: CGPoint(x: 600, y: 820), in: page, count: 1, stacked: false) == .bottom)
        #expect(SplitDrop.zone(at: CGPoint(x: 600, y: 450), in: page, count: 1, stacked: false) == nil, "the middle is no edge")
        #expect(SplitDrop.zone(at: CGPoint(x: 50, y: 450), in: page, count: 1, stacked: false) == nil, "off the page")
        #expect(SplitDrop.zone(at: CGPoint(x: 600, y: 820), in: page, count: 2, stacked: false) == nil, "a row grows sideways")
        #expect(SplitDrop.zone(at: CGPoint(x: 1050, y: 450), in: page, count: 2, stacked: false) == .trailing)
        #expect(SplitDrop.zone(at: CGPoint(x: 600, y: 80), in: page, count: 2, stacked: true) == .top)
        #expect(SplitDrop.zone(at: CGPoint(x: 150, y: 450), in: page, count: 2, stacked: true) == nil, "a stack grows up and down")
        #expect(SplitDrop.zone(at: CGPoint(x: 1050, y: 450), in: page, count: 3, stacked: false) == nil, "three is full")
        let place = SplitDrop.place(.trailing, in: CGSize(width: 900, height: 600), count: 2)
        #expect(place == CGRect(x: 600, y: 0, width: 300, height: 600))
        #expect(SplitDrop.place(.bottom, in: CGSize(width: 900, height: 600), count: 1) == CGRect(x: 0, y: 300, width: 900, height: 300))
    }

    @Test("A kept split rides in the session: order, stacked and shares come back; an old file's pair comes back side by side")
    func session() {
        let split = Split.shared
        defer { split.restore([:]) }
        let (a, b, c, d) = (UUID(), UUID(), UUID(), UUID())
        let token = UUID()
        split.restore([token: [a, b, c]], slots: [
            a: SplitSlot(at: 2, stacked: true, share: 0.5),
            b: SplitSlot(at: 0, stacked: true, share: 0.2),
            c: SplitSlot(at: 1, stacked: true, share: 0.3),
        ])
        let layout = split.layout(of: a)
        #expect(layout?.tabs == [b, c, a])
        #expect(layout?.stacked == true)
        #expect(layout.map { zip($0.shares, [0.2, 0.3, 0.5]).allSatisfy { abs($0 - $1) < 0.0001 } } == true)
        let written = split.session(for: c, alive: [a, b, c])
        #expect(written.token == token && written.slot == SplitSlot(at: 1, stacked: true, share: 0.3))
        // A pane closed since: the other two are still a split, their shares made whole.
        let left = split.session(for: a, alive: [a, b])
        #expect(left.slot?.at == 1 && left.slot?.share.map { abs($0 - 0.714) < 0.001 } == true)
        #expect(split.session(for: a, alive: [a]).token == nil, "a split of one is no split")

        let old = UUID()
        split.restore([old: [a, b, c, d]])
        #expect(split.layout(of: a)?.tabs == [a, b, c], "three panes at most")
        #expect(split.layout(of: a)?.stacked == false)
        #expect(split.layout(of: a)?.shares.allSatisfy { abs($0 - 1.0 / 3) < 0.0001 } == true)
        #expect(split.layout(of: d) == nil)
        #expect(SplitPairs.shared.ids == [a, b, c], "the column marks every pane")
    }

    @Test("Older sessions decode, and a pane's slot round-trips through JSON")
    func entryCodes() throws {
        let old = #"{"url":"https://a.example/","title":"A","split":"6E4B1F7C-1F4B-4C1E-9D7A-3C2B1A0F9E8D"}"#
        let entry = try JSONDecoder().decode(Session.Entry.self, from: Data(old.utf8))
        #expect(entry.split != nil && entry.pane == nil)
        var next = entry
        next.pane = SplitSlot(at: 1, stacked: true, share: 0.25)
        let back = try JSONDecoder().decode(Session.Entry.self, from: JSONEncoder().encode(next))
        #expect(back.pane == SplitSlot(at: 1, stacked: true, share: 0.25))
    }

    @Test("A run of a kept split's rows is one row: the top one carries the rest")
    func oneRow() {
        let (a, b, c, x) = (Search.Tab(), Search.Tab(), Search.Tab(), Search.Tab()) // SwiftUI has a Tab too
        let key = UUID()
        let ids: Set<UUID> = [a.id, b.id, c.id]
        let split: (UUID) -> UUID? = { ids.contains($0) ? key : nil }
        let rows: [FolderRow] = [x, a, b, c].enumerated().map { .tab($0.element, index: $0.offset, group: nil, depth: 0) }
        let merged = GroupedRows.merged(rows, split: split)
        #expect(merged.count == 1 && merged[a.id]?.map(\.id) == [b.id, c.id])
        // Apart (another row between), each part is its own row.
        let apart: [FolderRow] = [a, x, b].enumerated().map { .tab($0.element, index: $0.offset, group: nil, depth: 0) }
        #expect(GroupedRows.merged(apart, split: split).isEmpty)
    }
}
