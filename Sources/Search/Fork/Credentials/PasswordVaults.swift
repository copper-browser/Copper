import SwiftUI

/// What the account picker (Accounts.swift) and the browser ask of the two
/// optional vaults, Bitwarden and 1Password, in one place — so the upstream
/// files carry one call each instead of a branch per vault.
extension Browser {
    /// A login picker stays up while a vault is locked or still loading, so
    /// it can offer to unlock it or say it is on its way.
    static var vaultPending: Bool {
        if bitwardenLocked || Bitwarden.shared.isLoadingCache { return true }
        let onePassword = OnePassword.shared
        return onePassword.isLocked || (onePassword.isUnlocked && onePassword.isLoadingCache && onePassword.cachedItems.isEmpty)
    }
}

enum PickerFooter {
    /// "From your keychain", "From your keychain and 1Password", "From your
    /// keychain, Bitwarden and 1Password", "From 1Password" …
    @MainActor
    static func text(for asked: Browser.Suggesting) -> String {
        // Fork (new-password): nothing in this list comes from a vault yet.
        if case .newPassword? = asked.rows.first {
            return "Made on this Mac · kept in \(Credentials.saveTarget.title)"
        }
        var vaults = Set<Credential.Source>()
        var credentialRows = false
        var otherRows = false
        var codesOnly = !asked.rows.isEmpty
        for row in asked.rows {
            switch row {
            case .credential(let credential):
                credentialRows = true
                codesOnly = false
                if credential.source != .keychain { vaults.insert(credential.source) }
            case .code(let credential):
                credentialRows = true
                if credential.source != .keychain { vaults.insert(credential.source) }
            case .passkey: // Fork (passkey-picker): Copper's passkeys are in the keychain too
                credentialRows = true
                codesOnly = false
            case .identity(let identity):
                otherRows = true
                codesOnly = false
                vaults.insert(Autofill.source(of: identity.id))
            case .card(let card):
                otherRows = true
                codesOnly = false
                vaults.insert(Autofill.source(of: card.id))
            case .field(let field):
                otherRows = true
                codesOnly = false
                vaults.insert(Autofill.source(of: field.itemID))
            case .username:
                otherRows = true
                codesOnly = false
                vaults.formUnion(openVaults)
            case .newPassword:
                codesOnly = false
            }
        }
        for credential in asked.credentials where credential.source != .keychain { vaults.insert(credential.source) }
        if (otherRows && !credentialRows) || codesOnly {
            return "From " + names(vaults.isEmpty ? openVaults : vaults)
        }
        // A locked or loading vault is part of where this list comes from.
        if bitwardenPending { vaults.insert(.bitwarden) }
        if onePasswordPending { vaults.insert(.onePassword) }
        return vaults.isEmpty ? "From your keychain" : "From your keychain" + joined(ordered(vaults).map(\.title), leading: true)
    }

    @MainActor private static var openVaults: Set<Credential.Source> {
        var open = Set<Credential.Source>()
        if case .unlocked = Bitwarden.shared.state { open.insert(.bitwarden) }
        if OnePassword.shared.isUnlocked { open.insert(.onePassword) }
        return open.isEmpty ? [.bitwarden] : open
    }

    @MainActor private static var bitwardenPending: Bool {
        if case .locked = Bitwarden.shared.state { return true }
        if case .unlocked = Bitwarden.shared.state { return Bitwarden.shared.isLoadingCache }
        return false
    }

    @MainActor private static var onePasswordPending: Bool {
        OnePassword.shared.isLocked || (OnePassword.shared.isUnlocked && OnePassword.shared.isLoadingCache)
    }

    private static func ordered(_ sources: Set<Credential.Source>) -> [Credential.Source] {
        [.bitwarden, .onePassword].filter(sources.contains)
    }

    private static func names(_ sources: Set<Credential.Source>) -> String {
        let titles = ordered(sources).map(\.title)
        return titles.count == 2 ? "\(titles[0]) and \(titles[1])" : (titles.first ?? "Bitwarden")
    }

    /// ", Bitwarden and 1Password" / " and 1Password" after "your keychain".
    private static func joined(_ titles: [String], leading: Bool) -> String {
        switch titles.count {
        case 0: return ""
        case 1: return " and \(titles[0])"
        default: return ", " + titles.dropLast().joined(separator: ", ") + " and \(titles.last!)"
        }
    }
}

/// The rows under an empty login picker while a vault is locked or loading:
/// "Loading your 1Password vault…", "Unlock 1Password…". With the 1Password
/// app (or a service account) the unlock happens right here — the app shows
/// its own Touch ID sheet — otherwise it opens Settings › Passwords.
struct VaultPendingRows: View {
    @ObservedObject var browser: Browser
    let emptyLogin: Bool
    @ObservedObject private var bitwarden = Bitwarden.shared
    @ObservedObject private var onePassword = OnePassword.shared

    var body: some View {
        if emptyLogin {
            if bitwardenLoading { loading("Loading your Bitwarden vault…") }
            if bitwardenLocked {
                unlockRow("Unlock Bitwarden…", symbol: "shield") { openSettings() }
            }
            if onePassword.isUnlocked && onePassword.isLoadingCache && onePassword.cachedItems.isEmpty {
                loading("Loading your 1Password vault…")
            }
            if onePassword.isLocked {
                if onePassword.signingIn {
                    loading(onePassword.mode == .password ? "Unlocking 1Password…" : "Approve in 1Password…")
                } else {
                    unlockRow("Unlock 1Password…", symbol: "lock.circle") { unlockOnePassword() }
                }
            }
        }
    }

    private var bitwardenLoading: Bool {
        if case .unlocked = bitwarden.state { return bitwarden.isLoadingCache }
        return false
    }

    private var bitwardenLocked: Bool {
        if case .locked = bitwarden.state { return true }
        return false
    }

    private func loading(_ text: String) -> some View {
        HStack(spacing: 10) {
            Ring(size: 10).frame(width: 22, height: 22)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.muted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func unlockRow(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
                    .foregroundStyle(Palette.muted)
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openSettings() {
        browser.settingsPage = .passwords
        browser.tuning = true
        browser.managing = false
        browser.dropChoice()
    }

    /// The app's sheet (or a stored service token) needs nothing typed here;
    /// a password session needs the card.
    private func unlockOnePassword() {
        guard onePassword.mode == .app || onePassword.mode == .service else {
            openSettings()
            return
        }
        Task { @MainActor in
            do {
                try await onePassword.unlock()
            } catch {
                browser.announce(error.localizedDescription)
            }
        }
    }
}
