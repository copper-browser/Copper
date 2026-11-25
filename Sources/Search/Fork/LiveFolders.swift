import AppKit
import Foundation

// Live folders: a sidebar folder that fills itself. The one source so far is
// GitHub — your open pull requests and the ones waiting for your review —
// read with a token you give it (pasted, or GitHub CLI's), kept in the login
// keychain and sent only to api.github.com. Every five minutes, on Refresh,
// and when the token changes. A pull request opens as a tab (or goes to the
// tab it is already open in); one that is new or changed since you last
// opened it wears a dot. Ardia's and Dia's GitHub folder, smaller: no checks,
// stacks or hover preview yet. Design: docs/live-folders.md.

struct LiveItem: Codable, Equatable, Identifiable {
    var url: String
    var title: String
    /// `owner/name`.
    var repo: String
    var number: Int
    var author: String
    /// GitHub's `updated_at`: what "changed since you looked" is read against.
    var updated: String
    var draft = false
    /// Your review is asked for.
    var review = false
    /// You opened it.
    var mine = false

    var id: String { url }
}

struct LiveFolder: Codable, Equatable, Identifiable {
    enum Show: String, Codable, CaseIterable {
        case both, reviews, mine

        var title: String {
            switch self {
            case .both: return "Review Requests and Yours"
            case .reviews: return "Review Requests"
            case .mine: return "Your Pull Requests"
            }
        }
    }

    var id = UUID()
    var name = "GitHub"
    /// The space whose column shows it.
    var space: UUID
    var show: Show = .both
    var collapsed = false
    var items: [LiveItem] = []
    /// Per pull request, the `updated` it had when you last opened it.
    var seen: [String: String] = [:]
    /// When it last filled (Unix seconds), nil before the first time.
    var refreshed: Double?
    /// Why the last refresh didn't fill it.
    var problem: String?

    func unread(_ item: LiveItem) -> Bool { seen[item.url] != item.updated }
    var unreadCount: Int { items.filter { unread($0) }.count }
}

/// GitHub's REST search, and what it answers, read. Pure but for `search`.
enum GitHubPulls {
    static let defaultAPI = URL(string: "https://api.github.com")!
    static let reviewsQuery = "is:pr is:open archived:false review-requested:@me"
    static let mineQuery = "is:pr is:open archived:false author:@me"
    /// A classic token with `repo` reads private repositories' pull requests too.
    static let tokenPage = URL(string: "https://github.com/settings/tokens/new?description=Copper%20live%20folder&scopes=repo")!

    enum Failure: Error, Equatable {
        case token
        case limited(Date?)
        case refused(String)
        case offline(String)

        var text: String {
            switch self {
            case .token: return "GitHub didn't take the token. Add a new one."
            case .limited(let until):
                guard let until else { return "GitHub's request limit is reached. Copper tries again later." }
                return "GitHub's request limit is reached. Copper tries again at \(until.formatted(date: .omitted, time: .shortened))."
            case .refused(let why): return "GitHub said: \(why)"
            case .offline(let why): return "Couldn't reach GitHub: \(why)"
            }
        }
    }

    private struct Answer: Decodable {
        struct Hit: Decodable {
            struct User: Decodable { let login: String }
            let html_url: String
            let title: String
            let number: Int
            let updated_at: String
            let draft: Bool?
            let user: User?
            let repository_url: String?
        }
        let items: [Hit]
    }

    /// One page of search hits as items.
    static func parse(_ data: Data, review: Bool = false, mine: Bool = false) throws -> [LiveItem] {
        try JSONDecoder().decode(Answer.self, from: data).items.map { hit in
            LiveItem(url: hit.html_url, title: hit.title, repo: repo(hit.repository_url, html: hit.html_url), number: hit.number,
                     author: hit.user?.login ?? "", updated: hit.updated_at, draft: hit.draft ?? false, review: review, mine: mine)
        }
    }

