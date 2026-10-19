import CryptoKit
import Foundation

// Passkeys kept in the Bitwarden vault (`login.fido2Credentials`), signed by
// Copper's own authenticator.
//
// The unlocked item cache carries only their metadata (Bitwarden.Passkey):
// site, account, credential id, counter. The private key is read from
// `bw get item` at the moment a sign-in has been chosen and verified, used
// in memory, and the buffers Copper holds are overwritten before it returns.
// Keys also pass through memory on every cache refresh (`bw list items`
// returns them; that buffer is cleared once decoded, and the decoder never
// copies `keyValue`) and in `bw edit`/`bw create` replies (cleared too).
// Nothing here writes a vault key to disk, the keychain, a log or a reply.
//
// Bitwarden keeps one shape for every passkey: ES256 (keyAlgorithm ECDSA,
// keyCurve P-256), the key as base64url PKCS#8, the credential id as a GUID
// (or `b64.` + base64url for an imported one), the user handle as base64url,
// counter and discoverable as strings.

@MainActor
enum BitwardenPasskeys {
    /// One vault passkey with the login it lives on.
    struct Match: Hashable {
        let item: Bitwarden.Item
        let passkey: Bitwarden.Passkey
        /// The credential id as the site knows it (raw bytes).
        let id: Data

        /// What a person recognises: the passkey's account, else the login's.
        var label: String {
            if !passkey.userName.isEmpty { return passkey.userName }
            if !passkey.userDisplayName.isEmpty { return passkey.userDisplayName }
            return item.username.isEmpty ? item.name : item.username
        }

        var userHandle: Data { passkey.userHandle.flatMap(Data.init(base64URL:)) ?? Data() }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static var unlocked: Bool {
        if case .unlocked = Bitwarden.shared.state { return true }
        return false
    }

    /// Every vault passkey, for Settings and the bench. Empty while locked.
    static func all() -> [Match] {
        guard unlocked else { return [] }
        return Bitwarden.shared.cachedItems.filter { $0.type == 1 }.flatMap { item in
            item.passkeys.compactMap { passkey in rawID(passkey.credentialId).map { Match(item: item, passkey: passkey, id: $0) } }
        }
    }

    /// The vault passkeys a sign-in may use: this relying party exactly,
    /// then the site's list when it gave one, or only discoverable passkeys
    /// when it left the choice to the authenticator (an empty list).
    static func matching(rpId: String, allow: [Data]) -> [Match] {
        all().filter { match in
            guard match.passkey.rpId.caseInsensitiveCompare(rpId) == .orderedSame else { return false }
            return allow.isEmpty ? match.passkey.discoverable : allow.contains(match.id)
        }
    }

    /// The vault passkeys a page on `host` could ask for: its own relying
    /// party or a parent domain's (an explicit rpId may name either).
    /// The same rule the authenticator applies to the request (Passkeys.allowedRP:
    /// the host itself or a parent within its registrable domain); SignIn
    /// hands over the host without `www.`, so that form is tried too.
    static func usable(on host: String) -> [Match] {
        let host = host.lowercased()
        return all().filter { match in
            Passkeys.allowedRP(match.passkey.rpId, for: host) || Passkeys.allowedRP(match.passkey.rpId, for: "www." + host)
        }
    }

    /// Whether the person shared this passkey's login with agents — the same
    /// rule, and the same switch, as its password (AgentAccess). A login
    /// with Bitwarden's master-password reprompt is never an agent's: its
    /// passkey always takes the person's Touch ID.
    static func sharedWithAgents(_ match: Match) -> Bool {
        !match.item.reprompt && AgentAccess.isAllowed(Credentials.credential(bitwarden: match.item))
    }

    // MARK: - ids

