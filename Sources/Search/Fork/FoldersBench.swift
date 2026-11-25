import AppKit
import Foundation

// `./bench folders live|shared …` — drive live folders and shared folders in
// a world. Anything that edits the sidebar, shows an invite or takes a token
// answers in test worlds only.
//
//   live                          the live folders, their pull requests, unread
//   live add [both|reviews|mine]  a GitHub folder in this space
//   live api URL                  a stand-in for api.github.com
//   live token-file PATH          connect with the token in PATH (never on the command line)
//   live refresh | read | forget | remove | log
//   live open N                   open pull request N (from 0) as a tab
//   live picture PATH             the sidebar
//   shared                        every shared folder: health, path, files, records
//   shared root PATH              where shared folders are made and looked for
//   shared add NAME URL [SUB]     a Saved tab in folder NAME (made if need be), or in NAME › SUB
//   shared share NAME             share it: the invite link and words
//   shared join TEXT              join with an invite link or the words
//   shared links NAME             what the folder holds here, with its subfolders
//   shared close NAME URL…        close those tabs at once, as a person would
//   shared rename NAME NEW | move NAME URL SUB | stop NAME | let NAME | back NAME
//   shared now | log | files NAME
//   shared picture PATH | sheet NAME PATH

@MainActor
enum FoldersBench {
    static func handle(_ request: [String: Any], in browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        let area = request["op"] as? String ?? ""
        let words = (request["arg"] as? String ?? "").split(separator: " ").map(String.init)
        let op = words.first ?? ""
        let rest = Array(words.dropFirst())
        func test() -> Bool {
            guard Store.testing else { answer(["error": "test worlds only"]); return false }
            return true
        }
        switch area {
        case "live": live(op, rest, in: browser, test: test, answer: answer)
        case "shared": shared(op, rest, in: browser, test: test, answer: answer)
        default: answer(["error": "usage: folders live|shared …"])
        }
    }

    // MARK: - live

    static func liveState() -> [String: Any] {
        let live = LiveFolders.shared
        return [
            "token": live.hasToken, "login": (live.login as Any?) ?? NSNull(), "api": live.api.absoluteString,
            "folders": live.all.map { f in
                [
                    "id": String(f.id.uuidString.prefix(8)).lowercased(), "name": f.name, "show": f.show.rawValue,
                    "collapsed": f.collapsed, "problem": (f.problem as Any?) ?? NSNull(), "unread": f.unreadCount,
                    "refreshed": (f.refreshed as Any?) ?? NSNull(),
                    "items": f.items.map { i in
                        ["title": i.title, "url": i.url, "repo": i.repo, "number": i.number, "review": i.review,
                         "mine": i.mine, "draft": i.draft, "unread": f.unread(i)] as [String: Any]
                    },
                ] as [String: Any]
            },
        ]
    }

