import Foundation
import SQLite3
import SwiftUI

// Which agent, in which thread, has its hands on which tab.
//
// Drive keeps one story — the run the timeline pane tells. That is the right
// shape for the pane but the wrong one for the tabs: three terminal agents
// and a Jev run can all be touching pages at once, and the sidebar has to say
// which is which. So beside the run, Drive keeps a Hand per agent session:
// who it is (`Who`), the tabs it touched and when, what it is doing now. The
// tab rows, the bar over the page and the hover card all read these.
//
// A session's identity has to come from the agent's side, because the HTTP
// transport has no sessions of its own. The `--mcp-stdio` bridge and the
// `copper` CLI both run inside the agent's process tree, so they read the
// environment the agent gave them (COPPER_AGENT_LABEL / COPPER_AGENT_THREAD,
// Claude Code's CLAUDE_CODE_SESSION_ID, the working folder) and send it along
// on every request as one `X-Copper-Agent` header. A client that talks HTTP
// directly gets an `Mcp-Session-Id` from `initialize` instead, so two Claude
// Codes on the loopback still read as two.

extension Drive {
    /// One agent session, as the tab rows and the hover card name it.
    struct Who: Equatable, Hashable, Sendable {
        /// Stable for the session: the same thread keeps its hand, and its colour.
        var key: String
        /// "Claude Code", "Jev", "@dev-s · agents", "Copper's agent".
        var agent: String
        /// The thread's human title when one could be found, else the project
        /// folder and a short session id. Empty when nothing was said.
        var thread: String
        /// What the colour is hashed from: the agent app (Fork: covers — it
        /// was the session). A Jev run started by a thread wears that
        /// thread's colour, so the two read as one piece of work.
        var seed: String
        /// For Jev: whose goal it is ("Claude Code").
        var via: String = ""
        var project: String = ""
        var session: String = ""

        /// The bare driver, for paths that know nothing more.
        static func plain(_ driver: Driver) -> Who {
            switch driver {
            case .pane: return Who(key: "pane", agent: driver.name, thread: "this window", seed: "pane")
            case .jev: return Who(key: "jev", agent: "Jev", thread: "", seed: "jev")
            default: return Who(key: driver.name, agent: driver.name, thread: "", seed: driver.name)
            }
        }

        /// A Jev run on someone's behalf: named Jev, labelled with the thread
        /// that asked, coloured like it.
        static func jev(for caller: Who?) -> Who {
            guard let caller, caller.key != "jev" else { return plain(.jev) }
            return Who(key: "jev:" + caller.key, agent: "Jev", thread: caller.thread, seed: caller.seed,
                       via: caller.agent, project: caller.project, session: caller.session)
        }

        /// The one letter on the badge.
        var initial: String {
            if key == "pane" { return "C" }
            let name = agent.hasPrefix("@") ? String(agent.dropFirst()) : agent
            return name.first.map { String($0).uppercased() } ?? "A"
        }

        /// "Jev · Download Copper and Migrate Arc", or just the name.
        var line: String { thread.isEmpty ? agent : "\(agent) · \(thread)" }
    }

    /// One session's hands: which tabs, doing what, since when.
    struct Hand: Identifiable {
        var id: String { who.key }
        var who: Who
        var driver: Driver
        /// The tab it acted on last; the bar over the page follows it.
        var tab: UUID
        /// Every tab it touched, with when — a badge stays on each for `window`.
        var tabs: [UUID: Date]
        /// The last tool call, in Drive's own words: "Clicking Search".
        var doing: String
        /// When this stretch of work began.
        var since: Date
        /// When it last did anything.
        var last: Date
        /// A call is in flight, or a Jev loop is between begin and finish.
        var busy: Bool
        /// A bench stand-in stays on until this instant, calls or none.
        var until: Date?

        func active(on tab: UUID, at now: Date = Date()) -> Bool {
            guard let touched = tabs[tab] else { return false }
            if let until { return until > now }
            if busy, tab == self.tab { return true }
            return now.timeIntervalSince(touched) < Drive.window
        }

        func active(at now: Date = Date()) -> Bool { active(on: tab, at: now) }
    }

    /// How long a badge stays on a tab after the agent's last touch.
    nonisolated static let window: TimeInterval = 30

    // MARK: - bookkeeping

    /// Everyone with a hand on `tab` right now, the one who touched it last first.
    func hands(on tab: UUID) -> [Hand] {
        let now = Date()
        return hands.values.filter { $0.active(on: tab, at: now) }
            .sorted { ($0.tabs[tab] ?? .distantPast) > ($1.tabs[tab] ?? .distantPast) }
    }

