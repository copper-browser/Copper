import Foundation
import WebKit

/// Where an in-process sign-in was requested. The source is intentionally
/// used only for routing/telemetry inside Copper; it is never returned to the
/// caller as a secret-bearing value.
enum Source {
    case mcp
    case jev
}

/// Resolve a shared credential and fill it directly into the current page.
/// Secrets cross only the Copper process boundary and the page's form helper;
/// this method never returns one to MCP, Jev, or the CLI.
enum SignIn {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    static func run(_ args: [String: Any], in browser: Browser, source: Source) async throws -> [String: Any] {
        guard let tab = AgentTabs.target(in: browser) else { throw Failure(message: AgentTabs.missing()) }
        AgentTabs.prepare(tab)
        guard !tab.shy else { throw Failure(message: "sign-in is unavailable in private tabs") }
        let what = ((args["what"] as? String) ?? "password").lowercased()
        guard what == "password" || what == "otp" else {
            throw Failure(message: "what must be password or otp")
        }
        let account = (args["account"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Fork (form-origin): the page itself, unless a frame is named or
        // exactly one frame holds a sign-in a shared login is saved for —
        // never wherever the caret happens to be. And only a login saved for
        // that document's exact address (scheme, host and port).
        let target = try await place(args, tab: tab, otp: what == "otp", account: account)
        let host = target.host
        let framed = target.frame == nil ? "" : " (in the embedded frame from \(target.origin))"

        let all = Credentials.candidates(for: host)
        let permitted = shared(for: target)
        guard !permitted.isEmpty else {
            let wider = AgentAccess.permitted(for: host)
            if !wider.isEmpty {
                let saved = Array(Set(wider.flatMap(\.sites))).sorted().prefix(4).joined(separator: ", ")
                throw Failure(message: "the shared login for \(host) is saved for \(saved), not \(target.origin)\(framed) — agents fill a login only on the exact address it was saved for. Save it for this address (browser_vault_save, or add the address to the item) to use it here")
            }
            if !all.isEmpty {
                throw Failure(message: "credential for \(host) exists but is not shared with agents — enable it in Settings › Passwords › Agent access")
            }
            // Bitwarden deliberately drops its metadata cache when locked. If
            // no keychain candidate remains, a locked vault is the only
            // credential source Copper can have for this host.
            if case .locked = Bitwarden.shared.state {
                throw Failure(message: "bitwarden is locked — unlock it in Settings › Passwords")
            }
            if OnePassword.shared.isLocked {
                throw Failure(message: "1password is locked — unlock it in Settings › Passwords")
            }
            throw Failure(message: "no saved credential for \(host)\(framed)\(await elsewhere(tab, target: target, otp: what == "otp"))")
        }

        let selected: Credential?
        if let account, !account.isEmpty {
            selected = permitted.first(where: { $0.user == account })
                ?? permitted.first(where: { $0.user.caseInsensitiveCompare(account) == .orderedSame })
            if selected == nil {
                if all.contains(where: { $0.user.caseInsensitiveCompare(account) == .orderedSame }) {
                    throw Failure(message: "account \(account) for \(host) is not shared with agents — enable it in Settings › Passwords › Agent access")
                }
                throw Failure(message: "no shared account named \(account) for \(host); saved: \(permitted.map(\.user).joined(separator: ", "))")
            }
        } else if permitted.count == 1 {
            selected = permitted[0]
        } else {
            return ["candidates": permitted.map(\.user), "host": host]
        }
        guard let credential = selected else {
            return ["candidates": permitted.map(\.user), "host": host]
        }

        let submit = (args["submit"] as? Bool) ?? true

        switch what {
        case "password":
            // The field first, the secret second: a page with nothing to fill
            // never causes a read from the vault.
            guard await tab.hasPasswordField(at: target) else {
                throw Failure(message: "sign-in fields not found on the page\(framed)\(await elsewhere(tab, target: target, otp: false))")
            }
            let secret: String
            do {
                secret = try await Credentials.secret(credential.id)
            } catch {
                if credential.source == .bitwarden, case .locked = Bitwarden.shared.state {
                    throw Failure(message: "bitwarden is locked — unlock it in Settings › Passwords")
                }
                if credential.source == .onePassword, !OnePassword.shared.isUnlocked {
                    throw Failure(message: "1password is locked — unlock it in Settings › Passwords")
                }
                throw error
            }
            let filled = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                tab.fill(user: credential.user, password: secret, at: target) { ok in
                    continuation.resume(returning: ok)
                }
            }
            guard filled else { throw Failure(message: "sign-in fields not found on the page") }
            let submitted: Bool
            if submit {
                submitted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    tab.submitSignIn(at: target) { ok in continuation.resume(returning: ok) }
                }
            } else {
                submitted = false
            }
            Credentials.touch(credential)
            let sourceName: String
            switch credential.source {
            case .bitwarden: sourceName = "bitwarden"
            case .onePassword: sourceName = "onepassword"
            case .keychain: sourceName = "keychain"
            }
            return ["filled": true, "account": credential.user, "host": host,
                    "submitted": submitted, "source": sourceName]

        case "otp":
            guard credential.hasTOTP else { throw Failure(message: "no one-time code for this account") }
            guard await tab.hasOTPField(at: target) else {
                throw Failure(message: "no one-time-code field on the page\(framed)\(await elsewhere(tab, target: target, otp: true))")
            }
            let code: String
            do {
                code = try await Credentials.totp(credential.id)
            } catch {
                if credential.source == .bitwarden, case .locked = Bitwarden.shared.state {
                    throw Failure(message: "bitwarden is locked — unlock it in Settings › Passwords")
                }
                if credential.source == .onePassword, !OnePassword.shared.isUnlocked {
                    throw Failure(message: "1password is locked — unlock it in Settings › Passwords")
                }
                throw error
            }
            let filled = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                tab.fillOTP(code, at: target) { ok in continuation.resume(returning: ok) }
            }
            guard filled else { throw Failure(message: "no one-time-code field on the page") }
            let submitted: Bool
            if submit {
                submitted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    tab.submitOTP(at: target) { ok in continuation.resume(returning: ok) }
                }
            } else {
                submitted = false
            }
            return ["filled": true, "account": credential.user, "what": "otp", "submitted": submitted]
        default:
            throw Failure(message: "what must be password or otp")
        }
    }

    // MARK: - where it goes (Fork: form-origin)

    /// The shared logins an agent may fill into `target`: saved for that
    /// document's exact address, and (when asked for by name) that account.
    @MainActor
    static func shared(for target: Tab.FormTarget, account: String? = nil) -> [Credential] {
        AgentAccess.permitted(for: target.host).filter { credential in
            guard Credentials.owns(credential, origin: target.origin) else { return false }
            guard let account, !account.isEmpty else { return true }
            return credential.user.caseInsensitiveCompare(account) == .orderedSame
        }
    }

    @MainActor
    private static func spot(_ frame: WKFrameInfo) -> Tab.FormTarget? {
        guard let host = Tab.bare(frame.securityOrigin.host), let origin = Credentials.origin(of: frame.securityOrigin) else { return nil }
        return Tab.FormTarget(frame: frame, host: host, origin: origin)
    }

    @MainActor
    private static func has(_ target: Tab.FormTarget, otp: Bool, in tab: Tab) async -> Bool {
        otp ? await tab.hasOTPField(at: target) : await tab.hasPasswordField(at: target)
    }

    /// The document a sign-in goes into: the frame the agent named; else the
    /// page, when it has the boxes; else the one embedded frame that has
    /// them and a shared login saved for its own address. Two such frames
    /// are a question for the agent. The caret picks nothing: a frame can
    /// take it.
    @MainActor
    static func place(_ args: [String: Any], tab: Tab, otp: Bool, account: String?) async throws -> Tab.FormTarget {
        if let named = (args["frame"] as? String)?.trimmingCharacters(in: .whitespaces), !named.isEmpty {
            let entry: Tools.Frames.Entry
            do { entry = try Tools.Frames.frame(named: named, in: tab.web) } catch { throw Failure(message: error.localizedDescription) }
            guard let target = spot(entry.info) else { throw Failure(message: "frame \(named) has no address a login could be saved for") }
            return target
        }
        guard let page = tab.pageTarget else { throw Failure(message: "current tab has no host") }
        if await has(page, otp: otp, in: tab) { return page }
        var owned: [(number: Int, target: Tab.FormTarget)] = []
        // Only frames whose forms script has seen a sign-in or code box: a page of ad frames costs nothing.
        for entry in await Tools.Frames.live(tab.web, where: \.signIn) {
            guard let target = spot(entry.info), !shared(for: target, account: account).isEmpty,
                  await has(target, otp: otp, in: tab) else { continue }
            owned.append((entry.number, target))
        }
        if owned.count > 1 {
            let list = owned.map { "f\($0.number) (\($0.target.origin))" }.joined(separator: ", ")
            throw Failure(message: "several embedded frames hold a sign-in with a shared login: \(list) — pass frame to say which")
        }
        return owned.first?.target ?? page
    }

    /// For a refusal: the embedded frames that do hold the boxes, so the
    /// agent knows where the sign-in is and why nothing went there.
    @MainActor
    private static func elsewhere(_ tab: Tab, target: Tab.FormTarget, otp: Bool) async -> String {
        guard target.frame == nil else { return "" }
        var found: [String] = []
        // Only frames whose forms script has seen a sign-in or code box: a page of ad frames costs nothing.
        for entry in await Tools.Frames.live(tab.web, where: \.signIn) {
            guard let framed = spot(entry.info), await has(framed, otp: otp, in: tab) else { continue }
            found.append("f\(entry.number) (\(framed.origin))")
        }
        guard !found.isEmpty else { return "" }
        return ". An embedded frame has the boxes: \(found.joined(separator: ", ")) — the login asked for is not a shared one saved for that address"
    }
}
