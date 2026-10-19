import Foundation

/// Who has the wheel, and what they are doing with it.
///
/// One model for every hand on the page that is not the user's: a Jev run
/// (Ultrafast.swift writes its cycles here as it goes), an agent on the
/// loopback server calling the browser_* tools one at a time (phi, Claude
/// Code, the `copper` CLI), a bot reaching in through an agent link, and the
/// agent in Copper's own pane. Each of them is a Run: a driver, a list of
/// Cycles — for Jev a cycle is read → ask → act → settle; for a tool call it
/// is the one call, timed — and an outcome per cycle in the page's own words.
///
/// The agent pane's driver cards (DriveCard) and the pill over the page only read this.
/// `stop()` is the one thing that travels the other way: a Jev session checks
/// `stopRequested` before its next action; an agent's next tool call is
/// refused (`refusal`) until the user lets it back in or the window passes.
///
/// A run by an agent has no natural end — the agent calls, thinks, calls
/// again — so it stays live through `grace` seconds after each call and ends
/// on its own when nothing more comes. Jev runs end when the loop says so.
@MainActor
final class Drive: ObservableObject {
    static let shared = Drive()

    /// The live run, or the last one until a new one starts or `dismiss()`.
    /// The agent pane's transcript is told each time it becomes another
    /// run, so a run that is replaced is kept there as it ended.
    @Published private(set) var run: Run? {
        didSet { if oldValue?.id != run?.id { Agent.shared.driveChanged(from: oldValue, to: run) } }
    }
    /// True while someone has the wheel: a Jev loop between begin and finish,
    /// or an agent between its first call and `grace` seconds after its last.
    @Published private(set) var live = false
    /// A call is in flight right now. Between calls a live driver is thinking.
    @Published private(set) var busy = false
    /// The pane beside the page, which is the agent's: a run is a card in
    /// its conversation. Set true when a run begins; the user may close it.
    var paneOpen: Bool {
        get { Agent.shared.open }
        set { if newValue { Agent.shared.reveal() } else { Agent.shared.open = false } }
    }
    /// Set by `stop()`; a Jev Session reads it and ends with status "stopped".
    @Published private(set) var stopRequested = false
    /// After Stop on an agent's run: tool calls are refused until this instant.
    @Published private(set) var refusingUntil: Date?
    /// Every agent session with a hand on a tab right now, by `Who.key`
    /// (Hands.swift). The run above is the one story the pane tells; these
    /// are what the tab badges and the bar over the page show.
    @Published var hands: [String: Hand] = [:]
    /// Ticks once a second while any hand is out, so views that show "for
    /// 12 s" and badges that lapse redraw without a call to prompt them.
    @Published var heartbeat = Date()
    var handTimer: Timer?
    /// The bench's way to open a tab's hover card without a pointer.
    @Published var forcedCard: UUID?
    /// Stop is per session: one agent taken off the wheel must not refuse
    /// every other agent's calls. Key → refused until.
    private var refusedKeys: [String: Date] = [:]

    /// How long an agent's run stays live after a call, waiting for the next.
    /// Agents think between calls — ten, twenty seconds is ordinary — and the
    /// pill should not blink off in the middle of a task.
    static let grace: TimeInterval = 30
    /// A run that let go this recently is picked up again by the same driver
    /// rather than started over, so one task reads as one timeline.
    static let revival: TimeInterval = 180
    /// How long Stop keeps refusing an agent's calls.
    static let refusal: TimeInterval = 30

    /// Whose hands are on the page.
    enum Driver: Equatable {
        /// The Jev loop, driving towards a goal on its own.
        case jev
        /// An MCP client on the loopback server, by the name it gave at
        /// `initialize` — "Claude Code", "phi", "copper CLI" — or plain "Agent".
        case agent(String)
        /// A bot through an agent link: "@dev-s · agents".
        case bot(String)
        /// The agent in Copper's own pane.
        case pane

        var name: String {
            switch self {
            case .jev: return "Jev"
            case .agent(let name): return name.isEmpty ? "Agent" : name
            case .bot(let handle): return handle.isEmpty ? "Bot" : handle
            case .pane: return "Copper's agent"
            }
        }
    }