    /// `…/repos/owner/name` → `owner/name`, else out of the page's own address.
    static func repo(_ api: String?, html: String) -> String {
        if let api, let url = URL(string: api) {
            let parts = url.pathComponents.filter { $0 != "/" }
            if let at = parts.firstIndex(of: "repos"), parts.count >= at + 3 { return parts[at + 1] + "/" + parts[at + 2] }
        }
        let parts = URL(string: html)?.pathComponents.filter { $0 != "/" } ?? []
        return parts.count >= 2 ? parts[0] + "/" + parts[1] : ""
    }

    /// Both lists as one, a pull request once: review requests first, then
    /// yours, newest first in each.
    static func merge(reviews: [LiveItem], mine: [LiveItem]) -> [LiveItem] {
        var by: [String: LiveItem] = [:]
        for item in reviews + mine {
            if var have = by[item.url] {
                have.review = have.review || item.review
                have.mine = have.mine || item.mine
                by[item.url] = have
            } else {
                by[item.url] = item
            }
        }
        return by.values.sorted { a, b in
            if a.review != b.review { return a.review }
            return a.updated != b.updated ? a.updated > b.updated : a.url < b.url
        }
    }

    /// A tab at `address` is showing the pull request at `item`: the same
    /// page, or one of its own (its files, its commits).
    static func shows(_ address: String, _ item: String) -> Bool {
        guard address.hasPrefix(item) else { return false }
        guard let next = address.dropFirst(item.count).first else { return true }
        return "/?#".contains(next)
    }

    static func request(_ api: URL, path: String, query: [URLQueryItem] = [], token: String) -> URLRequest {
        var parts = URLComponents(url: api.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Copper", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// No cookies, no cache on disk: a token's answers stay in memory.
    private static let session = URLSession(configuration: .ephemeral)

    static func fetch(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw Failure.offline(error.localizedDescription) }
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        if code == 200 { return data }
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? "status \(code)"
        if code == 401 { throw Failure.token }
        if code == 429 || (code == 403 && (http?.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" || message.lowercased().contains("rate limit"))) {
            let reset = http?.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            let after = http?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init).map { Date().addingTimeInterval($0) }
            throw Failure.limited(after ?? reset)
        }
        throw Failure.refused(message)
    }

    static func search(api: URL, token: String, query: String, review: Bool = false, mine: Bool = false) async throws -> [LiveItem] {
        let ask = request(api, path: "search/issues", query: [
            URLQueryItem(name: "q", value: query), URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "order", value: "desc"), URLQueryItem(name: "per_page", value: "50"),
        ], token: token)
        do { return try parse(try await fetch(ask), review: review, mine: mine) } catch let failure as Failure { throw failure } catch {
            throw Failure.refused("an answer Copper couldn't read")
        }
    }

    /// Whose token it is: the login, or why not.
    static func login(api: URL, token: String) async throws -> String {
        let data = try await fetch(request(api, path: "user", token: token))
        guard let login = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["login"] as? String else {
            throw Failure.refused("an answer Copper couldn't read")
        }
        return login
    }

    /// GitHub CLI's own sign-in, if it is installed and signed in. Blocks:
    /// call it off the main thread.
    static func cliToken() -> String? {
        for path in cliPaths where FileManager.default.isExecutableFile(atPath: path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["auth", "token", "--hostname", "github.com"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { continue }
            return token
        }
        return nil
    }

    static let cliPaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
    static var cliInstalled: Bool { cliPaths.contains { FileManager.default.isExecutableFile(atPath: $0) } }
}

@MainActor
final class LiveFolders: ObservableObject {
    static let shared = LiveFolders()
    static let every: TimeInterval = 300
    private static let service = "Copper GitHub Token"
    private static let account = "live-folders"
    static let noToken = "Add a GitHub token to fill this folder."

    @Published private(set) var all: [LiveFolder] = []
    @Published private(set) var refreshing = false
    @Published private(set) var hasToken = false
    @Published private(set) var login: String?
    private(set) var log: [String] = []
    /// After a rate-limit answer: no automatic refresh before then.
    private var pausedUntil: Date?
    private var timer: Timer?
    private var started = false
    /// A test world's stand-in for api.github.com (`bench live api URL`).
    private var testAPI: String?

