import Foundation

/// The part a password box plays on a form that makes a new password, as the
/// page classifier reads it (`Forms.swift` `passwordRoles`).
enum PasswordRole: String, Equatable {
    /// The password you have now, on a change form.
    case current
    case new
    /// The new one again.
    case confirm

    var makesPassword: Bool { self == .new || self == .confirm }
}

/// What the page says about its new-password form: whose account it is, the
/// rules a new password must keep, and whether there is a current-password
/// box still waiting to be filled. Never a password.
struct NewPasswordPage {
    let user: String
    let rules: PasswordRules
    let hasCurrent: Bool
    let currentEmpty: Bool

    init?(_ object: Any?) {
        guard let body = object as? [String: Any], body["found"] as? Bool == true else { return nil }
        user = (body["user"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        rules = PasswordRules(
            passwordrules: body["rules"] as? String ?? "",
            minLength: (body["minLength"] as? NSNumber)?.intValue,
            maxLength: (body["maxLength"] as? NSNumber)?.intValue
        )
        hasCurrent = body["current"] as? Bool ?? false
        currentEmpty = body["currentEmpty"] as? Bool ?? false
    }
}

/// Fork (new-password): a strong password made, kept and only then put in the
/// page — Safari's "Use Strong Password" for any backend. Saved first so that
/// a save that fails leaves the page untouched and the account still on its
/// old password; a change that the site then refuses is recoverable, because
/// Bitwarden and 1Password keep the replaced password in the item's history.
@MainActor
enum NewPassword {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Made {
        let password: String
        /// The password the page's current box should get, read before the
        /// save replaced it; nil when there is no box to fill or no match.
        let current: String?
        let host: String
        let user: String
        let target: Credentials.Backend
        /// An existing login whose password was replaced, not a new one.
        let updated: Bool
        /// The keychain keeps no history, so a change there waits for the
        /// page to accept it (the save offer after submit).
        let deferred: Bool

        /// The confirmation, which names the account and never the password.
        var sentence: String {
            let who = user.isEmpty ? host : "\(user) on \(host)"
            if deferred {
                return "Strong password filled for \(who) — Copper offers to update the keychain once the site takes it"
            }
            if updated {
                let history = target == .keychain ? "" : " (the old one is in its password history)"
                return "Strong password saved to \(target.title) for \(who)\(history)"
            }
            return "Strong password saved to \(target.title) for \(who)"
        }
    }

    /// Under the row in the picker: where it goes, said before it goes.
    static func rowSubtitle(length: Int) -> String {
        "\(length) characters · saved to \(Credentials.saveTarget.title), then filled"
    }

    /// The saved login the new password belongs to: the account the page
    /// names, else the one picked into this tab, else the only one kept for
    /// the site. Nil means a new login.
    static func account(host: String, named: String, target: Credentials.Backend,
                        pickedHere: Credential?) -> (user: String, existing: Credential?) {
        let kept = Credentials.candidates(for: host).filter { $0.source == target.source }
        let named = named.trimmingCharacters(in: .whitespacesAndNewlines)
        if !named.isEmpty {
            let same = kept.first { $0.user == named }
                ?? kept.first { $0.user.caseInsensitiveCompare(named) == .orderedSame }
            return (same?.user ?? named, same)
        }
        if let pickedHere, let same = kept.first(where: { $0.id == pickedHere.id || $0.user == pickedHere.user }) {
            return (same.user, same)
        }
        if kept.count == 1, let only = kept.first { return (only.user, only) }
        return ("", nil)
    }

    /// Makes the password and saves it; the caller fills the page with what
    /// comes back. `avoiding` is what the password must not contain.
    static func make(host: String, page: NewPasswordPage, pickedHere: Credential? = nil) async throws -> Made {
        let target = Credentials.saveTarget
        let (user, existing) = account(host: host, named: page.user, target: target, pickedHere: pickedHere)
        let password = StrongPassword.generate(rules: page.rules, avoiding: [user, user.split(separator: "@").first.map(String.init) ?? ""])

        // The current password is read before the save replaces it.
        var current: String?
        if page.hasCurrent, page.currentEmpty, let existing {
            current = try? await Credentials.secret(existing.id)
        }
        if target == .keychain, existing != nil {
            return Made(password: password, current: current, host: host, user: user,
                        target: target, updated: true, deferred: true)
        }
        do {
            try await Credentials.save(host: host, user: user, password: password)
        } catch {
            throw Failure(message: "Couldn't save to \(target.title), so nothing was filled — \(error.localizedDescription)")
        }
        return Made(password: password, current: current, host: host, user: user,
                    target: target, updated: existing != nil, deferred: false)
    }
}
