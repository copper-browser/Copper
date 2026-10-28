import AppKit
import Combine
import CryptoKit
import Foundation

/// Copper's own update path. This deliberately does not use Updater.swift:
/// that feed and its signature belong to Search, and a fork must never let an
/// upstream release replace the browser that is running here.
///
/// The shape is: everything that can fail happens *before* anyone is asked.
/// A check that finds a newer release downloads it from the internal feed,
/// checks the archive against the manifest's SHA-256, unpacks it, and checks
/// that the bundle is Copper, is that version, and carries a signature that
/// verifies. Only then does Settings say "ready" and offer Update — which
/// backs up the tab session, swaps the verified bundle in where this one
/// runs, and relaunches. Whatever fails, fails in a sentence in Settings ›
/// Updates and a toast, never as a quiet "Updated" that was not.
@MainActor
final class Updates: ObservableObject {
    static let shared = Updates()

    struct Latest: Codable, Equatable {
        let version: String
        let releaseId: String
        let commit: String
        let publishedAt: String
        let sha256: String?
        let archiveUrl: String?
        /// What's new, as the release says it: NOTES.md's first paragraph.
        /// Optional — feeds from before it was published have none, and an
        /// `updates.json` saved by an older Copper decodes without it.
        let notes: String?
    }

    /// A release that has been downloaded, verified and unpacked, waiting for
    /// the swap. `path` is the bundle itself.
    struct Staged: Codable, Equatable {
        let version: String
        let path: String
        let sha256: String
        let at: Date
    }

    /// What the last update left behind, kept so Settings › Updates can say
    /// why an update did not land instead of a toast that is gone in two
    /// seconds. `detail` is the version on success, the reason otherwise.
    struct Outcome: Codable, Equatable {
        let ok: Bool
        let detail: String
        let at: Date
    }

    /// Written just before the swapped-in Copper is launched; the next process
    /// turns it into an Outcome by checking which version it is.
    struct Pending: Codable, Equatable {
        let version: String
        let from: String
        let at: Date
    }

    private struct Manifest: Decodable {
        let schemaVersion: Int
        let product: String
        let version: String
        let releaseId: String
        let commit: String
        let publishedAt: String
        let sha256: String?
        let archiveUrl: String?
        let notes: String?
        /// One archive per CPU, keyed `arm64` and `x86_64` — releases from the
        /// first Intel build on. The top-level `sha256` and `archiveUrl` are
        /// the arm64 archive's, for every Copper from before there was another.
        let archives: [String: Archive]?
    }

    private struct Archive: Decodable {
        let sha256: String?
        let archiveUrl: String?
    }

    /// The CPU this Copper was built for, as the manifest's `archives` key it.
    #if arch(x86_64)
    nonisolated static let arch = "x86_64"
    #else
    nonisolated static let arch = "arm64"
    #endif

    private struct Saved: Codable {
        var checkedAt: Date?
        var lastSeenVersion: String?
        var announcedVersion: String?
        var readyAnnounced: String?
        var troubleAnnounced: String?
        var latest: Latest?
        var staged: Staged?
        var outcome: Outcome?
        var pending: Pending?
    }

    enum State: Equatable {
        case idle
        case upgrading
    }

    @Published private(set) var latest: Latest?
    @Published private(set) var checkedAt: Date?
    /// Why the last check did not get an answer. Offline is the usual reason.
    @Published private(set) var error: String?
    /// Why the last update could not start or finish here, in this process.
    @Published private(set) var problem: String?
    @Published private(set) var state: State = .idle
    @Published private(set) var checking = false
    @Published private(set) var downloading = false
    /// How far the download has got, 0 to 1, while `downloading`; nil before
    /// the server has said how big it is. The sidebar's pill draws it.
    @Published private(set) var progress: Double?
    /// Why the download or the verification of the latest release failed.
    @Published private(set) var stageError: String?
    @Published private(set) var staged: Staged?
    @Published private(set) var outcome: Outcome?

    /// Bench can point this at a local HTTP server. The shipped value is the
    /// GitHub releases feed, not a user preference and not a command-line override.
    var manifestURL: URL = Updates.defaultManifestURL
    private nonisolated static let defaultManifestURL = URL(string: Setup.feed + "/copper-version.json")!
    /// Everything up to the swap: verify, back up, then stop and log what
    /// would have happened instead of replacing the bundle and quitting.
    var dryRun = false
    /// Bench, test worlds only: hold staged bundles to this requirement
    /// instead of `Signing.requirement(forBundleID:)`, so a test copy can be
    /// made to expect a certificate (`updates requirement TEXT|off`).
    var requirementOverride: String?
    /// What a staged bundle must satisfy to replace this one (Fork/Signing.swift).
    var requirement: String {
        if Store.testing, let requirementOverride { return requirementOverride }
        return Signing.requirement(forBundleID: Bundle.main.bundleIdentifier ?? Fork.bundle)
    }

    private weak var browser: Browser?
    private var timer: Timer?
    private var saved = Saved()

