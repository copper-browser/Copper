import AppKit
import Combine
import Foundation

/// 1Password, through the official `op` CLI — the way Bitwarden goes through
/// `bw`. Three ways in, picked by what the Mac has:
///
/// - **The 1Password app** (preferred): `op signin` asks the app, and the app
///   shows its own Touch ID / approval sheet. No password ever enters Copper;
///   the authorization lasts as long as 1Password says it does.
/// - **Account password** (no app): `op signin --raw` with the password on
///   stdin, or `op account add --signin --raw` for an account this Mac has not
///   seen (Secret Key through `OP_SECRET_KEY`). The session token goes to every
///   later `op` through `OP_SESSION_<user id>`.
/// - **Service account** (a Mac nobody sits at): an `ops_…` token, passed as
///   `OP_SERVICE_ACCOUNT_TOKEN`.
///
/// After unlock the item list is read at once (titles, usernames, sites) so the
/// picker fills straight away, then every item's details and secrets are read
/// in batches and kept in memory while unlocked — exactly Bitwarden's trust
/// model. Locking wipes all of it.
@MainActor
final class OnePassword: ObservableObject {
    static let shared = OnePassword()

    enum Mode: String, CaseIterable, Identifiable {
        case app
        case password
        case service
        var id: String { rawValue }

        var summary: String {
            switch self {
            case .app: return "through the 1Password app"
            case .password: return "with the account password"
            case .service: return "with a service account"
            }
        }
    }

    enum State: Equatable {
        /// No `op` on this Mac.
        case missing
        /// Copper has never been connected (or was signed out).
        case signedOut
        /// Connected before; the vault needs opening.
        case locked
        case unlocked(lastSync: Date?)
    }

    struct Account: Hashable, Identifiable {
        let url: String
        let email: String
        let userID: String
        let accountID: String
        let shorthand: String
        var id: String { userID }

        /// `my.1password.com`
        var host: String { OnePasswordCLI.address(url) }
        var label: String { email.isEmpty ? host : "\(email) · \(host)" }
    }

    typealias Failure = OnePasswordCLI.Failure

    @Published private(set) var state: State
    @Published private(set) var mode: Mode?
    /// Who Copper is signed in as (or was, while locked).
    @Published private(set) var account: Account?
    /// What `op account list` knows on this Mac — accounts added in the CLI or
    /// the app before Copper ever ran.
    @Published private(set) var accounts: [Account] = []
    /// The last thing that went wrong, for the card. Cleared on success.
    @Published private(set) var problem: Failure?
    /// A sign-in is running; with the app, 1Password is showing its sheet.
    @Published private(set) var signingIn = false
    @Published private(set) var cacheVersion = 0
    @Published private(set) var loadingList = false
    @Published private(set) var loadingDetails = false

    private(set) var cachedItems: [Item] = []
    private(set) var vaults: [Vault] = []
    private(set) var writableVaults: [Vault] = []
    private(set) var cachedIdentities: [AutofillIdentity] = []
    private(set) var cachedCards: [AutofillCard] = []
    private(set) var lastSync: Date?
    private(set) var cliVersion: String?

    private var secrets: [String: Secret] = [:]
    private var identitiesByItem: [String: AutofillIdentity] = [:]
    private var cardsByItem: [String: AutofillCard] = [:]
    private var sessionToken: String?
    private var serviceToken: String?
    private var keepAliveTimer: Timer?
    private var refreshTimer: Timer?
    /// Bumped by lock/sign-out so a load that was under way drops its result.
    private var generation = 0
    /// Bumped each time a session opens. A command that was started under an
    /// older session and then fails as "not signed in" says nothing about
    /// the one open now, and must not lock it.
    private var sessionEpoch = 0
    /// A read (list and details) is under way; another was asked for meanwhile.
    private var reading = false
    private var readAgain = false

    /// How many items one `op item get -` reads, and how many run at once.
    static var batchSize = 25
    static var parallelBatches = 4

    // MARK: - Settings kept in defaults (never a secret)

    private static let modeKey = "onepassword.mode"
    private static let accountKey = "onepassword.account"
    private static let emailKey = "onepassword.email"
    private static let urlKey = "onepassword.url"
    private static let stayUnlockedKey = "onepassword.stayUnlocked"
    private static let saveVaultKey = "onepassword.saveVault"
    static let defaultAddress = "my.1password.com"

