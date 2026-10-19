import AppKit
import Combine
import Foundation
import SwiftUI

// Native canvas links and the Share surface. The bundled page never receives
// a cloud token: it asks its host for the native sheet, and Copper's pinned
// Cloud client owns every request below.

struct CanvasJoinLink: Equatable {
    let token: String
    let cloud: String
    let name: String?
    let copper: Bool

    /// Pure parser used by LaunchServices, navigation policy, and the
    /// omnibox. It intentionally accepts only the two contract forms.
    static func parse(_ url: URL) -> CanvasJoinLink? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        let path = url.path(percentEncoded: false).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard path.count == 2, path[0].lowercased() == "join", !path[1].isEmpty else { return nil }
        let cloud: String
        let copper: Bool
        if scheme == "copper" {
            guard url.host()?.lowercased() == "canvas",
                  let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "cloud" })?.value,
                  !value.isEmpty else { return nil }
            cloud = value
            copper = true
        } else if scheme == "https", let host = url.host(), !host.isEmpty {
            let port = url.port.map { ":\($0)" } ?? ""
            cloud = host + port
            copper = false
        } else {
            return nil
        }
        let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "n" })?.value
        return CanvasJoinLink(token: path[1], cloud: cloud, name: name, copper: copper)
    }

    var normalizedCloud: String { Self.normalize(cloud) }

    /// `host[:port]` compared the way HTTPS does: case-insensitive, and the
    /// default port 443 is the same as none. A link code keeps an explicit
    /// `:443` (`copper-cloud://1.2.3.4:443/…`, so the linked host reads
    /// `1.2.3.4:443`) while a landing page served on 443 names its host
    /// without one, so both sides of every comparison go through this.
    static func normalize(_ cloud: String) -> String {
        var host = cloud.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasSuffix(":443") { host.removeLast(4) }
        return host
    }

    /// A pure check of `parse` against the contract's two forms and the
    /// shapes that must be refused — no window, no network, no probe.
    /// `bench canvas parsetest` runs this standing still.
    static func selfTest() -> [String: Any] {
        func parses(_ text: String) -> CanvasJoinLink? { URL(string: text).flatMap(parse) }
        var checks: [(String, Bool)] = []
        let copper = parses("copper://canvas/join/tok123?cloud=cloud.exowatt.com%3A8443&n=Roadmap")
        checks.append(("copper form token", copper?.token == "tok123"))
        checks.append(("copper form cloud", copper?.cloud == "cloud.exowatt.com:8443"))
        checks.append(("copper form name", copper?.name == "Roadmap"))
        checks.append(("copper form marked copper", copper?.copper == true))
        let web = parses("https://cloud.exowatt.com:8443/join/tok456")
        checks.append(("web form token", web?.token == "tok456"))
        checks.append(("web form cloud", web?.cloud == "cloud.exowatt.com:8443"))
        checks.append(("web form not copper", web?.copper == false))
        checks.append(("plain canvas address is not a join link", parses("copper://canvas/personal") == nil))
        checks.append(("copper form without cloud is refused", parses("copper://canvas/join/tok") == nil))
        checks.append(("join with no token is refused", parses("copper://canvas/join/?cloud=x") == nil))
        checks.append(("an unrelated scheme is refused", parses("mailto:join/tok?cloud=x") == nil))
        checks.append(("a bare host, no path, is refused", parses("https://cloud.exowatt.com") == nil))
        checks.append(("web form on 443 matches a link code with :443",
                       parses("https://100.57.251.123/join/tok789")?.normalizedCloud == normalize("100.57.251.123:443")))
        checks.append(("copper form without a port matches :443",
                       parses("copper://canvas/join/tok789?cloud=100.57.251.123")?.normalizedCloud == normalize("100.57.251.123:443")))
        checks.append(("another port still differs", normalize("cloud.exowatt.com:8443") != normalize("cloud.exowatt.com")))
        let failed = checks.filter { !$0.1 }.map(\.0)
        return ["passed": checks.count - failed.count, "failed": failed]
    }
}

@MainActor
enum CanvasJoinFlow {
    private static let pendingFile = Store.file("canvas/pending-join.json")
    private static var pending: CanvasJoinLink? = loadPending()

    static func handle(_ url: URL, in browser: Browser) -> Bool {
        // copper://cloud/join — a cloud's /start page (Fork/Cloud/CloudSSO.swift).
        if CloudJoin.handle(url, in: browser) { return true }
        guard let link = accepts(url) else { return false }
        Task { await join(link, in: browser) }
        return true
    }

    /// The link `handle` would take: either form, except a web landing page
    /// on another cloud, which belongs in the normal browser (the Copper
    /// form is unambiguous and always comes here).
    static func accepts(_ url: URL) -> CanvasJoinLink? {
        guard let link = CanvasJoinLink.parse(url) else { return nil }
        if !link.copper, Cloud.shared.link.map({ CanvasJoinLink.normalize($0.host) }) != link.normalizedCloud { return nil }
        return link
    }

    static func resumePending() {
        guard let link = pending, Cloud.shared.isSignedIn,
              let browser = Windows.all.first
        else { return }
        pending = nil
        removePending()
        Task { await join(link, in: browser) }
    }