    private struct File: Codable {
        var folders: [LiveFolder]
        var api: String?
        var login: String?
    }

    private static var file: URL { Store.file("live-folders.json") }

    var api: URL {
        guard Store.testing else { return GitHubPulls.defaultAPI }
        let given = testAPI ?? ProcessInfo.processInfo.environment["SEARCH_GITHUB_API"]
        return given.flatMap { URL(string: $0) } ?? GitHubPulls.defaultAPI
    }

    private init() {
        if let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode(File.self, from: data) {
            all = saved.folders
            testAPI = saved.api
            login = saved.login
        }
        hasToken = token != nil
    }

    private func save() {
        let file = Self.file
        guard let data = try? JSONEncoder().encode(File(folders: all, api: testAPI, login: login)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    func note(_ text: String) {
        log.append(text)
        if log.count > 100 { log.removeFirst(log.count - 100) }
        if Headless.on { Headless.log("live folders: \(text)") }
    }

    /// Once, after the session is back: a refresh soon, then every five minutes.
    func start() {
        guard !started else { return }
        started = true
        timer = Timer.scheduledTimer(withTimeInterval: Self.every, repeats: true) { _ in
            Task { @MainActor in await LiveFolders.shared.refreshAll() }
        }
        guard !all.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Task { await self.refreshAll() } }
    }

    func folders(in space: UUID) -> [LiveFolder] { all.filter { $0.space == space } }

    func folder(_ id: UUID) -> LiveFolder? { all.first { $0.id == id } }

    // MARK: - the token

    var token: String? {
        FolderSecrets.load(service: Self.service, account: Self.account)
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Checked with GitHub before it is kept. Throws `GitHubPulls.Failure`.
    func connect(_ given: String) async throws {
        let token = given.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw GitHubPulls.Failure.token }
        let who = try await GitHubPulls.login(api: api, token: token)
        guard FolderSecrets.save(Data(token.utf8), service: Self.service, account: Self.account) else {
            throw GitHubPulls.Failure.refused("Copper couldn't keep the token in the keychain")
        }
        login = who
        hasToken = true
        pausedUntil = nil
        note("Connected as \(who)")
        save()
        await refreshAll(manual: true)
    }

    func disconnect() {
        FolderSecrets.forget(service: Self.service, account: Self.account)
        hasToken = false
        login = nil
        for i in all.indices { all[i].problem = Self.noToken }
        note("Token forgotten")
        save()
    }

    func setTestAPI(_ url: String?) {
        guard Store.testing else { return }
        testAPI = url
        save()
    }

    // MARK: - editing

    @discardableResult
    func add(in space: UUID, show: LiveFolder.Show = .both) -> LiveFolder {
        var folder = LiveFolder(space: space, show: show)
        if !hasToken { folder.problem = Self.noToken }
        all.append(folder)
        save()
        note("Added a GitHub folder")
        Task { await refreshAll(manual: true) }
        return folder
    }

    func remove(_ id: UUID) {
        all.removeAll { $0.id == id }
        save()
    }

    func toggle(_ id: UUID) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].collapsed.toggle()
        save()
    }

