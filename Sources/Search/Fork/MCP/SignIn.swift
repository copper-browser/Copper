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
        guard let tab = AgentTabs.target(in: browser) else { throw Failure(message: AgentTabs.missing()) }
        AgentTabs.prepare(tab)
        guard !tab.shy else { throw Failure(message: "sign-in is unavailable in private tabs") }
        // Fork (form-target): the account is the site's whose box has the
        // caret — an embedded frame's when one has it — and the secret goes
        // into that frame only. Picking by the page's host and filling the
        // frame would hand the page's password to any frame that claims focus.
        guard let target = tab.formTarget else { throw Failure(message: "current tab has no host") }
        let host = target.host
        let framed = target.frame == nil ? "" : " (the box with the caret is in an embedded frame from \(host); click the sign-in box you mean first)"

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
            throw Failure(message: "no saved credential for \(host)\(framed)")
        }

        let account = (args["account"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
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

        let what = ((args["what"] as? String) ?? "password").lowercased()
        guard what == "password" || what == "otp" else {
            throw Failure(message: "what must be password or otp")
        }
        let submit = (args["submit"] as? Bool) ?? true

        switch what {
        case "password":
            // The field first, the secret second: a page with nothing to fill
            // never causes a read from the vault.
            guard await tab.hasPasswordField(at: target) else { throw Failure(message: "sign-in fields not found on the page") }
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
            guard await tab.hasOTPField(at: target) else { throw Failure(message: "no one-time-code field on the page") }
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
}
