import Foundation

/// The one source-neutral password façade used by the picker, save offer, and
/// agent surfaces. It is main-actor isolated because both Vault and the
/// Bitwarden cache are owned by Copper's UI process.
@MainActor
enum Credentials {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    enum Backend: String {
        case keychain
        case bitwarden
        case onePassword = "onepassword"

        /// What a person calls it, in save offers and announcements.
        var title: String {
            switch self {
            case .keychain: return "Keychain"
            case .bitwarden: return "Bitwarden"
            case .onePassword: return "1Password"
            }
        }

        /// The credential source a save to this backend lands in.
        var source: Credential.Source {
            switch self {
            case .keychain: return .keychain
            case .bitwarden: return .bitwarden
            case .onePassword: return .onePassword
            }
        }
    }

    /// Where a save offer goes: the chosen backend while it is open, the
    /// keychain otherwise.
    static var saveTarget: Backend {
        let chosen = Store.settings.string(forKey: "passwords.backend").flatMap(Backend.init(rawValue:)) ?? .keychain
        switch chosen {
        case .bitwarden where isBitwardenUnlocked: return .bitwarden
        // A 1Password that may create nothing (a read-only service account)
        // can't take a save.
        case .onePassword where isOnePasswordUnlocked && OnePassword.shared.saveVault != nil: return .onePassword
        default: return .keychain
        }
    }

