import AppKit
import Combine
import Foundation

// Chat on a shared canvas — Copper's half (docs/canvas.md, "Chat").
//
// The messages live in the canvas document itself: a top-level Y.Array
// named `chat`, written by the page and synced and stored with the board
// like any other change. Copper never reads them. What Copper keeps here:
//
// - per account and canvas, whether the panel shows and how far it was read
//   (`canvas/chat.json`, so both survive a relaunch);
// - the people the @ picker offers: the canvas's members
//   (`GET /v1/canvases/:id/members`), kept with the read marks so the picker
//   is instant (offline too), and the invites still waiting — shown as
//   "Invited", never mentionable until they join;
// - mentions of you (copper-cloud 0.6.0): `GET /v1/mentions?unread=1`, read
//   again on every `canvas` event of kind `mention`/`mention_read` and when
//   the event stream comes back. A new one raises the pill at the window's
//   foot (CanvasChatUI.swift), puts a dot on the Canvas door and the count on
//   the canvas's chat button, and — when Copper isn't frontmost — a macOS
//   notification. Open shows the canvas, its chat, the message; that marks it
//   read (`POST /v1/mentions/read`), which the server tells your other Macs.
// - after a message that mentions someone, `POST /v1/canvases/:id/mentions`.
//   Putting someone on a checklist row is told the same way: the page posts
//   a mention whose id names the card (`assign.<shapeId>.<nonce>`), so the
//   pill and the notification say "assigned you", and Open shows the card
//   (its rows that are yours glow once) instead of the chat.
//
// On an older cloud chat works the same (it is in the document) and a
// mention is a highlighted chip and a badge inside the canvas only.

@MainActor
final class CanvasChat: ObservableObject {
    static let shared = CanvasChat()

    /// A mention of you, as `GET /v1/mentions` lists it.
    struct Mention: Identifiable, Equatable {
        let id: String
        /// The server's canvas id (a shared canvas's `Entry.id` too).
        let canvasId: String
        let canvasName: String
        let fromId: String
        let fromName: String
        let fromEmail: String
        let messageId: String
        let excerpt: String
        let createdAt: Date?

        var who: String { fromName.isEmpty ? (fromEmail.isEmpty ? "Someone" : fromEmail) : fromName }
        /// Someone put you on a checklist row (the page's `assign.<shapeId>.<nonce>` id), not a chat message.
        var isAssignment: Bool { messageId.hasPrefix("assign.") }
        /// "mentioned you" / "assigned you", for the pill and the notification.
        var verb: String { isAssignment ? "assigned you" : "mentioned you" }
    }

    /// One canvas, for one account: the panel and the read mark.
    struct Pref: Codable, Equatable {
        var open: Bool?
        var readId: String?
        var readAt: Double?
    }

    struct Person: Codable, Equatable {
        let id: String
        let name: String
        let email: String
    }

    private struct Saved: Codable {
        /// account id → canvas id → pref
        var prefs: [String: [String: Pref]] = [:]
        /// canvas id → its members, as last read
        var members: [String: [Person]] = [:]
        /// Whether macOS has been asked about notifications (asked once, when the first mention arrives).
        var askedToNotify: Bool?
    }

    /// Unread mentions of the signed-in account, newest first.
    @Published private(set) var mentions: [Mention] = []
    /// The newest one not shown yet: the pill at the window's foot.
    @Published var newMention: Mention?

    /// What a notification would have said (test worlds record instead of posting), newest last.
    private(set) var notices: [[String: Any]] = []
    private var saved = Saved()
    private var invited: [String: [Person]] = [:]
    private var membersRead: [String: Date] = [:]
    private var membersLoading: Set<String> = []
    /// Mentions already raised (pill or notification) this run.
    private var raised: Set<String> = []
    /// Message ids a page has shown as read, per canvas, before the server's mention of them arrived.
    private var readHere: [String: [String]] = [:]
    private var refreshing: Task<Void, Never>?
    private var again = false
    private var started = false
    private var observers: [NSObjectProtocol] = []
    private var bag: Set<AnyCancellable> = []
    private var mentionsAccount: String?
    private var saveWork: DispatchWorkItem?

