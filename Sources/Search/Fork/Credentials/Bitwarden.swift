import Combine
import Foundation

private extension KeyedDecodingContainer {
    func decodeLossyString(forKey key: Key) throws -> String? {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) { return String(value) }
        if let value = try? decode(Bool.self, forKey: key) { return value ? "true" : "false" }
        return nil
    }
}

/// A small, in-process boundary around the official Bitwarden CLI. The
/// unlocked cache contains the values needed for autofill, including cards,
/// identities, notes, and hidden fields; it is wiped when the vault locks.
@MainActor
final class Bitwarden: ObservableObject {
    static let shared = Bitwarden()

    enum State: Equatable {
        case missing
        case unauthenticated
        case locked(email: String?)
        case unlocked(email: String?, lastSync: Date?)
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct URI: Hashable {
        let uri: String
        let match: Int?
    }

    struct Field: Hashable {
        let name: String
        let value: String
        let hidden: Bool

        init(name: String, value: String, hidden: Bool = false) {
            self.name = name
            self.value = value
            self.hidden = hidden
        }
    }

    /// A deliberately stripped vault item. Secret values stay in `secrets`;
    /// card and identity values live in the unlocked autofill cache.
    struct Item: Hashable {
        let id: String
        let type: Int
        let name: String
        let folderId: String?
        let username: String
        let uris: [URI]
        let hasTOTP: Bool
        let hasNotes: Bool
        let fields: [Field]

        init(id: String, type: Int = 1, name: String, folderId: String?, username: String,
             uris: [URI], hasTOTP: Bool, hasNotes: Bool = false, fields: [Field]) {
            self.id = id
            self.type = type
            self.name = name
            self.folderId = folderId
            self.username = username
            self.uris = uris
            self.hasTOTP = hasTOTP
            self.hasNotes = hasNotes
            self.fields = fields
        }
    }

    struct Folder: Hashable {
        let id: String
        let name: String
    }

    @Published private(set) var state: State
    private(set) var cachedItems: [Item] = []
    private(set) var cachedFolders: [Folder] = []
    private(set) var cachedIdentities: [AutofillIdentity] = []
    private(set) var cachedCards: [AutofillCard] = []

    private var sessionKey: String?
    private struct Secret {
        var password: String?
        var totp: String?
        var notes: String?
        var hiddenFields: [String: String]
    }
    /// The secrets that came with the item list, kept only in memory and only
    /// while unlocked, so a pick fills at once instead of starting `bw` for
    /// three seconds. Same trust as the session key that decrypts them.
    private var secrets: [String: Secret] = [:]
    /// Bumped whenever the item cache changes, so an open account list can
    /// redraw itself when the vault arrives.
    @Published private(set) var cacheVersion = 0
    /// Whether an item-list refresh is running (the list may be empty meanwhile).
    var isLoadingCache: Bool { cacheRefreshInFlight }

    var counts: (logins: Int, identities: Int, cards: Int, notes: Int) {
        (
            cachedItems.count(where: { $0.type == 1 }),
            cachedIdentities.count,
            cachedCards.count,
            cachedItems.count(where: { $0.type == 2 && $0.hasNotes })
        )
    }

    /// A `bw login` holding the sign-in open for a code (BitwardenLogin.swift).
    private var interactive: Interactive?
    /// What that sign-in waits for, for Settings and `copper bitwarden` to
    /// describe; nil when nothing is pending.
    @Published private(set) var pendingLogin: PendingLogin?
    private var pendingTimer: Timer?

    private var lastActivity = Date()
    private var lastCacheRefresh = Date.distantPast
    private var cacheRefreshInFlight = false
    private var idleTimer: Timer?
    private var cacheTimer: Timer?

    private static let serverKey = "bitwarden.server"
    private static let stayUnlockedKey = "bitwarden.stayUnlocked"

    /// Keep the session across launches: the session key goes in a 0600 file
    /// beside `bw`'s own data, and the vault opens with the app — the way the
    /// keychain does. Off, the master password is asked once per launch.
    var stayUnlocked: Bool {
        get { Store.settings.object(forKey: Self.stayUnlockedKey) as? Bool ?? true }
        set {
            Store.settings.set(newValue, forKey: Self.stayUnlockedKey)
            if newValue { persistSession() } else { forgetPersistedSession() }
        }
    }