    /// The accounts for a site, best first: the one the page already names
    /// (`hint`), then those kept for this exact host over the site's other
    /// subdomains, then the most recently used, then by name.
    static func candidates(for host: String, hint: String = "") -> [Credential] {
        let all = candidates(for: host)
        let wanted = hint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let exact = host.lowercased().hasPrefix("www.") ? String(host.lowercased().dropFirst(4)) : host.lowercased()
        func rank(_ c: Credential) -> Int {
            var score = 0
            if !wanted.isEmpty, c.user.lowercased() == wanted { score -= 100 }
            let mine = c.host.lowercased().hasPrefix("www.") ? String(c.host.lowercased().dropFirst(4)) : c.host.lowercased()
            if mine == exact { score -= 10 }
            return score
        }
        return all.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    static func candidates(for host: String) -> [Credential] {
        let keychain = Vault.logins(matching: host).map { login in
            Credential(id: .keychain(host: login.host, user: login.user), source: .keychain,
                       host: login.host, user: login.user, sites: [login.host], name: login.user,
                       hasTOTP: false, used: login.used, folder: nil, agentHint: .none)
        }
        var bitwarden: [Credential] = []
        if isBitwardenUnlocked {
            let folders = Dictionary(uniqueKeysWithValues: Bitwarden.shared.cachedFolders.map { ($0.id, $0.name) })
            bitwarden = itemsMatching(host: host).map { credential(for: $0, folders: folders) }
        }
        let onePassword = onePasswordItemsMatching(host: host).map(credential(for:))
        return sorted(deduplicated(keychain + bitwarden + onePassword))
    }

    static func all() -> [Credential] {
        let keychain = Vault.all().map { login in
            Credential(id: .keychain(host: login.host, user: login.user), source: .keychain,
                       host: login.host, user: login.user, sites: [login.host], name: login.user,
                       hasTOTP: false, used: login.used, folder: nil, agentHint: .none)
        }
        var bitwarden: [Credential] = []
        if isBitwardenUnlocked {
            let folders = Dictionary(uniqueKeysWithValues: Bitwarden.shared.cachedFolders.map { ($0.id, $0.name) })
            bitwarden = Bitwarden.shared.cachedItems
                .filter { $0.type == 1 }
                .map { credential(for: $0, folders: folders) }
        }
        let onePassword = isOnePasswordUnlocked
            ? OnePassword.shared.cachedItems.filter(\.isLogin).map(credential(for:))
            : []
        return sorted(deduplicated(keychain + bitwarden + onePassword))
    }

    static func secret(_ id: CredentialID) async throws -> String {
        switch id {
        case .keychain(let host, let user):
            // Read now, for this one account only — the keychain may ask.
            guard let password = Vault.secret(host: host, user: user)
            else { throw Failure(message: "The keychain didn't give up that password") }
            return password
        case .bitwarden(let itemID):
            return try await Bitwarden.shared.password(for: itemID)
        case .onePassword(let itemID):
            return try await OnePassword.shared.password(for: itemID)
        }
    }

    static func totp(_ id: CredentialID) async throws -> String {
        switch id {
        case .keychain:
            throw Failure(message: "Keychain credentials do not have a TOTP code")
        case .bitwarden(let itemID):
            return try await Bitwarden.shared.totp(for: itemID)
        case .onePassword(let itemID):
            return try await OnePassword.shared.totp(for: itemID)
        }
    }

    static func save(host: String, user: String, password: String) async throws {
        switch saveTarget {
        case .keychain:
            guard Vault.save(host: host, user: user, password: password) else {
                throw Failure(message: "Could not save the credential to the keychain")
            }
        case .bitwarden:
            // The same account already kept for this site: change its password
            // there rather than adding a twin.
            if let existing = candidates(for: host).first(where: { $0.source == .bitwarden && $0.user == user }),
               case .bitwarden(let id) = existing.id {
                try await Bitwarden.shared.update(id: id, password: password)
            } else {
                _ = try await Bitwarden.shared.create(host: host, user: user, password: password)
            }
        case .onePassword:
            // The same account already in 1Password for this site: a new
            // password on that item, not a twin.
            if let existing = candidates(for: host).first(where: { $0.source == .onePassword && $0.user == user }),
               case .onePassword(let id) = existing.id {
                try await OnePassword.shared.update(id: id, password: password)
            } else {
                _ = try await OnePassword.shared.create(host: host, user: user, password: password)
            }
        }
    }

    static func touch(_ credential: Credential) {
        guard case .keychain(let host, let user) = credential.id else { return }
        Vault.touch(Login(host: host, user: user, password: "", used: nil))
    }

    // MARK: - Bitwarden metadata and URI matching

    private static var isBitwardenUnlocked: Bool {
        if case .unlocked = Bitwarden.shared.state { return true }
        return false
    }

    private static var isOnePasswordUnlocked: Bool { OnePassword.shared.isUnlocked }

    // MARK: - 1Password metadata

    /// A 1Password login as the picker and agents see it. The vault stands
    /// where Bitwarden's folder does: a vault named `Agents` (or the item's
    /// `copper-agent` tag) shares it with agents; a `copper-agent: deny`
    /// field always keeps it back.
    private static func credential(for item: OnePassword.Item) -> Credential {
        let denied = item.fields.contains {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "copper-agent"
                && $0.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "deny"
        }
        let tagged = item.tags.contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "copper-agent" }
        let hint: Credential.AgentHint
        if denied {
            hint = .deny
        } else if item.vaultName.trimmingCharacters(in: .whitespaces).lowercased() == "agents" || tagged {
            hint = .allow
        } else {
            hint = .none
        }
        let host = item.urls.first.flatMap { uriHost($0) } ?? item.title
        return Credential(id: .onePassword(item.id), source: .onePassword, host: host,
                          user: item.username, sites: item.urls, name: item.title,
                          hasTOTP: item.hasTOTP, used: nil, folder: item.vaultName, agentHint: hint)
    }

    static func onePasswordItemsMatching(host: String) -> [OnePassword.Item] {
        guard isOnePasswordUnlocked else { return [] }
        return OnePassword.shared.cachedItems.filter { item in
            item.isLogin && item.urls.contains { matches(Bitwarden.URI(uri: $0, match: nil), host: host) }
        }
    }

    private static func credential(for item: Bitwarden.Item, folders: [String: String]) -> Credential {
        let folder = item.folderId.flatMap { folders[$0] }
        let lowerFolder = folder?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let denied = item.fields.contains {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "copper-agent"
                && $0.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "deny"
        }
        let hint: Credential.AgentHint
        if denied {
            hint = .deny
        } else if lowerFolder == "agents" {
            hint = .allow
        } else {
            hint = .none
        }
        let host = item.uris.first.flatMap { uriHost($0.uri) } ?? item.name
        return Credential(id: .bitwarden(item.id), source: .bitwarden, host: host,
                          user: item.username, sites: item.uris.map(\.uri), name: item.name,
                          hasTOTP: item.hasTOTP, used: nil, folder: folder, agentHint: hint,
                          hasPasskey: !item.passkeys.isEmpty)
    }

