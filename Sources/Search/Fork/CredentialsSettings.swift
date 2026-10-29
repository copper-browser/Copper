import SwiftUI

/// Settings controls for the optional Bitwarden backend. The card intentionally
/// owns only UI state; Bitwarden keeps the CLI session and metadata cache.
struct BitwardenCard: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var bitwarden = Bitwarden.shared

    @State private var server = ""
    @State private var email = ""
    @State private var password = ""
    @State private var otp = ""
    @State private var busy = false
    @State private var error: String?
    @State private var autolock = 0
    /// Where the sign-in stands: the form, a choice of two-step method, or
    /// the code `bw` is waiting for.
    @State private var step: SignInStep = .credentials
    /// The two-step method the user picked, when the account has several.
    @State private var method: Int?
    @FocusState private var codeFocused: Bool

    enum SignInStep: Equatable {
        case credentials
        case chooseMethod([Bitwarden.TwoStepMethod])
        case code(Bitwarden.CodePrompt)
    }

    /// A card that opens while a sign-in started elsewhere (`copper bitwarden
    /// login`, a linked app) waits for its code starts on the code step.
    init(browser: Browser) {
        self.browser = browser
        if let pending = Bitwarden.shared.pendingLogin {
            _step = State(initialValue: .code(pending.prompt))
            _email = State(initialValue: pending.email)
            _method = State(initialValue: pending.method)
        }
    }

    var body: some View {
        let _ = SettingsPerf.tick("bitwardenCard") // Fork (settings-perf)
        Card {
            stateContent
            if let error {
                Rule()
                Line("Bitwarden couldn't do that", firstLine(error)) {
                    Pill("Dismiss") { retry() }
                }
                .foregroundStyle(.red.opacity(0.78))
            }
        }
        .onAppear {
            server = bitwarden.serverURL
            autolock = storedAutolock
            if bitwarden.pendingLogin == nil, case .code = step { step = .credentials }
        }
        .onChange(of: bitwarden.pendingLogin) { _, pending in
            if let pending {
                // A sign-in started elsewhere — `copper bitwarden login`, a
                // linked app — is waiting for its code: this is where to type it.
                guard !busy, case .credentials = step else { return }
                email = pending.email
                method = pending.method
                otp = ""
                error = nil
                step = .code(pending.prompt)
                codeFocused = true
            } else {
                // `bw` let go of the sign-in (ten minutes without a code): the
                // code step has nothing to send to any more.
                guard !busy, case .code = step else { return }
                step = .credentials
                otp = ""
                if error == nil { error = "Bitwarden stopped waiting for the code — sign in again" }
            }
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch bitwarden.state {
        case .missing:
            Line("Bitwarden", "Install the Bitwarden CLI to connect an existing vault") {
                HStack(spacing: 8) {
                    Text("brew install bitwarden-cli")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                    Pill("Copy") { copyInstallCommand() }
                }
            }
        case .unauthenticated:
            // Fork (settings-revamp): the card says whose it is first, as the
            // other states do, now that it shares a section with other managers.
            Line("Bitwarden", "Sign in to fill and save from an existing vault") {
                Text("Not connected")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.muted)
            }
            Rule()
            signInLines
        case .locked(let account):
            Line("Bitwarden", account.map { "Locked · \($0)" } ?? "Locked") {
                // The way to another account or server, as 1Password's card has.
                Pill("Sign out") { signOut() }
                    .disabled(busy)
            }
            Rule()
            Line("Master password") {
                HStack(spacing: 8) {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onSubmit { unlock() }
                    actionPill("Unlock") { unlock() }
                }
            }
        case .unlocked(let account, let lastSync):
            Line("Bitwarden", "Unlocked · synced \(relative(lastSync))") {
                HStack(spacing: 8) {
                    // Outline, as 1Password's: filled is for Sign in and Unlock.
                    actionPill("Sync now", filled: false) { sync() }
                    Pill("Lock") { lock() }
                }
            }
            Rule()
            Line("Account", account ?? "Signed in") {
                Pill("Sign out") { signOut() }
                    .disabled(busy)
            }
            Rule()
            Line("Vault", countsSummary) {
                EmptyView()
            }
            Rule()
            Line("Stay unlocked between launches", "The session is kept beside Bitwarden's own data on this Mac, readable by this user only — off asks for the master password once per launch") {
                Switch(on: Binding(
                    get: { bitwarden.stayUnlocked },
                    set: { bitwarden.stayUnlocked = $0 }
                ))
            }
            .settingsAnchor("bitwarden.stay")
            Rule()
            Line("Auto-lock", "Lock the local Bitwarden session after inactivity") {
                Picker("Auto-lock", selection: Binding(
                    get: { autolock },
                    set: {
                        autolock = $0
                        Store.settings.set($0, forKey: "bitwarden.autolockMinutes")
                    }
                )) {
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("60 minutes").tag(60)
                    Text("Never").tag(0)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 110)
            }
            .settingsAnchor("bitwarden.autolock")
        }
    }

    private var countsSummary: String {
        let counts = bitwarden.counts
        var parts: [String] = []
        if counts.logins > 0 { parts.append("\(counts.logins) \(counts.logins == 1 ? "login" : "logins")") }
        if counts.identities > 0 { parts.append("\(counts.identities) \(counts.identities == 1 ? "identity" : "identities")") }
        if counts.cards > 0 { parts.append("\(counts.cards) \(counts.cards == 1 ? "card" : "cards")") }
        return parts.isEmpty ? "Nothing saved yet" : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var signInLines: some View {
        switch step {
        case .credentials:
            Line("Bitwarden server", "Use bitwarden.com, EU, or a self-hosted Vaultwarden server") {
                TextField("https://vault.bitwarden.com", text: $server)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }
            .settingsAnchor("bitwarden.server") // Fork (settings-revamp): search anchors
            Rule()
            Line("Email") {
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }
            Rule()
            Line("Master password", "A two-step or new-device code is asked for next, if the account wants one") {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit { signIn() }
            }
            Rule()
            Line("Connect") {
                actionPill("Sign in") { signIn() }
            }
        case .chooseMethod(let methods):
            Line("Two-step login", "This account has more than one way to get a code — which one?") {
                HStack(spacing: 6) {
                    ForEach(methods) { choice in
                        Pill(choice.name, filled: methods.count == 1) { pick(choice) }
                    }
                }
                .fixedSize()
            }
            Rule()
            Line("Account", email) {
                Pill("Cancel") { cancelSignIn() }
            }
        case .code(let prompt):
            Line(codeTitle(prompt), codeDetail(prompt)) {
                HStack(spacing: 8) {
                    TextField("Code", text: $otp)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .focused($codeFocused)
                        .onSubmit { submitCode() }
                    actionPill("Continue") { submitCode() }
                }
            }
            Rule()
            Line("Account", email) {
                HStack(spacing: 6) {
                    if wantsEmailOption(prompt) {
                        Pill(emailOptionTitle(prompt)) { pick(.email) }
                            .disabled(busy)
                    }
                    Pill("Cancel") { cancelSignIn() }
                }
                .fixedSize()
            }
        }
    }

    private func codeTitle(_ prompt: Bitwarden.CodePrompt) -> String {
        switch prompt {
        case .newDevice: return "New device — enter the emailed code"
        case .twoStep(let method):
            switch method {
            case 1: return "Enter the code Bitwarden emailed"
            case 3: return "Touch your YubiKey"
            case 0: return "Enter your authenticator app code"
            default: return "Enter your two-step login code"
            }
        }
    }

    private func codeDetail(_ prompt: Bitwarden.CodePrompt) -> String {
        switch prompt {
        case .newDevice:
            return "This Mac hasn't signed in to \(email) before, so Bitwarden emailed a verification code to it — check the inbox, spam too"
        case .twoStep(let method):
            switch method {
            case 1: return "A two-step code was just sent to \(email); the newest email is the one that counts"
            case 3: return "With the field focused, press the key so it types its code"
            case 0: return "The six digits your authenticator app shows for Bitwarden right now"
            default: return "Your authenticator app's code — or the one just emailed, if this account uses email codes"
            }
        }
    }

    /// A way to ask for an email code when the prompt did not say one was sent.
    private func wantsEmailOption(_ prompt: Bitwarden.CodePrompt) -> Bool {
        if case .twoStep(let method) = prompt { return method == nil || method == 1 }
        return false
    }

    private func emailOptionTitle(_ prompt: Bitwarden.CodePrompt) -> String {
        if case .twoStep(let method) = prompt, method == 1 { return "Send again" }
        return "Email me a code"
    }

    @ViewBuilder
    private func actionPill(_ title: String, filled: Bool = true, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            if busy { Ring(size: 10) }
            Pill(busy ? "Working…" : title, filled: filled && !busy, action: action)
                .disabled(busy)
        }
        .fixedSize()
    }

    private var storedAutolock: Int {
        guard let value = Store.settings.object(forKey: "bitwarden.autolockMinutes") as? NSNumber else {
            return 0
        }
        let minutes = value.intValue
        return [0, 5, 15, 60].contains(minutes) ? minutes : 0
    }

    /// Email and master password go to `bw`; what comes back decides the
    /// next step — signed in, a method to choose, or a code to enter.
    private func signIn() {
        guard !busy else { return }
        busy = true
        error = nil
        let server = self.server
        let email = self.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = self.password
        let method = self.method
        Task { @MainActor in
            defer { busy = false }
            do {
                try await bitwarden.configure(server: server)
                let outcome = try await bitwarden.login(email: email, password: password, method: method)
                handle(outcome)
            } catch {
                self.error = firstLine(error)
                self.step = .credentials
            }
        }
    }

    private func handle(_ outcome: Bitwarden.LoginOutcome) {
        switch outcome {
        case .signedIn:
            password = ""
            otp = ""
            method = nil
            step = .credentials
        case .step(.chooseMethod(let methods)):
            step = .chooseMethod(methods)
        case .step(.needsCode(let prompt)):
            otp = ""
            step = .code(prompt)
            codeFocused = true
        }
    }

    private func pick(_ choice: Bitwarden.TwoStepMethod) {
        method = choice.id
        signIn()
    }

    /// The code, to the `bw` that is waiting for it. A code that is refused
    /// ends that `bw`; a fresh sign-in is started at once so the next try
    /// has somewhere to go (and a fresh email is sent when that is the method).
    private func submitCode() {
        guard !busy else { return }
        let code = otp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        busy = true
        error = nil
        let email = self.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = self.password
        let method = self.method
        Task { @MainActor in
            defer { busy = false }
            do {
                try await bitwarden.submit(code: code)
                handle(.signedIn)
            } catch {
                let why = firstLine(error)
                otp = ""
                do {
                    let outcome = try await bitwarden.login(email: email, password: password, method: method)
                    handle(outcome)
                    if case .step(.needsCode(let prompt)) = outcome {
                        var hint = why
                        if case .twoStep(let m) = prompt, m == 1 { hint += " — a new code was emailed; enter that one" }
                        else if case .newDevice = prompt { hint += " — a new code was emailed; enter that one" }
                        else if case .twoStep(let m) = prompt, m == 0 { hint += " — enter the code your app shows now" }
                        self.error = hint
                    } else {
                        self.error = why
                    }
                } catch {
                    self.error = why
                    self.step = .credentials
                }
            }
        }
    }

    private func cancelSignIn() {
        bitwarden.cancelPendingLogin()
        otp = ""
        method = nil
        error = nil
        step = .credentials
    }

    private func unlock() {
        guard !busy else { return }
        busy = true
        error = nil
        let password = self.password
        Task { @MainActor in
            defer { busy = false }
            do {
                try await bitwarden.unlock(password: password)
                self.password = ""
            } catch {
                self.error = firstLine(error)
            }
        }
    }

    private func lock() {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            await bitwarden.lock()
            busy = false
            password = ""
        }
    }

    /// Lock, forget the account and its cache on this Mac — the sign-in
    /// form comes back, for another account or another server.
    private func signOut() {
        guard !busy else { return }
        busy = true
        error = nil
        Task { @MainActor in
            await bitwarden.logout()
            busy = false
            password = ""
            otp = ""
            step = .credentials
        }
    }

    private func sync() {
        guard !busy else { return }
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await bitwarden.sync()
            } catch {
                self.error = firstLine(error)
            }
        }
    }

    private func retry() {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            await bitwarden.refreshStatus()
            busy = false
            error = nil
        }
    }

    private func copyInstallCommand() {
        SettingsActions.copy("brew install bitwarden-cli")
        browser.announce("Install command copied")
    }

    private func relative(_ date: Date?) -> String {
        guard let date else { return "not yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func firstLine(_ error: Error) -> String {
        firstLine(error.localizedDescription)
    }

    private func firstLine(_ text: String) -> String {
        text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .first.map(String.init) ?? text
    }
}