    private var sessionFile: URL { appDataURL.appendingPathComponent("session") }

    private func persistSession() {
        guard stayUnlocked, let sessionKey else { return }
        let files = FileManager.default
        try? files.createDirectory(at: appDataURL, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        try? Data(sessionKey.utf8).write(to: sessionFile, options: [.atomic])
        try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionFile.path)
    }

    private func forgetPersistedSession() {
        try? FileManager.default.removeItem(at: sessionFile)
    }

    private func restorePersistedSession() {
        guard stayUnlocked, let data = try? Data(contentsOf: sessionFile) else { return }
        let key = Self.trimTrailingNewlines(String(decoding: data, as: UTF8.self))
        if !key.isEmpty { sessionKey = key }
    }
    static let defaultServer = "https://vault.bitwarden.com"

    private init() {
        state = Self.installed ? .unauthenticated : .missing
        // What `bw` knows from last time — signed in, locked — so the picker
        // can say "Unlock Bitwarden…" from the first sign-in box, not only
        // after Settings has been opened.
        if Self.installed {
            restorePersistedSession()
            // The CLI is Node, and the vault is decoded here on the main
            // thread: at launch both wait for the restored page to draw.
            Launch.shared.whenSettled {
                Task {
                    await self.refreshStatus()
                    await self.refreshCacheIfPossible()
                }
            }
        }
    }

    // MARK: - Discovery and process boundary

    nonisolated static var installed: Bool { executableURL != nil }

