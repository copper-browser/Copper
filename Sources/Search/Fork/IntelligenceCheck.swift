import Foundation

// Settings › Intelligence › Check: one question to Jev and one to the model
// lane in force, answered in plain words — what happened and the one thing
// to do next — rather than an HTTP status and a body. The result outlives
// the page (it is here, not in the view), and the key fields read it: a key
// the last check saw refused is drawn as refused until it changes. A verdict
// is about the setup it was asked with: change the lane, the model or a key
// and it no longer says anything, so the row goes back to its idle line.

@MainActor
final class IntelligenceCheck: ObservableObject {
    static let shared = IntelligenceCheck()

    struct Result: Equatable {
        /// `jev`, `router` or `claude`.
        let lane: String
        let ok: Bool
        let text: String
        /// The key itself was turned away (not the network, not the model).
        var refused = false
    }

    /// What a check is asked with, as data, so the rules about when a
    /// verdict still holds can be tested without a window or a network.
    struct Setup: Equatable {
        var keys: Intelligence.Keys
        /// The name the model lane sends (the tier, through Model names).
        var model: String
        /// Who the Claude account lane is signed in as (and which sign-in).
        var account: String

        /// One lane's key and address: a refusal stops counting once this
        /// changes. Hashed, so no second copy of a key is kept.
        func key(_ lane: String) -> Int {
            var hasher = Hasher()
            hasher.combine(lane)
            switch lane {
            case "jev": hasher.combine(keys.jevKey); hasher.combine(keys.jevEndpoint)
            case "router": hasher.combine(keys.routerKey); hasher.combine(keys.routerURL)
            default: hasher.combine(account)
            }
            return hasher.finalize()
        }

        /// The model lane in force: `claude` or `router`.
        var modelLane: String { keys.lane == .claude ? "claude" : "router" }

        /// Everything a verdict depends on: both lanes' keys, which model
        /// lane is in force, and the model it asks for.
        var whole: Int {
            var hasher = Hasher()
            hasher.combine(key("jev"))
            hasher.combine(modelLane)
            hasher.combine(key(modelLane))
            hasher.combine(model)
            return hasher.finalize()
        }
    }

    @Published private(set) var running = false
    @Published private(set) var results: [Result] = []
    @Published private(set) var at: Date?
    /// What each lane was asked with, so a refusal stops counting once the
    /// key (or the address) behind it changes.
    private var askedWith: [String: Int] = [:]
    /// The whole setup the last check ran against.
    private var askedSetup: Int?

    private init() {}

    /// The setup as it is now.
    static var setup: Setup {
        let brain = Intelligence.shared
        let account = ClaudeAccount.shared
        let signedIn = account.credential.map { "\($0.email)#\(account.session)" } ?? ""
        return Setup(keys: brain.effective, model: brain.modelName, account: signedIn)
    }

    /// Whether the last verdict was asked with the setup there is now.
    var fresh: Bool { Self.holds(askedSetup, now: Self.setup) }

    nonisolated static func holds(_ asked: Int?, now: Setup) -> Bool {
        guard let asked else { return false }
        return asked == now.whole
    }

    /// The verdict as the row says it: one sentence per lane, or nil while
    /// there is none for the setup as it is now.
    var line: String? {
        guard !results.isEmpty, fresh else { return nil }
        return results.map(\.text).joined(separator: "\n")
    }

    /// A key the last check saw refused, and still the same key.
    func refused(_ lane: String) -> Bool {
        guard let result = results.first(where: { $0.lane == lane }), result.refused else { return false }
        return askedWith[lane] == Self.setup.key(lane)
    }

