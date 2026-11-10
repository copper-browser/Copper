import AppKit
import WebKit

// Pinned tabs never unload.
//
// Felipe: "I want to be in a tab and it NEVER deloads from memory." A pin —
// one of the favourites every space shows (Spaces.pins) — is a page kept open
// all day, Gmail or a calendar, and coming back to one to find it loading
// again was the browser forgetting the one thing it had been asked to keep.
// So a pin has a live page from the moment it is pinned, or from launch,
// until it is unpinned. There is no setting for it.
//
// - Nothing puts one to sleep. The idle sweep and memory pressure passed over
//   pins already (`Browser.awake(because:)` says "pinned"); `Tab.sleep(picture:)`
//   and `Tab.rest()` now refuse one as well (`PinRule`), so no caller can
//   let a pin's page go by accident — only closing it for good can.
// - ⌘W on a pin — and the pin's cross, Close Tab, Close Other Tabs, an
//   agent's or an extension's close — steps away from it: you land where a
//   close would have landed you, and the page stays loaded (Browser.close).
//   Before, ⌘W put the pin down and the page went with it.
// - A pin with no page — every pin but the one on screen after a launch, one
//   pinned while it was put down, one another Mac sent — is loaded in the
//   background, one at a time, once the launch has settled: in the Room,
//   the way SpaceWarm loads each space's page, so it boots as a page in view
//   and then rests like any tab you have left.
// - A pin whose page's process went away out of sight — macOS took it back
//   under memory pressure, or it crashed — is loaded again at once, in the
//   background. A page that takes its process down as it loads would be
//   loaded for ever out of sight, so a pin gets three of those reloads in ten
//   minutes (`PinReloads`); after that it waits, as any other tab does, to be
//   loaded when you come back to it, and the trail says so.
//
// Unpinned, it is an ordinary tab again and sleeps by the ordinary rules.

/// Whether a tab may give its page back, and why it would. Pure, so the
/// tests can say it.
enum PinRule {
    enum Unload {
        /// Left too long, memory short, `chrome.tabs.discard` (Sleep.swift).
        case sleep
        /// ⌘W on a Saved row (Fork/Sections.swift).
        case putDown
        /// Gone for good: closed, or unpinned first and then anything.
        case close
    }

    /// A pin keeps its page until it is closed for good; any other tab may
    /// let it go for any reason.
    static func mayUnload(pinned: Bool, _ why: Unload) -> Bool {
        switch why {
        case .close: return true
        case .sleep, .putDown: return !pinned
        }
    }

    /// A pin with somewhere to be and no page there: asleep, or with no view
    /// at all. A blank pin has nothing to load.
    static func needsPage(pinned: Bool, blank: Bool, asleep: Bool, built: Bool) -> Bool {
        pinned && !blank && (asleep || !built)
    }
}

/// How many times each pin's page is loaded again on its own after its
/// process went away: at most `limit` in `window` seconds. Pure, so the
/// tests can wind the clock.
struct PinReloads {
    var limit = 3
    var window: TimeInterval = 10 * 60
    private var times: [UUID: [Date]] = [:]

    /// Whether `id` may be reloaded now — counted when it may.
    mutating func allow(_ id: UUID, at now: Date = Date()) -> Bool {
        let recent = (times[id] ?? []).filter { now.timeIntervalSince($0) < window }
        guard recent.count < limit else {
            times[id] = recent
            return false
        }
        times[id] = recent + [now]
        return true
    }

    /// The reloads `id` has had inside the window.
    func count(_ id: UUID, at now: Date = Date()) -> Int {
        (times[id] ?? []).filter { now.timeIntervalSince($0) < window }.count
    }

    mutating func forget(_ id: UUID) { times[id] = nil }
}

@MainActor
final class PinsAwake {
    static let shared = PinsAwake()