    /// Where `bw` is, first match wins: `SEARCH_BW_PATH` (the daemon points
    /// its LaunchAgent at the CLI it installed), a CLI an external installer
    /// placed at `~/.local/bin/bw`, then Homebrew's, then `$PATH`.
    nonisolated static var executableURL: URL? {
        let files = FileManager.default
        if let raw = ProcessInfo.processInfo.environment["SEARCH_BW_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let path = (raw as NSString).expandingTildeInPath
            if files.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        let external = files.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/bw", isDirectory: false).path
        for path in [external, "/opt/homebrew/bin/bw", "/usr/local/bin/bw"]
        where files.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["bw"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let path = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, files.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    var appDataURL: URL {
        let suffix = Store.world.map { " (\($0))" } ?? ""
        return Store.folder.appendingPathComponent("bitwarden\(suffix)", isDirectory: true)
    }
    var appDataFolder: URL { appDataURL }

    // MARK: - A sign-in waiting for its code

    /// A session `bw login` just returned: kept, and persisted when asked to.
    func adopt(sessionKey key: String) {
        sessionKey = key
        persistSession()
    }

    /// Keep the conversation with `bw` open until the code comes — or for
    /// `pendingLoginLifetime`, after which it is let go.
    func hold(_ runner: Interactive, _ pending: PendingLogin) {
        interactive?.terminate()
        interactive = runner
        pendingLogin = pending
        pendingTimer?.invalidate()
        pendingTimer = Timer.scheduledTimer(withTimeInterval: Self.pendingLoginLifetime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelPendingLogin() }
        }
    }

    /// Whether this is the `bw` being held open right now.
    func isHolding(_ runner: Interactive) -> Bool { interactive === runner }

    /// The waiting sign-in, taken over by whoever has the code.
    func takePendingLogin() -> (Interactive, PendingLogin)? {
        guard let runner = interactive, let pending = pendingLogin else { return nil }
        interactive = nil
        pendingLogin = nil
        pendingTimer?.invalidate()
        pendingTimer = nil
        return (runner, pending)
    }

    /// Let a waiting sign-in go: `bw` ends, nothing is signed in.
    func cancelPendingLogin() {
        pendingTimer?.invalidate()
        pendingTimer = nil
        interactive?.terminate()
        interactive = nil
        pendingLogin = nil
    }

    /// Run a CLI command away from the main actor. `extra` is used for the
    /// password environment during login/unlock; secrets are never arguments.
    private func run(_ args: [String], env extra: [String: String] = [:], stdin: Data? = nil,
                     timeout: TimeInterval = 10) async throws -> Data {
        guard let executable = Self.executableURL else {
            throw Failure(message: "Bitwarden CLI is not installed")
        }

        var environment = ProcessInfo.processInfo.environment
        // Do not inherit either secret from a shell or another process. The
        // session is supplied only when Copper itself currently holds it, and
        // the password is supplied only by login/unlock below.
        environment.removeValue(forKey: "BW_SESSION")
        environment.removeValue(forKey: "BW_PASSWORD")
        environment.removeValue(forKey: "BW_CLIENTID")
        environment.removeValue(forKey: "BW_CLIENTSECRET")
        environment["BITWARDENCLI_APPDATA_DIR"] = appDataURL.path
        environment["BW_NOINTERACTION"] = "true"
        if let sessionKey { environment["BW_SESSION"] = sessionKey }
        extra.forEach { environment[$0.key] = $0.value }
        let executablePath = executable.path
        let appDataPath = appDataURL.path
        let input = stdin

        if sessionKey != nil && args.first != "status" && args.first != "--version" {
            lastActivity = Date()
        }

        let result = try await Task.detached(priority: nil) {
            try Self.execute(path: executablePath, args: args, environment: environment,
                             appDataPath: appDataPath, stdin: input, timeout: timeout)
        }.value

        guard result.status == 0 else {
            let text = String(data: result.stderr, encoding: .utf8) ?? ""
            let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            // The SDK's Rust log lines ("ERROR bitwarden_crypto::…: …") come
            // before the sentence meant for people; prefer that sentence.
            let line = lines.first(where: { !Self.isLogLine($0) }) ?? lines.first
            throw Failure(message: line ?? "Bitwarden command failed")
        }
        return result.stdout
    }

    private nonisolated static func isLogLine(_ line: String) -> Bool {
        guard let space = line.firstIndex(of: " ") else { return false }
        let level = line[..<space]
        return ["ERROR", "WARN", "INFO", "DEBUG", "TRACE"].contains(String(level)) && line.contains("::")
    }

    private struct Execution {
        let stdout: Data
        let stderr: Data
        let status: Int32
    }

    private nonisolated static func execute(path: String, args: [String], environment: [String: String],
                                            appDataPath: String, stdin: Data?, timeout: TimeInterval) throws -> Execution {
        let files = FileManager.default
        try files.createDirectory(atPath: appDataPath, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appDataPath)

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input

        try process.run()
        if let stdin {
            try input.fileHandleForWriting.write(contentsOf: stdin)
        }
        try? input.fileHandleForWriting.close()

        let group = DispatchGroup()
        var stdout = Data()
        var stderr = Data()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stdout = output.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderr = errors.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let lock = NSLock()
        var timedOut = false
        let killer = DispatchWorkItem {
            lock.lock()
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
            lock.unlock()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        process.waitUntilExit()
        killer.cancel()
        group.wait()

        lock.lock()
        let didTimeOut = timedOut
        lock.unlock()
        if didTimeOut {
            throw Failure(message: "Bitwarden command timed out")
        }
        return Execution(stdout: stdout, stderr: stderr, status: process.terminationStatus)
    }

    // MARK: - Status and account lifecycle

    private struct RawStatus: Decodable {
        let status: String
        let userEmail: String?
        let lastSync: String?
        let serverUrl: String?
    }

    /// The server `bw status` reports, nil when the CLI has none configured
    /// (it then talks to bitwarden.com). Only meaningful once `cliStatusKnown`.
    private(set) var cliServer: String?
    private(set) var cliStatusKnown = false

    /// `bw --version`, read once per executable and kept; nil while there is
    /// no CLI. `loadCLIVersion()` fills it — the property itself never
    /// starts a process, so it is safe to read from the main actor.
    private(set) var cliVersion: String?
    private var cliVersionPath: String?

    @discardableResult
    func loadCLIVersion() async -> String? {
        guard let path = Self.executableURL?.path else {
            cliVersion = nil
            cliVersionPath = nil
            return nil
        }
        if cliVersionPath == path, let cliVersion { return cliVersion }
        guard let data = try? await run(["--version"]) else { return nil }
        let text = Self.trimTrailingNewlines(String(decoding: data, as: UTF8.self))
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= 40, !text.contains("\n") else { return nil }
        cliVersion = text
        cliVersionPath = path
        return text
    }

    var serverURL: String {
        get { Store.settings.string(forKey: Self.serverKey) ?? Self.defaultServer }
        set { Store.settings.set(newValue, forKey: Self.serverKey) }
    }

    func refreshStatus() async {
        guard Self.installed else {
            state = .missing
            return
        }
        do {
            let data = try await run(["status"])
            let status = try JSONDecoder().decode(RawStatus.self, from: data)
            if let server = status.serverUrl, !server.isEmpty {
                Store.settings.set(server, forKey: Self.serverKey)
                cliServer = server
            } else {
                cliServer = nil
            }
            cliStatusKnown = true
            switch status.status.lowercased() {
            case "unlocked":
                // A relaunch must not claim an unlocked Copper session merely
                // because the CLI's status file says unlocked: our key is only
                // ever the private property above.
                if sessionKey != nil {
                    state = .unlocked(email: status.userEmail, lastSync: Self.date(status.lastSync))
                    startTimer()
                } else {
                    state = .locked(email: status.userEmail)
                }
            case "locked":
                sessionKey = nil
                clearCache()
                forgetPersistedSession()
                stopTimer()
                state = .locked(email: status.userEmail)
            default:
                sessionKey = nil
                clearCache()
                forgetPersistedSession()
                stopTimer()
                state = .unauthenticated
            }
        } catch {
            if sessionKey == nil, case .missing = state { return }
            if sessionKey == nil { state = .unauthenticated }
        }
    }

    func configure(server: String) async throws {
        let value = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw Failure(message: "Bitwarden server URL is empty") }
        _ = try await run(["config", "server", value])
        serverURL = value
    }

    // `login(email:password:otp:method:)` — the interactive sign-in that
    // takes two-step and new-device codes — lives in BitwardenLogin.swift.

    /// Personal API key login — the unattended path: no two-step prompt, no
    /// new-device email. The id and secret reach `bw` only through the
    /// child's environment. `bw login --apikey` leaves the account signed in
    /// but locked, so the caller follows with `unlock(password:)`.
    func loginWithAPIKey(clientId: String, clientSecret: String) async throws {
        let id = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty else {
            throw Failure(message: "Bitwarden API key client_id and client_secret are both required")
        }
        _ = try await run(["login", "--apikey", "--raw"],
                          env: ["BW_CLIENTID": id, "BW_CLIENTSECRET": secret], timeout: 30)
        await refreshStatus()
    }

    func unlock(password: String) async throws {
        guard !password.isEmpty else { throw Failure(message: "Bitwarden master password is required") }
        let data: Data
        do {
            data = try await run(["unlock", "--passwordenv", "BW_PASSWORD", "--raw"],
                                 env: ["BW_PASSWORD": password], timeout: 30)
        } catch let failure as Failure {
            throw Failure(message: Self.unlockMessage(failure.message))
        }
        let key = Self.session(from: data)
        guard !key.isEmpty else { throw Failure(message: "Bitwarden did not return a session") }
        sessionKey = key
        persistSession()
        await refreshStatus()
        await refreshCacheIfPossible()
    }

    /// What `bw unlock` says when the master password is wrong — the SDK's
    /// "Cryptography error, The decryption operation failed", or the older
    /// "Invalid master password." — in words; anything else as it came.
    nonisolated static func unlockMessage(_ raw: String) -> String {
        let said = raw.lowercased()
        if said.contains("decryption operation failed") || said.contains("invalid master password") || said.contains("cryptography error") {
            return "Wrong master password — try again"
        }
        return raw
    }

    func lock() async {
        let missing: Bool
        if case .missing = state { missing = true } else { missing = false }
        _ = try? await run(["lock"])
        sessionKey = nil
        clearCache()
        forgetPersistedSession()
        let email = Self.email(from: state)
        state = missing ? .missing : .locked(email: email)
        stopTimer()
    }

    func logout() async {
        cancelPendingLogin()
        let missing: Bool
        if case .missing = state { missing = true } else { missing = false }
        _ = try? await run(["logout"])
        sessionKey = nil
        clearCache()
        forgetPersistedSession()
        state = missing ? .missing : .unauthenticated
        stopTimer()
    }

    func sync() async throws {
        try await requireUnlocked()
        _ = try await run(["sync"], timeout: 30)
        await refreshStatus()
        try await refreshCache()
    }

    // MARK: - Stripped metadata and secret fetches

    private struct RawURI: Decodable {
        let uri: String?
        let match: Int?
    }

    private struct RawLogin: Decodable {
        let username: String?
        let password: String?
        let totp: String?
        let uris: [RawURI]?
    }

    private struct RawCard: Decodable {
        let cardholderName: String?
        let brand: String?
        let number: String?
        let expMonth: String?
        let expYear: String?
        let code: String?

        private enum CodingKeys: String, CodingKey {
            case cardholderName, brand, number, expMonth, expYear, code
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            cardholderName = try container.decodeLossyString(forKey: .cardholderName)
            brand = try container.decodeLossyString(forKey: .brand)
            number = try container.decodeLossyString(forKey: .number)
            expMonth = try container.decodeLossyString(forKey: .expMonth)
            expYear = try container.decodeLossyString(forKey: .expYear)
            code = try container.decodeLossyString(forKey: .code)
        }
    }

    private struct RawIdentity: Decodable {
        let title: String?
        let firstName: String?
        let middleName: String?
        let lastName: String?
        let address1: String?
        let address2: String?
        let address3: String?
        let city: String?
        let state: String?
        let postalCode: String?
        let country: String?
        let company: String?
        let email: String?
        let phone: String?
        let ssn: String?
        let username: String?
        let passportNumber: String?
        let licenseNumber: String?

        private enum CodingKeys: String, CodingKey {
            case title, firstName, middleName, lastName, address1, address2, address3
            case city, state, postalCode, country, company, email, phone, ssn, username
            case passportNumber, licenseNumber
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decodeLossyString(forKey: .title)
            firstName = try container.decodeLossyString(forKey: .firstName)
            middleName = try container.decodeLossyString(forKey: .middleName)
            lastName = try container.decodeLossyString(forKey: .lastName)
            address1 = try container.decodeLossyString(forKey: .address1)
            address2 = try container.decodeLossyString(forKey: .address2)
            address3 = try container.decodeLossyString(forKey: .address3)
            city = try container.decodeLossyString(forKey: .city)
            state = try container.decodeLossyString(forKey: .state)
            postalCode = try container.decodeLossyString(forKey: .postalCode)
            country = try container.decodeLossyString(forKey: .country)
            company = try container.decodeLossyString(forKey: .company)
            email = try container.decodeLossyString(forKey: .email)
            phone = try container.decodeLossyString(forKey: .phone)
            ssn = try container.decodeLossyString(forKey: .ssn)
            username = try container.decodeLossyString(forKey: .username)
            passportNumber = try container.decodeLossyString(forKey: .passportNumber)
            licenseNumber = try container.decodeLossyString(forKey: .licenseNumber)
        }
    }

    private struct RawField: Decodable {
        let name: String?
        let value: String?
        let boolean: Bool?
        let type: Int?

        private enum CodingKeys: String, CodingKey { case name, value, type }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            type = try container.decodeIfPresent(Int.self, forKey: .type)
            if let value = try? container.decode(String.self, forKey: .value) {
                self.value = value
                boolean = nil
            } else if let value = try? container.decode(Bool.self, forKey: .value) {
                self.value = value ? "true" : "false"
                boolean = value
            } else if let value = try? container.decode(Int.self, forKey: .value) {
                self.value = String(value)
                boolean = nil
            } else {
                self.value = nil
                boolean = nil
            }
        }
    }

    private struct RawItem: Decodable {
        let id: String?
        let type: Int?
        let name: String?
        let folderId: String?
        let notes: String?
        let login: RawLogin?
        let card: RawCard?
        let identity: RawIdentity?
        let fields: [RawField]?
    }

    func items() async throws -> [Item] {
        try await requireUnlocked()
        let data = try await run(["list", "items"])
        let rows = try JSONDecoder().decode([RawItem].self, from: data)
        var fresh: [String: Secret] = [:]
        var identities: [AutofillIdentity] = []
        var cards: [AutofillCard] = []
        let result = rows.compactMap { row -> Item? in
            guard let type = row.type, let id = row.id, !id.isEmpty else { return nil }

            var secret = Secret(password: nil, totp: nil, notes: nil, hiddenFields: [:])
            if let password = row.login?.password, !password.isEmpty {
                secret.password = password
            }
            if let totp = row.login?.totp, !totp.isEmpty {
                secret.totp = totp
            }
            if let notes = row.notes, !notes.isEmpty {
                secret.notes = notes
            }

            let uris = (row.login?.uris ?? []).compactMap { raw -> URI? in
                guard let uri = raw.uri, !uri.isEmpty else { return nil }
                return URI(uri: uri, match: raw.match)
            }
            var fields: [Field] = []
            for raw in row.fields ?? [] {
                guard let name = raw.name, !name.isEmpty else { continue }
                switch raw.type ?? 0 {
                case 0:
                    guard let value = raw.value else { continue }
                    fields.append(Field(name: name, value: value, hidden: false))
                case 1:
                    secret.hiddenFields[name] = raw.value ?? ""
                    fields.append(Field(name: name, value: "", hidden: true))
                case 2:
                    let value = raw.boolean.map { $0 ? "true" : "false" }
                        ?? (raw.value?.lowercased() == "true" ? "true" : "false")
                    fields.append(Field(name: name, value: value, hidden: false))
                default:
                    // Linked fields are references to another item, not values.
                    continue
                }
            }

            switch type {
            case 3:
                if let card = row.card {
                    cards.append(AutofillCard(
                        id: id,
                        name: row.name ?? "",
                        cardholderName: card.cardholderName ?? "",
                        brand: card.brand ?? "",
                        expMonth: card.expMonth ?? "",
                        expYear: card.expYear ?? "",
                        number: card.number ?? "",
                        code: card.code ?? ""
                    ))
                }
            case 4:
                if let identity = row.identity {
                    identities.append(AutofillIdentity(
                        id: id,
                        name: row.name ?? "",
                        title: identity.title ?? "",
                        firstName: identity.firstName ?? "",
                        middleName: identity.middleName ?? "",
                        lastName: identity.lastName ?? "",
                        username: identity.username ?? "",
                        company: identity.company ?? "",
                        email: identity.email ?? "",
                        phone: identity.phone ?? "",
                        address1: identity.address1 ?? "",
                        address2: identity.address2 ?? "",
                        address3: identity.address3 ?? "",
                        city: identity.city ?? "",
                        state: identity.state ?? "",
                        postalCode: identity.postalCode ?? "",
                        country: identity.country ?? "",
                        ssn: identity.ssn ?? "",
                        passportNumber: identity.passportNumber ?? "",
                        licenseNumber: identity.licenseNumber ?? ""
                    ))
                }
            default:
                break
            }

            if secret.password != nil || secret.totp != nil || secret.notes != nil
                || !secret.hiddenFields.isEmpty {
                fresh[id] = secret
            }
            return Item(id: id, type: type, name: row.name ?? "", folderId: row.folderId,
                        username: row.login?.username ?? "", uris: uris,
                        hasTOTP: !(row.login?.totp?.isEmpty ?? true),
                        hasNotes: secret.notes != nil, fields: fields)
        }
        cachedItems = result
        cachedIdentities = identities
        cachedCards = cards
        secrets = fresh
        cacheVersion += 1
        return result
    }

    private func clearCache() {
        cachedItems = []
        cachedFolders = []
        cachedIdentities = []
        cachedCards = []
        secrets = [:]
        cacheVersion += 1
    }

    private struct RawFolder: Decodable {
        let id: String?
        let name: String?
    }

    func folders() async throws -> [Folder] {
        try await requireUnlocked()
        let data = try await run(["list", "folders"])
        let rows = try JSONDecoder().decode([RawFolder].self, from: data)
        let result = rows.compactMap { row -> Folder? in
            guard let id = row.id, !id.isEmpty else { return nil }
            return Folder(id: id, name: row.name ?? "")
        }
        cachedFolders = result
        return result
    }

    func password(for id: String) async throws -> String {
        try await requireUnlocked()
        if let kept = secrets[id]?.password { return kept }
        let data = try await run(["get", "password", id])
        return Self.trimTrailingNewlines(String(decoding: data, as: UTF8.self))
    }

    func totp(for id: String) async throws -> String {
        try await requireUnlocked()
        // Computed here when the seed is an ordinary otpauth URI or a bare
        // base32 secret; anything else (Steam, odd parameters) is bw's job.
        if let seed = secrets[id]?.totp, let code = TOTP.code(from: seed) { return code }
        let data = try await run(["get", "totp", id])
        return Self.trimTrailingNewlines(String(decoding: data, as: UTF8.self))
    }

    func fieldValue(itemID: String, name: String) -> String? {
        guard let item = cachedItems.first(where: { $0.id == itemID }),
              let field = item.fields.first(where: { $0.name == name })
        else { return nil }
        if field.hidden { return secrets[itemID]?.hiddenFields[name] ?? "" }
        return field.value
    }

    /// The account exists in the vault with another password: change it there.
    func update(id: String, password: String) async throws {
        try await requireUnlocked()
        let current = try await run(["get", "item", id])
        guard var object = try JSONSerialization.jsonObject(with: current) as? [String: Any]
        else { throw Failure(message: "Bitwarden returned an invalid item") }
        var login = object["login"] as? [String: Any] ?? [:]
        login["password"] = password
        object["login"] = login
        let itemJSON = try JSONSerialization.data(withJSONObject: object, options: [])
        let encoded = try await run(["encode"], stdin: itemJSON)
        let value = Self.trimTrailingNewlines(String(decoding: encoded, as: UTF8.self))
        guard !value.isEmpty else { throw Failure(message: "Bitwarden did not encode the item") }
        _ = try await run(["edit", "item", id, value])
        await refreshCacheIfPossible()
    }

    func create(host: String, user: String, password: String) async throws -> String {
        try await requireUnlocked()
        let templateData = try await run(["get", "template", "item"])
        guard var object = try JSONSerialization.jsonObject(with: templateData) as? [String: Any]
        else { throw Failure(message: "Bitwarden returned an invalid item template") }
        object["type"] = 1
        object["name"] = host
        object["login"] = [
            "username": user,
            "password": password,
            "totp": NSNull(),
            "uris": [["uri": "https://\(host)", "match": NSNull()]],
        ]
        let itemJSON = try JSONSerialization.data(withJSONObject: object, options: [])
        let encoded = try await run(["encode"], stdin: itemJSON)
        let value = Self.trimTrailingNewlines(String(decoding: encoded, as: UTF8.self))
        guard !value.isEmpty else { throw Failure(message: "Bitwarden did not encode the item") }
        let created = try await run(["create", "item", value])
        guard let object = try JSONSerialization.jsonObject(with: created) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty
        else { throw Failure(message: "Bitwarden did not return the new item id") }
        await refreshCacheIfPossible()
        return id
    }

    func generate() async throws -> String {
        let data = try await run(["generate", "-ulns", "--length", "20"])
        return Self.trimTrailingNewlines(String(decoding: data, as: UTF8.self))
    }

    // MARK: - Cache and timers

    private func requireUnlocked() async throws {
        guard sessionKey != nil else { throw Failure(message: "Bitwarden is locked") }
        guard case .unlocked = state else { throw Failure(message: "Bitwarden is locked") }
    }

    private func refreshCache() async throws {
        guard !cacheRefreshInFlight else { return }
        cacheRefreshInFlight = true
        defer { cacheRefreshInFlight = false }
        _ = try await items()
        _ = try await folders()
        lastCacheRefresh = Date()
    }

    func refreshCacheIfPossible() async {
        guard sessionKey != nil else { return }
        do {
            try await refreshCache()
        } catch {
            // A successful login/unlock remains useful even if a networked
            // metadata refresh is temporarily unavailable.
        }
    }

    private func startTimer() {
        guard idleTimer == nil else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
        idleTimer?.tolerance = 10
        cacheTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.sessionKey != nil else { return }
                Task { await self.refreshCacheIfPossible() }
            }
        }
        cacheTimer?.tolerance = 30
    }

    private func stopTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
        cacheTimer?.invalidate()
        cacheTimer = nil
    }

    private func checkIdle() {
        guard sessionKey != nil else { stopTimer(); return }
        let minutes: TimeInterval
        if let value = Store.settings.object(forKey: "bitwarden.autolockMinutes") as? NSNumber {
            minutes = max(0, value.doubleValue)
        } else {
            // Never, unless asked: the vault is as open as the keychain is
            // while the Mac is unlocked, and asking for the master password
            // every quarter hour is what makes people turn a feature off.
            minutes = 0
        }
        guard minutes > 0, Date().timeIntervalSince(lastActivity) >= minutes * 60 else { return }
        Task { await lock() }
    }

    // MARK: - Small decoding helpers

    private static func date(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func session(from data: Data) -> String {
        trimTrailingNewlines(String(decoding: data, as: UTF8.self))
            .trimmingCharacters(in: .whitespaces)
    }

    private static func trimTrailingNewlines(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet.newlines)
    }

    private static func email(from state: State) -> String? {
        switch state {
        case .locked(let email), .unlocked(let email, _): return email
        case .missing, .unauthenticated: return nil
        }
    }
}