/// The user's explicit agent-sharing policy. Nothing here reads a secret;
/// rows are stripped metadata from the keychain and Bitwarden cache only.
struct AgentAccessCard: View {
    /// Not observed (settings-perf): nothing here reads the browser, and a
    /// tab loading must not redraw — or re-read — every saved account. Its
    /// saved-logins list is still watched below, for a keychain save.
    let browser: Browser
    @ObservedObject private var bitwarden = Bitwarden.shared
    @ObservedObject private var onePassword = OnePassword.shared

    @FocusState private var huntFocused: Bool
    @State private var hunt = ""
    @State private var shareAll = AgentAccess.shareAll
    @State private var policyRevision = 0
    /// Bumped when the accounts themselves change, to draw them again.
    @State private var listRevision = 0
    /// The accounts, read once and kept until a vault or the keychain
    /// changes (settings-perf): `Credentials.all()` is a keychain query plus
    /// every Bitwarden and 1Password login merged and sorted, and it used to
    /// run several times per redraw.
    @State private var list = AgentAccessList()

    private var filtered: [Credential] { list.filtered(hunt) }

    private var identities: [AutofillIdentity] { Autofill.identities }
    private var cards: [AutofillCard] { Autofill.cards }

    private var filteredIdentities: [AutofillIdentity] {
        let needle = hunt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return identities }
        return identities.filter {
            $0.name.lowercased().contains(needle)
                || $0.fullName.lowercased().contains(needle)
                || $0.email.lowercased().contains(needle)
                || $0.summary.lowercased().contains(needle)
        }
    }

    private var filteredCards: [AutofillCard] {
        let needle = hunt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return cards }
        return cards.filter {
            $0.name.lowercased().contains(needle)
                || $0.label.lowercased().contains(needle)
                || $0.cardholderName.lowercased().contains(needle)
        }
    }

    var body: some View {
        let _ = SettingsPerf.tick("agentAccess") // Fork (settings-perf)
        let _ = listRevision
        Card {
            Line("Share every saved account with agents", shareAll ? "Agents can use every saved sign-in in Copper without receiving the password" : "Off, agents use only the accounts you allow, and never receive the password") {
                Switch(on: Binding(
                    get: { shareAll },
                    set: {
                        shareAll = $0
                        AgentAccess.shareAll = $0
                        policyRevision += 1
                    }
                ))
            }
            // Fork (settings-merge): sharing everything needs no list, and an
            // empty kind (no identities, no cards) draws nothing.
            if !shareAll, !(list.isEmpty && identities.isEmpty && cards.isEmpty) {
            Rule()
            VStack(alignment: .leading, spacing: 10) {
                Hunt(text: $hunt, prompt: "Search saved accounts", focus: $huntFocused)
                if filtered.isEmpty {
                    Nothing("No saved account matches.")
                } else {
                    ScrollView(showsIndicators: false) {
                        // Lazy (settings-perf): a whole 1Password vault is
                        // hundreds of rows; only the ones in the 400 pt
                        // window are built, laid out and kept as views.
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, credential in
                                if index > 0 { Rule(inset: 0) }
                                AgentCredentialRow(
                                    credential: credential,
                                    shareAll: shareAll,
                                    allowed: AgentAccess.isAllowed(credential),
                                    setAllowed: { value in
                                        AgentAccess.set(credential, allowed: value)
                                        policyRevision += 1
                                    }
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 400)
                }

                if !filteredIdentities.isEmpty {
                    Rule(inset: 0)
                    Caption("Identities")
                    VStack(spacing: 0) {
                        ForEach(Array(filteredIdentities.enumerated()), id: \.element.id) { index, identity in
                            if index > 0 { Rule(inset: 0) }
                            AgentIdentityRow(
                                identity: identity,
                                shareAll: shareAll,
                                allowed: AgentAccess.shareAll || AgentAccess.allowed.contains(Autofill.stableID(identity.id)),
                                setAllowed: { value in
                                    var allowed = AgentAccess.allowed
                                    if value { allowed.insert(Autofill.stableID(identity.id)) }
                                    else { allowed.remove(Autofill.stableID(identity.id)) }
                                    AgentAccess.allowed = allowed
                                    policyRevision += 1
                                }
                            )
                        }
                    }
                }

                if !filteredCards.isEmpty {
                    Rule(inset: 0)
                    Caption("Cards")
                    VStack(spacing: 0) {
                        ForEach(Array(filteredCards.enumerated()), id: \.element.id) { index, card in
                            if index > 0 { Rule(inset: 0) }
                            AgentCardRow(
                                card: card,
                                shareAll: shareAll,
                                allowed: AgentAccess.shareAll || AgentAccess.allowed.contains(Autofill.stableID(card.id)),
                                setAllowed: { value in
                                    var allowed = AgentAccess.allowed
                                    if value { allowed.insert(Autofill.stableID(card.id)) }
                                    else { allowed.remove(Autofill.stableID(card.id)) }
                                    AgentAccess.allowed = allowed
                                    policyRevision += 1
                                }
                            )
                        }
                    }
                }
            }
            .padding(12)
            .id(policyRevision)
            }
        }
        .onAppear {
            shareAll = AgentAccess.shareAll
            // Fork (settings-revamp): no longer takes the keyboard on appear —
            // Settings' own search field has it, and typing goes there.
        }
        // Bitwarden publishes lock/unlock/cache changes; keeping this observed
        // makes the union list redraw without a manual refresh button.
        .onChange(of: bitwarden.state) { _, _ in list.forget(); policyRevision += 1 }
        .onChange(of: bitwarden.cacheVersion) { _, _ in list.forget(); listRevision += 1 }
        .onChange(of: onePassword.cacheVersion) { _, _ in list.forget(); policyRevision += 1 }
        .onChange(of: onePassword.isUnlocked) { _, _ in list.forget(); listRevision += 1 }
        // A login saved to the keychain while Settings is open.
        .onReceive(browser.$saved.dropFirst()) { _ in list.forget(); listRevision += 1 }
    }

    private struct AgentIdentityRow: View {
        let identity: AutofillIdentity
        let shareAll: Bool
        let allowed: Bool
        let setAllowed: (Bool) -> Void

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: "person.text.rectangle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(identity.fullName.isEmpty ? identity.name : identity.fullName)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(identity.summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                // Its name handed in (not an outer label, which the
                // switch's own `accessibilityLabel` would override).
                Switch(on: Binding(get: { allowed }, set: setAllowed),
                       label: "Share identity \(identity.name) with agents")
                    .disabled(shareAll)
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 8)
        }
    }

    private struct AgentCardRow: View {
        let card: AutofillCard
        let shareAll: Bool
        let allowed: Bool
        let setAllowed: (Bool) -> Void

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: "creditcard")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.label.isEmpty ? card.name : card.label)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(card.cardholderName.isEmpty ? card.name : card.cardholderName)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Switch(on: Binding(get: { allowed }, set: setAllowed))
                    .disabled(shareAll)
                    .accessibilityLabel("Share card \(card.name) with agents")
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 8)
        }
    }

    private struct AgentCredentialRow: View {
        let credential: Credential
        let shareAll: Bool
        let allowed: Bool
        let setAllowed: (Bool) -> Void

        private var denied: Bool { credential.agentHint == .deny }
        private var sourceSymbol: String { credential.source.symbol }

        /// Why the vault itself shares this one.
        private var allowReason: String {
            guard credential.source == .onePassword else { return "Agents folder" }
            return credential.folder?.lowercased() == "agents" ? "Agents vault" : "copper-agent tag"
        }

        /// The site, after the item's own name when it has one — a keychain
        /// login is named by its username, which the line under it says.
        private var title: String {
            AgentAccessTitle.text(name: credential.name, user: credential.user, host: credential.host)
        }

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: sourceSymbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 20)
                    .accessibilityLabel(credential.source.title)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(credential.user.isEmpty ? "No username" : credential.user)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if credential.agentHint == .allow { badge(allowReason) }
                        if denied { badge("denied in \(credential.source.title)", tint: .red.opacity(0.72)) }
                    }
                }
                Spacer(minLength: 8)
                Switch(on: Binding(
                    get: { allowed },
                    set: setAllowed
                ), label: "Share \(title), \(credential.user.isEmpty ? "no username" : credential.user), with agents")
                // A Bitwarden-side deny is a hard boundary, not merely a
                // switch that ignores clicks. `.disabled` also gives it the
                // same muted treatment as other unavailable controls.
                .disabled(shareAll || denied)
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 8)
        }

        private func badge(_ text: String, tint: Color = Palette.muted) -> some View {
            Text(text)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Palette.wash, in: Capsule())
        }
    }
}