    private(set) var reloads = PinReloads()
    /// Pins waiting for their page, the next first; a reload after a process
    /// went away goes to the front.
    private var waiting: [(id: Tab.ID, reload: Bool)] = []
    /// The pin being loaded in the Room now.
    private var loading: Tab.ID?
    /// What follows the first round at launch (SpaceWarm's spaces).
    private var afterwards: [() -> Void] = []
    private var started = false
    private weak var browser: Browser?
    private var looking = false

    private init() {}

    /// Once, after the launch has settled (SpaceWarm.start): every pin
    /// without a page is loaded, then `then` runs. From here on, any pin that
    /// turns up without a page — pinned while asleep or put down, sent by
    /// another Mac, brought in by a move-in — is loaded the same way, a
    /// moment after Spaces says its rows changed (`changed`).
    func start(in browser: Browser, then: @escaping () -> Void) {
        guard !started else { return then() }
        started = true
        self.browser = browser
        afterwards.append(then)
        look()
    }

    /// Spaces changed its rows or its pins (Spaces.keep, which every edit
    /// ends in). They come in bursts: one look, half a second after the
    /// first of them. Nothing before the launch has settled.
    func changed() {
        guard started, !looking else { return }
        looking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            looking = false
            look()
        }
    }

    private func look() {
        for tab in Spaces.shared.pins where Self.needsPage(tab) && tab.id != loading && !waiting.contains(where: { $0.id == tab.id }) {
            waiting.append((tab.id, false))
        }
        next()
    }

    static func needsPage(_ tab: Tab) -> Bool {
        PinRule.needsPage(pinned: tab.pin != nil, blank: tab.isBlank, asleep: tab.asleep, built: tab.built != nil)
    }

    /// WebKit says a page's process went away while the page was not the one
    /// in front (Dialogs.swift). For a pin, the page is loaded again now and
    /// this answers true; false leaves the tab to be reloaded when it is next
    /// looked at (`Tab.stale`), as every other tab is — and a pin is, once
    /// it has had its three reloads in ten minutes.
    func processGone(_ tab: Tab, in browser: Browser) -> Bool {
        guard tab.pin != nil, !tab.isBlank, !tab.asleep, tab.built != nil else { return false }
        let host = tab.address?.host() ?? "-"
        guard reloads.allow(tab.id) else {
            Breadcrumbs.note("pin-reload-stop", [("host", host), ("n", String(reloads.count(tab.id)))])
            return false
        }
        Breadcrumbs.note("pin-reload", [("host", host), ("n", String(reloads.count(tab.id)))])
        if self.browser == nil { self.browser = browser }
        // Still on a stage, hung for an agent or already in the Room: it has
        // a window, so the load goes now and is seen there.
        if tab.built?.window != nil {
            tab.recoverFromCrash()
            return true
        }
        waiting.removeAll { $0.id == tab.id }
        waiting.insert((tab.id, true), at: 0)
        next()
        return true
    }

    /// A ⌘N window closed (Windows.closed). A tab answers to the window it
    /// was made in — its links, its sign-in windows, its process going away
    /// all go there — and a pin made in that window is still every window's,
    /// its page still loaded: the first window answers for it from now on.
    func rehome(from gone: Browser) {
        let main = Windows.main
        guard main !== gone else { return }
        for tab in Spaces.shared.pins where tab.delegate == nil || tab.delegate === gone { main.prepare(tab) }
    }

    /// One at a time, each in the Room until it has loaded.
    private func next() {
        guard loading == nil else { return }
        guard !waiting.isEmpty else {
            let then = afterwards
            afterwards = []
            then.forEach { $0() }
            return
        }
        let (id, reload) = waiting.removeFirst()
        // Unpinned, closed, woken or put on a stage since it was queued: skip it.
        guard let tab = Spaces.shared.pins.first(where: { $0.id == id }) else { return next() }
        if reload {
            guard !tab.asleep, tab.built != nil else { return next() }
            // A stage took it in the meantime: the load goes where it is.
            guard tab.built?.window == nil else {
                tab.recoverFromCrash()
                return next()
            }
        } else {
            guard Self.needsPage(tab) else { return next() }
        }
        loading = id
        SpaceWarm.warm(tab, size: browser?.active?.built?.bounds.size, start: {
            if reload {
                tab.recoverFromCrash()
            } else if !tab.wake() {
                // No view and not asleep (closed under its pin): the address.
                tab.revive()
            }
        }, done: { [weak self] in
            guard let self else { return }
            loading = nil
            // Looked at afresh rather than only the queue: a pin unpinned,
            // put to sleep and pinned again while it was in the Room was
            // passed over by every look that saw it loading.
            look()
        })
    }

    // MARK: - the bench

    /// `./bench pins` — every pin: loaded or not, its process, its reloads;
    /// `pins kill ID` ends a tab's page process as macOS would under memory
    /// pressure; `pins close ID` is ⌘W on it in its window, `pins others ID`
    /// Close Other Tabs. All but the list, test worlds only.
    static func bench(_ request: [String: Any], in browser: Browser) -> [String: Any] {
        let op = request["op"] as? String ?? "list"
        let arg = (request["arg"] as? String ?? "").lowercased()
        func find() -> Tab? {
            guard !arg.isEmpty else { return nil }
            return AgentTabs.all.first { $0.id.uuidString.lowercased().hasPrefix(arg) }
        }
        switch op {
        case "list", "state", "status":
            break
        case "kill", "close", "others":
            guard Store.testing else { return ["error": "pins \(op) only works in a test world"] }
            guard let tab = find() else { return ["error": "pins \(op) ID — no tab “\(arg)”"] }
            let owner = AgentTabs.owner(of: tab)
            if op == "close" {
                owner.close(tab)
            } else if op == "others" {
                owner.closeOthers(but: tab)
            } else {
                guard let web = tab.built else { return ["error": "that tab has no page to end"] }
                // SIGKILL, as jetsam does it; WebKit's own test hook only when
                // the process can't be named.
                if let pid = process(of: web) {
                    let ok = Darwin.kill(pid, SIGKILL) == 0
                    return ["killed": Int(pid), "how": ok ? "SIGKILL" : "SIGKILL failed: \(errno)", "tab": Bench.short(tab)]
                }
                let kill = NSSelectorFromString("_killWebContentProcess")
                guard web.responds(to: kill) else { return ["error": "no way to end that page's process"] }
                web.perform(kill)
                return ["killed": 0, "how": "_killWebContentProcess", "tab": Bench.short(tab)]
            }
        default:
            return ["error": "pins [list] | kill ID | close ID | others ID"]
        }
        let now = Date()
        let pins = Spaces.shared.pins.map { tab -> [String: Any] in
            [
                "id": Bench.short(tab),
                "pin": tab.pin ?? "",
                "title": tab.title,
                "url": (tab.pending ?? tab.address)?.absoluteString ?? "",
                "built": tab.built != nil,
                "asleep": tab.asleep,
                "stale": tab.stale,
                "loading": tab.loading,
                "failure": tab.failure ?? "",
                "pid": tab.built.flatMap { process(of: $0) }.map { Int($0) } ?? 0,
                "front": Windows.all.contains { $0.activeID == tab.id },
                "reloads": shared.reloads.count(tab.id, at: now),
            ]
        }
        let loose = AgentTabs.all.filter { $0.pin == nil }
        return [
            "pins": pins,
            "active": browser.active.map(Bench.short) ?? "",
            "loose": loose.count,
            "looseLoaded": loose.filter { $0.built != nil && !$0.asleep }.count,
            "looseAsleep": loose.filter(\.asleep).count,
            "waiting": shared.waiting.count + (shared.loading == nil ? 0 : 1),
        ]
    }

    private static func process(of web: WKWebView) -> pid_t? {
        let name = "_webProcessIdentifier"
        guard web.responds(to: NSSelectorFromString(name)), let value = web.value(forKey: name) as? NSNumber else { return nil }
        return value.int32Value > 0 ? value.int32Value : nil
    }
}
