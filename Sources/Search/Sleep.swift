import AppKit
import WebKit

// Tabs you aren't using, put to sleep.
//
// A page open in a tab keeps its whole content process — a hundred to three
// hundred megabytes, running its timers, holding its sockets — for as long as
// the tab exists. Twenty tabs is two or three gigabytes spent on the nineteen
// nobody is looking at. So a tab left alone gives its page back, and keeps
// what it takes to come back exactly where it was: its history, its scroll
// position, and a picture to show while the page is rebuilt underneath (see
// Tab.sleep).
//
// Fork (perf): but a page given back is a page loaded again, and on a Mac
// with memory to spare that was the commonest wait in the browser — any tab
// not looked at for half an hour reloaded when you went back to it. Now the
// half hour only makes a tab eligible: tabs sleep, longest-left first, only
// while more pages are loaded than this Mac keeps easily (`awakeBudget`, two
// for every three gigabytes), or once left for twelve hours.
//
// Some tabs never sleep, because waking them couldn't give back what they
// were doing: the one on screen, pinned tabs (those are put down by hand,
// with ⌘W), a tab playing sound, on a call, sending a download, holding its
// video out in the little window, or holding something typed and not sent.
//
// When macOS says memory is short, the half hour shrinks: to five minutes on
// a warning, to nothing when it is critical.

extension Browser {
    /// How long a tab has to go without being looked at. Half an hour, or
    /// `sleep.after` in seconds — for the bench and the measurements.
    static var sleepAfter: TimeInterval {
        let set = Store.settings.double(forKey: "sleep.after")
        return set > 0 ? set : 30 * 60
    }

    /// How many pages stay loaded however long they're left: two for every
    /// three gigabytes of memory (24 on 36 GB, 10 on 16), at least 6 and at
    /// most 40 — or `sleep.keep`, for the bench.
    static var awakeBudget: Int {
        let set = Store.settings.integer(forKey: "sleep.keep")
        if set > 0 { return set }
        let gigabytes = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        return min(40, max(6, gigabytes * 2 / 3))
    }

    /// Left this long, a page goes whatever the budget says.
    static let sleepCeiling: TimeInterval = 12 * 3600

    /// Started once, at launch.
    func watchForSleep() {
        let every = min(60, max(5, Browser.sleepAfter / 4))
        let timer = Timer(timeInterval: every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.sleepIdle() }
        }
        timer.tolerance = every / 4
        RunLoop.main.add(timer, forMode: .common)
        dozing = timer

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.pressure?.data else { return }
                _ = self.sleepIdle(within: event.contains(.critical) ? 0 : 5 * 60)
            }
        }
        source.resume()
        pressure = source
    }

    /// Every tab that has gone long enough without being looked at, the one
    /// left longest first — beyond the budget only, unless memory is short
    /// (`given`) or the bench set its own `sleep.after`. The tabs it chose.
    @discardableResult
    func sleepIdle(within given: TimeInterval? = nil) -> [Tab] {
        guard prefs.sleepsTabs else { return [] }
        let wait = given ?? Browser.sleepAfter
        let now = Date()
        var seen = Set<Tab.ID>()
        let candidates = (Windows.all.flatMap(\.tabs) + Spaces.shared.parkedTabs).filter { seen.insert($0.id).inserted }
        let idle = candidates
            .filter { now.timeIntervalSince($0.touched) >= wait && awake(because: $0) == nil }
            // Fork (space-keepalive): a space's own tab waits for memory pressure.
            .filter { given != nil || !Spaces.shared.remembered($0.id) }
            .sorted { $0.touched < $1.touched }
        guard given == nil, Store.settings.double(forKey: "sleep.after") <= 0 else {
            for tab in idle { self.sleep(tab) }
            return idle
        }
        // Fork (perf): only as many as there are loaded pages over the budget,
        // and any left past the ceiling.
        var over = candidates.filter { $0.built != nil && !$0.asleep }.count - Browser.awakeBudget
        var chosen: [Tab] = []
        for tab in idle where over > 0 || now.timeIntervalSince(tab.touched) >= Browser.sleepCeiling {
            self.sleep(tab)
            chosen.append(tab)
            over -= 1
        }
        return chosen
    }

    /// Why a tab has to stay awake — nil when nothing keeps it. The clock is
    /// the caller's business; this is everything else.
    func awake(because tab: Tab) -> String? {
        if Windows.all.contains(where: { $0.activeID == tab.id }) || Split.shared.has(tab.id) { return "on screen" } // Fork: windows — any window's stage
        if tab.pin != nil { return "pinned" }
        if Backstage.shared.holds(tab.id) { return "an agent is working in it" } // Fork: agent-tabs
        if tab.bench { return "a bench tab" }
        if tab.isBlank { return "blank" }
        if tab.asleep { return "already asleep" }
        guard let web = tab.built else { return "no page" }
        if tab.loading { return "still loading" }
        if tab.noisy { return "playing sound" }
        if tab.floating || floating == tab.id { return "its video is out" }
        if web.cameraCaptureState != .none || web.microphoneCaptureState != .none { return "on a call" }
        if downloading.contains(where: { $0.webView === web }) { return "downloading" }
        // A sign-in window hands its answer back to the page that opened it.
        if active?.opener == tab.id { return "the page on screen came from it" }
        return nil
    }

    /// Asks the page whether it holds anything typed, pictures it, then lets
    /// it go — looking again at each step, since each takes a moment and you
    /// may have gone back to the tab in the meantime.
    func sleep(_ tab: Tab, done: ((String) -> Void)? = nil) {
        if let reason = awake(because: tab) {
            done?(reason)
            return
        }
        tab.unsaved { [weak self, weak tab] typed in
            guard let self, let tab else { return }
            if typed {
                done?("holding something typed")
                return
            }
            if let reason = self.awake(because: tab) {
                done?(reason)
                return
            }
            tab.snapshot { [weak self, weak tab] picture in
                guard let self, let tab else { return }
                if let reason = self.awake(because: tab) {
                    done?(reason)
                    return
                }
                tab.sleep(picture: picture)
                done?("asleep")
            }
        }
    }
}