    /// Keep the session across launches (on by default, like Bitwarden's).
    /// Account-password mode keeps its session token in a 0600 file under
    /// Copper's support folder; the app and a service account need no token
    /// file of their own for this, and come back without asking anything.
    var stayUnlocked: Bool {
        get { Store.settings.object(forKey: Self.stayUnlockedKey) as? Bool ?? true }
        set {
            Store.settings.set(newValue, forKey: Self.stayUnlockedKey)
            if newValue { persistSession() } else { forgetSessionFile() }
            objectWillChange.send()
        }
    }

    /// The vault new logins are created in.
    var saveVault: Vault? {
        let pool = writableVaults
        if let id = Store.settings.string(forKey: Self.saveVaultKey), let kept = pool.first(where: { $0.id == id }) {
            return kept
        }
        for name in ["Private", "Personal", "Employee"] {
            if let vault = pool.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return vault }
        }
        return pool.first
    }

    func setSaveVault(_ vault: Vault) {
        Store.settings.set(vault.id, forKey: Self.saveVaultKey)
        objectWillChange.send()
    }

    var folder: URL {
        let suffix = Store.world.map { " (\($0))" } ?? ""
        return Store.folder.appendingPathComponent("1password\(suffix)", isDirectory: true)
    }
    private var sessionFile: URL { folder.appendingPathComponent("session") }
    private var serviceFile: URL { folder.appendingPathComponent("service-account") }

    static var installed: Bool { OnePasswordCLI.executableURL != nil }
    static var appInstalled: Bool { OnePasswordCLI.appURL != nil }

    var isUnlocked: Bool {
        if case .unlocked = state { return true }
        return false
    }

    var isLocked: Bool { state == .locked }

    var counts: (logins: Int, identities: Int, cards: Int) {
        (cachedItems.count(where: \.isLogin), cachedIdentities.count, cachedCards.count)
    }

    /// The list is still on its way (the picker says so).
    var isLoadingCache: Bool { loadingList }

    private init() {
        state = Self.installed ? .signedOut : .missing
        mode = Store.settings.string(forKey: Self.modeKey).flatMap(Mode.init(rawValue:))
        if let id = Store.settings.string(forKey: Self.accountKey) {
            account = Account(url: Store.settings.string(forKey: Self.urlKey) ?? "",
                              email: Store.settings.string(forKey: Self.emailKey) ?? "",
                              userID: id, accountID: "", shorthand: "")
        }
        if Self.installed {
            if mode != nil { state = .locked }
            Task { await self.start() }
        }
    }

    // MARK: - Launch

    /// What last time left: accounts known to `op`, and — with *stay
    /// unlocked* on — the vault opened again without asking anything. The app
    /// path only asks `op whoami`, which never raises the 1Password sheet.
    func start() async {
        await refreshAccounts()
        _ = await loadCLIVersion()
        guard let mode else {
            state = Self.installed ? .signedOut : .missing
            return
        }
        // Someone already unlocked (or is unlocking) while the version and
        // accounts were read: the stored session is theirs to replace.
        guard !isUnlocked, !signingIn else { return }
        state = .locked
        guard stayUnlocked else { return }
        let epoch = sessionEpoch
        switch mode {
        case .password:
            guard let token = readFile(sessionFile) else { return }
            sessionToken = token
        case .service:
            guard let token = readFile(serviceFile) else { return }
            serviceToken = token
        case .app:
            break
        }
        do {
            try await confirm()
            guard epoch == sessionEpoch, !isUnlocked else { return }
            opened()
        } catch {
            // A sign-in that finished meanwhile owns the session now.
            guard epoch == sessionEpoch, !isUnlocked else { return }
            sessionToken = nil
            if mode == .password { forgetSessionFile() }
            state = .locked
        }
    }

    @discardableResult
    func loadCLIVersion() async -> String? {
        guard let data = try? await run(["--version"], auth: false, timeout: 10) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 40 else { return nil }
        cliVersion = text
        return text
    }

    /// `op account list`: who this Mac's CLI (and app) already knows.
    func refreshAccounts() async {
        guard Self.installed else {
            state = .missing
            return
        }
        if state == .missing { state = mode == nil ? .signedOut : .locked }
        guard let data = try? await run(["account", "list", "--format", "json"], auth: false, timeout: 15) else { return }
        accounts = OnePasswordCLI.objects(in: data).compactMap(Self.account(from:))
    }

    private static func account(from object: [String: Any]) -> Account? {
        guard let id = object["user_uuid"] as? String, !id.isEmpty else { return nil }
        return Account(url: object["url"] as? String ?? "", email: object["email"] as? String ?? "",
                       userID: id, accountID: object["account_uuid"] as? String ?? "",
                       shorthand: object["shorthand"] as? String ?? "")
    }

    // MARK: - The process boundary

    /// Run `op`. `auth` hands the child this mode's credential — the session
    /// token or service-account token through its environment, the account
    /// through `--account` — and only Copper's; never an argument that holds
    /// a secret. A refusal that means the session has ended locks the vault.
    @discardableResult
    func run(_ args: [String], stdin: Data? = nil, env extra: [String: String] = [:], auth: Bool = true,
             appPath: Bool = false, timeout: TimeInterval = 30) async throws -> Data {
        guard let executable = OnePasswordCLI.executableURL else {
            throw Failure(.notInstalled, OnePasswordCLI.explain(.notInstalled, raw: ""))
        }
        var arguments = args
        var additions = extra
        if auth, let mode {
            switch mode {
            case .password:
                if let sessionToken, let account { additions[OnePasswordCLI.sessionVariable(for: account.userID)] = sessionToken }
                if let account { arguments += ["--account", account.userID] }
            case .app:
                if let account { arguments += ["--account", account.userID] }
            case .service:
                if let serviceToken { additions["OP_SERVICE_ACCOUNT_TOKEN"] = serviceToken }
            }
        }
        let environment = OnePasswordCLI.environment(adding: additions)
        let epoch = sessionEpoch
        let path = executable.path
        let input = stdin
        let result = try await Task.detached(priority: .userInitiated) {
            try OnePasswordCLI.execute(path: path, args: arguments, environment: environment, stdin: input, timeout: timeout)
        }.value
        guard result.status == 0 else {
            let raw = OnePasswordCLI.message(from: result.stderr)
            let problem = OnePasswordCLI.classify(raw, appPath: appPath)
            let failure = Failure(problem, OnePasswordCLI.explain(problem, raw: raw))
            if auth, isUnlocked, epoch == sessionEpoch, problem == .notSignedIn || problem == .sessionExpired {
                expire()
            }
            throw failure
        }
        return result.stdout
    }

    /// `op whoami` with this mode's credential: who is signed in, or a throw.
    @discardableResult
    private func confirm() async throws -> Account {
        let data = try await run(["whoami", "--format", "json"], timeout: 20)
        guard let object = OnePasswordCLI.objects(in: data).first else {
            throw Failure(.other, "1Password returned an unreadable account")
        }
        let who = Account(url: object["url"] as? String ?? account?.url ?? "",
                          email: object["email"] as? String ?? "",
                          userID: object["user_uuid"] as? String ?? account?.userID ?? "",
                          accountID: object["account_uuid"] as? String ?? "",
                          shorthand: account?.shorthand ?? "")
        if mode == .service {
            let kind = (object["user_type"] as? String ?? "").uppercased()
            guard kind.isEmpty || kind.contains("SERVICE") else {
                throw Failure(.badToken, OnePasswordCLI.explain(.badToken, raw: ""))
            }
        }
        account = who
        return who
    }

    // MARK: - The three ways in

    /// Through the 1Password app: `op signin` asks the app, the app shows its
    /// own Touch ID sheet, and nothing secret passes through Copper.
    func unlockWithApp(account chosen: String? = nil) async throws {
        try await signing {
            let filter = chosen ?? account?.userID ?? (accounts.count == 1 ? accounts[0].userID : nil)
            var args = ["signin"]
            if let filter { args += ["--account", filter] }
            // Two minutes: a person is finding their finger.
            _ = try await run(args, auth: false, appPath: true, timeout: 120)
            let previous = (mode, account)
            mode = .app
            sessionToken = nil
            serviceToken = nil
            if let filter { account = accounts.first(where: { $0.userID == filter || $0.shorthand == filter || $0.email == filter }) ?? account }
            do {
                try await confirm()
            } catch {
                (mode, account) = previous
                throw error
            }
            remember()
            opened()
        }
    }

    /// An account `op` already knows, with its password on stdin. With the
    /// app integration on, `op` asks the app instead and returns no token —
    /// then this is the app path after all.
    func signIn(password: String, account chosen: String?) async throws {
        guard !password.isEmpty else { throw Failure(.wrongPassword, "Enter the account password") }
        try await signing {
            let filter = chosen ?? account?.userID ?? (accounts.count == 1 ? accounts[0].userID : nil)
            guard let filter else { throw Failure(.unknownAccount, "Choose a 1Password account first") }
            let data = try await run(["signin", "--raw", "--account", filter], stdin: Data((password + "\n").utf8),
                                     auth: false, timeout: 60)
            try await adopt(token: Self.token(from: data), filter: filter)
        }
    }

    /// A new account on this Mac: sign-in address, email, Secret Key and
    /// password. The Secret Key goes through `OP_SECRET_KEY`, the password
    /// through stdin; `op` keeps the account in its own config afterwards.
    func addAccount(address: String, email: String, secretKey: String, password: String) async throws {
        let host = OnePasswordCLI.address(address.isEmpty ? Self.defaultAddress : address)
        let who = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty, !key.isEmpty, !password.isEmpty else {
            throw Failure(.wrongPassword, "Email, Secret Key and password are all needed")
        }
        try await signing {
            let data = try await run(["account", "add", "--address", host, "--email", who, "--signin", "--raw"],
                                     stdin: Data((password + "\n").utf8), env: ["OP_SECRET_KEY": key],
                                     auth: false, timeout: 90)
            await refreshAccounts()
            let added = accounts.first(where: {
                $0.email.caseInsensitiveCompare(who) == .orderedSame && $0.host == host
            }) ?? accounts.first(where: { $0.email.caseInsensitiveCompare(who) == .orderedSame })
            guard let added else { throw Failure(.unknownAccount, "1Password added the account but didn't list it") }
            try await adopt(token: Self.token(from: data), filter: added.userID)
        }
    }

    /// A service account token (`ops_…`): read-only unless the account was
    /// given write access to a vault. Kept in a 0600 file.
    func connect(serviceToken raw: String) async throws {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("ops_"), token.count > 10 else {
            let failure = Failure(.badToken, "A service account token starts with ops_")
            problem = failure
            throw failure
        }
        try await signing {
            let previous = (mode, account, serviceToken)
            mode = .service
            serviceToken = token
            sessionToken = nil
            account = nil
            do {
                try await confirm()
            } catch {
                (mode, account, serviceToken) = previous
                throw error
            }
            writeFile(serviceFile, token)
            remember()
            opened()
        }
    }

    /// Unlock the way this Mac was connected.
    func unlock(password: String? = nil) async throws {
        switch mode {
        case .app, .none:
            try await unlockWithApp()
        case .password:
            try await signIn(password: password ?? "", account: account?.userID)
        case .service:
            guard let token = serviceToken ?? readFile(serviceFile) else {
                throw Failure(.badToken, "The service account token is gone — connect it again")
            }
            try await connect(serviceToken: token)
        }
    }

    private func signing(_ work: () async throws -> Void) async throws {
        guard !signingIn else { throw Failure(.other, "A 1Password sign-in is already running") }
        signingIn = true
        problem = nil
        defer { signingIn = false }
        do {
            try await work()
            problem = nil
        } catch let failure as Failure {
            problem = failure
            throw failure
        }
    }

    private static func token(from data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // Without --raw op prints `export OP_SESSION_x="token"`; take the value either way.
        if let open = text.firstIndex(of: "\""), let close = text.lastIndex(of: "\""), open < close {
            return String(text[text.index(after: open)..<close])
        }
        return text
    }

    private func adopt(token: String, filter: String) async throws {
        let previous = (mode, account, sessionToken)
        account = accounts.first(where: { $0.userID == filter || $0.shorthand == filter || $0.email == filter })
            ?? Account(url: "", email: "", userID: filter, accountID: "", shorthand: "")
        serviceToken = nil
        if token.isEmpty {
            // The app took the sign-in: no token, the app's authorization instead.
            mode = .app
            sessionToken = nil
        } else {
            mode = .password
            sessionToken = token
        }
        do {
            try await confirm()
        } catch {
            (mode, account, sessionToken) = previous
            throw error
        }
        persistSession()
        remember()
        opened()
    }

    /// The mode and account, for next launch. Never a token.
    private func remember() {
        Store.settings.set(mode?.rawValue, forKey: Self.modeKey)
        Store.settings.set(account?.userID, forKey: Self.accountKey)
        Store.settings.set(account?.email, forKey: Self.emailKey)
        Store.settings.set(account?.url, forKey: Self.urlKey)
    }

    private func opened() {
        sessionEpoch += 1
        state = .unlocked(lastSync: lastSync)
        problem = nil
        startTimers()
        Task { await self.load() }
    }

    // MARK: - Lock, sign out, expiry

    /// Close the vault: the cache and the session go, and `op signout` ends the
    /// session on 1Password's side too (for the app: the CLI's authorization).
    func lock() async {
        // Secrets go first: an `op signout` that hangs (up to its ten
        // seconds) must not keep the vault readable meanwhile. The session it
        // ends is handed to it explicitly, since it is already gone from here.
        let ending = (mode: mode, token: sessionToken, account: account)
        wipe()
        sessionToken = nil
        // A service token is re-read from its 0600 file on unlock.
        serviceToken = nil
        forgetSessionFile()
        state = mode == nil ? (Self.installed ? .signedOut : .missing) : .locked
        guard ending.mode == .password || ending.mode == .app else { return }
        var args = ["signout"]
        var env: [String: String] = [:]
        if let account = ending.account {
            args += ["--account", account.userID]
            if ending.mode == .password, let token = ending.token {
                env[OnePasswordCLI.sessionVariable(for: account.userID)] = token
            }
        }
        _ = try? await run(args, env: env, auth: false, timeout: 10)
    }

    /// Forget Copper's connection: lock, and drop the mode, the account and a
    /// service token. The account stays in `op`'s own config — it was the
    /// user's before Copper, and the app's.
    func signOut() async {
        await lock()
        try? FileManager.default.removeItem(at: serviceFile)
        serviceToken = nil
        mode = nil
        account = nil
        problem = nil
        for key in [Self.modeKey, Self.accountKey, Self.emailKey, Self.urlKey, Self.saveVaultKey] {
            Store.settings.removeObject(forKey: key)
        }
        state = Self.installed ? .signedOut : .missing
    }

    /// 1Password said the session is over (30 idle minutes for a password
    /// session, the app's own rules for the app): lock cleanly and say why.
    func expire() {
        guard isUnlocked else { return }
        wipe()
        sessionToken = nil
        forgetSessionFile()
        state = .locked
        problem = Failure(.sessionExpired, OnePasswordCLI.explain(.sessionExpired, raw: ""))
    }

    private func wipe() {
        generation += 1
        stopTimers()
        cachedItems = []
        vaults = []
        writableVaults = []
        cachedIdentities = []
        cachedCards = []
        identitiesByItem = [:]
        cardsByItem = [:]
        secrets = [:]
        reading = false
        readAgain = false
        loadingList = false
        loadingDetails = false
        cacheVersion += 1
    }

    // MARK: - Files (0600, never the keychain)

    private func persistSession() {
        guard stayUnlocked, mode == .password, let sessionToken else { return }
        writeFile(sessionFile, sessionToken)
    }

    private func forgetSessionFile() {
        try? FileManager.default.removeItem(at: sessionFile)
    }

    private func writeFile(_ url: URL, _ value: String) {
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        // Created 0600 before a byte is written, then filled.
        files.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.truncate(atOffset: 0)
            try? handle.write(contentsOf: Data(value.utf8))
            try? handle.close()
        }
        try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func readFile(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - Timers

    private func startTimers() {
        stopTimers()
        // op sessions end after 30 idle minutes; a light `whoami` every four
        // keeps one alive while Copper runs, and notices when it has ended.
        if mode != .service {
            keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 240, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { _ = Task { await self?.keepAlive() } }
            }
            keepAliveTimer?.tolerance = 20
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.load() } }
        }
        refreshTimer?.tolerance = 30
    }

    private func stopTimers() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// One `op whoami`. Network trouble leaves the vault open; 1Password
    /// saying "not signed in" locks it (in `run`).
    func keepAlive() async {
        guard isUnlocked else { return }
        _ = try? await confirm()
    }

    // MARK: - Reading the vault

    /// Sync now, from the card or the bench.
    func sync() async throws {
        guard isUnlocked else { throw Failure(.notSignedIn, "1Password is locked") }
        // A read that times out or fails is said on the card (`problem`):
        // Sync now used to end its spinner on "synced 1 minute ago" as if
        // it had worked (UX pass 2026-10-07).
        do {
            try await reload(force: true)
        } catch let failure as Failure {
            if isUnlocked { problem = failure }
            throw failure
        } catch {
            let failure = Failure(.other, error.localizedDescription)
            if isUnlocked { problem = failure }
            throw failure
        }
    }

    /// The list first — vaults, then every login, card and identity's title,
    /// username and sites, so the picker fills at once — then the details in
    /// the background, only for items new or changed since the last read.
    func load(force: Bool = false) async {
        try? await reload(force: force)
    }

    private func reload(force: Bool) async throws {
        guard isUnlocked else { return }
        guard !reading else {
            // Asked again mid-read (a save, Sync now): once more after this one.
            readAgain = true
            return
        }
        let started = generation
        reading = true
        loadingList = true
        cacheVersion += 1
        defer {
            if generation == started {
                reading = false
                loadingList = false
                cacheVersion += 1
                if readAgain {
                    readAgain = false
                    Task { await self.load() }
                }
            }
        }
        // The three reads at once; which vaults take a new item is settled
        // before either list is shown, so the card never flashes
        // "Read-only" in between.
        async let vaultRead = run(["vault", "list", "--format", "json"], timeout: 30)
        async let listRead = run(["item", "list", "--categories", Self.categories, "--format", "json"], timeout: 60)
        async let writableRead = writableVaultIDs()
        let vaultData = try await vaultRead
        let listData = try await listRead
        let writableIDs = await writableRead
        guard generation == started else { return }
        // Both are one JSON array. A list cut short or garbled is a failed
        // read — said on the card, the vault as it was kept — not a
        // smaller vault (UX pass 2026-10-07: half the items vanished, "ok").
        guard OnePasswordCLI.isArray(vaultData), OnePasswordCLI.isArray(listData) else {
            let failure = Failure(.other, "1Password sent a list Copper couldn't read — nothing changed; try Sync now again")
            problem = failure
            throw failure
        }
        let readable = OnePasswordCLI.objects(in: vaultData).compactMap { object -> Vault? in
            guard let id = object["id"] as? String else { return nil }
            return Vault(id: id, name: object["name"] as? String ?? "")
        }
        let writable = writableIDs.map { ids in readable.filter { ids.contains($0.id) } } ?? readable
        vaults = readable
        writableVaults = writable
        let names = Dictionary(vaults.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let previous = Dictionary(cachedItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var fresh: [Item] = []
        var stale: [Item] = []
        for object in OnePasswordCLI.objects(in: listData) {
            guard var item = Self.summary(object) else { continue }
            if item.vaultName.isEmpty, let name = names[item.vaultID] {
                item = Item(id: item.id, vaultID: item.vaultID, vaultName: name, category: item.category,
                            title: item.title, username: item.username, urls: item.urls, tags: item.tags,
                            version: item.version, hasTOTP: item.hasTOTP, fields: item.fields, detailed: false)
            }
            if !force, let kept = previous[item.id], kept.detailed, kept.version == item.version {
                fresh.append(kept)
            } else {
                fresh.append(item)
                stale.append(item)
            }
        }
        let alive = Set(fresh.map(\.id))
        secrets = secrets.filter { alive.contains($0.key) }
        identitiesByItem = identitiesByItem.filter { alive.contains($0.key) }
        cardsByItem = cardsByItem.filter { alive.contains($0.key) }
        cachedItems = fresh.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        publishAutofill()
        lastSync = Date()
        state = .unlocked(lastSync: lastSync)
        problem = nil
        loadingList = false
        cacheVersion += 1

        guard !stale.isEmpty else { return }
        await loadDetails(stale, generation: started)
    }

    /// The ids of the vaults this account may create items in; nil when
    /// op is too old for `--permission` (then every readable vault is
    /// assumed). An empty set is an answer: a read-only service account.
    private func writableVaultIDs() async -> Set<String>? {
        guard let data = try? await run(["vault", "list", "--permission", "create_items", "--format", "json"], timeout: 20) else {
            return nil
        }
        return Set(OnePasswordCLI.objects(in: data).compactMap { $0["id"] as? String })
    }

    /// `op item get - --reveal`, fed the list rows on stdin, a batch at a
    /// time and a few batches at once. Each batch lands as it comes.
    private func loadDetails(_ items: [Item], generation started: Int) async {
        loadingDetails = true
        defer { if generation == started { loadingDetails = false } }
        let batches = stride(from: 0, to: items.count, by: Self.batchSize).map {
            Array(items[$0..<min($0 + Self.batchSize, items.count)])
        }
        var index = 0
        while index < batches.count {
            let wave = Array(batches[index..<min(index + Self.parallelBatches, batches.count)])
            index += wave.count
            await withTaskGroup(of: Data?.self) { group in
                for batch in wave {
                    let input = Self.specifiers(batch)
                    group.addTask { @MainActor [weak self] in
                        try? await self?.run(["item", "get", "-", "--reveal", "--format", "json"], stdin: input, timeout: 90)
                    }
                }
                for await data in group {
                    guard generation == started, let data else { continue }
                    ingest(OnePasswordCLI.objects(in: data))
                }
            }
            guard generation == started else { return }
        }
    }

    private static func specifiers(_ items: [Item]) -> Data {
        let rows: [[String: Any]] = items.map { ["id": $0.id, "vault": ["id": $0.vaultID]] }
        return (try? JSONSerialization.data(withJSONObject: rows)) ?? Data()
    }

    private func ingest(_ objects: [[String: Any]]) {
        guard !objects.isEmpty else { return }
        var byID = Dictionary(cachedItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for object in objects {
            guard let detail = Self.detail(object) else { continue }
            var item = detail.item
            if item.vaultName.isEmpty, let known = byID[item.id] {
                item = Item(id: item.id, vaultID: item.vaultID.isEmpty ? known.vaultID : item.vaultID,
                            vaultName: known.vaultName, category: item.category, title: item.title,
                            username: item.username, urls: item.urls.isEmpty ? known.urls : item.urls,
                            tags: item.tags.isEmpty ? known.tags : item.tags, version: item.version,
                            hasTOTP: item.hasTOTP, fields: item.fields, detailed: true)
            }
            byID[item.id] = item
            secrets[item.id] = detail.secret
            if let identity = detail.identity { identitiesByItem[item.id] = identity }
            if let card = detail.card { cardsByItem[item.id] = card }
        }
        cachedItems = byID.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        publishAutofill()
        cacheVersion += 1
    }

    private func publishAutofill() {
        cachedIdentities = identitiesByItem.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        cachedCards = cardsByItem.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// One item read now — a fill that arrived before its batch did.
    private func ensureDetail(_ id: String, force: Bool = false) async throws -> Item {
        guard isUnlocked else { throw Failure(.notSignedIn, "1Password is locked") }
        guard let item = cachedItems.first(where: { $0.id == id }) else {
            throw Failure(.other, "That item isn't in 1Password any more")
        }
        if item.detailed && !force { return item }
        var args = ["item", "get", id, "--reveal", "--format", "json"]
        if !item.vaultID.isEmpty { args += ["--vault", item.vaultID] }
        let data = try await run(args, timeout: 30)
        ingest(OnePasswordCLI.objects(in: data))
        return cachedItems.first(where: { $0.id == id }) ?? item
    }

    // MARK: - Secrets, in process only

    func password(for id: String) async throws -> String {
        if secrets[id]?.password == nil { _ = try await ensureDetail(id) }
        guard let password = secrets[id]?.password, !password.isEmpty else {
            throw Failure(.other, "That 1Password item has no password")
        }
        return password
    }

    func totp(for id: String) async throws -> String {
        let item = try await ensureDetail(id)
        if let seed = secrets[id]?.totp, let code = TOTP.code(from: seed) { return code }
        guard item.hasTOTP else { throw Failure(.other, "That 1Password item has no one-time password") }
        var args = ["item", "get", id, "--otp"]
        if !item.vaultID.isEmpty { args += ["--vault", item.vaultID] }
        let data = try await run(args, timeout: 30)
        let code = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw Failure(.other, "1Password returned no one-time password") }
        return code
    }

    func fieldValue(itemID: String, name: String) -> String? {
        guard let item = cachedItems.first(where: { $0.id == itemID }),
              let field = item.fields.first(where: { $0.name == name })
        else { return nil }
        if field.hidden { return secrets[itemID]?.hidden[name] ?? "" }
        return field.value
    }

    // MARK: - Saving

    /// The same account kept for this site with another password: change it
    /// there. The item goes back through stdin as JSON, never as
    /// `password=…` arguments. An item holding a passkey is left alone: op's
    /// JSON templates would drop the passkey.
    func update(id: String, password: String) async throws {
        guard isUnlocked else { throw Failure(.notSignedIn, "1Password is locked") }
        let vault = cachedItems.first(where: { $0.id == id })?.vaultID ?? ""
        var get = ["item", "get", id, "--reveal", "--format", "json"]
        if !vault.isEmpty { get += ["--vault", vault] }
        let data = try await run(get, timeout: 30)
        // Strictly the whole item, never a salvaged fragment: whatever goes
        // back through `op item edit` replaces the item's fields, so a
        // truncated read must stop here rather than wipe the rest.
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["id"] as? String == id, object["fields"] is [[String: Any]]
        else {
            throw Failure(.other, "1Password returned an unreadable item")
        }
        if Self.holdsPasskey(object) {
            throw Failure(.passkey, "That 1Password item holds a passkey — change its password in 1Password")
        }
        var fields = object["fields"] as? [[String: Any]] ?? []
        if let at = fields.firstIndex(where: { ($0["purpose"] as? String ?? "").uppercased() == "PASSWORD" }) {
            fields[at]["value"] = password
        } else {
            fields.append(["id": "password", "type": "CONCEALED", "purpose": "PASSWORD", "label": "password", "value": password])
        }
        object["fields"] = fields
        let body = try JSONSerialization.data(withJSONObject: object)
        var edit = ["item", "edit", id, "--format", "json"]
        if !vault.isEmpty { edit += ["--vault", vault] }
        _ = try await run(edit, stdin: body, timeout: 30)
        _ = try? await ensureDetail(id, force: true)
        Task { await self.load() }
    }

    /// A dev server on this Mac or the LAN speaks plain http; the item's
    /// website should open where the page was, not at an https that isn't there.
    static func scheme(for host: String) -> String {
        let value = host.lowercased()
        if value == "localhost" || value.contains(":") { return "http" }
        if [".localhost", ".local"].contains(where: { value.hasSuffix($0) }) { return "http" }
        let pieces = value.split(separator: ".")
        let numeric = pieces.count == 4 && pieces.allSatisfy { UInt8($0) != nil }
        return numeric ? "http" : "https"
    }

    static func holdsPasskey(_ object: [String: Any]) -> Bool {
        if object["passkey"] != nil || object["passkeys"] != nil { return true }
        let fields = object["fields"] as? [[String: Any]] ?? []
        return fields.contains { ($0["type"] as? String ?? "").uppercased().contains("PASSKEY") }
    }

    /// A new Login item in the chosen vault, from a JSON template on stdin.
    @discardableResult
    func create(host: String, user: String, password: String, origin: String? = nil) async throws -> String {
        guard isUnlocked else { throw Failure(.notSignedIn, "1Password is locked") }
        guard let vault = saveVault else { throw Failure(.other, "No 1Password vault Copper can save to") }
        let template: [String: Any] = [
            "title": host,
            "category": "LOGIN",
            "fields": [
                ["id": "username", "type": "STRING", "purpose": "USERNAME", "label": "username", "value": user],
                ["id": "password", "type": "CONCEALED", "purpose": "PASSWORD", "label": "password", "value": password],
            ],
            "urls": [["label": "website", "primary": true, "href": origin ?? "\(Self.scheme(for: host))://\(host)"]], // Fork (origin-save)
        ]
        let body = try JSONSerialization.data(withJSONObject: template)
        let data = try await run(["item", "create", "--vault", vault.id, "--format", "json", "-"], stdin: body, timeout: 30)
        guard let object = OnePasswordCLI.objects(in: data).first, let id = object["id"] as? String, !id.isEmpty else {
            throw Failure(.other, "1Password didn't return the new item")
        }
        try? await reload(force: false)
        return id
    }

    // MARK: - Reporting (no secret, by construction)

    var stateName: String {
        switch state {
        case .missing: return "missing"
        case .signedOut: return "signedOut"
        case .locked: return "locked"
        case .unlocked: return "unlocked"
        }
    }

    func statusReport() -> [String: Any] {
        let counts = self.counts
        var out: [String: Any] = [
            "state": stateName,
            "installed": Self.installed,
            "appInstalled": Self.appInstalled,
            "cli": OnePasswordCLI.executableURL?.path ?? NSNull(),
            "cliVersion": cliVersion ?? NSNull(),
            "mode": mode?.rawValue ?? NSNull(),
            "email": account?.email ?? NSNull(),
            "address": account?.host ?? NSNull(),
            "accounts": accounts.map { ["email": $0.email, "address": $0.host, "shorthand": $0.shorthand, "id": $0.userID] },
            "stayUnlocked": stayUnlocked,
            "signingIn": signingIn,
            "loadingList": loadingList,
            "loadingDetails": loadingDetails,
            "vaults": vaults.map(\.name),
            "writableVaults": writableVaults.map(\.name),
            "saveVault": saveVault?.name ?? NSNull(),
            "counts": ["logins": counts.logins, "identities": counts.identities, "cards": counts.cards],
            "detailed": cachedItems.count(where: \.detailed),
            "items": cachedItems.count,
            "sessionFile": FileManager.default.fileExists(atPath: sessionFile.path),
            "serviceFile": FileManager.default.fileExists(atPath: serviceFile.path),
        ]
        if let lastSync { out["lastSync"] = ISO8601DateFormatter().string(from: lastSync) }
        if let problem { out["problem"] = problem.problem.rawValue; out["problemMessage"] = problem.message }
        return out
    }

    func clearProblem() { problem = nil }

    /// Open the 1Password app (for the Developer setting).
    static func openApp() {
        if let url = OnePasswordCLI.appURL {
            // A test world notes it rather than bringing another app forward.
            if SettingsActions.probe { SettingsActions.open(url); return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
