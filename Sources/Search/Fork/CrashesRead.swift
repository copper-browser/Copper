import Foundation

// Reading what Crashes.swift keeps: `copper crashes` in a terminal, the
// `browser_crashes` tool for an agent, and the text Settings copies. The CLI
// needs no running Copper — it reads the data folder itself, taking in any
// report that arrived since the last launch first — and so works right after
// a crash, before anything has been reopened.

extension Crashes {
    // MARK: - the CLI

    static let usage = """
    Usage: copper crashes [--json] [list | show [N] [--symbolicate] | path]

      list (default)              Copper's crashes on this Mac, newest first: when, version,
                                  what, and the first frame in Copper's own code
      show [N]                    crash N (1 = newest) in full: how it ended, the crashed
                                  thread's frames, and the breadcrumbs of that run before it
      show N --symbolicate        names for Copper's own frames, from the matching dSYM
                                  (<data>/dsyms/<version>/, or build/Copper.app.dSYM); without
                                  one, the release asset to fetch and where to put it
      path                        the folder the reports are kept in

    Kept on this Mac only; nothing is sent anywhere.
    """

    /// `copper crashes …`. Exit 0 on success, 2 on usage.
    static func cli(_ input: [String], json: Bool) -> Int {
        var args = input
        let symbolicate = args.contains("--symbolicate")
        args.removeAll { $0 == "--symbolicate" }
        switch args.first ?? "list" {
        case "help", "-h", "--help":
            print(usage)
            return 0
        case "path":
            print(folder.path)
            return 0
        case "list":
            guard args.count <= 1, !symbolicate else { return refuse("crashes list takes no arguments") }
            let index = ingest()
            print(json ? encode(listing(index)) : listingText(index))
            return 0
        case "show":
            guard args.count <= 2 else { return refuse("crashes show takes one number") }
            let n = args.count == 2 ? Int(args[1]) : 1
            let index = ingest()
            guard let n, index.entries.indices.contains(n - 1) else {
                return refuse(index.entries.isEmpty ? "no crashes recorded" : "crashes show takes 1–\(index.entries.count)")
            }
            let entry = index.entries[n - 1]
            if json {
                var out = detail(entry, n: n)
                if symbolicate { out["symbolicated"] = symbolicated(entry) }
                print(encode(out))
            } else {
                print(text(entry, n: n, of: index.entries.count))
                if symbolicate { print("\n" + symbolicated(entry)) }
            }
            return 0
        default:
            return refuse("unknown crashes command: \(args[0]) — copper crashes help")
        }
    }

    private static func refuse(_ text: String) -> Int {
        FileHandle.standardError.write(Data("copper: \(text)\n".utf8))
        return 2
    }

    // MARK: - the tool