    struct Run: Identifiable {
        let id: UUID
        let driver: Driver
        /// Which session of that driver: two Claude Codes are two runs. Kept
        /// current — a thread's title can arrive or change mid-run.
        var who: Who
        /// Jev's goal. Empty for an agent, which never says one.
        let goal: String
        let tabID: UUID
        let started: Date
        var ended: Date?
        var status: Status
        var note: String
        var cycles: [Cycle]
        var url: String               // last seen
        var title: String             // last seen
        /// The latest thing the driver said about what it is doing: an agent's
        /// `reason` on a tool call, or what the model wrote before calling.
        var thought: String?
        var thoughtAt: Date?
    }

    enum Status: String { case running, done, blocked, budget, error, stopped, ended }

    struct Cycle: Identifiable {
        let id: UUID
        let number: Int               // 1-based
        let started: Date
        var phases: [Phase]
        var outcome: Outcome?
        var ended: Date?
    }

    struct Phase: Identifiable {
        let id: UUID
        let kind: Kind
        var title: String             // "Reading the page", "Clicking Search"
        var detail: String?           // "38 controls · Google Flights", the agent's reason
        let started: Date
        var ended: Date?
        var ms: Int? { ended.map { Int($0.timeIntervalSince(started) * 1000) } }
        enum Kind: String { case observe, ask, write, act, settle }
    }

    struct Outcome {
        var operation: String         // CLICK / TYPE_TEXT / SELECT / SCROLL / WAIT / DONE / BLOCKED / READ / GO …
        var label: String             // target label as the page or the agent names it
        var text: String?             // typed value if any
        var probability: Double       // 0…1 (Jev); 1 for a tool call
        var confidence: Double
        var pageChanged: Bool?        // nil until the settle read
        var stale: Bool               // the page moved under the decision; nothing executed
        var candidates: [String]      // up to 5 "[7] button Search" lines Jev was offered
        /// What went wrong, when the call failed. Empty when it didn't.
        var error: String?
        /// What the tool itself said it did (`Tools.summary`): "220
        /// operations applied", "Read 7 shapes". Said instead of whether the
        /// page moved, which is no measure of a call that doesn't navigate.
        var result: String?

        init(operation: String, label: String, text: String? = nil, probability: Double = 1, confidence: Double = 1,
             pageChanged: Bool? = nil, stale: Bool = false, candidates: [String] = [], error: String? = nil) {
            self.operation = operation; self.label = label; self.text = text
            self.probability = probability; self.confidence = confidence
            self.pageChanged = pageChanged; self.stale = stale; self.candidates = candidates; self.error = error
        }
    }

    private var graceTimer: Timer?
    private var refusalTimer: Timer?
    /// The tab an agent's calls land on, for taking the trail off it when the
    /// run ends. Jev clears its own.
    private weak var driven: Tab?

    // MARK: - lifecycle (Jev and shared)

    /// A fresh run. The pane opens itself; a stop asked for during the last
    /// one does not carry over.
    /// A Jev run wears the name of the thread whose tool call started it.
    func begin(goal: String, tab: Tab) { begin(driver: .jev, goal: goal, tab: tab, who: .jev(for: DriveCaller.who)) }

    func begin(driver: Driver, goal: String = "", tab: Tab?, who: Who? = nil) {
        graceTimer?.invalidate(); graceTimer = nil
        let who = who ?? .plain(driver)
        if live { finish(.ended, note: "Another driver took over") }
        run = Run(id: UUID(), driver: driver, who: who, goal: goal, tabID: tab?.id ?? UUID(), started: Date(), ended: nil,
                  status: .running, note: "", cycles: [], url: tab?.address?.absoluteString ?? "", title: tab?.title ?? "",
                  thought: nil, thoughtAt: nil)
        stopRequested = false
        live = true
        // The pane comes up for work on the page you are looking at. Work in
        // a background tab stays out of your way: its row wears the agent's
        // badge, and the pane is there if you open it.
        if AgentTabs.onScreen(tab), !AgentTabs.behind { paneOpen = true }
        touch(who, driver: driver, tab: tab?.id, doing: goal.isEmpty ? nil : goal, busy: driver == .jev)
    }

