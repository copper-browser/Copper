import Foundation

// The models Copper can ask, and the keys that let it. Nothing here is
// used until a key is pasted in Settings › Intelligence; until then every
// caller sees `configured == false` and stays local, which keeps upstream's
// promise that nothing leaves the Mac unless you set it up.
//
// Two lanes, on purpose:
//   - Jev (TypeSafe's System One model) answers typed questions — pick one of
//     these, how likely is this — in ~200 ms with a calibrated confidence.
//     It is the fast lane for anything that can be phrased as a choice.
//   - The router (a LiteLLM gateway, OpenAI-compatible) is the slow lane:
//     free-form judgement when Jev is unsure or when something has to be
//     *named*, which a closed set can't do.

@MainActor
final class Intelligence: ObservableObject {
    static let shared = Intelligence()

    /// where the model comes from.
    enum Lane: String, Codable, CaseIterable, Identifiable {
        case key
        case claude
        var id: String { rawValue }
        var title: String {
            switch self {
            case .key: return "API key"
            case .claude: return "Claude account"
            }
        }
    }

    /// the three sizes, shared by every model caller.
    enum Tier: String, Codable, CaseIterable, Identifiable {
        case haiku, sonnet, opus
        var id: String { rawValue }
        var title: String {
            switch self {
            case .haiku: return "Haiku"
            case .sonnet: return "Sonnet"
            case .opus: return "Opus"
            }
        }
        var blurb: String {
            switch self {
            case .haiku: return "Quick"
            case .sonnet: return "The balance"
            case .opus: return "Thinks hardest"
            }
        }
    }

    struct Keys: Codable, Equatable {
        var jevKey = ""
        var jevModel = "jev-latest"
        var jevEndpoint = "https://api.typesafe.ai/v1/systemone"
        var routerKey = ""
        var routerURL = "https://llm.dev.exowatt.com"
        var routerModel = "sonnet"
        var lane: Lane = .key
        var tier: Tier = .sonnet
        /// tier.rawValue → model id at Anthropic (Claude account lane).
        var claudeModels: [String: String] = Keys.defaultClaudeModels
        /// tier.rawValue → model name on the gateway (API key lane).
        var routerModels: [String: String] = Keys.defaultRouterModels
        static let defaultClaudeModels = [
            "haiku": "claude-haiku-4-5",
            "sonnet": "claude-sonnet-5",
            "opus": "claude-opus-5-5",
        ]
        static let defaultRouterModels = ["haiku": "haiku", "sonnet": "sonnet", "opus": "opus"]
        /// The small model Jev mode asks to write field values (TYPE_TEXT).
        /// Empty means the router model; a small fast one is the point.
        var textModel = ""
        /// What Jev mode shows Jev beside the element table, by default:
        /// off, screenshot, marks or box (Tools.Ultrafast.Vision). A run
        /// can say otherwise. Pictures are a TypeSafe preview.
        var jevVision = "auto"
        /// Jev mode's Fast mode: Strategy.shipped (on) or the classic loop.
        var jevFast = true

        init() {}

        // Lenient: a field added later must never make an older
        // intelligence.json unreadable — that would drop the keys.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let fresh = Keys()
            jevKey = try c.decodeIfPresent(String.self, forKey: .jevKey) ?? fresh.jevKey
            jevModel = try c.decodeIfPresent(String.self, forKey: .jevModel) ?? fresh.jevModel
            jevEndpoint = try c.decodeIfPresent(String.self, forKey: .jevEndpoint) ?? fresh.jevEndpoint
            routerKey = try c.decodeIfPresent(String.self, forKey: .routerKey) ?? fresh.routerKey
            routerURL = try c.decodeIfPresent(String.self, forKey: .routerURL) ?? fresh.routerURL
            routerModel = try c.decodeIfPresent(String.self, forKey: .routerModel) ?? fresh.routerModel
            lane = try c.decodeIfPresent(Lane.self, forKey: .lane) ?? fresh.lane
            tier = try c.decodeIfPresent(Tier.self, forKey: .tier) ?? fresh.tier
            var decodedClaude = Keys.defaultClaudeModels
            if let saved = try c.decodeIfPresent([String: String].self, forKey: .claudeModels) {
                decodedClaude.merge(saved) { _, value in value }
            }
            claudeModels = decodedClaude
            var decodedRouter = Keys.defaultRouterModels
            let hadRouterModels = c.contains(.routerModels)
            if let saved = try c.decodeIfPresent([String: String].self, forKey: .routerModels) {
                decodedRouter.merge(saved) { _, value in value }
            } else if !hadRouterModels,
                      Intelligence.family(of: routerModel) == nil {
                decodedRouter[Tier.sonnet.rawValue] = routerModel
            }
            routerModels = decodedRouter
            textModel = try c.decodeIfPresent(String.self, forKey: .textModel) ?? fresh.textModel
            jevVision = try c.decodeIfPresent(String.self, forKey: .jevVision) ?? fresh.jevVision
            jevFast = try c.decodeIfPresent(Bool.self, forKey: .jevFast) ?? fresh.jevFast
            migrateModelNames()
        }

