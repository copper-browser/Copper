import Foundation
import Network
import Security

// Copper as an MCP server: an agent drives the window you are looking at.
//
// Playwright's MCP and Chrome's DevTools MCP each start a browser of their
// own, signed in as nobody. This one is the browser you already have open —
// your tabs, your sign-ins, your extensions — listening on the loopback
// interface for the tools those agents already know how to use. Tool names
// and arguments follow Playwright MCP's, so a skill written for it works
// here without a word changed.
//
// Transport is MCP's Streamable HTTP, the simplest shape of it: one POST per
// message, one JSON reply, no session, no stream. Every request carries a
// bearer token that lives in a file only this user can read; the socket
// never leaves 127.0.0.1. A `--mcp-stdio` bridge (Bridge.swift) is there for
// clients that only speak stdio.

@MainActor
final class MCP: ObservableObject {
    static let shared = MCP()

    struct Config: Codable, Equatable {
        var enabled = false
        var port: UInt16 = 4123
        var token = ""
        /// Say each tool call in the line at the bottom, so you can see the
        /// agent's hands.
        var announces = true
        /// Jev mode: the jev_run / jev_step / jev_observe tools, which drive
        /// the page with TypeSafe's Jev at ~200 ms a decision (Ultrafast.swift).
        var jev = false
        /// Configured agent apps. Each entry has its own connection and retry state.
        var links: [AgentLink.Config] = []
        /// The legacy single-app key (an external installer may still write it).
        /// It is never emitted unless the matching legacy entry exists in `links`.
        var legacyLink: AgentLink.Config?

        init(enabled: Bool = false, port: UInt16 = 4123, token: String = "", announces: Bool = true, jev: Bool = false, links: [AgentLink.Config] = [], legacyLink: AgentLink.Config? = nil) {
            self.enabled = enabled; self.port = port; self.token = token; self.announces = announces; self.jev = jev
            self.links = links; self.legacyLink = legacyLink
        }

        enum CodingKeys: String, CodingKey {
            case enabled, port, token, announces, jev, links
            case legacyLink = "agentLink"
        }

