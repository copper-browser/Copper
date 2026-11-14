import AppKit
import Combine
import Foundation
import SwiftUI
import WebKit

// One quiet, session-sized model for downloads. WebKit owns the bytes; this
// owns only the little bit of state needed to make their progress legible.
@MainActor
final class Downloads: ObservableObject {
    static let shared = Downloads()

    enum State {
        case running
        case finished
        case failed(String)
        case cancelled
    }

    struct Item: Identifiable {
        let id: UUID
        var download: WKDownload?
        var name: String
        var from: String
        var file: URL?
        var total: Int64?
        var done: Int64
        var speed: Double
        let started: Date
        var state: State
        var resumeData: Data?
        var request: URLRequest?
        /// The tab it came from, and that tab's opener — browser_downloads lists a tab's own.
        var tabs: [UUID] = []
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var unseen = 0
    @Published var popoverOpen = false {
        didSet { if !popoverOpen { doorWindow = nil } }
    }
    @Published private(set) var pulsing = false

    /// The window whose door the list hangs from — one list, in one window.
    /// With every window's door bound to `popoverOpen` itself, two windows
    /// both presented it, and a press in one closed the other's transient
    /// popover, the flag and so the one under the pointer before its button
    /// had the release (the Canvas door's bug, CanvasUI.doorWindow). Nil:
    /// the window in front.
    @Published private(set) var doorWindow: ObjectIdentifier?

    func showsDoor(in browser: Browser) -> Bool {
        popoverOpen && (doorWindow ?? ObjectIdentifier(Windows.current)) == ObjectIdentifier(browser)
    }

    func toggleDoor(in browser: Browser) {
        if showsDoor(in: browser) { popoverOpen = false; return }
        doorWindow = ObjectIdentifier(browser)
        popoverOpen = true
    }

    /// Shown only from `browser`'s door; a dismissal there closes only its own list.
    func door(in browser: Browser) -> Binding<Bool> {
        Binding(
            get: { self.showsDoor(in: browser) },
            set: { open in
                if open { if !self.showsDoor(in: browser) { self.toggleDoor(in: browser) } }
                else if self.showsDoor(in: browser) { self.popoverOpen = false }
            }
        )
    }

    private var observations: [UUID: [NSKeyValueObservation]] = [:]
    private var samples: [UUID: (done: Int64, at: Date, speed: Double)] = [:]
    private var timer: Timer?
    private var pulseWork: DispatchWorkItem?

    var active: [Item] { items.filter { if case .running = $0.state { return true }; return false } }

    /// What the lists show: what is still arriving first, then the rest as
    /// they happened, newest on top. A cancelled download is not a thing to
    /// look at afterwards.
    var shown: [Item] {
        let kept = items.filter { if case .cancelled = $0.state { return false }; return true }
        return kept.filter { if case .running = $0.state { return true }; return false }
            + kept.filter { if case .running = $0.state { return false }; return true }
    }
    var doorShowing: Bool { !items.isEmpty }

    /// The aggregate ring is determinate only when every active download has a
    /// size. A single chunked response keeps the ring in its quiet indeterminate
    /// state rather than pretending its percentage means something.
    var fraction: Double? {
        let current = active
        guard !current.isEmpty, current.allSatisfy({ $0.total != nil }) else { return nil }
        let total = current.compactMap(\.total).reduce(0, +)
        guard total > 0 else { return 0 }
        let done = current.reduce(Int64(0)) { $0 + $1.done }
        return min(1, max(0, Double(done) / Double(total)))
    }

    func began(_ download: WKDownload, name: String? = nil, from host: String? = nil) {
        if let existing = items.firstIndex(where: { $0.download === download }) {
            items[existing].state = .running
            return
        }
        let request = download.originalRequest
        let url = request?.url
        let proposed = name?.isEmpty == false ? name! : (url?.lastPathComponent.isEmpty == false ? url!.lastPathComponent : "download")
        var item = Item(
            id: UUID(), download: download, name: proposed,
            from: host ?? url?.host ?? "", file: nil,
            total: knownTotal(download.progress), done: download.progress.completedUnitCount,
            speed: 0, started: Date(), state: .running, resumeData: nil,
            request: request
        )
        if let tab = AgentTabs.all.first(where: { $0.built != nil && $0.built === download.webView }) {
            item.tabs = [tab.id] + (tab.opener.map { [$0] } ?? [])
        }
        items.insert(item, at: 0)
        observe(download, for: item.id)
        startTimer()
        objectWillChange.send()
    }

    func destined(_ download: WKDownload, to url: URL) {
        guard let index = items.firstIndex(where: { $0.download === download }) else { return }
        items[index].file = url
        items[index].name = url.lastPathComponent
    }

