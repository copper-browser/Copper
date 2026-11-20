import Foundation

// Fork (jev-dump): jev_dump writes what Copper would send Jev for a page, a
// run's first decision (nothing done yet), to a JSON file, and calls no Jev:
// page states for training a small decision model (perf/crawl.py,
// ~/plans/hegemon-mini-jev). Test and dev worlds only, like SEARCH_JEV_LOG.
// The read, the table and the request are Session's own (observe,
// elideCalendar, availability, request), so the state matches serve time.
// A harness tool: callable by name, never in tools/list (its 25 kB budget).
//   jev_dump {url, out, wait_ms?, goal_hint?} → {ok, out, elements, chars}
// chars = the state as JSON; goal_hint = the goal the read and questions are for.
extension Tools.Ultrafast {
    @MainActor
    static func dumpPage(_ args: [String: Any], in browser: Browser) async throws -> [Tools.Content] {
        guard Store.world != nil else { throw Tools.Failure(text: "jev_dump runs in test and dev worlds only") }
        guard let raw = args["url"] as? String, let url = Address.url(from: raw) else { throw Tools.Failure(text: "url required") }
        guard let path = args["out"] as? String, !path.isEmpty else { throw Tools.Failure(text: "out required: a .json path") }
        let out = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let goal = ((args["goal_hint"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let waitMs = min(max((args["wait_ms"] as? NSNumber)?.intValue ?? 0, 0), 20_000)

        let started = Date()
        let tab = browser.open(url, foreground: false)
        AgentTabs.opened.insert(tab.id)
        AgentTabs.bind(tab)
        AgentTabs.prepare(tab)
        defer { Tools.close(tab) }
        try await Tools.settle(tab, navigating: true)
        if waitMs > 0 { try await Task.sleep(nanoseconds: UInt64(waitMs) * 1_000_000) }

        // As Session's first decision: this Mac's strategy, the read that waits for the page to stand still.
        let strategy = Intelligence.shared.keys.jevFast ? Strategy.shipped : Strategy()
        let obs = try await observe(tab, after: strategy.near ? ["kind": "read"] : nil, terms: strategy.reach ? goalTerms(goal) : nil,
                                    near: strategy.near, calm: strategy.calm, deep: strategy.deep)
        let shown = strategy.lean ? elideCalendar(obs, months: calendarMonths(goal)) : obs
        let available = await availability(tab)
        let r = request(shown, goal: goal, history: [], signInAvailable: available.signIn, autofill: available.autofill, strategy: strategy)
        // As sent (AgentSecrets) and as logged (JevLog: card and password values out).
        let hidden = shown.actions.filter { ($0["sensitive"] as? Bool) == true }
            .flatMap { [$0["value"] as? String, $0["current_value"] as? String].compactMap { $0 } }
            .filter { !$0.isEmpty && $0 != AgentSecrets.placeholder }
        let body = Jev.body(model: Intelligence.shared.effective.jevModel, state: r.state, questions: r.questions)
        let state = JevLog.redact(body["state"] ?? [String: Any](), hiding: hidden)
        let questions = JevLog.redact(body["questions"] ?? [String: Any](), hiding: hidden)
        // What questions.py needs to ask the same for another goal: the fields a named value can go in.
        let values = valueQuestions(["·"], fills: r.fills, goal: "")["value_1"] as? [String: Any]

        let stateData = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys, .withoutEscapingSlashes])
        let elements = ((state as? [String: Any])?["elements"] as? [Any])?.count ?? 0
        let text = (((state as? [String: Any])?["page"] as? [String: Any])?["text"] as? String) ?? ""
        let chars = String(decoding: stateData, as: UTF8.self).count
        let file: [String: Any] = [
            "v": 1, "ts": ISO8601DateFormatter().string(from: Date()), "requested_url": raw, "world": Store.world.map { $0 as Any } ?? NSNull(),
            "strategy": strategy.name, "model": body["model"] ?? NSNull(), "goal_hint": goal.isEmpty ? NSNull() as Any : goal,
            "state": state, "questions": questions,
            "copper": ["value_criteria": values?["criteria"] ?? NSNull(), "value_rule": valueRule, "unmet_statement": unmetStatement, "literals": r.quoted,
                       "omitted": shown.omitted, "text_chars": text.count, "state_chars": chars] as [String: Any],
            "ms": Int(Date().timeIntervalSince(started) * 1000),
        ]
        let data = try JSONSerialization.data(withJSONObject: file, options: [.sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: out, options: .atomic)
        return [.text(encodeJSON(["ok": true, "out": out.path, "elements": elements, "chars": chars]))]
    }
}