        /// Pinned and prefixed names for a tier go back to what tracks the
        /// newest model: on the gateway the bare float (`opus`, never
        /// `exowatt/opus`, `opus-5` or `claude-opus-5`), on the Claude-account
        /// lane Copper's own current id for that tier (Anthropic has no
        /// float). A name that is not a Claude tier — a gateway's own
        /// `gpt-…`, `luna` — is the user's choice and is left alone, but for
        /// the `exowatt/` prefix phi shows and the gateway does not know.
        mutating func migrateModelNames() {
            for (tier, name) in routerModels { routerModels[tier] = Intelligence.gatewayName(name) }
            for (tier, name) in claudeModels { claudeModels[tier] = Intelligence.claudeName(name, tier: Tier(rawValue: tier)) }
            routerModel = Intelligence.gatewayName(routerModel)
            let text = textModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                // A tier word resolves on whichever lane is chosen.
                textModel = Intelligence.family(of: text)?.rawValue ?? Intelligence.unprefixed(text)
            }
        }
    }

    // MARK: - model names

    /// The tier a Claude model name belongs to, however it is spelled:
    /// `opus`, `opus-5`, `exowatt/opus-5`, `claude-opus-5-5`,
    /// `claude-sonnet-4-5-20250929`, `claude-3-5-haiku-latest`,
    /// `anthropic/claude-opus-5`. Nil for anything else — including a
    /// variant that is a different offering, such as `sonnet-1m`.
    nonisolated static func family(of raw: String) -> Tier? {
        var name = unprefixed(raw).lowercased()
        if name.hasPrefix("anthropic/") { name.removeFirst("anthropic/".count) }
        let pattern = #"^(?:claude-)?(?:\d+(?:[.-]\d+)*-)?(haiku|sonnet|opus)(?:-\d+(?:[.-]\d+)*)?(?:-latest)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range(at: 1), in: name) else { return nil }
        return Tier(rawValue: String(name[range]))
    }

    /// Without phi's `exowatt/` provider prefix: the gateway's own names have none.
    nonisolated static func unprefixed(_ raw: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.lowercased().hasPrefix("exowatt/") ? String(name.dropFirst("exowatt/".count)) : name
    }

    /// What the gateway is sent for a name: a Claude tier in any spelling
    /// becomes its float (`opus`), so it follows the gateway to the newest
    /// model; anything else goes as typed, without an `exowatt/` prefix.
    nonisolated static func gatewayName(_ raw: String) -> String {
        if let tier = family(of: raw) { return tier.rawValue }
        return unprefixed(raw)
    }

    /// What the Claude-account lane is sent: a Claude tier in any spelling
    /// becomes Copper's current id for it; anything else as typed.
    nonisolated static func claudeName(_ raw: String, tier: Tier?) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let family = family(of: name) ?? (name.isEmpty ? tier : nil),
           let current = Keys.defaultClaudeModels[family.rawValue] {
            return current
        }
        return unprefixed(name)
    }

    /// What is set on this Mac — intelligence.json. Settings edits this.
    @Published var keys: Keys { didSet { if keys != oldValue, !loading { save() } } }

    /// What the linked Copper Cloud provides (`GET /v1/intelligence`,
    /// Fork/Cloud/CloudIntelligence.swift). Never written into
    /// intelligence.json: it lives in memory and cloud-intelligence.json.
    @Published private(set) var cloud: CloudProvided?

    /// The model the last answer said it came from, beside what was sent.
    @Published private(set) var reported: (sent: String, answered: String)?

    func adoptCloud(_ provided: CloudProvided?) {
        if cloud != provided { cloud = provided }
    }

    func noteAnswer(sent: String, answered: String?) {
        guard let answered, !answered.isEmpty else { return }
        if reported?.sent != sent || reported?.answered != answered { reported = (sent, answered) }
    }

    /// The model the last answer for the current choice reported, if any.
    var answeredModel: String? {
        guard let reported, reported.sent == modelName else { return nil }
        return reported.answered
    }

    /// What every caller uses: this Mac's keys with Copper Cloud's merged
    /// in (Intelligence.merge) — the cloud's gateway key, address and lane
    /// whenever it provides a gateway key. Never saved.
    var effective: Keys { Intelligence.merge(local: keys, cloud: cloud).keys }
    /// Where each key and address comes from: local, cloud, or none/default;
    /// and `lane`: cloud or local.
    var sources: [String: String] { Intelligence.merge(local: keys, cloud: cloud).sources }

    /// True while `reload()` assigns what it read: that is the file, and
    /// writing it straight back would only race whoever just wrote it.
    private var loading = false
    private var hangup: DispatchSourceSignal?

    /// The lane every model caller uses: the gateway while Copper Cloud
    /// provides its key, else the one chosen on this Mac (`keys.lane`, which
    /// the cloud never changes — it is back in force once the cloud goes).
    var lane: Lane { effective.lane }
    /// `cloud` while Copper Cloud's gateway key decides the lane, else `local`.
    var laneSource: String { sources["lane"] ?? "local" }
    var cloudLane: Bool { laneSource == "cloud" }
    /// The org's tool-call rounds per question while Copper Cloud sets one;
    /// it wins over Settings › Agents (Agent.turnBudget), which is kept.
    var cloudMaxTurns: Int? { cloud?.agentMaxTurns }
    var tier: Tier { keys.tier }

    /// what Jev mode types with: the text model when one is named, else the chosen model.
    var textModelName: String { keys.textModel.trimmingCharacters(in: .whitespaces).isEmpty ? model() : model(keys.textModel) }

    /// Whether Jev can be asked at all — with this Mac's key or the cloud's.
    var jevReady: Bool { !effective.jevKey.trimmingCharacters(in: .whitespaces).isEmpty }
    /// Whether the router can be asked at all — with this Mac's key or the cloud's.
    var routerReady: Bool {
        let keys = effective
        return !keys.routerKey.trimmingCharacters(in: .whitespaces).isEmpty && URL(string: keys.routerURL) != nil
    }
    /// Whether the active model lane can be asked at all.
    var claudeReady: Bool { ClaudeAccount.shared.signedIn }
    var modelReady: Bool { lane == .key ? routerReady : claudeReady }
    var configured: Bool { jevReady || modelReady }

    /// resolve a tier name or pass through a full model name.
    func model(_ named: String? = nil, tier: Tier? = nil) -> String {
        let raw = named ?? ""
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.isEmpty {
            // Any spelling of a tier is that tier: the gateway gets the
            // float, the Claude lane Copper's current id.
            if let namedTier = Intelligence.family(of: candidate) {
                return model(for: namedTier)
            }
            return lane == .key ? Intelligence.unprefixed(candidate) : candidate
        }
        return model(for: tier ?? self.tier)
    }

    private func model(for tier: Tier) -> String {
        let keys = effective
        return Intelligence.name(for: tier, lane: keys.lane, keys: keys)
    }

    /// The name a tier is sent as on a lane: the gateway's float (or the
    /// custom name set for it), or the Claude lane's current id.
    nonisolated static func name(for tier: Tier, lane: Lane, keys: Keys) -> String {
        if lane == .claude {
            return claudeName(keys.claudeModels[tier.rawValue] ?? "", tier: tier)
        }
        let named = (keys.routerModels[tier.rawValue] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return named.isEmpty ? tier.rawValue : gatewayName(named)
    }

    var modelName: String { model() }

    /// one short line for menus and headers.
    var accessLine: String {
        guard modelReady else { return "Not set up" }
        switch lane {
        case .key:
            let effective = self.effective
            let host = URL(string: effective.routerURL)?.host ?? effective.routerURL
            if sources["routerKey"] == "cloud" { return "Copper Cloud · \(host)" }
            return "API key · \(host)"
        case .claude:
            return "Claude account · \(ClaudeAccount.shared.email)"
        }
    }

    private static var file: URL { Store.file("intelligence.json") }

    private init() {
        if let data = try? Data(contentsOf: Intelligence.file),
           let saved = try? JSONDecoder().decode(Keys.self, from: data) {
            keys = saved
        } else {
            keys = Keys()
        }
    }

    // MARK: - outside writers

    /// intelligence.json, read again. An external daemon writes keys it was
    /// provisioned with into the file, then signals (SIGHUP) or calls
    /// `copper intelligence reload`, so nobody restarts the browser for a key.
    @discardableResult
    func reload() -> Bool {
        guard let data = try? Data(contentsOf: Intelligence.file),
              let saved = try? JSONDecoder().decode(Keys.self, from: data) else { return false }
        loading = true
        keys = saved
        loading = false
        return true
    }

    /// SIGHUP → reload. SIGHUP's default is to end the process, so it is
    /// ignored first and taken as an event on the main queue instead.
    func watchForReload() {
        guard hangup == nil else { return }
        signal(SIGHUP, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                let ok = Intelligence.shared.reload()
                let line = ok
                    ? "intelligence.json reloaded on SIGHUP — jevReady \(Intelligence.shared.jevReady), routerReady \(Intelligence.shared.routerReady)"
                    : "SIGHUP: intelligence.json missing or unreadable; keys unchanged"
                FileHandle.standardError.write(Data("\(ISO8601DateFormatter().string(from: Date())) copper: \(line)\n".utf8))
            }
        }
        source.resume()
        hangup = source
    }

    /// readiness and the non-secret settings. Never a key.
    var status: [String: Any] {
        let effective = self.effective
        var out: [String: Any] = ["jevReady": jevReady, "routerReady": routerReady, "routerURL": effective.routerURL,
         "routerModel": keys.routerModel, "jevModel": effective.jevModel, "jevVision": keys.jevVision, "jevFast": keys.jevFast,
         "lane": effective.lane.rawValue, "laneSource": laneSource, "localLane": keys.lane.rawValue,
         "tier": tier.rawValue, "model": modelName,
         "modelReady": modelReady, "claudeReady": claudeReady,
         "claudeAccount": ClaudeAccount.shared.email,
         "sources": sources]
        if let answered = answeredModel { out["answeredBy"] = answered }
        if let cloud {
            var line: [String: Any] = ["host": cloud.host ?? "", "provides": cloud.provides]
            if let updated = cloud.updatedAt { line["updatedAt"] = updated }
            if let fetched = cloud.fetchedAt { line["fetchedAt"] = ISO8601DateFormatter().string(from: fetched) }
            if let turns = cloud.agentMaxTurns { line["agentMaxTurns"] = turns }
            out["cloud"] = line
        }
        return out
    }

    /// Settings' words for a key Copper Cloud supplies; nil when this
    /// Mac's own key (or no key) is in use.
    func cloudLine(_ field: String, _ key: String?) -> String? {
        guard sources[field] == "cloud" else { return nil }
        return "Provided by Copper Cloud (\(cloud?.host ?? "your cloud"))"
    }

    /// The key field's placeholder while the cloud's key is in use: the
    /// key masked (`sk-…1a2b`), and — for the Jev key, which one typed here
    /// still overrides — that typing one overrides it. The cloud's gateway
    /// key is not overridden while it is provided.
    func cloudPlaceholder(_ field: String, _ key: String?, otherwise: String) -> String {
        guard sources[field] == "cloud" else { return otherwise }
        if field == "routerKey" { return CloudProvided.masked(key) }
        return "\(CloudProvided.masked(key)) · type to override"
    }

    /// One line per key and address: where it comes from, never its value.
    var sourcesLine: String {
        let s = sources
        let order = ["jevKey", "jevEndpoint", "jevModel", "routerKey", "routerURL", "lane"]
        return order.map { "\($0) \(s[$0] ?? "none")" }.joined(separator: " · ")
    }

    // MARK: - this Mac's keys and the cloud's

    /// This Mac's keys merged with Copper Cloud's, and where each came from.
    /// While the cloud provides a gateway key, every model call goes through
    /// the cloud's gateway — even with a Claude account signed in, even with
    /// a gateway key typed here. Per field:
    ///   - `routerKey`: the cloud's whenever it provides one, else a
    ///     non-empty local key.
    ///   - `lane`: `.key` while the cloud's gateway key is in use, else this
    ///     Mac's choice. `local.lane` itself is never changed, so it is back
    ///     the moment the cloud signs out or stops providing a key.
    ///   - `routerURL`: the cloud's alongside the cloud's key; else a local
    ///     address other than the default; else the default. A key typed on
    ///     this Mac is never sent to an address the cloud chose.
    ///   - `jevKey`: a non-empty local key wins, else the cloud's.
    ///   - `jevModel`: a local name other than the default wins, else the
    ///     cloud's, else the default.
    ///   - `jevEndpoint`: a local address other than the default wins; the
    ///     cloud's is used only alongside the cloud's Jev key.
    /// Sources are `local`, `cloud`, `none` (no key) or `default`; `lane` is
    /// `cloud` or `local`. The model names for each tier stay this Mac's:
    /// `/v1/intelligence` ships none.
    nonisolated static func merge(local: Keys, cloud: CloudProvided?) -> (keys: Keys, sources: [String: String]) {
        let fresh = Keys()
        var out = local
        var sources: [String: String] = [:]
        func trimmed(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func custom(_ value: String, _ standard: String) -> Bool {
            let v = trimmed(value)
            return !v.isEmpty && v.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != standard.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        func web(_ s: String?) -> String? {
            let v = trimmed(s)
            guard let url = URL(string: v), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
            return v
        }

        // Jev
        if !trimmed(local.jevKey).isEmpty {
            sources["jevKey"] = "local"
        } else if !trimmed(cloud?.jev?.key).isEmpty {
            out.jevKey = trimmed(cloud?.jev?.key)
            sources["jevKey"] = "cloud"
        } else {
            sources["jevKey"] = "none"
        }
        if custom(local.jevEndpoint, fresh.jevEndpoint) {
            sources["jevEndpoint"] = "local"
        } else if sources["jevKey"] == "cloud", let endpoint = web(cloud?.jev?.endpoint) {
            out.jevEndpoint = endpoint
            sources["jevEndpoint"] = "cloud"
        } else {
            out.jevEndpoint = fresh.jevEndpoint
            sources["jevEndpoint"] = "default"
        }
        if custom(local.jevModel, fresh.jevModel) {
            sources["jevModel"] = "local"
        } else if !trimmed(cloud?.jev?.model).isEmpty {
            out.jevModel = trimmed(cloud?.jev?.model)
            sources["jevModel"] = "cloud"
        } else {
            out.jevModel = fresh.jevModel
            sources["jevModel"] = "default"
        }

        // the router: the cloud's gateway key, when it provides one, wins
        // the key, its address and the lane.
        if !trimmed(cloud?.router?.key).isEmpty {
            out.routerKey = trimmed(cloud?.router?.key)
            sources["routerKey"] = "cloud"
        } else if !trimmed(local.routerKey).isEmpty {
            sources["routerKey"] = "local"
        } else {
            sources["routerKey"] = "none"
        }
        if sources["routerKey"] == "cloud" {
            out.lane = .key
            sources["lane"] = "cloud"
        } else {
            sources["lane"] = "local"
        }
        if sources["routerKey"] == "cloud", let url = web(cloud?.router?.url) {
            out.routerURL = url
            sources["routerURL"] = "cloud"
        } else if custom(local.routerURL, fresh.routerURL) {
            sources["routerURL"] = "local"
        } else {
            out.routerURL = fresh.routerURL
            sources["routerURL"] = "default"
        }
        return (out, sources)
    }

    /// The loopback server's `copper/intelligence` method (`copper
    /// intelligence …`). `set` takes any of jevKey, routerKey, routerURL,
    /// routerModel, textModel and writes through `keys`, so the file is
    /// saved 0600 the same way Settings saves it. Answers name what changed,
    /// never its value.
    func control(_ params: [String: Any]) -> [String: Any] {
        switch params["op"] as? String ?? "status" {
        case "status":
            return status
        case "reload":
            var out = status
            out["reloaded"] = reload()
            return out
        case "sources":
            var out: [String: Any] = sources
            out["line"] = sourcesLine
            if let cloud { out["cloudHost"] = cloud.host ?? "" }
            out["cloudFetch"] = CloudIntelligence.shared.lastOutcome
            return out
        case "refresh":
            CloudIntelligence.shared.refresh(force: true)
            var out: [String: Any] = sources
            out["line"] = sourcesLine
            out["refreshing"] = true
            return out
        case "set":
            var next = keys
            var applied: [String] = []
            var problem: String?
            func take(_ name: String, _ apply: (String) -> Void) {
                guard problem == nil, let raw = params[name] else { return }
                guard let value = raw as? String else {
                    problem = "\(name) must be a string"
                    return
                }
                apply(value.trimmingCharacters(in: .whitespacesAndNewlines))
                applied.append(name)
            }
            if let raw = params["lane"] {
                guard let text = raw as? String, let value = Lane(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                    return ["error": "lane must be key or claude"]
                }
                next.lane = value
                applied.append("lane")
            }
            if let raw = params["tier"] {
                guard let text = raw as? String, let value = Tier(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                    return ["error": "tier must be haiku, sonnet or opus"]
                }
                next.tier = value
                applied.append("tier")
            }
            if let raw = params["routerURL"] {
                guard let text = raw as? String else { return ["error": "routerURL must be a string"] }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                    return ["error": "routerURL must be an http(s) URL"]
                }
            }
            take("jevKey") { next.jevKey = $0 }
            take("routerKey") { next.routerKey = $0 }
            take("routerURL") { next.routerURL = $0 }
            take("textModel") { next.textModel = $0 }
            if let raw = params["jevVision"] {
                guard let text = raw as? String, let mode = Tools.Ultrafast.Vision.parse(text), Tools.Ultrafast.Vision.offered.contains(mode) else {
                    return ["error": "jevVision must be auto, off, screenshot, marks or box"]
                }
                next.jevVision = mode.rawValue
                applied.append("jevVision")
            }
            if let raw = params["jevFast"] {
                let text = (raw as? String)?.lowercased()
                guard let on = (raw as? Bool) ?? (text.map { ["on", "true", "1", "yes"].contains($0) ? true : ["off", "false", "0", "no"].contains($0) ? false : nil } ?? nil) else {
                    return ["error": "jevFast must be on or off"]
                }
                next.jevFast = on
                applied.append("jevFast")
            }
            if let raw = params["jevModel"] {
                guard let text = raw as? String else { return ["error": "jevModel must be a string"] }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                next.jevModel = trimmed.isEmpty ? Keys().jevModel : trimmed
                applied.append("jevModel")
            }
            take("routerModel") {
                next.routerModel = Intelligence.gatewayName($0)
                next.routerModels[next.tier.rawValue] = Intelligence.gatewayName($0)
            }
            // A tier's name goes to the map of the lane in force (the
            // gateway's while Copper Cloud provides its key).
            let namesLane = Intelligence.merge(local: next, cloud: cloud).keys.lane
            let modelFields: [(String, Tier)] = [("haikuModel", .haiku), ("sonnetModel", .sonnet), ("opusModel", .opus)]
            for (name, modelTier) in modelFields {
                take(name) { value in
                    if namesLane == .claude {
                        next.claudeModels[modelTier.rawValue] = Intelligence.claudeName(value, tier: modelTier)
                    } else {
                        next.routerModels[modelTier.rawValue] = Intelligence.gatewayName(value)
                    }
                }
            }
            if let problem { return ["error": problem] }
            guard !applied.isEmpty else {
                return ["error": "set needs at least one of lane, tier, jevKey, jevModel, jevVision, jevFast, routerKey, routerURL, routerModel, haikuModel, sonnetModel, opusModel, textModel"]
            }
            keys = next
            var out = status
            out["applied"] = applied
            return out
        case let op:
            return ["error": "unknown intelligence op \(op) (status, sources, refresh, set, reload)"]
        }
    }

    /// Keys are secrets: the file is this user's alone (0600), and it is
    /// never the session or the settings, which other things read and write.
    private func save() {
        let file = Intelligence.file
        guard let data = try? JSONEncoder().encode(keys) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

// MARK: - Jev

/// One System One call. `state` is whatever the question is about; each
/// question is a `choice` (pick one of these), a `score` (where on this
/// rubric) or a `noul` (how likely is this true). Text only, no streaming,
/// one round trip — see https://docs.typesafe.ai.
enum Jev {
    /// Where a Jev key comes from: the user's own TypeSafe account. Every
    /// "no Jev key" message names it — Jev has no stand-in.
    static let keyPage = "https://console.typesafe.ai"

    struct Choice {
        let key: String
        let confidence: Double
        let probabilities: [String: Double]
    }

    /// A Box answer (Jev 1.14, images on): four edges as fractions of the
    /// image, (0, 0) top-left to (1, 1) bottom-right, and how sure.
    struct Box {
        let top: Double
        let bottom: Double
        let left: Double
        let right: Double
        let confidence: Double
        var centerX: Double { (left + right) / 2 }
        var centerY: Double { (top + bottom) / 2 }
    }

    struct Answer {
        var choices: [String: Choice] = [:]
        var nouls: [String: Double] = [:]
        var scores: [String: Double] = [:]
        var boxes: [String: Box] = [:]
        var latencyMs: Double = 0
        var inputTokens = 0
        /// The versioned model that answered (`jev-1.14.0`), when the API says.
        var model = ""
    }

    /// An image for the request's `assets` map: a JPEG or PNG, base64, under
    /// a reference string that is written wherever the picture belongs
    /// (docs.typesafe.ai/images). Every asset must be referenced somewhere.
    struct Asset {
        let reference: String
        let data: Data
        let format: String // "jpg" | "png"
        var json: [String: Any] { ["type": "image", "format": format, "data_base64": data.base64EncodedString()] }
    }

    struct Failure: LocalizedError {
        let kind: String
        let detail: String
        var errorDescription: String? { detail.isEmpty ? kind : "\(kind): \(detail)" }
    }

    static func choice(_ instructions: String, _ criteria: [String: String]) -> [String: Any] {
        ["type": "choice", "instructions": instructions, "criteria": criteria]
    }

    static func noul(_ instructions: String) -> [String: Any] {
        ["type": "noul", "instructions": instructions]
    }

    static func score(_ instructions: String, _ levels: [String]) -> [String: Any] {
        ["type": "score", "instructions": instructions, "criteria": levels]
    }

    /// Ask, with a hard budget. Anything but a clean 200 with `answers`
    /// throws; the caller decides whether to fail open to the router.
    /// `assets` attaches images (and turns on TypeSafe's images header, which
    /// Box questions need too); `model` overrides the configured one for this
    /// call — `jev-1.14.0` for a Box, say, while the default stays `jev-latest`.
    static func ask(state: Any, questions: [String: Any], keys: Intelligence.Keys, timeout: TimeInterval = 4,
                    assets: [Asset] = [], model override: String? = nil) async throws -> Answer {
        guard !keys.jevKey.isEmpty else { throw Failure(kind: "not_configured", detail: "No Jev key — get one at \(Jev.keyPage) and paste it in Settings › Intelligence") }
        guard let url = URL(string: keys.jevEndpoint) else { throw Failure(kind: "bad_endpoint", detail: keys.jevEndpoint) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(keys.jevKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("copper/\(Fork.version)", forHTTPHeaderField: "User-Agent")
        let model = (override ?? "").trimmingCharacters(in: .whitespaces)
        var body: [String: Any] = ["model": model.isEmpty ? keys.jevModel : model, "state": state, "questions": questions]
        let usesBox = questions.values.contains { (($0 as? [String: Any])?["type"] as? String) == "box" }
        if !assets.isEmpty || usesBox {
            // Images and Box are off by default on TypeSafe's side; this
            // header turns them on for this one request.
            request.setValue("true", forHTTPHeaderField: "TypeSafe-Danger-Zone-Images")
        }
        if !assets.isEmpty {
            var map: [String: Any] = [:]
            for asset in assets { map[asset.reference] = asset.json }
            body["assets"] = map
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let latency = Date().timeIntervalSince(started) * 1000
        guard let http = response as? HTTPURLResponse else { throw Failure(kind: "transport", detail: "no HTTP response") }
        guard http.statusCode == 200 else {
            throw Failure(kind: "http_\(http.statusCode)", detail: String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = payload["answers"] as? [String: Any]
        else { throw Failure(kind: "bad_response", detail: "no answers in body") }

        var out = Answer(latencyMs: latency)
        if let usage = payload["usage"] as? [String: Any] { out.inputTokens = (usage["input_tokens"] as? Int) ?? 0 }
        out.model = payload["model"] as? String ?? ""
        for (name, raw) in answers {
            guard let a = raw as? [String: Any] else { continue }
            if let box = a["box"] as? [String: Any],
               let top = (box["top"] as? NSNumber)?.doubleValue, let bottom = (box["bottom"] as? NSNumber)?.doubleValue,
               let left = (box["left"] as? NSNumber)?.doubleValue, let right = (box["right"] as? NSNumber)?.doubleValue {
                out.boxes[name] = Box(top: top, bottom: bottom, left: left, right: right,
                                      confidence: (a["confidence"] as? NSNumber)?.doubleValue ?? 0)
            } else if let picked = a["choice"] as? String {
                var probabilities: [String: Double] = [:]
                for (k, v) in (a["probabilities"] as? [String: Any]) ?? [:] { probabilities[k] = (v as? NSNumber)?.doubleValue ?? 0 }
                out.choices[name] = Choice(key: picked, confidence: (a["confidence"] as? NSNumber)?.doubleValue ?? 0, probabilities: probabilities)
            } else if let p = a["noul"] as? NSNumber {
                out.nouls[name] = p.doubleValue
            } else if let s = a["score"] as? NSNumber {
                out.scores[name] = s.doubleValue
            }
        }
        return out
    }
}

// MARK: - the router

/// The slow lane: one chat completion against an OpenAI-compatible gateway
/// (LiteLLM, here), asked for JSON and read leniently — fences and preambles
/// stripped — because not every model behind a router honours a format flag.
enum Router {
    struct Failure: LocalizedError {
        let detail: String
        /// The gateway's HTTP status, when it answered with one.
        var status: Int? = nil
        var errorDescription: String? { detail }
    }

    struct Reply {
        let json: [String: Any]
        let text: String
        let latencyMs: Double
        let model: String
    }

    static func ask(system: String, user: String, keys: Intelligence.Keys, timeout: TimeInterval = 20, maxTokens: Int = 400, model override: String? = nil) async throws -> Reply {
        if keys.lane == .claude {
            let token = try await ClaudeAccount.shared.token()
            let model = await MainActor.run { Intelligence.shared.model(override) }
            let reply: Reply
            do {
                reply = try await Claude.ask(token: token, model: model, system: system, user: user, timeout: timeout, maxTokens: maxTokens)
            } catch let failure as Claude.Failure where failure.status == 401 {
                let refreshed = try await ClaudeAccount.shared.refreshNow()
                reply = try await Claude.ask(token: refreshed, model: model, system: system, user: user, timeout: timeout, maxTokens: maxTokens)
            }
            let answered = reply.model
            await MainActor.run { Intelligence.shared.noteAnswer(sent: model, answered: answered) }
            return reply
        }

        guard !keys.routerKey.isEmpty else { throw Failure(detail: "No router key — Settings › Intelligence") }
        guard let base = URL(string: keys.routerURL) else { throw Failure(detail: "Bad router address: \(keys.routerURL)") }
        let url = base.appendingPathComponent("v1/chat/completions")
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(keys.routerKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("copper/\(Fork.version)", forHTTPHeaderField: "User-Agent")
        let chosen = await MainActor.run { Intelligence.shared.model(override) }
        // The instructions are marked for the cache (PromptCache); the
        // question is asked once, so it is not.
        func send(_ marks: PromptCache.Marks) async throws -> (Data, URLResponse) {
            let body = Router.body(model: chosen, maxTokens: maxTokens, messages: [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ], cache: marks)
            var sending = request
            sending.httpBody = try PromptCache.json(body)
            return try await URLSession.shared.data(for: sending)
        }

        let started = Date()
        var (data, response) = try await send(.prefix)
        if (response as? HTTPURLResponse)?.statusCode != 200, PromptCache.refused(data) {
            (data, response) = try await send(.none)
        }
        let latency = Date().timeIntervalSince(started) * 1000
        guard let http = response as? HTTPURLResponse else { throw Failure(detail: "no HTTP response") }
        guard http.statusCode == 200 else {
            throw Failure(detail: "router \(http.statusCode): \(String(decoding: data.prefix(300), as: UTF8.self))", status: http.statusCode)
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = payload["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any]
        else { throw Failure(detail: "router answered with no choices") }
        // Content is a string for chat models; a few gateways hand back a
        // list of parts, of which the text ones are what we want.
        var text = ""
        if let s = message["content"] as? String { text = s }
        else if let parts = message["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined()
        }
        let model = (payload["model"] as? String) ?? chosen
        let answered = payload["model"] as? String
        await MainActor.run { Intelligence.shared.noteAnswer(sent: chosen, answered: answered) }
        return Reply(json: Router.json(in: text), text: text, latencyMs: latency, model: model)
    }

    /// One chat-completions body. No `temperature`, no thinking switch and
    /// no forced tool: the newest models (Opus 5.5) refuse a sampling knob,
    /// and `auto` is the one tool_choice every model behind a gateway takes.
    /// A Claude model gets prompt-cache marks (PromptCache); write it with
    /// `PromptCache.json` so the same history is the same bytes every turn.
    static func body(model: String, maxTokens: Int, messages: [[String: Any]], tools: [[String: Any]] = [],
                     cache: PromptCache.Marks = .prefix) -> [String: Any] {
        let marks = PromptCache.gatewayCaches(model) ? cache : .none
        let (messages, tools) = PromptCache.chat(messages: messages, tools: tools, marks: marks)
        var body: [String: Any] = ["model": model, "max_tokens": maxTokens, "messages": messages]
        if !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = "auto"
        }
        return body
    }

    /// The first JSON object in a reply, fences and chatter around it ignored.
    static func json(in text: String) -> [String: Any] {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else { return [:] }
        let slice = String(text[open...close])
        if let data = slice.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        return [:]
    }
}

// MARK: - self test (`./bench --world W ai selftest`, also in `agent selftest`)

extension Intelligence {
    /// The model-name migration, the local-over-cloud merge, the cloud
    /// answer's decoder, the request shapes and their prompt-cache marks.
    /// Pure: no file, no network.
    static func selfTest() -> [String] {
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String) { if !ok { failures.append("intelligence: \(name)") } }

        // Every spelling of a tier is that tier; anything else is not.
        let tiers: [(String, Tier?)] = [
            ("opus", .opus), ("OPUS", .opus), ("opus-5", .opus), ("opus-5.5", .opus), ("exowatt/opus", .opus),
            ("exowatt/opus-5", .opus), ("claude-opus-5", .opus), ("claude-opus-5-5", .opus),
            ("anthropic/claude-opus-5", .opus), ("claude-opus-latest", .opus),
            ("sonnet", .sonnet), ("exowatt/sonnet", .sonnet), ("claude-sonnet-5", .sonnet),
            ("claude-sonnet-4-5-20250929", .sonnet), ("claude-3-5-sonnet-20241022", .sonnet),
            ("haiku", .haiku), ("claude-haiku-4-5", .haiku), ("claude-3-5-haiku-latest", .haiku),
            ("gpt-4o-mini", nil), ("luna", nil), ("exowatt/luna", nil), ("sonnet-1m", nil),
            ("opus-fast", nil), ("my-opus-proxy", nil), ("", nil),
        ]
        for (name, want) in tiers { check(family(of: name) == want, "family(\(name))") }
        check(gatewayName("exowatt/opus-5") == "opus", "gateway exowatt/opus-5 → opus")
        check(gatewayName("claude-opus-5-5") == "opus", "gateway claude-opus-5-5 → opus")
        check(gatewayName("exowatt/luna") == "luna", "gateway strips exowatt/ off a custom name")
        check(gatewayName("gpt-4o-mini") == "gpt-4o-mini", "gateway leaves a custom name")
        check(claudeName("claude-opus-5", tier: .opus) == "claude-opus-5-5", "claude lane: opus-5 → current")
        check(claudeName("exowatt/opus", tier: .opus) == "claude-opus-5-5", "claude lane: exowatt/opus → current")
        check(claudeName("", tier: .haiku) == "claude-haiku-4-5", "claude lane: empty → current")

        // intelligence.json written by older builds decodes to the floats.
        func decode(_ json: String) -> Keys? { try? JSONDecoder().decode(Keys.self, from: Data(json.utf8)) }
        if let k = decode(#"{"routerKey":"sk-x","routerModel":"exowatt/sonnet","routerModels":{"opus":"exowatt/opus-5","sonnet":"claude-sonnet-5","haiku":"gpt-4o-mini"},"claudeModels":{"opus":"claude-opus-5","sonnet":"claude-sonnet-5"},"textModel":"exowatt/haiku-4-5","tier":"opus"}"#) {
            check(k.routerModels["opus"] == "opus", "migrate routerModels.opus")
            check(k.routerModels["sonnet"] == "sonnet", "migrate routerModels.sonnet")
            check(k.routerModels["haiku"] == "gpt-4o-mini", "keep a custom routerModels name")
            check(k.routerModel == "sonnet", "migrate routerModel")
            check(k.claudeModels["opus"] == "claude-opus-5-5", "migrate claudeModels.opus")
            check(k.claudeModels["haiku"] == "claude-haiku-4-5", "claudeModels default filled")
            check(k.textModel == "haiku", "migrate textModel to its tier")
            check(k.routerKey == "sk-x" && k.tier == .opus, "keys and tier kept")
            check(name(for: .opus, lane: .key, keys: k) == "opus", "gateway sends opus")
            check(name(for: .opus, lane: .claude, keys: k) == "claude-opus-5-5", "claude lane sends current opus")
            check(name(for: .haiku, lane: .key, keys: k) == "gpt-4o-mini", "gateway sends the custom haiku")
            if let again = try? JSONDecoder().decode(Keys.self, from: JSONEncoder().encode(k)) {
                check(again == k, "round trip is stable")
            } else { check(false, "round trip decodes") }
        } else { check(false, "decode a migrated file") }
        if let legacy = decode(#"{"routerModel":"exowatt/opus-5"}"#) {
            check(legacy.routerModel == "opus" && legacy.routerModels["sonnet"] == "sonnet", "legacy pinned routerModel not copied into sonnet")
        } else { check(false, "decode legacy pinned") }
        if let legacy = decode(#"{"routerModel":"gpt-4o"}"#) {
            check(legacy.routerModels["sonnet"] == "gpt-4o", "legacy custom routerModel still lands in sonnet")
        } else { check(false, "decode legacy custom") }
        if let empty = decode("{}") {
            check(empty == Keys(), "an empty file is the defaults")
            check(name(for: .sonnet, lane: .key, keys: empty) == "sonnet", "default gateway sonnet is the float")
        } else { check(false, "decode empty") }

        // Cloud answer: lenient, nulls and wrong types are \"not provided\".
        let full = CloudProvided.parse(Data(#"{"jev":{"key":"ts-cloud-1234567","endpoint":"https://api.typesafe.ai/v1/systemone","model":"jev-latest"},"router":{"key":"sk-cloud-1234567","url":"https://llm.dev.exowatt.com"},"updated_at":"2026-10-03T12:00:00Z"}"#.utf8))
        check(full?.jev?.key == "ts-cloud-1234567" && full?.router?.url == "https://llm.dev.exowatt.com" && full?.updatedAt == "2026-10-03T12:00:00Z", "parse a full answer")
        check(full?.provides == ["jev", "router"], "provides both")
        let nulls = CloudProvided.parse(Data(#"{"jev":null,"router":{"key":null,"url":"https://gw.example"},"updated_at":null}"#.utf8))
        check(nulls != nil && nulls?.jev == nil && nulls?.router?.key == nil && nulls?.router?.url == "https://gw.example" && nulls?.provides == [], "parse nulls")
        let odd = CloudProvided.parse(Data(#"{"jev":{"key":5,"model":["x"]},"router":"nope","extra":1}"#.utf8))
        check(odd != nil && odd!.isEmpty, "wrong types are not provided")
        check(CloudProvided.parse(Data("{}".utf8))?.isEmpty == true, "an empty object provides nothing")
        check(CloudProvided.parse(Data("[]".utf8)) == nil && CloudProvided.parse(Data("<html>".utf8)) == nil, "not an object is nil")
        // The org's agent turn budget: top level, beside the keys, 1…500 only.
        func turns(_ json: String) -> Int? { CloudProvided.parse(Data(json.utf8))?.agentMaxTurns }
        let withAgent = CloudProvided.parse(Data(#"{"jev":null,"router":{"key":"sk-cloud-1234567","url":"https://gw.example"},"agent":{"max_turns":100}}"#.utf8))
        check(withAgent?.agentMaxTurns == 100 && withAgent?.provides == ["router"], "parse agent.max_turns beside the keys")
        check(full?.agent == nil && full?.agentMaxTurns == nil, "agent absent (an older cloud): not provided")
        check(turns(#"{"agent":null}"#) == nil && turns(#"{"agent":{"max_turns":null}}"#) == nil && turns(#"{"agent":{}}"#) == nil, "agent null: not provided")
        check(turns(#"{"agent":{"max_turns":1}}"#) == 1 && turns(#"{"agent":{"max_turns":500}}"#) == 500, "agent 1 and 500 are in range")
        check(turns(#"{"agent":{"max_turns":0}}"#) == nil && turns(#"{"agent":{"max_turns":501}}"#) == nil && turns(#"{"agent":{"max_turns":-5}}"#) == nil, "agent out of range: ignored")
        check(turns(#"{"agent":{"max_turns":100.5}}"#) == nil && turns(#"{"agent":{"max_turns":true}}"#) == nil && turns(#"{"agent":{"max_turns":"100"}}"#) == nil && turns(#"{"agent":5}"#) == nil, "agent wrong types: ignored")
        check(turns(#"{"agent":{"max_turns":100.0}}"#) == 100, "agent 100.0 is 100")
        if let agentOnly = CloudProvided.parse(Data(#"{"jev":null,"router":null,"agent":{"max_turns":80},"updated_at":null}"#.utf8)) {
            check(!agentOnly.isEmpty && agentOnly.provides == [], "an agent value alone is something provided, not a key")
            // cloud-intelligence.json keeps it the way CloudIntelligence writes it.
            var cached = agentOnly
            cached.fetchedAt = Date(timeIntervalSince1970: 1_790_000_000)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            if let data = try? encoder.encode(cached), let text = String(data: data, encoding: .utf8), let back = try? decoder.decode(CloudProvided.self, from: data) {
                check(text.contains(#""max_turns":80"#) && back == cached && back.agentMaxTurns == 80, "agent survives the cache")
            } else { check(false, "encode the agent part") }
            if let old = try? decoder.decode(CloudProvided.self, from: Data(#"{"router":{"key":"sk-x"},"host":"h"}"#.utf8)) {
                check(old.agent == nil, "a cache from before the agent part decodes")
            } else { check(false, "decode an older cache") }
        } else { check(false, "parse an agent-only answer") }
        check(CloudProvided(agent: .init(maxTurns: 900)).agentMaxTurns == nil && CloudProvided(agent: .init(maxTurns: 900)).isEmpty, "an out-of-range cached value is not used")
        check(CloudProvided.masked("sk-abcdefghijkl") == "sk-…ijkl" && !CloudProvided.masked("sk-abcdefghijkl").contains("abcdefgh"), "masked")

        // This Mac and the cloud, field by field.
        let cloud = CloudProvided(jev: .init(key: "ts-cloud", endpoint: "https://jev.cloud.example/v1", model: "jev-cloud"),
                                  router: .init(key: "sk-cloud", url: "https://gw.cloud.example"), host: "cloud.example")
        var local = Keys()
        var m = merge(local: local, cloud: cloud)
        check(m.keys.jevKey == "ts-cloud" && m.keys.routerKey == "sk-cloud", "empty local takes the cloud's keys")
        check(m.keys.jevEndpoint == "https://jev.cloud.example/v1" && m.keys.routerURL == "https://gw.cloud.example", "the cloud's addresses follow its keys")
        check(m.keys.jevModel == "jev-cloud", "the cloud's jev model over the default")
        check(m.sources == ["jevKey": "cloud", "jevEndpoint": "cloud", "jevModel": "cloud", "routerKey": "cloud", "routerURL": "cloud", "lane": "cloud"], "all cloud sources")
        local.jevKey = "ts-mine"
        local.routerKey = "  sk-mine "
        local.routerURL = "https://my.gateway.example"
        m = merge(local: local, cloud: cloud)
        check(m.keys.jevKey == "ts-mine" && m.sources["jevKey"] == "local", "a local jev key wins")
        check(m.keys.routerKey == "sk-cloud" && m.sources["routerKey"] == "cloud", "local .key with its own key: the cloud's gateway key wins")
        check(m.keys.routerURL == "https://gw.cloud.example" && m.sources["routerURL"] == "cloud", "local .key with its own address: the cloud's address wins")
        check(m.keys.lane == .key && m.sources["lane"] == "cloud", "local .key: the lane is the cloud's")
        check(m.keys.jevEndpoint == Keys().jevEndpoint && m.sources["jevEndpoint"] == "default", "a local jev key keeps the default endpoint")
        check(m.keys.jevModel == "jev-cloud" && m.sources["jevModel"] == "cloud", "jev model: default local yields to the cloud")
        let urlOnly = CloudProvided(router: .init(key: nil, url: "https://gw.cloud.example"))
        m = merge(local: local, cloud: urlOnly)
        check(m.keys.routerKey == "  sk-mine " && m.keys.routerURL == "https://my.gateway.example" && m.sources["lane"] == "local", "a local key is never sent to the cloud's address")
        local = Keys()
        local.routerKey = "   "
        local.routerURL = "https://my.gateway.example/"
        local.jevModel = "jev-mine"
        m = merge(local: local, cloud: cloud)
        check(m.keys.routerKey == "sk-cloud" && m.sources["routerKey"] == "cloud", "a blank local key is no key")
        check(m.keys.routerURL == "https://gw.cloud.example" && m.sources["routerURL"] == "cloud", "the cloud's address over a custom local one")
        check(m.keys.jevModel == "jev-mine" && m.sources["jevModel"] == "local", "a custom local jev model wins")
        m = merge(local: local, cloud: nil)
        check(m.keys.routerURL == "https://my.gateway.example/" && m.sources["routerURL"] == "local", "no cloud: a custom local address wins")
        local = Keys()
        local.routerURL = "https://llm.dev.exowatt.com/"
        m = merge(local: local, cloud: nil)
        check(m.sources["routerURL"] == "default", "the default address with a slash is still the default")
        m = merge(local: Keys(), cloud: nil)
        check(m.keys == Keys() && m.sources == ["jevKey": "none", "jevEndpoint": "default", "jevModel": "default", "routerKey": "none", "routerURL": "default", "lane": "local"], "no cloud, no keys")
        let bad = CloudProvided(router: .init(key: "sk-cloud", url: "ftp://nope"))
        m = merge(local: Keys(), cloud: bad)
        check(m.keys.routerKey == "sk-cloud" && m.keys.routerURL == Keys().routerURL && m.sources["routerURL"] == "default", "a bad cloud address is ignored")

        // The lane: Copper Cloud's gateway key puts every model call on the
        // gateway, whatever this Mac chose; this Mac's choice is kept.
        var claude = Keys()
        claude.lane = .claude
        claude.tier = .opus
        m = merge(local: claude, cloud: cloud)
        check(m.keys.lane == .key && m.sources["lane"] == "cloud", "local .claude + cloud key: the gateway lane")
        check(m.keys.routerKey == "sk-cloud" && m.keys.routerURL == "https://gw.cloud.example", "local .claude + cloud key: the cloud's key and address")
        check(name(for: m.keys.tier, lane: m.keys.lane, keys: m.keys) == "opus" && m.keys.tier == .opus, "local .claude + cloud key: the gateway's name for this Mac's tier")
        check(claude.lane == .claude, "merging never changes this Mac's lane")
        m = merge(local: claude, cloud: nil)
        check(m.keys.lane == .claude && m.sources["lane"] == "local", "local .claude, no cloud: the Claude lane")
        m = merge(local: claude, cloud: CloudProvided(jev: .init(key: "ts-cloud")))
        check(m.keys.lane == .claude && m.sources["lane"] == "local", "a cloud Jev key alone leaves the lane")
        m = merge(local: claude, cloud: urlOnly)
        check(m.keys.lane == .claude && m.sources["lane"] == "local", "a cloud address without a key leaves the lane")
        if let saved = try? JSONEncoder().encode(claude), let text = String(data: saved, encoding: .utf8) {
            check(text.contains("\"lane\":\"claude\"") && !text.contains("sk-cloud"), "intelligence.json keeps .claude and never the cloud's key")
        } else { check(false, "encode local keys") }

        // The same on the live instance: every caller follows the lane in
        // force, and the cloud going gives this Mac's choice back untouched.
        // Synchronous on the main actor, so no fetch lands in between.
        let me = Intelligence.shared
        let before = me.cloud
        let chosen = me.keys.lane
        let onDisk = try? Data(contentsOf: Intelligence.file)
        me.adoptCloud(CloudProvided(router: .init(key: "sk-selftest-cloud", url: "https://gw.selftest.example"), host: "selftest.example"))
        check(me.lane == .key && me.laneSource == "cloud" && me.cloudLane, "live: the cloud's key decides the lane")
        check(me.effective.routerKey == "sk-selftest-cloud" && me.effective.routerURL == "https://gw.selftest.example", "live: the cloud's key and address")
        check(me.modelReady && me.modelName == name(for: me.tier, lane: .key, keys: me.effective), "live: ready, with the gateway's name")
        check(me.status["lane"] as? String == "key" && me.status["laneSource"] as? String == "cloud" && me.status["localLane"] as? String == chosen.rawValue, "live: status says lane key from the cloud")
        check(me.keys.lane == chosen, "live: this Mac's lane kept")
        me.adoptCloud(nil)
        check(me.lane == chosen && me.laneSource == "local" && !me.cloudLane, "live: the cloud gone, this Mac's lane again")
        check((try? Data(contentsOf: Intelligence.file)) == onDisk, "live: intelligence.json untouched")
        me.adoptCloud(before)

        // What goes on the wire works on Opus 5.5.
        let tool: [[String: Any]] = [["type": "function", "function": ["name": "x"]]]
        let chat = Router.body(model: "opus", maxTokens: 100, messages: [["role": "user", "content": "hi"]], tools: tool)
        check(chat["temperature"] == nil && chat["thinking"] == nil && chat["tool_choice"] as? String == "auto" && chat["model"] as? String == "opus", "gateway body")
        check(Router.body(model: "opus", maxTokens: 1, messages: [])["tool_choice"] == nil, "no tools, no tool_choice")
        let messages = Claude.body(model: "claude-opus-5-5", system: [], messages: [], tools: [["name": "x"]], maxTokens: 10)
        check(messages["temperature"] == nil && messages["thinking"] == nil && (messages["tool_choice"] as? [String: String]) == ["type": "auto"], "claude body")
        // Prompt-cache marks on both lanes (Fork/PromptCache.swift).
        return failures + PromptCache.selfTest()
    }
}