    static let tool: [String: Any] = [
        "name": "browser_crashes",
        "description": "Copper's own crash history on this Mac, newest first: time, version, exception and the first frame in Copper's code. index=N returns crash N in full — how it ended, the crashed thread's frames and the breadcrumbs (tool calls, page-process exits, memory) of that run before it. Read-only; nothing is sent anywhere.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "index": ["type": "number", "description": "Crash N in full (1 = newest)"],
                "limit": ["type": "number", "description": "How many to list; default 20"],
                "reason": Tools.reasonProperty,
            ] as [String: Any],
            "required": [String](),
        ] as [String: Any],
    ]

    /// The tool's answer, as JSON text. Reads the index; never takes reports
    /// in (the app did at launch) and never touches a page.
    static func answer(_ args: [String: Any]) throws -> String {
        let index = current()
        if let n = (args["index"] as? NSNumber)?.intValue {
            guard index.entries.indices.contains(n - 1) else {
                throw Tools.Failure(text: index.entries.isEmpty ? "No crashes recorded." : "index is 1–\(index.entries.count)")
            }
            return encode(detail(index.entries[n - 1], n: n))
        }
        let limit = max(1, (args["limit"] as? NSNumber)?.intValue ?? 20)
        return encode(listing(index, limit: limit))
    }

    // MARK: - shapes

    static func listing(_ index: Index, limit: Int? = nil) -> [String: Any] {
        let shown = limit.map { Array(index.entries.prefix($0)) } ?? index.entries
        return [
            "folder": folder.path,
            "count": index.entries.count,
            "crashes": shown.enumerated().map { n, entry in
                var row: [String: Any] = ["n": n + 1, "id": entry.id, "kind": entry.kind.rawValue,
                                          "time": stamp(entry.time), "what": entry.headline]
                row["version"] = entry.version
                row["exception"] = entry.exception
                row["signal"] = entry.signal
                row["topFrame"] = entry.topFrame?.text
                row["file"] = entry.file.map { folder.appendingPathComponent($0).path }
                return row
            },
        ]
    }

    static func detail(_ entry: Entry, n: Int) -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var out = (try? encoder.encode(entry)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        out["n"] = n
        out["what"] = entry.headline
        out["file"] = entry.file.map { folder.appendingPathComponent($0).path }
        return out
    }

    static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func stamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    // MARK: - text

    static func listingText(_ index: Index) -> String {
        guard !index.entries.isEmpty else { return "No crashes recorded. (\(folder.path))" }
        var lines = ["\(index.entries.count) kept in \(folder.path), newest first:"]
        for (n, entry) in index.entries.enumerated() {
            let columns = [
                String(n + 1).leftPad(3),
                when(entry.time),
                (entry.version ?? "?").rightPad(16),
                (entry.kind == .fault ? "fault: " + entry.headline : entry.headline).rightPad(30),
                entry.topFrame?.text ?? "",
            ]
            lines.append(columns.joined(separator: "  "))
        }
        lines.append("copper crashes show N for one in full")
        return lines.joined(separator: "\n")
    }

    /// One crash in full: what `show` prints and Settings' Copy Report copies.
    static func text(_ entry: Entry, n: Int, of count: Int) -> String {
        var lines: [String] = []
        let ago = RelativeDateTimeFormatter().localizedString(for: entry.time, relativeTo: Date())
        lines.append("Crash \(n) of \(count) · \(when(entry.time)) (\(ago))\(entry.fatal ? "" : " · a fault Copper lived through")")
        var who = ["\(process) \(entry.version ?? "?")" + (entry.build.map { " (build \($0))" } ?? "")]
        if let os = entry.os { who.append(os) }
        if let pid = entry.pid { who.append("pid \(pid)") }
        lines.append(who.joined(separator: " · "))
        lines.append([entry.headline, entry.codes].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
        if let end = entry.termination, !end.isEmpty { lines.append("Ended: \(end)") }
        if let reason = entry.reason { lines.append("Reason: \(reason)") }
        if let frames = entry.frames, !frames.isEmpty {
            lines.append("")
            lines.append(entry.thread.map { "Thread \($0) crashed:" } ?? "Call stack:")
            for (i, frame) in frames.enumerated() {
                let address = frame.address.map { "0x" + String($0, radix: 16).leftPad(12, "0") } ?? "".rightPad(14)
                lines.append("  " + String(i).leftPad(2) + "  " + frame.image.rightPad(28) + "  " + address + "  " + frame.text)
            }
        }
        if let file = entry.file { lines.append("\nReport: " + folder.appendingPathComponent(file).path) }
        lines.append("")
        let trail = entry.trail ?? []
        if trail.isEmpty {
            lines.append("No breadcrumbs for this run (it predates the trail, or was another Copper's).")
        } else {
            lines.append("Breadcrumbs, that run up to the crash (UTC, oldest first):")
            lines += trail.map { "  " + $0 }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - symbols

    /// Copper's own frames by name, through atos and the dSYM whose UUID is
    /// the crashed binary's. Only ever reads files already on this Mac.
    static func symbolicated(_ entry: Entry, data: URL = Store.folder) -> String {
        guard let binary = entry.binary else { return "Nothing to symbolicate: this entry has no frames from a crash report." }
        let ours = (entry.frames ?? []).enumerated().compactMap { i, frame -> (Int, Frame, UInt64)? in
            guard frame.image == process, let address = frame.address else { return nil }
            return (i, frame, address)
        }
        guard !ours.isEmpty else { return "No frames in \(process)'s own code to symbolicate." }
        let version = entry.version ?? "unknown"
        var mismatched: [String] = []
        for dsym in dsyms(version: version, data: data) {
            guard let dwarf = dwarfFile(in: dsym) else { continue }
            // The UUID is the binary's identity: a dSYM rebuilt from the same
            // commit, or another build of the same version, does not match.
            if let said = run("/usr/bin/dwarfdump", ["--uuid", dwarf.path]), !said.uppercased().contains(binary.uuid.uppercased()) {
                mismatched.append(dsym.path)
                continue
            }
            let hex = { (value: UInt64) in "0x" + String(value, radix: 16) }
            guard let out = run("/usr/bin/atos", ["-o", dwarf.path, "-arch", binary.arch ?? "arm64", "-l", hex(binary.base)] + ours.map { hex($0.2) })
            else { return "atos failed on \(dwarf.path)." }
            let names = out.split(separator: "\n").map(String.init)
            var lines = ["Symbolicated with \(dsym.path):"]
            for (k, (i, frame, address)) in ours.enumerated() {
                lines.append("  " + String(i).leftPad(2) + "  " + frame.image.rightPad(10) + "  " + hex(address) + "  " + (names.indices.contains(k) ? names[k] : frame.text))
            }
            return lines.joined(separator: "\n")
        }

        let shelf = data.appendingPathComponent("dsyms/\(version)", isDirectory: true)
        var lines = ["No dSYM with UUID \(binary.uuid) on this Mac." + (mismatched.isEmpty ? "" : " (Not these, their UUIDs differ: \(mismatched.joined(separator: ", ")).)")]
        if isRelease(version) {
            // One dSYM per CPU from the first Intel release on; the crashed binary says which.
            let asset = "copper-\(version)-macos-\(binary.arch == "x86_64" ? "x86_64" : "arm64").dSYM.zip"
            lines.append("It is a release asset of \(process) \(version) (published from the release workflow on; earlier releases kept none):")
            lines.append("  \(releases)/download/v\(version)/\(asset)")
            lines.append("Put it here, then run this again:")
            lines.append("  mkdir -p \"\(shelf.path)\" && ditto -x -k \(asset) \"\(shelf.path)\"")
        } else {
            lines.append("\(process) \(version) is a local build: its dSYM is the Copper.app.dSYM build.sh left beside that build in build/.")
            lines.append("Run this from that worktree (or copy the .dSYM into \(shelf.path)) and try again.")
        }
        return lines.joined(separator: "\n")
    }

    /// Where a dSYM for this version may be: the shelf in the data folder,
    /// beside this app (a worktree's build/), and build/ under the directory
    /// the command runs in.
    private static func dsyms(version: String, data: URL) -> [URL] {
        let files = FileManager.default
        var found: [URL] = []
        let shelf = data.appendingPathComponent("dsyms/\(version)", isDirectory: true)
        for name in (try? files.contentsOfDirectory(atPath: shelf.path)) ?? [] {
            let item = shelf.appendingPathComponent(name)
            if name.hasSuffix(".dSYM") { found.append(item); continue }
            // An archive unpacked into a folder of its own.
            for inner in (try? files.contentsOfDirectory(atPath: item.path)) ?? [] where inner.hasSuffix(".dSYM") {
                found.append(item.appendingPathComponent(inner))
            }
        }
        let app = Bundle.main.bundleURL
        found.append(app.deletingLastPathComponent().appendingPathComponent(app.lastPathComponent + ".dSYM"))
        found.append(URL(fileURLWithPath: files.currentDirectoryPath).appendingPathComponent("build/\(process).app.dSYM"))
        var seen = Set<String>()
        return found.filter { files.fileExists(atPath: $0.path) && seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func dwarfFile(in dsym: URL) -> URL? {
        let dwarf = dsym.appendingPathComponent("Contents/Resources/DWARF", isDirectory: true)
        guard let name = (try? FileManager.default.contentsOfDirectory(atPath: dwarf.path))?.first(where: { !$0.hasPrefix(".") }) else { return nil }
        return dwarf.appendingPathComponent(name)
    }

    /// The release workflow's versions: 1.0.20261007.31.
    static func isRelease(_ version: String) -> Bool {
        let parts = version.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0) != nil } && parts[2].count == 8
    }

    /// The GitHub releases the updater reads from (Setup.feed, less `latest/download`).
    private static var releases: String {
        Setup.feed.replacingOccurrences(of: "/latest/download", with: "")
    }

    /// A tool's output, or nil when it couldn't run or failed.
    private static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

private extension String {
    func leftPad(_ width: Int, _ fill: Character = " ") -> String {
        count >= width ? self : String(repeating: fill, count: width - count) + self
    }

    func rightPad(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
