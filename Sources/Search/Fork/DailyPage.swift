import AppKit
import SwiftUI

// A page for the start of the day: the first window, launch, return to Copper
// or wake after the day turns over (3 AM by default, `daily.hour`) opens it as
// the active tab, once. Every other window that day restores as it always did.
// Off until Settings › General › Morning page has an address (`daily.url`);
// `daily.shown` is when it last opened.
@MainActor
enum DailyPage {
    static var address: URL? {
        let typed = (Store.settings.string(forKey: "daily.url") ?? "").trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: typed), url.scheme?.hasPrefix("http") == true, url.host() != nil else { return nil }
        return url
    }
    static var hour: Int {
        let stored = Store.settings.object(forKey: "daily.hour") as? Int ?? 3
        return (0...23).contains(stored) ? stored : 3
    }

    /// When the day that `now` belongs to began: today at `hour`, or yesterday
    /// at `hour` while it is still before it. Wall-clock, so a DST night moves nothing.
    nonisolated static func dayStart(_ now: Date, hour: Int, calendar: Calendar = .current) -> Date {
        let today = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
        if today <= now { return today }
        return calendar.date(byAdding: .day, value: -1, to: today).flatMap {
            calendar.date(bySettingHour: hour, minute: 0, second: 0, of: $0)
        } ?? today
    }

    /// Whether the page is still to be shown today.
    nonisolated static func due(now: Date, lastShown: Date?, hour: Int, calendar: Calendar = .current) -> Bool {
        guard let lastShown else { return true }
        return lastShown < dayStart(now, hour: hour, calendar: calendar)
    }

    private static var watching = false

    /// A window is up (launch, ⌘N, Dock): show the page if it is due. Also the
    /// first call starts listening for Copper coming to the front and the Mac waking.
    static func windowUp(_ browser: Browser) {
        if !watching {
            watching = true
            let center = NotificationCenter.default
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { check(Windows.current) }
            }
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { if NSApp.isActive { check(Windows.current) } }
            }
        }
        // After the launch's own pass: the restore is done and `Windows.main` exists.
        DispatchQueue.main.async { check(browser) }
    }

    static func check(_ browser: Browser, now: Date = Date()) {
        guard !Headless.on, let url = address else { return }
        let shown = Store.settings.object(forKey: "daily.shown") as? Double
        guard due(now: now, lastShown: shown.map { Date(timeIntervalSince1970: $0) }, hour: hour) else { return }
        Store.settings.set(now.timeIntervalSince1970, forKey: "daily.shown")
        if let open = browser.tabs.first(where: { $0.address?.host() == url.host() && $0.address?.path() == url.path() }) {
            browser.select(open)
            open.go(to: url) // today's edition, not the one left open yesterday
        } else {
            browser.open(url, foreground: true)
        }
        Breadcrumbs.note("daily-page", [("host", url.host() ?? "-")])
    }
}

/// Settings › General: the address, empty for off.
struct DailyPageLine: View {
    @AppStorage("daily.url", store: Store.settings) private var url = ""

    var body: some View {
        Line("Morning page", "Opens once a day, in the first window after 3 AM. Empty for off.") {
            TextField("", text: $url)
                .fieldExample("https://…", when: url.isEmpty)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 220)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .settingsField()
                .accessibilityLabel("Morning page address")
        }
    }
}
