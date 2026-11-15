import Foundation
import Testing
@testable import Search

// Fork (uichrome): an agent step that failed reads as a plain outcome — the
// tool's counts and codes stay behind Details — and a run that ended on an
// error says so in words, not with the tool's message.

@Test func failedStepDropsTheToolsCounts() {
    #expect(DriveStep.plain(head: "Changing the canvas · 12 ops") == "Changing the canvas didn't work")
    #expect(DriveStep.plain(head: "Clicking Search…") == "Clicking Search didn't work")
    #expect(DriveStep.plain(head: " · E_SHAPE") == "That step didn't work")
}

@MainActor @Test func erroredRunIsAPlainOutcome() {
    let run = Drive.Run(id: UUID(), driver: .jev, who: .plain(.jev),
                        goal: "", tabID: UUID(), started: Date(), ended: Date(), status: .error,
                        note: "canvas_apply: 12 ops rejected (E_SHAPE_MISSING)", cycles: [], url: "", title: "")
    #expect(run.statusLine(busy: false) == "Didn't finish")
    #expect(run.failed)
}