    /// Opens the canvas a link names. Nil when it opened; otherwise the one
    /// sentence the window announced (also what `canvas_join` answers).
    @discardableResult
    static func join(_ link: CanvasJoinLink, in browser: Browser) async -> String? {
        func say(_ text: String) -> String { browser.announce(text); return text }
        guard let linked = Cloud.shared.link else {
            pending = link; savePending(link)
            CanvasUI.openCloudSettings(in: browser)
            return say("This canvas is on \(link.cloud). Connect to that Copper Cloud to open it.")
        }
        guard CanvasJoinLink.normalize(linked.host) == link.normalizedCloud else {
            CanvasUI.openCloudSettings(in: browser)
            return say("This canvas is on \(link.cloud). Connect to that Copper Cloud to open it.")
        }
        guard Cloud.shared.isSignedIn else {
            pending = link; savePending(link)
            CanvasUI.openCloudSettings(in: browser)
            return say("Sign in to Copper Cloud to open this canvas.")
        }
        // An instance from before share links has no such token to look up:
        // say so, rather than that a perfectly good link stopped working.
        await Cloud.shared.loadInfo()
        if Cloud.shared.supports(.shareLinks) == false { return say(Canvases.joinUnsupported) }
        do {
            let (previewData, _) = try await Cloud.shared.request("GET", "/v1/canvas-links/\(link.token)")
            let preview = Canvases.object(previewData) ?? [:]
            let member = (preview["member"] as? Bool) ?? false
            let row: [String: Any]
            if member, let id = Canvases.string(preview["canvas_id"]), let existing = Canvases.shared.entry(id) {
                // A member already: an invite to it still on screen is stale.
                if Canvases.shared.invites.contains(where: { $0.canvasId == id }) || Canvases.shared.newInvite?.canvasId == id {
                    Canvases.shared.drop(canvas: id)
                    Canvases.shared.refreshSoon()
                }
                CanvasHost.show(existing.id, in: browser, foreground: true)
                return nil
            }
            let (joined, _) = try await Cloud.shared.request("POST", "/v1/canvas-links/\(link.token)/join")
            row = Canvases.object(joined) ?? preview
            guard let entry = Canvases.shared.upsert(remote: row, account: Canvases.account ?? "") else {
                throw Cloud.Failure(status: 0, code: "shape", message: "The invite did not contain a canvas")
            }
            // The join closed any email invite to this canvas (copper-cloud
            // marks it accepted): its pill and row go now, not on the next read.
            Canvases.shared.drop(canvas: entry.id)
            await Canvases.shared.refresh()
            CanvasHost.show(entry.id, in: browser, foreground: true)
            pending = nil
            removePending()
            return nil
        } catch let failure as Cloud.Failure where failure.status == 404 {
            // 0.3.0 and later refuse a revoked or unknown token with
            // `link_not_found`; a bare `not_found` is the router's "no such
            // route" — an instance that predates share links.
            if failure.code != "link_not_found" {
                await Cloud.shared.loadInfo(force: true)
                if Cloud.shared.supports(.shareLinks) != true {
                    Cloud.shared.lacks(.shareLinks)
                    return say(Canvases.joinUnsupported)
                }
            }
            return say("This invite link no longer works — ask for a new one.")
        } catch {
            return say(Canvases.plain(error, while: .joining))
        }
    }

    private static func savePending(_ value: CanvasJoinLink) {
        let object: [String: Any] = ["token": value.token, "cloud": value.cloud, "name": value.name ?? "", "copper": value.copper]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: pendingFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: pendingFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pendingFile.path)
    }

    private static func loadPending() -> CanvasJoinLink? {
        guard let data = try? Data(contentsOf: pendingFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["token"] as? String, let cloud = object["cloud"] as? String else { return nil }
        return CanvasJoinLink(token: token, cloud: cloud, name: object["name"] as? String, copper: object["copper"] as? Bool ?? true)
    }

    private static func removePending() { try? FileManager.default.removeItem(at: pendingFile) }
}

// MARK: - cloud link storage

extension Canvases {
    private struct LinkCache: Codable { var tokens: [String: String] = [:] }
    private static var linkCacheFile: URL { folder.appendingPathComponent("share-links.json") }

    private func cachedTokens() -> [String: String] {
        guard let data = try? Data(contentsOf: Self.linkCacheFile), let value = try? JSONDecoder().decode(LinkCache.self, from: data) else { return [:] }
        return value.tokens
    }

    private func saveTokens(_ tokens: [String: String]) {
        guard let data = try? JSONEncoder().encode(LinkCache(tokens: tokens)) else { return }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? data.write(to: Self.linkCacheFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.linkCacheFile.path)
    }

    // MARK: what this cloud can do

    /// The code a refusal carries when the instance predates share links:
    /// its message is already the sentence to show.
    static let linksUnsupportedCode = "links_unsupported"

    /// The linked cloud as people read it — the default `:443` left off.
    static var cloudHost: String {
        guard let host = Cloud.shared.link?.host else { return "your Copper Cloud" }
        return host.hasSuffix(":443") ? String(host.dropLast(4)) : host
    }

    /// "runs 0.2.0" — or, when it only refused, "runs an older version".
    private static var runs: String { Cloud.shared.serverVersion.map { "runs \($0)" } ?? "runs an older version" }

    /// The Share sheet's one quiet line on an instance without share links.
    static var linksUnsupported: String {
        "Invite links need Copper Cloud \(Cloud.Feature.shareLinks.since) — \(cloudHost) \(runs). You can still invite people by email."
    }

    /// What opening a join link against such an instance says.
    static var joinUnsupported: String { "This Copper Cloud doesn't support invite links yet (\(runs))." }

    private static var linksRefused: Cloud.Failure {
        Cloud.Failure(status: 404, code: linksUnsupportedCode, message: linksUnsupported)
    }

