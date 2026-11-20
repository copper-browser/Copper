import Foundation
import Testing
@testable import Search

// jev_dump writes `Ultrafast.request` for a run's first decision: the state
// and questions `choose` sends. What a training example relies on.

private typealias U = Tools.Ultrafast

@Suite("Jev dump")
struct JevDumpTests {
    @Test func firstDecisionRequestIsWhatChooseSends() {
        let obs = U.Observation(raw: [
            "url": "https://a.test/", "title": "A", "text": String(repeating: "x", count: 2000),
            "actions": [
                ["kind": "click", "node": 1, "id": "c1", "label": "Sign in → account menu", "role": "link"],
                ["kind": "fill", "node": 2, "id": "f2", "label": "Email", "role": "textbox", "value": ""],
                ["kind": "scroll", "id": "scroll_down", "label": "Scroll down"],
            ],
        ])
        let r = U.request(obs, goal: "Type \"ada@b.test\" in the email box", history: [], strategy: .shipped)
        #expect((r.state["recent_actions"] as? [Any])?.isEmpty == true)
        #expect(((r.state["page"] as? [String: Any])?["text"] as? String)?.count == 1200) // lean
        let elements = r.state["elements"] as? [[String: Any]] ?? []
        #expect(elements.map { $0["label"] as? String } == ["Sign in", "Email"])
        #expect(Set(r.questions.keys) == ["operation", "click_target", "type_text_target", "value_1"])
        let ops = (r.questions["operation"] as? [String: Any])?["criteria"] as? [String: String] ?? [:]
        #expect(Set(ops.keys) == ["CLICK", "TYPE_TEXT", "SCROLL_DOWN", "DONE", "BLOCKED"])
        // The target head keeps the whole label; the table only its first part.
        let click = ((r.questions["click_target"] as? [String: Any])?["criteria"] as? [String: Any])?["1"] as? [String: Any]
        #expect(click?["element"] as? String == "[1] Sign in → account menu")
    }
}
