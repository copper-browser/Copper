import AppKit
import SwiftUI

/// Settings › Passwords › 1Password. Three ways in — the 1Password app
/// (Touch ID in 1Password's own window; preferred whenever the app is on this
/// Mac), the account password, or a service account token — then the vault's
/// status, where new logins go, and Lock / Sign out / Sync now. The card owns
/// only what is being typed; `OnePassword` owns the session and the cache.
struct OnePasswordCard: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var onePassword = OnePassword.shared

    @State private var path: OnePassword.Mode = OnePassword.appInstalled ? .app : .password
    @State private var chosenAccount = ""
    @State private var addingAccount = false
    @State private var address = OnePassword.defaultAddress
    @State private var email = ""
    @State private var secretKey = ""
    @State private var password = ""
    @State private var token = ""
    @State private var busy = false
    /// Bench renders pass a path in, to picture each way in.
    var initialPath: OnePassword.Mode?

    init(browser: Browser, path: OnePassword.Mode? = nil) {
        self.browser = browser
        self.initialPath = path
        if let path { _path = State(initialValue: path) }
    }

    var body: some View {
        let _ = SettingsPerf.tick("onePasswordCard") // Fork (settings-perf)
        Card {
            content
            if let problem = onePassword.problem, problem.problem != .integrationOff, !isMissing {
                Rule()
                Line("1Password couldn't do that", problem.message) {
                    Pill("Dismiss") { onePassword.clearProblem() }
                }
                .foregroundStyle(Palette.danger)
            }
        }
        .onAppear {
            if initialPath == nil, let mode = onePassword.mode { path = mode }
            if chosenAccount.isEmpty { chosenAccount = onePassword.account?.userID ?? onePassword.accounts.first?.userID ?? "" }
            Task { await onePassword.refreshAccounts() }
        }
        .onChange(of: onePassword.accounts) { _, accounts in
            if chosenAccount.isEmpty || !accounts.contains(where: { $0.userID == chosenAccount }) {
                chosenAccount = onePassword.account?.userID ?? accounts.first?.userID ?? ""
            }
        }
    }

    private var isMissing: Bool { onePassword.state == .missing }

    @ViewBuilder
    private var content: some View {
        switch onePassword.state {
        case .missing: missing
        case .signedOut: signedOut
        case .locked: locked
        case .unlocked(let lastSync): unlocked(lastSync)
        }
    }

    // MARK: - No CLI

    @ViewBuilder
    private var missing: some View {
        Line("1Password", "Install the 1Password CLI to fill from your vaults") {
            HStack(spacing: 8) {
                Text("brew install 1password-cli")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .fixedSize()
                Pill("Copy") { copy("brew install 1password-cli") }
            }
        }
        Rule()
        Line("Then", OnePassword.appInstalled
             ? "In 1Password, turn on Settings › Developer › Integrate with 1Password CLI — Touch ID then unlocks it here"
             : "Sign in here with your account, or install the 1Password app to unlock with Touch ID") {
            Pill("Check again") { Task { await onePassword.refreshAccounts() } }
        }
    }

    // MARK: - Not connected

    @ViewBuilder
    private var signedOut: some View {
        Line("1Password", "Copper reads your vaults through the 1Password CLI and keeps them in memory while unlocked") {
            Text("Not connected")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.muted)
        }
        Rule()
        Line("Sign in with") {
            Segmented(options: paths, selection: $path)
                .fixedSize()
        }
        .settingsAnchor("onepassword.method")
        Rule()
        switch path {
        case .app: appSignIn
        case .password: passwordSignIn
        case .service: serviceSignIn
        }
    }

    private var paths: [(OnePassword.Mode, String)] {
        var options: [(OnePassword.Mode, String)] = []
        if OnePassword.appInstalled { options.append((.app, "1Password app")) }
        options.append((.password, "Password"))
        options.append((.service, "Service account"))
        return options
    }

    @ViewBuilder
    private var appSignIn: some View {
        if onePassword.accounts.count > 1 {
            Line("Account") { accountMenu(allowNew: false) }
                .settingsAnchor("onepassword.account")
            Rule()
        }
        Line("Unlock with 1Password", "1Password asks for Touch ID in its own window — no password is typed into Copper") {
            actionPill(onePassword.signingIn ? "Waiting for 1Password…" : "Unlock with 1Password") { unlockWithApp() }
        }
        .settingsAnchor("onepassword.unlock")
        if onePassword.problem?.problem == .integrationOff {
            Rule()
            integrationGuide
        }
    }

    @ViewBuilder
    private var passwordSignIn: some View {
        if onePassword.accounts.isEmpty || addingAccount {
            Line("Sign-in address") {
                TextField(OnePassword.defaultAddress, text: $address)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
            .settingsAnchor("onepassword.account")
            Rule()
            Line("Email") {
                TextField("you@example.com", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
            Rule()
            Line("Secret Key", "From your Emergency Kit — A3-…") {
                SecureField("A3-XXXXXX-…", text: $secretKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
            Rule()
            Line("Account password") {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onSubmit { addAccount() }
            }
            Rule()
            Line("Add this account", "The Secret Key and password go to the 1Password CLI, which keeps the account on this Mac") {
                HStack(spacing: 6) {
                    if !onePassword.accounts.isEmpty {
                        Pill("Cancel") { addingAccount = false }
                    }
                    actionPill("Sign in") { addAccount() }
                }
                .fixedSize()
            }
            .settingsAnchor("onepassword.unlock")
        } else {
            Line("Account", "Already known to 1Password on this Mac") { accountMenu(allowNew: true) }
                .settingsAnchor("onepassword.account")
            Rule()
            Line("Account password") {
                HStack(spacing: 8) {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .onSubmit { signIn() }
                    actionPill("Sign in") { signIn() }
                }
            }
            .settingsAnchor("onepassword.unlock")
        }
    }

    @ViewBuilder
    private var serviceSignIn: some View {
        Line("Service account token", "For a Mac nobody sits at. Reads the vaults the account was given; saves only where it may write") {
            HStack(spacing: 8) {
                SecureField("ops_…", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .onSubmit { connectToken() }
                actionPill("Connect") { connectToken() }
            }
        }
        .settingsAnchor("onepassword.service")
    }

    private var integrationGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.muted)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Let 1Password answer Copper")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                    Text("In the 1Password app, open Settings › Developer and turn on Integrate with 1Password CLI. Touch ID unlock (Settings › Security) has to be on too.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Pill("Use the password instead") {
                    path = .password
                    onePassword.clearProblem()
                }
                Pill("Open 1Password", filled: true) { OnePassword.openApp() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Locked

    @ViewBuilder
    private var locked: some View {
        Line("1Password", "Locked" + accountSuffix) {
            Pill("Sign out") { signOut() }
        }
        .settingsAnchor("onepassword.account")
        Rule()
        switch onePassword.mode {
        case .password:
            Line("Account password", "The session ended or Copper was locked") {
                HStack(spacing: 8) {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .onSubmit { unlock() }
                    actionPill("Unlock") { unlock() }
                }
            }
            .settingsAnchor("onepassword.unlock")
        case .service:
            Line("Service account", "The token is kept on this Mac, readable by this user only") {
                actionPill("Unlock") { unlock() }
            }
            .settingsAnchor("onepassword.unlock")
        case .app, .none:
            Line("Unlock with 1Password", "Touch ID in 1Password's own window") {
                actionPill(onePassword.signingIn ? "Waiting for 1Password…" : "Unlock with 1Password") { unlock() }
            }
            .settingsAnchor("onepassword.unlock")
            if onePassword.problem?.problem == .integrationOff {
                Rule()
                integrationGuide
            }
        }
    }

    private var accountSuffix: String {
        guard let account = onePassword.account else { return "" }
        if !account.email.isEmpty { return " · \(account.email)" }
        return account.host.isEmpty ? "" : " · \(account.host)"
    }

    // MARK: - Unlocked

    @ViewBuilder
    private func unlocked(_ lastSync: Date?) -> some View {
        Line("1Password", onePassword.loadingList || onePassword.loadingDetails
             ? "Unlocked · reading your vaults…"
             : "Unlocked · synced \(relative(lastSync))") {
            HStack(spacing: 8) {
                if onePassword.loadingList || onePassword.loadingDetails { Ring(size: 10) }
                Pill("Sync now") { sync() }
                    .disabled(onePassword.loadingList)
                Pill("Lock") { lock() }
            }
            .fixedSize()
        }
        .settingsAnchor("onepassword.sync")
        Rule()
        Line("Account", accountLine) {
            Pill("Sign out") { signOut() }
        }
        .settingsAnchor("onepassword.account")
        Rule()
        Line("Vaults", vaultsLine) { EmptyView() }
        // Once the vaults are read: which one takes a new login, or that
        // none can (a read-only service account).
        if !onePassword.vaults.isEmpty {
            Rule()
            if onePassword.writableVaults.isEmpty {
                Line("New logins go to", "None of these vaults lets this account create items — saves stay in the keychain") {
                    Text("Read-only").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                .settingsAnchor("onepassword.vault")
            } else {
                Line("New logins go to", saveVaultDetail) { vaultMenu }
                    .settingsAnchor("onepassword.vault")
            }
        }
        Rule()
        Line("Stay unlocked between launches", stayDetail) {
            Switch(on: Binding(
                get: { onePassword.stayUnlocked },
                set: { onePassword.stayUnlocked = $0 }
            ))
        }
        .settingsAnchor("onepassword.stay")
    }

    private var accountLine: String {
        let who = onePassword.account
        var parts: [String] = []
        if let email = who?.email, !email.isEmpty { parts.append(email) }
        if let host = who?.host, !host.isEmpty { parts.append(host) }
        let how = onePassword.mode?.summary ?? ""
        let head = parts.joined(separator: " · ")
        if head.isEmpty { return how.isEmpty ? "Signed in" : "Signed in \(how)" }
        return how.isEmpty ? head : "\(head) — \(how)"
    }

    private var vaultsLine: String {
        let names = onePassword.vaults.map(\.name)
        let counts = onePassword.counts
        var parts: [String] = []
        if counts.logins > 0 { parts.append("\(counts.logins) \(counts.logins == 1 ? "login" : "logins")") }
        if counts.identities > 0 { parts.append("\(counts.identities) \(counts.identities == 1 ? "identity" : "identities")") }
        if counts.cards > 0 { parts.append("\(counts.cards) \(counts.cards == 1 ? "card" : "cards")") }
        let what = parts.isEmpty ? (onePassword.loadingList ? "Reading…" : "Nothing to fill yet") : parts.joined(separator: " · ")
        guard !names.isEmpty else { return what }
        return "\(names.joined(separator: ", ")) — \(what)"
    }

    private var saveVaultDetail: String {
        browser.prefs.passwordsBackend == .onePassword
            ? "A login saved from a page is created in this vault"
            : "Used when new passwords are saved to 1Password"
    }

    private var stayDetail: String {
        switch onePassword.mode {
        case .password:
            return "The session is kept in a file only you can read, beside Copper's data — off asks for the password once per launch"
        case .service:
            return "Off, the vault stays locked at launch until you unlock it here"
        default:
            return "Copper checks with 1Password at launch and opens when the app still approves it — off, it waits for you"
        }
    }

    private var vaultMenu: some View {
        Menu {
            ForEach(onePassword.writableVaults) { vault in
                Button(vault.name) { onePassword.setSaveVault(vault) }
            }
        } label: {
            Text(onePassword.saveVault?.name ?? "Choose…").font(.system(size: 11.5))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func accountMenu(allowNew: Bool) -> some View {
        let current = onePassword.accounts.first(where: { $0.userID == chosenAccount }) ?? onePassword.accounts.first
        return Menu {
            ForEach(onePassword.accounts) { account in
                Button(account.label) { chosenAccount = account.userID }
            }
            if allowNew {
                Divider()
                Button("Add another account…") { addingAccount = true }
            }
        } label: {
            Text(current?.label ?? "Choose an account").font(.system(size: 11.5)).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Actions

    @ViewBuilder
    private func actionPill(_ title: String, action: @escaping () -> Void) -> some View {
        let working = busy || onePassword.signingIn
        HStack(spacing: 6) {
            if working { Ring(size: 10) }
            Pill(working && !title.hasPrefix("Waiting") ? "Working…" : title, filled: !working, action: action)
                .disabled(working)
        }
        .fixedSize()
    }

    private func perform(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await work() } catch {
                // OnePassword keeps the failure (`problem`) for the card to show.
            }
        }
    }

    private func unlockWithApp() {
        let account = onePassword.accounts.count > 1 ? chosenAccount : nil
        perform { try await onePassword.unlockWithApp(account: account) }
    }

    private func signIn() {
        let password = self.password
        let account = chosenAccount.isEmpty ? nil : chosenAccount
        perform {
            try await onePassword.signIn(password: password, account: account)
            self.password = ""
        }
    }

    private func addAccount() {
        let (address, email, key, password) = (self.address, self.email, self.secretKey, self.password)
        perform {
            try await onePassword.addAccount(address: address, email: email, secretKey: key, password: password)
            self.password = ""
            self.secretKey = ""
            self.addingAccount = false
        }
    }

    private func connectToken() {
        let token = self.token
        perform {
            try await onePassword.connect(serviceToken: token)
            self.token = ""
        }
    }

    private func unlock() {
        let password = self.password
        perform {
            try await onePassword.unlock(password: password)
            self.password = ""
        }
    }

    private func lock() {
        perform { await onePassword.lock() }
    }

    private func signOut() {
        perform {
            await onePassword.signOut()
            if browser.prefs.passwordsBackend == .onePassword { browser.prefs.passwordsBackend = .keychain }
        }
    }

    private func sync() {
        perform { try await onePassword.sync() }
    }

    private func copy(_ text: String) {
        SettingsActions.copy(text)
        browser.announce("Install command copied")
    }

    private func relative(_ date: Date?) -> String {
        guard let date else { return "not yet" }
        if Date().timeIntervalSince(date) < 45 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// "Save new passwords to: Keychain | Bitwarden | 1Password" — one chooser
/// for every backend, at the head of Settings › Passwords › Password
/// managers, drawn once a password manager is connected. A vault that is set
/// up but locked stays offered; its saves go to the keychain until it opens,
/// and the line says so.
struct SaveTargetCard: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var bitwarden = Bitwarden.shared
    @ObservedObject private var onePassword = OnePassword.shared

    var body: some View {
        let _ = SettingsPerf.tick("saveTarget") // Fork (settings-perf)
        if SaveTargetLine.choices(prefs: browser.prefs).count > 1 {
            Card { SaveTargetLine(browser: browser) }
                .settingsAnchor("passwords.backend")
        }
    }
}

struct SaveTargetLine: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject private var bitwarden = Bitwarden.shared
    @ObservedObject private var onePassword = OnePassword.shared

    init(browser: Browser, prefs: Preferences? = nil) {
        self.browser = browser
        self.prefs = prefs ?? browser.prefs
    }

    var body: some View {
        Line("Save new passwords to", detail) {
            Segmented(options: Self.choices(prefs: prefs), selection: $prefs.passwordsBackend)
                .fixedSize()
        }
    }

    /// Keychain always; a manager once it is connected (locked or open), or
    /// while it is the chosen one.
    @MainActor
    static func choices(prefs: Preferences) -> [(Credentials.Backend, String)] {
        var list: [(Credentials.Backend, String)] = [(.keychain, "Keychain")]
        var bitwardenConnected = false
        switch Bitwarden.shared.state {
        case .locked, .unlocked: bitwardenConnected = true
        default: break
        }
        if bitwardenConnected || prefs.passwordsBackend == .bitwarden { list.append((.bitwarden, "Bitwarden")) }
        let onePassword = OnePassword.shared
        if onePassword.isUnlocked || onePassword.isLocked || prefs.passwordsBackend == .onePassword {
            list.append((.onePassword, "1Password"))
        }
        return list
    }

    private var detail: String {
        let chosen = prefs.passwordsBackend
        guard chosen != .keychain else { return "Offers to save go to the macOS keychain; filling uses every source" }
        if Credentials.saveTarget == chosen {
            if chosen == .onePassword, let vault = onePassword.saveVault {
                return "New logins go to 1Password's \(vault.name) vault; filling still uses every source"
            }
            return "Offers to save go to \(chosen.title); filling still uses every source"
        }
        if chosen == .onePassword, onePassword.isUnlocked {
            return "1Password has no vault this account may add to — saves go to the keychain"
        }
        var locked = chosen == .onePassword && onePassword.isLocked
        if chosen == .bitwarden, case .locked = bitwarden.state { locked = true }
        return locked
            ? "\(chosen.title) is locked — saves go to the keychain until it opens"
            : "\(chosen.title) isn't connected — saves go to the keychain"
    }
}
