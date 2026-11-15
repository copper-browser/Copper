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
        #expect(!turbo.glide && turbo.literals && turbo.burst && turbo.lean && turbo.paste && turbo.watch && turbo.near && turbo.reach && !turbo.llm)
        #expect(!U.Strategy().near && !U.Strategy().reach)
        let llm = U.Strategy.parse("fast,llm=Haiku")!
        #expect(llm.llm && llm.llmModel == "Haiku" && !llm.glide)
        #expect(U.Strategy.parse("warp") == nil)
        #expect(U.Strategy.parse("burst")!.literals)
        let words = U.Strategy.parse("turbo,calm,deep")!
        #expect(words.calm && words.deep && !turbo.calm && !turbo.deep)
        #expect(words.name.hasSuffix("reach,calm,deep"))
    }

    @Test func shippedGlidesOnlyWhenWatched() {
        let shipped = U.Strategy.shipped
        #expect(!shipped.glide && shipped.glideWatched && shipped.burst && shipped.paste)
        #expect(shipped.name.hasPrefix("watched"))
        #expect(shipped.calm && shipped.deep)
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
        // What an article is about, to the end, with a curly apostrophe made straight (the text model wrote it before).
        #expect(U.literals(in: "Find and open the Wikipedia article about Gödel’s incompleteness theorems.") == ["Gödel's incompleteness theorems"])
        #expect(U.literals(in: "Open the article on Alan Turing.") == ["Alan Turing"])
        #expect(U.literals(in: "Tell me about the weather.").isEmpty)
        #expect(U.literals(in: "Book a table at Chez Panisse in San Francisco for 2026-12-01.") == ["Chez Panisse", "San Francisco", "2026-12-01"])
        // A month is a date, never a place; lowercase words end a name.
        #expect(U.literals(in: "Show what is on in March and switch to the German-language version.").isEmpty)
    }

    @Test func aFieldIsRememberedByRoleAndLabel() {
        #expect(U.fieldKey(["role": "combobox", "label": "Where to? "]) == U.fieldKey(["role": "combobox", "label": "where to?"]))
        #expect(U.fieldKey(["role": "combobox", "label": "Where to?"]) != U.fieldKey(["role": "combobox", "label": "Where from?"]))
        #expect(U.fieldKey(["role": "textbox", "label": "Name"]) != U.fieldKey(["role": "searchbox", "label": "Name"]))
        // "Search" in another document or form is another field.
        #expect(U.fieldKey(["role": "searchbox", "label": "Search", "scope": "1.5|q"]) != U.fieldKey(["role": "searchbox", "label": "Search", "scope": "9.1|q"]))
        #expect(U.fieldKey(["role": "searchbox", "label": "Search", "scope": "1.5|q"]) == U.fieldKey(["role": "searchbox", "label": "search ", "scope": "1.5|q"]))
    }

    @Test func paraphrasedValues() {
        // The same flight said other ways: lowercase, airport codes, German, French.
        #expect(U.literals(in: "find one-way flights from zurich to london on january 20, 2027 for one adult in economy.")
                == ["zurich", "london", "january 20, 2027"])
        #expect(U.literals(in: "One-way flights ZRH → LHR on 2027-01-20, 1 adult, economy.") == ["ZRH", "LHR", "2027-01-20"])
        #expect(U.literals(in: "Finde einfache Flüge von Zürich nach London am 20. Januar 2027 für einen Erwachsenen in der Economy Class.")
                == ["Zürich", "London", "20. Januar 2027"])
        #expect(U.literals(in: "Trouve un vol de Zurich à Londres le 20 janvier 2027.") == ["Zurich", "Londres", "20 janvier 2027"])
        #expect(U.literals(in: "Move it from New York to San Francisco, then save.") == ["New York", "San Francisco"])
        #expect(U.literals(in: "Change the date to 20/01/2027 and the name to 'Ada'") == ["Ada", "20/01/2027"])
        // A phrase is not a place: articles start no value.
        #expect(U.literals(in: "Starting from the article that is open, go to the next one.").isEmpty)
    }

    @Test func goalTermsForOffscreenLinks() {
        let terms = U.goalTerms("Open the MDN reference page for the JavaScript Array.prototype.flatMap() method.")
        let words = terms["words"] as? [String] ?? []
        #expect(words.contains("array") && words.contains("flatmap") && !words.contains("the") && !words.contains("open") && !words.contains("page"))
        #expect((terms["phrases"] as? [String] ?? []).contains("array prototype flatmap"))
        let game = U.goalTerms(#"Reach the Wikipedia article titled "Buenos Aires" by clicking links."#)
        #expect((game["phrases"] as? [String]) == ["buenos aires"])
        #expect((game["words"] as? [String] ?? []).contains("aires"))
        #expect((U.goalTerms("Find Gödel’s theorems")["words"] as? [String] ?? []).contains("godel"))
    }

    @Test func humanChecksAreNamed() {
        #expect(U.humanCheck("I am human") != nil)
        #expect(U.humanCheck("I'm not a robot") != nil)
        #expect(U.humanCheck("Press & Hold to confirm you are a human") != nil)
        #expect(U.humanCheck("Type the characters you see in this image") != nil)
        // Amazon's bot check (phi-mcp, r4).
        #expect(U.humanCheck("We're noticing unusual browser activity from your device") != nil)
        #expect(U.humanCheck("Continue shopping") == nil)
        #expect(U.humanCheck("reCAPTCHA documentation") == nil)
        #expect(U.humanCheck("Human resources") == nil)
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
        #expect(U.Strategy.shipped.submit && U.Strategy.shipped.name.hasSuffix("watch,near,reach,calm,deep,submit"))
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

    @Test func imageLinksAndRepeatsWaitForTheChoice() {
        // Wikipedia: imageless links and "edit" × 20 sent a picture with 26 of 30 game runs.
        let article = obs([click(1, "link", "Milk"), click(2, "link", "link"), click(3, "link", "link"), click(4, "link", ""),
                           click(5, "link", "edit"), click(6, "link", "edit"), click(7, "link", "edit")])
        #expect(!U.needsPicture(article, after: nil))
        // The picture comes when the chosen one has a namesake (none is a name too).
        #expect(!U.sharesName(article, choice: "e1"))
        #expect(U.sharesName(article, choice: "e2") && U.sharesName(article, choice: "e4") && U.sharesName(article, choice: "e6"))
        // Wikipedia links one article twice (text and infobox): one place, one choice, no picture.
        var twice = click(8, "link", "Austria"), again = click(9, "link", "Austria")
        twice["href"] = "https://en.wikipedia.org/wiki/Austria"; again["href"] = "https://en.wikipedia.org/wiki/Austria"
        var other = click(10, "link", "Austria"); other["href"] = "https://en.wikipedia.org/wiki/Austria_(disambiguation)"
        #expect(!U.sharesName(obs([twice, again]), choice: "e8"))
        #expect(U.sharesName(obs([twice, again, other]), choice: "e8"))
        let invoices = obs([click(1, "button", "Approve"), click(2, "button", "approve"), click(3, "button", "Reject")])
        #expect(!U.needsPicture(invoices, after: nil))
        #expect(U.sharesName(invoices, choice: "e1") && !U.sharesName(invoices, choice: "e3"))
        #expect(!U.sharesName(invoices, choice: "e9"))
    }

    @Test func aMoveThatChangedNothingGetsPicture() {
        let page = obs([click(1, "button", "Sign in")])
        var step = U.Step(number: 1, operation: "CLICK", kind: "click", label: "Sign in", text: nil, confidence: 1,
                          probability: 1, latencyMs: 0, textLatencyMs: 0, pageChanged: false, url: "")
        #expect(U.needsPicture(page, after: step))
        step.pageChanged = true
        #expect(!U.needsPicture(page, after: step))
        // Its answer still out (Flights' Reload) is not "changed nothing".
        step.pageChanged = false
        step.inFlight = true
        #expect(!U.needsPicture(page, after: step))
        // Nor is a form that went in: the page took it, it may just not say so.
        step.inFlight = false
        step.sent = true
        step.formSent = true
        #expect(!U.needsPicture(page, after: step))
        // Said as it was: sent, and the page didn't change (r4 said page_changed: true for any POST).
        #expect(step.quietSend && (step.recent["page_changed"] as? Bool) == false && (step.recent["sent"] as? Bool) == true)
        #expect((step.recent["action"] as? String ?? "").contains("no confirmation"))
        // A fetch POST with no form is the same send (a Pay button): the guard arms on it.
        step.formSent = false
        #expect(step.quietSend)
        step.pageChanged = true
        #expect(!step.quietSend && step.recent["sent"] as? Bool == true)
        // The read moved (the viewport's size) but showed nothing new: still quiet.
        step.nothingNew = true
        #expect(step.quietSend)
    }
}

@MainActor
@Suite("Jev's claims and waits")
struct JevClaimTests {
    private typealias E = NetLog.Entry

    @Test func floors() {
        #expect(U.floor("BLOCKED") == 0.8 && U.floor("DONE") == U.claimFloor)
        // r4: every DONE at 80% or more passed; Amazon's false DONE was 67%.
        #expect(U.claimFloor == 0.8 && 0.67 < U.floor("DONE"))
        // A WAIT is never shorter than the 238 ms that ended in DONE on Flights.
        #expect(U.waitFloor >= 0.24 && U.waitLinger >= 0.4)
        // far-link's BLOCKED at 76% on the page it was sent to (r3) is doubted now.
        #expect(0.76 < U.floor("BLOCKED"))
    }

    @Test func waitsOnlyOnWhatIsLive() {
        let now = Date()
        var open = E(id: 1, method: "POST", url: "https://www.google.com/_/FlightsFrontendUi/data/batchexecute", kind: "xhr")
        open.at = now.addingTimeInterval(-0.5)
        #expect(NetLog.pending(open, now: now))
        // An aborted call WebKit never ends stops counting after 1.5 s.
        open.at = now.addingTimeInterval(-2)
        #expect(!NetLog.pending(open, now: now))
        // A call with a status is answered, open stream or not.
        var streaming = E(id: 2, method: "GET", url: "https://x.test/stream", kind: "fetch", status: 200)
        streaming.at = now
        #expect(!NetLog.pending(streaming, now: now))
        // Quiet: nothing pending and the last answer 150 ms ago.
        streaming.answeredAt = now.addingTimeInterval(-0.05)
        #expect(!NetLog.quiet([streaming], now: now))
        streaming.answeredAt = now.addingTimeInterval(-0.2)
        #expect(NetLog.quiet([streaming], now: now) && NetLog.quiet([], now: now))
    }

    @Test func bookkeepingIsNotAnAnswer() {
        #expect(NetLog.noise(E(id: 1, method: "POST", url: "https://www.google.com/log?format=json&hasfast=true", kind: "xhr")))
        #expect(NetLog.noise(E(id: 2, method: "POST", url: "https://www.google-analytics.com/g/collect?v=2", kind: "fetch")))
        #expect(NetLog.noise(E(id: 3, method: "POST", url: "https://x.test/anything", kind: "beacon")))
        #expect(!NetLog.noise(E(id: 4, method: "POST", url: "https://www.google.com/_/FlightsFrontendUi/data/travel.frontend.flights.FlightsFrontendService/GetShoppingResults", kind: "xhr")))
        #expect(!NetLog.noise(E(id: 5, method: "POST", url: "http://127.0.0.1:4171/api/review", kind: "fetch")))
        // Path words and stats. hosts are not bookkeeping: these POSTs change things (council R5).
        #expect(!NetLog.noise(E(id: 6, method: "POST", url: "https://shop.test/payments/collect", kind: "fetch")))
        #expect(!NetLog.noise(E(id: 7, method: "POST", url: "https://stats.shop.test/api/orders", kind: "xhr")))
        #expect(!NetLog.noise(E(id: 8, method: "POST", url: "https://shop.test/track", kind: "fetch")))
        #expect(NetLog.noise(E(id: 9, method: "POST", url: "https://o1.ingest.sentry.io/api/1/envelope/", kind: "fetch")))
        #expect(NetLog.noise(E(id: 10, method: "GET", url: "https://www.google.com/gen_204?atyp=i", kind: "xhr")))
    }

    private func clicked(_ n: Int, _ label: String, kind: String = "click") -> U.Step {
        U.Step(number: n, operation: kind == "wait" ? "WAIT" : "CLICK", kind: kind, label: label, text: nil, confidence: 1,
               probability: 1, latencyMs: 0, textLatencyMs: 0, pageChanged: true, url: "")
    }

    @Test func aControlUsedAgainOnAnUnchangedPageIsALoop() {
        let oops: Set<String> = ["Oops, something went wrong.", "Reload"]
        // Flights' Reload twice, a WAIT between, the page reading the same each time.
        let history = [clicked(1, "Search"), clicked(2, "Reload"), clicked(3, "Wait", kind: "wait"), clicked(4, "Reload")]
        let lines: [Int: Set<String>] = [1: ["Search"], 2: oops, 3: oops, 4: oops]
        #expect(U.repeats("click", "Reload", in: history, lines: lines, now: oops) == 2)
        // Something new since (results came in): not a loop.
        #expect(U.repeats("click", "Reload", in: history, lines: lines, now: oops.union(["Zurich to London · 2 h"])) == 0)
        // A prompt naming the next colour each time (uibench swatches): never a loop.
        let swatches = [clicked(1, "button"), clicked(2, "button")]
        #expect(U.repeats("click", "button", in: swatches, lines: [1: ["Click Teal"], 2: ["Click Red"]], now: ["Click Plum"]) == 0)
        #expect(U.repeats("click", "Other", in: history, lines: lines, now: oops) == 0)
    }

    @Test func aSearchsResultsAreAnotherPlace() {
        #expect(U.place("https://www.google.com/travel/flights?tfs=A") == U.place("https://www.google.com/travel/flights?tfs=B"))
        #expect(U.place("https://www.google.com/travel/flights?tfs=A") != U.place("https://www.google.com/travel/flights/search?tfs=A"))
    }

    @Test func aRetrySaysWhatIsOnOffer() {
        let offered = U.offeredOps(targets: ["CLICK": ["10": [:], "2": [:]], "SELECT": ["7:2": [:], "7:1": [:]]], controls: ["WAIT": [:], "SCROLL_DOWN": [:]])
        #expect(offered == "CLICK: 2, 10 · SELECT: 7:1, 7:2 · SCROLL_DOWN · WAIT · DONE · BLOCKED")
    }

    @Test func snapshotSaysWhatItCantTellApart() {
        let swatches = (1...9).map { "  - button [ref=e\($0)]" }.joined(separator: "\n")
        #expect(Tools.snapshotHints(swatches).contains("9 controls have no name"))
        #expect(Tools.snapshotHints("- button \"Approve\" [ref=e1]\n- button \"Reject\" [ref=e2]").isEmpty)
        #expect(Tools.snapshotHints("- checkbox \"I am human\" [ref=e3]").contains("browser_handoff"))
    }

    private func typed(_ value: String) -> U.Step {
        U.Step(number: 1, operation: "TYPE_TEXT", kind: "fill", label: "Where from?", text: value, confidence: 1,
               probability: 1, latencyMs: 0, textLatencyMs: 0, pageChanged: true, url: "")
    }

    @Test func typedCodesMustShow() {
        let goal = "One-way flights ZRH → LHR on 2027-01-20, 1 adult, economy."
        let history = [typed("ZRH"), typed("LHR")]
        // r3's results address carries both airports, base64'd.
        let carried = U.Observation(raw: ["text": "Flights", "actions": [] as [Any],
            "url": "https://www.google.com/travel/flights/search?tfs=CBwQAhoeEgoyMDI3LTAxLTIwagcIARIDWlJIcgcIARIDTEhSQAFIAXABggELCP___________wGYAQI&hl=en"])
        #expect(U.unshownTyped(history, goal: goal, obs: carried).isEmpty)
        // London City picked instead of Heathrow: LHR shows nowhere.
        let city = U.Observation(raw: ["text": "Zurich ZRH to London LCY", "actions": [] as [Any], "url": "https://www.google.com/travel/flights/search?tfs=CBwQAhoeEgoyMDI3LTAxLTIwagcIARIDWlJIcgcIARIDTENZQAFIAXABggELCP___________wGYAQI"])
        #expect(U.unshownTyped(history, goal: goal, obs: city) == ["LHR"])
        // Codes the goal names but nothing typed, or typed words that aren't codes: not checked.
        #expect(U.unshownTyped([], goal: goal, obs: city).isEmpty)
        #expect(U.unshownTyped([typed("Zurich")], goal: "Flights from Zurich to London", obs: city).isEmpty)
    }

    @Test func llmAnswersSayHowSure() throws {
        let targets: [String: [String: [String: Any]]] = ["CLICK": ["7": ["id": "e7"]]]
        let sure = try U.llmDecision(["operation": "CLICK", "target": 7, "confidence": 0.42], targets: targets, controls: [:], latencyMs: 1)
        #expect(sure.choice == "e7" && sure.probability == 0.42)
        #expect(try U.llmDecision(["operation": "DONE"], targets: targets, controls: [:], latencyMs: 1).probability == 1)
        #expect(try U.llmDecision(["operation": "DONE", "confidence": "85"], targets: targets, controls: [:], latencyMs: 1).probability == 0.85)
        #expect(throws: Tools.Failure.self) { try U.llmDecision([:], targets: targets, controls: [:], latencyMs: 1) }
    }
}

@Suite("A date picker's other months")
struct JevCalendarTests {
    private func days(_ month: String, _ count: Int, from node: Int) -> [[String: Any]] {
        (1...count).map { click(node + $0, "button", "Wednesday, \(month) \($0), 2027, 86 US dollars") }
    }

    @Test func goalMonths() {
        #expect(U.calendarMonths("Find one-way flights from Zurich to London on January 20, 2027.") == [1])
        #expect(U.calendarMonths("One-way flights ZRH → LHR on 2027-01-20, 1 adult.") == [1])
        #expect(U.calendarMonths("Flüge von Zürich nach London am 20. Januar 2027.") == [1])
        #expect(U.calendarMonths("Change the date to 20/03/2027") == [3])
        #expect(U.calendarMonths("Open Settings and save").isEmpty)
    }

    @Test func onlyTheGoalsMonthIsRead() {
        let grid = [click(1, "button", "Next")] + days("December", 31, from: 100) + days("January", 31, from: 200)
        let shown = U.elideCalendar(U.Observation(raw: ["actions": grid]), months: [1])
        #expect(shown.actions.count == 32)
        #expect(shown.action("e1") != nil && shown.action("e220") != nil && shown.action("e110") == nil)
        // No month in the goal, or no grid: untouched.
        #expect(U.elideCalendar(U.Observation(raw: ["actions": grid]), months: []).actions.count == grid.count)
        let few = days("December", 5, from: 100)
        #expect(U.elideCalendar(U.Observation(raw: ["actions": few]), months: [1]).actions.count == 5)
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