    var current: String { Fork.version }
    var available: Bool {
        guard let latest else { return false }
        return Self.compare(latest.version, current) > 0
    }

    /// The staged bundle is the latest release and is still where it was put.
    /// This is what puts the Update button on screen.
    var ready: Bool {
        guard available, let latest, let staged, Self.stagedMatches(staged, latest) else { return false }
        return Self.bundleVersion(at: URL(fileURLWithPath: staged.path)) == staged.version
    }

    /// The staged copy is the release the feed names now: the same version
    /// and, when the feed gives one, the same checksum — a release re-cut
    /// under the same version is a different download.
    nonisolated static func stagedMatches(_ staged: Staged, _ latest: Latest) -> Bool {
        guard staged.version == latest.version else { return false }
        guard let want = latest.sha256?.lowercased(), want.count == 64 else { return true }
        return staged.sha256.lowercased() == want
    }

    /// A Homebrew install is only a fact worth showing; the update itself no
    /// longer goes through brew. Both pieces of evidence are needed: a stray
    /// brew binary is not an install, and an abandoned Caskroom is not one
    /// either.
    var managedByBrew: Bool {
        // The cask puts Copper in /Applications; a build folder's copy or a
        // test run on the same Mac is not the cask's install.
        guard Self.caskPlace(Bundle.main.bundleURL) else { return false }
        let files = FileManager.default
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let brew = URL(fileURLWithPath: prefix).appendingPathComponent("bin/brew")
            let caskroom = URL(fileURLWithPath: prefix).appendingPathComponent("Caskroom/copper", isDirectory: true)
            if files.isExecutableFile(atPath: brew.path), files.fileExists(atPath: caskroom.path) { return true }
        }
        return false
    }

    /// Where the cask installs Copper: /Applications/Copper.app, or the
    /// user's own Applications folder.
    nonisolated static func caskPlace(_ bundle: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = bundle.resolvingSymlinksInPath().standardizedFileURL.path
        return path == "/Applications/Copper.app"
            || path == home.appendingPathComponent("Applications/Copper.app").standardizedFileURL.path
    }

    /// A test world on the real feed: it never stages those releases (see
    /// `stage`), so nothing in it should offer them either — every probe
    /// world's screenshots would carry an update pill. A world the bench
    /// pointed at a feed of its own is a test of updating, and is not quiet.
    var quietHere: Bool { Store.testing && manifestURL == Self.defaultManifestURL }

    /// The host releases come from, for the sentence under the card.
    var feedHost: String { manifestURL.host ?? Setup.feed }

    /// Where every step is written down, this process's and the bundle swap's.
    /// Settings offers to open it when an update did not finish.
    /// A test world keeps its own, in its folder: a probe's dry runs are no
    /// part of the record of anyone's install.
    nonisolated static let log: URL = logFile(world: Store.world, folder: Store.folder,
                                              home: FileManager.default.homeDirectoryForCurrentUser)

    nonisolated static func logFile(world: String?, folder: URL, home: URL) -> URL {
        world != nil ? folder.appendingPathComponent("update.log")
            : home.appendingPathComponent("Library/Logs/Copper/update.log")
    }

    /// Downloads are unpacked here, one folder per version, and the bundle an
    /// update replaced is kept in `previous` until the next one is staged.
    nonisolated static var updatesFolder: URL { Store.file("updates") }
    nonisolated static var previousFolder: URL { updatesFolder.appendingPathComponent("previous", isDirectory: true) }

    private init() {
        load()
    }

    // MARK: - launch and checking

    /// Attach once the Browser exists. The five-second delay leaves session
    /// restoration and the first window draw alone; after that, a long-lived
    /// Copper checks every six hours without asking the user to remember.
    func start(for browser: Browser) {
        self.browser = browser
        settleAtLaunch()
        guard timer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.check(force: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(force: false) }
        }
        timer?.tolerance = 15 * 60
    }

    /// `force` is the Settings/⌘K action. Automatic calls are ignored for six
    /// hours after the previous attempt, including a failed/offline attempt.
    /// A newer release is staged as soon as it is seen.
    func check(force: Bool = false) {
        AddonSync.shared.updatesChecked(force: force) // Fork (addons): addons are looked for at every update check
        guard !checking else { return }
        if !force, let checkedAt, Date().timeIntervalSince(checkedAt) < 6 * 60 * 60 { return }
        checking = true
        let url = manifestURL
        Task { [weak self] in
            let result = await Self.fetch(url)
            guard let self else { return }
            let now = Date()
            checking = false
            checkedAt = now
            saved.checkedAt = now
            switch result {
            case .success(let found):
                latest = found
                error = nil
                saved.lastSeenVersion = found.version
                saved.latest = found
                persist()
                if available {
                    stage()
                } else {
                    discardStaged()
                }
            case .failure(let sentence):
                error = sentence
                persist()
            }
        }
    }

    private enum FetchResult {
        case success(Latest)
        case failure(String)
    }

    private nonisolated static func fetch(_ url: URL) async -> FetchResult {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 8
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                return .failure("The update feed answered \(code) — try again later")
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.schemaVersion == 1, manifest.product.lowercased() == "copper",
                  !manifest.version.isEmpty, !manifest.releaseId.isEmpty
            else { return .failure("The update feed didn’t name a Copper release — try again later") }
            let notes = manifest.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
            // This Mac's archive. Only arm64 falls back to the top-level fields
            // (they have always been arm64's): an Intel Copper handed a feed
            // with no x86_64 archive gets none, and staging says so, rather
            // than swapping in a bundle this Mac can't run.
            let own = manifest.archives?[arch]
            let fallback = arch == "arm64"
            return .success(Latest(version: manifest.version, releaseId: manifest.releaseId,
                                   commit: manifest.commit, publishedAt: manifest.publishedAt,
                                   sha256: own?.sha256 ?? (fallback ? manifest.sha256 : nil),
                                   archiveUrl: own?.archiveUrl ?? (fallback ? manifest.archiveUrl : nil),
                                   notes: notes?.isEmpty == false ? notes : nil))
        } catch is URLError {
            return .failure("Couldn’t reach the update feed — check the connection, then Check now")
        } catch is DecodingError {
            return .failure("The update feed couldn’t be read — try again later")
        } catch {
            return .failure("Couldn’t check for updates — try again")
        }
    }

    // MARK: - staging: download, verify, unpack

    /// Get the latest release onto disk and verified, unless it already is.
    /// `force` re-does it: the Retry button, and the bench.
    func stage(force: Bool = false) {
        guard let latest, available, !downloading else { return }
        // A test world reaches the real feed too; it must not fill up with
        // real releases it will never install, unless the bench pointed it
        // at a feed of its own.
        if Store.testing, manifestURL == Self.defaultManifestURL, !force { return }
        if !force, let staged, Self.stagedMatches(staged, latest),
           Self.bundleVersion(at: URL(fileURLWithPath: staged.path)) == staged.version {
            // Already there and right: an older failure no longer applies.
            if stageError != nil { stageError = nil }
            return
        }
        downloading = true
        progress = nil
        stageError = nil
        let want = latest
        let folder = Self.updatesFolder
        let requirement = self.requirement
        Self.note("staging \(want.version) from \(want.archiveUrl ?? "no archive URL")")
        Task { [weak self] in
            let result = await Self.fetchAndStage(want, into: folder, requirement: requirement) { fraction in
                Task { @MainActor in Updates.shared.downloaded(fraction) }
            }
            guard let self else { return }
            downloading = false
            progress = nil
            switch result {
            case .success(let done):
                staged = done
                stageError = nil
                saved.staged = done
                persist()
                Self.note("staged \(done.version) at \(done.path)")
                if saved.readyAnnounced != done.version {
                    saved.readyAnnounced = done.version
                    persist()
                    browser?.announce("Copper \(done.version) is ready — ⌘K “Update Copper” or Settings › Updates")
                }
            case .failure(let why), .unsigned(let why):
                stageError = why
                Self.note("staging \(want.version) failed: \(why)")
                // Once per version: the feed answered a moment ago, so this is
                // not the quiet offline case, and it should be seen.
                if saved.troubleAnnounced != want.version {
                    saved.troubleAnnounced = want.version
                    persist()
                    if case .unsigned = result {
                        browser?.announce("Copper \(want.version) isn’t signed as a Copper release — see Settings › Updates")
                    } else {
                        browser?.announce("Couldn’t download Copper \(want.version) — see Settings › Updates")
                    }
                }
            }
        }
    }

    private enum StageResult {
        case success(Staged)
        case failure(String)
        /// Downloaded and intact, but refused for its signature.
        case unsigned(String)
    }

    /// A late report from a download that already finished must not put a
    /// fraction back on a pill that has moved on.
    private func downloaded(_ fraction: Double) {
        guard downloading else { return }
        progress = fraction
    }

    /// Off the main actor: the download, the hash, ditto, codesign. Nothing
    /// here touches the running bundle; a failure leaves at most a folder
    /// under `updates/` that the next attempt clears.
    private nonisolated static func fetchAndStage(_ latest: Latest, into folder: URL, requirement: String,
                                                  progress: @escaping @Sendable (Double) -> Void) async -> StageResult {
        let files = FileManager.default
        let version = latest.version
        guard let raw = latest.archiveUrl, let url = URL(string: raw) else {
            return .failure("The feed did not say where Copper \(version) is.")
        }
        guard let want = latest.sha256?.lowercased(), want.count == 64 else {
            return .failure("The feed did not publish a checksum for Copper \(version).")
        }

        // 1. Download. Two minutes is generous for six megabytes over a VPN
        // and short enough that a stalled transfer is reported, not waited on.
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 120
        let zip: URL
        let watch = DownloadWatch(progress)
        do {
            let (downloaded, response) = try await URLSession.shared.download(for: request, delegate: watch)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                try? files.removeItem(at: downloaded)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                return .failure("\(url.host ?? "The feed") answered \(code) for Copper \(version).")
            }
            zip = downloaded
        } catch {
            note("download of \(version) failed: \(error.localizedDescription)")
            return .failure("Couldn’t download Copper \(version) from \(url.host ?? "the feed") — check the connection.")
        }
        defer { try? files.removeItem(at: zip) }

        // 2. The bytes are the manifest's bytes, or they are nothing.
        guard let have = try? sha256(of: zip) else {
            return .failure("The download of Copper \(version) couldn’t be read back.")
        }
        guard have == want else {
            return .failure("The download of Copper \(version) didn’t match the feed’s checksum.")
        }

        // 3. Unpack into a folder of its own; older staged versions go.
        let target = folder.appendingPathComponent(version, isDirectory: true)
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            for entry in (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where entry.lastPathComponent != "previous" {
                try? files.removeItem(at: entry)
            }
            try files.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            return .failure("Couldn’t make room for Copper \(version): \(error.localizedDescription)")
        }
        let unpack = run("/usr/bin/ditto", ["-x", "-k", zip.path, target.path])
        guard unpack.status == 0 else {
            return .failure("The archive of Copper \(version) could not be unpacked: \(unpack.output)")
        }
        let apps = ((try? files.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "app" }
        guard let app = apps.first(where: { $0.lastPathComponent == "\(Fork.name).app" }) ?? apps.first else {
            return .failure("The archive of Copper \(version) did not contain \(Fork.name).app.")
        }

        // 4. It is Copper, it is this version, and its signature holds.
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let bundleID = info?["CFBundleIdentifier"] as? String ?? ""
        let shortVersion = info?["CFBundleShortVersionString"] as? String ?? ""
        // A copied test app has an isolated bundle id; production still
        // requires Copper's fixed identity.
        let expectedBundleID = Bundle.main.bundleIdentifier ?? Fork.bundle
        guard bundleID == expectedBundleID else {
            return .failure("The download is not Copper (bundle id \(bundleID.isEmpty ? "missing" : bundleID)).")
        }
        guard shortVersion == version else {
            return .failure("The download says it is \(shortVersion.isEmpty ? "no version" : shortVersion), not \(version).")
        }
        // Built for this CPU: an arm64 bundle swapped in on an Intel Mac
        // would never open again, and nothing could update it from there.
        let wanted = arch == "x86_64" ? NSBundleExecutableArchitectureX86_64 : NSBundleExecutableArchitectureARM64
        guard let built = Bundle(url: app)?.executableArchitectures?.map(\.intValue), built.contains(wanted) else {
            return .failure("The download of Copper \(version) isn’t built for this Mac’s processor (\(arch)).")
        }
        let signature = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard signature.status == 0 else {
            return .failure("The signature of Copper \(version) did not verify: \(signature.output)")
        }
        // Signed by Copper's own certificate, so macOS keeps this app's
        // permissions across the swap (Fork/Signing.swift). Anything else is
        // not a Copper release, however well it verifies on its own.
        if let why = Signing.unsatisfied(app, requirement: requirement) {
            note("Copper \(version) does not satisfy \(requirement): \(why)")
            return .unsigned(requirement.contains("certificate leaf")
                ? "Copper \(version) isn’t signed with Copper’s release certificate, so it won’t replace this one. Download it from github.com/copper-browser/Copper/releases instead."
                : "Copper \(version) isn’t signed as this app (\(requirement)), so it won’t replace this one.")
        }
        // Ad-hoc builds may carry a quarantine flag from the download; the
        // launch after the swap must not be Gatekeeper's to refuse.
        _ = run("/usr/bin/xattr", ["-cr", app.path])

        return .success(Staged(version: version, path: app.path, sha256: have, at: Date()))
    }

    private nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var sha = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            sha.update(data: chunk)
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A tool with its output, one line, for a sentence.
    private nonisolated static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return (process.terminationStatus, text.last ?? "")
    }

    nonisolated static func bundleVersion(at app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    private func discardStaged() {
        if let staged {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: staged.path).deletingLastPathComponent())
        }
        staged = nil
        saved.staged = nil
        persist()
    }

    // MARK: - the update: back up, swap, relaunch

    enum Refused: Error {
        case notStaged, gone(String), wrongVersion(String, String), signature(String), session(String)
        case readOnly(String), moveAside(String), moveIn(String), verify(String)

        var sentence: String {
            switch self {
            case .notStaged: return "The new Copper isn’t downloaded yet — getting it now."
            case .gone(let path): return "The downloaded Copper is no longer at \(path) — downloading it again."
            case .wrongVersion(let have, let want): return "The downloaded bundle is \(have), not \(want) — downloading again."
            case .signature(let why): return "The downloaded bundle’s signature no longer verifies: \(why)"
            case .session(let why): return "Couldn’t back up the tab session, so nothing was changed: \(why)"
            case .readOnly(let folder): return "\(folder) does not allow replacing the app from here."
            case .moveAside(let why): return "Couldn’t move the current Copper aside: \(why) If macOS asked about App Management, allow it in System Settings › Privacy & Security."
            case .moveIn(let why): return "Couldn’t move the new Copper into place, so the current one was put back: \(why)"
            case .verify(let why): return "The swap did not leave the expected version in place, so the current one was put back: \(why)"
            }
        }
    }

    /// The Update button and ⌘K. Everything risky already happened in
    /// `stage`; this re-checks the staged bundle, backs up the session, swaps
    /// the bundles where this app runs and relaunches. Any refusal is a
    /// sentence in Settings and the bundle on disk is the one that was there.
    func upgrade() {
        guard state != .upgrading, let latest, available else { return }
        state = .upgrading
        problem = nil
        do {
            guard let staged, staged.version == latest.version else { throw Refused.notStaged }
            let bundle = URL(fileURLWithPath: staged.path)
            try Self.reverify(bundle, version: staged.version, requirement: requirement)
            try backUpSession()
            let target = Bundle.main.bundleURL
            Self.note("update \(current) -> \(staged.version): swapping \(bundle.path) into \(target.path)\(dryRun ? " (dry run: stopping here)" : "")")
            if dryRun {
                state = .idle
                return
            }
            try Self.swap(bundle, into: target, keeping: Self.previousFolder, version: staged.version)
            saved.pending = Pending(version: staged.version, from: current, at: Date())
            saved.staged = nil
            persist()
            Self.note("swapped; relaunching \(target.path)")
            relaunch(target)
        } catch let refused as Refused {
            state = .idle
            problem = refused.sentence
            Self.note("update refused: \(refused.sentence)")
            switch refused {
            case .notStaged, .gone, .wrongVersion, .signature:
                // The staged copy is not to be trusted any more; fetch afresh.
                discardStaged()
                stage(force: true)
            case .session, .readOnly, .moveAside, .moveIn, .verify:
                record(Outcome(ok: false, detail: refused.sentence, at: Date()))
            }
        } catch {
            state = .idle
            problem = error.localizedDescription
            Self.note("update failed: \(error.localizedDescription)")
            record(Outcome(ok: false, detail: error.localizedDescription, at: Date()))
        }
    }

    /// The same checks as staging did, on what is on disk now.
    private nonisolated static func reverify(_ app: URL, version: String, requirement: String) throws {
        guard FileManager.default.fileExists(atPath: app.path) else { throw Refused.gone(app.path) }
        let have = bundleVersion(at: app) ?? ""
        guard have == version else { throw Refused.wrongVersion(have.isEmpty ? "unreadable" : have, version) }
        let signature = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard signature.status == 0 else { throw Refused.signature(signature.output) }
        if let why = Signing.unsatisfied(app, requirement: requirement) {
            note("\(app.path) does not satisfy \(requirement): \(why)")
            throw Refused.signature("it isn’t signed with Copper’s release certificate.")
        }
    }

    /// A copy of session.json beside it, because tabs are the thing an update
    /// must preserve. Ten copies are kept; the folder should not grow with
    /// every update. No session yet (a first run) is nothing to protect.
    private func backUpSession() throws {
        let files = FileManager.default
        let session = Store.file("session.json")
        guard files.fileExists(atPath: session.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let copy = session.deletingLastPathComponent().appendingPathComponent("session.backup-\(stamp).json")
        do {
            // A retry within the same second replaces its own copy.
            if files.fileExists(atPath: copy.path) { try files.removeItem(at: copy) }
            try files.copyItem(at: session, to: copy)
        } catch {
            throw Refused.session(error.localizedDescription)
        }
        let backups = ((try? files.contentsOfDirectory(at: session.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("session.backup-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in backups.dropFirst(10) { try? files.removeItem(at: old) }
    }

    /// Two renames on one volume: the running bundle goes to `previous`, the
    /// staged one takes its place. Either one failing puts things back as they
    /// were. The bundle that was replaced stays in `previous` until the next
    /// release is staged, in case the new one has to be put back by hand.
    private nonisolated static func swap(_ staged: URL, into target: URL, keeping previous: URL, version: String) throws {
        let files = FileManager.default
        let folder = target.deletingLastPathComponent()
        guard files.isWritableFile(atPath: folder.path) else { throw Refused.readOnly(folder.path) }
        let aside = previous.appendingPathComponent(target.lastPathComponent)
        try? files.removeItem(at: previous)
        do {
            try files.createDirectory(at: previous, withIntermediateDirectories: true)
            try files.moveItem(at: target, to: aside)
        } catch {
            throw Refused.moveAside(error.localizedDescription)
        }
        do {
            try files.moveItem(at: staged, to: target)
        } catch {
            try? files.moveItem(at: aside, to: target)
            throw Refused.moveIn(error.localizedDescription)
        }
        let have = bundleVersion(at: target) ?? ""
        guard have == version else {
            try? files.removeItem(at: target)
            try? files.moveItem(at: aside, to: target)
            throw Refused.verify("\(target.lastPathComponent) reads \(have.isEmpty ? "no version" : have), expected \(version)")
        }
        _ = run("/usr/bin/xattr", ["-cr", target.path])
        // The version folder the bundle came out of is spent.
        try? files.removeItem(at: staged.deletingLastPathComponent())
    }

    /// The relaunch, as a small POSIX `sh` script that outlives this process.
    /// Every step is a dated `copper-update:` line in update.log. Arguments:
    /// old pid, app bundle, the world's instance.lock, updates.json, the
    /// result file, the version being installed, 1 if `--headless` was on the
    /// command line, 1 to open in the background, the log, and the launchd
    /// job label ("" unless launchd itself runs this Copper).
    ///
    /// 1. Wait (≤ 60 s) for the old pid to exit.
    /// 2. A launchd job: let launchd bring it back (≤ 3 s, KeepAlive), else
    ///    `launchctl kickstart` it. Anything else: wait (≤ 10 s) until
    ///    LaunchServices stops listing the old pid, settle, then `open -n` —
    ///    a new instance, never a reopen event to a dead or probe instance —
    ///    with the world's environment, retried 3× on a non-zero exit.
    /// 3. Confirm (≤ 20 s): the world's lock has a new live holder, or the
    ///    pending marker is gone from updates.json.
    /// 4. Not confirmed and nobody holds the lock: start the executable
    ///    directly, detached, and confirm again (≤ 20 s).
    /// The instance lock makes every path safe against two of one world.
    private nonisolated static let waiterScript = #"""
    set -u
    pid=$1 app=$2 lock=$3 state=$4 result=$5 version=$6 headless=$7 background=$8 log=$9
    shift 9
    job=${1:-}

    note() {
        printf '%s copper-update: %s\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$log"
    }

    finish() {
        if [ "$1" = confirmed ]; then
            note "relaunch confirmed"
        else
            note "relaunch not confirmed: $2"
            printf 'relaunch %s %s\n' "$version" "$2" > "$result"
        fi
        exit 0
    }

    # The live pid written into the lock by its holder, if it is not the old one.
    new_holder() {
        holder=$(/usr/bin/head -n 1 "$lock" 2>/dev/null | /usr/bin/tr -cd '0-9')
        [ -n "$holder" ] && [ "$holder" != "$pid" ] && /bin/kill -0 "$holder" 2>/dev/null
    }

    confirm() {
        deadline=$(( $(/bin/date +%s) + $1 ))
        while :; do
            if new_holder; then
                note "world lock held by new pid $holder"
                return 0
            fi
            if [ -f "$state" ] && ! /usr/bin/grep -q '"pending"' "$state"; then
                note "pending update marker cleared"
                return 0
            fi
            [ "$(/bin/date +%s)" -ge "$deadline" ] && return 1
            /bin/sleep 0.1
        done
    }

    # Runs "$@", logging its stderr and exit status under a label.
    logged() {
        label=$1
        shift
        err=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/copper-update.XXXXXX") || err=/dev/null
        "$@" </dev/null >/dev/null 2>"$err"
        status=$?
        if [ "$err" != /dev/null ]; then
            while IFS= read -r line; do note "$label stderr: $line"; done < "$err"
            /bin/rm -f "$err"
        fi
        note "$label exited $status"
        return "$status"
    }

    note "waiter for pid $pid: $app${job:+ (launchd job $job)}"
    ticks=0
    while /bin/kill -0 "$pid" 2>/dev/null; do
        [ "$ticks" -ge 600 ] && finish not-confirmed "Copper $version is installed, but the old Copper did not quit within 60 seconds"
        /bin/sleep 0.1
        ticks=$((ticks + 1))
    done
    note "old pid $pid exited"

    # How long to wait for the new Copper once something was asked to start it.
    grace=2
    if [ -n "$job" ]; then
        if confirm 3; then finish confirmed; fi
        uid=$(/usr/bin/id -u)
        for domain in "gui/$uid" "user/$uid"; do
            if /bin/launchctl print "$domain/$job" >/dev/null 2>&1; then
                note "launchd did not restart $job; kickstarting $domain/$job"
                logged "launchctl kickstart" /bin/launchctl kickstart "$domain/$job" && grace=20
                break
            fi
        done
        [ "$grace" = 20 ] || note "launchd job $job not found in gui/$uid or user/$uid"
    else
        ticks=0
        while /usr/bin/lsappinfo find "pid=$pid" 2>/dev/null | /usr/bin/grep -q .; do
            if [ "$ticks" -ge 100 ]; then
                note "LaunchServices still lists pid $pid after 10s; opening a new instance anyway"
                break
            fi
            /bin/sleep 0.1
            ticks=$((ticks + 1))
        done
        /bin/sleep 0.5
        note "LaunchServices released pid $pid"

        set -- /usr/bin/open -n
        [ "$background" = 1 ] && set -- "$@" -g
        for key in SEARCH_PROBE SEARCH_MCP_PORT SEARCH_MEASURE SEARCH_HEADLESS SEARCH_HEADLESS_SIZE \
                   SEARCH_HEADLESS_WINDOW SEARCH_HEADLESS_DEBUG COPPER_AGENT_PORT COPPER_MAIN_WORLD COPPER_MAIN_WORLD_PORT; do
            eval "isset=\${$key+x} value=\${$key-}"
            [ "$isset" = x ] && set -- "$@" --env "$key=$value"
        done
        set -- "$@" "$app"
        [ "$headless" = 1 ] && set -- "$@" --args --headless
        note "opening: $*"
        attempt=1
        while :; do
            if logged "open attempt $attempt" "$@"; then grace=20; break; fi
            [ "$attempt" -ge 3 ] && break
            /bin/sleep "$attempt"
            attempt=$((attempt + 1))
        done
    fi

    if confirm "$grace"; then finish confirmed; fi
    if /usr/sbin/lsof -t "$lock" 2>/dev/null | /usr/bin/grep -q .; then
        finish not-confirmed "Copper $version is installed, but a Copper that never finished starting holds this world"
    fi
    note "no new Copper after ${grace}s and nobody holds the world lock; starting the executable directly"
    set -- /usr/bin/env -i
    for key in HOME USER LOGNAME SHELL TMPDIR PATH LANG \
               SEARCH_PROBE SEARCH_MCP_PORT SEARCH_MEASURE SEARCH_HEADLESS SEARCH_HEADLESS_SIZE \
               SEARCH_HEADLESS_WINDOW SEARCH_HEADLESS_DEBUG COPPER_AGENT_PORT COPPER_MAIN_WORLD COPPER_MAIN_WORLD_PORT; do
        eval "isset=\${$key+x} value=\${$key-}"
        [ "$isset" = x ] && set -- "$@" "$key=$value"
    done
    set -- "$@" "$app/Contents/MacOS/Copper"
    [ "$headless" = 1 ] && set -- "$@" --headless
    /usr/bin/nohup "$@" </dev/null >/dev/null 2>&1 &
    note "started $app/Contents/MacOS/Copper directly as pid $!"
    if confirm 20; then finish confirmed; fi
    finish not-confirmed "Copper $version is installed, but it did not reopen by itself after the update"
    """#

    /// The launchd job running this process, if a LaunchAgent/LaunchDaemon
    /// (a headless Mac mini, docs/headless.md) started it. LaunchServices
    /// launches every app as a launchd job too — its XPC_SERVICE_NAME is
    /// `application.<bundle id>.…` — and a shell passes its own value down,
    /// so only a job label on a process whose parent is launchd counts.
    nonisolated static func launchdJob(parent: pid_t = getppid(),
                                       environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard parent == 1, let label = environment["XPC_SERVICE_NAME"], !label.isEmpty, label != "0",
              !label.hasPrefix("application.")
        else { return nil }
        return label
    }

    /// Quit, and come back as the new one, in the same world, on the same
    /// port, headless if this run was. See `waiterScript`.
    private func relaunch(_ target: URL) {
        let oldPID = String(ProcessInfo.processInfo.processIdentifier)
        let pendingVersion = saved.pending?.version ?? current
        let job = Self.launchdJob()
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = [
            "-c", Self.waiterScript, "copper-update-waiter", oldPID, target.path,
            Store.file("instance.lock").path, Store.file("updates.json").path,
            Store.file("update-result.txt").path, pendingVersion,
            CommandLine.arguments.contains("--headless") ? "1" : "0", Headless.on ? "1" : "0",
            Self.log.path, job ?? "",
        ]
        waiter.standardInput = FileHandle.nullDevice
        waiter.standardOutput = FileHandle.nullDevice
        waiter.standardError = FileHandle.nullDevice
        do {
            try waiter.run() // its own process group: a launchd job's exit does not take it down
        } catch {
            // The swap is done; this process cannot arrange its own return.
            let why = "Copper \(pendingVersion) is installed, but the relaunch could not be started — open Copper again."
            problem = why
            record(Outcome(ok: false, detail: why, at: Date()))
            Self.note("relaunch waiter could not start: \(error.localizedDescription)")
            state = .idle
            return
        }
        Self.note("relaunch waiter pid \(waiter.processIdentifier) started for pid \(oldPID)\(job.map { " (launchd job \($0))" } ?? "")")
        browser?.announce("Relaunching as Copper \(pendingVersion)")
        NSApp.terminate(nil)
    }

    // MARK: - the next launch

    /// The process that comes back after a swap says what it is. A pending
    /// record that matches is the update landing; one that does not is the
    /// wrong bundle running, and is said so.
    private func settleAtLaunch() {
        if let pending = saved.pending {
            saved.pending = nil
            if pending.version == current {
                record(Outcome(ok: true, detail: pending.version, at: Date()))
                Self.note("launched as \(current): update from \(pending.from) landed")
                browser?.announce("Updated to \(current)")
            } else {
                let why = "\(pending.version) was put in place, but this is \(current) — the bundle at \(Bundle.main.bundleURL.path) is not the one that was installed."
                record(Outcome(ok: false, detail: why, at: Date()))
                Self.note("launched as \(current) after installing \(pending.version)")
                browser?.announce("Update did not take — see Settings › Updates")
            }
            persist()
        }
        // The relaunch waiter writes here only when the new Copper did not
        // come back by itself (`relaunch <version> <why>`); an older Copper's
        // helper left `ok …`/`failed …`. Read once.
        let legacy = Store.file("update-result.txt")
        if let text = try? String(contentsOf: legacy, encoding: .utf8) {
            try? FileManager.default.removeItem(at: legacy)
            let pieces = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1).map(String.init)
            if pieces.first == "relaunch", pieces.count >= 2 {
                let rest = pieces[1].split(separator: " ", maxSplits: 1).map(String.init)
                // A verdict about an older install than this one is stale.
                if let version = rest.first, Self.compare(version, current) >= 0 {
                    let why = rest.count > 1 ? rest[1] : "Copper \(version) is installed, but it did not reopen by itself after the update"
                    record(Outcome(ok: false, detail: "\(why). The update log has every step.", at: Date()))
                    Self.note("launched as \(current) after a relaunch that was not confirmed")
                }
            } else if pieces.first == "ok", pieces.count >= 2 {
                let version = String(pieces[1].split(separator: " ").first ?? "")
                record(Outcome(ok: version == current, detail: version == current ? version : "\(version) was reported installed, but this is \(current)", at: Date()))
            } else if pieces.first == "failed" {
                record(Outcome(ok: false, detail: pieces.count >= 2 ? pieces[1] : "no reason was recorded", at: Date()))
            }
        }
        // A staged bundle that is not newer than what is running is spent.
        if let staged, Self.compare(staged.version, current) <= 0 { discardStaged() }
    }

    private func record(_ result: Outcome) {
        outcome = result
        saved.outcome = result
        persist()
    }

    // MARK: - versions, persistence, the log

    /// Numeric dotted versions are compared component by component. Missing
    /// components are zero, so a local `1.0` build is older than every feed
    /// release. If a component is not numeric, comparing the component text is
    /// the least surprising fallback and still gives a total ordering.
    nonisolated static func compare(_ left: String, _ right: String) -> Int {
        let a = left.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let b = right.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : "0"
            let y = index < b.count ? b[index] : "0"
            if let xi = Int(x), let yi = Int(y) {
                if xi < yi { return -1 }
                if xi > yi { return 1 }
                continue
            }
            if x < y { return -1 }
            if x > y { return 1 }
        }
        return 0
    }

    private func load() {
        guard let data = try? Data(contentsOf: Store.file("updates.json")),
              let loaded = try? JSONDecoder().decode(Saved.self, from: data)
        else { return }
        saved = loaded
        checkedAt = loaded.checkedAt
        latest = loaded.latest
        outcome = loaded.outcome
        // A staged bundle counts only if it is still there and still itself.
        if let kept = loaded.staged, Self.bundleVersion(at: URL(fileURLWithPath: kept.path)) == kept.version {
            staged = kept
        } else {
            saved.staged = nil
        }
    }

    private func persist() {
        let file = Store.file("updates.json")
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// One dated line per step, appended. The log is the record of what
    /// happened to someone's install; nothing here ever truncates it.
    nonisolated static func note(_ line: String) {
        let files = FileManager.default
        try? files.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !files.fileExists(atPath: log.path) { files.createFile(atPath: log.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: log) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        let stamp = ISO8601DateFormatter().string(from: Date())
        try? handle.write(contentsOf: Data("\(stamp) copper-update: \(line)\n".utf8))
    }

    var status: [String: Any] {
        [
            "current": current,
            "latest": latest?.version ?? "",
            "available": available,
            "ready": ready,
            "downloading": downloading,
            "progress": progress ?? -1,
            "notes": latest?.notes ?? "",
            "stageError": stageError ?? "",
            "staged": staged.map { ["version": $0.version, "path": $0.path, "sha256": $0.sha256] } ?? [:],
            "managedByBrew": managedByBrew,
            "checkedAt": checkedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            "error": error ?? "",
            "problem": problem ?? "",
            "state": state == .upgrading ? "upgrading" : "idle",
            "outcome": outcome.map { ["ok": $0.ok, "detail": $0.detail, "at": ISO8601DateFormatter().string(from: $0.at)] } ?? [:],
            "log": Self.log.path,
            "requirement": requirement,
        ]
    }
}

/// Hands a download's fraction out as it goes. The async `download(for:)`
/// reports nothing until it is done; its task keeps a `Progress` all along,
/// and a task delegate is the way to reach the task. Reports are thinned to
/// whole percents — the pill redraws on each one.
private final class DownloadWatch: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var watching: NSKeyValueObservation?
    private var said = -1

    init(_ report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let seen = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            self?.moved(progress)
        }
        lock.withLock { watching = seen }
    }

    private func moved(_ progress: Progress) {
        // No total yet is nothing to draw: the pill keeps its turning ring.
        guard progress.totalUnitCount > 0 else { return }
        let fraction = min(1, max(0, progress.fractionCompleted))
        let percent = Int(fraction * 100)
        let due: Bool = lock.withLock {
            guard percent != said else { return false }
            said = percent
            return true
        }
        if due { report(fraction) }
    }
}