    /// Ask the instance what it runs if nobody has yet, and refuse up front
    /// when that predates share links — no request to a route it hasn't got.
    private func requireShareLinks() async throws {
        if Cloud.shared.supports(.shareLinks) == nil { await Cloud.shared.loadInfo() }
        if Cloud.shared.supports(.shareLinks) == false { throw Canvases.linksRefused }
    }

    /// A share-link route answered `404 not_found`. 0.3.0 says that too for
    /// a canvas this account can't reach, so the version decides: asked
    /// again, and only an old (or silent) instance is taken not to have them.
    private func linksMissing(_ failure: Cloud.Failure) async -> Cloud.Failure {
        guard failure.status == 404, failure.code == "not_found" else { return failure }
        await Cloud.shared.loadInfo(force: true)
        guard Cloud.shared.supports(.shareLinks) != true else { return failure }
        Cloud.shared.lacks(.shareLinks)
        return Canvases.linksRefused
    }

    /// Returns the primary Copper form and the HTTPS landing form.
    func shareLinks(_ id: String) async throws -> (link: String, webLink: String) {
        guard let entry = entry(id), entry.isShared, let remote = entry.remoteId else {
            throw Cloud.Failure(status: 400, code: "local", message: "This canvas is on this Mac only and can't be shared")
        }
        guard cloudReady, let cloud = Cloud.shared.link else { throw Canvases.offline }
        try await requireShareLinks()
        var tokens = cachedTokens()
        let token: String
        if let saved = tokens[remote], !saved.isEmpty {
            token = saved
        } else {
            let data: Data
            do {
                (data, _) = try await Cloud.shared.request("POST", "/v1/canvases/\(remote)/links", json: [:])
            } catch let failure as Cloud.Failure {
                throw await linksMissing(failure)
            }
            guard let value = Canvases.object(data), let made = Canvases.string(value["token"]), !made.isEmpty else {
                throw Cloud.Failure(status: 0, code: "shape", message: "The server did not return an invite link")
            }
            token = made
            tokens[remote] = made
            saveTokens(tokens)
        }
        let host = cloud.host
        let name = entry.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? entry.name
        return ("copper://canvas/join/\(token)?cloud=\(host.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? host)&n=\(name)",
                "https://\(host)/join/\(token)")
    }

    func resetShareLink(_ id: String) async throws {
        guard let entry = entry(id), entry.isShared, let remote = entry.remoteId else { return }
        guard cloudReady else { throw Canvases.offline }
        try await requireShareLinks()
        do {
            _ = try await Cloud.shared.request("DELETE", "/v1/canvases/\(remote)/links")
        } catch let failure as Cloud.Failure {
            throw await linksMissing(failure)
        }
        var tokens = cachedTokens(); tokens.removeValue(forKey: remote); saveTokens(tokens)
    }

