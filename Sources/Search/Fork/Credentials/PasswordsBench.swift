import Foundation

/// `bench passwords …` — Copper's own saved passwords in a probe world whose
/// keychain is the file stand-in (`ProbeKeychain`). Every verb but `status`
/// refuses anywhere else, so a script can never read or write a real
/// keychain through it. Secrets are never printed: `check` answers whether a
/// login holds a given password, true or false.
@MainActor
enum PasswordsBench {
    /// The last CSV import's outcome, for `status` after `import`.
    static var lastImport: PasswordCSV.Outcome?

    static func handle(_ request: [String: Any], in browser: Browser) -> [String: Any] {
        let op = request["op"] as? String ?? "status"
        let words = (request["arg"] as? String ?? "").split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if op != "status", !ProbeKeychain.active {
            return ["error": "passwords \(op) only works in a probe world with `defaults write com.collinrijock.copper.test.<world> probe.keychain -string file` set before launch"]
        }
        switch op {
        case "status":
            return [
                "probeKeychain": ProbeKeychain.active,
                "count": ProbeKeychain.active ? Vault.all().count : -1,
                "never": Vault.never.sorted(),
                "panel": browser.managing,
                "proves": ProbeKeychain.proves,
                "lastImport": lastImport.map { ["kept": $0.kept, "skipped": $0.skipped, "codes": $0.codes, "sentence": $0.sentence] as [String: Any] } ?? NSNull(),
            ]
        case "list":
            return ["logins": Vault.all().map { login -> [String: Any] in
                ["host": login.host, "user": login.user, "used": login.used?.timeIntervalSince1970 ?? NSNull()]
            }]
        case "add":
            guard words.count >= 3 else { return ["error": "passwords add HOST USER PASSWORD"] }
            browser.keep(host: words[0], user: words[1] == "-" ? "" : words[1], password: words[2...].joined(separator: " "))
            return ["count": Vault.all().count]
        case "forget":
            guard words.count >= 1 else { return ["error": "passwords forget HOST [USER]"] }
            browser.forget(Login(host: words[0], user: words.count > 1 && words[1] != "-" ? words[1] : "", password: "", used: nil))
            return ["count": Vault.all().count]
        case "check":
            guard words.count >= 3 else { return ["error": "passwords check HOST USER PASSWORD"] }
            let user = words[1] == "-" ? "" : words[1]
            return ["matches": Vault.secret(host: words[0], user: user) == words[2...].joined(separator: " ")]
        case "import":
            guard let path = words.first else { return ["error": "passwords import PATH"] }
            lastImport = nil
            browser.importPasswordsCSV(from: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            return ["started": true]
        case "export":
            guard let path = words.first else { return ["error": "passwords export PATH"] }
            guard ProbeKeychain.proves else { return ["exported": false, "sentence": "Nothing exported"] }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            do {
                let result = try PasswordCSV.export(to: url)
                let mode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int).map { String($0, radix: 8) } ?? "?"
                return ["exported": true, "written": result.written, "refused": result.refused, "mode": mode,
                        "sentence": PasswordCSV.exportSentence(result.written, refused: result.refused, file: url.lastPathComponent)]
            } catch {
                return ["exported": false, "error": error.localizedDescription]
            }
        case "csvcheck":
            guard let path = words.first else { return ["error": "passwords csvcheck PATH"] }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) else { return ["error": "no file"] }
            guard let text = PasswordCSV.text(of: data) else { return ["problem": "not text"] }
            // Counts only — never a value.
            let found = PasswordCSV.summary(text)
            return ["problem": PasswordCSV.problem(with: text) ?? NSNull(), "understood": found.understood,
                    "logins": found.logins, "skipped": found.skipped, "withCodes": found.withCodes, "withNotes": found.withNotes]
        case "prove":
            ProbeKeychain.proves = (words.first ?? "yes") != "no"
            return ["proves": ProbeKeychain.proves]
        case "wipe":
            ProbeKeychain.wipePasswords()
            browser.relist()
            return ["count": 0]
        case "never":
            switch words.first ?? "list" {
            case "offer":
                // The save offer's own "Never here".
                guard browser.offering != nil else { return ["error": "no save offer"] }
                browser.neverOffer()
            case "add":
                // As the save offer's "Never here" keeps it: the page's host, lowercased.
                for host in words.dropFirst() { Vault.never(host.lowercased()) }
            case "forget":
                var never = Vault.never
                for host in words.dropFirst() { never.remove(host) }
                Vault.never = never
            case "clear":
                Vault.never = []
            default: break
            }
            return ["never": Vault.never.sorted()]
        default:
            return ["error": "passwords status|list|add HOST USER PW|forget HOST [USER]|check HOST USER PW|import PATH|export PATH|csvcheck PATH|prove yes|no|wipe|never [offer|add HOST…|forget HOST…|clear]"]
        }
    }
}
