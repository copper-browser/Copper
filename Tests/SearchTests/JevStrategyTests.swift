import Foundation
import Testing
@testable import Search

// Jev mode's faster loop and the hybrid, apart from any page or network: the
// strategy words, the values a goal quotes, which reads get a picture, where
// a box lands, and which fields a burst fills.

private typealias U = Tools.Ultrafast

private func click(_ node: Int, _ role: String, _ label: String, x: Double = 0, y: Double = 0, w: Double = 40, h: Double = 20) -> [String: Any] {
    ["id": "e\(node)", "node": node, "kind": "click", "role": role, "label": label,
     "rect": ["x": x, "y": y, "w": w, "h": h]]
}

@Suite("Jev strategies")
struct JevStrategyTests {
    @Test func parsesWords() {
        #expect(U.Strategy.parse(nil) == U.Strategy())
        #expect(U.Strategy.parse("classic") == U.Strategy())
        let turbo = U.Strategy.parse("turbo")!
        #expect(!turbo.glide && turbo.literals && turbo.burst && turbo.lean && turbo.paste && turbo.watch && !turbo.llm)
        let llm = U.Strategy.parse("fast,llm=Haiku")!
        #expect(llm.llm && llm.llmModel == "Haiku" && !llm.glide)
        #expect(U.Strategy.parse("warp") == nil)
        #expect(U.Strategy.parse("burst")!.literals)
    }

    @Test func shippedGlidesOnlyWhenWatched() {
        let shipped = U.Strategy.shipped
        #expect(!shipped.glide && shipped.glideWatched && shipped.burst && shipped.paste)
        #expect(shipped.name.hasPrefix("watched"))
    }

    @Test func quotedValues() {
        let goal = #"Sign in with the work email "maya@northwind.test" and the access code “482915”, then open bob@acme.io's page"#
        #expect(U.literals(in: goal) == ["maya@northwind.test", "482915", "bob@acme.io"])
        #expect(U.literals(in: "Open the settings and save").isEmpty)
    }

    @Test func namedValuesWithoutQuotes() {
        // jev-ultrafast's own three goals: the places and the date are typed
        // as the goal says them; things to click or choose are not values.
        #expect(U.literals(in: "Find one-way flights from Zurich to London on January 20, 2027, for one adult in economy. Stop when matching flight options are visible. Do not select or book a flight.")
                == ["Zurich", "London", "January 20, 2027"])
        #expect(U.literals(in: "Use the destination search and filters to find Design stays in Lisbon with Free cancellation, then open Casa Flora.") == ["Lisbon"])
        #expect(U.literals(in: "Find and open the Wikipedia article about Gödel’s incompleteness theorems.").isEmpty)
        #expect(U.literals(in: "Book a table at Chez Panisse in San Francisco for 2026-12-01.") == ["Chez Panisse", "San Francisco", "2026-12-01"])
        // A month is a date, never a place; lowercase words end a name.
        #expect(U.literals(in: "Show what is on in March and switch to the German-language version.").isEmpty)
    }

    @Test func aFieldIsRememberedByRoleAndLabel() {
        #expect(U.fieldKey(["role": "combobox", "label": "Where to? "]) == U.fieldKey(["role": "combobox", "label": "where to?"]))
        #expect(U.fieldKey(["role": "combobox", "label": "Where to?"]) != U.fieldKey(["role": "combobox", "label": "Where from?"]))
        #expect(U.fieldKey(["role": "textbox", "label": "Name"]) != U.fieldKey(["role": "searchbox", "label": "Name"]))
    }

    @Test func textModelsFastFirstHaikuLast() {
        var keys = Intelligence.Keys()
        #expect(U.textModels(keys) == [U.fastTextModel, "haiku"])
        keys.textModel = "haiku"
        #expect(U.textModels(keys) == ["haiku"])
        keys.textModel = "luna"
        #expect(U.textModels(keys) == ["luna", "haiku"])
        keys.textModel = ""
        keys.lane = .claude
        #expect(U.textModels(keys) == ["haiku"])
    }

    @Test func shippedSubmitsAndVerifyIsOptIn() {
        #expect(!U.Strategy.shipped.verify && !U.Strategy.parse("turbo")!.verify && U.Strategy.parse("verify")!.verify)
        #expect(U.Strategy.shipped.submit && U.Strategy.shipped.name.hasSuffix("watch,submit"))
    }

    @Test func visionParses() {
        #expect(U.Vision.parse("auto") == .auto)
        #expect(U.Vision.parse("hybrid") == .auto)
        #expect(U.Vision.parse("text") == .off)
        #expect(U.Vision.parse("pixel") == .pixels)
        #expect(!U.Vision.auto.usesPicture && U.Vision.marks.usesPicture)
        #expect(!U.Vision.offered.contains(.pixels))
    }
}

