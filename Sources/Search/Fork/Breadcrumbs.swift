import AppKit
import Darwin
import Foundation

// What Copper was doing, a line at a time, so a crash report has a "before".
//
// Metadata only, on purpose: launches and clean quits, each agent tool call
// (its name, the tab's short id, how long it took, ok or the kind of error),
// a web page's process going away (its host, nothing more) and a pulse a
// minute with the memory footprint and how many tabs and web views there are.
// Never page content, an address's path or query, form values, typed text,
// cookies or a tool's arguments — this file is something a person may paste
// into an issue without reading it first.
//
// `logs/trail.log` in the data folder, a line per event, each written straight
// through to the file (no buffer in the process for a crash to take with it).
// Past ~1.5 MB it becomes `trail.previous.log` and a fresh file starts, so the
// two together stay under 3 MB. A launch line with no quit line after it is a
// run that died; Crashes reads that at the next launch.
//
//     2026-10-07T04:13:40.123Z 5511 tool name=browser_click tab=1a2b3c4d ms=212 result=ok

enum Breadcrumbs {
    /// Every write, in order, off whatever thread asked.
    private static let queue = DispatchQueue(label: "copper.breadcrumbs", qos: .utility)
    /// Opened on first use, touched only on `queue`.
    private static var log: Log?
    /// Only the app writes: the CLI and the stdio bridge are the same binary
    /// and must never add lines to a world's trail.
    private static var on = false
    private static var pulse: DispatchSourceTimer?

    static var folder: URL { Store.folder.appendingPathComponent("logs", isDirectory: true) }

    // MARK: - the events

