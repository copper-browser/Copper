import AppKit
import Combine
import Foundation
import SwiftUI
import WebKit

/// A detected source shown in the Flow picker: a Chromium profile root
/// (Chrome, Arc, …) or Safari.
struct FlowSource: Identifiable, Hashable {
    enum Kind: Hashable { case chromium, safari }

    let source: Chromium.Source
    let profiles: [String]
    let isArc: Bool
    var locked: Bool
    /// A user-selected copy or folder, kept in memory for this session only.
    let rootOverride: URL?
    /// Installed but never opened: no profile to read yet.
    var empty = false
    var kind: Kind = .chromium
    /// Safari's export, picked or dropped this session: readable even while
    /// macOS keeps Safari's own files locked.
    var export: URL? = nil

    var id: String { source.name }
    var name: String { source.name }
    var isSafari: Bool { kind == .safari }
    var glyph: String { isSafari ? "safari" : isArc ? "a.circle" : "globe" }
    var profileCount: Int { profiles.count }
    var root: URL { isSafari ? safariRoots.library : rootOverride ?? source.root }
    /// All the pure rules in FlowState need of it.
    var candidate: FlowCandidate { FlowCandidate(id: id, readable: readable, locked: locked) }
    /// Something to read: its own files, or (Safari) an export.
    var readable: Bool { export != nil || (!locked && !empty) }
    /// The locked card: nothing to read, and macOS is the reason.
    var showsLocked: Bool { locked && export == nil }

    /// Safari's folders: a test world's copy, else this Mac's.
    var safariRoots: FlowSafari.Roots { rootOverride.map(FlowSafari.Roots.copy(at:)) ?? .system }
    /// Safari's own files, when Copper may read them.
    var safariDirect: FlowSafari.Roots? { isSafari && !locked && !empty ? safariRoots : nil }

    /// Safari as a source. Its `Chromium.Source` is a name only; nothing
    /// Chromium reads ever runs for it.
    static func safari(locked: Bool, empty: Bool, rootOverride: URL?, export: URL?) -> FlowSource {
        FlowSource(source: Chromium.Source(name: FlowSafari.name, folder: "", service: "", account: ""),
                   profiles: [], isArc: false, locked: locked, rootOverride: rootOverride, empty: empty,
                   kind: .safari, export: export)
    }

    /// Chromium's readers already accept a Source. Point that Source at a
    /// selected folder without changing the upstream importer or the browser's
    /// known source metadata (service and account still belong to this browser).
    var readerSource: Chromium.Source {
        guard let rootOverride else { return source }
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .standardizedFileURL.path
        let target = rootOverride.standardizedFileURL.path
        let baseParts = support.split(separator: "/").map(String.init)
        let targetParts = target.split(separator: "/").map(String.init)
        var common = 0
        while common < baseParts.count, common < targetParts.count,
              baseParts[common] == targetParts[common] { common += 1 }
        let components = Array(repeating: "..", count: baseParts.count - common)
            + targetParts.dropFirst(common)
        let folder = components.isEmpty ? "." : components.joined(separator: "/")
        return Chromium.Source(name: source.name, folder: folder, service: source.service, account: source.account)
    }
}

/// The one-button move from a Chromium browser into Copper.
@MainActor
final class Flow: ObservableObject {
    static let shared = Flow()

    /// Folder choices are session-only: a panel grant should not become a
    /// hidden new source in the next launch.
    @MainActor static var roots: [String: URL] = [:]
    /// A test run may list only some sources (`bench flow limit`), so a
    /// script sees its fixtures and not whatever this Mac has installed.
    @MainActor static var only: Set<String>?
    /// A test run may say a source is locked without touching its folder
    /// (`bench flow access --source Chrome locked`), so the locked card and
    /// its re-check can be proven without a TCC request.
    @MainActor static var forced: [String: FlowAccess.State] = [:]
    /// A test run may slow a move down (`bench flow slow --seconds S`), a
    /// pause after each step, so its moving view can be pictured and its
    /// frame watched; zero otherwise.
    @MainActor static var slow: Double = 0
    /// Safari's export, picked or dropped this session. Never remembered
    /// past it: it holds passwords until the move is done with it.
    @MainActor static var safariExport: URL?

