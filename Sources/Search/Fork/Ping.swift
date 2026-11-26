import Foundation

// Fork (telemetry): the anonymous daily ping, so we know how many people use
// Copper. Brave's usage-ping model: at most one GET a day (UTC) to
// copper.exowatt.com/ping carrying the version, macOS major.minor, the chip
// and three "first this day/week/month" flags (plus `new` on the very first).
// No ID of any kind: the only thing kept on this Mac is the day of the last
// ping. The server adds the flags up per day (infra/site-aws.yml), so a
// day's d-count is DAU, w-count WAU, m-count MAU. Settings › Privacy turns
// it off. Never sent from a test world, headless, bench or dev build.

@MainActor
enum Ping {
    static let endpoint = URL(string: "https://copper.exowatt.com/ping")!
    /// "yyyy-MM-dd" (UTC) of the last ping the server took.
    static let lastKey = "ping.last"

    private static var prefs: Preferences?
    private static var clock: Timer?
    private static var sending = false

    /// Once the Browser exists: ten seconds after launch, then hourly so a
    /// Copper left open sends the next day's (and retries one that failed).
    static func start(for browser: Browser) {
        guard prefs == nil, !Store.testing, !Headless.on, !browser.prefs.bench, Fork.version != "dev" else { return }
        prefs = browser.prefs
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { sendIfDue() }
        clock = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { sendIfDue() }
        }
        clock?.tolerance = 5 * 60
    }

    static func sendIfDue() {
        guard let prefs, prefs.pings, !sending else { return }
        let now = Date()
        guard let flags = flags(now: now, last: Store.settings.string(forKey: lastKey)) else { return }
        var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        let os = ProcessInfo.processInfo.operatingSystemVersion
        parts.queryItems = [URLQueryItem(name: "v", value: Fork.version),
                            URLQueryItem(name: "os", value: "\(os.majorVersion).\(os.minorVersion)"),
                            URLQueryItem(name: "chip", value: Updates.arch)]
            + flags.map { URLQueryItem(name: $0, value: "1") }
        var request = URLRequest(url: parts.url!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        sending = true
        // URLSession works off the main thread; only the answer comes back here.
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let ok = ((response as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    sending = false
                    if ok { Store.settings.set(day(now), forKey: lastKey) }
                }
            }
        }.resume()
    }

    // MARK: - the flags (pure; Tests/SearchTests/PingTests.swift)

    private nonisolated static var utc: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    nonisolated static func day(_ date: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// The flags a ping sent at `now` carries, given the day of the last one;
    /// nil when one already went today. ISO weeks (Monday first, the week
    /// that holds Jan 1–3 may belong to the year before).
    nonisolated static func flags(now: Date, last: String?) -> [String]? {
        let today = day(now)
        guard last != today else { return nil }
        let before = last.flatMap { text -> Date? in
            let n = text.split(separator: "-").compactMap { Int($0) }
            guard n.count == 3 else { return nil }
            return utc.date(from: DateComponents(year: n[0], month: n[1], day: n[2]))
        }
        let cal = utc
        func week(_ d: Date) -> [Int] { let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d); return [c.yearForWeekOfYear!, c.weekOfYear!] }
        func month(_ d: Date) -> [Int] { let c = cal.dateComponents([.year, .month], from: d); return [c.year!, c.month!] }
        var flags = ["d"]
        if before.map({ week($0) != week(now) }) ?? true { flags.append("w") }
        if before.map({ month($0) != month(now) }) ?? true { flags.append("m") }
        if last == nil { flags.append("new") }
        return flags
    }
}
