import Foundation
import Testing
@testable import Search

// Fork (uib): a turn that got past a problem is not a failed turn — its
// "1 step had a problem" is muted, red only when it ended on a failed step.

private func group(_ oks: [Bool], warning: Int? = nil) -> AgentActivityGroup {
    let items = oks.enumerated().map { index, ok in
        Agent.Item(kind: .tool, text: "", ok: ok, warning: index == warning ? "2 ops didn't work" : "")
    }
    return AgentActivityGroup(id: UUID(), items: items, started: Date(), running: false)
}

@Test func activityFailsOnlyWhenTheTurnEndedOnAFailure() {
    #expect(!group([true, true]).failed)
    #expect(!group([true, true], warning: 0).failed, "a warning is a problem it got past")
    #expect(!group([false, true]).failed, "a failed step followed by one that worked is recovered")
    #expect(group([true, false]).failed)
    #expect(!group([]).failed)
}

// Fork (hc6): nothing tracks a retry, so a failure the turn got past never claims one.
@Test func activityNeverClaimsARetryItDidNotTrack() {
    #expect(group([false, true]).trouble == " · 1 earlier step failed")
    #expect(group([false, false, true]).trouble == " · 2 earlier steps failed")
    #expect(group([true, false]).trouble == " · 1 step had a problem")
    #expect(group([true, true], warning: 0).trouble == " · 1 step had a problem")
    #expect(group([true, true]).trouble.isEmpty)
}