    /// The instance's people directory. Before 0.3.0 there is none: nothing
    /// is asked and nothing is said — inviting by email still works.
    func people(query: String) async throws -> [CloudPerson] {
        guard cloudReady else { throw Canvases.offline }
        if Cloud.shared.supports(.people) == nil { await Cloud.shared.loadInfo() }
        guard Cloud.shared.supports(.people) != false else { return [] }
        let data: Data
        do {
            (data, _) = try await Cloud.shared.request("GET", "/v1/people", query: ["q": query, "limit": "50"])
        } catch let failure as Cloud.Failure where failure.status == 404 && failure.code == "not_found" {
            // An instance with a directory never answers it so: this one
            // predates it, and share links came in the same release.
            Cloud.shared.lacks(.people)
            Cloud.shared.lacks(.shareLinks)
            return []
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = object["people"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = Canvases.string(row["id"]) else { return nil }
            return CloudPerson(id: id, name: Canvases.string(row["display_name"]) ?? "", email: Canvases.string(row["email"]) ?? "")
        }
    }

    func removeMember(_ id: String, member: String) async throws {
        guard let entry = entry(id), entry.isShared, let remote = entry.remoteId else { return }
        guard entry.isOwner, cloudReady else { throw Canvases.offline }
        _ = try await Cloud.shared.request("DELETE", "/v1/canvases/\(remote)/members/\(member)")
        refreshSoon()
    }

    // MARK: what an invite came to, in words

    /// The Share sheet's line under the field once an invite (or a Resend)
    /// has been answered. `name` is who it is for as the sheet knows them
    /// (the directory's name, else the address); `nobody` is true when the
    /// directory looked the address up and found no account — the only
    /// way to tell on a cloud before 0.5.0, which doesn't say.
    static func sheetLine(_ outcome: InviteOutcome, email: String, name: String, nobody: Bool) -> String {
        let host = cloudHost
        let invite = outcome.invite
        let known = invite?.inviteeKnown == true
        let who = invite?.invitee.map { $0.name.isEmpty ? name : $0.name } ?? name
        let noAccount = known ? invite?.invitee == nil : nobody
        if outcome.made {
            if noAccount { return "Invited \(email) — waiting for them to make an account on \(host)" }
            return "Invited \(who) — it's waiting for them in Copper"
        }
        switch outcome.nudged {
        case true?: return "Reminded \(who)"
        case false?:
            // A cloud reminds someone at most every 30 seconds, counting from the invite itself.
            if noAccount { return "\(email) has no account on \(host) yet — the invite is waiting for them" }
            if invite?.nudgedAt == nil { return "Invited \(who) moments ago — you can remind them in a minute" }
            return "Reminded \(who) moments ago — you can remind them again in a minute"
        case nil:
            if noAccount { return "\(email) is already invited — waiting for them to make an account on \(host)" }
            return "\(who) is already invited — it's waiting for them in Copper"
        }
    }

    /// `canvas_invite`'s answer: the same outcome, naming the canvas.
    static func inviteLine(_ outcome: InviteOutcome, email: String, canvas: String) -> String {
        let host = cloudHost
        let invite = outcome.invite
        let who = invite?.invitee.map { $0.name.isEmpty ? email : $0.name } ?? email
        let noAccount = invite?.inviteeKnown == true && invite?.invitee == nil
        let waiting = noAccount ? " — it waits for them to make an account on \(host)" : ""
        if outcome.made { return "Invited \(who) to \(canvas)\(waiting)" }
        switch outcome.nudged {
        case true?: return "Reminded \(who) about \(canvas)"
        case false?:
            if noAccount { return "\(email) was already invited to \(canvas)\(waiting)" }
            if invite?.nudgedAt == nil { return "\(who) was invited to \(canvas) moments ago — too soon to remind them" }
            return "\(who) was reminded about \(canvas) moments ago — too soon to remind them again"
        case nil: return "\(email) was already invited to \(canvas)"
        }
    }

    // MARK: refusals, in words

    /// What the sheet (or a join) was doing when something went wrong.
    enum ShareAction {
        case inviting(String)
        case reminding(String)
        case withdrawing(String)
        case linking
        case resetting
        case removing(String)
        case joining
    }

    /// One plain sentence for a sharing failure — never the server's own
    /// short code or status text ("not found", "conflict", "forbidden").
    /// Checked against copper-cloud 0.2.0's and 0.3.0's invite refusals:
    /// 400 for a bad address, the Personal canvas or inviting yourself, 409
    /// for someone already a member, 404 for a canvas this account can't
    /// reach, 403 for an action only its owner may take.
    static func plain(_ error: Error, while action: ShareAction) -> String {
        let host = cloudHost
        let fallback: String
        switch action {
        case .inviting(let email): fallback = "Couldn't invite \(email) — try again."
        case .reminding(let name): fallback = "Couldn't remind \(name) — try again."
        case .withdrawing(let name): fallback = "Couldn't withdraw the invite to \(name) — try again."
        case .linking: fallback = "Couldn't make an invite link — try again."
        case .resetting: fallback = "Couldn't reset the link — try again."
        case .removing(let name): fallback = "Couldn't remove \(name) — try again."
        case .joining: fallback = "Couldn't open that invite — try again."
        }
        guard let failure = error as? Cloud.Failure else { return fallback }
        let said = failure.message.lowercased()
        switch (failure.status, failure.code) {
        case (_, linksUnsupportedCode):
            return failure.message
        case (_, "not_signed_in"), (_, "not_linked"), (401, _):
            return "Sign in at Settings › Cloud to share canvases."
        case (_, "local"), (_, "missing"):
            return sentence(failure.message)
        case (_, "personal"):
            return "The Personal canvas can't be shared."
        case (_, "email"):
            if case .inviting(let email) = action { return "“\(email)” isn't an email address." }
            return "That isn't an email address."
        case (400, _):
            if said.contains("email") {
                if case .inviting(let email) = action { return "“\(email)” isn't an email address." }
                return "That isn't an email address."
            }
            if said.contains("already a member") { return "That's your own address — you're already on this canvas." }
            if said.contains("personal") { return "The Personal canvas can't be shared." }
            return fallback
        case (409, _), (_, "conflict"):
            if case .inviting(let email) = action { return "\(email) is already a member of this canvas." }
            if case .reminding(let name) = action { return "\(name) has already joined this canvas." }
            return "That changed somewhere else first — try again."
        case (403, _):
            switch action {
            case .inviting, .reminding: return "Only members of this canvas can invite people to it."
            case .withdrawing: return "Only the canvas's owner or whoever sent an invite can withdraw it."
            case .linking: return "Only members of this canvas can make an invite link."
            case .resetting: return "Only the canvas's owner can reset its link."
            case .removing: return "Only the canvas's owner can remove people."
            case .joining: return "\(host) won't open that canvas for this account."
            }
        case (404, _):
            if case .joining = action { return "This invite link no longer works — ask for a new one." }
            if case .withdrawing = action { return "That invite was already answered or withdrawn." }
            return "This canvas isn't on \(host) any more."
        case (429, _), (_, "rate_limited"):
            return "Too many tries — wait a minute and try again."
        case (0, "fingerprint"), (0, "tls"):
            return "\(host)'s certificate isn't the one this Mac trusts — check Settings › Cloud."
        case (0, "network"):
            return "Can't reach \(host) right now — check the connection and try again."
        case (500..., _):
            return "\(host) had a problem — try again in a moment."
        default:
            return fallback
        }
    }

    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, !".!?".contains(last) else { return trimmed }
        return trimmed + "."
    }
}

// MARK: - native share card

