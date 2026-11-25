import WebKit

// The ad blocker. No counter, no shield icon going green — the lists are
// compiled once per version and then it is simply true that the page is lighter.
//
// A content rule list is enforced inside WebKit's networking, before a request
// is made and before a stylesheet is applied, so this costs nothing at run time
// in the way a JavaScript blocker does.

@MainActor
final class Shield: ObservableObject {
    static let shared = Shield()

    /// Set the one time compiling the list didn't work. The toggle in
    /// Settings can say "on" all it wants; nothing is actually blocked until
    /// this is nil, so it is the one thing worth telling a person about
    /// rather than failing the quiet way a missing ad is quiet.
    @Published private(set) var trouble: String?

    /// On unless somebody said otherwise. Every tab's controller is told when
    /// this changes, so it takes effect on the next request rather than the
    /// next launch.
    var enabled = true

    /// Sites it is off for — the ones it broke. A checkout that never
    /// finishes, a video that never starts: switching off here, for this site,
    /// beats switching off everywhere and forgetting to switch back.
    private(set) var paused: Set<String> = Set(
        Store.settings.stringArray(forKey: "shield.paused") ?? []
    )

    func isPaused(on host: String?) -> Bool {
        guard let host else { return false }
        return paused.contains(host)
    }

    func pause(_ host: String, _ off: Bool) {
        if off { paused.insert(host) } else { paused.remove(host) }
        Store.settings.set(Array(paused).sorted(), forKey: "shield.paused")
    }

    /// Before each page: the lists go on or off for the site this tab is
    /// heading to. A rule list is enforced from the moment it is added, so
    /// doing this at the navigation is what makes "off for this site" true
    /// for the whole page rather than for the second half of it.
    func tune(_ controller: WKUserContentController, for host: String?) {
        // Fork (navperf): touched only when it changes — the next page
        // usually wants what the last one had.
        let on = enabled && !isPaused(on: host)
        guard attached.object(forKey: controller)?.boolValue != on else { return }
        for list in lists.values {
            controller.remove(list)
            if on { controller.add(list) }
        }
        attached.setObject(on as NSNumber, forKey: controller)
    }

    /// Fork (navperf): whether each controller has the lists, as last set here.
    private let attached = NSMapTable<WKUserContentController, NSNumber>.weakToStrongObjects()

    /// Fork (navperf): something else took the lists off (a canvas board).
    func forget(_ controller: WKUserContentController) {
        attached.removeObject(forKey: controller)
    }

    /// Every controller that has the lists on.
    private var wearing: [WKUserContentController] {
        (attached.keyEnumerator().allObjects as? [WKUserContentController] ?? []).filter { attached.object(forKey: $0)?.boolValue == true }
    }

    // Fork (ardia-shield): the real lists (Fork/ShieldLists.swift) — EasyList,
    // EasyPrivacy, uBlock's filters, cookie notices, a regional list for each
    // language the Mac reads, your own — each its own WebKit rule list, by
    // identifier, compiled once per version into this world's store.

    /// The lists on pages now, by WebKit identifier.
    private(set) var lists: [String: WKContentRuleList] = [:]

    /// What each wanted list came to: Settings' trouble line and `bench shield stats`.
    struct Stat {
        let piece: ShieldLists.Piece
        var state: String // loading, cached, compiled, failed
        var rules: Int
        var ms: Double = 0
        var main: Double = 0 // of that, on the main thread: the hand-off to WebKit and adding it to pages
        var error: String?
    }
    private(set) var stats: [String: Stat] = [:]

    /// This world's own compiled lists (the default store is shared by every world of a build).
    private lazy var store: WKContentRuleListStore? = {
        let folder = Store.file("Shield")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return WKContentRuleListStore(url: folder)
    }()
    private var swept = false

    /// At launch, and on any change of what is wanted: lists no longer wanted
    /// come off every page, new ones are looked up — compiled only the first
    /// time this version is seen (or every time, `fresh`, for the bench).
    func load(fresh: Bool = false) {
        guard let store else {
            trouble = "WebKit has nowhere to compile the block lists"
            return
        }
        let wanted = ShieldLists.wanted()
        let ids = Set(wanted.map(\.id))
        for (id, list) in lists where !ids.contains(id) || fresh {
            for controller in wearing { controller.remove(list) }
            lists[id] = nil
        }
        stats = stats.filter { ids.contains($0.key) && !fresh && $0.value.state != "failed" } // failed ones try again
        trouble = nil
        for piece in wanted where stats[piece.id] == nil {
            bring(piece, from: store, fresh: fresh)
        }
        sweep(store, keeping: Set(ShieldLists.every.map(\.id)).union(ids))
        objectWillChange.send()
    }

    /// The launch and Settings' Try again: the lists, and your list's address
    /// fetched again if its copy is a day old.
    func compile() {
        load()
        ShieldLists.fetch()
    }