    /// The app is starting. Hands back, on the trail's own queue, what the
    /// trail said before this launch's line went in — so a run that never
    /// wrote its quit line can be recognised.
    static func launched(before: @escaping ([Crumb]) -> Void) {
        guard !on else { return }
        on = true
        let info = ProcessInfo.processInfo
        let os = info.operatingSystemVersion
        let fields: [(String, String)] = [
            ("version", Updater.version),
            ("build", String(Updater.build)),
            ("macos", "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
            ("headless", Headless.on ? "yes" : "no"),
            ("world", Store.world ?? "main"),
        ]
        let line = format("launch", fields, at: Date())
        queue.async {
            before(read(in: folder))
            write(line)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            quit()
        }
        startPulse()
    }

    /// A clean quit: written before the process goes, not queued behind it.
    static func quit() {
        guard on else { return }
        let line = format("quit", [], at: Date())
        queue.sync { write(line) }
    }

    /// One agent tool call, from MCP, the agent pane or a linked app.
    static func tool(_ name: String, tab: UUID?, started: Date, error: Error?) {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        var fields: [(String, String)] = [("name", name)]
        if let tab { fields.append(("tab", String(tab.uuidString.prefix(8)).lowercased())) }
        fields.append(("ms", String(ms)))
        fields.append(("result", error == nil ? "ok" : "error"))
        if let error { fields.append(("class", errorClass(error))) }
        note("tool", fields)
    }

    /// A page's WebContent process went away (memory pressure, a crash).
    static func webContentGone(host: String?, inFront: Bool) {
        note("webcontent-gone", [("host", host.flatMap { $0.isEmpty ? nil : $0 } ?? "-"), ("front", inFront ? "yes" : "no")])
    }

    static func note(_ event: String, _ fields: [(String, String)]) {
        guard on else { return }
        let line = format(event, fields, at: Date())
        queue.async { write(line) }
    }

    // MARK: - the pulse

    /// Once a minute: what the app weighs and what it is holding. Counted on
    /// the main thread, where the tabs live; written on the trail's queue.
    private static func startPulse() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(5))
        timer.setEventHandler {
            // Fork (tab-memory): and what the pages weigh — every web process
            // once, and the heaviest by its host (never more of the address),
            // so "Copper was using a lot of memory" has a which and a when.
            let (tabs, views, web, top) = MainActor.assumeIsolated { () -> (Int, Int, UInt64, String) in
                let all = AgentTabs.all
                var weighed: [pid_t: (UInt64, String)] = [:]
                for tab in all {
                    guard let (pid, bytes) = Heat.shared.weight(of: tab), weighed[pid] == nil else { continue }
                    weighed[pid] = (bytes, tab.address?.host ?? "-")
                }
                let heaviest = weighed.values.max { $0.0 < $1.0 }
                return (all.count, all.filter { $0.built != nil }.count, weighed.values.reduce(0) { $0 + $1.0 },
                        heaviest.map { "\($0.1):\($0.0 / 1_048_576)MB" } ?? "-")
            }
            note("pulse", [("mem", footprint().map { "\($0 / 1_048_576)MB" } ?? "-"), ("tabs", String(tabs)), ("views", String(views)),
                           ("web", "\(web / 1_048_576)MB"), ("top", top)])
        }
        timer.resume()
        pulse = timer
    }

    /// The physical footprint — the number macOS weighs a process by when it
    /// is short of memory.
    static func footprint(of pid: pid_t = getpid()) -> UInt64? {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    /// What kind of failure, never what it said: a message can carry page
    /// text or an address. A Cocoa or WebKit error is its domain and code.
    static func errorClass(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        let name = String(describing: type(of: error))
        if name.contains("NSError") {
            let ns = error as NSError
            return clean("\(ns.domain)#\(ns.code)")
        }
        return clean(name)
    }

    // MARK: - lines

    private static func write(_ line: String) {
        if log == nil { log = Log(folder: folder) }
        log?.append(line)
    }

    /// Formatters are not cheap to make; one is kept, behind a lock, since a
    /// line is formatted on the caller's thread with the caller's time.
    private static let stamps: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
    private static let stampLock = NSLock()

    static func format(_ event: String, _ fields: [(String, String)], at date: Date, pid: Int32 = getpid()) -> String {
        stampLock.lock()
        let stamp = stamps.string(from: date)
        stampLock.unlock()
        let rest = fields.map { "\($0.0)=\(clean($0.1))" }.joined(separator: " ")
        return "\(stamp) \(pid) \(event)" + (rest.isEmpty ? "" : " \(rest)")
    }

    /// A value is one word: no spaces or line breaks to split a line on.
    private static func clean(_ value: String) -> String {
        let one = value.map { $0.isWhitespace ? "_" : $0 }
        return String(one.prefix(120))
    }

    /// Both files' lines, oldest first, parsed. Lines that don't parse (a
    /// half-written last line after a power cut) are skipped.
    static func read(in folder: URL) -> [Crumb] {
        let names = ["trail.previous.log", "trail.log"]
        return names.flatMap { name -> [Crumb] in
            guard let data = FileManager.default.contents(atPath: folder.appendingPathComponent(name).path) else { return [] }
            return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { Crumb(String($0)) }
        }
    }

    // MARK: - the file

    /// One line, one write(2) on an O_APPEND descriptor: the kernel has it
    /// the moment `append` returns, whatever happens to the process next.
    final class Log {
        let file: URL
        let previous: URL
        let cap: Int
        private var handle: FileHandle?
        private var size = 0

        init(folder: URL, cap: Int = 1_500_000) {
            file = folder.appendingPathComponent("trail.log")
            previous = folder.appendingPathComponent("trail.previous.log")
            self.cap = cap
        }

        func append(_ line: String) {
            let data = Data((line + "\n").utf8)
            if handle == nil { reopen() }
            if size > 0, size + data.count > cap { rotate() }
            guard let handle else { return }
            do {
                try handle.write(contentsOf: data)
                size += data.count
            } catch {
                // A full disk: drop the line and try a fresh descriptor next time.
                try? handle.close()
                self.handle = nil
            }
        }

        private func reopen() {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { return }
            let end = lseek(fd, 0, SEEK_END)
            size = end > 0 ? Int(end) : 0
            handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }

        private func rotate() {
            try? handle?.close()
            handle = nil
            let files = FileManager.default
            try? files.removeItem(at: previous)
            try? files.moveItem(at: file, to: previous)
            reopen()
        }
    }

    // MARK: - reading a line back

    struct Crumb {
        let time: Date
        let pid: Int32
        let event: String
        let fields: [String: String]
        let line: String

        init?(_ line: String) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int32(parts[1]), let time = Crumb.date(String(parts[0])) else { return nil }
            self.time = time
            self.pid = pid
            event = String(parts[2])
            var fields: [String: String] = [:]
            for part in parts.dropFirst(3) {
                guard let eq = part.firstIndex(of: "=") else { continue }
                fields[String(part[..<eq])] = String(part[part.index(after: eq)...])
            }
            self.fields = fields
            self.line = line
        }

        private static let parser: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        private static let lock = NSLock()

        static func date(_ text: String) -> Date? {
            lock.lock()
            defer { lock.unlock() }
            return parser.date(from: text)
        }
    }
}
