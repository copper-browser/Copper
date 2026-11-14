import Foundation

// `copper bitwarden save -|note -` and the `browser_vault_save` /
// `browser_vault_note` tools: an agent keeps a login it was given (a password
// from a text message, a two-step seed) or a secure note (backup codes) in the
// Bitwarden vault Copper has open. The values come in as JSON — stdin for the
// CLI, never argv — and never go back out: the answer is
// {ok, id, created, updated, name, folder}, or {ok:false, error} with every
// value the caller sent cut out of the line.
//
// With agent access set to `folder`, a new item lands in the Agents folder,
// so `copper signin` can use it at once; with `all`, where it was asked to
// (or no folder). A saved item changes only when it is shared with agents —
// an agent can add to the vault, never overwrite what the user kept back.

extension Bitwarden {
    struct LoginDraft: Equatable {
        let name: String
        let host: String
        let uri: String
        let username: String
        let password: String
        let totp: String?
        let notes: String?
        let folder: String?
    }

    struct NoteDraft: Equatable {
        let name: String
        let text: String
        let folder: String?
    }

    /// Bitwarden refuses a note longer than this.
    nonisolated static let noteLimit = 10_000

    /// `op` save | note. Never throws and never returns a value it was given.
    func vaultWrite(_ op: String, _ p: [String: Any]) async -> [String: Any] {
        var secrets = ["password", "totp", "notes", "text"].compactMap { p[$0] as? String }
        secrets += (p["totp"] as? String).flatMap(Self.normalizedTOTP).map { [$0] } ?? []
        // A bw message could quote one line of a note: every line counts.
        secrets += ((p["text"] as? String) ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 4 }
        do {
            return op == "note" ? try await saveNote(p) : try await saveLogin(p)
        } catch {
            let raw = (error as? Failure)?.message ?? error.localizedDescription
            return ["ok": false, "error": Self.sanitize(raw, hiding: secrets.filter { !$0.isEmpty })]
        }
    }

    private func saveLogin(_ p: [String: Any]) async throws -> [String: Any] {
        let draft = try Self.loginDraft(p)
        let items = try await self.items()
        _ = try await folders()
        if let existing = Self.existingLogin(in: items, host: draft.host, username: draft.username) {
            try requireShared(existing, "a login for \(draft.username) on \(draft.host)")
            var object = try await rawItem(id: existing.id)
            var login = object["login"] as? [String: Any] ?? [:]
            login["password"] = draft.password
            if let totp = draft.totp { login["totp"] = totp }
            object["login"] = login
            if let notes = draft.notes { object["notes"] = notes }
            let id = try await write(object, id: existing.id)
            await refreshCacheIfPossible()
            return answer(id: id, created: false, name: existing.name, folderID: existing.folderId)
        }
        let folder = try await target(draft.folder)
        var object = try await itemTemplate()
        object["type"] = 1
        object["name"] = draft.name
        object["folderId"] = folder?.id ?? NSNull()
        object["notes"] = draft.notes ?? NSNull()
        object["login"] = [
            "username": draft.username,
            "password": draft.password,
            "totp": draft.totp ?? NSNull(),
            "uris": [["uri": draft.uri, "match": NSNull()]],
        ] as [String: Any]
        let id = try await write(object)
        await refreshCacheIfPossible()
        return answer(id: id, created: true, name: draft.name, folderID: folder?.id)
    }

    private func saveNote(_ p: [String: Any]) async throws -> [String: Any] {
        let draft = try Self.noteDraft(p)
        let items = try await self.items()
        _ = try await folders()
        if let existing = items.first(where: { $0.type == 2 && $0.name == draft.name }) {
            try requireShared(existing, "a note named \(draft.name)")
            var object = try await rawItem(id: existing.id)
            object["notes"] = draft.text
            let id = try await write(object, id: existing.id)
            await refreshCacheIfPossible()
            return answer(id: id, created: false, name: existing.name, folderID: existing.folderId)
        }
        let folder = try await target(draft.folder)
        var object = try await itemTemplate()
        object["type"] = 2
        object["name"] = draft.name
        object["folderId"] = folder?.id ?? NSNull()
        object["notes"] = draft.text
        object["secureNote"] = ["type": 0]
        let id = try await write(object)
        await refreshCacheIfPossible()
        return answer(id: id, created: true, name: draft.name, folderID: folder?.id)
    }

    /// The folder a new item goes to: the one named, else the Agents folder
    /// while agents see only that one.
    private func target(_ named: String?) async throws -> Folder? {
        if let named { return try await folder(named: named) }
        return AgentAccess.shareAll ? nil : try await folder(named: "Agents")
    }