/// The agent-access card's accounts (settings-perf): `Credentials.all()` read
/// once, kept until `forget()`, and the search over it kept per query.
@MainActor
final class AgentAccessList {
    private var all: [Credential]?
    private var last: (needle: String, rows: [Credential])?

    func forget() {
        all = nil
        last = nil
    }

    /// Nothing saved at all, whatever the search says.
    var isEmpty: Bool {
        if all == nil { all = Credentials.all() }
        return all?.isEmpty ?? true
    }

    func filtered(_ hunt: String) -> [Credential] {
        let needle = hunt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let last, last.needle == needle { return last.rows }
        let everything: [Credential]
        if let all { everything = all } else {
            everything = Credentials.all()
            all = everything
        }
        let rows = needle.isEmpty ? everything : everything.filter {
            $0.name.lowercased().contains(needle)
                || $0.host.lowercased().contains(needle)
                || $0.user.lowercased().contains(needle)
        }
        last = (needle, rows)
        return rows
    }
}

/// An Agent access row's title: the site, with the item's own name first
/// when it says something the site doesn't — not "Localhost · localhost",
/// and not a keychain login's username twice.
enum AgentAccessTitle {
    static func text(name: String, user: String, host: String) -> String {
        let plain = name.trimmingCharacters(in: .whitespaces)
        func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if plain.isEmpty || same(plain, user) || same(plain, host) || same(plain, bare) { return host }
        return "\(plain) · \(host)"
    }
}