    private func bring(_ piece: ShieldLists.Piece, from store: WKContentRuleListStore, fresh: Bool) {
        let started = CFAbsoluteTimeGetCurrent()
        stats[piece.id] = Stat(piece: piece, state: "loading", rules: piece.rules)
        let build: () -> Void = { [weak self] in
            DispatchQueue.global(qos: .utility).async {
                let made = ShieldLists.read(piece)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.stats[piece.id] != nil else { return }
                        guard let made else {
                            return self.failed(piece, piece.kind == .custom ? "None of these are in a form Copper reads" : "Couldn't read \(piece.title)")
                        }
                        self.stats[piece.id]?.rules = made.rules
                        // WebKit parses the JSON on the main thread (selectors need it), ~110 ms
                        // for the ads list: after the launch's first page, one list per pass.
                        self.handOff {
                            guard self.stats[piece.id] != nil else { return }
                            let handing = CFAbsoluteTimeGetCurrent()
                            defer { self.stats[piece.id]?.main += (CFAbsoluteTimeGetCurrent() - handing) * 1000 }
                            store.compileContentRuleList(forIdentifier: piece.id, encodedContentRuleList: made.json) { compiled, error in
                                MainActor.assumeIsolated {
                                    guard let compiled else {
                                        return self.failed(piece, error?.localizedDescription ?? "Compiling \(piece.title) failed")
                                    }
                                    self.ready(piece, compiled, "compiled", since: started)
                                }
                            }
                        }
                    }
                }
            }
        }
        // Your own filters are built every launch: they are few, and their count is shown.
        if piece.kind == .custom { return build() }
        if fresh {
            store.removeContentRuleList(forIdentifier: piece.id) { _ in MainActor.assumeIsolated { build() } }
            return
        }
        store.lookUpContentRuleList(forIdentifier: piece.id) { [weak self] found, _ in
            MainActor.assumeIsolated {
                if let found { self?.ready(piece, found, "cached", since: started) } else { build() }
            }
        }
    }

    /// The next free slot for a hand-off, 0.1 s after the last one.
    private var nextHandOff = DispatchTime.now()

    private func handOff(_ work: @escaping () -> Void) {
        Launch.shared.whenSettled { [self] in
            nextHandOff = max(nextHandOff, .now()) + .milliseconds(100)
            DispatchQueue.main.asyncAfter(deadline: nextHandOff, execute: work)
        }
    }

    private func ready(_ piece: ShieldLists.Piece, _ list: WKContentRuleList, _ state: String, since started: CFAbsoluteTime) {
        guard stats[piece.id] != nil else { return } // switched off while it compiled
        stats[piece.id]?.state = state
        stats[piece.id]?.ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        lists[piece.id] = list
        // Tabs that opened while this was loading get it now.
        let adding = CFAbsoluteTimeGetCurrent()
        for controller in wearing { controller.add(list) }
        stats[piece.id]?.main += (CFAbsoluteTimeGetCurrent() - adding) * 1000
        objectWillChange.send()
    }

    private func failed(_ piece: ShieldLists.Piece, _ message: String) {
        guard stats[piece.id] != nil else { return }
        stats[piece.id]?.state = "failed"
        stats[piece.id]?.error = message
        if piece.kind != .custom { trouble = message } // yours says so on its own line
        objectWillChange.send()
    }

    /// Your own filters' line in Settings: what they came to.
    var custom: Stat? { stats.values.first { $0.piece.kind == .custom } }

    /// Once a launch: compiled lists from an older version (and the single
    /// list of before, in WebKit's default store) are deleted.
    private func sweep(_ store: WKContentRuleListStore, keeping: Set<String>) {
        guard !swept else { return }
        swept = true
        WKContentRuleListStore.default()?.removeContentRuleList(forIdentifier: "office-shield") { _ in }
        store.getAvailableContentRuleListIdentifiers { ids in
            MainActor.assumeIsolated {
                for id in ids ?? [] where !keeping.contains(id) && self.stats[id] == nil {
                    store.removeContentRuleList(forIdentifier: id) { _ in }
                }
            }
        }
    }

    /// Every tab asks for them; a list that is still loading arrives later.
    func protect(_ controller: WKUserContentController) {
        if enabled { for list in lists.values { controller.add(list) } }
        attached.setObject(enabled as NSNumber, forKey: controller)
    }

    /// Switched on or off for every page that is already open.
    func apply(to controllers: [WKUserContentController]) {
        for controller in controllers {
            for list in lists.values {
                controller.remove(list)
                if enabled { controller.add(list) }
            }
            attached.setObject(enabled as NSNumber, forKey: controller)
        }
    }

    /// Loads the lists stopped on each page, for the bench only (nothing on
    /// screen counts): WebKit says so per load (Browser, Fork/ShieldLists.swift).
    final class Count { var page: URL?; var blocked = 0 }
    private let counts = NSMapTable<WKWebView, Count>.weakToStrongObjects()

    func counted(_ webView: WKWebView) {
        let count = counts.object(forKey: webView) ?? Count()
        if count.page != webView.url { count.page = webView.url; count.blocked = 0 } // a new page starts at 0
        count.blocked += 1
        counts.setObject(count, forKey: webView)
    }

    func blocked(on webView: WKWebView) -> Int {
        guard let count = counts.object(forKey: webView), count.page == webView.url else { return 0 }
        return count.blocked
    }

    /// `bench shield stats`: each list, its rules and what loading it cost.
    func report() -> [String: Any] {
        let rows = stats.values.sorted { $0.piece.id < $1.piece.id }.map { stat -> [String: Any] in
            ["id": stat.piece.id, "list": stat.piece.title, "kind": stat.piece.kind.rawValue, "rules": stat.rules,
             "state": stat.state, "ms": (stat.ms * 10).rounded() / 10, "mainMs": (stat.main * 10).rounded() / 10, "error": stat.error ?? NSNull()]
        }
        return ["enabled": enabled, "languages": ShieldLists.languages(),
                "kinds": Dictionary(uniqueKeysWithValues: ShieldLists.Kind.allCases.map { ($0.rawValue, ShieldLists.isOn($0)) }),
                "lists": rows, "rules": stats.values.filter { $0.state == "cached" || $0.state == "compiled" }.reduce(0) { $0 + $1.rules },
                "loading": stats.values.filter { $0.state == "loading" }.count, "bundled": ShieldLists.bundled.count,
                "paused": Array(paused).sorted(), "trouble": trouble ?? NSNull()]
    }
}