    /// A touch: a call starting, a Jev phase opening.
    func touch(_ who: Who, driver: Driver, tab: UUID?, doing: String?, busy: Bool) {
        let now = Date()
        var hand = hands[who.key] ?? Hand(who: who, driver: driver, tab: tab ?? UUID(), tabs: [:], doing: "",
                                          since: now, last: now, busy: false, until: nil)
        if !hand.active(at: now) { hand.since = now }
        hand.who = who
        if let tab { hand.tab = tab; hand.tabs[tab] = now }
        if let doing, !doing.isEmpty { hand.doing = doing }
        hand.last = now
        hand.busy = busy
        hands[who.key] = hand
        Drive.colour(for: who) // claim its colour while it is on screen
        tickIfNeeded()
    }

    /// The call returned, or the Jev loop finished: the hand rests. Its
    /// badges stay for `window` seconds and then go.
    func rest(_ key: String) {
        // Only a hand that was holding on: an agent's run lapsing after its
        // grace must not restart the badge's thirty seconds a second time.
        guard var hand = hands[key], hand.busy else { return }
        let now = Date()
        hand.busy = false
        hand.last = now
        hand.tabs[hand.tab] = now
        hands[key] = hand
    }

    /// Stop one hand. The current run's driver stops the way the pill always
    /// stopped it; any other agent has its next calls refused, the same way.
    func stop(_ key: String) {
        guard let hand = hands[key] else { return }
        if let run, run.who.key == key, live {
            stop()
        } else if hand.until != nil {
            hands[key] = nil   // a bench stand-in: nothing behind it to stop
        } else if hand.driver != .jev {
            refuse(key)
            Agent.shared.stopRecorded(key)
            hands[key] = nil
        }
    }

    /// Whether the hover card's Stop does anything for this hand. A Jev run
    /// that is not the current one has already ended; nothing to stop.
    func canStop(_ hand: Hand) -> Bool {
        if hand.until != nil { return true }
        if let run, run.who.key == hand.who.key, live { return true }
        return hand.driver != .jev && hand.active()
    }

    /// Badges have to go when their thirty seconds are up even if nothing
    /// else changes, so a slow clock runs while any hand is out.
    private func tickIfNeeded() {
        guard handTimer == nil else { return }
        handTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let now = Date()
        let gone = hands.filter { _, hand in
            hand.tabs.keys.allSatisfy { !hand.active(on: $0, at: now) }
        }.map(\.key)
        for key in gone { hands[key] = nil }
        // Republish so rows whose badge just lapsed redraw.
        if gone.isEmpty, hands.values.contains(where: { h in h.tabs.contains { now.timeIntervalSince($0.value) > Drive.window - 1.5 } }) {
            hands = hands
        }
        heartbeat = now
        if hands.isEmpty { handTimer?.invalidate(); handTimer = nil }
    }

    // MARK: - bench stand-ins

    /// A pretend agent through the same model, so the badges, the bar and the
    /// card can be looked at without one: `drive fake NAME THREAD [tab ID] [--for S]`.
    func fake(agent: String, thread: String, tab: UUID, seconds: TimeInterval, doing: String) {
        let who = Who(key: "fake:\(agent):\(thread)", agent: agent, thread: thread, seed: agent, // Fork (covers): by app, as `from`
                      project: "", session: String(UUID().uuidString.prefix(8)).lowercased())
        touch(who, driver: agent == "Jev" ? .jev : .agent(agent), tab: tab, doing: doing, busy: true)
        hands[who.key]?.until = Date().addingTimeInterval(seconds)
    }

    // MARK: - colours

    /// The agents' colours: nine hues spaced round the wheel, each deep enough
    /// to carry white on a light page and bright enough to read on a dark one
    /// or on a space's picture. Copper's own orange is left out — it is Copper's
    /// agent's, and the pill's — and a hue too near the current space's tint
    /// is skipped, so a badge never reads as part of the column.
    struct Swatch: Equatable {
        let hue: Double     // 0…1, for keeping away from the space's tint
        let fill: Color
        let ink: Color      // the letter on it
    }