    /// Opens a cycle and returns its id.
    ///
    /// Not every cycle reaches an outcome: the page can move under the
    /// decision, or the budget can run out mid-read. The one before this
    /// ends here either way, so nothing is left spinning behind the new one.
    @discardableResult
    func cycle() -> UUID {
        let id = UUID()
        guard let run else { return id }
        if let last = run.cycles.indices.last, run.cycles[last].ended == nil {
            let now = Date()
            for p in run.cycles[last].phases.indices where run.cycles[last].phases[p].ended == nil {
                self.run?.cycles[last].phases[p].ended = now
            }
            self.run?.cycles[last].ended = now
        }
        self.run?.cycles.append(Cycle(id: id, number: run.cycles.count + 1, started: Date(), phases: [], outcome: nil, ended: nil))
        return id
    }

    /// Opens a phase in the current cycle and returns its id.
    @discardableResult
    func phase(_ kind: Phase.Kind, _ title: String, detail: String? = nil) -> UUID {
        let id = UUID()
        guard let run, !run.cycles.isEmpty else { return id }
        self.run?.cycles[run.cycles.count - 1].phases.append(
            Phase(id: id, kind: kind, title: title, detail: detail, started: Date(), ended: nil))
        // The hover card's "doing now" is the phase that just opened. A Jev
        // loop stays busy between phases; a tool call's busy is its own.
        if live { touch(run.who, driver: run.driver, tab: run.tabID, doing: title, busy: run.driver == .jev ? true : busy) }
        return id
    }

    /// Closes a phase; a detail given here replaces the one it opened with.
    func close(phase id: UUID, detail: String? = nil) {
        guard let run else { return }
        for c in run.cycles.indices.reversed() {
            guard let p = run.cycles[c].phases.lastIndex(where: { $0.id == id }) else { continue }
            self.run?.cycles[c].phases[p].ended = Date()
            if let detail { self.run?.cycles[c].phases[p].detail = detail }
            return
        }
    }

    /// What the cycle amounted to. The cycle closes with it.
    func outcome(_ o: Outcome) {
        guard let run, !run.cycles.isEmpty else { return }
        let last = run.cycles.count - 1
        self.run?.cycles[last].outcome = o
        self.run?.cycles[last].ended = Date()
    }

    /// Where the page stands, as of the last read.
    func page(url: String, title: String) {
        guard run != nil else { return }
        run?.url = url
        run?.title = title
    }