    func rename(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].name = clean
        save()
    }

    /// What it lists. The next fill is a first one again, so the pull
    /// requests it starts showing don't all light up.
    func set(_ id: UUID, show: LiveFolder.Show) {
        guard let i = all.firstIndex(where: { $0.id == id }), all[i].show != show else { return }
        all[i].show = show
        all[i].refreshed = nil
        save()
        Task { await refreshAll(manual: true) }
    }

    func markRead(_ item: LiveItem, in id: UUID) {
        guard let i = all.firstIndex(where: { $0.id == id }), all[i].seen[item.url] != item.updated else { return }
        all[i].seen[item.url] = item.updated
        save()
    }

    func markAllRead(_ id: UUID) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        for item in all[i].items { all[i].seen[item.url] = item.updated }
        save()
    }

    /// The tab it is already open in, else a new one.
    func open(_ item: LiveItem, in id: UUID, browser: Browser, background: Bool = false) {
        markRead(item, in: id)
        var seen: Set<Tab.ID> = []
        let every = (browser.tabs + Spaces.shared.everyTab).filter { seen.insert($0.id).inserted }
        if let tab = every.first(where: { tab in (tab.pending ?? tab.address).map { GitHubPulls.shows($0.absoluteString, item.url) } ?? false }) {
            if !background { browser.select(tab) }
            return
        }
        guard let url = URL(string: item.url) else { return }
        _ = browser.open(url, foreground: !background)
    }

    // MARK: - doors

    /// New Live Folder, from a menu or ⌘K: the folder, and the token sheet if there is no token yet.
    static func addFromMenu(in browser: Browser) {
        shared.add(in: Spaces.shared.current(in: browser))
        if !shared.hasToken { GitHubTokenSheet.show(browser: browser) }
    }

    /// ⌘K: a live folder, a shared one, the GitHub token.
    static var commands: [CommandBar.Command] {
        [
            .init(id: "live-folder", name: "New Live Folder: GitHub Pull Requests", glyph: "arrow.triangle.pull") { addFromMenu(in: $0) },
            .init(id: "shared-folder-add", name: "Add Shared Folder…", glyph: "person.2") { AddSharedFolderSheet.show(browser: $0) },
            .init(id: "live-github-token", name: "GitHub Token for Live Folders…", glyph: "key") { GitHubTokenSheet.show(browser: $0) },
        ]
    }

    // MARK: - filling

    /// One request per list for every folder, whatever their number. Not
    /// automatic ones while GitHub has asked Copper to wait.
    func refreshAll(manual: Bool = false) async {
        guard !all.isEmpty, !refreshing else { return }
        if !manual, let until = pausedUntil, Date() < until { return }
        guard let token else {
            hasToken = false
            for i in all.indices { all[i].problem = Self.noToken }
            save()
            return
        }
        refreshing = true
        defer { refreshing = false }
        let api = self.api
        var reviews: [LiveItem] = []
        var mine: [LiveItem] = []
        do {
            if all.contains(where: { $0.show != .mine }) {
                reviews = try await GitHubPulls.search(api: api, token: token, query: GitHubPulls.reviewsQuery, review: true)
            }
            if all.contains(where: { $0.show != .reviews }) {
                mine = try await GitHubPulls.search(api: api, token: token, query: GitHubPulls.mineQuery, mine: true)
            }
        } catch {
            let failure = error as? GitHubPulls.Failure ?? .offline(error.localizedDescription)
            if case .limited(let until) = failure { pausedUntil = until ?? Date().addingTimeInterval(600) }
            for i in all.indices { all[i].problem = failure.text }
            note(failure.text)
            save()
            return
        }
        pausedUntil = nil
        let now = Date().timeIntervalSince1970
        for i in all.indices {
            let items = GitHubPulls.merge(reviews: all[i].show == .mine ? [] : reviews, mine: all[i].show == .reviews ? [] : mine)
            all[i] = Self.fill(all[i], with: items, at: now)
        }
        note("Refreshed: \(reviews.count) review request\(reviews.count == 1 ? "" : "s"), \(mine.count) of yours")
        save()
    }

    /// A folder with a fresh list. Its first fill is quiet — what is there
    /// already isn't news — and a pull request that left and came back is.
    nonisolated static func fill(_ folder: LiveFolder, with items: [LiveItem], at now: Double) -> LiveFolder {
        var out = folder
        var seen = folder.seen.filter { url, _ in items.contains { $0.url == url } }
        if folder.refreshed == nil { for item in items { seen[item.url] = item.updated } }
        out.seen = seen
        out.items = items
        out.refreshed = now
        out.problem = nil
        return out
    }
}
