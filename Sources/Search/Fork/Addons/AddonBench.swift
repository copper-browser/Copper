import AppKit
import WebKit

// `./bench agent addons …` (reached through MCP.bench, which the bench's
// `agent` verb falls through to): the addon machinery from the shell.
//
//     status                         state.json, what each window's slot shows, the log
//     check                          ask the cloud (or the fake) now
//     fake RESOLVED.json BUNDLES/|off   stand in for the cloud (test worlds)
//     stage BUNDLE.json              stage a served-format bundle file as if downloaded
//     install [SLOT]                 install what is staged
//     enable ID on|off · remove ID   the Settings switches
//     dev FOLDER|off                 COPPER_ADDONS_DEV_DIR, at run time
//     open · close                   the agent sidebar (⌘E)
//     reload                         the front window's slot page, again
//     emit EVENT [JSON]              an event to the front slot page
//     eval JS                        run JS in the front slot page; `result` has it
//     shot PNG                       picture the front window (PNG) and its slot
//                                    page (….slot.png); `result` has the paths
//     selftest BUNDLE.json [PNG]     install, open, call every bridge method,
//                                    picture the window; `result` has it
//     result                         what the last selftest or eval came to
//
// Anything that installs or stands in for the cloud runs in test worlds
// only: the bench must never change what a real profile runs.

@MainActor
enum AddonBench {
    private(set) static var last: [String: Any] = [:]