        // Lenient on purpose: a field added later must not make an older
        // agent.json unreadable, or the token would rotate under every
        // client that has it.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 4123
            token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
            announces = try c.decodeIfPresent(Bool.self, forKey: .announces) ?? true
            jev = try c.decodeIfPresent(Bool.self, forKey: .jev) ?? false
            var decoded: [AgentLink.Config] = []
            if var items = try? c.nestedUnkeyedContainer(forKey: .links) {
                while !items.isAtEnd {
                    if let entry = try? items.decode(AgentLink.Config.self),
                       entry.id == "legacy" || UUID(uuidString: entry.id) != nil { decoded.append(entry) }
                }
            }
            links = decoded
            if var value = try? c.decode(AgentLink.Config.self, forKey: .legacyLink) {
                value.id = "legacy"
                legacyLink = value
            } else { legacyLink = nil }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(enabled, forKey: .enabled); try c.encode(port, forKey: .port)
            try c.encode(token, forKey: .token); try c.encode(announces, forKey: .announces); try c.encode(jev, forKey: .jev)
            if !links.isEmpty { try c.encode(links, forKey: .links) }
            if let legacy = links.first(where: { $0.id == "legacy" }) {
                struct Legacy: Codable {
                    let enabled: Bool; let api: String; let token: String; let name: String; let linkId: String?; let announces: Bool
                }
                try c.encode(Legacy(enabled: legacy.enabled, api: legacy.api, token: legacy.token,
                                    name: legacy.name, linkId: legacy.linkId, announces: legacy.announces), forKey: .legacyLink)
            }
        }
    }

    /// What the line at the bottom says for a tool call.
    enum Announce {
        /// "Agent · tool", when Settings says so.
        case agent
        /// "<prefix> · tool" — the agent link, with the bot's handle.
        case prefix(String)
        case quiet
    }

    @Published var config: Config {
        didSet {
            guard config != oldValue else { return }
            save()
            if config.enabled != oldValue.enabled || config.port != oldValue.port { apply() }
        }
    }
    @Published private(set) var running = false
    @Published private(set) var trouble: String?
    @Published private(set) var calls = 0
    @Published private(set) var lastTool = ""
    /// The name the last client gave at `initialize` ("Claude Code", "phi"),
    /// for the pill and the pane: whose hands are on the page. The transport
    /// has no sessions, so this is the best the server knows.
    @Published private(set) var clientName = ""
    /// The last Jev run, in a few words, for Settings.
    @Published var jevNote = ""
    /// What each transport session said about itself at `initialize`, by the
    /// `Mcp-Session-Id` this server handed it — so a client that talks HTTP
    /// directly, and says nothing else, is still one session and not "the
    /// last client to connect".
    private var said: [String: Drive.Who.Said] = [:]

    /// Where a message came from, beyond its body: the headers that carry
    /// the agent's identity, and the transport session.
    struct Context {
        var headers: [String: String] = [:]
        /// The `Mcp-Session-Id` the client sent, or the one minted for its `initialize`.
        var session: String?
    }

    private weak var browser: Browser?
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]

    static let path = "/mcp"

    /// Whether a request with this Origin header may reach the socket. None at
    /// all is a proper MCP client; otherwise the host must be exactly a loopback
    /// name over http(s) — a substring test let `http://localhost.evil.example`
    /// through. `null`, empty and unparsable origins are refused.
    nonisolated static func originAllowed(_ origin: String?) -> Bool {
        guard let origin else { return true }
        let text = origin.trimmingCharacters(in: .whitespaces).lowercased()
        guard let parts = URLComponents(string: text),
              let scheme = parts.scheme, scheme == "http" || scheme == "https",
              let host = parts.host else { return false }
        return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    /// Where the token and port live. Beside the session, this user only.
    static var file: URL { Store.file("agent.json") }

    /// SEARCH_MCP_PORT: listen here instead of agent.json's port, without
    /// writing it back — so a second Copper (a probe world, a headless run
    /// beside the windowed app) can serve on its own port while the file,
    /// and the port every configured client points at, stay as they are.
    nonisolated static let portOverride: UInt16? = {
        guard let raw = ProcessInfo.processInfo.environment["SEARCH_MCP_PORT"], let port = UInt16(raw), port > 0 else { return nil }
        return port
    }()

    /// The port the listener actually uses.
    var port: UInt16 { MCP.portOverride ?? config.port }

    var endpoint: String { "http://127.0.0.1:\(port)\(MCP.path)" }

    private init() {
        let raw = try? Data(contentsOf: MCP.file)
        let saved = raw.flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
        var loaded = saved ?? Config()
        if let legacy = loaded.legacyLink {
            if let index = loaded.links.firstIndex(where: { $0.id == "legacy" }) {
                var merged = loaded.links[index]
                merged.enabled = legacy.enabled
                merged.api = legacy.api
                merged.token = legacy.token
                merged.name = legacy.name
                merged.linkId = legacy.linkId
                merged.announces = legacy.announces
                loaded.links[index] = merged
            } else {
                loaded.links.insert(legacy, at: 0)
            }
        }
        if loaded.token.isEmpty { loaded.token = MCP.freshToken(); config = loaded; save() }
        else { config = loaded }
    }

    static func freshToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func save() {
        let file = MCP.file
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func rotateToken() {
        config.token = MCP.freshToken()
    }

    /// What to paste into Claude Code's or phi's mcp.json.
    var clientConfig: String {
        """
        {
          "mcpServers": {
            "copper": {
              "type": "http",
              "url": "\(endpoint)",
              "headers": { "Authorization": "Bearer \(config.token)" }
            }
          }
        }
        """
    }

    /// The same, for a client that only speaks stdio.
    var stdioConfig: String {
        let binary = Bundle.main.executablePath ?? "/Applications/Copper.app/Contents/MacOS/Copper"
        return """
        {
          "mcpServers": {
            "copper": {
              "type": "stdio",
              "command": "\(binary)",
              "args": ["--mcp-stdio"]
            }
          }
        }
        """
    }

    /// One paragraph to paste into a chat with an agent: where Copper is,
    /// how to connect, what it can do. The Playwright-shaped tools.
    var agentPrompt: String {
        """
        If you already have Copper set up, just type `/jev <goal>`.
        Copper is the user's own browser, signed in as them; the current tab is the one they are looking at — work there unless the task names another tab. First action: call browser_snapshot with interactive: true on the current tab, then act with its refs. Call browser_tabs only when another tab is named; take a screenshot when layout matters; nothing is sandboxed — act as the user would.
        Connect MCP server `copper` at \(endpoint) with `Authorization: Bearer \(config.token)`. Claude Code: `claude mcp add -s user --transport http copper \(endpoint) --header \"Authorization: Bearer \(config.token)\"`.
        """
    }

    /// The same, with Jev mode: hand over a goal, get a finished run back.
    var jevPrompt: String {
        """
        If you already have Copper set up, just type `/jev <goal>`.
        Copper is the user's own browser, signed in as them; the current tab is the one they are looking at — work there unless task names another tab. ANY task: FIRST call `jev_run` with whole goal (all concrete values: places, dates, names, filters; stop condition); no `browser_tabs` or snapshot first. Add `url` only for named non-current page. `jev_observe` = indexed read; `jev_extract` = JSON; `jev_step` = one decision. BLOCKED → browser_snapshot/click/type for that part then `jev_run`; DONE is Jev's claim — verify with `jev_observe`/`jev_extract`.
        Connect MCP server `copper` at \(endpoint) with `Authorization: Bearer \(config.token)`. Claude Code: `claude mcp add -s user --transport http copper \(endpoint) --header \"Authorization: Bearer \(config.token)\"`.
        """
    }

    /// A client's `initialize` name as a person would say it.
    static func pretty(client raw: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let low = name.lowercased()
        if low.isEmpty { return "" }
        if low.contains("claude") { return "Claude Code" }
        if low == "pi" || low == "phi" || low.hasPrefix("pi-") || low.hasPrefix("phi-") || low.contains("pi-coding") { return "phi" }
        if low.contains("copper-cli") || low == "copper" { return "copper CLI" }
        if low.contains("cursor") { return "Cursor" }
        if low.contains("codex") { return "Codex" }
        if low.contains("mcp-remote") || low.contains("inspector") { return "MCP client" }
        return name.count > 24 ? String(name.prefix(23)) + "…" : name
    }

    static func jevCommand(goal: String?) -> String {
        guard let goal, !goal.isEmpty else { return "/jev " }
        return "/jev \(goal)"
    }

    // MARK: - starting and stopping

    func start(for browser: Browser) {
        // Headless has no Settings: unsaid switches default on. Before the
        // browser is set, so the didSet's apply() is inert and we listen once.
        Headless.adoptDefaults(self)
        self.browser = browser
        apply()
        // An external daemon nudges new keys in with SIGHUP.
        Intelligence.shared.watchForReload()
        // Model keys the linked Copper Cloud provides (Fork/Cloud/CloudIntelligence.swift).
        CloudIntelligence.shared.start()
        AddonSync.shared.start() // Fork (addons): the cloud's addons, same lifecycle (Fork/Addons/AddonSync.swift)
        Headless.start(for: browser)
        // Agent links dial out once there is a window to drive.
        AgentLinks.shared.start()
        // The agent in the window connects to your other servers now, so its
        // first question already has their tools. Same hook, no second one.
        Task { await Servers.shared.reload() }
    }

    /// Windows: agents act in the browser window in front (Fork/Windows.swift).
    /// Only once the server has a browser at all — this never starts it.
    func follow(_ browser: Browser) {
        guard self.browser != nil else { return }
        self.browser = browser
    }

    func follows(_ browser: Browser) -> Bool { self.browser === browser }

    private func apply() {
        stop(keepingState: true)
        guard config.enabled, browser != nil else { running = false; return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            // Loopback only. Nothing on the network can reach this, whatever
            // the firewall says.
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? 4123)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.running = true
                        self.trouble = nil
                    case .failed(let error):
                        self.running = false
                        self.trouble = "Couldn't listen on port \(self.port): \(error.localizedDescription)"
                        if Headless.on { Headless.log(self.trouble ?? "") }
                    case .cancelled:
                        self.running = false
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            trouble = "Couldn't open the agent port: \(error.localizedDescription)"
            running = false
        }
    }

    func stop(keepingState: Bool = false) {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.close() }
        connections = [:]
        running = false
        if !keepingState { trouble = nil }
    }

    private func accept(_ connection: NWConnection) {
        let wrapped = Connection(connection) { [weak self] request, answer in
            guard let self else { answer(HTTPResponse(status: 503, body: Data())); return }
            self.route(request, answer)
        } gone: { [weak self] id in
            self?.connections[id] = nil
        }
        connections[wrapped.id] = wrapped
        wrapped.open()
    }

    // MARK: - HTTP

    private func route(_ request: HTTPRequest, _ answer: @escaping (HTTPResponse) -> Void) {
        // A page in some other browser must never be able to reach in here:
        // a browser sends Origin, a proper MCP client does not.
        guard MCP.originAllowed(request.headers["origin"]) else {
            answer(HTTPResponse(status: 403, json: ["error": "forbidden origin"]))
            return
        }
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        if path == "/" || path == "/health" {
            var health: [String: Any] = ["name": "copper", "version": Fork.version, "mcp": MCP.path, "running": running,
                                         "headless": Headless.on, "port": Int(port)]
            if Headless.on { health["headlessWindow"] = Headless.health }
            answer(HTTPResponse(status: 200, json: health))
            return
        }
        guard path == MCP.path else {
            answer(HTTPResponse(status: 404, json: ["error": "not found"]))
            return
        }
        guard authorised(request) else {
            answer(HTTPResponse(status: 401, json: ["error": "bearer token required — Settings › Agents"]))
            return
        }
        switch request.method {
        case "POST":
            guard let body = try? JSONSerialization.jsonObject(with: request.body) else {
                answer(HTTPResponse(status: 400, jsonrpcError: nil, code: -32700, message: "Parse error"))
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let one = body as? [String: Any], one["method"] as? String == "copper/link" {
                    // `copper link …`: controls for configured agent apps.
                    // Only here, behind the bearer and loopback — `handle`
                    // never sees it, so a linked app cannot reach controls.
                    let result = await AgentLinks.shared.control(one["params"] as? [String: Any] ?? [:])
                    answer(HTTPResponse(status: 200, json: ["jsonrpc": "2.0", "id": one["id"] ?? NSNull(), "result": result]))
                } else if let one = body as? [String: Any], one["method"] as? String == "copper/intelligence" {
                    // `copper intelligence …`: readiness and keys, loopback
                    // only for the same reason as copper/link. Never echoes a key.
                    let result = Intelligence.shared.control(one["params"] as? [String: Any] ?? [:])
                    answer(HTTPResponse(status: 200, json: ["jsonrpc": "2.0", "id": one["id"] ?? NSNull(), "result": result]))
                } else if let one = body as? [String: Any], one["method"] as? String == "copper/claude" {
                    // `copper claude …`: loopback + bearer only, never via the agent link.
                    let result = ClaudeAccount.shared.control(one["params"] as? [String: Any] ?? [:], in: self.browser)
                    answer(HTTPResponse(status: 200, json: ["jsonrpc": "2.0", "id": one["id"] ?? NSNull(), "result": result]))
                } else if let one = body as? [String: Any], one["method"] as? String == "copper/bitwarden" {
                    // `copper bitwarden …` and an external daemon's sealed
                    // sign-in: loopback + bearer only, like the two above —
                    // the link refuses every copper/* method before `handle`.
                    // The answer is a status report; never a secret.
                    let result = await Bitwarden.shared.control(one["params"] as? [String: Any] ?? [:])
                    answer(HTTPResponse(status: 200, json: ["jsonrpc": "2.0", "id": one["id"] ?? NSNull(), "result": result]))
                } else if let one = body as? [String: Any] {
                    var context = Context(headers: request.headers, session: request.headers["mcp-session-id"])
                    // A session id for each `initialize` that comes without
                    // one: the client sends it back on every request after.
                    let minted = one["method"] as? String == "initialize" && context.session == nil
                    if minted { context.session = UUID().uuidString.lowercased() }
                    if let reply = await self.handle(one, context: context) {
                        var response = HTTPResponse(status: 200, json: reply)
                        if minted, let sid = context.session { response.extra["Mcp-Session-Id"] = sid }
                        answer(response)
                    } else {
                        answer(HTTPResponse(status: 202, body: Data()))
                    }
                } else if let many = body as? [[String: Any]] {
                    var replies: [[String: Any]] = []
                    let context = Context(headers: request.headers, session: request.headers["mcp-session-id"])
                    for one in many { if let reply = await self.handle(one, context: context) { replies.append(reply) } }
                    answer(replies.isEmpty ? HTTPResponse(status: 202, body: Data()) : HTTPResponse(status: 200, jsonArray: replies))
                } else {
                    answer(HTTPResponse(status: 400, jsonrpcError: nil, code: -32600, message: "Invalid request"))
                }
            }
        case "GET":
            // No server-to-client stream; the spec lets a server say so.
            answer(HTTPResponse(status: 405, json: ["error": "no event stream — POST JSON-RPC messages here"]))
        case "DELETE":
            answer(HTTPResponse(status: 200, body: Data()))
        default:
            answer(HTTPResponse(status: 405, json: ["error": "method not allowed"]))
        }
    }

    private func authorised(_ request: HTTPRequest) -> Bool {
        guard let header = request.headers["authorization"] else { return false }
        let parts = header.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
        return !config.token.isEmpty && parts[1] == config.token
    }

    // MARK: - JSON-RPC

    /// One message in, one reply out — or none, for a notification.
    /// `driver` names whose call this is for the pane beside the page; unsaid,
    /// it is the loopback client by the name it gave at `initialize`.
    func handle(_ message: [String: Any], announce: Announce = .agent, driver: Drive.Driver? = nil,
                who given: Drive.Who? = nil, context: Context = Context()) async -> [String: Any]? {
        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]

        func reply(_ result: [String: Any]) -> [String: Any]? {
            guard let id else { return nil }
            return ["jsonrpc": "2.0", "id": id, "result": result]
        }
        func fail(_ code: Int, _ text: String) -> [String: Any]? {
            guard let id else { return nil }
            return ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]]
        }

        switch method {
        case "initialize":
            if let info = params["clientInfo"] as? [String: Any], let name = info["name"] as? String {
                clientName = MCP.pretty(client: name)
                if let sid = context.session {
                    var first = Drive.Who.Said(); first.name = name
                    said[sid] = MCP.said(params, context).over(first)
                }
            }
            let asked = params["protocolVersion"] as? String ?? ""
            let version = MCP.protocolVersions.contains(asked) ? asked : "2025-06-18"
            return reply([
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false], "resources": [:], "prompts": [:]],
                "serverInfo": ["name": "copper", "version": Fork.version],
                "instructions": Tools.instructions(jev: config.jev, voice: driver == nil),
            ])
        case "notifications/initialized", "notifications/cancelled", "notifications/roots/list_changed":
            return nil
        case "ping":
            return reply([:])
        case "tools/list":
            // cloud_history_delete, the Listen transcript's tools and code
            // mode only for loopback clients (no `driver`): never offered
            // through an agent link (CloudHistoryTool, VoiceTools, CodeMode).
            var tools = Tools.catalogue(jev: config.jev)
            if driver == nil {
                tools += loopbackTools
                tools += CodeMode.catalogue(for: tools)
            }
            return reply(["tools": tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            // Which session this is, from what it says about itself (Hands.swift).
            let saidNow = MCP.said(params, context)
            let known = context.session.flatMap { said[$0] } ?? Drive.Who.Said()
            let caller = given ?? Drive.Who.from(saidNow.over(known), mcpSession: context.session, fallbackName: clientName)
            do {
                return reply(try await invoke(name, arguments, announce: announce, driver: driver, caller: caller))
            } catch {
                return fail(-32000, (error as? Tools.Failure)?.text ?? error.localizedDescription)
            }
        case "resources/list":
            // The one resource, copper.d.ts, for loopback clients (CodeMode).
            guard driver == nil else { return reply(["resources": []]) }
            return reply(["resources": [[
                "uri": CodeMode.resourceURI, "name": "copper.d.ts", "mimeType": "text/plain",
                "description": "TypeScript declarations for the `copper` object copper_run scripts see, from this Copper's tool schemas",
            ] as [String: Any]]])
        case "resources/read":
            guard driver == nil, params["uri"] as? String == CodeMode.resourceURI else { return fail(-32002, "Resource not found") }
            let text = CodeModeTypes.declarations(Tools.catalogue(jev: config.jev) + loopbackTools)
            return reply(["contents": [["uri": CodeMode.resourceURI, "mimeType": "text/plain", "text": text] as [String: Any]]])
        case "resources/templates/list":
            return reply(["resourceTemplates": []])
        case "prompts/list":
            return reply(["prompts": []])
        case "logging/setLevel":
            return reply([:])
        default:
            return fail(-32601, "Method not found: \(method)")
        }
    }

    /// The tools only a loopback client gets, beyond `Tools.catalogue`.
    var loopbackTools: [[String: Any]] { [CloudHistoryTool.schema] + VoiceTools.catalogue }

    /// Whether a code-mode run is on, for the call being served: a script's
    /// calls carry it, so copper_run cannot start another from inside.
    @TaskLocal static var inScript = false

    /// One tool call, by name, for a known caller — everything a `tools/call`
    /// does between the request and its result: the voice tools' loopback
    /// gate, the announcement in the line at the bottom, the user's Stop, the
    /// Drive ticket for the pane, the task-locals the handlers read, and the
    /// result's shape (content, isError, _meta). Code mode (CodeMode.swift)
    /// runs each of a script's calls through here with the same caller, so a
    /// script can do nothing a run of direct calls could not. Throws only
    /// when there is no window to drive: everything else is the tool's own
    /// answer, errors included.
    func invoke(_ name: String, _ arguments: [String: Any], announce: Announce, driver: Drive.Driver?, caller: Drive.Who) async throws -> [String: Any] {
        if VoiceTools.names.contains(name) {
            // Fork (voice): reading the Listen transcript drives nothing — no
            // announcement, Drive ticket, staged tab or breadcrumb, and a
            // long-poll only suspends (VoiceTools.swift). A linked bot is
            // refused whatever the person's choice.
            if let refused = VoiceTools.refusal(loopback: driver == nil) {
                return ["content": [["type": "text", "text": refused]], "isError": true]
            }
            let answer = await VoiceTools.call(name, arguments)
            return ["content": [["type": "text", "text": answer.text]], "isError": answer.isError]
        }
        guard let browser = browser ?? (running ? Windows.main : nil) else { throw Tools.Failure(text: "Copper has no window") }
        calls += 1
        lastTool = name
        let who = driver ?? .agent(caller.agent)
        // The tab the call will land on: its own, the caller's, or the
        // one on screen (AgentTabs). Work in a tab you are not looking at
        // is not announced over the one you are.
        let landing = AgentTabs.peek(arguments, in: browser, caller: caller.key)
        let behind = AgentTabs.opensBehind(name, arguments)
        if AgentTabs.onScreen(landing), !behind {
            switch announce {
            case .agent: if config.announces { browser.announce("Agent · \(name)") }
            case .prefix(let who): browser.announce("\(who) · \(name)")
            case .quiet: break
            }
        }
        // The user pressed Stop on this driver: the call is refused with
        // words the agent can act on, and nothing touches the page.
        if let refusal = Drive.shared.refusal(for: caller.key) {
            Drive.shared.refused(call: name, args: arguments, by: who, who: caller)
            return ["content": [["type": "text", "text": refusal]], "isError": true]
        }
        let ticket = AgentTabs.$behind.withValue(behind) { Drive.shared.began(call: name, args: arguments, by: who, who: caller, tab: landing) }
        // A tool may leave a one-line summary (jev_run / jev_step do:
        // "done · 7 actions · 12.3 s · example.com"); it rides as
        // `_meta.summary`, which the app's gateway copies into its audit.
        let summary = Tools.SummaryBox()
        func result(_ content: [[String: Any]], isError: Bool) -> [String: Any] {
            var out: [String: Any] = ["content": content, "isError": isError]
            if let line = summary.line { out["_meta"] = ["summary": line] }
            return out
        }
        do {
            let content = try await DriveCaller.$who.withValue(caller) {
                try await Tools.$summary.withValue(summary) {
                    try await perform(name, arguments, in: browser, announce: announce, driver: driver, caller: caller)
                }
            }
            if let ticket { Drive.shared.ended(ticket, error: nil, summary: summary.line, tab: AgentTabs.peek(arguments, in: browser, caller: caller.key)) }
            return result(content.map(\.json), isError: false)
        } catch {
            let text = (error as? Tools.Failure)?.text ?? error.localizedDescription
            if let ticket { Drive.shared.ended(ticket, error: text, tab: AgentTabs.peek(arguments, in: browser, caller: caller.key)) }
            return result([["type": "text", "text": text]], isError: true)
        }
    }

    /// The call itself: code mode's two tools here, every other name through
    /// `Tools.call`. copper_run and copper_types are loopback-only, like the
    /// tools they are listed with, and a script never reaches copper_run
    /// again — its `copper` has no such method, and this refuses the name
    /// while a run is on, whatever a caller sends.
    private func perform(_ name: String, _ arguments: [String: Any], in browser: Browser, announce: Announce, driver: Drive.Driver?, caller: Drive.Who) async throws -> [Tools.Content] {
        guard CodeMode.names.contains(name) else { return try await Tools.call(name, arguments, in: browser) }
        guard driver == nil else { throw Tools.Failure(text: "\(name) is only for agents on the person's Mac, never through an agent link") }
        guard !MCP.inScript else { throw Tools.Failure(text: "\(name) cannot be called from a copper_run script") }
        let tools = Tools.catalogue(jev: config.jev) + loopbackTools
        let started = Date()
        do {
            let content: [Tools.Content]
            if name == CodeMode.typesName {
                content = CodeMode.types(for: tools)
            } else {
                // Each of the script's calls is bound here, in its own task:
                // the same caller, the same announcement, and the flag that
                // keeps copper_run out of its own scripts. The refusal is
                // the caller's — Stop on the pane's card turns the run away.
                content = try await CodeMode.run(arguments, tools: tools, caller: caller, call: { [weak self] tool, args in
                    guard let self else { throw Tools.Failure(text: "Copper is shutting down") }
                    return try await MCP.$inScript.withValue(true) {
                        try await self.invoke(tool, args, announce: announce, driver: driver, caller: caller)
                    }
                }, refusal: { Drive.shared.refusal(for: caller.key) })
            }
            Breadcrumbs.tool(name, tab: nil, started: started, error: nil)
            return content
        } catch {
            Breadcrumbs.tool(name, tab: nil, started: started, error: error)
            throw error
        }
    }

    /// What a message's sender says about itself: the bridge's or the CLI's
    /// `X-Copper-Agent` header, under the request's own `_meta["copper/agent"]`.
    static func said(_ params: [String: Any], _ context: Context) -> Drive.Who.Said {
        let header = Drive.Who.Said.header(context.headers["x-copper-agent"])
        guard let meta = (params["_meta"] as? [String: Any])?["copper/agent"] as? [String: Any] else { return header }
        return Drive.Who.Said(meta).over(header)
    }

    // MARK: - bench

    func bench(_ request: [String: Any]) -> [String: Any] {
        switch request["op"] as? String ?? "" {
        case "on": config.enabled = true
        case "off": config.enabled = false
        case "rotate": rotateToken()
        case "jev": config.jev = (request["arg"] as? String ?? "on") != "off"
        case "link": return AgentLinks.shared.bench(request["arg"] as? String ?? "")
        case "transcript": return VoiceTools.bench(request["arg"] as? String ?? "") // Fork (voice): test world only
        case "addons": return AddonBench.handle(request["arg"] as? String ?? "") // Fork (addons): `bench agent addons …`
        case "setup-phi":
            do { return try Setup(endpoint: endpoint, token: config.token).phi().dictionary } catch let error { return ["error": (error as? Tools.Failure)?.text ?? error.localizedDescription] }
        case "setup-claude":
            do { return try Setup(endpoint: endpoint, token: config.token).claude().dictionary } catch let error { return ["error": (error as? Tools.Failure)?.text ?? error.localizedDescription] }
        case "setup-cli":
            do { return try Setup(endpoint: endpoint, token: config.token).cli().dictionary } catch let error { return ["error": (error as? Tools.Failure)?.text ?? error.localizedDescription] }
        case "setup-status":
            return Setup(endpoint: endpoint, token: config.token).status().dictionary
        default: break
        }
        return ["enabled": config.enabled, "running": running, "port": Int(port), "headless": Headless.on, "endpoint": endpoint, "calls": calls, "last": lastTool, "trouble": trouble ?? "",
                "jev": config.jev, "jevKey": Intelligence.shared.jevReady, "jevLast": jevNote]
    }
}