    func run() {
        guard !running else { return }
        running = true
        let brain = Intelligence.shared
        let setup = Self.setup
        let keys = setup.keys
        let model = setup.model
        let jevReady = brain.jevReady
        let modelReady = brain.modelReady
        Task { @MainActor in
            var out: [Result] = []
            var asked: [String: Int] = [:]
            if jevReady {
                asked["jev"] = setup.key("jev")
                do {
                    let a = try await Jev.ask(state: ["word": "apple"], questions: ["kind": Jev.choice("What is `word`?", ["fruit": "a fruit", "tool": "a tool"])], keys: keys)
                    out.append(Result(lane: "jev", ok: true, text: "Jev answered in \(Self.duration(a.latencyMs))."))
                } catch {
                    out.append(Self.jevFailure(error))
                }
            } else if modelReady {
                out.append(Result(lane: "jev", ok: true, text: "No Jev key — Jev runs use the model instead, one call per step. A key makes them fast."))
            } else {
                out.append(Result(lane: "jev", ok: false, text: "Jev has no key yet — paste one below, or sign in with a Claude account above."))
            }
            let lane = keys.lane == .claude ? "claude" : "router"
            if modelReady {
                asked[lane] = setup.key(lane)
                do {
                    let r = try await Router.ask(system: "Reply with JSON only.", user: "{\"ping\": true} → reply {\"pong\": true}", keys: keys, timeout: 15, maxTokens: 20)
                    let who = keys.lane == .claude ? "Claude" : "The gateway"
                    out.append(Result(lane: lane, ok: true, text: "\(who) answered as \(r.model) in \(Self.duration(r.latencyMs))."))
                } catch {
                    out.append(keys.lane == .claude ? Self.claudeFailure(error) : Self.gatewayFailure(error, model: model))
                }
            } else if keys.lane == .claude {
                out.append(Result(lane: lane, ok: false, text: "Not signed in to Claude — Sign in above."))
            } else if keys.routerKey.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(Result(lane: lane, ok: false, text: "The gateway has no key yet — paste one above."))
            } else {
                out.append(Result(lane: lane, ok: false, text: "The gateway address isn't a web address — it should start with https://"))
            }
            results = out
            askedWith = asked
            askedSetup = setup.whole
            at = Date()
            running = false
        }
    }

    /// For `bench ai check`.
    var report: [String: Any] {
        ["running": running, "line": line ?? "", "fresh": fresh,
         "refused": ["jev": refused("jev"), "router": refused("router"), "claude": refused("claude")],
         "results": results.map { ["lane": $0.lane, "ok": $0.ok, "text": $0.text, "refused": $0.refused] as [String: Any] }]
    }

    // MARK: - words

    nonisolated static func duration(_ ms: Double) -> String {
        ms < 1000 ? "\(Int(ms.rounded())) ms" : String(format: "%.1f s", ms / 1000)
    }

    /// A transport failure in a person's words, or nil for anything else.
    nonisolated static func network(_ error: Error, _ who: String, waited: Int) -> String? {
        guard let url = error as? URLError else { return nil }
        switch url.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return "This Mac is offline — \(who) wasn't asked. Try again once you're connected."
        case .timedOut:
            return "\(who) didn't answer in \(waited) seconds. Try again; if it keeps happening, check the address."
        case .cannotFindHost, .dnsLookupFailed:
            return "\(who) couldn't be found at that address — check it, or your network."
        case .cannotConnectToHost:
            return "Nothing answered at \(who.lowercased())'s address — check it."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return "\(who)'s address has a certificate this Mac doesn't trust."
        case .unsupportedURL, .badURL:
            return "That isn't a web address \(who.lowercased()) can be reached at — it should start with https://"
        default:
            return "\(who) couldn't be reached (\(url.code.rawValue)). Try again."
        }
    }

    nonisolated static func jevFailure(_ error: Error) -> Result {
        if let words = network(error, "Jev", waited: 4) { return Result(lane: "jev", ok: false, text: words) }
        let kind = (error as? Jev.Failure)?.kind ?? ""
        switch kind {
        case "http_401", "http_403":
            return Result(lane: "jev", ok: false, text: "Jev turned the key away — paste a new one below.", refused: true)
        case "http_402":
            return Result(lane: "jev", ok: false, text: "Jev says this key's account is out of credit.", refused: true)
        case "http_429":
            return Result(lane: "jev", ok: false, text: "Jev is busy with this key just now — try again in a minute.")
        case "bad_endpoint":
            return Result(lane: "jev", ok: false, text: "Jev's address isn't a web address.")
        default:
            if kind.hasPrefix("http_5") { return Result(lane: "jev", ok: false, text: "Jev is having trouble on its side (\(kind.dropFirst(5))). Try again later.") }
            if kind.hasPrefix("http_") { return Result(lane: "jev", ok: false, text: "Jev answered with an error (\(kind.dropFirst(5))).") }
            return Result(lane: "jev", ok: false, text: "Jev's answer didn't make sense. Try again.")
        }
    }

    nonisolated static func gatewayFailure(_ error: Error, model: String) -> Result {
        if let words = network(error, "The gateway", waited: 15) { return Result(lane: "router", ok: false, text: words) }
        let failure = error as? Router.Failure
        let body = (failure?.detail ?? "").lowercased()
        switch failure?.status {
        case 401?, 403?:
            return Result(lane: "router", ok: false, text: "The gateway turned the key away — paste a new one above.", refused: true)
        case let status? where (status == 400 || status == 404) && body.contains("model"):
            return Result(lane: "router", ok: false, text: "The gateway has no model called “\(model)” — check Model names.")
        case 404?:
            return Result(lane: "router", ok: false, text: "Nothing at that address answers like a gateway — check the address.")
        case 429?:
            return Result(lane: "router", ok: false, text: "The gateway is limiting this key just now — try again in a minute.")
        case let status? where status >= 500:
            return Result(lane: "router", ok: false, text: "The gateway is having trouble on its side (\(status)). Try again later.")
        case let status?:
            return Result(lane: "router", ok: false, text: "The gateway answered with an error (\(status)).")
        case nil:
            return Result(lane: "router", ok: false, text: "The gateway's answer didn't make sense — is that the right address?")
        }
    }

    nonisolated static func claudeFailure(_ error: Error) -> Result {
        if let words = network(error, "Claude", waited: 15) { return Result(lane: "claude", ok: false, text: words) }
        if let failure = error as? Claude.Failure {
            switch failure.status {
            case 401, 403: return Result(lane: "claude", ok: false, text: "Claude signed this Mac out — sign in again above.", refused: true)
            case 429: return Result(lane: "claude", ok: false, text: "Your Claude plan's limit is reached for now — try again later.")
            case 500...: return Result(lane: "claude", ok: false, text: "Claude is having trouble on its side (\(failure.status)). Try again later.")
            default: return Result(lane: "claude", ok: false, text: "Claude answered with an error (\(failure.status)).")
            }
        }
        if let failure = error as? ClaudeAccount.Failure {
            if failure.text.hasPrefix("Not signed in") { return Result(lane: "claude", ok: false, text: "Not signed in to Claude — Sign in above.") }
            return Result(lane: "claude", ok: false, text: "Claude's sign-in has run out — sign in again above.", refused: true)
        }
        return Result(lane: "claude", ok: false, text: "Claude couldn't be asked: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
    }
}