    static func handle(_ arg: String) -> [String: Any] {
        var words = arg.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let op = words.isEmpty ? "status" : words.removeFirst()
        let rest = words.joined(separator: " ")
        let sync = AddonSync.shared
        let changes = ["fake", "stage", "install", "dev", "selftest", "remove", "enable"]
        if changes.contains(op), !Store.testing {
            return ["error": "addons \(op) only works in a test world"]
        }
        switch op {
        case "status":
            return sync.status
        case "check":
            Task { await sync.check() }
            return ["checking": true]
        case "fake":
            if words.first == "off" || words.isEmpty {
                sync.fake = nil
                return ["fake": false]
            }
            guard words.count >= 2 else { return ["error": "addons fake RESOLVED.json BUNDLES-FOLDER"] }
            sync.fake = AddonSync.Fake(resolved: URL(fileURLWithPath: words[0]), bundles: URL(fileURLWithPath: words[1], isDirectory: true))
            Task { await sync.check() }
            return ["fake": true, "checking": true]
        case "stage":
            do {
                let entry = try sync.stage(file: URL(fileURLWithPath: rest))
                return ["staged": entry.id, "version": entry.version, "sha256": entry.sha256]
            } catch {
                return ["error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription]
            }
        case "install":
            let slot = words.first.flatMap(AddonSlot.init(rawValue:))
            if let problem = sync.install(slot) { return ["error": problem] }
            return sync.status
        case "enable":
            guard words.count == 2 else { return ["error": "addons enable ID on|off"] }
            sync.setEnabled(words[0], words[1] != "off")
            return sync.status
        case "remove":
            guard let id = words.first else { return ["error": "addons remove ID"] }
            sync.remove(id)
            return sync.status
        case "dev":
            sync.useDevelopment(rest.isEmpty || rest == "off" ? nil : URL(fileURLWithPath: rest, isDirectory: true))
            return ["development": sync.development?.dir ?? NSNull(), "problem": sync.developmentProblem ?? ""]
        case "open", "close":
            Agent.shared.open = op == "open"
            return ["open": Agent.shared.open]
        case "reload":
            guard let host = AddonSlotHost.front(.agentSidebar) else { return ["error": "the front window's slot has no page yet"] }
            host.retry()
            return ["reloading": host.entry?.id ?? ""]
        case "emit":
            guard let host = AddonSlotHost.front(.agentSidebar), let name = words.first else { return ["error": "addons emit EVENT [JSON] (with the slot open)"] }
            let json = words.dropFirst().joined(separator: " ")
            let payload = json.isEmpty ? NSNull() : ((try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])) ?? json)
            host.emit(name, payload)
            return ["emitted": name]
        case "eval":
            guard let web = AddonSlotHost.front(.agentSidebar)?.web else { return ["error": "the front window's slot has no page"] }
            last = ["eval": "running"]
            Task { @MainActor in
                do {
                    let value = try await run(web, rest)
                    last = ["eval": AddonBench.plain(value)]
                } catch {
                    last = ["eval": NSNull(), "error": error.localizedDescription]
                }
            }
            return ["started": true, "then": "addons result"]
        case "shot":
            guard !rest.isEmpty else { return ["error": "addons shot PNG"] }
            let file = URL(fileURLWithPath: rest)
            let browser = Windows.current
            last = ["shot": "running"]
            Task { @MainActor in
                var out: [String: Any] = ["shot": "done"]
                out["window"] = picture(browser, to: file) ? file.path : "couldn't picture the window"
                if let web = AddonSlotHost.front(.agentSidebar)?.web {
                    let slotShot = file.deletingPathExtension().appendingPathExtension("slot.png")
                    out["slot"] = await snapshot(web, to: slotShot) ? slotShot.path : "couldn't picture the slot"
                }
                last = out
            }
            return ["started": true, "then": "addons result"]
        case "selftest":
            guard let bundle = words.first else { return ["error": "addons selftest BUNDLE.json [PNG]"] }
            let shot = words.count > 1 ? URL(fileURLWithPath: words[1]) : nil
            selftest(URL(fileURLWithPath: bundle), shot: shot)
            return ["started": true, "then": "addons result"]
        case "result":
            return last
        default:
            return ["error": "addons status|check|fake|stage|install|enable|remove|dev|open|close|reload|emit|eval|shot|selftest|result"]
        }
    }

    /// What `callAsyncJavaScript` hands back, as plain JSON for the answer.
    static func plain(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        if JSONSerialization.isValidJSONObject([value]) { return value }
        return "\(value)"
    }

    // MARK: - selftest

    /// Every bridge method, from inside the page, in the page's own world.
    /// Methods that would act on the person's things are called the way
    /// that is refused (a bad URL, an unknown model), which still goes the
    /// whole way through the bridge and back.
    static let probe = """
    const c = window.copper;
    if (!c) return {error: "no window.copper"};
    const out = {};
    async function t(name, f) {
      try { out[name] = {ok: true, value: await f()}; }
      catch (e) { out[name] = {ok: false, code: e && e.code, message: e && e.message}; }
    }
    await t("info", () => c.info());
    await t("identity", () => c.identity());
    await t("settings", () => c.settings());
    await t("storage.set", () => c.storage.set("bench-selftest", {n: 1}));
    await t("storage.get", () => c.storage.get("bench-selftest"));
    await t("storage.keys", () => c.storage.keys().then(k => k.includes("bench-selftest") ? k : Promise.reject({code: "mismatch", message: "keys() missed bench-selftest: " + JSON.stringify(k)})));
    await t("storage.remove", () => c.storage.remove("bench-selftest"));
    await t("fetch", () => c.fetch("https://example.com/", {timeoutMs: 15000}).then(r => ({status: r.status, type: r.headers["content-type"] || "", bytes: r.body.length})));
    await t("fetch.denied", () => c.fetch("https://denied.invalid/"));
    await t("oauth.authorize.denied", () => c.oauth.authorize({url: "https://denied.invalid/authorize", redirectPrefix: "http://127.0.0.1:53682/callback"}));
    await t("openUrl.refused", () => c.openUrl("javascript:void(0)"));
    await t("page.current", () => c.page.current());
    await t("agent.state", () => c.agent.state().then(s => ({available: s.available, busy: s.busy, model: s.model, models: s.models.length, items: s.items.length})));
    await t("agent.setModel.refused", () => c.agent.setModel("no-such-model"));
    await t("agent.send.refused", () => c.agent.send(""));
    await t("agent.stop", () => c.agent.stop());
    out.secureContext = window.isSecureContext;
    out.origin = location.origin;
    out.cspBlocksNetwork = await fetch("https://example.com/").then(() => false, () => true);
    out.windowOpenRefused = window.open("https://example.com/") === null;
    return out;
    """

    private static func selftest(_ bundle: URL, shot: URL?) {
        last = ["selftest": "running"]
        Task { @MainActor in
            var out: [String: Any] = ["selftest": "done"]
            do {
                let sync = AddonSync.shared
                let staged = try sync.stage(file: bundle)
                guard let slot = AddonSlot(rawValue: staged.slot) else { throw AddonProblem(code: "slot", message: "unknown slot") }
                if let problem = sync.install(slot) { throw AddonProblem(code: "install", message: problem) }
                sync.setEnabled(staged.id, true)
                out["installed"] = ["id": staged.id, "version": staged.version, "sha256": staged.sha256]
                Agent.shared.open = true
                let browser = Windows.current
                let host = AddonSlotHost.host(for: browser, slot: slot)
                for _ in 0..<150 where !(host.loaded && host.entry?.sha256 == staged.sha256) && host.failed == nil {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                out["loaded"] = host.loaded
                out["visible"] = host.visible
                out["failed"] = host.failed ?? ""
                guard host.loaded, let web = host.web else {
                    last = out
                    return
                }
                let value = try await run(web, probe)
                out["calls"] = plain(value)
                // A beat for a page that draws what it got.
                try await Task.sleep(nanoseconds: 800_000_000)
                if let shot {
                    out["window"] = picture(browser, to: shot) ? shot.path : "couldn't picture the window"
                    let slotShot = shot.deletingPathExtension().appendingPathExtension("slot.png")
                    out["slot"] = await snapshot(web, to: slotShot) ? slotShot.path : "couldn't picture the slot"
                }
                // ui.close last: the slot hides, the page stays and hears it.
                let closed = try await run(web, "return await window.copper.ui.close()")
                try await Task.sleep(nanoseconds: 300_000_000)
                out["ui.close"] = ["value": plain(closed), "agentOpen": Agent.shared.open, "pageKept": host.web != nil, "visible": host.visible]
                Agent.shared.open = true
            } catch {
                out["error"] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            last = out
        }
    }

    private static func picture(_ browser: Browser, to file: URL) -> Bool {
        guard let window = Windows.window(of: browser), let image = Fork.layered([CGWindowID(window.windowNumber)]) else { return false }
        return CanvasBench.write(image, to: file.path)
    }

    private static func snapshot(_ web: WKWebView, to file: URL) async -> Bool {
        let image: NSImage? = await withCheckedContinuation { continuation in
            web.takeSnapshot(with: nil) { image, _ in continuation.resume(returning: image) }
        }
        guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: file)) != nil
    }

    /// `body` as an async function in the page's world (as CanvasHost.call:
    /// the completion form, which hands back a bare `undefined` safely).
    private static func run(_ web: WKWebView, _ body: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            web.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value is NSNull ? nil : value)
                case .failure(let error):
                    let ns = error as NSError
                    let detail = (ns.userInfo["WKJavaScriptExceptionMessage"] as? String) ?? ns.localizedDescription
                    continuation.resume(throwing: AddonProblem(code: "js", message: detail))
                }
            }
        }
    }
}
