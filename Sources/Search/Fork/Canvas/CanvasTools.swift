import AppKit
import WebKit

// The canvas tools: one implementation behind the ⌘E agent, the loopback MCP
// server and the `copper` CLI, because all three go through Tools.call
// (Fork/MCP/Tools.swift hands every `canvas_*` name here and appends this
// catalogue to its own). Every call is a Driver call like any other — named
// in the pane, stoppable — and every write is attributed to the agent that
// made it, which the board shows beside the shapes it touched.

enum CanvasTools {
    typealias Content = Tools.Content
    struct Failure: Error { let text: String }

    // MARK: - the catalogue

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        var all = properties
        all["reason"] = Tools.reasonProperty
        return ["name": name, "description": description,
                "inputSchema": ["type": "object", "properties": all, "required": required] as [String: Any]]
    }

    private static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
    private static func bool(_ description: String) -> [String: Any] { ["type": "boolean", "description": description] }
    private static func ids(_ description: String) -> [String: Any] { ["type": "array", "items": ["type": "string"], "description": description] }
    private static let which = string("Canvas id or name (from canvas_list); omit for the canvas tab in front, else Personal")

    static let names: Set<String> = ["canvas_list", "canvas_open", "canvas_read", "canvas_apply", "canvas_select",
                                     "canvas_focus", "canvas_create", "canvas_invite", "canvas_share_link", "canvas_join", "canvas_screenshot",
                                     CanvasChat.toolName]

    static var catalogue: [[String: Any]] {
        [
            tool("canvas_list", "List the user's canvases (whiteboards): id, name, kind (personal|shared|local), whether one is open in a tab, and how many collaborators are live in it"),
            tool("canvas_open", "Make sure a canvas has a tab (in the background unless foreground is true) and return its summary", [
                "id": which, "name": string("Canvas name, if you have no id"),
                "foreground": bool("Bring its tab to the front; default false"),
            ]),
            tool("canvas_read", "Read a canvas: {canvas, viewport, shapes:[{id,type,x,y,w,h,color,text|title|label|url,live?,by}], agents, selection}; a checklist card (a sticky with view:'checklist') also has title, columns, rows:[{label,pick,by?,at?,note?,noteBy?,noteAt?,assignees?:[{name,id?,email?}]}] (note: the row's comment, when it has one; assignees: who the row is assigned to, id their Copper Cloud user id) and tally {column: count}; a timeline (view:'timeline') has title, start, end, step and items:[{date, end?, label, text?, color?, kind:'note'|'bubble'|'section'}]; comments:[{id, anchor (shape id), anchorDeleted?, resolved, resolvedBy?, messages:[{id, by, at, text, edited?}]}] lists the comment threads people left on shapes (a frame is often a slide). Text is cut at 500 characters unless full is true. Read before you write.", [
                "id": which, "full": bool("Whole texts instead of the first 500 characters"),
            ]),
            tool("canvas_apply", "Change a canvas in one transaction (opens its tab in the background if needed). Returns {applied, ids, errors}. Ops: {op:'add', shape:{type:'sticky'|'text'|'frame'|'arrow'|'image'|'link'|'checklist'|'timeline', id?, x?, y?, w?, h?, color?, text?|title?|url?|from?/to?|label?}} (omit x/y to place it in free space near the view; give it your own id, e.g. 'n1', to connect it later in the same call). A link with live:true (or type:'web') shows the site itself on the board, an iframe everyone on the board can browse — each person signed in as themselves; it defaults to 960×640 and needs an http(s) url; update {live:false} turns it back into a card. A checklist is a clickable RSVP / to-do card: {type:'checklist', title, columns?:['Yes','No'] (1–4; one column = to-do boxes), rows:['Ann', …] (≤60), picks?:{'Ann':'Yes'}, notes?:{'Ann':'Back at 6'}, assignees?:{'Fix login':['Grace Hopper','ann@example.com']}} — it is stored as a sticky with view:'checklist' whose text is the list ('### Title' then '- [ ] Ann' / '- [x] Ann · No' lines, a row's comment as indented '  > …' lines under it, then one indented '  @Name' line per assignee), so older Coppers show it as a note with task boxes; each row has at most one pick and one comment (multi-line text, shown collapsed under the row) and up to 12 assignees (people on the canvas named by name, email or id — each newly assigned one is notified like a chat @mention; anyone else by a name of their own); in update, picks, notes and assignees name a row by label, null clears it (assignees replace the row's list), and rows/columns/title replace them in the text (rows keep their picks, comments and assignees by label). {op:'update', id, patch:{view:'checklist', columns?}} turns a sticky that holds a heading and a task list into a card, ticks kept; view:null turns it back into a note. A timeline: {type:'timeline', title?, start:'YYYY-MM-DD', end, step?:'day'|'week'|'month'|'quarter'|'year', items?:[{date, end?, label, text?, color?}]} (text makes a bubble, end a section), stored as a sticky with view:'timeline' whose text is the timeline; update takes the same (items replaces the list) plus addItems:[…] and editItems:{ref: patch|null} (ref: 'YYYY-MM-DD · label', a label, a date or an index; null removes). {op:'update', id, patch:{…}}; {op:'move', id, dx, dy}; {op:'resize', id, w, h}; {op:'delete', id}; {op:'connect', from:id, to:id, label?} (an arrow); comment threads on a shape, Figma-style: {op:'comment', on:shapeId, text} starts one (its ids[i] is the thread id), {op:'reply', thread, text} adds onto one (a resolved thread opens again), {op:'resolve', thread, resolved:true|false} resolves or reopens; {op:'clear', confirm:true} only when the user explicitly asked to wipe the board.", [
                "id": which,
                "ops": ["type": "array", "items": ["type": "object"], "description": "The operations, applied in order in one transaction"] as [String: Any],
                "as": string("Name to attribute the change to; defaults to the calling agent"),
            ], required: ["ops"]),
            tool("canvas_select", "Select shapes on a canvas (what the user sees highlighted)", [
                "id": which, "shapeIds": ids("Shape ids from canvas_read; empty clears the selection"),
            ], required: ["shapeIds"]),
            tool("canvas_focus", "Pan and zoom a canvas's view to fit these shapes", [
                "id": which, "shapeIds": ids("Shape ids from canvas_read"),
            ], required: ["shapeIds"]),
            tool("canvas_create", "Make a new canvas: shared on the user's cloud when signed in, on this Mac only otherwise. Returns its summary.", [
                "name": string("The canvas's name"),
            ], required: ["name"]),
            tool("canvas_invite", "Invite someone by email to a shared canvas (needs Copper Cloud; the Personal canvas is never shared). Inviting someone already invited reminds them, on a cloud that can.", [
                "id": string("Canvas id or name"), "email": string("Their email address"),
            ], required: ["id", "email"]),
            tool("canvas_share_link", "Create or reuse the invite link for a shared canvas", ["id": string("Canvas id or name")], required: ["id"]),
            tool("canvas_join", "Open a Copper canvas invite link in the current window", ["link": string("copper://canvas/join/... or https://cloud/join/...")], required: ["link"]),
            tool("canvas_screenshot", "A PNG of a canvas as it looks in its tab", ["id": which]),
            CanvasChat.tool,
        ]
    }

    static let instructions = "Canvases are the user's whiteboards — each is a copper://canvas/<id> tab; Personal always exists and is private. Use canvas_* tools, never browser_* clicks, to change one. Coordinates are board units: x grows right, y grows down, (0,0) is arbitrary; shapes have x, y (top-left), w, h. Always canvas_read first: reuse its ids, place new shapes beside existing ones (or omit x/y to auto-place near the view), and change a shape with update/move/resize instead of re-adding it. canvas_apply runs every op in one transaction and returns {applied, ids, errors}; colors are yellow, pink, blue, green, purple, gray, white or #hex; connect draws an arrow between two shapes; clear needs confirm:true and only on an explicit request. For a big batch (dozens of shapes) send several canvas_apply calls of at most 40 ops each rather than one huge call, and give added shapes your own ids (shape.id) so connect ops can name them."

    // MARK: - dispatch

    @MainActor
    static func call(_ name: String, _ args: [String: Any], in browser: Browser) async throws -> [Content] {
        do {
            return try await run(name, args, in: browser)
        } catch let failure as Failure {
            throw Tools.Failure(text: failure.text)
        } catch let failure as CanvasHost.Failure {
            throw Tools.Failure(text: failure.text)
        } catch let failure as Cloud.Failure {
            throw Tools.Failure(text: failure.message)
        }
    }

    @MainActor
    private static func run(_ name: String, _ args: [String: Any], in browser: Browser) async throws -> [Content] {
        switch name {
        case "canvas_list":
            let rows = Canvases.shared.visible.map { summary($0, in: browser) }
            Tools.summary?.line = "Listed \(rows.count) canvas\(rows.count == 1 ? "" : "es")"
            var out: [String: Any] = ["canvases": rows, "cloud": cloudLine]
            // Invites waiting for the user's answer — theirs to give, in the Canvas card.
            let waiting = Canvases.shared.invites
            if !waiting.isEmpty { out["invitations"] = waiting.map { ["canvas": $0.canvasName, "from": $0.from] } }
            return [.text(json(out))]

        case "canvas_open":
            let entry = try resolve(args, in: browser, fallbackToActive: false)
            let foreground = (args["foreground"] as? Bool) ?? false
            let host = try await open(entry, in: browser, foreground: foreground)
            try await host.waitReady()
            Tools.summary?.line = "Opened \(entry.name)"
            return [.text(json(summary(entry, in: browser)))]

        case "canvas_read":
            let entry = try resolve(args, in: browser)
            let host = try await open(entry, in: browser, foreground: false)
            let read = try await host.read(full: (args["full"] as? Bool) ?? false)
            let shapes = (read["shapes"] as? [Any])?.count ?? 0
            Tools.summary?.line = "Read \(shapes) shape\(shapes == 1 ? "" : "s") on \(entry.name)"
            return [.text(json(read))]

        case "canvas_apply":
            guard let ops = args["ops"] as? [Any], !ops.isEmpty else { throw Failure(text: "ops (a non-empty array) required") }
            guard ops.count <= 1000 else { throw Failure(text: "at most 1000 ops per call") }
            let entry = try resolve(args, in: browser)
            let host = try await open(entry, in: browser, foreground: false)
            let agent = CanvasAgent.caller(args["as"])
            // Checklist assignees are named against the canvas's people: the page has them first.
            if CanvasChat.shared.offered(entry), CanvasTools.mentions(ops, key: "assignees") { await CanvasChat.shared.prepare(host) }
            let result = try await host.apply(ops, as: agent)
            let applied = (result["applied"] as? NSNumber)?.intValue ?? 0
            let errors = (result["errors"] as? [Any])?.count ?? 0
            Tools.summary?.line = "\(applied) operation\(applied == 1 ? "" : "s") applied\(errors > 0 ? ", \(errors) failed" : "") on \(entry.name)"
            return [.text(json(result))]

        case "canvas_select", "canvas_focus":
            let entry = try resolve(args, in: browser)
            let wanted = (args["shapeIds"] as? [Any] ?? args["ids"] as? [Any] ?? []).compactMap { $0 as? String }
            let host = try await open(entry, in: browser, foreground: false)
            if name == "canvas_select" {
                try await host.select(wanted)
                Tools.summary?.line = "Selected \(wanted.count) shape\(wanted.count == 1 ? "" : "s") on \(entry.name)"
                return [.text("Selected \(wanted.count) shape\(wanted.count == 1 ? "" : "s") on \(entry.name)")]
            }
            guard !wanted.isEmpty else { throw Failure(text: "shapeIds required") }
            try await host.zoom(to: wanted)
            Tools.summary?.line = "Showing \(wanted.count) shape\(wanted.count == 1 ? "" : "s") on \(entry.name)"
            return [.text("Showing \(wanted.count) shape\(wanted.count == 1 ? "" : "s") on \(entry.name)")]

        case "canvas_create":
            let name = (args["name"] as? String) ?? ""
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw Failure(text: "name required") }
            let entry = try await Canvases.shared.create(named: name)
            Tools.summary?.line = "Created \(entry.name)\(entry.isShared ? " (shared)" : " on this Mac")"
            return [.text(json(summary(entry, in: browser)))]

        case "canvas_invite":
            guard let key = args["id"] as? String, let entry = Canvases.shared.find(key) else { throw Failure(text: "no canvas \(args["id"] as? String ?? "") — canvas_list names them") }
            guard let email = args["email"] as? String, !email.isEmpty else { throw Failure(text: "email required") }
            let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
            let outcome: Canvases.InviteOutcome
            do { outcome = try await Canvases.shared.invite(entry.id, email: address) } catch {
                throw Failure(text: Canvases.plain(error, while: .inviting(address)))
            }
            let said = Canvases.inviteLine(outcome, email: address, canvas: entry.name)
            Tools.summary?.line = outcome.nudged == true ? "Reminded \(address) about \(entry.name)" : "Invited \(address) to \(entry.name)"
            return [.text(said)]

        case "canvas_share_link":
            let entry = try resolve(args, in: browser, fallbackToActive: false)
            let links: (link: String, webLink: String)
            do { links = try await Canvases.shared.shareLinks(entry.id) } catch {
                // An instance before 0.3.0 has no links: say so, and what still works.
                if (error as? Cloud.Failure)?.code == Canvases.linksUnsupportedCode {
                    throw Failure(text: Canvases.linksUnsupported + " (canvas_invite takes an email.)")
                }
                throw Failure(text: Canvases.plain(error, while: .linking))
            }
            Tools.summary?.line = "Share link for \(entry.name)"
            return [.text(json(["link": links.link, "webLink": links.webLink]))]

        case "canvas_join":
            guard let text = (args["link"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                throw Failure(text: "link required")
            }
            guard let url = URL(string: text), CanvasJoinLink.parse(url) != nil else {
                throw Failure(text: "not a canvas invite link: \(text)")
            }
            guard let parsed = CanvasJoinFlow.accepts(url) else {
                throw Failure(text: "couldn't open that invite — it may be for another Copper Cloud")
            }
            Tools.summary?.line = "Joining \(parsed.name ?? parsed.cloud)"
            // Waited for, so the answer says what happened rather than that it began.
            if let problem = await CanvasJoinFlow.join(parsed, in: browser) { throw Failure(text: problem) }
            let opened = CanvasHost.active(in: browser).flatMap { Canvases.shared.entry($0)?.name } ?? parsed.name ?? "the canvas"
            return [.text("Joined “\(opened)” from \(parsed.cloud)")]

        case "canvas_screenshot":
            let entry = try resolve(args, in: browser)
            let host = try await open(entry, in: browser, foreground: false)
            let data = try await host.picture()
            Tools.summary?.line = "Screenshot of \(entry.name)"
            return [.image(data, mime: "image/png"), .text("Canvas · \(entry.name)")]

        case CanvasChat.toolName:
            return try await CanvasChat.runTool(args, in: browser)

        default:
            throw Failure(text: "Unknown tool \(name)")
        }
    }

    // MARK: - helpers

    /// `id` (an id or a name), or `name`; nothing → the canvas in front, else Personal.
    @MainActor
    static func resolve(_ args: [String: Any], in browser: Browser, fallbackToActive: Bool = true) throws -> Canvases.Entry {
        for key in ["id", "name"] {
            guard let given = (args[key] as? String)?.trimmingCharacters(in: .whitespaces), !given.isEmpty else { continue }
            guard let entry = Canvases.shared.find(given) else { throw Failure(text: "no canvas “\(given)” — canvas_list names them") }
            return entry
        }
        if fallbackToActive, let id = CanvasHost.active(in: browser), let entry = Canvases.shared.entry(id) { return entry }
        return Canvases.shared.personal
    }

    /// The canvas's tab, made if there is none, and its host once the page has one.
    @MainActor
    static func open(_ entry: Canvases.Entry, in browser: Browser, foreground: Bool) async throws -> CanvasHost {
        let tab = CanvasHost.show(entry.id, in: browser, foreground: foreground)
        let deadline = Date().addingTimeInterval(15)
        var nudged = false
        while Date() < deadline {
            if let host = CanvasHost.host(for: tab) { return host }
            if !nudged {
                nudged = true
                if tab.asleep { _ = tab.wake() } else if tab.hollow { tab.revive() } else if tab.built == nil { _ = tab.web; tab.revive() }
            }
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        throw Failure(text: "the canvas tab for \(entry.name) didn't open")
    }

    @MainActor
    static func summary(_ entry: Canvases.Entry, in browser: Browser) -> [String: Any] {
        let presence = CanvasPresence.shared
        var out: [String: Any] = [
            "id": entry.id, "name": entry.name, "kind": entry.kind.rawValue,
            "open": CanvasHost.tab(showing: entry.id, in: browser) != nil,
            "live": presence.live.contains(entry.id),
            "collaborators": presence.peers[entry.id] ?? 0,
            "url": CanvasLinks.url(entry.id).absoluteString,
            "updatedAt": ISO8601DateFormatter().string(from: entry.updatedAt),
        ]
        if entry.isShared {
            out["role"] = entry.role ?? "editor"
            if let members = entry.members { out["members"] = members }
            if let owner = entry.owner { out["owner"] = owner }
        }
        return out
    }

    /// An invite, for the bench.
    @MainActor
    static func describe(_ invite: Canvases.Invite) -> [String: Any] {
        let stamp = ISO8601DateFormatter()
        var out: [String: Any] = ["id": invite.id, "canvas": invite.canvasName, "canvasId": invite.canvasId,
                                  "from": invite.from, "email": invite.email,
                                  "nudgedAt": invite.nudgedAt.map { stamp.string(from: $0) as Any } ?? NSNull()]
        if invite.inviteeKnown {
            out["invitee"] = invite.invitee.map { ["id": $0.id, "name": $0.name, "email": $0.email] as Any } ?? NSNull()
        }
        return out
    }

    @MainActor
    private static var cloudLine: String {
        if Canvases.shared.cloudReady {
            let personal = Canvases.shared.personalSyncs ? "Personal syncs with the account" : "Personal stays on this Mac (its sync is off)"
            return "signed in — new canvases are shared and can take invites; \(personal)"
        }
        if Cloud.shared.isLinked { return "linked, not signed in — canvases are local" }
        return "not connected — canvases are local to this Mac"
    }

    /// Whether any op (at any depth) carries `key` — e.g. checklist `assignees` in an add's shape or an update's patch.
    static func mentions(_ value: Any, key: String) -> Bool {
        if let object = value as? [String: Any] { return object[key] != nil || object.values.contains { mentions($0, key: key) } }
        if let list = value as? [Any] { return list.contains { mentions($0, key: key) } }
        return false
    }

    static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - the bench

    /// `bench canvas list | open ID | apply JSON | read [ID] | invites | hosts
    /// | create NAME | link [ID] | join LINK | presence [ID] | ui open|close`.
    /// Async — the page answers in its own time.
    @MainActor
    static func bench(_ request: [String: Any], in browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        let op = request["op"] as? String ?? "list"
        let arg = (request["arg"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        func decoded(_ text: String) -> [String: Any] {
            guard let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) else { return ["text": text] }
            if let object = value as? [String: Any] { return object }
            return ["value": value]
        }
        func content(_ parts: [Content]) -> [String: Any] {
            var texts: [String] = []
            for part in parts { if case .text(let text) = part { texts.append(text) } }
            return decoded(texts.joined(separator: "\n"))
        }
        Task { @MainActor in
            do {
                switch op {
                case "list":
                    answer(content(try await call("canvas_list", [:], in: browser)))
                case "open":
                    answer(content(try await call("canvas_open", ["id": arg.isEmpty ? Canvases.personalID : arg, "foreground": true], in: browser)))
                case "read":
                    answer(content(try await call("canvas_read", arg.isEmpty ? [:] : ["id": arg], in: browser)))
                case "apply":
                    let given = decoded(arg)
                    var args: [String: Any] = [:]
                    if let ops = given["value"] as? [Any] { args["ops"] = ops } else { args = given }
                    answer(content(try await call("canvas_apply", args, in: browser)))
                case "create":
                    answer(content(try await call("canvas_create", ["name": arg], in: browser)))
                case "invites":
                    // The invites waiting for this account, and the pill's.
                    await Canvases.shared.refresh()
                    answer(["invites": Canvases.shared.invites.map(describe),
                            "pill": Canvases.shared.newInvite.map(describe) ?? NSNull(),
                            "cloud": cloudLine, "problem": Canvases.shared.problem ?? ""])
                case "pill":
                    // `pill` what the pill at the window's foot shows; `pill dismiss` is
                    // its × (Not now); `pill open` its Open (joins, opens the canvas).
                    switch arg {
                    case "dismiss": Canvases.shared.dismissNewInvite()
                    case "open":
                        guard let invite = Canvases.shared.newInvite else { answer(["error": "no pill"]); return }
                        if let problem = await CanvasInvites.join(invite, in: browser).problem { answer(["error": problem]); return }
                    default: break
                    }
                    answer(["pill": Canvases.shared.newInvite.map(describe) ?? NSNull(), "invites": Canvases.shared.invites.count])
                case "pending":
                    // `pending ID`: the invites waiting on canvas ID, as its members see them.
                    guard let entry = Canvases.shared.find(arg) else { answer(["error": "pending ID — no canvas \(arg)"]); return }
                    let pending = try await Canvases.shared.canvasInvites(entry.id)
                    answer(["canvas": entry.name, "pending": pending.map(describe),
                            "reminders": Cloud.shared.supports(.inviteReminders).map { $0 as Any } ?? NSNull()])
                case "remind", "withdraw":
                    // `remind ID EMAIL` (invite again: a reminder on 0.5.0),
                    // `withdraw ID EMAIL|INVITE_ID` — what the Share sheet's Resend and × do.
                    let words = arg.split(separator: " ").map(String.init)
                    guard words.count >= 2, let entry = Canvases.shared.find(words.dropLast().joined(separator: " ")) else {
                        answer(["error": "\(op) ID EMAIL"]); return
                    }
                    let who = words.last ?? ""
                    if op == "remind" {
                        let outcome = try await Canvases.shared.invite(entry.id, email: who)
                        answer(["made": outcome.made, "nudged": outcome.nudged.map { $0 as Any } ?? NSNull(),
                                "invite": outcome.invite.map(describe) ?? NSNull(),
                                "said": Canvases.inviteLine(outcome, email: who, canvas: entry.name)])
                        return
                    }
                    let pending = try await Canvases.shared.canvasInvites(entry.id)
                    guard let invite = pending.first(where: { $0.id == who || $0.email.lowercased() == who.lowercased() }) else {
                        answer(["error": "no invite for \(who) on \(entry.name)", "pending": pending.map(\.email)]); return
                    }
                    try await Canvases.shared.withdraw(entry.id, invite: invite)
                    answer(["withdrawn": invite.id, "pending": (try await Canvases.shared.canvasInvites(entry.id)).map(describe)])
                case "accept", "decline":
                    // `accept INVITE_ID|CANVAS_NAME` — what the card's buttons do.
                    await Canvases.shared.refresh()
                    guard let invite = Canvases.shared.invites.first(where: { $0.id == arg || $0.canvasName == arg || $0.canvasId == arg }) else {
                        answer(["error": "no invite \(arg)", "invites": Canvases.shared.invites.map(\.id)])
                        return
                    }
                    let outcome = try await Canvases.shared.answer(invite, accept: op == "accept")
                    var out = content(try await call("canvas_list", [:], in: browser))
                    out["answer"] = outcome.rawValue
                    answer(out)
                case "stale":
                    // `stale accept|decline INVITE_ID CANVAS_ID` (test worlds): answer
                    // an invite by id as the pill and the Invitations row would, even
                    // one this Copper no longer lists — the stale pill a share-link
                    // join or a withdraw left on screen. Accept goes the pill's way
                    // (CanvasInvites.join: opens the canvas, or says it has gone).
                    let words = arg.split(separator: " ").map(String.init)
                    guard Store.testing, words.count == 3, ["accept", "decline"].contains(words[0]) else {
                        answer(["error": "stale accept|decline INVITE_ID CANVAS_ID (test worlds only)"]); return
                    }
                    let invite = Canvases.shared.invites.first { $0.id == words[1] }
                        ?? Canvases.Invite(id: words[1], canvasId: words[2], canvasName: "", from: "", createdAt: nil)
                    var out: [String: Any] = [:]
                    if words[0] == "accept" {
                        switch await CanvasInvites.join(invite, in: browser) {
                        case .opened: out["answer"] = "opened"
                        case .closed: out["answer"] = "closed"
                        case .failed(let said): out["error"] = said
                        }
                    } else {
                        out["answer"] = (try await Canvases.shared.answer(invite, accept: false)).rawValue
                    }
                    let front = browser.tabs.first { $0.id == browser.activeID }.flatMap(CanvasTabs.showing)
                    out["front"] = front ?? NSNull()
                    out["said"] = browser.announcement ?? NSNull()
                    out["member"] = Canvases.shared.entry(words[2]) != nil
                    out["listed"] = Canvases.shared.invites.contains { $0.id == words[1] || $0.canvasId == words[2] }
                    out["pill"] = Canvases.shared.newInvite.map(describe) ?? NSNull()
                    answer(out)
                case "rename", "delete", "leave", "members":
                    // `rename ID -> NAME` (or `rename ID NAME` for an id without spaces),
                    // `delete ID`, `leave ID`, `members ID` — the row's menu.
                    var words = [arg]
                    if op == "rename" {
                        words = arg.contains(" -> ") ? arg.components(separatedBy: " -> ") : arg.split(separator: " ", maxSplits: 1).map(String.init)
                    }
                    guard let key = words.first, let entry = Canvases.shared.find(key) else { answer(["error": "no canvas \(arg)"]); return }
                    switch op {
                    case "rename": try await Canvases.shared.rename(entry.id, to: words.count > 1 ? words[1] : entry.name)
                    case "delete": try await Canvases.shared.delete(entry.id)
                    case "leave": try await Canvases.shared.leave(entry.id)
                    default:
                        let members = try await Canvases.shared.members(entry.id)
                        answer(["members": members.map { ["name": $0.name, "email": $0.email, "role": $0.role] }])
                        return
                    }
                    answer(content(try await call("canvas_list", [:], in: browser)))
                case "hosts":
                    answer(["hosts": CanvasHost.all.map(\.describe), "page": CanvasPage.file?.path ?? "missing"])
                case "link":
                    answer(content(try await call("canvas_share_link", arg.isEmpty ? [:] : ["id": arg], in: browser)))
                case "join":
                    answer(content(try await call("canvas_join", ["link": arg], in: browser)))
                case "presence":
                    let entry = try resolve(arg.isEmpty ? [:] : ["id": arg], in: browser)
                    let host = try await open(entry, in: browser, foreground: false)
                    let people = try await host.presence()
                    answer(["canvas": entry.id, "people": people])
                case "chat":
                    // `chat …` — the chat panel, mentions and the pill (CanvasChatUI.swift).
                    answer(try await CanvasChat.bench(arg, in: browser))
                case "parsetest":
                    // The join-link parser is pure: a self-test, not a probe
                    // round trip — `bench canvas parsetest` runs it standing still.
                    answer(CanvasJoinLink.selfTest())
                case "ui":
                    // `ui open|close`, `ui mode list|new|rename ID|invite ID|members ID|delete ID`,
                    // `ui picture PATH [dark]` — the card drawn off screen, whole.
                    let words = arg.split(separator: " ").map(String.init)
                    let ui = CanvasUI.shared
                    switch words.first ?? "open" {
                    case "close": ui.popoverOpen = false
                    case "mode":
                        let id = words.count > 2 ? Canvases.shared.find(words[2...].joined(separator: " "))?.id ?? words[2] : ""
                        switch words.count > 1 ? words[1] : "list" {
                        case "new": ui.mode = .new
                        case "rename": ui.mode = .rename(id)
                        case "invite": ui.mode = .invite(id)
                        case "share": ui.mode = .share(id)
                        case "members": ui.mode = .members(id)
                        case "delete": ui.mode = .delete(id)
                        default: ui.mode = .list
                        }
                    case "share":
                        // `ui share state`, `ui share type TEXT` (the field, as typed),
                        // `ui share invite [EMAIL]` (the Invite row for it, or the typed one),
                        // `ui share copy` (Copy invite link) — on the sheet `ui mode share ID` opened.
                        guard let model = ui.share else { answer(["error": "no Share sheet — ui mode share ID first"]); return }
                        let instant = words.contains("--instant")
                        let rest = words.count > 2 ? words[2...].filter { $0 != "--instant" }.joined(separator: " ") : ""
                        switch words.count > 1 ? words[1] : "state" {
                        case "type": model.query = rest
                        case "invite":
                            guard let email = rest.isEmpty ? model.emailRow : rest else { answer(["error": "nothing to invite", "state": model.describe]); return }
                            model.invite(email)
                            // The row flips before the server answers: say so, as it was.
                            if instant { answer(model.describe); return }
                        case "resend", "withdraw":
                            guard let invite = model.pending.first(where: { $0.email.lowercased() == rest.lowercased() || $0.id == rest }) else {
                                answer(["error": "no invite waiting for \(rest)", "state": model.describe]); return
                            }
                            if words[1] == "resend" { model.resend(invite) } else { model.withdraw(invite) }
                        case "reload": await model.reloadMembers()
                        case "copy": model.copyLink()
                        default: break
                        }
                        // Let the round trip (and the debounced search) land before answering.
                        if words.count > 1, words[1] != "state" {
                            try? await Task.sleep(nanoseconds: 450_000_000)
                            for _ in 0..<20 where model.working || !model.acting.isEmpty { try? await Task.sleep(nanoseconds: 150_000_000) }
                        }
                        answer(model.describe)
                        return
                    case "picture":
                        guard words.count > 1 else { answer(["error": "ui picture PATH [dark]"]); return }
                        let dark = words.contains("dark")
                        guard let picture = await CanvasUI.picture(browser: browser, dark: dark),
                              let png = picture.representation(using: .png, properties: [:])
                        else { answer(["error": "could not draw the card"]); return }
                        try png.write(to: URL(fileURLWithPath: words[1]))
                        answer(["path": words[1]])
                        return
                    default: ui.popoverOpen = true
                    }
                    answer(["popover": ui.popoverOpen, "mode": "\(ui.mode)"])
                default:
                    // The tab, the row and the board (CanvasBench.swift).
                    benchTabs(request, in: browser, answer: answer)
                }
            } catch {
                answer(["error": (error as? Tools.Failure)?.text ?? "\(error)"])
            }
        }
    }
}
