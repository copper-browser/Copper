import Foundation

/// Bench's small, JSON-safe window into the test-world passkey store.
enum PasskeysBench {
    @MainActor static func handle(_ request: [String: Any]) -> [String: Any] {
        let op = request["op"] as? String ?? "list"
        switch op {
        case "list":
            // Copper's own, then the unlocked Bitwarden vault's (metadata only).
            return ["credentials": PasskeyStore.all().map(row) + BitwardenPasskeys.all().map(row)]
        case "count":
            return ["count": PasskeyStore.all().count, "bitwarden": BitwardenPasskeys.all().count]
        case "pick":
            guard Store.testing else { return ["error": "passkeys pick only works in a test world"] }
            let answer = (request["arg"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            Passkeys.autoPick = answer.isEmpty || answer.lowercased() == "ask" ? nil : answer
            return ["pick": Passkeys.autoPick ?? "ask"]
        case "offered":
            return ["offered": Passkeys.lastOffered]
        case "forget":
            guard let text = request["arg"] as? String, let id = Data(base64URL: text) else {
                return ["error": "passkeys forget needs an id"]
            }
            PasskeyStore.forget(id: id)
            return ["forgotten": text, "count": PasskeyStore.all().count]
        case "answer":
            guard Store.testing else { return ["error": "passkeys answer only works in a test world"] }
            switch (request["arg"] as? String ?? "").lowercased() {
            case "yes": Passkeys.autoProve = true
            case "no": Passkeys.autoProve = false
            case "ask", "": Passkeys.autoProve = nil
            default: return ["error": "passkeys answer expects yes, no, or ask"]
            }
            return ["answer": Passkeys.autoProve.map { $0 ? "yes" : "no" } ?? "ask"]
        default:
            return ["error": "unknown passkeys operation \(op)"]
        }
    }

    private static func row(_ credential: PasskeyStore.Credential) -> [String: Any] {
        [
            "id": credential.id.base64URL,
            "rpId": credential.rpId,
            "userName": credential.userName,
            "displayName": credential.displayName,
            "label": credential.label,
            "origin": credential.origin ?? "Copper",
            "created": credential.created.timeIntervalSince1970,
            "lastUsed": credential.lastUsed?.timeIntervalSince1970 ?? NSNull(),
            "counter": credential.counter,
            "source": "copper",
        ]
    }

    @MainActor private static func row(_ match: BitwardenPasskeys.Match) -> [String: Any] {
        [
            "id": match.id.base64URL,
            "rpId": match.passkey.rpId,
            "userName": match.passkey.userName,
            "displayName": match.passkey.userDisplayName,
            "label": match.label,
            "origin": "Bitwarden",
            "source": "bitwarden",
            "item": match.item.id,
            "discoverable": match.passkey.discoverable,
            "counter": match.passkey.counter,
            "created": match.passkey.created?.timeIntervalSince1970 ?? NSNull(),
            "agent": BitwardenPasskeys.sharedWithAgents(match),
        ]
    }
}
