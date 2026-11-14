import Foundation
import Testing
@testable import Search

// Which tabs left half an hour go to sleep (Sleep.swift, SleepPlan): the
// count budget as before, and the footprint budget the pages that may sleep
// keep between them (Fork: idle-memory).

@Suite("Idle sleep: count and footprint budgets")
struct SleepPlanTests {
    private let mb: UInt64 = 1_048_576
    private func tab(_ left: TimeInterval, mb size: UInt64 = 100, remembered: Bool = false, heavy: Bool = false, hot: Bool = false) -> SleepPlan.Resting {
        SleepPlan.Resting(id: UUID(), left: left, bytes: size * mb, remembered: remembered, heavy: heavy, hot: hot)
    }

    @Test("Under both budgets only the heavy, the hot and the twelve-hour ones go")
    func underBudget() {
        let plain = tab(3600), heavy = tab(1900, heavy: true), hot = tab(1900, hot: true), old = tab(13 * 3600)
        let space = tab(13 * 3600, remembered: true)
        let chosen = SleepPlan(overCount: -5, overBytes: -1, ceiling: 12 * 3600).choose([plain, heavy, hot, old, space])
        #expect(Set(chosen) == [heavy.id, hot.id, old.id])
    }

    @Test("Over the count, the longest-left go first, never a space's own tab")
    func overCount() {
        let a = tab(4000), b = tab(9000), space = tab(20000, remembered: true)
        let chosen = SleepPlan(overCount: 1, overBytes: -1, ceiling: 12 * 3600).choose([a, b, space])
        #expect(chosen == [b.id])
    }

    @Test("Over the footprint, tabs go longest-left first until what is left fits, a space's own tab included")
    func overBytes() {
        let a = tab(2000, mb: 300), space = tab(9000, mb: 400, remembered: true), b = tab(5000, mb: 200)
        let chosen = SleepPlan(overCount: -3, overBytes: Int64(500 * mb), ceiling: 12 * 3600).choose([a, space, b])
        #expect(chosen == [space.id, b.id])
    }
}