// MARK: - one connection

/// Reads HTTP/1.1 requests off one socket, one after another, and writes
/// the replies. Small on purpose: the requests are JSON from a client on this
/// machine (a canvas_apply with pictures in it can be megabytes).
///
/// Replies go out in the order their requests came in, whatever order the
/// calls finish in — a client that pipelines two requests on one socket
/// gets each answer against the right one — and a client that shuts its
/// side after sending (EOF) still gets every answer it is owed before the
/// socket closes.
final class Connection {
    let id: ObjectIdentifier
    private let connection: NWConnection
    private var buffer = Data()
    private let handle: (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void
    private let gone: (ObjectIdentifier) -> Void
    private var closed = false
    /// Requests taken, the next reply to write, and replies done early.
    private var taken = 0
    private var written = 0
    private var ready: [Int: (HTTPResponse, Bool)] = [:]
    /// The client sent EOF: close once the replies owed are out.
    private var peerDone = false
    static let maxRequest = 32_000_000

    init(_ connection: NWConnection, handle: @escaping (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void, gone: @escaping (ObjectIdentifier) -> Void) {
        self.connection = connection
        self.id = ObjectIdentifier(connection)
        self.handle = handle
        self.gone = gone
    }

    func open() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: .main)
        read()
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            if self.buffer.count > Connection.maxRequest {
                let n = self.taken
                self.taken += 1
                self.reply(n, HTTPResponse(status: 413, json: ["error": "request too large"]), thenClose: true)
                return
            }
            self.drain()
            if error != nil { self.close(); return }
            if complete {
                self.peerDone = true
                if self.written == self.taken { self.close() }
                return
            }
            self.read()
        }
    }

    /// Every whole request in the buffer, in order.
    private func drain() {
        while let request = HTTPRequest.take(from: &buffer) {
            let wantsClose = request.headers["connection"]?.lowercased() == "close"
            let n = taken
            taken += 1
            handle(request) { [weak self] response in
                self?.reply(n, response, thenClose: wantsClose)
            }
        }
    }

    /// Reply `n` is done: written now if every one before it is out, else kept until they are.
    private func reply(_ n: Int, _ response: HTTPResponse, thenClose: Bool) {
        guard !closed else { return }
        ready[n] = (response, thenClose)
        while let (next, close) = ready.removeValue(forKey: written) {
            written += 1
            let last = close || (peerDone && written == taken)
            connection.send(content: next.bytes, completion: .contentProcessed { [weak self] _ in
                if last { self?.close() }
            })
            if close { break }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        gone(id)
    }
}

