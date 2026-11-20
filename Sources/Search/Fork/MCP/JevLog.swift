import Foundation
import ImageIO

// Fork (jev-log): SEARCH_JEV_LOG=<folder> keeps every Jev (TypeSafe
// /v1/systemone) call as one JSON line in <folder>/jev-YYYYMMDD.jsonl, and
// each run's end as a `kind: run` line with the same run_id: training data
// for a small decision model (~/plans/hegemon-mini-jev). Off when unset, and
// only ever in a test or dev world (Store.world), never the browser in use.
//
// What is kept is the request body exactly as sent (it has already passed
// AgentSecrets: secret boxes read as the placeholder, filled secrets are
// scrubbed), minus the pictures (by reference and size only), plus the
// values of card fields the page script marks `sensitive` (cc-exp, cc-name…).
// No header is ever kept, so no key. Writing is on a background queue and
// never throws: a full disk warns once and the run goes on.
enum JevLog {
    static let folder: URL? = {
        guard Store.world != nil, let path = ProcessInfo.processInfo.environment["SEARCH_JEV_LOG"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }()

    /// One decision's Jev calls: who asked (run, step), filled in by Jev.ask,
    /// written once the decision is acted on or dropped (`Session.tick`).
    final class Tick: @unchecked Sendable {
        let run: String?
        let step: Int
        let strategy: String
        private let lock = NSLock()
        private var calls: [[String: Any]] = []
        private var hiddenValues: [String] = []
        var chosen: [String: Any]?

        init(run: String?, step: Int, strategy: String) {
            self.run = run
            self.step = step
            self.strategy = strategy
        }

        /// Values of the read's sensitive fields, taken out of every line.
        func hide(_ values: [String]) {
            lock.lock(); defer { lock.unlock() }
            hiddenValues = values.filter { !$0.isEmpty && $0 != AgentSecrets.placeholder }
        }
        var hidden: [String] { lock.lock(); defer { lock.unlock() }; return hiddenValues }

        func add(_ call: [String: Any]) {
            lock.lock(); defer { lock.unlock() }
            calls.append(call)
        }

        func take() -> [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            defer { calls = [] }
            return calls
        }
    }

    @TaskLocal static var tick: Tick?

    /// Jev.ask, after a clean answer: kept with the decision it belongs to,
    /// or written now when no run asked (Settings' check, say).
    static func record(body: [String: Any], assets: [Jev.Asset], payload: [String: Any], latencyMs: Double, at date: Date = Date()) {
        guard let folder else { return }
        let t = tick
        let call = line(body: body, assets: assets, payload: payload, latencyMs: latencyMs, date: date,
                        run: t?.run, step: t?.step, strategy: t?.strategy, world: Store.world, hidden: t?.hidden ?? [])
        if let t { t.add(call) } else { write([call], to: folder) }
    }

    /// The decision is over: its calls are written with what was chosen and
    /// whether it went into the page.
    static func flush(_ tick: Tick, executed: Bool) {
        guard let folder else { return }
        let calls = tick.take()
        guard !calls.isEmpty else { return }
        write(calls.map { var c = $0; c["chosen"] = tick.chosen ?? NSNull(); c["executed"] = executed; return c }, to: folder)
    }

    /// A run's end, joined to its calls by run_id.
    static func finish(run: String, goal: String, status: String, steps: Int, wallMs: Int, answer: String?) {
        guard let folder else { return }
        write([runLine(run: run, goal: goal, status: status, steps: steps, wallMs: wallMs, answer: answer)], to: folder)
    }

    // MARK: - the lines (pure, for the tests)

    static func line(body: [String: Any], assets: [Jev.Asset], payload: [String: Any], latencyMs: Double, date: Date,
                     run: String?, step: Int?, strategy: String?, world: String?, hidden: [String]) -> [String: Any] {
        let state: Any = body["state"] ?? NSNull()
        let url = ((state as? [String: Any])?["page"] as? [String: Any])?["url"] as? String
        let host: Any = url.flatMap { URL(string: $0)?.host } ?? NSNull()
        let request: [String: Any] = ["state": state, "questions": body["questions"] ?? [String: Any]()]
        let response: [String: Any] = ["answers": payload["answers"] ?? [String: Any](),
                                       "usage": payload["usage"] ?? NSNull(), "model": payload["model"] ?? NSNull()]
        var out: [String: Any] = ["v": 1, "ts": stamp(date), "request": request, "response": response,
                                  "assets": assets.map(meta), "latency_ms": (latencyMs * 10).rounded() / 10,
                                  "chosen": NSNull(), "executed": false]
        out["run_id"] = run ?? NSNull() as Any
        out["step"] = step ?? NSNull() as Any
        out["world"] = world ?? NSNull() as Any
        out["host"] = host
        out["url"] = url ?? NSNull() as Any
        out["strategy"] = strategy ?? NSNull() as Any
        out["model"] = body["model"] ?? NSNull()
        out = redact(out, hiding: hidden) as? [String: Any] ?? out
        return out
    }

    static func runLine(run: String, goal: String, status: String, steps: Int, wallMs: Int, answer: String?) -> [String: Any] {
        var out: [String: Any] = ["v": 1, "kind": "run", "run_id": run, "goal": goal, "status": status, "steps": steps, "wall_ms": wallMs]
        if let answer { out["answer"] = answer }
        return out
    }

    /// A picture by reference and size, never its bytes.
    static func meta(_ asset: Jev.Asset) -> [String: Any] {
        var w: Int?, h: Int?
        if let source = CGImageSourceCreateWithData(asset.data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
            h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        }
        return ["ref": asset.reference, "w": w ?? NSNull(), "h": h ?? NSNull(), "bytes": asset.data.count]
    }

    /// Every string leaf equal to a hidden value becomes the placeholder, and
    /// longer ones (≥ AgentSecrets.shortest) are cut out of any text they're in.
    static func redact(_ value: Any, hiding: [String]) -> Any {
        guard !hiding.isEmpty else { return value }
        switch value {
        case let s as String:
            if hiding.contains(s) { return AgentSecrets.placeholder }
            var out = s
            for h in hiding where h.count >= AgentSecrets.shortest { out = out.replacingOccurrences(of: h, with: AgentSecrets.placeholder) }
            return out
        case let d as [String: Any]: return d.mapValues { redact($0, hiding: hiding) }
        case let a as [Any]: return a.map { redact($0, hiding: hiding) }
        default: return value
        }
    }

    private static func stamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func file(in folder: URL, at date: Date = Date()) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd"
        return folder.appendingPathComponent("jev-\(f.string(from: date)).jsonl")
    }

    // MARK: - writing

    private static let queue = DispatchQueue(label: "copper.jev-log", qos: .utility)
    private static var warned = false

    /// Appends on the log's own queue; `sync` for the tests.
    static func write(_ lines: [[String: Any]], to folder: URL, sync: Bool = false) {
        let work = {
            do {
                var data = Data()
                for line in lines {
                    data.append(try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes]))
                    data.append(0x0A)
                }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = file(in: folder)
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                if !warned { warned = true; Headless.log("SEARCH_JEV_LOG: not written (\(error.localizedDescription)); later failures are silent") }
            }
        }
        if sync { queue.sync(execute: work) } else { queue.async(execute: work) }
    }
}