    /// A vault credential id as bytes: a GUID is its 16 bytes, `b64.` marks
    /// base64url, and anything else is tried as base64url.
    nonisolated static func rawID(_ text: String) -> Data? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uuid = UUID(uuidString: value) {
            return withUnsafeBytes(of: uuid.uuid) { Data($0) }
        }
        if value.hasPrefix("b64.") { return Data(base64URL: String(value.dropFirst(4))) }
        return Data(base64URL: value)
    }

    /// How a credential id made here is written to the vault: Bitwarden's
    /// own GUID form for 16 bytes, `b64.` + base64url otherwise.
    nonisolated static func vaultID(_ raw: Data) -> String {
        guard raw.count == 16 else { return "b64." + raw.base64URL }
        let b = Array(raw)
        let uuid = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
        return uuid.uuidString.lowercased()
    }

    // MARK: - signing

    struct Assertion {
        let authenticatorData: Data
        let signature: Data
    }

    /// Items whose counter write-back lost the passkey it was advancing (a
    /// read-back after `bw edit item` did not find it): Copper stops writing
    /// counters there for the rest of the run rather than rewrite the item
    /// again. Said once in the log.
    private static var counterless: Set<String> = []
    /// Signs in flight per item, and those waiting: `bw get item` → sign →
    /// `bw edit item` is one read-modify-write, so two at once on the same
    /// item would hand out the same counter and the later edit would undo
    /// the earlier.
    private static var signing: Set<String> = []
    private static var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    private static func serially<T>(_ id: String, _ body: () async throws -> T) async throws -> T {
        if signing.contains(id) {
            await withCheckedContinuation { waiting[id, default: []].append($0) }
        } else {
            signing.insert(id)
        }
        defer {
            if var queue = waiting[id], !queue.isEmpty {
                let next = queue.removeFirst()
                waiting[id] = queue.isEmpty ? nil : queue
                next.resume()
            } else {
                signing.remove(id)
            }
        }
        return try await body()
    }

    /// Sign one assertion with the vault key. `authenticatorData` is built by
    /// the caller from the counter handed to it, which comes from the item
    /// as `bw get item` returns it now, not the cache. Bitwarden leaves most
    /// counters at zero and so does this; a non-zero counter is advanced
    /// (saturating at UInt32.max, never wrapping to zero) and written back to
    /// the item before the answer goes to the site.
    static func sign(_ match: Match, clientDataHash: Data,
                     authenticatorData: @escaping (UInt32) -> Data) async throws -> Assertion {
        try await Bitwarden.shared.requireUnlocked()
        let id = match.item.id
        return try await serially(id) {
            var raw = try await Bitwarden.shared.run(["get", "item", id])
            defer { raw.resetBytes(in: 0..<raw.count) }
            guard var object = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  var login = object["login"] as? [String: Any],
                  var entries = login["fido2Credentials"] as? [[String: Any]],
                  let at = entries.firstIndex(where: { ($0["credentialId"] as? String) == match.passkey.credentialId }),
                  let keyText = entries[at]["keyValue"] as? String
            else { throw Failure(message: "Bitwarden no longer has that passkey") }

            let stored = counter(entries[at]["counter"])
            let next = advanced(stored)
            let auth = authenticatorData(next)
            var der = Data(base64URL: keyText) ?? Data(base64Encoded: keyText) ?? Data()
            defer { der.resetBytes(in: 0..<der.count) }
            let signature: Data
            do {
                let key = try P256.Signing.PrivateKey(derRepresentation: der)
                signature = try key.signature(for: auth + clientDataHash).derRepresentation
            } catch {
                throw Failure(message: "Bitwarden's passkey key could not be read")
            }

            if next != stored, !counterless.contains(id) {
                // Keep the vault's spelling: the CLI writes a string.
                entries[at]["counter"] = entries[at]["counter"] is NSNumber ? NSNumber(value: next) : String(next)
                login["fido2Credentials"] = entries
                object["login"] = login
                do {
                    try await edit(id, object)
                    // `bw edit item` replaces the whole item: if anything
                    // else changed it since the read above, the passkey
                    // could be gone. Look, and stop rewriting if so.
                    if try await !holds(id, credential: match.passkey.credentialId) {
                        counterless.insert(id)
                        NSLog("%@", "Copper: a Bitwarden passkey was missing after its counter write-back; Copper no longer writes counters to that item")
                    }
                } catch {
                    // The sign-in still stands; the next one repeats this count,
                    // which a site that checks may refuse. Said, not hidden.
                    NSLog("%@", "Copper: could not advance the Bitwarden passkey counter: \(error.localizedDescription)")
                }
                Task { await Bitwarden.shared.refreshCacheIfPossible() }
            }
            return Assertion(authenticatorData: auth, signature: signature)
        }
    }