    /// What the driver says it is doing, in its own words. Kept short.
    func thought(_ text: String) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard run != nil, !line.isEmpty else { return }
        run?.thought = line.count > 400 ? String(line.prefix(399)) + "…" : line
        run?.thoughtAt = Date()
    }

    /// The end state. The pane stays open so the trace can be read after.
    func finish(_ status: Status, note: String) {
        graceTimer?.invalidate(); graceTimer = nil
        busy = false
        guard let run else { live = false; return }
        // Whatever was still in flight ended here; nothing is left spinning.
        let now = Date()
        for c in run.cycles.indices {
            for p in run.cycles[c].phases.indices where run.cycles[c].phases[p].ended == nil {
                self.run?.cycles[c].phases[p].ended = now
            }
            if run.cycles[c].ended == nil { self.run?.cycles[c].ended = now }
        }
        self.run?.ended = Date()
        self.run?.status = status
        self.run?.note = note
        live = false
        stopRequested = false
        rest(run.who.key)
        if run.driver != .jev { clearTrail() }
    }

    /// The hard stop. A Jev loop ends before its next action; an agent's
    /// next call is refused, for `refusal` seconds, so it stops and says so.
    func stop() {
        guard live, let run else { return }
        switch run.driver {
        case .jev:
            stopRequested = true
            // A run with no loop behind it to hear the request — a seeded
            // card, a session already torn down — ends here, or it would
            // sit "running" with a Stop that does nothing.
            if Tools.Ultrafast.sessions[run.tabID]?.finished ?? true { finish(.stopped, note: "Stopped by you") }
        case .agent, .bot, .pane:
            refuse(run.who.key)
            refusingUntil = Date().addingTimeInterval(Drive.refusal)
            refusalTimer?.invalidate()
            refusalTimer = Timer.scheduledTimer(withTimeInterval: Drive.refusal, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            }
            if run.driver == .pane { Agent.shared.stop() }
            finish(.stopped, note: "Stopped by you — calls refused for \(Int(Drive.refusal)) s")
        }
    }

    /// Let the agent back in before the refusal window passes.
    func resume() {
        refusalTimer?.invalidate(); refusalTimer = nil
        refusingUntil = nil
        refusedKeys = [:]
    }

    /// Turn one session's calls away for `refusal` seconds.
    func refuse(_ key: String) {
        refusedKeys[key] = Date().addingTimeInterval(Drive.refusal)
    }

    /// Why a call from this session must not run right now, in words for the
    /// agent — or nil. Only the session that was stopped is refused.
    func refusal(for key: String) -> String? {
        let now = Date()
        refusedKeys = refusedKeys.filter { $0.value > now }
        if refusingUntil.map({ $0 <= now }) == true { refusingUntil = nil }
        guard refusedKeys[key] != nil else { return nil }
        return "Stopped by the user in Copper: they took the browser back. Do not retry; tell them what you were doing and wait until they ask you to continue."
    }

    /// The pane's agent, which is one session.
    var refusal: String? { refusal(for: Who.plain(.pane).key) }

    /// Put the last run away. Only when nothing is running. Its card stays
    /// in the conversation, as it ended; the pane stays as it is.
    func dismiss() {
        guard !live else { return }
        run = nil
    }

    /// The bench's way to picture a card: a whole run, as given, without a
    /// driver behind it. Live until `finish` or Stop.
    func seed(_ seeded: Run, live: Bool) {
        graceTimer?.invalidate(); graceTimer = nil
        run = seeded
        self.live = live
        busy = false
    }

    // MARK: - tool calls

    /// One tool call in flight, for `ended(_:)`.
    struct Ticket {
        let run: UUID
        let who: String
        let phase: UUID
        let url: String
        let title: String
        let tool: String
        let args: [String: Any]
    }

    /// An agent's tool call is starting. Opens the driver's run when there is
    /// none live (or another driver's), adds the call as a cycle, and returns
    /// a ticket for `ended`. Jev's own tools (jev_run, jev_step) own their run
    /// and get nothing here; a live Jev run is never interrupted by a stray
    /// call either — it is the story being told.
    func began(call tool: String, args: [String: Any], by driver: Driver, who: Who? = nil, tab: Tab?) -> Ticket? {
        if tool == "jev_run" || tool == "jev_step" { return nil }
        let who = who ?? .plain(driver)
        let beside = live && run?.driver == .jev
        touch(who, driver: driver, tab: tab?.id, doing: Drive.words(for: tool, args).0, busy: true)
        if beside {
            // Keep the call in the same transcript, without replacing the
            // Jev session whose phase callbacks still own `run`.
            let now = Date()
            let (title, detail) = Drive.words(for: tool, args)
            let phase = Phase(id: UUID(), kind: .act, title: title, detail: detail, started: now)
            let side = Run(id: UUID(), driver: driver, who: who, goal: "", tabID: tab?.id ?? UUID(), started: now,
                           status: .running, note: "", cycles: [Cycle(id: UUID(), number: 1, started: now, phases: [phase])],
                           url: tab?.address?.absoluteString ?? "", title: tab?.title ?? "", thought: args["reason"] as? String)
            Agent.shared.record(side)
            return Ticket(run: side.id, who: who.key, phase: phase.id, url: side.url, title: side.title, tool: tool, args: args)
        }
        if !live || run?.who.key != who.key || run?.status != .running {
            if let run, run.who.key == who.key, run.status == .ended,
               let ended = run.ended, Date().timeIntervalSince(ended) < Drive.revival {
                // The same driver, back within a few minutes: the same task.
                self.run?.status = .running
                self.run?.ended = nil
                self.run?.note = ""
                live = true
                if AgentTabs.onScreen(tab), !AgentTabs.behind { paneOpen = true }
            } else {
                begin(driver: driver, tab: tab, who: who)
            }
        }
        self.run?.who = who
        graceTimer?.invalidate(); graceTimer = nil
        busy = true
        if let tab { driven = tab }
        if let reason = (args["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            thought(reason)
        }
        cycle()
        let (title, detail) = Drive.words(for: tool, args)
        let phase = phase(.act, title, detail: detail)
        if let tab { page(url: tab.address?.absoluteString ?? "", title: tab.title) }
        return Ticket(run: run?.id ?? UUID(), who: who.key, phase: phase, url: tab?.address?.absoluteString ?? "", title: tab?.title ?? "", tool: tool, args: args)
    }

    /// The call returned. Closes its row with what came of it, and starts the
    /// grace clock: the run ends by itself when no call follows.
    func ended(_ ticket: Ticket, error: String?, summary: String? = nil, tab: Tab?) {
        rest(ticket.who)
        guard var target = Agent.shared.run(ticket.run),
              let cycle = target.cycles.firstIndex(where: { $0.phases.contains(where: { $0.id == ticket.phase }) }) else { return }
        let now = Date()
        for p in target.cycles[cycle].phases.indices where target.cycles[cycle].phases[p].id == ticket.phase {
            target.cycles[cycle].phases[p].ended = now
        }
        let url = tab?.address?.absoluteString ?? ticket.url
        let title = tab?.title ?? ticket.title
        let moved = url != ticket.url || (title != ticket.title && !title.isEmpty)
        let changes = Drive.mayChange(ticket.tool)
        var o = Outcome(operation: Drive.operation(for: ticket.tool, ticket.args), label: Drive.target(ticket.tool, ticket.args))
        o.text = Drive.typed(ticket.tool, ticket.args)
        o.pageChanged = changes ? moved : nil
        o.error = error
        if let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            o.result = summary
            o.pageChanged = nil
        }
        target.cycles[cycle].outcome = o
        target.cycles[cycle].ended = now
        target.url = url
        target.title = title
        if run?.id != target.id {
            if target.status != .stopped {
                target.status = error == nil ? .done : .error
                target.ended = now
                target.note = error ?? ""
            }
            Agent.shared.record(target)
            return
        }
        run = target
        busy = target.cycles.contains { $0.ended == nil }
        guard !busy else { return }
        graceTimer?.invalidate()
        graceTimer = Timer.scheduledTimer(withTimeInterval: Drive.grace, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.lapse() }
        }
    }

    /// A call the user's Stop turned away: a row in the stopped run, so it
    /// shows that the agent tried again and was refused.
    func refused(call tool: String, args: [String: Any], by driver: Driver, who: Who? = nil) {
        guard let run, run.who.key == (who ?? .plain(driver)).key else { return }
        cycle()
        let (title, detail) = Drive.words(for: tool, args)
        let id = phase(.act, title, detail: detail)
        close(phase: id)
        outcome(Outcome(operation: Drive.operation(for: tool, args), label: Drive.target(tool, args), error: "Refused — you stopped it"))
    }

    /// Nothing came for `grace` seconds: the driver has let go.
    private func lapse() {
        guard live, let run, run.driver != .jev, !busy else { return }
        let acted = run.cycles.count
        finish(.ended, note: "\(acted) call\(acted == 1 ? "" : "s")")
    }

    /// An agent's run is over, however it ended: the trail comes off the page.
    private func clearTrail() {
        guard let tab = driven else { return }
        driven = nil
        Tools.Trail.clear(tab.web)
    }

    // MARK: - words for a call

    /// The row's title and detail for a tool call, as a person would say it.
    /// The agent's `element` is Playwright's own "human-readable element
    /// description"; its `reason`, when given, is the detail.
    static func words(for tool: String, _ args: [String: Any]) -> (String, String?) {
        let element = (args["element"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ref = (args["ref"] as? String) ?? (args["selector"] as? String)
        let named = element.flatMap { $0.isEmpty ? nil : $0 } ?? ref.map { "'\($0)'" } ?? ""
        let reason = (args["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = reason.flatMap { $0.isEmpty ? nil : $0 }
        let host: String = {
            guard let raw = args["url"] as? String, let url = Address.url(from: raw) else { return (args["url"] as? String) ?? "" }
            return url.host ?? url.absoluteString
        }()
        func sentence(_ verb: String) -> String { named.isEmpty ? verb : "\(verb) \(named)" }
        switch tool {
        case "browser_snapshot": return ((args["interactive"] as? Bool) == true ? "Reading the page's controls" : "Reading the page", detail)
        case "browser_click":
            let double = (args["doubleClick"] as? Bool) == true
            let button = (args["button"] as? String) ?? "left"
            let how = double ? "Double-clicking" : (button == "right" ? "Right-clicking" : "Clicking")
            return (sentence(how), detail)
        case "browser_type":
            let submit = (args["submit"] as? Bool) == true
            return (named.isEmpty ? "Typing" : "Typing into \(named)" + (submit ? ", then Enter" : ""), detail)
        case "browser_fill_form":
            let n = (args["fields"] as? [[String: Any]])?.count ?? 0
            return ("Filling \(n) field\(n == 1 ? "" : "s")", detail)
        case "browser_press_key": return ("Pressing \((args["key"] as? String) ?? "a key")", detail)
        case "browser_hover": return (sentence("Hovering"), detail)
        case "browser_select_option":
            let values = ((args["values"] as? [String]) ?? []).joined(separator: ", ")
            return (named.isEmpty ? "Choosing \(values)" : "Choosing \(values) in \(named)", detail)
        case "browser_drag": return ("Dragging \((args["startElement"] as? String) ?? (args["startRef"] as? String) ?? "") to \((args["endElement"] as? String) ?? (args["endRef"] as? String) ?? "")", detail)
        case "browser_navigate": return (host.isEmpty ? "Opening a page" : "Opening \(host)", detail)
        case "browser_navigate_back": return ("Going back", detail)
        case "browser_navigate_forward": return ("Going forward", detail)
        case "browser_take_screenshot": return ((args["fullPage"] as? Bool) == true ? "Taking a full-page screenshot" : "Taking a screenshot", detail)
        case "browser_evaluate": return ("Running a script in the page", detail)
        case "browser_wait_for":
            if let text = args["text"] as? String, !text.isEmpty { return ("Waiting for “\(text.prefix(40))”", detail) }
            if let gone = args["textGone"] as? String, !gone.isEmpty { return ("Waiting for “\(gone.prefix(40))” to go", detail) }
            if let t = (args["time"] as? NSNumber)?.doubleValue { return ("Waiting \(t.rounded() == t ? String(Int(t)) : String(format: "%.1f", t)) s", detail) }
            return ("Waiting", detail)
        case "browser_scroll":
            if let dy = (args["deltaY"] as? NSNumber)?.doubleValue { return (dy < 0 ? "Scrolling up" : "Scrolling down", detail) }
            if let ref = args["ref"] as? String { return ("Scrolling '\(ref)' into view", detail) }
            return ("Scrolling down", detail)
        case "browser_get_text": return (named.isEmpty ? "Reading the page's text" : "Reading the text of \(named)", detail)
        case "browser_console_messages": return ("Reading the console", detail)
        case "browser_find": return ("Finding “\(((args["text"] as? String) ?? "").prefix(40))”", detail)
        case "browser_resize": return ("Resizing the window", detail)
        case "browser_close": return ("Closing the tab", detail)
        case "browser_tabs":
            switch (args["action"] as? String) ?? "list" {
            case "new": return (host.isEmpty ? "Opening a new tab" : "Opening a tab on \(host)", detail)
            case "close": return ("Closing a tab", detail)
            case "select": return ("Switching tabs", detail)
            default: return ("Listing the tabs", detail)
            }
        case "browser_groups": return ("Tab groups: \((args["action"] as? String) ?? "list")", detail)
        case "browser_sign_in":
            switch args["what"] as? String {
            case "otp": return ("Filling the one-time code from the vault", detail)
            case "passkey": return ("Signing in with a saved passkey", detail) // Fork: bitwarden-passkeys
            default: return ("Signing in with a saved account", detail)
            }
        case "browser_autofill": return ("Filling a saved \((args["kind"] as? String) ?? "item")", detail)
        case "browser_perf_probe": return ("Sampling the page's performance", detail)
        case "browser_crashes": return ("Reading Copper's crash history", detail)
        case "jev_observe": return ("Reading the page (Jev)", detail)
        case "canvas_read": return ("Reading the canvas", detail)
        case "canvas_apply":
            let ops = (args["ops"] as? [Any])?.count ?? 0
            return (ops > 0 ? "Changing the canvas · \(ops) op\(ops == 1 ? "" : "s")" : "Changing the canvas", detail)
        case "canvas_list": return ("Listing canvases", detail)
        case "canvas_open": return ("Opening a canvas", detail)
        case "canvas_create": return ("Making a canvas", detail)
        case "canvas_select", "canvas_focus": return ("Pointing at shapes on the canvas", detail)
        case "canvas_invite": return ("Inviting someone to a canvas", detail)
        case "canvas_screenshot": return ("Picturing the canvas", detail)
        case "jev_extract": return ("Extracting values (Jev)", detail)
        case "cloud_history_delete": return ("Deleting history on Copper Cloud", detail)
        default:
            let plain = tool.hasPrefix("browser_") ? String(tool.dropFirst("browser_".count)) : tool
            return (plain.replacingOccurrences(of: "_", with: " ").capitalized, detail)
        }
    }

    /// The chip: one word for what kind of move it was.
    static func operation(for tool: String, _ args: [String: Any]) -> String {
        switch tool {
        case "browser_click": return "CLICK"
        case "browser_type", "browser_fill_form": return "TYPE"
        case "browser_press_key": return "KEY"
        case "browser_hover": return "HOVER"
        case "browser_select_option": return "SELECT"
        case "browser_drag": return "DRAG"
        case "browser_navigate", "browser_navigate_back", "browser_navigate_forward": return "GO"
        case "browser_take_screenshot": return "SHOT"
        case "browser_evaluate": return "SCRIPT"
        case "browser_wait_for": return "WAIT"
        case "browser_scroll": return "SCROLL"
        case "browser_snapshot", "browser_get_text", "browser_console_messages", "browser_find", "jev_observe", "jev_extract", "browser_crashes": return "READ"
        case "browser_tabs":
            switch (args["action"] as? String) ?? "list" {
            case "new", "close", "select": return "TABS"
            default: return "READ"
            }
        case "browser_close": return "TABS"
        case "browser_sign_in": return "SIGN_IN"
        case "browser_autofill": return "AUTOFILL"
        case "browser_perf_probe": return "PROBE"
        case "canvas_read", "canvas_list": return "READ"
        case _ where tool.hasPrefix("canvas_"): return "CANVAS"
        case "cloud_history_delete": return "CLOUD"
        default: return String(tool.uppercased().prefix(12))
        }
    }

    /// Whether the call can move the page — so "→ page changed" means something.
    static func mayChange(_ tool: String) -> Bool {
        switch tool {
        case "browser_snapshot", "browser_get_text", "browser_console_messages", "browser_find", "browser_take_screenshot",
             "browser_hover", "browser_perf_probe", "jev_observe", "jev_extract", "browser_resize", "browser_groups", "browser_wait_for",
             "browser_crashes", "cloud_history_delete":
            return false
        // The canvas tools change a board, not the page: their result is
        // what they say they did (`result`), never "page changed".
        case _ where tool.hasPrefix("canvas_"):
            return false
        case "browser_tabs": return true
        default: return true
        }
    }

    /// The outcome's label: the thing acted on, as the agent named it.
    static func target(_ tool: String, _ args: [String: Any]) -> String {
        if let element = (args["element"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !element.isEmpty { return element }
        switch tool {
        case "browser_navigate":
            if let raw = args["url"] as? String, let url = Address.url(from: raw) { return url.host ?? raw }
            return (args["url"] as? String) ?? ""
        case "browser_press_key": return (args["key"] as? String) ?? ""
        case "browser_find", "browser_wait_for": return (args["text"] as? String) ?? (args["textGone"] as? String) ?? ""
        case "browser_drag": return "\((args["startRef"] as? String) ?? "") → \((args["endRef"] as? String) ?? "")"
        case "browser_select_option": return ((args["values"] as? [String]) ?? []).joined(separator: ", ")
        case "browser_autofill": return (args["name"] as? String) ?? (args["kind"] as? String) ?? ""
        case "browser_sign_in": return (args["account"] as? String) ?? ""
        default: return (args["ref"] as? String) ?? (args["selector"] as? String) ?? ""
        }
    }

    /// What was typed, for the row — masked when the field sounds secret.
    static func typed(_ tool: String, _ args: [String: Any]) -> String? {
        guard tool == "browser_type", let text = args["text"] as? String, !text.isEmpty else { return nil }
        let label = ((args["element"] as? String) ?? "") + " " + ((args["ref"] as? String) ?? "")
        return JevProgress.looksSecret(label) ? "•••" : text
    }
}