    /// One Bitwarden login as the agent policy sees it — for its passkeys,
    /// which share the login's switch (Fork/Passkeys/BitwardenPasskeys.swift).
    static func credential(bitwarden item: Bitwarden.Item) -> Credential {
        let folders = Dictionary(Bitwarden.shared.cachedFolders.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return credential(for: item, folders: folders)
    }

    static func itemsMatching(host: String) -> [Bitwarden.Item] {
        guard isBitwardenUnlocked else { return [] }
        return Bitwarden.shared.cachedItems.filter { item in
            item.type == 1 && item.uris.contains { matches($0, host: host) }
        }
    }

    static func matches(_ uri: Bitwarden.URI, host: String) -> Bool {
        let target = normalized(host)
        let match = uri.match ?? 0
        if match == 5 { return false }
        if match == 4 {
            let targetURL = canonicalURL(host: target, scheme: scheme(of: uri.uri))
            guard let expression = try? NSRegularExpression(pattern: uri.uri, options: [.caseInsensitive]) else {
                return false
            }
            let range = NSRange(targetURL.startIndex..<targetURL.endIndex, in: targetURL)
            return expression.firstMatch(in: targetURL, options: [], range: range) != nil
        }
        guard let uriHost = uriHost(uri.uri) else { return false }
        let stored = normalized(uriHost)
        switch match {
        case 1:
            return stored == target
        case 2:
            let targetURL = canonicalURL(host: target, scheme: scheme(of: uri.uri))
            return targetURL.lowercased().hasPrefix(uri.uri.lowercased())
        case 3:
            let targetURL = canonicalURL(host: target, scheme: scheme(of: uri.uri))
            return targetURL.caseInsensitiveCompare(uri.uri.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) == .orderedSame
                || (isLocalOrAddress(target) && stored == target)
        default:
            if isLocalOrAddress(target) || isLocalOrAddress(stored) {
                return stored == target
            }
            return Vault.registrable(stored) == Vault.registrable(target)
        }
    }

    private static func uriHost(_ value: String) -> String? {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let candidate = raw.contains("://") ? raw : "https://\(raw)"
        if let host = URL(string: candidate)?.host, !host.isEmpty { return normalized(host) }
        return normalized(raw.split(separator: "/", maxSplits: 1).first.map(String.init) ?? raw)
    }

    private static func normalized(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    private static func scheme(of uri: String) -> String {
        guard let range = uri.range(of: "://") else { return "https" }
        return String(uri[..<range.lowerBound]).lowercased()
    }

    private static func canonicalURL(host: String, scheme: String) -> String {
        "\(scheme)://\(host)"
    }

    private static func isLocalOrAddress(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host.contains(":") { return true }
        let pieces = host.split(separator: ".")
        return pieces.count == 4 && pieces.allSatisfy { Int($0) != nil }
    }

    // MARK: - Ordering and duplicate policy

    private static func deduplicated(_ values: [Credential]) -> [Credential] {
        var result: [Credential] = []
        result.reserveCapacity(values.count)
        // Where each host+user key first landed (settings-perf): the old
        // search rebuilt every earlier row's key for every row — quadratic,
        // and ~185 ms for a vault of 800 logins on each Settings redraw.
        var at: [String: Int] = [:]
        for value in values {
            let key = "\(normalized(value.host))\u{1}\(value.user.lowercased())"
            guard let existing = at[key] else {
                at[key] = result.count
                result.append(value)
                continue
            }
            // A vault's copy wins over the keychain's (it carries a TOTP key,
            // custom fields, the agent policy); the first vault's over the second.
            if value.source != .keychain && result[existing].source == .keychain {
                result[existing] = value
            }
        }
        return result
    }

    private static func sorted(_ values: [Credential]) -> [Credential] {
        values.sorted {
            let left = $0.used ?? .distantPast
            let right = $1.used ?? .distantPast
            if left != right { return left > right }
            let leftName = $0.name.localizedCaseInsensitiveCompare($1.name)
            if leftName != .orderedSame { return leftName == .orderedAscending }
            return $0.user.localizedCaseInsensitiveCompare($1.user) == .orderedAscending
        }
    }
}
