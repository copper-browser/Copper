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
// were doing: the one on screen, pinned tabs, a tab playing sound, on a call,
// sending a download, holding its video out in the little window, or holding
// something typed and not sent.
// (A video with no sound needs no rule: WebKit pauses it the moment its tab
// leaves the screen, so nothing plays silently in a tab that could sleep.)
//
// Fork (pins-awake): a pinned tab never gives its page back at all, by any
// road — from the moment it is pinned, or from launch, until it is unpinned.
// ⌘W on one steps away from it and leaves the page loaded (it used to put
// the pin down), `Tab.sleep(picture:)` and `Tab.rest()` refuse one whoever
// asks, the pins a launch brings back asleep are loaded in the background,
// and one whose process macOS took back is loaded again at once
// (Fork/PinsAwake.swift). Unpinned, it sleeps by the rules here.
//
// Fork (tab-memory): the budget counts pages, and pages are not one size —
// X, Gmail or YouTube hold about a gigabyte each, so ten of them "kept
// easily" on a 16 GB Mac was most of its memory. A page that heavy (`heavy`:
// a thirty-second of the Mac's memory, half a gigabyte on 16 GB)
// goes at the half hour whatever the budget says, and so does a space's own
// tab, which otherwise waits for memory pressure: the Gmail a launch warmed
// for a space nobody went to held 980 MB all day. A tab an agent opened for
// itself goes at the half hour too, once the agent is done with it.
//
// When macOS says memory is short, the half hour shrinks: to five minutes on
// a warning, to nothing when it is critical.
//
// Fork (idle-memory): the budget counts bytes too. The pages that may sleep
// — every loaded page but the pins — keep at most `footprintBudget` between
// them (a sixteenth of the Mac's memory, 1.5 GB on 24 GB): past it, tabs left
// half an hour go, longest-left first, until what is left fits, a space's own
// tab included. Under it, a space's own tab still waits for memory pressure.

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

    /// A page whose process holds this much goes at the half hour whatever
    /// the budget says: a thirty-second of this Mac's memory (512 MB on
    /// 16 GB, 1.1 GB on 36 — a Mac with memory to spare keeps more of its
    /// pages), at least 500 MB — or `sleep.heavy` in megabytes, for the bench.
    static var heavy: UInt64 {
        let set = Store.settings.integer(forKey: "sleep.heavy")
        if set > 0 { return UInt64(set) * 1_048_576 }
        return max(500 * 1_048_576, ProcessInfo.processInfo.physicalMemory / 32)
    }

    /// Left this long, a page goes whatever the budget says.
    static let sleepCeiling: TimeInterval = 12 * 3600

    /// Fork (idle-memory): what the pages that may sleep keep between them:
    /// a sixteenth of this Mac's memory, at least 1 GB — or `sleep.budget`
    /// in megabytes, for the bench.
    static var footprintBudget: UInt64 {
        let set = Store.settings.integer(forKey: "sleep.budget")
        if set > 0 { return UInt64(set) * 1_048_576 }
        return max(1_073_741_824, ProcessInfo.processInfo.physicalMemory / 16)
    }

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
    /// `after` is the bench's shorter wait, everything else as it would be.
    @discardableResult
    func sleepIdle(within given: TimeInterval? = nil, after: TimeInterval? = nil) -> [Tab] {
        guard prefs.sleepsTabs else { return [] }
        let wait = given ?? after ?? Browser.sleepAfter
        let now = Date()
        var seen = Set<Tab.ID>()
        let candidates = (Windows.all.flatMap(\.tabs) + Spaces.shared.parkedTabs).filter { seen.insert($0.id).inserted }
        let rested = candidates.filter { now.timeIntervalSince($0.touched) >= wait && awake(because: $0) == nil }
        // Fork (tab-memory): weighed once, and only the ones that could go.
        // A tab an agent opened and is done with goes the same way: nobody
        // chose to keep it loaded.
        let heavy = Set(rested.filter {
            AgentTabs.opened.contains($0.id) || (Heat.shared.weight(of: $0)?.bytes ?? 0) >= Browser.heavy
        }.map(\.id))
        guard given == nil, Store.settings.double(forKey: "sleep.after") <= 0 else {
            let idle = rested
                // Fork (space-keepalive): a space's own tab waits for memory
                // pressure — unless it is a heavy one.
                .filter { given != nil || !Spaces.shared.remembered($0.id) || heavy.contains($0.id) }
                .sorted { $0.touched < $1.touched }
            for tab in idle { self.sleep(tab) }
            return idle
        }
        // Fork (perf): only as many as there are loaded pages over the budget,
        // any left past the ceiling, any still burning a core with nobody
        // looking (Heat's sustained reading) — under the budget that page
        // kept the fans going for twelve hours — and any heavy one.
        // Fork (idle-memory): and as many as it takes to bring the pages that
        // may sleep inside their footprint budget (`SleepPlan`).
        let loaded = candidates.filter { $0.built != nil && !$0.asleep }
        var pids = Set<pid_t>()
        let bytes = loaded.filter { $0.pin == nil }.reduce(UInt64(0)) { sum, tab in
            guard let weight = Heat.shared.weight(of: tab), pids.insert(weight.pid).inserted else { return sum }
            return sum + weight.bytes
        }
        let plan = SleepPlan(overCount: loaded.count - Browser.awakeBudget,
                             overBytes: Int64(bytes) - Int64(Browser.footprintBudget), ceiling: Browser.sleepCeiling)
        let resting = rested.map { tab in
            SleepPlan.Resting(id: tab.id, left: now.timeIntervalSince(tab.touched),
                              bytes: heavy.contains(tab.id) || plan.overBytes > 0 ? Heat.shared.weight(of: tab)?.bytes ?? 0 : 0,
                              remembered: Spaces.shared.remembered(tab.id), heavy: heavy.contains(tab.id), hot: Heat.shared.isHot(tab))
        }
        let ids = Set(plan.choose(resting))
        let chosen = rested.filter { ids.contains($0.id) }.sorted { $0.touched < $1.touched }
        for tab in chosen { self.sleep(tab) }
        return chosen
    }

    /// Why a tab has to stay awake — nil when nothing keeps it. The clock is
    /// the caller's business; this is everything else.
    func awake(because tab: Tab) -> String? {
        if Windows.all.contains(where: { $0.activeID == tab.id }) || Split.shared.has(tab.id) { return "on screen" } // Fork: windows — any window's stage
        if tab.pin != nil { return "pinned" } // Fork (pins-awake): always — Tab.sleep(picture:) refuses a pin too
        if Backstage.shared.holds(tab.id) { return "an agent is working in it" } // Fork: agent-tabs
        if TabShare.shared.involves(tab.id) { return "being shared" } // Fork: tab-share — the shared tab and the page sharing it
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

/// Fork (idle-memory): which of the tabs left long enough go to sleep. Pure,
/// so the tests can say it.
struct SleepPlan {
    /// A tab past the half hour with nothing keeping it awake.
    struct Resting {
        let id: UUID
        /// Seconds since it was last looked at.
        let left: TimeInterval
        /// Its page's footprint (0 when not weighed).
        let bytes: UInt64
        /// A space's own tab: the one a switch back lands on.
        let remembered: Bool
        let heavy: Bool
        let hot: Bool
    }

    /// Loaded pages over the count budget.
    var overCount: Int
    /// Bytes the pages that may sleep hold over their footprint budget.
    var overBytes: Int64
    var ceiling: TimeInterval

    /// Longest-left first: any heavy, hot or past the ceiling; any other
    /// while the count is over its budget — never a space's own tab for
    /// that — and any at all while the bytes are over theirs.
    func choose(_ resting: [Resting]) -> [UUID] {
        var count = overCount, bytes = overBytes
        var chosen: [UUID] = []
        for tab in resting.sorted(by: { $0.left > $1.left }) {
            let must = tab.heavy || (!tab.remembered && (tab.hot || tab.left >= ceiling))
            guard must || (count > 0 && !tab.remembered) || bytes > 0 else { continue }
            chosen.append(tab.id)
            count -= 1
            bytes -= Int64(tab.bytes)
        }
        return chosen
    }
}