    static let swatches: [Swatch] = [
        Swatch(hue: 0.99, fill: Color(red: 0.90, green: 0.28, blue: 0.30), ink: .white),  // red
        Swatch(hue: 0.13, fill: Color(red: 0.93, green: 0.69, blue: 0.13), ink: Color(white: 0.12)), // amber
        Swatch(hue: 0.40, fill: Color(red: 0.19, green: 0.64, blue: 0.42), ink: .white),  // green
        Swatch(hue: 0.48, fill: Color(red: 0.07, green: 0.65, blue: 0.58), ink: .white),  // teal
        Swatch(hue: 0.54, fill: Color(red: 0.02, green: 0.62, blue: 0.80), ink: .white),  // cyan
        Swatch(hue: 0.63, fill: Color(red: 0.24, green: 0.39, blue: 0.87), ink: .white),  // blue
        Swatch(hue: 0.71, fill: Color(red: 0.43, green: 0.34, blue: 0.81), ink: .white),  // violet
        Swatch(hue: 0.78, fill: Color(red: 0.56, green: 0.31, blue: 0.78), ink: .white),  // purple
        Swatch(hue: 0.90, fill: Color(red: 0.84, green: 0.25, blue: 0.62), ink: .white),  // pink
    ]

    /// Copper's own agent keeps Copper's colour.
    static let paneSwatch = Swatch(hue: 0.064, fill: DriveStyle.accent, ink: .white)

    /// A seed's colour, once given, is kept for the life of the app, so a
    /// thread that comes back an hour later comes back the same colour.
    @discardableResult
    static func colour(for who: Who) -> Swatch {
        if who.key == "pane" { return paneSwatch }
        if let index = given[who.seed] { return swatches[index] }
        var hash: UInt32 = 2_166_136_261
        for byte in who.seed.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        let start = Int(hash % UInt32(swatches.count))
        let space = Spaces.shared.space.look.hue
        // Others on screen keep theirs; a new one steps past them and past
        // the space's own hue, and only when all are taken shares one.
        let taken = Set(Drive.shared.hands.values.filter { $0.who.seed != who.seed && $0.active() }
            .compactMap { given[$0.who.seed] })
        func near(_ a: Double, _ b: Double?) -> Bool {
            guard let b else { return false }
            let d = abs(a - b)
            return min(d, 1 - d) < 0.045
        }
        var pick = start
        for step in 0..<swatches.count {
            let i = (start + step) % swatches.count
            if !taken.contains(i), !near(swatches[i].hue, space) { pick = i; break }
        }
        given[who.seed] = pick
        return swatches[pick]
    }

    private static var given: [String: Int] = [:]
}

/// The caller of the tool call being served, for code that starts a run from
/// inside it — Jev, which begins its own run and should wear the asking
/// thread's name.
enum DriveCaller {
    @TaskLocal static var who: Drive.Who?
}

// MARK: - identity from a request

extension Drive.Who {
    /// The fields an agent sends about itself, from the `X-Copper-Agent`
    /// header, `_meta["copper/agent"]`, or `initialize`'s clientInfo.
    struct Said {
        var name = ""        // the MCP client's own name, from initialize
        var label = ""       // COPPER_AGENT_LABEL: what to call it, overriding all else
        var thread = ""      // COPPER_AGENT_THREAD
        var session = ""     // a session or thread id from the agent's environment
        var harness = ""     // the agent the CLI or bridge is running under, as detected
        var client = ""      // "copper-cli" / "copper-bridge"
        var instance = ""    // one bridge process: a session when nothing better is said
        var project = ""     // the working folder's name
        var t3home = ""      // T3CODE_HOME, where P3/T3 keeps its threads