    private static func live(_ op: String, _ rest: [String], in browser: Browser, test: () -> Bool, answer: @escaping ([String: Any]) -> Void) {
        let live = LiveFolders.shared
        let space = Spaces.shared.current(in: browser)
        switch op {
        case "", "list": answer(liveState())
        case "add":
            guard test() else { return }
            let show = rest.first.flatMap(LiveFolder.Show.init(rawValue:)) ?? .both
            live.add(in: space, show: show)
            answer(liveState())
        case "api":
            guard test(), let url = rest.first else { return answer(["error": "usage (test worlds): folders live api URL"]) }
            live.setTestAPI(url)
            answer(["api": live.api.absoluteString])
        case "token-file":
            guard test(), let path = rest.first, let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
                return answer(["error": "usage (test worlds): folders live token-file PATH"])
            }
            Task {
                do { try await live.connect(raw) } catch {
                    return answer(["error": (error as? GitHubPulls.Failure)?.text ?? error.localizedDescription])
                }
                answer(liveState())
            }
        case "refresh":
            Task { await live.refreshAll(manual: true); answer(liveState()) }
        case "read":
            for f in live.all { live.markAllRead(f.id) }
            answer(liveState())
        case "open":
            guard test(), let folder = live.all.first(where: { $0.space == space }) ?? live.all.first,
                  let n = rest.first.flatMap(Int.init), folder.items.indices.contains(n) else { return answer(["error": "usage: folders live open N"]) }
            live.open(folder.items[n], in: folder.id, browser: browser)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                var out = liveState()
                out["active"] = (browser.active.flatMap { ($0.pending ?? $0.address)?.absoluteString } as Any?) ?? NSNull()
                out["tabs"] = browser.tabs.count
                answer(out)
            }
        case "forget":
            guard test() else { return }
            live.disconnect()
            answer(liveState())
        case "remove":
            guard test() else { return }
            for f in live.all { live.remove(f.id) }
            answer(liveState())
        case "log": answer(["log": Array(live.log.suffix(40))])
        case "picture":
            guard let path = rest.first else { return answer(["error": "usage: folders live picture PATH"]) }
            answer(SideHand.picture(to: path, extra: 0, in: browser))
        default:
            answer(["error": "unknown folders live op \(op) — list|add|api|token-file|refresh|read|open|forget|remove|log|picture"])
        }
    }

    // MARK: - shared

    static func sharedState() -> [String: Any] {
        let shared = SharedFolders.shared
        return [
            "root": shared.root.path,
            "folders": shared.bindings.map { b -> [String: Any] in
                let health = shared.health[b.id]
                let name = Groups.shared.group(b.group).map(\.name) ?? ""
                return [
                    "name": name, "path": b.path, "owner": b.owner, "health": health?.text ?? "—", "bad": health?.bad ?? false,
                    "files": b.files.count, "seq": b.seq, "damaged": shared.damaged[b.id] ?? 0,
                    "links": b.base.keys.filter { $0.hasPrefix("ln:") }.count, "device": b.device,
                ]
            },
        ]
    }

    /// What a folder and the folders in it hold here: `[sub, url]`, sorted.
    private static func links(_ top: TabGroup, in browser: Browser) -> [[String]] {
        var seen = Set<Tab.ID>()
        var out: [[String]] = []
        for group in Groups.shared.all where group.id == top.id || Folders.below(group.name, top.name) {
            let sub = group.id == top.id ? "" : String(group.name.dropFirst(top.name.count + Folders.mark.count))
            for tab in Groups.shared.members(of: group.id, in: browser) where seen.insert(tab.id).inserted {
                out.append([sub, (tab.pending ?? tab.address)?.absoluteString ?? "", tab.title])
            }
        }
        return out.sorted { $0[1] < $1[1] }
    }

    private static func tab(_ url: String, in top: TabGroup, browser: Browser) -> Tab? {
        for group in Groups.shared.all where group.id == top.id || Folders.below(group.name, top.name) {
            if let tab = Groups.shared.members(of: group.id, in: browser).first(where: { ($0.pending ?? $0.address)?.absoluteString == url }) { return tab }
        }
        return nil
    }

    private static func shared(_ op: String, _ rest: [String], in browser: Browser, test: () -> Bool, answer: @escaping ([String: Any]) -> Void) {
        let shared = SharedFolders.shared
        let groups = Groups.shared
        func folder(_ name: String?) -> TabGroup? { name.flatMap { groups.group(matching: $0) } }
        switch op {
        case "", "status": answer(sharedState())
        case "root":
            guard test(), let path = rest.first else { return answer(["error": "usage (test worlds): folders shared root PATH"]) }
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            shared.setTestRoot(path)
            answer(sharedState())
        case "add":
            guard test(), rest.count >= 2, let url = URL(string: rest[1]) else { return answer(["error": "usage: folders shared add NAME URL [SUB]"]) }
            let space = Spaces.shared.current(in: browser)
            var top = folder(rest[0])
            if top == nil {
                let made = groups.adding(named: rest[0], hue: nil)
                groups.imported(made.id, collapsed: false, space: space, slot: nil)
                top = groups.group(made.id)
            }
            guard let top else { return answer(["error": "no folder"]) }
            var into = top
            if rest.count > 2 {
                let name = top.name + Folders.mark + rest[2]
                into = groups.all.first { $0.name == name } ?? groups.createInside(top, named: rest[2]) ?? top
            }
            guard let tab = Spaces.shared.cloudOpen(url, title: url.host() ?? rest[1], pin: nil, in: space, browser: browser) else { return answer(["error": "couldn't open"]) }
            groups.cloudFile(tab, in: into.id)
            answer(["links": links(top, in: browser)])
        case "share":
            guard test(), let group = folder(rest.joined(separator: " ")) else { return answer(["error": "usage: folders shared share NAME"]) }
            Task {
                do {
                    let invite = try await shared.share(group, in: browser)
                    answer(["link": invite.link, "words": invite.words.joined(separator: " "), "status": sharedState()])
                } catch { answer(["error": error.localizedDescription]) }
            }
        case "join":
            guard test(), !rest.isEmpty else { return answer(["error": "usage: folders shared join LINK|WORDS"]) }
            Task {
                do {
                    let b = try await shared.join(rest.joined(separator: " "), in: browser)
                    let name = groups.group(b.group)
                    answer(["joined": name?.name ?? "", "links": name.map { links($0, in: browser) } ?? [], "status": sharedState()])
                } catch { answer(["error": error.localizedDescription]) }
            }
        case "links":
            guard let top = folder(rest.joined(separator: " ")) else { return answer(["error": "no folder \(rest.joined(separator: " "))"]) }
            answer(["name": top.name, "links": links(top, in: browser)])
        case "close":
            // Several at once, in one go: what a flattened folder looks like.
            guard test(), rest.count >= 2, let top = folder(rest[0]) else { return answer(["error": "usage: folders shared close NAME URL…"]) }
            let tabs = rest.dropFirst().compactMap { tab($0, in: top, browser: browser) }
            guard tabs.count == rest.count - 1 else { return answer(["error": "not every URL is in \(top.name)"]) }
            for tab in tabs {
                if browser.tabs.contains(where: { $0.id == tab.id }) { Sections.shared.closeForGood(tab, in: browser) } else { Spaces.shared.cloudClose(tab, browser: browser) }
            }
            answer(["links": links(top, in: browser)])
        case "rename":
            guard test(), rest.count == 2, let top = folder(rest[0]) else { return answer(["error": "usage: folders shared rename NAME NEW"]) }
            groups.rename(top.id, to: rest[1])
            answer(["name": groups.group(top.id)?.name ?? ""])
        case "move":
            guard test(), rest.count == 3, let top = folder(rest[0]), let tab = tab(rest[1], in: top, browser: browser) else {
                return answer(["error": "usage: folders shared move NAME URL SUB"])
            }
            let name = top.name + Folders.mark + rest[2]
            let into = groups.all.first { $0.name == name } ?? groups.createInside(top, named: rest[2]) ?? top
            groups.cloudFile(tab, in: into.id)
            answer(["links": links(top, in: browser)])
        case "stop", "let", "back":
            guard test(), let top = folder(rest.joined(separator: " ")), let b = shared.binding(of: top.id) else { return answer(["error": "not a shared folder"]) }
            if op == "stop" { shared.stop(b.id) } else if op == "let" { shared.letHeldThrough(b.id) } else { shared.putHeldBack(b.id) }
            answer(sharedState())
        case "now":
            Task { await shared.syncNow(); answer(sharedState()) }
        case "log": answer(["log": Array(shared.log.suffix(60))])
        case "files":
            guard let top = folder(rest.joined(separator: " ")), let b = shared.binding(of: top.id) else { return answer(["error": "not a shared folder"]) }
            let all = (try? FileManager.default.subpathsOfDirectory(atPath: b.path)) ?? []
            answer(["path": b.path, "files": all.sorted()])
        case "picture":
            guard let path = rest.first else { return answer(["error": "usage: folders shared picture PATH"]) }
            answer(SideHand.picture(to: path, extra: 0, in: browser))
        case "sheet":
            guard rest.count >= 2, let top = folder(rest.dropLast().joined(separator: " ")), let b = shared.binding(of: top.id) else {
                return answer(["error": "usage: folders shared sheet NAME PATH"])
            }
            let path = rest.last!
            guard let picture = SettingsPicture.draw(SharedFolderSheet(id: b.id, browser: browser).frame(width: 440), dark: false),
                  let png = picture.representation(using: .png, properties: [:]) else { return answer(["error": "couldn't draw"]) }
            do { try png.write(to: URL(fileURLWithPath: path)) } catch { return answer(["error": error.localizedDescription]) }
            answer(["path": path])
        default:
            answer(["error": "unknown folders shared op \(op) — status|root|add|share|join|links|close|rename|move|stop|let|back|now|log|files|picture|sheet"])
        }
    }
}
