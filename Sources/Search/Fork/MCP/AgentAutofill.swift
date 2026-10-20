import Foundation

/// Fill a shared Bitwarden or 1Password card, identity, or custom field
/// without returning its value — or make, save and fill a new password
/// (`kind=new-password`) without ever returning it.
enum AgentAutofill {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    static func run(_ args: [String: Any], in browser: Browser, source: Source) async throws -> [String: Any] {
        guard let tab = AgentTabs.target(in: browser) else { throw Failure(message: "no active tab") }
        AgentTabs.prepare(tab)
        guard !tab.shy else { throw Failure(message: "autofill is unavailable in private tabs") }
        guard let address = tab.address, let rawHost = address.host(), !rawHost.isEmpty else {
            throw Failure(message: "current tab has no host")
        }
        var host = rawHost.lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        // Fork (new-password): needs no open vault — a locked one sends the
        // save to the keychain, as the picker's row does.
        if let raw = args["kind"] as? String,
           ["new-password", "new_password", "newpassword"].contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            return try await newPassword(args, tab: tab, host: host, in: browser)
        }
        var bitwardenOpen = false
        if case .unlocked = Bitwarden.shared.state { bitwardenOpen = true }
        guard bitwardenOpen || OnePassword.shared.isUnlocked else {
            if OnePassword.shared.isLocked, Bitwarden.shared.state == .unauthenticated || Bitwarden.shared.state == .missing {
                throw Failure(message: "1password is locked — unlock it in Settings › Passwords")
            }
            throw Failure(message: "bitwarden is locked — unlock it in Settings › Passwords")
        }

        guard let rawKind = args["kind"] as? String else {
            throw Failure(message: "kind is required (card, identity, field, or new-password)")
        }
        let kind = rawKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["card", "identity", "field"].contains(kind) else {
            throw Failure(message: "kind must be card, identity, field, or new-password")
        }
        let shouldSubmit = (args["submit"] as? Bool) ?? false
        let first = (args["first"] as? Bool) ?? false
        let requestedName = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = requestedName.flatMap { $0.isEmpty ? nil : $0 }

        switch kind {
        case "card":
            let all = Autofill.cards
            let permitted = all.filter { Autofill.isAllowed($0.id) }
            guard !permitted.isEmpty else {
                if !all.isEmpty {
                    throw Failure(message: "card exists but is not shared with agents — enable it in Settings › Passwords › Agent access")
                }
                throw Failure(message: "no saved card")
            }
            let matches: [AutofillCard]
            if let name {
                matches = permitted.filter { card in
                    [card.name, card.label, card.last4, card.cardholderName].contains {
                        $0.caseInsensitiveCompare(name) == .orderedSame
                    }
                }
                guard !matches.isEmpty else {
                    throw Failure(message: "no shared card named \(name); saved: \(permitted.map(\.name).joined(separator: ", "))")
                }
            } else {
                matches = permitted
            }
            guard first || matches.count == 1 else {
                return ["candidates": matches.map(\.name), "kind": kind]
            }
            guard let card = matches.first else { throw Failure(message: "no saved card") }
            guard await tab.hasFields(.card) else { throw Failure(message: "no card fields on the page") }
            let filled = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
                tab.fillValues(card.values()) { count in continuation.resume(returning: count) }
            }
            // The boxes were there but already held values: nothing was
            // overwritten, and that is a result, not a failure.
            let submitted = shouldSubmit ? await submit(tab) : false
            var result: [String: Any] = ["filled": filled, "kind": kind, "name": card.name, "submitted": submitted,
                                         "source": Autofill.source(of: card.id) == .onePassword ? "onepassword" : "bitwarden"]
            if filled == 0 { result["note"] = "the card fields already hold values; nothing overwritten" }
            return result