    /// A counter's next value: zero stays zero (Bitwarden's own choice), any
    /// other advances by one and stops at the top rather than wrap to zero,
    /// which a relying party reads as "counters not supported".
    nonisolated static func advanced(_ stored: UInt32) -> UInt32 {
        stored == 0 || stored == .max ? stored : stored + 1
    }

    private static func counter(_ value: Any?) -> UInt32 {
        if let number = value as? NSNumber { return number.uint32Value }
        if let text = value as? String { return UInt32(text.trimmingCharacters(in: .whitespaces)) ?? 0 }
        return 0
    }

    /// Whether the vault item still carries this credential, read fresh.
    private static func holds(_ id: String, credential: String) async throws -> Bool {
        var raw = try await Bitwarden.shared.run(["get", "item", id])
        defer { raw.resetBytes(in: 0..<raw.count) }
        let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        let entries = (object?["login"] as? [String: Any])?["fido2Credentials"] as? [[String: Any]] ?? []
        return entries.contains { ($0["credentialId"] as? String) == credential }
    }

    // MARK: - writing

    /// `bw edit item ID` / `bw create item` with the encoded item on stdin,
    /// never in argv where any process on the Mac could read it. The CLI
    /// answers with the whole item, keys included: that buffer is cleared
    /// too, after the new item's id is read from it.
    @discardableResult
    private static func write(_ args: [String], _ object: [String: Any]) async throws -> String? {
        var json = try JSONSerialization.data(withJSONObject: object, options: [])
        defer { json.resetBytes(in: 0..<json.count) }
        var encoded = Data(json.base64EncodedString().utf8)
        defer { encoded.resetBytes(in: 0..<encoded.count) }
        var answer = try await Bitwarden.shared.run(args, stdin: encoded, timeout: 30)
        defer { answer.resetBytes(in: 0..<answer.count) }
        return (try? JSONSerialization.jsonObject(with: answer) as? [String: Any])?["id"] as? String
    }

    private static func edit(_ id: String, _ object: [String: Any]) async throws {
        try await write(["edit", "item", id], object)
    }

    /// Whether an organization owns this item: a passkey added to it would
    /// be shared with everyone in the item's collections.
    private static func organizationOwned(_ object: [String: Any]) -> Bool {
        guard let org = object["organizationId"], !(org is NSNull) else { return false }
        return !((org as? String)?.isEmpty ?? false)
    }

    /// A login with no passkey at all, as the vault has it now — not the
    /// cache, which drops passkeys Copper cannot sign with and is minutes
    /// old. Anything that is not an empty list counts as a passkey.
    private static func passkeyFree(_ login: [String: Any]) -> Bool {
        guard let value = login["fido2Credentials"], !(value is NSNull) else { return true }
        return (value as? [Any])?.isEmpty ?? false
    }

