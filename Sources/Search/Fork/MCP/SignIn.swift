import Foundation

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
        guard let tab = AgentTabs.target(in: browser) else { throw Failure(message: "no active tab") }
        AgentTabs.prepare(tab)
        guard !tab.shy else { throw Failure(message: "sign-in is unavailable in private tabs") }
        guard let address = tab.address, let rawHost = address.host(), !rawHost.isEmpty else {
            throw Failure(message: "current tab has no host")
        }
        var host = rawHost.lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let what = ((args["what"] as? String) ?? "password").lowercased()
        let account = (args["account"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if what == "passkey" { return try passkey(account: account, tab: tab, host: host) }

        let all = Credentials.candidates(for: host)
        let permitted = AgentAccess.permitted(for: host)
        guard !permitted.isEmpty else {
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
            throw Failure(message: "no saved credential for \(host)")
        }

        let selected: Credential?
        if let account, !account.isEmpty {
            selected = permitted.first(where: { $0.user == account })
                ?? permitted.first(where: { $0.user.caseInsensitiveCompare(account) == .orderedSame })
            if selected == nil {
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

        guard what == "password" || what == "otp" else {
            throw Failure(message: "what must be password, otp or passkey")
        }
        let submit = (args["submit"] as? Bool) ?? true

        switch what {
        case "password":
            // The field first, the secret second: a page with nothing to fill
            // never causes a read from the vault.
            guard await tab.hasPasswordField() else {
                // A passkey-only sign-in page has no password box to fill.
                if !BitwardenPasskeys.usable(on: host).filter(BitwardenPasskeys.sharedWithAgents).isEmpty {
                    throw Failure(message: "sign-in fields not found on the page; a shared Bitwarden passkey exists — call with what=passkey, then click the site's passkey button")
                }
                throw Failure(message: "sign-in fields not found on the page")
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
                tab.fill(user: credential.user, password: secret) { ok in
                    continuation.resume(returning: ok)
                }
            }
            guard filled else { throw Failure(message: "sign-in fields not found on the page") }
            let submitted: Bool
            if submit {
                submitted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    tab.submitSignIn { ok in continuation.resume(returning: ok) }
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
            guard await tab.hasOTPField() else { throw Failure(message: "no one-time-code field on the page") }
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
                tab.fillOTP(code) { ok in continuation.resume(returning: ok) }
            }
            guard filled else { throw Failure(message: "no one-time-code field on the page") }
            let submitted: Bool
            if submit {
                submitted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    tab.submitSignIn { ok in continuation.resume(returning: ok) }
                }
            } else {
                submitted = false
            }
            return ["filled": true, "account": credential.user, "what": "otp", "submitted": submitted]
        default:
            throw Failure(message: "what must be password, otp or passkey")
        }
    }

    /// what=passkey: arm the tab so the site's next WebAuthn sign-in signs
    /// with this shared Bitwarden passkey, in-process and with no prompt
    /// (Passkeys.grant). Nothing is filled here and nothing secret is read:
    /// the key is read from the vault only when the site asks, and never
    /// leaves Copper. The agent then clicks the site's passkey button.
    @MainActor
    private static func passkey(account: String?, tab: Tab, host: String) throws -> [String: Any] {
        let all = BitwardenPasskeys.usable(on: host)
        let permitted = all.filter(BitwardenPasskeys.sharedWithAgents)
        guard !permitted.isEmpty else {
            if !all.isEmpty {
                throw Failure(message: "passkey for \(host) exists but is not shared with agents — enable it in Settings › Passwords › Agent access")
            }
            if case .unlocked = Bitwarden.shared.state {} else {
                throw Failure(message: "no passkey for \(host) while Bitwarden is locked — unlock it in Settings › Passwords")
            }
            throw Failure(message: "no saved Bitwarden passkey for \(host)")
        }
        func named(_ match: BitwardenPasskeys.Match, _ name: String) -> Bool {
            [match.passkey.userName, match.item.username, match.label].contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        let chosen: [BitwardenPasskeys.Match]
        if let account, !account.isEmpty {
            chosen = permitted.filter { named($0, account) }
            if chosen.isEmpty, all.contains(where: { named($0, account) }) {
                throw Failure(message: "passkey for \(account) on \(host) exists but is not shared with agents — enable it in Settings › Passwords › Agent access")
            }
            if chosen.isEmpty {
                throw Failure(message: "no shared passkey named \(account) for \(host); saved: \(permitted.map(\.label).joined(separator: ", "))")
            }
        } else if permitted.count == 1 {
            chosen = permitted
        } else {
            return ["candidates": permitted.map(\.label), "host": host, "what": "passkey"]
        }
        // Bound to the page showing now: a request from another origin, or a
        // frame inside it, is not the one the agent armed for.
        guard let origin = Passkeys.origin(of: tab.address) else {
            throw Failure(message: "the tab has no page to sign in to")
        }
        Passkeys.grant(chosen, tab: tab.id, origin: origin)
        return ["armed": true, "what": "passkey", "account": chosen[0].label, "host": host, "source": "bitwarden",
                "next": "click the site's passkey sign-in button within 60 s; Copper signs that request in-process"]
    }
}