        case "identity":
            let all = Autofill.identities
            let permitted = all.filter { Autofill.isAllowed($0.id) }
            guard !permitted.isEmpty else {
                if !all.isEmpty {
                    throw Failure(message: "identity exists but is not shared with agents — enable it in Settings › Passwords › Agent access")
                }
                throw Failure(message: "no saved identity")
            }
            let matches: [AutofillIdentity]
            if let name {
                matches = permitted.filter { identity in
                    [identity.name, identity.fullName, identity.email].contains {
                        $0.caseInsensitiveCompare(name) == .orderedSame
                    }
                }
                guard !matches.isEmpty else {
                    throw Failure(message: "no shared identity named \(name); saved: \(permitted.map(\.name).joined(separator: ", "))")
                }
            } else {
                matches = permitted
            }
            guard first || matches.count == 1 else {
                return ["candidates": matches.map(\.name), "kind": kind]
            }
            guard let identity = matches.first else { throw Failure(message: "no saved identity") }
            guard await tab.hasFields(.identity) else { throw Failure(message: "no identity fields on the page") }
            let filled = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
                tab.fillValues(identity.values()) { count in continuation.resume(returning: count) }
            }
            let submitted = shouldSubmit ? await submit(tab) : false
            var result: [String: Any] = ["filled": filled, "kind": kind, "name": identity.name, "submitted": submitted,
                                         "source": Autofill.source(of: identity.id) == .onePassword ? "onepassword" : "bitwarden"]
            if filled == 0 { result["note"] = "the identity fields already hold values; nothing overwritten" }
            return result

        case "field":
            guard let name else { throw Failure(message: "name is required for field") }
            let all = Autofill.fields(for: host, matching: name)
            guard let field = all.first(where: { Autofill.isAllowed($0.itemID) }) else {
                if !all.isEmpty {
                    throw Failure(message: "field exists but is not shared with agents — enable it in Settings › Passwords › Agent access")
                }
                throw Failure(message: "no saved field named \(name)")
            }
            let filled = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                tab.fillField(label: name, value: field.value) { ok in continuation.resume(returning: ok) }
            }
            if !filled {
                let focused = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    tab.fillFocused(field.value) { ok in continuation.resume(returning: ok) }
                }
                guard focused else { throw Failure(message: "no field named \(name) on the page") }
            }
            return ["filled": 1, "kind": kind, "name": field.name, "item": field.itemName]

        default:
            throw Failure(message: "kind must be card, identity, or field")
        }
    }

    /// A strong password for the page's sign-up or change form: made, saved
    /// (first, so a failed save fills nothing), filled into the new and
    /// confirm boxes and an empty current box. The answer says whose it is,
    /// where it went and how long it is — never the password. An existing
    /// login's password changes only when that login is shared with agents.
    @MainActor
    private static func newPassword(_ args: [String: Any], tab: Tab, host: String, in browser: Browser) async throws -> [String: Any] {
        let save = (args["save"] as? Bool) ?? true
        let shouldSubmit = (args["submit"] as? Bool) ?? false
        let named = (args["account"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard save || !shouldSubmit else {
            throw Failure(message: "submit needs save: a new password nobody kept would lock the account")
        }
        guard let page = await tab.newPasswordPage() else {
            throw Failure(message: "no new-password form on the page (sign-up or change-password)")
        }
        let target = Credentials.saveTarget
        let account = NewPassword.account(host: host, named: named.flatMap { $0.isEmpty ? nil : $0 } ?? page.user,
                                          target: target, pickedHere: browser.pickedCredential(in: tab))
        if let existing = account.existing, !AgentAccess.isAllowed(existing) {
            throw Failure(message: "the saved login \(existing.user.isEmpty ? host : existing.user) is not shared with agents — enable it in Settings › Passwords › Agent access")
        }
        let (made, filled) = try await browser.makeNewPassword(
            in: tab, host: host, page: page, named: account.user, save: save)
        let submitted = shouldSubmit ? await submit(tab) : false
        return [
            "kind": "new-password", "filled": filled, "saved": !made.deferred, "target": made.target.rawValue,
            "user": made.user, "updated": made.updated, "current": made.current != nil,
            "length": made.password.count, "submitted": submitted, "note": made.sentence,
        ]
    }

    @MainActor
    private static func submit(_ tab: Tab) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            tab.submitSignIn { ok in continuation.resume(returning: ok) }
        }
    }
}