// MARK: - HTTP, the little that is needed

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// One request off the front of the buffer, if a whole one is there.
    static func take(from buffer: inout Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: separator) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        lines.removeFirst()
        let words = first.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count >= 2 else {
            buffer.removeAll()
            return nil
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let length = max(0, Int(headers["content-length"] ?? "0") ?? 0)
        let bodyStart = end.upperBound
        let bodyEnd = bodyStart + length
        guard buffer.endIndex >= bodyEnd else { return nil }
        let body = Data(buffer[bodyStart..<bodyEnd])
        // A fresh Data, so indices start at zero again for the next request.
        buffer = Data(buffer[bodyEnd...])
        return HTTPRequest(method: words[0].uppercased(), path: words[1], headers: headers, body: body)
    }
}

struct HTTPResponse {
    let status: Int
    let body: Data
    var contentType = "application/json"
    /// Headers beyond the fixed few — the `Mcp-Session-Id` on an initialize.
    var extra: [String: String] = [:]

    init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    init(status: Int, json: [String: Any]) {
        self.status = status
        self.body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
    }

    init(status: Int, jsonArray: [[String: Any]]) {
        self.status = status
        self.body = (try? JSONSerialization.data(withJSONObject: jsonArray)) ?? Data("[]".utf8)
    }

    init(status: Int, jsonrpcError id: Any?, code: Int, message: String) {
        self.status = status
        let object: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
        self.body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    private static let reasons: [Int: String] = [
        200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
        405: "Method Not Allowed", 413: "Payload Too Large", 500: "Internal Server Error", 503: "Service Unavailable",
    ]

    var bytes: Data {
        var head = "HTTP/1.1 \(status) \(HTTPResponse.reasons[status] ?? "OK")\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        for (name, value) in extra { head += "\(name): \(value)\r\n" }
        head += "Connection: keep-alive\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }
}