    func finished(_ download: WKDownload) {
        guard let index = items.firstIndex(where: { $0.download === download }) else { return }
        let itemID = items[index].id
        let file = items[index].file ?? download.progress.fileURL
        items[index].file = file
        items[index].done = max(items[index].done, download.progress.completedUnitCount)
        if let total = knownTotal(download.progress) { items[index].total = total }
        items[index].state = .finished
        stopObserving(itemID)
        samples.removeValue(forKey: itemID)
        stopTimerIfIdle()
        unseen += 1
        pulsing = active.isEmpty
        pulseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pulsing = false }
        pulseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    func failed(_ download: WKDownload, error: Error, resumeData: Data?) {
        guard let index = items.firstIndex(where: { $0.download === download }) else { return }
        let itemID = items[index].id
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        items[index].resumeData = resumeData
        items[index].done = download.progress.completedUnitCount
        if let total = knownTotal(download.progress) { items[index].total = total }
        items[index].state = cancelled ? .cancelled : .failed(error.localizedDescription)
        if let file = items[index].file {
            try? FileManager.default.removeItem(at: file)
        } else if let file = download.progress.fileURL {
            try? FileManager.default.removeItem(at: file)
        }
        stopObserving(itemID)
        samples.removeValue(forKey: itemID)
        stopTimerIfIdle()
        if !cancelled { unseen += 1 }
    }

    func cancel(_ item: Item) {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              let download = items[index].download else { return }
        items[index].state = .cancelled
        stopObserving(item.id)
        samples.removeValue(forKey: item.id)
        stopTimerIfIdle()
        download.cancel { [weak self, weak download] resumeData in
            guard let self else { return }
            if let index = self.items.firstIndex(where: { $0.id == item.id }) {
                self.items[index].resumeData = resumeData
                if let file = self.items[index].file { try? FileManager.default.removeItem(at: file) }
                else if let file = download?.progress.fileURL { try? FileManager.default.removeItem(at: file) }
            }
        }
    }

    /// The failed row goes as its second attempt begins, so the list shows
    /// one download trying again rather than a corpse beside a newcomer.
    func retry(_ item: Item, in browser: Browser) {
        // Only something that stopped: retrying a download still arriving
        // would start a second copy and lose track of the first.
        switch item.state {
        case .failed, .cancelled: break
        default: return
        }
        guard let web = browser.active?.web else { return }
        let oldID = item.id
        let completion: @MainActor @Sendable (WKDownload) -> Void = { [weak browser, weak self] download in
            browser?.keep(download)
            self?.items.removeAll { $0.id == oldID }
        }
        if let resume = item.resumeData, #available(macOS 11.3, *) {
            web.resumeDownload(fromResumeData: resume, completionHandler: completion)
        } else if let request = item.request, #available(macOS 11.3, *) {
            web.startDownload(using: request, completionHandler: completion)
        } else if let index = items.firstIndex(where: { $0.id == oldID }) {
            items[index].state = .failed("Retry unavailable")
        }
    }

    func remove(_ item: Item) {
        stopObserving(item.id)
        samples.removeValue(forKey: item.id)
        items.removeAll { $0.id == item.id }
        stopTimerIfIdle()
    }

    func clearFinished() {
        let gone = items.filter { if case .running = $0.state { return false }; return true }
        gone.forEach { stopObserving($0.id); samples.removeValue(forKey: $0.id) }
        items.removeAll { if case .running = $0.state { return false }; return true }
        unseen = 0
        stopTimerIfIdle()
    }

    func seen() { unseen = 0 }

    private func observe(_ download: WKDownload, for id: UUID) {
        let progress = download.progress
        let keys: [NSKeyValueObservation] = [
            progress.observe(\.completedUnitCount, options: [.new]) { [weak self, weak download] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let download else { return }
                    self.sync(download, id: id)
                }
            },
            progress.observe(\.totalUnitCount, options: [.new]) { [weak self, weak download] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let download else { return }
                    self.sync(download, id: id)
                }
            },
            progress.observe(\.fractionCompleted, options: [.new]) { [weak self, weak download] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let download else { return }
                    self.sync(download, id: id)
                }
            }
        ]
        observations[id] = keys
        sync(download, id: id)
    }

    private func sync(_ download: WKDownload, id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let progress = download.progress
        items[index].done = progress.completedUnitCount
        items[index].total = knownTotal(progress)
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func sample() {
        let now = Date()
        for index in items.indices {
            guard case .running = items[index].state else { continue }
            let id = items[index].id
            guard let download = items[index].download else { continue }
            sync(download, id: id)
            let done = items[index].done
            if let prior = samples[id] {
                let elapsed = max(0.01, now.timeIntervalSince(prior.at))
                let instant = max(0, Double(done - prior.done) / elapsed)
                let speed = prior.speed == 0 ? instant : prior.speed * 0.72 + instant * 0.28
                items[index].speed = speed
                samples[id] = (done, now, speed)
            } else {
                samples[id] = (done, now, items[index].speed)
            }
        }
    }

    private func stopObserving(_ id: UUID) {
        observations[id]?.forEach { $0.invalidate() }
        observations.removeValue(forKey: id)
    }

    private func stopTimerIfIdle() {
        guard active.isEmpty else { return }
        timer?.invalidate()
        timer = nil
    }

    private func knownTotal(_ progress: Progress) -> Int64? {
        guard !progress.isIndeterminate, progress.totalUnitCount >= 0 else { return nil }
        return progress.totalUnitCount
    }
}
