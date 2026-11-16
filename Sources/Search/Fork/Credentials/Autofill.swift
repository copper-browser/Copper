import Foundation

struct AutofillIdentity: Identifiable, Hashable {
    let id: String
    let name: String
    let title: String
    let firstName: String
    let middleName: String
    let lastName: String
    let username: String
    let company: String
    let email: String
    let phone: String
    let address1: String
    let address2: String
    let address3: String
    let city: String
    let state: String
    let postalCode: String
    let country: String
    let ssn: String
    let passportNumber: String
    let licenseNumber: String

    var fullName: String {
        [firstName, middleName, lastName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var summary: String {
        let street = [address1, address2, address3]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let locality = [city, state, postalCode]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let place = [locality, country]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let address = [street, place]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        if !address.isEmpty { return address }
        if !email.isEmpty { return email }
        if !phone.isEmpty { return phone }
        if !fullName.isEmpty { return fullName }
        return name
    }

    func values() -> [FieldKind: String] {
        var result: [FieldKind: String] = [:]
        func add(_ kind: FieldKind, _ value: String) {
            if !value.isEmpty { result[kind] = value }
        }
        add(.fullName, fullName)
        add(.firstName, firstName)
        add(.middleName, middleName)
        add(.lastName, lastName)
        add(.username, username)
        add(.company, company)
        add(.email, email)
        add(.phone, phone)
        add(.address1, address1)
        add(.address2, address2)
        add(.address3, address3)
        add(.city, city)
        add(.state, state)
        add(.postalCode, postalCode)
        add(.country, country)
        add(.ssn, ssn)
        add(.passportNumber, passportNumber)
        add(.licenseNumber, licenseNumber)
        return result
    }
}

struct AutofillCard: Identifiable, Hashable {
    let id: String
    let name: String
    let cardholderName: String
    let brand: String
    let expMonth: String
    let expYear: String
    let number: String
    let code: String

    var last4: String {
        let digits = number.filter { $0.isNumber }
        guard !digits.isEmpty else { return "" }
        return String(digits.suffix(4))
    }

    var label: String {
        let tail = last4.isEmpty ? "" : "•••• \(last4)"
        return [brand, tail].filter { !$0.isEmpty }.joined(separator: " ")
    }

    func values() -> [FieldKind: String] {
        var result: [FieldKind: String] = [:]
        func add(_ kind: FieldKind, _ value: String) {
            if !value.isEmpty { result[kind] = value }
        }
        add(.cardNumber, number)
        add(.cardName, cardholderName)
        add(.cardExpMonth, expMonth)
        add(.cardExpYear, expYear)
        if !expMonth.isEmpty && !expYear.isEmpty {
            let month = expMonth.count == 1 ? "0\(expMonth)" : expMonth
            let year = expYear.count > 2 ? String(expYear.suffix(2)) : expYear
            add(.cardExp, "\(month)/\(year)")
        }
        add(.cardCode, code)
        add(.cardBrand, brand)
        return result
    }
}

struct AutofillField: Hashable {
    let itemID: String
    let itemName: String
    let name: String
    let value: String
    let hidden: Bool
}

/// The in-process view of the unlocked Bitwarden and 1Password autofill
/// caches. A 1Password identity, card or field carries `op:<item id>` as its
/// id; Bitwarden's carry the bare item id (shared as `bw:<id>`).
@MainActor
enum Autofill {
    static var identities: [AutofillIdentity] {
        Bitwarden.shared.cachedIdentities + (OnePassword.shared.isUnlocked ? OnePassword.shared.cachedIdentities : [])
    }

    static var cards: [AutofillCard] {
        Bitwarden.shared.cachedCards + (OnePassword.shared.isUnlocked ? OnePassword.shared.cachedCards : [])
    }

    /// The id an identity, card or field is shared with agents under.
    static func stableID(_ id: String) -> String {
        id.hasPrefix("op:") ? id : "bw:\(id)"
    }

    /// Which vault an autofill id came from.
    static func source(of id: String) -> Credential.Source {
        id.hasPrefix("op:") ? .onePassword : .bitwarden
    }

    static func fields(for host: String) -> [AutofillField] {
        bitwardenFields(for: host) + onePasswordFields(for: host)
    }

    private static func onePasswordFields(for host: String) -> [AutofillField] {
        Credentials.onePasswordItemsMatching(host: host).flatMap { item in
            item.fields.compactMap { field in
                guard !field.name.isEmpty else { return nil }
                return AutofillField(
                    itemID: OnePassword.stableID(item.id),
                    itemName: item.title,
                    name: field.name,
                    value: OnePassword.shared.fieldValue(itemID: item.id, name: field.name) ?? field.value,
                    hidden: field.hidden
                )
            }
        }
    }

    private static func bitwardenFields(for host: String) -> [AutofillField] {
        Credentials.itemsMatching(host: host).flatMap { item in
            item.fields.compactMap { field in
                guard !field.name.isEmpty else { return nil }
                return AutofillField(
                    itemID: item.id,
                    itemName: item.name,
                    name: field.name,
                    value: Bitwarden.shared.fieldValue(itemID: item.id, name: field.name) ?? field.value,
                    hidden: field.hidden
                )
            }
        }
    }

    static func fields(for host: String, matching label: String) -> [AutofillField] {
        let wanted = normalized(label)
        guard wanted.count >= 3 else { return [] }
        return fields(for: host).filter { field in
            let candidate = normalized(field.name)
            guard candidate.count >= 3 else { return false }
            return candidate == wanted || candidate.contains(wanted) || wanted.contains(candidate)
        }
    }

    static var topUsernames: [String] {
        var seen: [String: (name: String, count: Int)] = [:]
        let onePassword = OnePassword.shared.isUnlocked
            ? OnePassword.shared.cachedItems.filter(\.isLogin).map(\.username) : []
        let names = Bitwarden.shared.cachedItems.filter { $0.type == 1 }.map(\.username) + onePassword
        for name in names {
            let username = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !username.isEmpty else { continue }
            let key = username.lowercased()
            if let current = seen[key] {
                seen[key] = (name: current.name, count: current.count + 1)
            } else {
                seen[key] = (name: username, count: 1)
            }
        }

        var result = seen.values.sorted { left, right in
            if left.count != right.count { return left.count > right.count }
            let order = left.name.localizedCaseInsensitiveCompare(right.name)
            return order == .orderedSame ? left.name < right.name : order == .orderedAscending
        }.map(\.name)
        if result.count >= 8 { return Array(result.prefix(8)) }
        var included = Set(result.map { $0.lowercased() })

        for identity in identities {
            for value in [identity.email, identity.username] {
                let username = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !username.isEmpty else { continue }
                let key = username.lowercased()
                guard !included.contains(key) else { continue }
                result.append(username)
                included.insert(key)
                if result.count == 8 { return result }
            }
        }
        return result
    }

    /// Every item — login, card or identity — keeps the full policy: the
    /// Agents folder (1Password: vault or `copper-agent` tag) shares it, the
    /// `copper-agent: deny` field keeps it back, then the switch and the list.
    static func isAllowed(_ id: String) -> Bool {
        let hint = Credentials.agentHint(autofillID: id) ?? Credential.AgentHint.none
        return hint != .deny && (AgentAccess.shareAll || AgentAccess.allowed.contains(stableID(id)) || hint == .allow)
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().filter { character in
            !character.isWhitespace && character != "-" && character != "_"
                && character != ":" && character != "*"
        }
    }
}
