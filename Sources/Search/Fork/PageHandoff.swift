import AppKit
import Combine

// Fork (ardia: automation): Handoff. The page in front — the active tab of the
// window in front — is this Mac's current web-browsing activity, so an iPhone
// or another Mac signed in to the same Apple Account offers to carry on with
// it (Safari there, or that Mac's default browser). It follows the tab's
// address and title as they change, including a single-page site's pushState.
// A private tab, a blank one or anything but http(s) (a canvas, an extension
// page, a file) is never offered. The other way, a page handed to this Mac
// lands as a link from another app does (Links.application(_:continue:)).
//
// The hooks (Spaces.activeChanged / frontChanged) run while windows are being
// built, so the work waits one turn of the run loop and happens once.

@MainActor
final class PageHandoff {
    static let shared = PageHandoff()

    private(set) var activity: NSUserActivity?
    private weak var watched: Tab?
    private var sink: AnyCancellable?
    private var queued = false

    /// The tab in front may have changed.
    func soon() {
        guard !queued else { return }
        queued = true
        DispatchQueue.main.async { [self] in
            queued = false
            follow(Windows.current.active)
        }
    }

    private func follow(_ tab: Tab?) {
        if tab !== watched || sink == nil {
            watched = tab
            // @Published sends before it stores, so the values come from the stream.
            sink = tab.map { tab in
                tab.$address.combineLatest(tab.$title).sink { [weak self, weak tab] address, title in
                    guard let self, let tab, tab === self.watched else { return }
                    self.offer(tab, address, title)
                }
            }
        }
        if tab == nil { offer(nil, nil, "") }
    }

    private func offer(_ tab: Tab?, _ address: URL?, _ title: String) {
        guard let tab, !tab.shy, let url = address, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            activity?.invalidate()
            activity = nil
            return
        }
        let current = activity ?? NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        current.isEligibleForHandoff = true
        current.webpageURL = url
        current.title = title.isEmpty ? url.host() : title
        activity = current
        current.becomeCurrent()
    }

    /// `handoff`: what is offered now.
    static func bench() -> [String: Any] {
        let activity = shared.activity
        return ["offered": activity != nil, "url": activity?.webpageURL?.absoluteString ?? "",
                "title": activity?.title ?? "", "type": activity?.activityType ?? "",
                "tab": shared.watched.map { String($0.id.uuidString.prefix(8)).lowercased() } ?? ""]
    }
}
