import AppKit
import SwiftUI

/// `./bench op …`: 1Password without the Settings card, for a probe world —
/// the `bw` verbs' twin. Long operations start and return; `op status` says
/// where they got to (`step`, `error`). No answer carries a secret: status is
/// `OnePassword.statusReport()`, rows are usernames and metadata, and an
/// error has anything the caller sent as a secret cut out.
@MainActor
enum OnePasswordBench {
    static var lastStep: String?
    static var lastError: String?

    static func handle(_ request: [String: Any], in browser: Browser) -> [String: Any] {
        let op = request["op"] as? String ?? "status"
        let words = (request["arg"] as? String ?? "").split(separator: " ").map(String.init)
        let vault = OnePassword.shared

        func status() -> [String: Any] {
            var out = vault.statusReport()
            out["backend"] = browser.prefs.passwordsBackend.rawValue
            out["saveTarget"] = Credentials.saveTarget.rawValue
            if let lastStep { out["step"] = lastStep }
            if let lastError { out["lastError"] = lastError }
            return out
        }

        /// Run one long operation; `status` reports how it ended.
        func start(_ name: String, secrets: [String] = [], _ work: @escaping () async throws -> Void) -> [String: Any] {
            lastStep = "\(name):running"
            lastError = nil
            Task { @MainActor in
                do {
                    try await work()
                    lastStep = "\(name):ok"
                } catch {
                    lastStep = "\(name):failed"
                    lastError = scrub(error.localizedDescription, secrets)
                }
            }
            return ["started": true, "op": name]
        }

        switch op {
        case "status", "problem":
            return status()
        case "accounts":
            return start("accounts") { await vault.refreshAccounts() }
        case "signin":
            // op signin app [ACCOUNT] | password [--account A] PW… | token TOKEN
            // A password is the rest of the line, spaces and all.
            guard let how = words.first else { return ["error": "op signin app [ACCOUNT]|password [--account A] PW|token TOKEN"] }
            switch how {
            case "app":
                let account = words.count > 1 ? words[1] : nil
                return start("signin-app") { try await vault.unlockWithApp(account: account) }
            case "password":
                var rest = Array(words.dropFirst())
                var account: String?
                if rest.count >= 2, rest[0] == "--account" { account = rest[1]; rest.removeFirst(2) }
                guard !rest.isEmpty else { return ["error": "op signin password [--account A] PW"] }
                let password = rest.joined(separator: " ")
                return start("signin-password", secrets: [password]) { try await vault.signIn(password: password, account: account) }
            case "token":
                guard words.count == 2 else { return ["error": "op signin token TOKEN"] }
                let token = words[1]
                return start("signin-token", secrets: [token]) { try await vault.connect(serviceToken: token) }
            default:
                return ["error": "op signin app|password|token"]
            }
        case "account":
            // op account add ADDRESS EMAIL SECRETKEY PW…
            guard words.count >= 5, words[0] == "add" else { return ["error": "op account add ADDRESS EMAIL SECRETKEY PW"] }
            let (address, email, key) = (words[1], words[2], words[3])
            let password = words[4...].joined(separator: " ")
            return start("account-add", secrets: [key, password]) {
                try await vault.addAccount(address: address, email: email, secretKey: key, password: password)
            }
        case "unlock":
            let password = words.isEmpty ? nil : words.joined(separator: " ")
            return start("unlock", secrets: password.map { [$0] } ?? []) { try await vault.unlock(password: password) }
        case "lock":
            return start("lock") { await vault.lock() }
        case "signout":
            return start("signout") { await vault.signOut() }
        case "sync":
            return start("sync") { try await vault.sync() }
        case "keepalive":
            // The four-minute `op whoami`, now.
            return start("keepalive") { await vault.keepAlive() }
        case "stay":
            guard let value = words.first else { return ["stayUnlocked": vault.stayUnlocked] }
            vault.stayUnlocked = ["on", "true", "1", "yes"].contains(value)
            return ["stayUnlocked": vault.stayUnlocked]
        case "vault":
            guard !words.isEmpty else { return ["saveVault": vault.saveVault?.name ?? NSNull()] }
            let name = words.joined(separator: " ")
            let pool = vault.writableVaults
            guard let chosen = pool.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id == name }) else {
                return ["error": "no writable vault \(name)", "vaults": pool.map(\.name)]
            }
            vault.setSaveVault(chosen)
            return ["saveVault": chosen.name]
        case "backend":
            guard let value = words.first, let backend = Credentials.Backend(rawValue: value) else {
                return ["error": "op backend keychain|bitwarden|onepassword"]
            }
            browser.prefs.passwordsBackend = backend
            return ["backend": backend.rawValue, "saveTarget": Credentials.saveTarget.rawValue]
        case "settings":
            guard words.first == "passwords" else { return ["error": "op settings passwords"] }
            browser.tuning = false
            browser.settingsPage = .passwords
            Store.settings.set(SettingsPanel.Page.passwords.rawValue, forKey: "settings.page")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { browser.tuning = true }
            return ["started": true, "page": browser.settingsPage.rawValue]
        case "candidates":
            guard let host = words.first else { return ["error": "op candidates HOST"] }
            return ["candidates": Credentials.candidates(for: host).map {
                ["id": $0.id.string, "user": $0.user, "host": $0.host, "source": "\($0.source)",
                 "vault": $0.folder ?? "", "totp": $0.hasTOTP, "agent": AgentAccess.isAllowed($0)]
            }]
        case "choose":
            guard let id = words.first else { return ["error": "op choose ID"] }
            guard let tab = browser.active, let host = tab.address?.host() else { return ["error": "no active page"] }
            guard let credential = Credentials.candidates(for: host).first(where: { $0.id.string == id }) else {
                return ["error": "no credential \(id) for \(host)"]
            }
            browser.choose(credential)
            return ["started": true, "id": id]
        case "rows":
            return ["rows": (browser.suggesting?.rows ?? []).map(\.id), "pending": Browser.vaultPending,
                    "footer": browser.suggesting.map(PickerFooter.text(for:)) ?? NSNull()]
        case "pick":
            guard let id = words.first else { return ["error": "op pick ROW"] }
            guard let row = browser.suggesting?.rows.first(where: { $0.id == id }) else { return ["error": "no row \(id) in the list"] }
            browser.choose(row)
            return ["started": true, "id": id]
        case "offer":
            switch words.first ?? "status" {
            case "keep":
                guard browser.offering != nil else { return ["error": "no save offer"] }
                browser.keepOffer()
                return ["started": true]
            case "drop":
                browser.dropOffer()
                return ["dropped": true]
            default:
                guard let offer = browser.offering else { return ["offer": NSNull()] }
                return ["offer": ["host": offer.login.host, "user": offer.login.user, "changed": offer.changed, "target": offer.target.rawValue]]
            }
        case "identities":
            return ["identities": Autofill.identities.map {
                ["id": $0.id, "name": $0.name, "fullName": $0.fullName, "summary": $0.summary, "agent": Autofill.isAllowed($0.id)]
            }]
        case "cards":
            return ["cards": Autofill.cards.map {
                ["id": $0.id, "name": $0.name, "label": $0.label, "holder": $0.cardholderName, "agent": Autofill.isAllowed($0.id)]
            }]
        case "fields":
            guard let host = words.first else { return ["error": "op fields HOST"] }
            return ["fields": Autofill.fields(for: host).map { ["item": $0.itemName, "id": $0.itemID, "name": $0.name, "hidden": $0.hidden] }]
        case "usernames":
            return ["usernames": Autofill.topUsernames]
        case "counts":
            let counts = vault.counts
            return ["counts": ["logins": counts.logins, "identities": counts.identities, "cards": counts.cards],
                    "items": vault.cachedItems.count, "detailed": vault.cachedItems.count(where: \.detailed)]
        case "autofill":
            guard words.count == 2, let tab = browser.active else {
                return ["error": "op autofill card|identity ID (requires an active page)"]
            }
            let kind = words[0].lowercased()
            let id = words[1].hasPrefix("op:") ? words[1] : "op:\(words[1])"
            if kind == "card", let card = Autofill.cards.first(where: { $0.id == id }) {
                tab.fillValues(card.values())
                return ["started": true, "kind": kind, "id": card.id]
            }
            if kind == "identity", let identity = Autofill.identities.first(where: { $0.id == id }) {
                tab.fillValues(identity.values())
                return ["started": true, "kind": kind, "id": identity.id]
            }
            return ["error": "no \(kind) \(words[1])"]
        case "share":
            guard words.count == 2 else { return ["error": "op share all|ID on|off"] }
            let on = ["on", "true", "1", "yes"].contains(words[1])
            if words[0] == "all" { AgentAccess.shareAll = on; return ["shareAll": on] }
            let stable = words[0].hasPrefix("op:") ? words[0] : "op:\(words[0])"
            if let credential = Credentials.all().first(where: { $0.id.string == stable }) {
                AgentAccess.set(credential, allowed: on)
                return ["id": credential.id.string, "agent": AgentAccess.isAllowed(credential)]
            }
            if Autofill.identities.contains(where: { $0.id == stable }) || Autofill.cards.contains(where: { $0.id == stable }) {
                var ids = AgentAccess.allowed
                if on { ids.insert(stable) } else { ids.remove(stable) }
                AgentAccess.allowed = ids
                return ["id": stable, "agent": Autofill.isAllowed(stable)]
            }
            return ["error": "no 1Password item \(words[0])"]
        default:
            return ["error": "unknown op operation \(op)"]
        }
    }

    private static func scrub(_ text: String, _ secrets: [String]) -> String {
        var value = text
        for secret in secrets where secret.count >= 3 {
            value = value.replacingOccurrences(of: secret, with: "•••")
        }
        return String(value.prefix(200))
    }

    // MARK: - Pictures

    /// `render onepassword[-app|-password|-service] PATH` and `render picker
    /// PATH [HOST]` — the card in its current state (or the sign-in on one
    /// path), and the account picker as it would hang under HOST's sign-in box.
    static func view(_ which: String, host: String?, in browser: Browser) -> AnyView? {
        /// As Settings draws it: its greys, its row metrics, its width.
        func settings<V: View>(_ card: V) -> AnyView {
            AnyView(card.frame(width: 600).padding(16).background(SettingsInk.content)
                .environment(\.settingsLook, true))
        }
        switch which {
        case "onepassword", "onepassword-dark":
            return settings(OnePasswordCard(browser: browser))
        case "onepassword-app", "onepassword-password", "onepassword-service":
            let path = OnePassword.Mode(rawValue: String(which.dropFirst("onepassword-".count)))
            return settings(OnePasswordCard(browser: browser, path: path))
        case "managers", "managers-dark":
            // Settings › Passwords › Password managers, the whole section.
            return settings(VStack(alignment: .leading, spacing: 8) {
                SettingsSectionTitle("Password managers")
                VStack(alignment: .leading, spacing: 12) {
                    SaveTargetCard(browser: browser)
                    BitwardenCard(browser: browser)
                    OnePasswordCard(browser: browser)
                }
            })
        case "picker-live":
            // The list hanging from the box the caret is in right now.
            guard let asked = browser.suggesting else { return nil }
            return AnyView(AccountList(browser: browser, asked: Browser.Suggesting(
                tab: asked.tab, spot: CGRect(x: 0, y: 0, width: max(320, asked.spot.width), height: 0),
                credentials: asked.credentials, rows: asked.rows))
                .padding(EdgeInsets(top: 18, leading: 28, bottom: 40, trailing: 28))
                .background(Palette.wash))
        case "picker":
            let site = host ?? "localhost"
            let credentials = Credentials.candidates(for: site)
            let asked = Browser.Suggesting(tab: UUID(), spot: CGRect(x: 0, y: 0, width: 320, height: 0),
                                           credentials: credentials, rows: credentials.map(Browser.Suggestion.credential))
            return AnyView(AccountList(browser: browser, asked: asked)
                .padding(EdgeInsets(top: 18, leading: 28, bottom: 40, trailing: 28))
                .background(Palette.wash))
        default:
            return nil
        }
    }
}
