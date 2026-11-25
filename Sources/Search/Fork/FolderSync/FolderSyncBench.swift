import AppKit
import Foundation

// `./bench icloud …` — drive iCloud sync in a world. Anything that shows or
// takes the phrase, or edits the browser, answers in test worlds only.
//
//   status                     on, status, folder, records, peers, files
//   folder PATH                sync through PATH (while off)
//   on                         turn on: a new phrase (its words, in a test world)
//   join WORD…                 join with a phrase
//   phrase                     the words (test worlds)
//   off [delete]               stop; delete also removes the phrase's folder
//   now                        a cycle, awaited
//   set DOMAIN on|off          a domain's switch
//   doc spaces|settings|bookmarks|history|tabs|extensions
//                              what the folder says, merged
//   log                        the last lines of the sync log
//   files                      the files read, by kind and device
//   setting KEY VALUE          change an allowlisted setting here (test worlds)
//   unbookmark URL             remove a bookmark here (test worlds)
//   picture PATH [dark] [kit]  the iCloud sync section, drawn (kit: the Recovery Kit open)
//   kit PATH                   the Recovery Kit PDF (test worlds)

@MainActor
enum FolderSyncBench {
    static func handle(_ request: [String: Any], in browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        let op = request["op"] as? String ?? "status"
        let rest = (request["arg"] as? String ?? "").split(separator: " ").map(String.init)
        let sync = FolderSync.shared
        func test() -> Bool {
            if !Store.testing { answer(["error": "test worlds only"]) }
            return Store.testing
        }
        switch op {
        case "status":
            answer(status())
        case "folder":
            guard let path = rest.first else { return answer(["folder": sync.folder.path]) }
            guard !sync.on else { return answer(["error": "sync is on — stop it first"]) }
            sync.choose(folder: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true))
            answer(["folder": sync.folder.path, "holdsData": SyncVault.holdsData(sync.folder)])
        case "on":
            Task {
                do {
                    let phrase = try await sync.turnOn()
                    var out = status()
                    if Store.testing { out["phrase"] = phrase.joined(separator: " ") }
                    answer(out)
                } catch { answer(["error": error.localizedDescription]) }
            }
        case "join":
            Task {
                do {
                    try await sync.join(phrase: rest.joined(separator: " "))
                    answer(status())
                } catch { answer(["error": error.localizedDescription]) }
            }
        case "phrase":
            guard test() else { return }
            answer(["phrase": (sync.testPhrase()?.joined(separator: " ") as Any?) ?? NSNull()])
        case "off":
            Task {
                await sync.stop(deleting: rest.first == "delete")
                answer(status())
            }
        case "now":
            Task {
                await sync.syncNow()
                answer(status())
            }
        case "set":
            guard rest.count == 2, let domain = FolderSync.Domain(rawValue: rest[0]), ["on", "off"].contains(rest[1]) else {
                return answer(["error": "usage: icloud set \(FolderSync.Domain.allCases.map(\.rawValue).joined(separator: "|")) on|off"])
            }
            sync.set(domain, rest[1] == "on")
            answer(["enabled": sync.enabled.map(\.rawValue).sorted()])
        case "doc":
            guard let domain = rest.first.flatMap(FolderSync.Domain.init(rawValue:)) else { return answer(["error": "usage: icloud doc DOMAIN"]) }
            answer(["domain": domain.rawValue, "doc": doc(domain)])
        case "log":
            answer(["log": Array(sync.log.suffix(60))])
        case "files":
            answer(["files": sync.state.files.map { name, meta in
                ["name": name, "kind": meta.kind, "device": meta.device, "seq": meta.seq ?? 0, "size": meta.size] as [String: Any]
            }.sorted { ($0["name"] as! String) < ($1["name"] as! String) }])
        case "setting":
            guard test() else { return }
            guard rest.count == 2 else { return answer(["error": "usage: icloud setting KEY VALUE"]) }
            var values = CloudApply.settings(browser).values
            values[rest[0]] = rest[1]
            guard CloudSettingsKeys.filter(values)[rest[0]] == rest[1] else { return answer(["error": "not an allowlisted setting and value"]) }
            CloudApply.apply(settings: CloudDocs.Settings(values: values), in: browser)
            answer(["settings": CloudApply.settings(browser).values])
        case "unbookmark":
            guard test() else { return }
            guard let raw = rest.first else { return answer(["error": "usage: icloud unbookmark URL"]) }
            func find(_ nodes: [Bookmark]) -> Bookmark.ID? {
                for node in nodes {
                    if node.url == raw { return node.id }
                    if let id = find(node.children ?? []) { return id }
                }
                return nil
            }
            guard let id = find(browser.bookmarks.roots) else { return answer(["error": "no bookmark for \(raw)"]) }
            browser.bookmarks.remove(id)
            answer(["bookmarks": Bookmarks.count(browser.bookmarks.roots)])
        case "picture":
            guard let path = rest.first else { return answer(["error": "usage: icloud picture PATH [dark] [kit]"]) }
            // kit: as right after Turn On Sync, the Recovery Kit open (test worlds).
            let kit = rest.contains("kit") && Store.testing ? sync.testPhrase() : nil
            guard let picture = SettingsPicture.draw(ICloudSyncPage(browser: browser, kit: kit), dark: rest.contains("dark")),
                  let png = picture.representation(using: .png, properties: [:]) else { return answer(["error": "could not draw the page"]) }
            do { try png.write(to: URL(fileURLWithPath: path)) } catch { return answer(["error": error.localizedDescription]) }
            answer(["path": path, "size": [picture.pixelsWide, picture.pixelsHigh]])
        case "kit":
            guard test(), let path = rest.first, let phrase = sync.testPhrase() else { return answer(["error": "usage (test worlds, sync on): icloud kit PATH"]) }
            do { try SyncKit.pdf(phrase, folder: sync.folder).write(to: URL(fileURLWithPath: path)) } catch { return answer(["error": error.localizedDescription]) }
            answer(["path": path])
        default:
            answer(["error": "unknown icloud op \(op) — status|folder|on|join|phrase|off|now|set|doc|log|files|setting|unbookmark|picture|kit"])
        }
    }

    static func status() -> [String: Any] {
        let sync = FolderSync.shared
        let status: String
        switch sync.status {
        case .off: status = "off"
        case .starting: status = "starting"
        case .updating: status = "updating"
        case .updated: status = "updated"
        case .offline: status = "offline"
        case .failed(let why): status = "failed: \(why)"
        case .reset: status = "reset"
        }
        return [
            "on": sync.on, "status": status, "joining": sync.joining, "folder": sync.folder.path,
            "device": sync.state.device, "seq": sync.state.seq, "waiting": sync.waiting,
            "enabled": sync.enabled.map(\.rawValue).sorted(), "records": sync.counts,
            "files": sync.state.files.count, "damaged": sync.state.damaged.count,
            "held": (sync.held?.text as Any?) ?? NSNull(),
            "peers": sync.peers.map { ["name": $0.name, "tabs": $0.tabs.map(\.url)] as [String: Any] },
            "lastSync": (sync.lastSync.map { $0.timeIntervalSince1970 } as Any?) ?? NSNull(),
        ]
    }

    /// The folder's merged state of a domain, decoded.
    private static func doc(_ domain: FolderSync.Domain) -> Any {
        let live = FolderSync.shared.state.replica.live(SyncRecords.of(domain.kind))
        func json<T: Encodable>(_ value: T) -> Any {
            (try? JSONSerialization.jsonObject(with: Data(SyncRecords.encode(value).utf8))) ?? NSNull()
        }
        switch domain {
        case .spaces: return json(SyncRecords.spaces(live))
        case .settings: return json(SyncRecords.settings(live))
        case .bookmarks: return json(SyncRecords.bookmarks(live))
        case .history, .tabs, .extensions:
            var out: [String: Any] = [:]
            for (key, value) in live { out[key] = (try? JSONSerialization.jsonObject(with: Data(value.utf8))) ?? value }
            return out
        }
    }
}