@MainActor
@Suite("The hybrid's picture rule")
struct JevHybridTests {
    private func obs(_ actions: [[String: Any]]) -> U.Observation { U.Observation(raw: ["actions": actions]) }

    @Test func labelledPageStaysText() {
        let page = obs([click(1, "button", "Sign in"), click(2, "link", "Settings"), click(3, "link", "Files")])
        #expect(!U.needsPicture(page, after: nil))
    }

    @Test func namelessControlGetsPicture() {
        #expect(U.needsPicture(obs([click(1, "button", "Save"), click(2, "button", "button")]), after: nil))
        #expect(U.needsPicture(obs([click(1, "button", "")]), after: nil))
    }

    @Test func aFewImageLinksStayText() {
        // Wikipedia: one or two links around images with no alt text.
        let article = obs([click(1, "link", "Milk"), click(2, "link", "link"), click(3, "link", "link")])
        #expect(!U.needsPicture(article, after: nil))
        let gallery = obs([click(1, "link", "link"), click(2, "link", "link"), click(3, "link", "")])
        #expect(U.needsPicture(gallery, after: nil))
    }

    @Test func repeatedLabelsGetPicture() {
        let two = obs([click(1, "button", "Approve"), click(2, "button", "Approve")])
        #expect(!U.needsPicture(two, after: nil))
        let three = obs([click(1, "button", "Approve"), click(2, "button", "approve"), click(3, "button", "Approve")])
        #expect(U.needsPicture(three, after: nil))
    }

    @Test func aMoveThatChangedNothingGetsPicture() {
        let page = obs([click(1, "button", "Sign in")])
        var step = U.Step(number: 1, operation: "CLICK", kind: "click", label: "Sign in", text: nil, confidence: 1,
                          probability: 1, latencyMs: 0, textLatencyMs: 0, pageChanged: false, url: "")
        #expect(U.needsPicture(page, after: step))
        step.pageChanged = true
        #expect(!U.needsPicture(page, after: step))
    }
}

@Suite("Where a box lands")
struct JevBoxTests {
    // 1000×500 picture of a 1000×500 page.
    private let shot = U.Shot(data: Data(), width: 1000, height: 500, scale: 1, reference: "r", ms: 0)

    @Test func overlapBeatsCentre() {
        // Two 32-px icons side by side and a box a little left of the right
        // one, the way the bench saw Jev draw it: it covers the right icon
        // more than the left, so the right one is the click.
        let candidates: [String: [String: Any]] = [
            "1": click(1, "button", "button", x: 600, y: 100, w: 32, h: 32),
            "2": click(2, "button", "button", x: 636, y: 100, w: 32, h: 32),
        ]
        let box = Jev.Box(top: 0.2, bottom: 0.264, left: 0.630, right: 0.666, confidence: 0.9)
        #expect(U.land(box, on: candidates, shot: shot) == "2")
    }

    @Test func farFromEverythingIsAMiss() {
        let candidates: [String: [String: Any]] = ["1": click(1, "button", "Save", x: 10, y: 10)]
        let box = Jev.Box(top: 0.8, bottom: 0.9, left: 0.8, right: 0.9, confidence: 0.9)
        #expect(U.land(box, on: candidates, shot: shot) == nil)
    }
}

@Suite("Burst fills")
struct JevBurstTests {
    private let fills: [String: [String: Any]] = [
        "1": ["id": "e1", "node": 1, "kind": "fill", "label": "Work email", "value": ""],
        "2": ["id": "e2", "node": 2, "kind": "fill", "label": "Access code", "value": ""],
        "3": ["id": "e3", "node": 3, "kind": "fill", "label": "Name", "value": "Apollo"],
    ]

    @Test func fillsTheOthersSurely() {
        let found = [
            U.Assignment(literal: "maya@northwind.test", target: "1", probability: 0.99),
            U.Assignment(literal: "482915", target: "2", probability: 0.95),
            U.Assignment(literal: "Apollo", target: "3", probability: 0.99), // already there
            U.Assignment(literal: "maybe", target: "2", probability: 0.4),   // unsure
        ]
        let out = U.burstFills(found, except: "1", fills: fills)
        #expect(out.count == 1)
        #expect(out.first?.text == "482915")
        #expect((out.first?.action["id"] as? String) == "e2")
    }

    @Test func neverIntoAFieldThatSuggests() {
        // "Where to?" answers typing with a list to pick from: that is the next read's.
        var fills = self.fills
        fills["2"]?["role"] = "combobox"
        #expect(U.burstFills([U.Assignment(literal: "London", target: "2", probability: 0.99)], except: "1", fills: fills).isEmpty)
        #expect(U.suggests(["role": "searchbox"]) && !U.suggests(["role": "textbox"]))
    }
}