    private static var file: URL { Canvases.folder.appendingPathComponent("chat.json") }

    private init() {
        if let data = try? Data(contentsOf: CanvasChat.file), let value = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = value
        }
    }

    /// Listens to the cloud from now on. Idempotent; the pill's view starts it.
    func start() {
        guard !started else { return }
        started = true
        CanvasChatNotices.install()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: Cloud.event, object: nil, queue: .main) { note in
            let event = note.userInfo?["event"] as? [String: Any] ?? [:]
            MainActor.assumeIsolated { CanvasChat.shared.heard(event) }
        })
        observers.append(center.addObserver(forName: Cloud.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CanvasChat.shared.accountChanged() }
        })
        Cloud.shared.$serverVersion.removeDuplicates().dropFirst().sink { _ in
            DispatchQueue.main.async {
                CanvasChat.shared.refreshSoon()
                CanvasChat.shared.tellAll()
            }
        }.store(in: &bag)
        accountChanged()
    }

    // MARK: - who and where

    private var account: String? { Canvases.account }

    /// Chat is on a canvas that lives on the cloud, while signed in to it.
    func offered(_ entry: Canvases.Entry?) -> Bool {
        guard let entry, entry.isShared, entry.remoteId != nil else { return false }
        return Canvases.shared.cloudReady
    }

    /// The cloud takes mention notifications: true, false, or nil while its version isn't known.
    var mentionsApi: Bool? { Cloud.shared.supports(.mentions) }

    func pref(_ canvas: String) -> Pref {
        guard let account else { return Pref() }
        return saved.prefs[account]?[canvas] ?? Pref()
    }

    private func setPref(_ canvas: String, _ change: (inout Pref) -> Void) {
        guard let account else { return }
        var value = saved.prefs[account]?[canvas] ?? Pref()
        change(&value)
        guard value != saved.prefs[account]?[canvas] else { return }
        saved.prefs[account, default: [:]][canvas] = value
        saveSoon()
    }

    private func saveSoon() {
        saveWork?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { CanvasChat.shared.saveNow() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Asked macOS about notifications already (once, when the first mention arrived).
    var askedToNotify: Bool {
        get { saved.askedToNotify == true }
        set { saved.askedToNotify = newValue; saveSoon() }
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: Canvases.folder, withIntermediateDirectories: true)
        try? data.write(to: CanvasChat.file, options: .atomic)
    }

    func members(_ canvas: String) -> [Person] { saved.members[canvas] ?? [] }

    // MARK: - the page

    /// What the page is told (`copperCanvas.setChat`), for one host.
    func payload(for host: CanvasHost) -> [String: Any] {
        let canvas = host.canvasId
        guard offered(host.entry) else { return ["enabled": false, "open": false] }
        let pref = pref(canvas)
        var out: [String: Any] = [
            "enabled": true,
            "open": pref.open ?? false,
            "mentionsApi": mentionsApi == true,
            "mentioned": mentions.filter { $0.canvasId == canvas }.map(\.messageId),
            "invited": (invited[canvas] ?? []).map { ["name": $0.name, "email": $0.email] },
        ]
        if let list = saved.members[canvas] {
            out["members"] = list.map { ["id": $0.id, "name": $0.name, "email": $0.email, "color": CanvasColors.stable($0.id)] }
        }
        if pref.readId != nil || pref.readAt != nil {
            out["lastReadId"] = pref.readId ?? NSNull()
            out["lastReadAt"] = pref.readAt ?? NSNull()
        } else {
            out["known"] = false
        }
        return out
    }

    /// Tell a page where chat stands (from `CanvasHost.shareNow`, and whenever it changes).
    func tell(_ host: CanvasHost) {
        guard host.isReady else { return }
        start()
        let value = payload(for: host)
        Task { try? await host.call("const c = window.copperCanvas; if (c && typeof c.setChat === 'function') c.setChat(s);", ["s": value]) }
        if value["enabled"] as? Bool == true { loadMembers(host.canvasId) }
    }

    /// Every page showing `canvas` (all of them when nil).
    func tellAll(_ canvas: String? = nil) {
        for host in CanvasHost.all where canvas == nil || host.canvasId == canvas { tell(host) }
    }

    /// Before an agent posts: the page knows who is on the canvas.
    func prepare(_ host: CanvasHost) async {
        if saved.members[host.canvasId] == nil || membersStale(host.canvasId) { await readMembers(host.canvasId) }
        let value = payload(for: host)
        _ = try? await host.call("const c = window.copperCanvas; if (c && typeof c.setChat === 'function') c.setChat(s);", ["s": value])
    }

    private func membersStale(_ canvas: String, within: TimeInterval = 60) -> Bool {
        guard let read = membersRead[canvas] else { return true }
        return Date().timeIntervalSince(read) > within
    }

    private func loadMembers(_ canvas: String, force: Bool = false, within: TimeInterval = 60) {
        guard force || membersStale(canvas, within: within), !membersLoading.contains(canvas) else { return }
        Task { await readMembers(canvas) }
    }

    private func readMembers(_ canvas: String) async {
        guard !membersLoading.contains(canvas), Canvases.shared.cloudReady else { return }
        membersLoading.insert(canvas)
        defer { membersLoading.remove(canvas) }
        do {
            let list = try await Canvases.shared.members(canvas)
            membersRead[canvas] = Date()
            let people = list.map { Person(id: $0.id.lowercased(), name: $0.name, email: $0.email) }
            var waiting: [Person] = []
            if let pending = try? await Canvases.shared.canvasInvites(canvas) {
                // Only those who already have an account; they can be mentioned once they join.
                waiting = pending.compactMap { invite in
                    guard let person = invite.invitee else { return nil }
                    return Person(id: person.id.lowercased(), name: person.name.isEmpty ? invite.email : person.name, email: person.email.isEmpty ? invite.email : person.email)
                }.filter { person in !people.contains { $0.id == person.id } }
            }
            let changed = saved.members[canvas] != people || invited[canvas] != waiting
            saved.members[canvas] = people
            invited[canvas] = waiting
            if changed {
                saveSoon()
                for host in CanvasHost.hosts(of: canvas) where host.isReady {
                    let value = payload(for: host)
                    _ = try? await host.call("const c = window.copperCanvas; if (c && typeof c.setChat === 'function') c.setChat(s);", ["s": value])
                }
            }
        } catch {
            CanvasHost.log.debug("chat: members of \(canvas, privacy: .public) unread: \(String(describing: error), privacy: .public)")
        }
    }

    /// A message from a page about chat. False: not one of ours.
    @discardableResult
    func received(_ body: [String: Any], from host: CanvasHost) -> Bool {
        let canvas = host.canvasId
        switch body["type"] as? String ?? "" {
        case "chat":
            guard let open = body["open"] as? Bool else { return true }
            setPref(canvas) { $0.open = open }
            // Every other tab on this canvas follows.
            for other in CanvasHost.hosts(of: canvas) where other !== host && other.isReady {
                Task { try? await other.call("const c = window.copperCanvas; if (c && typeof c.showChat === 'function') c.showChat(o);", ["o": open]) }
            }
        case "chatRead":
            let id = body["id"] as? String
            let at = (body["at"] as? NSNumber)?.doubleValue
            setPref(canvas) { pref in
                if let id { pref.readId = id }
                if let at { pref.readAt = at }
            }
            let read = (body["mentionIds"] as? [Any] ?? []).compactMap { $0 as? String }
            if !read.isEmpty {
                var seen = readHere[canvas] ?? []
                seen.append(contentsOf: read)
                readHere[canvas] = Array(seen.suffix(200))
                let ids = mentions.filter { $0.canvasId == canvas && read.contains($0.messageId) }.map(\.id)
                if !ids.isEmpty { markRead(ids) }
            }
        case "chatMembers":
            loadMembers(canvas, within: 15)
        case "mention":
            guard let message = body["messageId"] as? String, let entry = host.entry, let remote = entry.remoteId else { return true }
            let users = (body["userIds"] as? [Any] ?? []).compactMap { $0 as? String }
            let excerpt = String((body["excerpt"] as? String ?? "").prefix(200))
            guard !users.isEmpty, mentionsApi != false else { return true }
            Task { await self.notify(canvas: remote, message: message, users: users, excerpt: excerpt) }
        default:
            return false
        }
        return true
    }

    /// `POST /v1/canvases/:id/mentions`, retried a few times while the cloud is away.
    private func notify(canvas: String, message: String, users: [String], excerpt: String, attempt: Int = 1) async {
        do {
            _ = try await Cloud.shared.request("POST", "/v1/canvases/\(canvas)/mentions",
                                               json: ["message_id": message, "user_ids": users, "excerpt": excerpt])
        } catch let failure as Cloud.Failure where failure.status == 404 && failure.code == "not_found" && mentionsApi == nil {
            Cloud.shared.lacks(.mentions)
        } catch {
            CanvasHost.log.debug("chat: mention for \(message, privacy: .public) not sent (\(String(describing: error), privacy: .public))")
            let failure = error as? Cloud.Failure
            guard attempt < 4, failure == nil || failure?.status == 0 || (failure?.status ?? 0) >= 500 else { return }
            try? await Task.sleep(nanoseconds: UInt64(attempt * attempt) * 1_500_000_000)
            await notify(canvas: canvas, message: message, users: users, excerpt: excerpt, attempt: attempt + 1)
        }
    }

    // MARK: - mentions of you

    private func heard(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "open":
            refreshSoon()
        case "canvas":
            let kind = event["kind"] as? String ?? ""
            let canvas = (event["canvas_id"] as? String)?.lowercased()
            if kind == "mention" || kind == "mention_read" {
                refreshSoon()
            } else if kind.hasPrefix("member") || kind.hasPrefix("invite"), let canvas {
                if !CanvasHost.hosts(of: canvas).isEmpty { loadMembers(canvas, force: true) } else { membersRead[canvas] = nil }
            }
        default:
            break
        }
    }

    private func accountChanged() {
        let now = Canvases.shared.cloudReady ? account : nil
        guard now != mentionsAccount else { return }
        mentionsAccount = now
        mentions = []
        newMention = nil
        raised = []
        invited = [:]
        membersRead = [:]
        if now != nil { refreshSoon() }
    }

    /// Read the unread mentions again (coalesced: one in flight, one more after it).
    func refreshSoon() {
        if refreshing != nil { again = true; return }
        refreshing = Task { [weak self] in
            await self?.refresh()
            guard let self else { return }
            self.refreshing = nil
            if self.again { self.again = false; self.refreshSoon() }
        }
    }

    func refresh() async {
        guard Canvases.shared.cloudReady, let account, mentionsApi != false else {
            if !mentions.isEmpty { mentions = []; newMention = nil; tellAll() }
            return
        }
        let rows: [[String: Any]]
        do {
            let (data, _) = try await Cloud.shared.request("GET", "/v1/mentions", query: ["unread": "1", "limit": "100"])
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            rows = object?["mentions"] as? [[String: Any]] ?? []
        } catch let failure as Cloud.Failure where failure.status == 404 && failure.code == "not_found" {
            if mentionsApi == nil { Cloud.shared.lacks(.mentions) }
            return
        } catch {
            return
        }
        guard account == self.account else { return }
        let fresh = rows.compactMap(CanvasChat.mention).filter { $0.fromId != account }
        let before = Set(mentions.map(\.id))
        let touched = Set(fresh.map(\.canvasId)).union(mentions.map(\.canvasId))
        mentions = fresh
        if let shown = newMention, !fresh.contains(where: { $0.id == shown.id }) { newMention = nil }

        // Read here already (the canvas was open on it): read on the server too, quietly.
        let readAlready = fresh.filter { readHere[$0.canvasId]?.contains($0.messageId) == true }
        if !readAlready.isEmpty { markRead(readAlready.map(\.id)) }
        let unseen = fresh.filter { !raised.contains($0.id) && !before.contains($0.id) && !readAlready.contains($0) }
        for mention in unseen { raised.insert(mention.id) }
        // Watching a canvas's chat covers its messages, not a checklist card somewhere on it.
        if let newest = unseen.first(where: { $0.isAssignment || !watching($0.canvasId) }) {
            newMention = newest
            // A notification only for one that just came — not for every unread one at launch.
            let recent = newest.createdAt.map { Date().timeIntervalSince($0) < 15 * 60 } ?? true
            if !CanvasChatNotices.frontmost, recent { CanvasChatNotices.post(newest) }
        }
        for canvas in touched { tellAll(canvas) }
    }

    /// The canvas is in front with its chat showing, in the app the person is using: they see it there.
    private func watching(_ canvas: String) -> Bool {
        guard CanvasChatNotices.frontmost, pref(canvas).open == true else { return false }
        return Windows.all.contains { browser in CanvasHost.active(in: browser) == canvas }
    }

    static func mention(_ row: [String: Any]) -> Mention? {
        guard let id = Canvases.string(row["id"]), let message = Canvases.string(row["message_id"]) else { return nil }
        if row["read_at"] != nil, !(row["read_at"] is NSNull) { return nil }
        let canvas = row["canvas"] as? [String: Any]
        let from = row["from"] as? [String: Any]
        return Mention(id: id,
                       canvasId: (Canvases.string(canvas?["id"]) ?? Canvases.string(row["canvas_id"]) ?? "").lowercased(),
                       canvasName: Canvases.string(canvas?["name"]) ?? "a canvas",
                       fromId: (Canvases.string(from?["id"]) ?? "").lowercased(),
                       fromName: Canvases.string(from?["display_name"]) ?? Canvases.string(from?["name"]) ?? "",
                       fromEmail: Canvases.string(from?["email"]) ?? "",
                       messageId: message,
                       excerpt: Canvases.string(row["excerpt"]) ?? "",
                       createdAt: Canvases.date(row["created_at"]))
    }

    /// `POST /v1/mentions/read {ids}`; gone from here at once.
    func markRead(_ ids: [String]) {
        let ids = Array(Set(ids))
        guard !ids.isEmpty else { return }
        let canvases = Set(mentions.filter { ids.contains($0.id) }.map(\.canvasId))
        mentions.removeAll { ids.contains($0.id) }
        if let shown = newMention, ids.contains(shown.id) { newMention = nil }
        CanvasChatNotices.withdraw(ids)
        for canvas in canvases { tellAll(canvas) }
        guard Canvases.shared.cloudReady, mentionsApi != false else { return }
        Task {
            do { _ = try await Cloud.shared.request("POST", "/v1/mentions/read", json: ["ids": ids]) } catch {
                CanvasHost.log.debug("chat: mentions/read failed: \(String(describing: error), privacy: .public)")
                self.refreshSoon()
            }
        }
    }

    func dismissNewMention() { newMention = nil }

    /// A test world's notification, kept for the bench instead of shown.
    func recordNotice(_ notice: [String: Any]) {
        var stamped = notice
        stamped["at"] = ISO8601DateFormatter().string(from: Date())
        notices.append(stamped)
        if notices.count > 20 { notices.removeFirst(notices.count - 20) }
    }

    /// Open: the canvas, its chat, the message — and read.
    @discardableResult
    func open(_ mention: Mention, in browser: Browser) async -> String? {
        if newMention?.id == mention.id { newMention = nil }
        if Canvases.shared.find(mention.canvasId) == nil { await Canvases.shared.refresh() }
        guard let entry = Canvases.shared.find(mention.canvasId) else {
            markRead([mention.id])
            return "That canvas isn't yours to open any more."
        }
        if !NSApp.isActive, !Store.testing { NSApp.activate(ignoringOtherApps: true) }
        // An assignment shows its card; the chat stays as the person left it.
        if !mention.isAssignment { setPref(entry.id) { $0.open = true } }
        let tab = CanvasHost.show(entry.id, in: browser, foreground: true)
        var host: CanvasHost?
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let found = CanvasHost.host(for: tab), found.isReady { host = found; break }
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        markRead([mention.id])
        guard let host else { return "The canvas didn't open in time." }
        _ = try? await host.call("const c = window.copperCanvas; if (c && typeof c.revealChat === 'function') return c.revealChat(t); return false;",
                                 ["t": ["id": mention.messageId]])
        return nil
    }

    /// Unread mentions on one canvas (the card's rows).
    func mentionCount(_ canvas: String) -> Int { mentions.filter { $0.canvasId == canvas }.count }
}
