import AppKit
import Foundation
import Testing
import WebKit
@testable import Search

// SEARCH_JEV_LOG's lines: the format a data builder reads, what is never in
// them (keys, picture bytes, secret and card values), and the run line that
// joins a run's calls by run_id.

private typealias U = Tools.Ultrafast

private func json(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }

/// A 2×3 PNG, small enough to write out here.
private func png(width: Int, height: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
}

@Suite("Jev call log")
struct JevLogTests {
    @Test func lineHasTheFormatAndNoSecrets() throws {
        let tab = UUID()
        AgentSecrets.remember("hunter2-secret", tab: tab)
        defer { AgentSecrets.forget(tab: tab) }
        let state: [String: Any] = [
            "page": ["url": "https://shop.test/checkout", "title": "Pay", "text": "Card ends 4242 · exp 12 · pw hunter2-secret"],
            "elements": [
                ["index": "1", "role": "textbox", "label": "Password", "value": AgentSecrets.placeholder],
                ["index": "2", "role": "textbox", "label": "Expiry month", "value": "12"],
                ["index": "3", "role": "textbox", "label": "Name on card", "value": "Ada Lovelace"],
                ["index": "4", "role": "textbox", "label": "Search", "value": "12 flights"],
            ],
            "recent_actions": [["action": "TYPE_TEXT", "text": "Ada Lovelace"]],
        ]
        let questions: [String: Any] = ["operation": Jev.choice("Which?", ["CLICK": "click", "DONE": "done"])]
        // What Jev.ask sends: the scrubbed body (AgentSecrets), assets taken out.
        let body = Jev.body(model: "jev-1.14.0", state: state, questions: questions)
        let asset = Jev.Asset(reference: "shot-1", data: png(width: 2, height: 3), format: "png")
        let payload: [String: Any] = [
            "answers": ["operation": ["choice": "CLICK", "confidence": 0.91, "probabilities": ["CLICK": 0.93, "DONE": 0.07]]],
            "usage": ["input_tokens": 1234], "model": "jev-1.14.0",
        ]
        let line = JevLog.line(body: body, assets: [asset], payload: payload, latencyMs: 87.34, date: Date(timeIntervalSince1970: 1_800_000_000),
                               run: "r-1", step: 3, strategy: "turbo", world: "dev", hidden: ["12", "Ada Lovelace"])
        let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        let text = String(decoding: data, as: UTF8.self)
        let back = json(data)

        #expect(back["v"] as? Int == 1 && back["run_id"] as? String == "r-1" && back["step"] as? Int == 3)
        #expect(back["world"] as? String == "dev" && back["host"] as? String == "shop.test" && back["url"] as? String == "https://shop.test/checkout")
        #expect(back["strategy"] as? String == "turbo" && back["model"] as? String == "jev-1.14.0")
        #expect(back["latency_ms"] as? Double == 87.3)
        #expect((back["ts"] as? String)?.hasPrefix("2027-01-15T") == true)
        let request = try #require(back["request"] as? [String: Any])
        #expect(Set(request.keys) == ["state", "questions"])
        let response = try #require(back["response"] as? [String: Any])
        let op = try #require((response["answers"] as? [String: Any])?["operation"] as? [String: Any])
        // JSONSerialization may print a double with its last bits (0.07000000000000001): the same double read back.
        let done = try #require((op["probabilities"] as? [String: Any])?["DONE"] as? Double)
        #expect(abs(done - 0.07) < 1e-12 && abs((op["confidence"] as? Double ?? 0) - 0.91) < 1e-12)
        #expect((response["usage"] as? [String: Any])?["input_tokens"] as? Int == 1234 && response["model"] as? String == "jev-1.14.0")
        let assets = try #require(back["assets"] as? [[String: Any]])
        #expect(assets.count == 1 && assets[0]["ref"] as? String == "shot-1" && assets[0]["w"] as? Int == 2 && assets[0]["h"] as? Int == 3)
        #expect(assets[0]["bytes"] as? Int == asset.data.count)
        #expect(back["executed"] as? Bool == false && back["chosen"] is NSNull)

        // Never in a line: picture bytes, a key, a filled secret, a card field's value.
        #expect(!text.contains("data_base64") && !text.contains(asset.data.base64EncodedString()))
        #expect(!text.contains("Authorization") && !text.contains("Bearer"))
        #expect(!text.contains("hunter2-secret"))
        #expect(!text.contains("Ada Lovelace"))
        let elements = try #require((request["state"] as? [String: Any])?["elements"] as? [[String: Any]])
        #expect(elements[1]["value"] as? String == AgentSecrets.placeholder) // a short card value, as the whole value
        #expect(elements[3]["value"] as? String == "12 flights")             // …but not cut out of other words
        #expect(elements[2]["value"] as? String == AgentSecrets.placeholder)
    }