        init() {}
        init(_ d: [String: Any]) {
            func s(_ k: String) -> String { ((d[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            name = s("name"); label = s("label"); thread = s("thread"); session = s("session"); harness = s("harness")
            client = s("client"); instance = s("instance"); project = s("project"); t3home = s("t3home")
        }

        /// Fields set here win over `other`'s.
        func over(_ other: Said) -> Said {
            var out = other
            for (k, v) in [(\Said.name, name), (\.label, label), (\.thread, thread), (\.session, session), (\.harness, harness),
                           (\.client, client), (\.instance, instance), (\.project, project), (\.t3home, t3home)] where !v.isEmpty {
                out[keyPath: k] = v
            }
            return out
        }

        static func header(_ raw: String?) -> Said {
            guard let raw, let data = Data(base64Encoded: raw),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Said() }
            return Said(d)
        }
    }

    /// Put a name and a thread to what was said. `mcpSession` is the
    /// transport's own session, for a client that said nothing else.
    @MainActor
    static func from(_ said: Said, mcpSession: String?, fallbackName: String) -> Drive.Who {
        let agent: String = {
            if !said.label.isEmpty { return said.label }
            if !said.name.isEmpty { return MCP.pretty(client: said.name) }
            if !said.harness.isEmpty { return MCP.pretty(client: said.harness) }
            if !said.client.isEmpty { return MCP.pretty(client: said.client) }
            return fallbackName.isEmpty ? "Agent" : fallbackName
        }()
        let session = !said.session.isEmpty ? said.session : (!said.instance.isEmpty ? said.instance : (mcpSession ?? ""))
        let short = String(session.prefix(8)).lowercased()
        let thread: String = {
            if !said.thread.isEmpty { return said.thread }
            if !said.session.isEmpty, let title = Threads.title(for: said.session, home: said.t3home) { return title }
            switch (said.project.isEmpty, short.isEmpty) {
            case (false, false): return "\(said.project) · \(short)"
            case (false, true): return said.project
            case (true, false): return short
            default: return ""
            }
        }()
        let key = "\(agent):\(session.isEmpty ? said.project : session)"
        // Fork (covers, hill-climb r5): coloured by the app, not the session —
        // two Claude Code threads are one agent to look at (they were lavender
        // and cyan); the thread's name tells them apart.
        return Drive.Who(key: key, agent: agent, thread: thread, seed: agent,
                         project: said.project, session: short)
    }
}

// MARK: - thread titles

/// A thread's title from the coding app it lives in. P3 / T3 Code keeps its
/// threads in `state.sqlite` under ~/.t3 (or T3CODE_HOME), and each thread's
/// provider runtime row carries the agent's own session id in its resume
/// cursor — so the Claude Code session id an agent has in its environment
/// leads straight to the title the user sees in P3's sidebar. Read-only, and
/// cached: titles are regenerated after the first turn, so a miss or an old
/// answer is looked at again after a minute.
@MainActor
enum Threads {
    private static var cache: [String: (title: String?, at: Date)] = [:]

    static func title(for session: String, home: String) -> String? {
        let id = session.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard id.count >= 8 else { return nil }
        if let hit = cache[id], Date().timeIntervalSince(hit.at) < 60 { return hit.title }
        let base = home.isEmpty ? (NSHomeDirectory() as NSString).appendingPathComponent(".t3") : (home as NSString).expandingTildeInPath
        let title = lookUp(id, in: (base as NSString).appendingPathComponent("userdata/state.sqlite"))
        cache[id] = (title, Date())
        return title
    }

    private static func lookUp(_ id: String, in path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        let sql = """
            SELECT t.title FROM provider_session_runtime r JOIN projection_threads t USING(thread_id)
            WHERE (r.resume_cursor_json LIKE ?1 OR r.thread_id = ?2) AND t.deleted_at IS NULL
            ORDER BY r.last_seen_at DESC LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, "%\"\(id)\"%", -1, transient)
        sqlite3_bind_text(statement, 2, id, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        let title = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
}

// MARK: - the agent's side

/// What the bridge and the CLI say about the agent they run under, read from
/// the environment it gave them. One header, base64 JSON, so a thread title
/// in any script survives HTTP.
enum AgentEnvironment {
    /// The bridge is one process per agent session: its own id stands in for
    /// a session when the agent's environment names none.
    static let instance = String(UUID().uuidString.prefix(8)).lowercased()

    static func fields(client: String, name: String = "") -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        func first(_ keys: [String]) -> String {
            for k in keys { if let v = env[k]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v } }
            return ""
        }
        var out: [String: String] = ["client": client]
        out["label"] = first(["COPPER_AGENT_LABEL"])
        out["thread"] = first(["COPPER_AGENT_THREAD"])
        out["session"] = first(["COPPER_AGENT_SESSION", "CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID", "CODEX_SESSION_ID",
                                "T3CODE_THREAD_ID", "P3_THREAD_ID", "P3CODE_THREAD_ID"])
        out["harness"] = {
            if env["CLAUDECODE"] == "1" || env["CLAUDE_CODE_SESSION_ID"] != nil { return "Claude Code" }
            if env["CODEX_THREAD_ID"] != nil || env["CODEX_SESSION_ID"] != nil || env["CODEX_MANAGED_BY_NPM"] != nil { return "Codex" }
            if env["PI_CODING_AGENT"] != nil || env["PHI_SESSION_ID"] != nil { return "phi" }
            return ""
        }()
        out["t3home"] = first(["T3CODE_HOME"])
        let cwd = FileManager.default.currentDirectoryPath
        if cwd != "/" && cwd != NSHomeDirectory() { out["project"] = (cwd as NSString).lastPathComponent }
        if client == "copper-bridge" { out["instance"] = instance }
        if !name.isEmpty { out["name"] = name }
        return out.filter { !$0.value.isEmpty }
    }

    static func header(client: String, name: String = "") -> String {
        let data = (try? JSONSerialization.data(withJSONObject: fields(client: client, name: name))) ?? Data("{}".utf8)
        return data.base64EncodedString()
    }
}