/// The Share sheet's state, kept outside the view so it survives the
/// sheet being drawn again (a picture, a re-render) and so `bench canvas ui
/// share …` can type into it and press its buttons the way a person would.
/// One per sheet shown: `CanvasUI.mode` makes it, and drops it on leaving.
@MainActor
final class CanvasShareModel: ObservableObject {
    let canvasId: String
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            if !query.isEmpty { said = nil }
            searchSoon()
        }
    }
    @Published private(set) var people: [Canvases.CloudPerson] = []
    /// The query `people` is the directory's answer to.
    @Published private(set) var searched: String?
    @Published private(set) var members: [Canvases.Member] = []
    /// The invites waiting on this canvas (`GET /v1/canvases/:id/invites`),
    /// newest first — with one made here a moment ago standing in until the
    /// server's copy arrives, so a row says Invited the instant it is clicked.
    @Published private(set) var pending: [Canvases.Invite] = []
    @Published private(set) var madeLink: (link: String, webLink: String)?
    @Published private(set) var copied = false
    /// Copy invite link is on its way.
    @Published private(set) var working = false
    /// Addresses (lowercased) with an invite, a reminder or a withdrawal on its way.
    @Published private(set) var acting: Set<String> = []
    /// Under the invite field: what the last invite, reminder, withdrawal or
    /// removal came to, and whether it went wrong (orange) or right (muted).
    @Published private(set) var said: (text: String, failed: Bool)?
    /// Under the link buttons: why the last copy or reset didn't work.
    @Published private(set) var linkFailure: String?
    /// Still hearing what the instance runs, the first time round.
    @Published private(set) var checking = true
    private var search: Task<Void, Never>?
    private var watching: AnyCancellable?
    /// Invites being withdrawn: gone from the rows until the server says otherwise.
    private var withdrawing: Set<String> = []

    /// A stand-in's id: an invite made here that the server hasn't answered for yet.
    private static let local = "local-"

    init(canvasId: String) {
        self.canvasId = canvasId
        Task { await self.load() }
        // Someone accepting, declining, leaving or being removed shows while the sheet is open.
        watching = Canvases.shared.$refreshed.dropFirst().sink { [weak self] _ in
            Task { @MainActor in await self?.reloadMembers() }
        }
    }

    var entry: Canvases.Entry? { Canvases.shared.entry(canvasId) }
    var canShare: Bool { (entry?.isShared ?? false) && Cloud.shared.isLinked && Cloud.shared.isSignedIn }
    /// Share links: true, false, or nil while unknown — then the buttons
    /// show and a refusal teaches the answer.
    var links: Bool? { Cloud.shared.supports(.shareLinks) }
    /// The people directory: everything but a known "no".
    var directory: Bool { Cloud.shared.supports(.people) != false }
    /// Resend and withdraw (copper-cloud 0.5.0). Before that an invite sent
    /// again reminds nobody and can't be taken back, so neither is offered:
    /// the row only says Invited.
    var reminders: Bool { Cloud.shared.supports(.inviteReminders) == true }

    func load() async {
        guard canShare else { checking = false; return }
        await Cloud.shared.loadInfo()
        checking = false
        await reloadMembers()
        // As before: with nothing typed, the directory's first page.
        if directory { await runSearch(query) }
    }

    /// The members and the invites still waiting, read again.
    func reloadMembers() async {
        if let fresh = try? await Canvases.shared.members(canvasId) { members = fresh }
        if let waiting = try? await Canvases.shared.canvasInvites(canvasId) { adopt(waiting) }
    }

    /// The server's list, keeping the stand-ins whose invite is still on its
    /// way and leaving out the ones being withdrawn.
    private func adopt(_ server: [Canvases.Invite]) {
        let keys = Set(server.map { $0.email.lowercased() })
        let standing = pending.filter { invite in
            let key = invite.email.lowercased()
            return invite.id.hasPrefix(Self.local) && acting.contains(key) && !keys.contains(key)
        }
        pending = standing + server.filter { !withdrawing.contains($0.id) }
    }

    private func searchSoon() {
        search?.cancel()
        let wanted = query
        search = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.runSearch(wanted)
        }
    }

    private func runSearch(_ text: String) async {
        guard canShare, directory else { people = []; searched = text; return }
        let found = (try? await Canvases.shared.people(query: text.trimmingCharacters(in: .whitespacesAndNewlines))) ?? []
        guard text == query else { return }
        people = found
        searched = text
        for person in found where !person.name.isEmpty { names[person.email.lowercased()] = person.name }
    }

    /// Names the directory has given this sheet, by lowercased address: an
    /// invited person keeps theirs after the search moves on.
    private var names: [String: String] = [:]

    // MARK: who is where

    /// What a person's row says, and offers.
    enum RowState: Equatable {
        case you
        case member(role: String)
        case invited(Canvases.Invite)
        case invite
    }

    func state(of email: String) -> RowState {
        let key = email.lowercased()
        if key == Cloud.shared.account?.email.lowercased() { return .you }
        if let member = members.first(where: { $0.email.lowercased() == key }) { return .member(role: member.role) }
        if let invite = pending.first(where: { $0.email.lowercased() == key }) { return .invited(invite) }
        return .invite
    }

    /// The typed text, when it is an address.
    var typedEmail: String? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Canvases.isEmail(text) ? text : nil
    }

    func isMember(_ email: String) -> Bool {
        let key = email.lowercased()
        return members.contains { $0.email.lowercased() == key }
    }

    private var isMe: Bool { typedEmail?.lowercased() == Cloud.shared.account?.email.lowercased() }

    /// A typed address that isn't yours, isn't on the canvas and isn't
    /// already a directory row below: its own row — Invite, or Invited
    /// when it already has one waiting.
    var typedRow: String? {
        guard let email = typedEmail, !isMember(email), !isMe else { return nil }
        let key = email.lowercased()
        if people.contains(where: { $0.email.lowercased() == key }) { return nil }
        return email
    }

    /// "Invite <email>": the typed row, when it has nothing waiting yet.
    var emailRow: String? {
        guard let email = typedRow, state(of: email) == .invite else { return nil }
        return email
    }

    /// The muted line instead of a row, when the typed address is already in.
    var emailNote: String? {
        guard let email = typedEmail else { return nil }
        if isMe { return "That's you — you're already on this canvas." }
        if isMember(email) { return "\(email) is already on this canvas." }
        return nil
    }

    /// Who an invite is for, in words: their account's name, the
    /// directory's, else the address itself.
    func name(for email: String, invite: Canvases.Invite? = nil) -> String {
        if let name = invite?.invitee?.name, !name.isEmpty { return name }
        let key = email.lowercased()
        if let person = people.first(where: { $0.email.lowercased() == key }), !person.name.isEmpty { return person.name }
        return names[key] ?? email
    }

    /// Resend on a waiting invite: a 0.5.0 cloud, the server's own copy, and
    /// someone to remind — an address with no account yet has no Copper
    /// to bring it up in.
    func canRemind(_ invite: Canvases.Invite) -> Bool {
        reminders && !invite.id.hasPrefix(Self.local) && !(invite.inviteeKnown && invite.invitee == nil)
    }

    /// The × on a waiting invite: a 0.5.0 cloud, the canvas's owner or whoever sent it.
    func canWithdraw(_ invite: Canvases.Invite) -> Bool {
        reminders && !invite.id.hasPrefix(Self.local) && Canvases.shared.mayWithdraw(invite, on: canvasId)
    }

    // MARK: doing

    /// Return in the field: invite the typed address, if it is one.
    func submit() {
        if let email = emailRow { invite(email) }
    }

    func invite(_ email: String) {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = address.lowercased()
        guard !address.isEmpty, !acting.contains(key) else { return }
        if case .invited(let waiting) = state(of: address) {
            if canRemind(waiting) { resend(waiting) }
            return
        }
        let who = self.name(for: address)
        // The directory looked this exact address up and found nobody: the
        // invite waits for an account with it (a cloud before 0.5.0 says
        // nothing about that itself).
        let nobody = Cloud.shared.supports(.people) == true
            && searched?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key
            && !people.contains { $0.email.lowercased() == key }
        acting.insert(key)
        said = nil
        // The row says Invited now; the server's copy takes this one's place.
        let me = Canvases.shared.identity
        let standIn = Canvases.Invite(id: Self.local + key, canvasId: canvasId, canvasName: entry?.name ?? "", from: me.name,
                                      createdAt: Date(), email: address, fromId: Canvases.account)
        pending.insert(standIn, at: 0)
        Task {
            do {
                let outcome = try await Canvases.shared.invite(canvasId, email: address)
                if let made = outcome.invite, let index = pending.firstIndex(where: { $0.id == standIn.id }) {
                    pending[index] = made
                }
                said = (Canvases.sheetLine(outcome, email: address, name: who, nobody: nobody), false)
                CanvasUI.shared.note = "Invited \(address)"
            } catch {
                pending.removeAll { $0.id == standIn.id }
                said = (Canvases.plain(error, while: .inviting(address)), true)
            }
            acting.remove(key)
            await reloadMembers()
        }
    }

    /// Resend: the same invite again, which a 0.5.0 cloud turns into a
    /// reminder on the invitee's Copper (its pill comes back up).
    func resend(_ invite: Canvases.Invite) {
        let key = invite.email.lowercased()
        guard canRemind(invite), !acting.contains(key) else { return }
        let who = self.name(for: invite.email, invite: invite)
        acting.insert(key)
        said = nil
        Task {
            do {
                let outcome = try await Canvases.shared.invite(canvasId, email: invite.email)
                said = (Canvases.sheetLine(outcome, email: invite.email, name: who, nobody: false), false)
            } catch {
                said = (Canvases.plain(error, while: .reminding(who)), true)
            }
            acting.remove(key)
            await reloadMembers()
        }
    }

    /// The ×: the invite taken back. The row goes at once, and comes back
    /// with the reason if the server says no.
    func withdraw(_ invite: Canvases.Invite) {
        let key = invite.email.lowercased()
        guard canWithdraw(invite), !acting.contains(key) else { return }
        let who = self.name(for: invite.email, invite: invite)
        acting.insert(key)
        withdrawing.insert(invite.id)
        said = nil
        pending.removeAll { $0.id == invite.id }
        Task {
            do {
                try await Canvases.shared.withdraw(canvasId, invite: invite)
                said = ("Withdrew the invite to \(who)", false)
            } catch {
                said = (Canvases.plain(error, while: .withdrawing(who)), true)
            }
            withdrawing.remove(invite.id)
            acting.remove(key)
            await reloadMembers()
        }
    }

    func copyLink() {
        guard !working else { return }
        working = true
        linkFailure = nil
        Task {
            do {
                let value = try await Canvases.shared.shareLinks(canvasId)
                madeLink = value
                copy(value.link)
                copied = true
            } catch let failure as Cloud.Failure where failure.code == Canvases.linksUnsupportedCode {
                // The note takes the buttons' place; there is nothing to add.
            } catch {
                linkFailure = Canvases.plain(error, while: .linking)
            }
            working = false
        }
    }

    func copyWebLink() {
        guard let madeLink else { return }
        copy(madeLink.webLink)
        copied = true
    }

    func reset() {
        linkFailure = nil
        Task {
            do {
                try await Canvases.shared.resetShareLink(canvasId)
                madeLink = nil
                copied = false
            } catch let failure as Cloud.Failure where failure.code == Canvases.linksUnsupportedCode {
            } catch {
                linkFailure = Canvases.plain(error, while: .resetting)
            }
        }
    }

    func remove(_ member: Canvases.Member) {
        let name = member.name.isEmpty ? member.email : member.name
        Task {
            do {
                try await Canvases.shared.removeMember(canvasId, member: member.id)
                await reloadMembers()
            } catch {
                said = (Canvases.plain(error, while: .removing(name)), true)
            }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    /// "Only you here" with the canvas open and nobody else in it; "3 here
    /// now" counting you among the people in the room; nothing at all when
    /// the canvas isn't open here and nobody else is in it.
    static func presenceLine(others: Int, here: Bool) -> String? {
        if here { return others == 0 ? "Only you here" : "\(others + 1) here now" }
        return others == 0 ? nil : "\(others) here now"
    }

    /// The people in the room besides you, once each.
    static func others(in id: String) -> [Canvases.PresencePerson] {
        let me = Canvases.shared.identity.id
        var seen = Set<String>()
        return (Canvases.shared.presence[id] ?? []).filter { $0.id != me && seen.insert($0.id).inserted }
    }

    /// A row's state, as the bench says it.
    private func word(_ state: RowState) -> String {
        switch state {
        case .you: return "you"
        case .member(let role): return role == "owner" ? "owner" : "member"
        case .invited(let invite): return invite.id.hasPrefix(Self.local) ? "invited (sending)" : "invited"
        case .invite: return "invite"
        }
    }

    /// For `bench canvas ui share state`: what the sheet shows, as data.
    var describe: [String: Any] {
        let others = CanvasShareModel.others(in: canvasId)
        let here = CanvasPresence.shared.open.contains(canvasId)
        let stamp = ISO8601DateFormatter()
        var out: [String: Any] = [
            "canvas": canvasId, "canShare": canShare, "checking": checking,
            "serverVersion": Cloud.shared.serverVersion ?? NSNull(),
            "links": links.map { $0 as Any } ?? NSNull(), "directory": directory, "reminders": reminders,
            "query": query,
            "people": people.prefix(6).map { ["name": $0.name, "email": $0.email, "state": word(state(of: $0.email))] },
            "members": members.map { ["name": $0.name, "email": $0.email, "role": $0.role] },
            "pending": pending.map { invite -> [String: Any] in
                var row: [String: Any] = ["email": invite.email, "name": name(for: invite.email, invite: invite),
                                          "state": word(.invited(invite)), "resend": canRemind(invite), "withdraw": canWithdraw(invite),
                                          "nudgedAt": invite.nudgedAt.map { stamp.string(from: $0) as Any } ?? NSNull()]
                if invite.inviteeKnown { row["account"] = invite.invitee != nil }
                return row
            },
            "presence": CanvasShareModel.presenceLine(others: others.count, here: here) ?? NSNull(),
            "emailRow": emailRow ?? NSNull(), "emailNote": emailNote ?? NSNull(),
            "typedRow": typedRow.map { ["email": $0, "state": word(state(of: $0))] as Any } ?? NSNull(),
            "working": working, "acting": Array(acting).sorted(), "copied": copied,
        ]
        if links == false { out["note"] = Canvases.linksUnsupported }
        if let said { out["said"] = said.text; out["failed"] = said.failed }
        if let linkFailure { out["linkFailure"] = linkFailure }
        return out
    }
}

struct CanvasShareSheet: View {
    let entry: Canvases.Entry
    @ObservedObject var model: CanvasShareModel
    @ObservedObject private var canvases = Canvases.shared
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var ui = CanvasUI.shared
    @ObservedObject private var presence = CanvasPresence.shared

    private var canShare: Bool { entry.isShared && cloud.isLinked && cloud.isSignedIn }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CanvasFormTitle(text: "Share canvas")
            CanvasSubject(name: entry.name)
            if !canShare {
                Text(entry.isPersonal ? "Personal canvases can't be shared." : "This canvas is on this Mac only and can't be shared.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if cloud.isSignedIn { Button("New shared canvas") { ui.mode = .new } }
                    else { Button("Connect to Copper Cloud") { ui.popoverOpen = false; CanvasUI.openCloudSettings(in: Windows.all.first ?? Windows.main) } }
                }.buttonStyle(CanvasButtonStyle(kind: .primary))
            } else {
                presenceRow
                linkSection
                inviteField
                // The rows, the members and the invites waiting scroll
                // together under the field, so the line above them — what an
                // invite came to — is never pushed out of the card.
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        peopleRows
                        membersSection
                        invitedSection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic, axes: .vertical)
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
                if entry.isOwner, model.links != false, !model.checking {
                    Button("Reset link", role: .destructive) { model.reset() }.buttonStyle(CanvasButtonStyle(kind: .plain))
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder private var presenceRow: some View {
        let others = CanvasShareModel.others(in: entry.id)
        let here = presence.open.contains(entry.id)
        if let line = CanvasShareModel.presenceLine(others: others.count, here: here) {
            HStack(spacing: 6) {
                if here {
                    let me = canvases.identity
                    face(me.name, color: me.color).help("You")
                }
                ForEach(others.prefix(8)) { person in face(person.name, color: person.color).help(person.name) }
                Text(line).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line)
        }
    }

    private func face(_ name: String, color: String) -> some View {
        Circle().fill(Color(hex: color)).frame(width: 22, height: 22)
            .overlay(Text(String(name.prefix(1)).uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white))
    }

    @ViewBuilder private var linkSection: some View {
        if model.links == false {
            Text(Canvases.linksUnsupported)
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        } else if !(model.checking && model.links == nil) {
            Button(model.copied ? "Copied" : "Copy invite link") { model.copyLink() }
                .buttonStyle(CanvasButtonStyle(kind: .primary)).disabled(model.working)
            if model.madeLink != nil { Button("Copy web link") { model.copyWebLink() }.buttonStyle(CanvasButtonStyle(kind: .plain)) }
            if let failure = model.linkFailure {
                Text(failure).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The heading, the field, and right under it what the last invite came to.
    private var inviteField: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.directory ? "People on this cloud" : "Invite by email").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
            TextField(model.directory ? "Search people or type an email" : "Type an email to invite", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.submit() }
            if let said = model.said {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if !said.failed {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted)
                    }
                    Text(said.text).font(.system(size: 11)).foregroundStyle(said.failed ? Color.orange : Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .transition(.opacity)
            }
        }
        .animation(Motion.quick, value: model.said?.text)
    }

    @ViewBuilder private var peopleRows: some View {
        let typed = model.typedRow
        let directory = model.directory ? Array(model.people.prefix(6)) : []
        if typed != nil || model.emailNote != nil || !directory.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if let email = typed {
                    person(name: nil, email: email)
                } else if let note = model.emailNote {
                    Text(note).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(directory) { person in
                    self.person(name: person.name.isEmpty ? nil : person.name, email: person.email)
                }
            }
        }
    }

    /// One person: who, and where they stand — You, Owner, Member,
    /// Invited (· Resend · ×), or Invite.
    private func person(name: String?, email: String) -> some View {
        HStack(spacing: 8) {
            if let name {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 11.5)).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.tail)
                    Text(email).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
                }
            } else {
                Image(systemName: "envelope").font(.system(size: 10.5)).foregroundStyle(Palette.muted)
                Text(email).font(.system(size: 11.5)).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            standing(email)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func standing(_ email: String) -> some View {
        switch model.state(of: email) {
        case .you:
            Text("You").font(.system(size: 10)).foregroundStyle(Palette.muted)
        case .member(let role):
            Text(role == "owner" ? "Owner" : "Member").font(.system(size: 10)).foregroundStyle(Palette.muted)
                .help("\(role.capitalized) of this canvas")
        case .invited(let invite):
            invited(invite)
        case .invite:
            Button("Invite") { model.invite(email) }
                .buttonStyle(CanvasButtonStyle(kind: .plain))
                .disabled(model.acting.contains(email.lowercased()))
        }
    }

    /// "Invited", then Resend and × where the cloud and the account allow
    /// them. Under the Invited heading the word itself would only repeat it.
    private func invited(_ invite: Canvases.Invite, label: Bool = true) -> some View {
        let busy = model.acting.contains(invite.email.lowercased())
        return HStack(spacing: 6) {
            if label {
                Text("Invited").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    .help(waiting(invite))
            }
            if busy {
                ProgressView().controlSize(.mini)
            } else {
                if model.canRemind(invite) {
                    Button("Resend") { model.resend(invite) }
                        .buttonStyle(CanvasButtonStyle(kind: .plain))
                        .help("Remind them — the invite comes up again in their Copper")
                }
                if model.canWithdraw(invite) {
                    Button { model.withdraw(invite) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                            .frame(width: 16, height: 16).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.muted)
                    .help("Withdraw the invite")
                    .accessibilityLabel("Withdraw the invite to \(model.name(for: invite.email, invite: invite))")
                }
            }
        }
    }

    /// The Invited label's help: what the invite is waiting for.
    private func waiting(_ invite: Canvases.Invite) -> String {
        if invite.inviteeKnown, invite.invitee == nil { return "Waiting for them to make an account on \(Canvases.cloudHost)" }
        return "Waiting for them to join — it's in their Copper"
    }

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Members").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
            ForEach(model.members) { member in
                HStack(spacing: 8) {
                    Text(member.name.isEmpty ? member.email : member.name).font(.system(size: 11.5)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 6)
                    Text(member.role.capitalized).font(.system(size: 10)).foregroundStyle(Palette.muted)
                    if entry.isOwner && member.role != "owner" {
                        Button("Remove") { model.remove(member) }.buttonStyle(CanvasButtonStyle(kind: .plain))
                    }
                }
            }
        }
    }

    /// The invites waiting on this canvas, whoever sent them: by name once
    /// they have an account, else by address, with a line under each that
    /// says what it is waiting for.
    @ViewBuilder private var invitedSection: some View {
        if !model.pending.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Invited").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                ForEach(model.pending) { invite in
                    HStack(spacing: 8) {
                        let name = model.name(for: invite.email, invite: invite)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name).font(.system(size: 11.5)).foregroundStyle(Palette.ink)
                                .lineLimit(1).truncationMode(.middle)
                            if invite.inviteeKnown, invite.invitee == nil {
                                Text("No account on \(Canvases.cloudHost) yet").font(.system(size: 10)).foregroundStyle(Palette.muted)
                                    .lineLimit(1).truncationMode(.middle)
                            } else if name != invite.email {
                                Text(invite.email).font(.system(size: 10)).foregroundStyle(Palette.muted)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 6)
                        invited(invite, label: false)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private extension Color {
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt32(digits, radix: 16) ?? 0x888888
        self.init(red: Double((value >> 16) & 0xff) / 255,
                  green: Double((value >> 8) & 0xff) / 255,
                  blue: Double(value & 0xff) / 255)
    }
}