    /// A passkey made in Copper, saved to the vault instead of the keychain
    /// (Save new passwords to: Bitwarden). It joins the site's personal
    /// login for the same account when, read fresh, that login has no
    /// passkey of any kind — Bitwarden keeps one per login — and is a new
    /// personal login otherwise. An organization's login is never joined:
    /// its collections would share the new key.
    static func save(_ credential: PasskeyStore.Credential, key: P256.Signing.PrivateKey, rpName: String) async throws {
        try await Bitwarden.shared.requireUnlocked()
        var pkcs8 = key.derRepresentation
        defer { pkcs8.resetBytes(in: 0..<pkcs8.count) }
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let credentialID = vaultID(credential.id)
        let entry: [String: Any] = [
            "credentialId": credentialID,
            "keyType": "public-key",
            "keyAlgorithm": "ECDSA",
            "keyCurve": "P-256",
            "keyValue": pkcs8.base64URL,
            "rpId": credential.rpId,
            "rpName": rpName.isEmpty ? credential.rpId : rpName,
            "userHandle": credential.userHandle.base64URL,
            "userName": credential.userName,
            "userDisplayName": credential.displayName,
            "counter": "0",
            "discoverable": "true",
            "creationDate": stamp.string(from: credential.created),
        ]
        let metadata = Bitwarden.Passkey(
            credentialId: credentialID, rpId: credential.rpId.lowercased(),
            userHandle: credential.userHandle.isEmpty ? nil : credential.userHandle.base64URL,
            userName: credential.userName, userDisplayName: credential.displayName,
            rpName: rpName.isEmpty ? credential.rpId : rpName, counter: 0, discoverable: true, created: credential.created)

        let candidates = credential.userName.isEmpty ? [] : Credentials.itemsMatching(host: credential.rpId).filter {
            $0.type == 1 && $0.username.caseInsensitiveCompare(credential.userName) == .orderedSame
        }
        do {
            var joined: Bitwarden.Item?
            for candidate in candidates.prefix(3) {
                var raw = try await Bitwarden.shared.run(["get", "item", candidate.id])
                defer { raw.resetBytes(in: 0..<raw.count) }
                guard var object = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
                      !organizationOwned(object) else { continue }
                var login = object["login"] as? [String: Any] ?? [:]
                guard passkeyFree(login) else { continue }
                login["fido2Credentials"] = [entry]
                object["login"] = login
                try await edit(candidate.id, object)
                joined = candidate
                break
            }
            if let joined {
                Bitwarden.shared.cache(metadata, on: joined.id, otherwise: joined)
            } else {
                let object: [String: Any] = [
                    "organizationId": NSNull(), "collectionIds": NSNull(), "folderId": NSNull(),
                    "type": 1, "name": credential.rpId, "notes": NSNull(), "favorite": false,
                    "fields": [], "reprompt": 0,
                    "login": [
                        "username": credential.userName.isEmpty ? NSNull() : credential.userName,
                        "password": NSNull(), "totp": NSNull(),
                        "uris": [["uri": "\(OnePassword.scheme(for: credential.rpId))://\(credential.rpId)", "match": NSNull()]],
                        "fido2Credentials": [entry],
                    ] as [String: Any],
                ]
                let made = try await write(["create", "item"], object)
                let uri = Bitwarden.URI(uri: "\(OnePassword.scheme(for: credential.rpId))://\(credential.rpId)", match: nil)
                Bitwarden.shared.cache(metadata, on: made ?? "", otherwise: Bitwarden.Item(
                    id: made ?? "pending-\(credentialID)", name: credential.rpId, folderId: nil, username: credential.userName,
                    uris: [uri], hasTOTP: false, fields: [], passkeys: [metadata]))
            }
        } catch {
            // A write that timed out may still have landed. Look before the
            // caller keeps a second copy of the same passkey in the keychain.
            await Bitwarden.shared.refreshCacheIfPossible()
            if all().contains(where: { $0.passkey.credentialId == credentialID }) {
                NSLog("%@", "Copper: Bitwarden reported \(error.localizedDescription) but holds the new passkey; not kept twice")
                return
            }
            throw error
        }
        // The page's next sign-in reads the cache, which already has this
        // one; the vault's own copy follows without holding up the reply.
        Task { await Bitwarden.shared.refreshCacheIfPossible() }
    }
}
