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

// Fork (hc6): a turn Copper split (Agent.tooLong) and finished is one quiet
// activity — the cut step is the split, not a failure; red only if it ends failed.
@Test @MainActor func aSplitTurnIsOneQuietActivity() {
    let items = [Agent.Item(kind: .user, text: "make 100 notes"),
                 Agent.Item(kind: .tool, text: "", ok: false),
                 Agent.Item(kind: .note, text: Agent.tooLong, ok: false),
                 Agent.Item(kind: .tool, text: "")]
    let blocks = AgentPane.blocks(items, busy: false)
    #expect(blocks.count == 2, "the note folds into the activity instead of splitting the turn")
    guard case .activity(let g) = blocks.last else { Issue.record("no activity"); return }
    #expect(g.split && !g.failed)
    #expect(g.trouble == " · split into smaller pieces")
    var broken = g; broken.items.append(Agent.Item(kind: .tool, text: "", ok: false))
    #expect(broken.failed && broken.trouble == " · 2 steps had problems")
}