    private func requireShared(_ item: Item, _ what: String) throws {
        let folder = item.folderId.flatMap { id in cachedFolders.first { $0.id == id }?.name }
        guard Self.agentMayChange(item, folder: folder, shareAll: AgentAccess.shareAll, allowed: AgentAccess.allowed) else {
            throw Failure(message: "\(what) is already saved and not shared with agents — share it in Settings › Passwords › Agent access, or ask the user to change it")
        }
    }

    private func answer(id: String, created: Bool, name: String, folderID: String?) -> [String: Any] {
        let folder = folderID.flatMap { id in cachedFolders.first { $0.id == id }?.name }
        return ["ok": true, "id": id, "created": created, "updated": !created, "name": name,
                "folder": folder.map { $0 as Any } ?? NSNull()]
    }

    // MARK: - The pure parts (BitwardenSaveTests)

    /// {name?, url | host, username, password, totp?, notes?, folder?}. The
    /// password and notes are kept as typed; everything else trimmed.
    nonisolated static func loginDraft(_ p: [String: Any]) throws -> LoginDraft {
        guard let raw = text(p["url"]) ?? text(p["host"]) else {
            throw Failure(message: "url (or host) is required: the site the login is for")
        }
        guard let site = site(raw) else { throw Failure(message: "url must be a web address (https://example.com)") }
        guard let username = text(p["username"]) else { throw Failure(message: "username is required") }
        guard let password = p["password"] as? String, !password.isEmpty else { throw Failure(message: "password is required") }
        var totp: String?
        if let seed = text(p["totp"]) {
            guard let valid = normalizedTOTP(seed) else {
                throw Failure(message: "totp must be an otpauth://totp/ URI or a base32 secret")
            }
            totp = valid
        }
        let notes = (p["notes"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let notes, notes.count > noteLimit { throw Failure(message: "notes are longer than \(noteLimit) characters") }
        let www = site.host.hasPrefix("www.") ? String(site.host.dropFirst(4)) : site.host
        return LoginDraft(name: text(p["name"]) ?? www, host: site.host, uri: site.uri, username: username,
                          password: password, totp: totp, notes: notes, folder: text(p["folder"]))
    }

    /// {name, text, folder?}; the text as typed.
    nonisolated static func noteDraft(_ p: [String: Any]) throws -> NoteDraft {
        guard let name = text(p["name"]) else { throw Failure(message: "name is required") }
        guard let body = p["text"] as? String, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "text is required")
        }
        guard body.count <= noteLimit else { throw Failure(message: "text is longer than \(noteLimit) characters") }
        return NoteDraft(name: name, text: body, folder: text(p["folder"]))
    }

    /// The site from a URL or a bare host: lowercased host, and
    /// `scheme://host[:port]` for the item — no path, no query (a token in a
    /// link never lands in the vault). Nil for anything but http(s).
    nonisolated static func site(_ raw: String) -> (host: String, uri: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              var host = url.host?.lowercased(), url.user == nil, url.password == nil
        else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        guard host.contains(".") || host == "localhost" else { return nil }
        return (host, "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")")
    }

    /// An otpauth URI as given, or a base32 secret without its spaces and
    /// dashes, uppercased — only when a code can be made from it.
    nonisolated static func normalizedTOTP(_ raw: String) -> String? {
        let seed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if seed.lowercased().hasPrefix("otpauth://") { return TOTP.code(from: seed) == nil ? nil : seed }
        let secret = seed.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        return TOTP.code(from: secret) == nil ? nil : secret
    }

    /// The saved login a save replaces: same site as `copper signin` matches
    /// sites, same username in any case.
    static func existingLogin(in items: [Item], host: String, username: String) -> Item? {
        items.first { item in
            item.type == 1 && item.username.caseInsensitiveCompare(username) == .orderedSame
                && item.uris.contains { Credentials.matches($0, host: host) }
        }
    }

    /// Whether an agent may change a saved item: shared with agents (share
    /// all, the Agents folder, its own toggle) and not `copper-agent: deny`.
    nonisolated static func agentMayChange(_ item: Item, folder: String?, shareAll: Bool, allowed: Set<String>) -> Bool {
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if item.fields.contains(where: { clean($0.name) == "copper-agent" && clean($0.value) == "deny" }) { return false }
        return shareAll || folder.map(clean) == "agents" || allowed.contains(CredentialID.bitwarden(item.id).string)
    }

    private nonisolated static func text(_ any: Any?) -> String? {
        guard let value = (any as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