    @Test func writesDailyFileAndRunLineJoins() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jevlog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let tick = JevLog.Tick(run: "r-9", step: 1, strategy: "turbo")
        tick.add(JevLog.line(body: ["model": "jev-latest", "state": ["page": ["url": "https://en.wikipedia.org/wiki/Cat"]], "questions": [String: Any]()],
                             assets: [], payload: ["answers": [String: Any]()], latencyMs: 50, date: Date(), run: "r-9", step: 1, strategy: "turbo", world: "test", hidden: []))
        tick.chosen = ["operation": "CLICK", "target": "7"]
        let calls = tick.take().map { var c = $0; c["chosen"] = tick.chosen; c["executed"] = true; return c }
        JevLog.write(calls, to: folder, sync: true)
        JevLog.write([JevLog.runLine(run: "r-9", goal: "Reach Dog", status: "done", steps: 4, wallMs: 9000, answer: nil)], to: folder, sync: true)
        #expect(tick.take().isEmpty)

        let file = JevLog.file(in: folder)
        #expect(file.lastPathComponent.range(of: #"^jev-\d{8}\.jsonl$"#, options: .regularExpression) != nil)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { json(Data($0.utf8)) }
        #expect(lines.count == 2)
        #expect(lines[0]["host"] as? String == "en.wikipedia.org" && lines[0]["executed"] as? Bool == true)
        #expect((lines[0]["chosen"] as? [String: Any])?["target"] as? String == "7")
        #expect(lines[1]["kind"] as? String == "run" && lines[1]["run_id"] as? String == lines[0]["run_id"] as? String)
        #expect(lines[1]["status"] as? String == "done" && lines[1]["steps"] as? Int == 4 && lines[1]["answer"] == nil)
    }
}

@MainActor
private final class Loaded: NSObject, WKNavigationDelegate {
    var done: CheckedContinuation<Void, Never>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
}

@MainActor private var kept: [AnyObject] = []

/// The page script marks card and secret fields `sensitive` (the log's cue) and nothing else.
@MainActor @Test func pageMarksCardFieldsSensitive() async throws {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = web
    window.orderBack(nil)
    let loaded = Loaded()
    web.navigationDelegate = loaded
    let html = """
    <html><body>
    <input aria-label="Expiry" autocomplete="cc-exp" value="12/29">
    <input aria-label="Name on card" autocomplete="cc-name" value="Ada Lovelace">
    <input aria-label="Code" autocomplete="one-time-code" value="123456">
    <input aria-label="Search" value="cats">
    </body></html>
    """
    await withCheckedContinuation { c in loaded.done = c; web.loadHTMLString(html, baseURL: URL(string: "https://jev.test/")) }
    kept += [window, loaded]
    let obs = try await U.js(web, "window.__jevFast.observe(undefined, {deep: false})") as? [String: Any]
    let fills = ((obs?["actions"] as? [[String: Any]]) ?? []).filter { $0["kind"] as? String == "fill" }
    func sensitive(_ label: String) -> Bool? { fills.first { $0["label"] as? String == label }.map { ($0["sensitive"] as? Bool) == true } }
    #expect(sensitive("Expiry") == true && sensitive("Name on card") == true && sensitive("Code") == true)
    #expect(sensitive("Search") == false)
    // What Jev itself is sent is unchanged: the one-time code reads as the placeholder, a card's expiry as itself.
    #expect(fills.first { $0["label"] as? String == "Code" }?["value"] as? String == AgentSecrets.placeholder)
    #expect(fills.first { $0["label"] as? String == "Expiry" }?["value"] as? String == "12/29")
}