    private func pause() async {
        guard Store.testing, Self.slow > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(Self.slow * 1_000_000_000))
    }

    struct Report: Equatable {
        /// What each chosen category came to, for the summary lines.
        var facts = FlowSummary.Facts(source: "")
        var summary: [FlowSummary.Line] { FlowSummary.lines(facts) }
        var title: String { FlowSummary.title(summary, source: facts.source) }
        /// Where Done lands: the first space the move made or filled.
        var landing: UUID?
        /// Undo took the tabs back.
        var undone = false
        /// The Chrome guide is offered: Chrome, and tabs or bookmarks came.
        var guideOffered: Bool {
            facts.source == "Chrome" && (facts.tabsAdded > 0 || facts.bookmarksNew > 0)
        }
        /// Cookies in this world's website store after the move.
        var cookiesInStore = 0
        /// Cookies set in a profile's own jar, by profile, for the spaces
        /// that wear one.
        var profileCookies: [String: Int] = [:]
        var tabs = 0
        var spaces = 0
        var groups = 0
        var bookmarks = 0
        var places = 0
        var passwords = 0
        var cookies = 0
        var passkeys = 0
        var extensions = 0
        /// The local guide opened after a Chrome move, if its tab came up.
        var canvasId: String?
        /// What stayed in the other browser and why, a sentence each
        /// (Safari: its tabs when only the export was read, payment cards,
        /// its extensions).
        var stayed: [String] = []
        /// Sites whose localStorage came over, and how many keys in all.
        var storageSites = 0
        var storageKeys = 0
        /// Keys WebKit actually took, across every store (a profile's store
        /// counts its keys again).
        var storageKeysSet = 0
        var notes: [String] = []

        var line: String {
            "\(tabs) tabs in \(spaces) spaces · \(groups) groups · \(bookmarks) bookmarks · \(places) places · \(passwords) passwords · \(cookies) cookies · local storage for \(storageSites) sites · \(passkeys) passkeys · \(extensions) extensions"
        }
    }

    enum Phase: Equatable {
        case idle
        case scanning
        case preview(FlowModel.Haul)
        case moving([FlowStep])
        case done(Report)

        /// For the event log and the bench: which phase, not its contents.
        var name: String {
            switch self {
            case .idle: return "idle"
            case .scanning: return "scanning"
            case .preview: return "preview"
            case .moving: return "moving"
            case .done: return "done"
            }
        }
    }

    enum HistoryImportState: Equatable {
        case idle
        case reading(String, Int)
        case done(String, Int, Date)
        case failed(String)

        var detail: String? {
            switch self {
            case .idle: return nil
            case .reading(let source, let count): return "Reading \(source)… \(count.formatted()) places"
            case .done(let source, let count, let date):
                let ago = Int(max(0, Date().timeIntervalSince(date)))
                let when = ago < 60 ? "just now" : "\(ago / 60)m ago"
                return "Brought in \(count.formatted()) places from \(source) · \(when)"
            case .failed(let message): return message
            }
        }
    }

    /// A source may be read for history without opening the full Flow sheet.
    /// This is also what the quiet nudge under an empty address field checks
    /// — and it says "Arc", so without a name only Arc's folder is looked
    /// at. Chrome's is one macOS protects: walking it on every empty field
    /// would put a refusal on record each time, with nobody having asked.
    static func hasHistorySource() -> Bool {
        HistorySource.answer()
    }

    /// Whether Arc has a history file, for the ⌘K nudge. One level down
    /// (`<root>/<profile>/History`), never a walk; looked at off the main
    /// actor at most once a minute, and the last answer given meanwhile.
    /// Only Arc's folder: it is the nudge's source, and other browsers'
    /// folders aren't looked at before Move in opens.
    @MainActor private enum HistorySource {
        static var known = false
        static var checked: Date?
        static var looking = false

        static func answer() -> Bool {
            if !looking, checked.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
                looking = true
                Task.detached(priority: .utility) {
                    let found = Flow.arcHistoryExists()
                    await MainActor.run {
                        known = found
                        checked = Date()
                        looking = false
                    }
                }
            }
            return known
        }
    }

    private nonisolated static func arcHistoryExists() -> Bool {
        guard let arc = Chromium.known.first(where: { $0.name == "Arc" }) else { return false }
        return FlowChromeTabs.profiles(at: arc.root).contains { profile in
            FileManager.default.fileExists(atPath: arc.root.appendingPathComponent(profile, isDirectory: true)
                .appendingPathComponent("History").path)
        }
    }

    /// Whether the sheet is up. Only `present(from:via:)` turns it on and
    /// only `close()` turns it off; `FlowPresenter` follows it, and is the
    /// one thing that puts a sheet on screen.
    @Published private(set) var open = false
    @Published private(set) var sources: [FlowSource] = []
    /// The sources have been looked for since the sheet opened. Until then
    /// the picker draws nothing rather than "No other browser found".
    @Published private(set) var sourcesKnown = false
    @Published var choice = FlowModel.Choice()
    @Published private(set) var phase: Phase = .idle {
        didSet { if phase.name != oldValue.name { log("phase", phase.name) } }
    }
    @Published private(set) var selected: FlowSource?
    @Published private(set) var historyImport: HistoryImportState = .idle
    /// When each source was last moved in, by name. A move is a one-time
    /// thing, so once a source has one the sheet says so and wants "Move in
    /// again" before it will run.
    @Published private(set) var movedAt: [String: Date] = Flow.movedAtSetting
    @Published var moveAgain = false

    /// When Arc was last moved in (older scripts read this name).
    var arcMovedAt: Date? { movedAt["Arc"] }

    private static let movedKey = "flow.movedAt"
    private static var movedAtSetting: [String: Date] {
        var out: [String: Date] = [:]
        for (name, value) in Store.settings.dictionary(forKey: movedKey) ?? [:] {
            if let stamp = value as? Double, stamp > 0 { out[name] = Date(timeIntervalSince1970: stamp) }
        }
        // Before every source had a date, only Arc's was kept.
        let arc = Store.settings.double(forKey: "flow.arcMovedAt")
        if out["Arc"] == nil, arc > 0 { out["Arc"] = Date(timeIntervalSince1970: arc) }
        return out
    }

    private func noteMoved(_ name: String, at date: Date) {
        movedAt[name] = date
        Store.settings.set(movedAt.mapValues { $0.timeIntervalSince1970 }, forKey: Self.movedKey)
        moveAgain = false
    }

    private var lastHaul = FlowModel.Haul()
    private var lastHaulSource: String?
    /// What the last move did to the spaces, for Undo.
    private var lastAdoption: FlowAdoption?
    private weak var browserForUndo: Browser?

    /// The locked card's "Use an export instead…": the sheet shows the
    /// export pane for this source until the person goes back or picks one.
    @Published var exporting: FlowSource?
    /// What the last file brought, in a sentence.
    @Published var fileResult: FileResult?
    /// A file is being read.
    @Published var fileBusy = false
    struct FileResult: Equatable {
        var ok: Bool
        var text: String
    }

    /// The window that asked for the sheet; the presenter hangs it there.
    private(set) weak var requester: Browser?
    /// What the sheet did, for `bench flow events`.
    private(set) var events = FlowEvents()
    /// Only the newest scan, for the selected source, may land.
    private var ticket = FlowScanTicket()
    /// The source whose counts are on screen or being read.
    private var previewed: String?
    /// Only the newest look for sources may land.
    private var detection = 0
    private var activation: NSObjectProtocol?
    /// Select this source when a refresh finds it readable (`apply`).
    private var preferNext: String?
    /// A move finished while the sheet was closed ("You can close this; the
    /// move keeps going"): the next open shows its summary instead of
    /// starting over, so what came over is never only in the sidebar.
    private var unseenDone = false
    /// When Safari wrote the export it was given, for its card.
    @Published private(set) var safariExportDate: Date?

    private init() {
        // Nothing is read here. Listing another browser's folder is a request
        // macOS records (and for Chrome's, refuses), so it waits until a
        // person opens Move in — never at launch, never behind their back.
        FlowPresenter.shared.start(self)
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
        }
    }

    func log(_ kind: String, _ detail: String = "") {
        events.record(kind, detail, at: ProcessInfo.processInfo.systemUptime)
    }

    // MARK: - the sheet

    /// Every way in: ⌘K, the Settings row, the menu, the bench.
    enum Door: String { case command, settings, menu, bench }

    /// The one way to bring the sheet up. Each time it opens it starts
    /// fresh — a finished move is behind it, the switches are back to all on
    /// — unless a move is still running, which it shows.
    func present(from browser: Browser?, via door: Door) {
        log("open", door.rawValue)
        requester = browser ?? Windows.current
        guard !open else { return FlowPresenter.shared.raise() }
        if !moving, !unseenDone {
            phase = .idle
            selected = nil
            previewed = nil
            lastHaul = FlowModel.Haul()
            lastHaulSource = nil
            ticket.cancel()
            choice = FlowModel.Choice()
            moveAgain = false
            exporting = nil
            fileResult = nil
            guide = .idle
            preferNext = nil
            askedAccess = []
        }
        unseenDone = false
        open = true
        refresh("open")
    }

    /// Settings closes first, with nothing animating, and the sheet comes up
    /// on the next turn: opening it inside Settings' closing animation
    /// animated the sheet's first layout too, and its text morphed.
    static func presentFromSettings(_ browser: Browser) {
        var calm = Transaction()
        calm.disablesAnimations = true
        withTransaction(calm) { browser.tuning = false }
        DispatchQueue.main.async { Flow.shared.present(from: browser, via: .settings) }
    }

    func close() {
        guard open else { return }
        log("close")
        open = false
        guard !moving else { return }
        // A read still running belongs to a sheet nobody is looking at.
        ticket.cancel()
        if case .scanning = phase {
            phase = .idle
            previewed = nil
        }
    }

    /// Back from System Settings (or any other app): the one thing worth
    /// looking at again is a source that was locked. Nothing else is re-read.
    private func becameActive() {
        let candidates = sources.map(\.candidate)
        guard FlowMachine.recheckOnActivation(sources: candidates, open: open) else { return }
        refresh("activation")
    }

    // MARK: - sources

    /// Looks for sources off the main actor and lands the newest answer.
    func refresh(_ reason: String) {
        detection += 1
        let generation = detection
        let roots = Self.roots
        let only = Self.only
        let forced = Self.forced
        let export = Self.safariExport
        log("refresh", reason)
        Task.detached(priority: .userInitiated) {
            let found = Flow.detect(roots: roots, only: only, forced: forced, safariExport: export)
            await MainActor.run { [weak self] in
                guard let self, generation == self.detection else { return }
                self.apply(found, autoScan: true)
            }
        }
    }

    /// Synchronous form for the bench and the history row, which answer at
    /// once and are not the sheet.
    func refreshSources(autoScan: Bool = false) {
        detection += 1
        apply(Self.detect(roots: Self.roots, only: Self.only, forced: Self.forced, safariExport: Self.safariExport), autoScan: autoScan)
    }

    /// Makes one real directory-list attempt before declaring a source
    /// locked (`FlowAccess.state`). A browser that is installed but has no
    /// profile yet is listed, disabled; one that isn't installed is not.
    nonisolated static func detect(roots: [String: URL], only: Set<String>? = nil,
                                   forced: [String: FlowAccess.State] = [:], safariExport: URL? = nil) -> [FlowSource] {
        let fm = FileManager.default
        let chromium: [FlowSource] = Chromium.known.compactMap { source in
            if let only, !only.contains(source.name) { return nil }
            let isArc = source.name == "Arc"
            let override = roots[source.name].flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
            let root = override ?? source.root
            func empty() -> FlowSource? {
                FlowAccess.installed(source.name)
                    ? FlowSource(source: source, profiles: [], isArc: isArc, locked: false, rootOverride: override, empty: true)
                    : nil
            }
            let state = forced[source.name] ?? FlowAccess.state(of: root)
            switch state {
            case .locked:
                return FlowSource(source: source, profiles: [], isArc: isArc, locked: true, rootOverride: override)
            case .missing:
                return empty()
            case .readable:
                break
            }
            let readerSource = FlowSource(
                source: source, profiles: [], isArc: isArc, locked: false, rootOverride: override
            ).readerSource
            let profiles = FlowChromeTabs.profiles(of: readerSource)
            let hasPreferences = profiles.contains { profile in
                let folder = profile.isEmpty ? root : root.appendingPathComponent(profile)
                return fm.fileExists(atPath: folder.appendingPathComponent("Preferences").path)
            }
            guard hasPreferences else { return empty() }
            return FlowSource(source: source, profiles: profiles, isArc: isArc, locked: false, rootOverride: override)
        }
        guard let safari = safari(roots: roots, only: only, forced: forced, export: safariExport) else { return chromium }
        return chromium + [safari]
    }

    /// Safari's card. Safari comes with macOS, so it is always listed:
    /// readable with Full Disk Access, locked without, never opened when its
    /// folder isn't there. A headless probe (`SEARCH_PROBE`) never looks at
    /// this Mac's own Safari: there Safari is listed only when the script
    /// names it (`flow limit … Safari`, `flow root`, `flow access`), and with
    /// no copy handed over it is what a Mac without Full Disk Access sees.
    nonisolated static func safari(roots: [String: URL], only: Set<String>?, forced: [String: FlowAccess.State],
                                   export: URL?, probe: Bool = Flow.probe) -> FlowSource? {
        let name = FlowSafari.name
        let override = roots[name].flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        if let only, !only.contains(name) { return nil }
        if probe, only == nil, override == nil, forced[name] == nil { return nil }
        let state: FlowAccess.State
        if let pinned = forced[name] {
            state = pinned
        } else if let override {
            state = FlowSafari.probeAccess(.copy(at: override)).state
        } else if probe {
            state = .locked
        } else {
            state = FlowSafari.probeAccess(.system).state
        }
        return .safari(locked: state == .locked, empty: state == .missing, rootOverride: override, export: export)
    }

    /// A headless probe world, started by a script: it never reads this
    /// Mac's own Safari.
    nonisolated static let probe = ProcessInfo.processInfo.environment["SEARCH_PROBE"] != nil

    /// Publishes a new source list only when it differs, and selects and
    /// reads by `FlowMachine.reconcile`: a selection is kept, the only
    /// readable source is picked for you, nothing changes during a move.
    private func apply(_ found: [FlowSource], autoScan: Bool) {
        if sources != found { sources = found }
        if !sourcesKnown { sourcesKnown = true }
        var keep = selected?.id
        // The source the person just acted on (Safari's export taken, Full
        // Disk Access asked for) is the one to show once it can be read.
        if !moving, let wanted = preferNext, found.contains(where: { $0.id == wanted && $0.readable }) {
            keep = wanted
            preferNext = nil
        }
        // The source on screen changed under its counts — its export came,
        // or macOS let Copper in — so what it holds is read again.
        if !moving, let shown = previewed, let old = selected, old.id == shown,
           let fresh = found.first(where: { $0.id == shown }), fresh != old, fresh.readable {
            previewed = nil
            log("changed", shown)
        }
        let decision = FlowMachine.reconcile(
            sources: found.map(\.candidate), selected: keep, previewed: previewed, busy: moving
        )
        guard !moving else { return }
        if decision.resetPreview {
            ticket.cancel()
            previewed = nil
            lastHaul = FlowModel.Haul()
            phase = .idle
        }
        let next = decision.selected.flatMap { id in found.first { $0.id == id } }
        if next != selected { selected = next }
        guard autoScan, let id = decision.scan, let source = found.first(where: { $0.id == id }) else { return }
        scan(source, reason: "auto")
    }

    /// Reads the cheap, non-secret parts off the main actor. Picking the
    /// source already on screen reads nothing again.
    func scan(_ source: FlowSource, reason: String = "pick") {
        guard source.readable, !moving else { return }
        exporting = nil
        if selected?.id == source.id, previewed == source.id {
            switch phase {
            case .scanning, .preview: return
            default: break
            }
        }
        selected = source
        previewed = source.id
        let number = ticket.issue(for: source.id)
        phase = .scanning
        log("scan", "\(source.id) \(reason)")
        Task.detached(priority: .userInitiated) { [source] in
            let haul = Flow.read(source)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.ticket.accepts(number, for: source.id, selected: self.selected?.id) else {
                    self.log("scan-dropped", source.id)
                    return
                }
                self.lastHaul = haul
                self.lastHaulSource = source.id
                self.phase = .preview(haul)
            }
        }
    }

    /// Synchronous form used by the local bench. The bench is already on the
    /// main actor and must answer one request with one JSON object.
    @discardableResult
    func scanNow(_ source: FlowSource) -> FlowModel.Haul {
        guard source.readable else { return FlowModel.Haul() }
        selected = source
        previewed = source.id
        _ = ticket.issue(for: source.id)
        log("scan", "\(source.id) bench")
        let haul = Flow.read(source)
        lastHaul = haul
        lastHaulSource = source.id
        phase = .preview(haul)
        return haul
    }

    private nonisolated static func read(_ source: FlowSource) -> FlowModel.Haul {
        if source.isSafari {
            return FlowSafari.haul(FlowSafari.collect(direct: source.safariDirect, export: source.export))
        }
        var haul = FlowModel.Haul()
        do {
            if source.isArc {
                // Arc keeps its sidebar one level above `User Data`; a copy
                // handed over as the root keeps it there too.
                haul.spaces = try source.rootOverride.map {
                    try FlowArc.read(sidebar: $0.deletingLastPathComponent().appendingPathComponent("StorableSidebar.json"))
                } ?? FlowArc.read()
            } else {
                haul.spaces = try FlowChromeTabs.read(source.readerSource)
            }
        } catch {
            haul.notes.append(error.localizedDescription)
            haul.tabsTrouble = "couldn't read \(source.name)'s open tabs"
        }
        haul.extensions = FlowExtensions.read(source.readerSource, profiles: source.profiles)
        haul.passkeyCount = FlowPasskeys.count(source.readerSource, profiles: source.profiles)
        haul.bookmarkCount = FlowBookmarks.count(FlowChromium.bookmarks(in: source).nodes)
        haul.placeCount = FlowChromium.placeCount(in: source)
        haul.loginCount = FlowChromium.loginCount(in: source)
        haul.notes.append("\(haul.bookmarkCount) bookmarks")
        haul.notes.append("\(haul.placeCount) places")
        return haul
    }

    var moving: Bool { if case .moving = phase { return true } else { return false } }

    /// The big button can run: a readable source chosen, its counts in.
    var canMove: Bool {
        guard let selected, selected.readable, !moving else { return false }
        if case .scanning = phase { return false }
        if selected.isSafari {
            // Something Safari can actually bring is switched on.
            guard case .preview(let haul) = phase else { return false }
            return FlowSafari.anything(FlowSafari.usable(choice, direct: selected.safariDirect != nil, look: haul.safari))
        }
        return true
    }

    /// Performs each choice independently. A failure is a line in the report,
    /// never a reason to abandon the remaining data.
    ///
    /// Async so the window stays live the whole way: everything that reads
    /// another browser's files, and the keychain call that can sit behind
    /// macOS's "allow" prompt for as long as the person takes, runs in a
    /// detached task; only the merges into Copper's own state come back here.
    func move(_ source: FlowSource, into browser: Browser) async {
        guard source.readable, !moving else { return }
        browserForUndo = browser
        lastAdoption = nil
        selected = source
        exporting = nil
        // Begun on the sheet (not by a script with it closed): if the person
        // closes it before the end, the summary waits for them.
        let watched = open
        let movedAt = Date()
        var report = Report()
        report.facts = FlowSummary.Facts(source: source.name)
        // Safari: what is there to read is read again now (its files and its
        // export), and only what Safari can bring is moved.
        let safari: FlowSafari.Collected? = source.isSafari
            ? await Task.detached(priority: .userInitiated) {
                FlowSafari.collect(direct: source.safariDirect, export: source.export)
            }.value
            : nil
        let look = safari.map(FlowSafari.look)
        let choice = safari == nil ? self.choice : FlowSafari.usable(self.choice, direct: source.safariDirect != nil, look: look)
        var steps = FlowStep.steps(for: choice)
        phase = .moving(steps)
        await pause()
        // The counts on screen are this source's own read; anything else is
        // read again rather than moved from a stale preview.
        let haul: FlowModel.Haul
        if let safari {
            haul = FlowSafari.haul(safari)
        } else if previewed == source.id && lastHaulSource == source.id {
            haul = lastHaul
        } else {
            haul = await Task.detached(priority: .userInitiated) { Flow.read(source) }.value
        }
        let reader = source.readerSource
        NSLog("Copper: Flow moving from %@ — %d spaces, %d tabs read; notes: %@",
              source.name, haul.spaces.count, haul.tabCount, haul.notes.joined(separator: "; "))

        if choice.tabs {
            mark(.tabs, .working, "making spaces…", &steps)
            report.facts.tabsChosen = true
            report.facts.windowsRead = haul.spaces.count
            report.facts.windowsEmpty = haul.spaces.filter { $0.tabs.isEmpty }.count
            report.facts.windowsAreSpaces = source.isArc
            report.facts.tabsWhy = haul.tabsTrouble
            // A window of only new-tab pages is a line in the summary, not
            // an empty space.
            let adoption = Spaces.shared.adopt(
                haul.spaces.filter { !$0.tabs.isEmpty }, in: browser, sourceName: source.name,
                registry: FlowAdopt.registry(for: source.name), brought: FlowAdopt.brought(for: source.name),
                movedAt: movedAt
            )
            FlowAdopt.keep(adoption.registry, for: source.name)
            FlowAdopt.keep(brought: FlowAdopt.merged(FlowAdopt.brought(for: source.name), adoption), for: source.name)
            lastAdoption = adoption
            report.landing = adoption.landing
            report.facts.tabsAdded = adoption.tabs
            report.facts.pinsAdded = adoption.pins
            report.facts.tabsSkipped = adoption.skipped
            report.facts.spacesMade = adoption.made.count
            report.facts.spacesFilled = adoption.filled.count
            // A space with nothing of its own to open was not made either.
            report.facts.windowsEmpty += adoption.leftOut
            report.tabs = adoption.tabs
            report.spaces = adoption.made.count + adoption.filled.count
            report.groups = adoption.groups
            finish(.tabs, report.facts, &steps)
            await pause()
            // The new spaces are the one thing that cannot be re-fetched from
            // the store or re-read later: write them down now, before the
            // keychain prompt, cookie decryption and extension downloads that
            // follow, so a quit or a hang during those keeps them.
            Session.write(now: true, Spaces.shared.shape(visible: browser.tabs, active: browser.activeID))
            NSLog("Copper: Flow adopted %d tabs (%d skipped) — %d spaces made, %d filled (%d groups) and saved the session",
                  adoption.tabs, adoption.skipped, adoption.made.count, adoption.filled.count, adoption.groups)
        }

        if choice.bookmarks {
            mark(.bookmarks, .working, "reading…", &steps)
            report.facts.bookmarksChosen = true
            if let safari {
                // No bookmark file at all (a passwords-only export) is no
                // take: an empty read would remove the last move's.
                if let read = safari.bookmarkRead {
                    let new = await browser.takeBookmarks(read, from: source.name)
                    report.facts.bookmarksRead = FlowBookmarks.count(read.nodes)
                    report.facts.readingListRead = safari.bookmarks.readingListCount
                    report.facts.bookmarksNew = new
                    if !read.complete { report.facts.bookmarksWhy = "couldn't read Safari's bookmarks file" }
                } else {
                    report.facts.bookmarksWhy = "this export has no bookmarks file"
                }
            } else {
                let (read, new) = await browser.bringBookmarks(from: source)
                report.facts.bookmarksRead = FlowBookmarks.count(read.nodes)
                report.facts.bookmarksNew = new
                if !read.complete, read.nodes.isEmpty {
                    report.facts.bookmarksWhy = "couldn't read \(source.name)'s bookmarks file"
                }
            }
            report.bookmarks = report.facts.bookmarksRead
            finish(.bookmarks, report.facts, &steps)
            await pause()
        }

        if choice.history {
            mark(.history, .working, "reading…", &steps)
            let before = browser.history.visitCount
            let places = await Task.detached(priority: .userInitiated) { safari?.places ?? FlowChromium.places(in: source) }.value
            await Self.take(places, into: browser.history) { [weak self] done in
                self?.progress(.history, "\(done.formatted()) of \(places.count.formatted()) places…")
            }
            report.facts.historyChosen = true
            report.facts.placesRead = places.count
            report.facts.placesNew = max(0, browser.history.visitCount - before)
            report.places = places.count
            finish(.history, report.facts, &steps)
            await pause()
        }

        if let safari, choice.passwords, let csv = safari.passwordsCSV {
            await movePasswordsCSV(csv, source: source.name, report: &report, steps: &steps)
        } else if safari == nil, choice.passwords || choice.cookies || choice.passkeys {
            await moveSecrets(source, reader: reader, choice: choice, worn: profilesWorn(by: source, haul: haul),
                              report: &report, steps: &steps)
        }

        if choice.localStorage {
            report.facts.storageChosen = true
            await moveLocalStorage(source, worn: profilesWorn(by: source, haul: haul), report: &report, steps: &steps)
            report.facts.storageSites = report.storageSites
            finish(.localStorage, report.facts, &steps)
        }

        if choice.extensions {
            let extensions = haul.extensions
            report.facts.extensionsChosen = true
            report.facts.extensionsFound = extensions.count
            if #available(macOS 15.4, *) {
                report.extensions = FlowExtensions.install(extensions) { [weak self, weak browser] landed in
                    guard let self, case .done(var report) = self.phase else { return }
                    report.extensions = landed
                    report.facts.extensionsQueued = landed
                    self.phase = .done(report)
                    browser?.announce(landed == 0 ? "No extensions could be installed" : "\(landed) extensions installed")
                }
                report.facts.extensionsQueued = report.extensions
                if report.extensions > 0 {
                    report.notes.append("extensions are still installing in the background")
                }
            } else {
                report.facts.extensionsWhy = "they need macOS 15.4 or later"
            }
            finish(.extensions, report.facts, &steps)
        }

        report.notes.append(contentsOf: haul.notes.filter { !$0.contains("bookmarks") && !$0.contains("places") })
        if let look { report.stayed = FlowSafari.stayed(look) }
        browser.objectWillChange.send()
        Session.write(now: true, Spaces.shared.shape(visible: browser.tabs, active: browser.activeID))
        noteMoved(source.name, at: Date())
        // The summary stays until Done. The Chrome guide is one button away
        // on it (`openGuide`), never opened over the summary on its own.
        phase = .done(report)
        log("done", report.summary.map(\.plain).joined(separator: " | "))
        if watched, !open {
            unseenDone = true
            browser.announce("\(report.title) — open Move in to see what came")
        }
    }

    /// A row of the moving view changed in place.
    private func mark(_ category: FlowSummary.Category, _ state: FlowStep.State, _ text: String, _ steps: inout [FlowStep]) {
        steps = FlowStep.set(category, state, text, in: steps)
        phase = .moving(steps)
    }

    /// A row done: what the summary will say about it.
    private func finish(_ category: FlowSummary.Category, _ facts: FlowSummary.Facts, _ steps: inout [FlowStep]) {
        steps = FlowStep.finished(category, facts, in: steps)
        phase = .moving(steps)
    }

    /// A working row's progress, from a callback that can't hold the rows.
    private func progress(_ category: FlowSummary.Category, _ text: String) {
        guard case .moving(let shown) = phase else { return }
        phase = .moving(FlowStep.set(category, .working, text, in: shown))
    }

    /// One key read, then three reads that stand or fall on their own: a
    /// broken cookie jar no longer hides the passwords, and a key macOS
    /// refused is said once, against each thing it would have unlocked.
    private func moveSecrets(_ source: FlowSource, reader: Chromium.Source, choice: FlowModel.Choice, worn: [String],
                             report: inout Report, steps: inout [FlowStep]) async {
        let seams = FlowSecrets.seams
        let passphrase = FlowSecrets.passphrases[source.name]
        report.facts.passwordsChosen = choice.passwords
        report.facts.cookiesChosen = choice.cookies
        report.facts.passkeysChosen = choice.passkeys
        let asking = seams ? "using the test passphrase for \(source.name)…" : "asking macOS for \(source.name)'s key…"
        for category in [FlowSummary.Category.passwords, .passkeys, .cookies] { mark(category, .working, asking, &steps) }
        // The keychain read, the decryption and the SQLite copies all happen
        // off the main actor; this is where the old path froze the window
        // behind macOS's prompt.
        let key = await Task.detached(priority: .userInitiated) {
            Result { try FlowSecrets.key(for: reader, testPassphrase: passphrase, seams: seams) }
        }.value
        guard case .success(let key) = key else {
            let why: String
            if case .failure(FlowSecrets.KeyTrouble.testRun) = key {
                why = "a test run reads no keychain, and no test passphrase was given"
            } else if case .failure(Chromium.Trouble.noPassphrase) = key {
                why = "macOS didn't hand over \(source.name)'s key"
            } else {
                why = "couldn't read \(source.name)'s key"
            }
            if choice.passwords { report.facts.passwordsWhy = why }
            if choice.cookies { report.facts.cookiesWhy = why }
            if choice.passkeys { report.facts.passkeysWhy = why }
            report.notes.append(why)
            for category in [FlowSummary.Category.passwords, .passkeys, .cookies] { finish(category, report.facts, &steps) }
            return
        }
        let profiles = source.profiles
        let legs = await Task.detached(priority: .userInitiated) { () -> SecretLegs in
            var legs = SecretLegs()
            if choice.passwords {
                // No Login Data at all is "none saved", not a failure.
                legs.logins = reader.files.isEmpty
                    ? .success(Chromium.Found(logins: [], never: []))
                    : Result { try Chromium.read(reader, key: key) }
            }
            if choice.cookies {
                legs.cookies = Result { try FlowCookies.read(reader, key: key, profiles: profiles) }
                // A profile a moved space wears: its own cookies, for its own jar.
                for name in worn {
                    if let own = try? FlowCookies.read(reader, key: key, profiles: [name]) { legs.worn.append((name, own)) }
                }
            }
            if choice.passkeys { legs.passkeys = Result { try FlowPasskeys.read(reader, key: key, profiles: profiles) } }
            return legs
        }.value
        let sink = FlowSecrets.sink
        switch legs.logins {
        case .success(let found):
            // One keychain write per login: hundreds of them, off the main
            // actor, so the window keeps drawing.
            let (kept, new, known) = await Task.detached(priority: .userInitiated) { () -> (Int, Int, Bool) in
                var kept = 0
                var new = 0
                var known = true
                for login in found.logins {
                    let saved = sink.savePassword(host: login.host, user: login.user, password: login.password, used: login.used)
                    if saved.kept { kept += 1 }
                    if let isNew = saved.new { if isNew && saved.kept { new += 1 } } else { known = false }
                }
                return (kept, new, known)
            }.value
            sink.never(found.never)
            report.facts.passwordsFound = found.logins.count
            report.facts.passwordsKept = kept
            report.facts.passwordsNew = known ? new : nil
            report.passwords = kept
            // Copper's list of saved passwords reads the keychain; a test
            // run's stand-in has nothing there to list.
            if !seams { browser(for: report)?.relist() }
        case .failure:
            report.facts.passwordsWhy = "couldn't read \(source.name)'s saved passwords"
        case nil: break
        }
        finish(.passwords, report.facts, &steps)
        switch legs.cookies {
        case .success(let cookies):
            // Awaited: the count is what WebKit took, not what was read.
            // The shared jar, by name: `Store.websites` is the jar of the
            // space in front, which may be one of a profile's.
            let store = StorageImport.sharedStore.httpCookieStore
            let before = await withCheckedContinuation { done in
                store.getAllCookies { done.resume(returning: Set($0.map { "\($0.domain)\t\($0.name)\t\($0.path)\t\($0.value)" })) }
            }
            let set = await FlowCookies.install(cookies, into: store)
            report.facts.cookiesNew = cookies.filter { !before.contains("\($0.domain)\t\($0.name)\t\($0.path)\t\($0.value)") }.count
            report.facts.cookiesFound = cookies.count
            report.facts.cookiesSet = set
            report.facts.cookieSites = Set(cookies.map { Vault.registrable($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) }).count
            report.cookies = set
            report.cookiesInStore = await withCheckedContinuation { done in
                store.getAllCookies { done.resume(returning: $0.count) }
            }
            // A space wearing a profile opens its pages in that profile's jar
            // (`Spaces.store(forProfile:)`): its sign-ins go there too, or its
            // tabs would open signed out.
            for (name, own) in legs.worn where !own.isEmpty {
                let set = await FlowCookies.install(own, into: Spaces.store(forProfile: name).httpCookieStore)
                report.profileCookies[name] = set
                NSLog("Copper: Flow set %d cookies in profile %@'s jar", set, name)
            }
        case .failure:
            report.facts.cookiesWhy = "couldn't read \(source.name)'s cookies"
        case nil: break
        }
        finish(.cookies, report.facts, &steps)
        switch legs.passkeys {
        case .success(let passkeys):
            let name = source.name
            let added = await Task.detached(priority: .userInitiated) { sink.savePasskeys(passkeys, from: name) }.value
            report.facts.passkeysFound = passkeys.count
            report.facts.passkeysNew = added
            report.passkeys = added
        case .failure:
            report.facts.passkeysWhy = "couldn't read \(source.name)'s passkeys"
        case nil: break
        }
        finish(.passkeys, report.facts, &steps)
    }

    private func browser(for report: Report) -> Browser? { browserForUndo }

    /// The profiles whose own jars a move's sign-ins and site data also go
    /// to: each of the source's profiles that a space from it wears — this
    /// move's, and those an earlier move made that the person kept.
    func profilesWorn(by source: FlowSource, haul: FlowModel.Haul) -> [String] {
        var worn = Set(haul.spaces.compactMap(\.profile))
        let made = Set(FlowAdopt.registry(for: source.name).values)
        for space in Spaces.shared.all where made.contains(space.id) {
            if let profile = space.profile { worn.insert(profile) }
        }
        return worn.filter { source.profiles.contains($0) }.sorted()
    }

    /// Safari's passwords, from its export's CSV, through the one CSV module
    /// (`PasswordCSV`) into where a move's passwords go (`FlowSecrets.sink`):
    /// Copper's keychain, or in a test run the probe's stand-in. No macOS
    /// prompt: nothing of Safari's keychain is read.
    private func movePasswordsCSV(_ csv: String, source: String, report: inout Report, steps: inout [FlowStep]) async {
        report.facts.passwordsChosen = true
        mark(.passwords, .working, "saving…", &steps)
        let seams = FlowSecrets.seams
        let sink = FlowSecrets.sink
        let result = await Task.detached(priority: .userInitiated) { () -> (found: Int, kept: Int, new: Int?) in
            let found = PasswordCSV.summary(csv).logins
            guard let plain = PasswordCSV.canonical(csv) else { return (found, 0, 0) }
            if !seams {
                // What is already here, by site and account — no secret read.
                let have = Set(Vault.all().map { $0.host + "\u{1}" + $0.user })
                let new = Set(PasswordCSV.accounts(csv)).subtracting(have).count
                return (found, Vault.take(csv: plain).kept, new)
            }
            var new = 0
            var known = true
            let taken = Vault.take(csv: plain) { host, user, password in
                let saved = sink.savePassword(host: host, user: user, password: password, used: nil)
                if let isNew = saved.new { if isNew && saved.kept { new += 1 } } else { known = false }
                return saved.kept
            }
            return (found, taken.kept, known ? new : nil)
        }.value
        report.facts.passwordsFound = result.found
        report.facts.passwordsKept = result.kept
        report.facts.passwordsNew = result.new
        report.passwords = result.kept
        if !seams { browser(for: report)?.relist() }
        finish(.passwords, report.facts, &steps)
        log("passwords", "\(source) \(result.kept) kept")
    }

    /// What the key unlocked, each read on its own.
    private struct SecretLegs {
        var logins: Result<Chromium.Found, Error>?
        var cookies: Result<[FlowModel.Cookie], Error>?
        var worn: [(String, [FlowModel.Cookie])] = []
        var passkeys: Result<[FlowModel.Passkey], Error>?
    }

    /// The done screen's "Open the Chrome guide": Tim's guide, made or
    /// reopened, in front — then the sheet goes, since the guide is what the
    /// person asked to see.
    func openGuide() async {
        guard case .done(let report) = phase, report.guideOffered, guide != .opening,
              let browser = browserForUndo ?? requester ?? Optional(Windows.current) else { return }
        guide = .opening
        log("guide", "opening")
        let id = await landChromeCanvas(in: browser)
        guard case .done(var latest) = phase else { guide = .idle; return }
        if let id {
            latest.canvasId = id
            phase = .done(latest)
            guide = .opened
            log("guide", "opened \(id)")
            close()
        } else {
            guide = .failed
            log("guide", "failed")
        }
    }

    enum Guide: Equatable { case idle, opening, opened, failed }
    @Published private(set) var guide: Guide = .idle

    /// Done: the sheet goes, and the window lands on the first space the
    /// move made or filled.
    func finish() {
        if case .done(let report) = phase, !report.undone, let landing = report.landing,
           let browser = browserForUndo, Spaces.shared.all.contains(where: { $0.id == landing }) {
            Spaces.shared.select(landing, in: browser)
            log("landed", landing.uuidString)
        }
        close()
    }

    private static let chromeCanvasKey = "flow.chromeCanvasID"
    private static let chromeCanvasName = "Switching from Chrome"

    /// A renamed guide still belongs to this move; a deleted one may be made
    /// again. Never apply the template to an existing board — it may have been
    /// edited by its owner, and a failed first apply must not duplicate ops.
    private func landChromeCanvas(in browser: Browser) async -> String? {
        let canvases = Canvases.shared
        let remembered = Store.settings.string(forKey: Self.chromeCanvasKey)
            .flatMap { canvases.entry($0) }
            .flatMap { $0.kind == .local ? $0 : nil }
        let existing = remembered ?? canvases.visible.first {
            $0.kind == .local && $0.name.compare(Self.chromeCanvasName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        do {
            // CanvasPage.folder uses the same Search_Search.bundle resolution as
            // canvas.html, both beside the bare binary and inside Copper.app.
            let ops: [Any]?
            if existing == nil {
                guard let folder = CanvasPage.folder else { throw CanvasHost.Failure(text: "canvas resource bundle is missing") }
                let data = try Data(contentsOf: folder.appendingPathComponent("switching-from-chrome.json"))
                ops = try JSONSerialization.jsonObject(with: data) as? [Any]
                guard ops != nil else { throw CanvasHost.Failure(text: "guide ops are not an array") }
            } else {
                ops = nil
            }
            let entry = existing ?? canvases.createLocal(named: Self.chromeCanvasName)
            Store.settings.set(entry.id, forKey: Self.chromeCanvasKey)
            let host = try await CanvasTools.open(entry, in: browser, foreground: true)
            try await host.waitReady()
            if let ops {
                let result = try await host.apply(ops, as: CanvasAgent(id: "agent:copper", name: "Copper", color: CanvasColors.stable("Copper")))
                let applied = result["applied"] as? Int ?? 0
                let errors = result["errors"] as? [Any] ?? []
                guard applied == ops.count, errors.isEmpty else {
                    throw CanvasHost.Failure(text: "guide applied \(applied)/\(ops.count) ops (\(errors.count) errors)")
                }
                try await host.zoom(to: ["sfc_header", "sfc_f_map"])
            }
            CanvasHost.show(entry.id, in: browser, foreground: true)
            return entry.id
        } catch {
            NSLog("Copper: Flow Chrome canvas: %@", String(describing: error))
            return nil
        }
    }

    /// Reads the browser's localStorage LevelDBs off the main actor, then has
    /// `StorageImport` set it origin by origin in a hidden web view — the one
    /// part WebKit insists happen here, awaited so the window keeps drawing.
    /// Every profile's storage goes into the shared store (where a space with
    /// no profile looks); a profile that one of the moved spaces wears also
    /// gets its own into that profile's store.
    private func moveLocalStorage(_ source: FlowSource, worn: [String], report: inout Report, steps: inout [FlowStep]) async {
        mark(.localStorage, .working, "reading…", &steps)
        let root = source.root
        let found = await Task.detached(priority: .userInitiated) { FlowLocalStorage.read(root: root) }.value
        found.warnings.forEach { NSLog("Copper: Flow local storage: %@", $0) }
        var plan = [StorageImport.Target(label: "shared", store: StorageImport.sharedStore,
                                         data: found.merged, origins: found.merged.keys.sorted())]
        for (name, origins) in found.profiles where worn.contains(name) && !origins.isEmpty {
            plan.append(StorageImport.Target(label: "profile:\(name)", store: Spaces.store(forProfile: name),
                                             data: origins, origins: origins.keys.sorted()))
        }
        let sites = found.merged.count
        let summary = await StorageImport.shared.put(plan) { [weak self] done, total in
            // Count every few origins rather than redraw the sheet 900 times.
            guard done == total || done.isMultiple(of: 10) else { return }
            self?.progress(.localStorage, "\(done) of \(total) sites…")
        }
        guard let summary else {
            report.facts.storageWhy = "another import was already running"
            report.notes.append("local storage was not moved: an import was already running")
            return
        }
        report.storageSites = sites
        report.storageKeys = found.keyCount
        report.storageKeysSet = summary.keys
        if summary.failedOrigins > 0 {
            report.notes.append("local storage: \(summary.failedOrigins) sites kept only part of theirs (over WebKit's 5 MB, or would not load)")
        }
        if found.partitioned > 0 {
            report.notes.append("left out \(found.partitioned) third-party (partitioned) local storage keys")
        }
    }

    // MARK: - Safari's export

    /// A Safari export (the zip, its folder, or one bookmarks .html or
    /// passwords .csv) dropped on the export pane or picked there. It is read
    /// once to check it, off the main actor; if it is one, Safari's card
    /// takes it for this session and its counts come up on the checklist.
    func takeSafariExport(_ url: URL) {
        guard !fileBusy, !moving else { return }
        fileBusy = true
        fileResult = nil
        log("file", "reading Safari's export")
        let roots = Self.roots
        let only = Self.only
        let forced = Self.forced
        let generation = detection + 1
        detection = generation
        Task {
            let (trouble, date, found) = await Task.detached(priority: .userInitiated) { () -> (String?, Date?, [FlowSource]) in
                let read: SafariExport
                do {
                    read = try SafariExport.read(url)
                } catch {
                    let why = (error as? SafariExport.Trouble)?.errorDescription ?? "Couldn't read \(url.lastPathComponent)"
                    return (why, nil, [])
                }
                return (nil, read.exportedAt, Flow.detect(roots: roots, only: only, forced: forced, safariExport: url.standardizedFileURL))
            }.value
            fileBusy = false
            if let trouble {
                fileResult = FileResult(ok: false, text: "\(trouble) — in Safari, choose File › Export Browsing Data to File…, then drop the .zip here")
                log("file", "no \(trouble)")
                return
            }
            Self.safariExport = url.standardizedFileURL
            safariExportDate = date
            exporting = nil
            fileResult = nil
            log("file", "ok Safari's export")
            preferNext = FlowSafari.name
            // A look that started meanwhile didn't know of the export: look again.
            if generation == detection { apply(found, autoScan: true) } else { refresh("export") }
        }
    }

    /// Safari's export, let go of (`bench flow export --source Safari --clear`).
    func forgetSafariExport() {
        Self.safariExport = nil
        safariExportDate = nil
        refreshSources(autoScan: false)
    }

    /// Undo has something to take back.
    var canUndo: Bool {
        guard case .done(let report) = phase, !report.undone, let adoption = lastAdoption else { return false }
        return adoption.tabs > 0 || !adoption.made.isEmpty
    }

    /// The locked card's "Allow in System Settings…": Privacy & Security ›
    /// Files & Folders. Coming back to Copper re-checks (`becameActive`).
    func allow(_ source: FlowSource) {
        // Safari's files open with Full Disk Access; Chrome's with its own
        // switch in Files & Folders, under a record that matches this build.
        if !source.isSafari, FlowAccess.state(of: source.root) == .locked {
            FlowAccess.renewRecord(for: source.root)
        }
        let page = FlowAccess.openPrivacySettings(fullDisk: source.isSafari)
        askedAccess.insert(source.id)
        preferNext = source.id
        log("allow", "\(source.name) \(page)")
    }

    /// Sources whose card sent the person to System Settings since the
    /// sheet opened: still locked on coming back, the card says what else
    /// it takes.
    @Published private(set) var askedAccess: Set<String> = []

    /// Takes back the tabs and spaces this move added, and nothing else:
    /// spaces an earlier move made stay, with the tabs they had.
    func undo() {
        guard case .done(var report) = phase, !report.undone, let adoption = lastAdoption,
              let browser = browserForUndo else { return }
        Spaces.shared.undo(adoption, in: browser)
        // The registry forgets only the spaces this move made.
        let source = report.facts.source
        var registry = FlowAdopt.registry(for: source)
        registry = registry.filter { !adoption.made.contains($0.value) }
        FlowAdopt.keep(registry, for: source)
        FlowAdopt.keep(brought: FlowAdopt.without(FlowAdopt.brought(for: source), adoption), for: source)
        lastAdoption = nil
        Session.write(now: true, Spaces.shared.shape(visible: browser.tabs, active: browser.activeID))
        report.undone = true
        report.landing = nil
        report.facts.tabsAdded = 0
        report.facts.pinsAdded = 0
        report.facts.tabsSkipped = 0
        report.facts.spacesMade = 0
        report.facts.spacesFilled = 0
        report.facts.tabsWhy = "taken back with Undo"
        phase = .done(report)
        log("undo", "\(adoption.made.count) spaces, \(adoption.addedTabs.count + adoption.addedPins.count) tabs")
    }

    /// Import just the address history, without opening the larger Flow sheet.
    /// The SQLite copy/read is off the main actor; only the small merge touches
    /// History, which is main-actor isolated.
    func importHistory(preferred name: String = "Arc", in browser: Browser) {
        if case .reading = historyImport { return }
        let source = historySource(named: name, rootOverride: nil)
            ?? (name.caseInsensitiveCompare("Arc") == .orderedSame ? historySource(named: "Chrome", rootOverride: nil) : nil)
        guard let source else {
            browser.announce("No readable \(name) history found")
            return
        }
        historyImport = .reading(source.name, 0)
        let sourceName = source.name
        Task { [weak self, weak browser] in
            let places = await Task.detached(priority: .userInitiated) {
                FlowChromium.places(in: source)
            }.value
            guard let self, let browser else { return }
            self.historyImport = .reading(sourceName, places.count)
            await Self.take(places, into: browser.history) { done in self.historyImport = .reading(sourceName, done) }
            self.historyImport = .done(sourceName, places.count, Date())
            browser.announce(places.isEmpty ? "No places from \(sourceName)" : "Brought in \(places.count.formatted()) places from \(sourceName)")
        }
    }

    /// Synchronous history import for `bench`, where one request must return
    /// one complete JSON object. It is intentionally available only in a test
    /// world when the caller supplies an isolated root.
    @discardableResult
    func importHistoryNow(named name: String, limit: Int = Int.max, rootOverride: URL?, in browser: Browser) -> [String: Any] {
        guard Store.testing || rootOverride == nil else { return ["error": "history import only works in a test run"] }
        guard let source = historySource(named: name, rootOverride: rootOverride) else {
            return ["error": "no readable \(name) history found"]
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let places = FlowChromium.places(in: source, limit: limit)
        historyImport = .reading(source.name, places.count)
        mergeHistory(places, source: source.name, into: browser)
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        return ["source": source.name, "places": places.count, "visits": browser.history.visitCount,
                "seconds": seconds, "historyFile": Store.file("history.json").path]
    }

    private func historySource(named name: String, rootOverride: URL?) -> FlowSource? {
        guard let source = Chromium.known.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        if let rootOverride {
            let profiles = Self.historyProfiles(in: rootOverride)
            guard !profiles.isEmpty else { return nil }
            return FlowSource(source: source, profiles: profiles, isArc: source.name == "Arc", locked: false, rootOverride: rootOverride)
        }
        refreshSources(autoScan: false)
        guard let found = sources.first(where: { $0.id == source.name }), !found.locked else { return nil }
        return found
    }

    private static func historyProfiles(in root: URL) -> [String] {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("History").path) { return [""] }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { entry in
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  FileManager.default.fileExists(atPath: entry.appendingPathComponent("History").path)
            else { return nil }
            return entry.lastPathComponent
        }.sorted()
    }

    /// Places into Copper's history a batch at a time, the window drawing
    /// between batches: years of another browser's history is a lot of
    /// pages, and History is the main actor's.
    static func take(_ places: [Chromium.Place], into history: History, progress: ((Int) -> Void)? = nil) async {
        for (index, place) in places.enumerated() {
            history.take(place.url, title: place.title, count: place.count, last: place.last)
            if index % 1_000 == 999 {
                progress?(index + 1)
                await Task.yield()
            }
        }
        history.settle()
    }

    private func mergeHistory(_ places: [Chromium.Place], source: String, into browser: Browser) {
        historyImport = .reading(source, places.count)
        for (index, place) in places.enumerated() {
            browser.history.take(place.url, title: place.title, count: place.count, last: place.last)
            if index.isMultiple(of: 1000) && index > 0 { historyImport = .reading(source, index) }
        }
        browser.history.settle()
        historyImport = .done(source, places.count, Date())
        browser.announce(places.isEmpty ? "No places from \(source)" : "Brought in \(places.count.formatted()) places from \(source)")
    }

    func source(named name: String) -> FlowSource? {
        sources.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func benchBookmarks(_ nodes: [Bookmark]) -> [[String: Any]] {
        nodes.map { node in
            if node.isFolder { return ["id": node.id.uuidString, "title": node.title, "children": benchBookmarks(node.children ?? [])] }
            return ["id": node.id.uuidString, "title": node.title, "url": node.url ?? ""]
        }
    }

    /// `--zip PATH` on `flow scan` / `flow move` (test runs): Safari's
    /// export, taken as the export pane takes it but before answering.
    private func benchZip(_ request: [String: Any]) -> [String: Any]? {
        guard let path = request["zip"] as? String else { return nil }
        guard Store.testing else { return ["error": "--zip only works in a test run"] }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        do { safariExportDate = try SafariExport.read(url).exportedAt } catch {
            return ["error": (error as? SafariExport.Trouble)?.errorDescription ?? "couldn't read the export"]
        }
        Self.safariExport = url
        refreshSources(autoScan: false)
        return nil
    }

    func bench(_ request: [String: Any], in browser: Browser) -> [String: Any] {
        let op = request["op"] as? String ?? "sources"
        switch op {
        case "import":
            guard Store.testing else { return ["error": "history import only works in a test run"] }
            guard let source = request["source"] as? String else { return ["error": "history import needs arc or chrome"] }
            let limit = (request["limit"] as? Int) ?? Int.max
            let root = (request["root"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL }
            return importHistoryNow(named: source, limit: limit, rootOverride: root, in: browser)
        case "sources":
            refreshSources(autoScan: false)
            return ["sources": sources.map { ["name": $0.name, "profiles": $0.profiles, "profileCount": $0.profileCount, "isArc": $0.isArc, "glyph": $0.glyph, "locked": $0.locked, "empty": $0.empty, "root": $0.root.path, "kind": $0.isSafari ? "safari" : "chromium", "export": $0.export?.path ?? "", "readable": $0.readable] }]
        case "root" where (request["source"] as? String)?.caseInsensitiveCompare(FlowSafari.name) == .orderedSame:
            // A copy of Safari's files, read as if Copper had Full Disk
            // Access: `Safari/` + `Container/`, or `none` to let go of it.
            guard Store.testing else { return ["error": "flow root only works in a test run"] }
            guard let path = request["path"] as? String else { return ["error": "root needs --path DIR|none"] }
            if path == "none" {
                Self.roots[FlowSafari.name] = nil
            } else {
                let root = URL(fileURLWithPath: path).standardizedFileURL
                guard FileManager.default.fileExists(atPath: root.path) else { return ["error": "root does not exist"] }
                Self.roots[FlowSafari.name] = root
            }
            refreshSources(autoScan: false)
            guard let updated = self.source(named: FlowSafari.name) else { return ["source": FlowSafari.name, "listed": false] }
            return ["source": updated.name, "root": updated.root.path, "container": updated.safariRoots.container.path,
                    "locked": updated.locked, "empty": updated.empty, "readable": updated.readable]
        case "root":
            guard Store.testing else { return ["error": "flow root only works in a test run"] }
            guard let name = request["source"] as? String,
                  let source = Chromium.known.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
                  let path = request["path"] as? String
            else { return ["error": "root needs a known source and path"] }
            let root = URL(fileURLWithPath: path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: root.path) else { return ["error": "root does not exist"] }
            Self.roots[source.name] = root
            refreshSources(autoScan: false)
            guard let updated = self.source(named: source.name) else { return ["error": "root is not a readable source"] }
            return ["source": updated.name, "root": updated.root.path, "locked": updated.locked, "empty": updated.empty, "profiles": updated.profiles]
        case "bookmarks":
            // In a probe world, inspect the tree that actually landed, not
            // just the source preview (including root order and nesting).
            guard Store.testing else { return ["error": "bookmark tree only works in a test run"] }
            return ["count": browser.bookmarks.count, "roots": Self.benchBookmarks(browser.bookmarks.roots)]
        case "bookmark-move":
            guard Store.testing, let id = (request["id"] as? String).flatMap(UUID.init(uuidString:)),
                  browser.bookmarks.roots.contains(where: { $0.id == id })
            else { return ["error": "bookmark-move requires a probe-world top-level id"] }
            browser.bookmarks.move(id, into: nil)
            return ["roots": Self.benchBookmarks(browser.bookmarks.roots)]
        case "scan":
            if let failed = benchZip(request) { return failed }
            guard let source = source(named: request["source"] as? String ?? "") else { return ["error": "no source"] }
            guard source.readable else { return ["error": source.locked ? "source is locked" : "source has no profile yet"] }
            let haul = scanNow(source)
            if let look = haul.safari {
                return ["source": source.name, "tabs": look.tabs, "spaces": look.spaces, "pins": look.pins,
                        "tabGroups": look.tabGroups, "windows": look.windows, "bookmarks": look.bookmarks,
                        "readingList": look.readingList, "hasBookmarks": look.hasBookmarks, "places": look.places,
                        "hasPasswords": look.hasPasswords, "passwords": look.passwords, "passwordsSkipped": look.passwordsSkipped,
                        "passwordCodes": look.passwordCodes, "passwordNotes": look.passwordNotes, "cards": look.cards,
                        "extensions": look.extensions.count, "direct": look.direct, "fromExport": look.fromExport,
                        "stays": FlowSafari.staysLine(look) ?? "", "stayed": FlowSafari.stayed(look), "notes": look.notes]
            }
            return ["source": source.name, "tabs": haul.tabCount, "spaces": haul.spaces.count, "groups": haul.groupCount,
                    "bookmarks": haul.bookmarkCount, "places": haul.placeCount, "passwords": haul.loginCount,
                    "passkeys": haul.passkeyCount, "extensions": haul.extensions.count,
                    "extensionDetails": haul.extensions.map { item in
                        ["id": item.id, "name": item.name, "enabled": item.enabled] as [String: Any]
                    },
                    "notes": haul.notes]
        case "move":
            // A test run moves freely; the real profile only when the script
            // says so outright (`bench flow move … --real`) — the one way to
            // bring cookies over without clicking through the sheet, and never
            // by accident from a script meant for a test world.
            guard Store.testing || (request["real"] as? Bool) == true else {
                return ["error": "flow move only works in a test run (or with --real)"]
            }
            if Store.testing, let failed = benchZip(request) { return failed }
            guard let source = source(named: request["source"] as? String ?? "") else { return ["error": "no source"] }
            if let only = request["only"] as? String {
                choice = FlowBench.choice(only: only)
            }
            guard !moving else { return ["error": "a move is already running"] }
            guard source.readable else { return ["error": source.locked ? "source is locked" : "source has no profile yet"] }
            _ = scanNow(source)
            // The move runs on (local storage alone is minutes of origins,
            // past the bench's 25 s answer); the script asks `flow status`
            // until it is done, as `storage import` does.
            Task { await move(source, into: browser) }
            return ["started": true, "source": source.name]
        case "status":
            switch phase {
            case .moving(let steps): return ["running": true, "lines": steps.filter { $0.state != .waiting }.map(\.line)]
            case .done(let report):
                return ["running": false, "source": selected?.name ?? "", "report": report.line,
                        "title": report.title, "summary": report.summary.map(\.plain),
                        "landing": report.landing?.uuidString ?? "", "undone": report.undone,
                        "guideOffered": report.guideOffered, "guide": "\(guide)",
                        "tabsSkipped": report.facts.tabsSkipped, "spacesMade": report.facts.spacesMade,
                        "spacesFilled": report.facts.spacesFilled, "pinsAdded": report.facts.pinsAdded,
                        "bookmarksNew": report.facts.bookmarksNew, "placesNew": report.facts.placesNew,
                        "passwordsNew": report.facts.passwordsNew ?? -1, "cookiesInStore": report.cookiesInStore, "profileCookies": report.profileCookies,
                        "cookieSites": report.facts.cookieSites, "tabs": report.tabs, "spaces": report.spaces, "groups": report.groups,
                        "bookmarks": report.bookmarks, "places": report.places, "passwords": report.passwords, "cookies": report.cookies, "passkeys": report.passkeys, "extensions": report.extensions,
                        "localStorageSites": report.storageSites, "localStorageKeys": report.storageKeys, "localStorageKeysSet": report.storageKeysSet,
                        "arcMovedAt": arcMovedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                        "canvasId": report.canvasId ?? "", "notes": report.notes, "stayed": report.stayed,
                        "readingList": report.facts.readingListRead]
            default: return ["running": false, "phase": "\(phase)"]
            }
        case "localstorage":
            // The reader alone, written as `arc-localstorage` JSON, so the
            // two readers can be diffed on the same data. Reads only.
            guard let source = source(named: request["source"] as? String ?? "") else { return ["error": "no source"] }
            guard let out = request["path"] as? String else { return ["error": "localstorage needs --path OUT.json"] }
            let root = (request["root"] as? String).map { URL(fileURLWithPath: $0) } ?? source.root
            let started = Date()
            let found = FlowLocalStorage.read(root: root)
            do { try FlowLocalStorage.json(found.merged).write(to: URL(fileURLWithPath: out)) } catch { return ["error": error.localizedDescription] }
            return ["path": out, "origins": found.merged.count, "keys": found.keyCount, "partitioned": found.partitioned,
                    "undecoded": found.undecoded, "warnings": found.warnings, "seconds": Date().timeIntervalSince(started),
                    "profiles": found.profiles.map { "\($0.name): \($0.origins.count)" }]
        case "open":
            // Through the same door a person would use (`--via settings`
            // presses the Settings row, Settings first opened behind it);
            // the sheet opens on the defaults a person would see. Opening
            // is asynchronous, as it is for a person: ask `flow state`.
            let windows = Windows.all
            let at = (request["window"] as? Int).flatMap { windows.indices.contains($0) ? windows[$0] : nil } ?? browser
            switch request["via"] as? String ?? "bench" {
            case "settings":
                at.tuning = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { Flow.presentFromSettings(at) }
            case "command": present(from: at, via: .command)
            case "menu": present(from: at, via: .menu)
            default: present(from: at, via: .bench)
            }
            if request["again"] as? Bool == true { moveAgain = true }
            return ["opening": true, "window": windows.firstIndex { $0 === at } ?? 0,
                    "arcMovedAt": arcMovedAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""]
        case "close":
            close()
            return ["open": open]
        case "state":
            // What the sheet shows and where it is: one sheet, one size.
            var out = FlowPresenter.shared.describe()
            out["open"] = open
            out["phase"] = phase.name
            out["selected"] = selected?.name ?? ""
            out["sourcesKnown"] = sourcesKnown
            out["sources"] = sources.map { ["name": $0.name, "locked": $0.locked, "empty": $0.empty] as [String: Any] }
            out["readable"] = sources.filter(\.readable).map(\.name)
            out["exports"] = sources.filter { $0.export != nil }.map(\.name)
            out["askedAccess"] = askedAccess.sorted()
            out["moveAgain"] = moveAgain
            out["exporting"] = exporting?.name ?? ""
            out["fileResult"] = fileResult?.text ?? ""
            out["guide"] = "\(guide)"
            if case .done(let report) = phase {
                out["title"] = report.title
                out["summary"] = report.summary.map(\.plain)
            }
            out["movedAt"] = movedAt.mapValues { ISO8601DateFormatter().string(from: $0) }
            out["choice"] = FlowBench.choice(choice)
            if case .moving(let steps) = phase {
                out["lines"] = steps.filter { $0.state != .waiting }.map(\.line)
                out["steps"] = steps.map { ["category": $0.category.rawValue, "state": "\($0.state)", "text": $0.text] }
            }
            return out
        case "events":
            // Counts of what the sheet did since the last `--clear`.
            let log = events
            if request["clear"] as? Bool == true { events.clear() }
            var counts: [String: Int] = [:]
            for entry in log.entries { counts[entry.kind, default: 0] += 1 }
            return ["counts": counts, "overlapping": log.overlapping, "scansPerOpen": log.scansPerOpen,
                    "entries": log.entries.suffix(request["all"] as? Bool == true ? FlowEvents.limit : 60).map {
                        ["at": ($0.at * 1000).rounded() / 1000, "kind": $0.kind, "detail": $0.detail] as [String: Any]
                    }]
        case "key":
            return FlowPresenter.shared.press(request["key"] as? String ?? "")
        case "pick":
            // A source card clicked: its counts read off the main actor, as
            // the sheet does (`flow scan` answers at once instead).
            guard let source = source(named: request["source"] as? String ?? "") else { return ["error": "no source"] }
            scan(source)
            return ["picked": source.name, "phase": phase.name]
        case "shot":
            guard let path = request["path"] as? String else { return ["error": "shot needs --path OUT.png"] }
            return FlowPresenter.shared.shot(to: path)
        case "choose":
            // The switches, set as a person would before pressing the big
            // button: `--only tabs,history`, everything else off.
            guard Store.testing else { return ["error": "flow choose only works in a test run"] }
            choice = FlowBench.choice(only: request["only"] as? String ?? "")
            return ["choice": FlowBench.choice(choice)]
        case "slow":
            guard Store.testing else { return ["error": "flow slow only works in a test run"] }
            Self.slow = max(0, min(10, request["seconds"] as? Double ?? 0))
            return ["slow": Self.slow]
        case "limit":
            guard Store.testing else { return ["error": "flow limit only works in a test run"] }
            let names = (request["only"] as? String ?? "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            // Nothing is read here: a script may limit the list before it
            // points a source at a copy, so the real folder is never listed.
            Self.only = names.isEmpty ? nil : Set(names)
            return ["only": names]
        case "access" where (request["source"] as? String)?.caseInsensitiveCompare(FlowSafari.name) == .orderedSame:
            // Safari: `locked` / `clear` (test runs) as for Chrome; with
            // neither, what macOS says of its folder — measured on the copy
            // `flow root` gave, never this Mac's own Safari from a probe.
            let name = FlowSafari.name
            switch request["state"] as? String ?? "" {
            case "locked":
                guard Store.testing else { return ["error": "flow access locked only works in a test run"] }
                Self.forced[name] = .locked
                refreshSources(autoScan: false)
                return ["source": name, "forced": "locked"]
            case "clear":
                guard Store.testing else { return ["error": "flow access clear only works in a test run"] }
                Self.forced[name] = nil
                refreshSources(autoScan: false)
                return ["source": name, "forced": ""]
            case "":
                if let forced = Self.forced[name] { return ["source": name, "state": "\(forced)", "forced": true] }
                if let root = Self.roots[name] { return FlowSafari.report(.copy(at: root)) }
                if Flow.probe { return ["source": name, "state": "locked", "note": "a probe never looks at this Mac's own Safari"] }
                return FlowSafari.report(.system)
            default:
                return ["error": "access state is locked or clear"]
            }
        case "access":
            // `flow access --source Chrome` reports what macOS says about
            // every file a move reads; `locked` / `clear` (test runs) make it
            // locked without touching the folder, or let it be read again.
            guard let name = request["source"] as? String,
                  let known = Chromium.known.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
            else { return ["error": "access needs --source NAME"] }
            switch request["state"] as? String ?? "" {
            case "locked":
                guard Store.testing else { return ["error": "flow access locked only works in a test run"] }
                Self.forced[known.name] = .locked
                return ["source": known.name, "forced": "locked"]
            case "clear":
                guard Store.testing else { return ["error": "flow access clear only works in a test run"] }
                Self.forced[known.name] = nil
                return ["source": known.name, "forced": ""]
            case "":
                if let forced = Self.forced[known.name] { return ["source": known.name, "state": "\(forced)", "forced": true] }
                let root = Self.roots[known.name] ?? known.root
                var out = FlowAccess.report(root: root)
                out["state"] = "\(FlowAccess.state(of: root))"
                out["installed"] = FlowAccess.installed(known.name)
                return out
            default:
                return ["error": "access state is locked or clear"]
            }
        case "allow":
            // The locked card's primary button. A test run opens nothing.
            if let source = source(named: request["source"] as? String ?? "") {
                allow(source)
                return ["page": FlowAccess.openPrivacySettings(fullDisk: source.isSafari), "source": source.name]
            }
            return ["page": FlowAccess.openPrivacySettings()]
        case "passphrase":
            // A test passphrase for a source's encrypted fixture (test runs
            // only, this run only): its passwords, cookies and passkeys are
            // read with it, and kept in the in-memory stand-in, never the
            // keychain.
            guard Store.testing else { return ["error": "flow passphrase only works in a test run"] }
            guard let name = request["source"] as? String,
                  let known = Chromium.known.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
            else { return ["error": "passphrase needs --source NAME"] }
            guard let path = request["path"] as? String,
                  let text = try? String(contentsOfFile: path, encoding: .utf8)
            else { return ["error": "passphrase needs --path FILE (the passphrase on its first line)"] }
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            guard !line.isEmpty else { return ["error": "the passphrase file is empty"] }
            FlowSecrets.passphrases[known.name] = line
            return ["source": known.name, "passphrase": true, "sink": FlowSecrets.sink.name]
        case "secrets":
            guard Store.testing else { return ["error": "flow secrets only works in a test run"] }
            if request["clear"] as? Bool == true { FlowProbeSink.shared.clear() }
            return FlowProbeSink.shared.describe()
        case "export":
            // The locked card's "Use an export instead…"; for Safari,
            // `--clear` lets go of the export it was given.
            guard let source = source(named: request["source"] as? String ?? "Chrome") else { return ["error": "no source"] }
            if source.isSafari, request["clear"] as? Bool == true {
                forgetSafariExport()
                return ["export": "", "source": source.name]
            }
            showExport(for: source)
            return ["exporting": source.name]
        case "back":
            exporting = nil
            fileResult = nil
            return ["exporting": ""]
        case "file":
            // A file dropped on the export pane, or picked there.
            guard let path = request["path"] as? String else { return ["error": "file needs --path FILE"] }
            let name = (request["source"] as? String).flatMap { name in
                (Chromium.known.map(\.name) + [FlowSafari.name]).first { $0.caseInsensitiveCompare(name) == .orderedSame }
            } ?? exporting?.name ?? "Chrome"
            guard !fileBusy else { return ["error": "a file is already being read"] }
            takeFile(URL(fileURLWithPath: path), from: name, into: browser)
            return ["started": true]
        case "file-status":
            return ["running": fileBusy, "ok": fileResult?.ok ?? false, "text": fileResult?.text ?? "",
                    "bookmarks": browser.bookmarks.count, "safariExport": Self.safariExport?.lastPathComponent ?? ""]
        case "guide":
            // The done screen's "Open the Chrome guide", as pressed.
            guard case .done(let report) = phase else { return ["error": "the move isn't done"] }
            guard report.guideOffered else { return ["error": "no guide button: nothing came over from Chrome"] }
            Task { await openGuide() }
            return ["started": true]
        case "done":
            guard case .done = phase else { return ["error": "the move isn't done"] }
            finish()
            return ["open": open, "space": Spaces.shared.current(in: browserForUndo ?? browser).uuidString]
        case "undo":
            guard case .done = phase else { return ["error": "the move isn't done"] }
            undo()
            if case .done(let report) = phase { return ["undone": report.undone] }
            return ["undone": false]
        case "spaces":
            // Every space with its loose tabs, as JSON for a script: what a
            // move made, filled or left alone.
            let spaces = Spaces.shared
            return ["pins": spaces.pins.count, "current": spaces.current(in: browser).uuidString,
                    "spaces": spaces.all.map { space -> [String: Any] in
                        let row = spaces.row(space.id)
                        return ["id": space.id.uuidString, "name": space.name, "tabs": row.count,
                                "profile": space.profile ?? "shared",
                                "today": row.filter { !Sections.shared.isSaved($0) }.count,
                                "urls": row.map { ($0.pending ?? $0.address)?.absoluteString ?? "" }]
                    }]
        case "registry":
            let name = request["source"] as? String ?? "Chrome"
            return ["source": name, "registry": FlowAdopt.registry(for: name).mapValues(\.uuidString)]
        case "activate":
            // What coming back from System Settings does, without anything
            // being brought to the front.
            guard Store.testing else { return ["error": "flow activate only works in a test run"] }
            becameActive()
            return ["open": open, "rechecking": FlowMachine.recheckOnActivation(sources: sources.map(\.candidate), open: open)]
        case "probe":
            // Why a source was or wasn't found: the folder, whether the app
            // can list it, and which profile folders carry a Preferences file.
            return ["known": Chromium.known.map { source -> [String: Any] in
                var row: [String: Any] = ["name": source.name, "root": source.root.path,
                                          "exists": FileManager.default.fileExists(atPath: source.root.path)]
                let listed: Bool
                do {
                    _ = try FileManager.default.contentsOfDirectory(at: source.root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                    listed = true
                } catch {
                    listed = false
                }
                row["locked"] = !listed && FileManager.default.fileExists(atPath: source.root.path)
                do {
                    let names = try FileManager.default.contentsOfDirectory(atPath: source.root.path)
                    row["entries"] = names.count
                } catch {
                    row["listError"] = String(describing: error)
                }
                row["profiles"] = FlowChromeTabs.profiles(of: source)
                return row
            }]
        default:
            return ["error": "unknown flow operation \(op)"]
        }
    }
}
