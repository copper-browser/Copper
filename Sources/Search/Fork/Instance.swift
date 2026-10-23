import AppKit
import Darwin
import Foundation

/// One Copper process per world, and probes that hand a Dock click or a plain
/// `open Copper.app` to the real Copper instead of swallowing it.
///
/// The lock is `flock` on `<world folder>/instance.lock`, taken before the
/// browser, the session, MCP or any window exists and held for the life of the
/// process. The kernel owns its lifetime: exit, crash or `kill -9` releases it,
/// so a stale lock file never needs cleaning up. The holder writes its pid into
/// the file so the updater's waiter (a shell script, no flock there) can tell a
/// new holder from the old one.
enum Instance {
    private static var descriptor: Int32 = -1

    /// SearchApp.init, first line. The `copper` CLI (`--cli`) and the stdio
    /// MCP bridge (`--mcp-stdio`) are the same binary run as clients of a
    /// running Copper; they never take a world's lock. A second process for a
    /// world that already has one activates the holder (unless headless) and
    /// exits here, before anything is restored or bound. Any failure other
    /// than "someone holds it" fails open: Copper starts as it always did.
    static func acquireIfNeeded() {
        let arguments = CommandLine.arguments
        guard descriptor < 0, !arguments.contains("--cli"), !arguments.contains("--mcp-stdio") else { return }

        let file = Store.file("instance.lock")
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            Updates.note("instance lock: folder failed (\(error.localizedDescription)); starting without it")
            return
        }
        // O_CLOEXEC: no helper this process spawns may carry the lock past it.
        let fd = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            Updates.note("instance lock: open failed (\(String(cString: strerror(errno)))); starting without it")
            return
        }
        // A probe asking "is this world running?" holds a shared lock for a
        // moment (isRunning); a few short retries keep that from reading as a
        // second Copper.
        var failure: Int32 = 0
        for attempt in 0..<8 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { failure = 0; break }
            failure = errno
            guard failure == EWOULDBLOCK, attempt < 7 else { break }
            usleep(40_000)
        }
        if failure == EWOULDBLOCK {
            let owner = ownerPID(in: file)
            close(fd)
            Updates.note("instance lock: \(Store.folder.lastPathComponent) already running\(owner.map { " as pid \($0)" } ?? ""); pid \(getpid()) exiting")
            if !Headless.on, let owner, let running = NSRunningApplication(processIdentifier: owner) {
                // The main world's second launch (`open -n`, a relaunch that
                // raced) is a Dock click that reached the wrong process: the
                // running Copper gets the reopen too, so one with no browser
                // window brings one back rather than coming forward empty
                // (Fork/LaunchWatchdog.swift). A probe's would be handed on
                // to the main world (`reopenFromProbe`), so a probe only
                // activates its holder, as before.
                if Store.world == nil { reopen(owner) }
                running.activate(options: [.activateAllWindows])
            }
            exit(0)
        }
        if failure != 0 {
            Updates.note("instance lock: flock failed (\(String(cString: strerror(failure)))); starting without it")
            close(fd)
            return
        }
        let pid = "\(getpid())\n"
        _ = ftruncate(fd, 0)
        _ = pid.withCString { pwrite(fd, $0, strlen($0), 0) }
        descriptor = fd
    }

    /// The pid holding a world's lock, or nil when nobody does. flock is the
    /// authority; the pid in the file is only read once the lock is known to
    /// be held. A shared, non-blocking probe: it never creates the file and
    /// never blocks the holder.
    static func isRunning(worldFolder: URL) -> pid_t? {
        let file = worldFolder.appendingPathComponent("instance.lock")
        let fd = open(file.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil } // no file: no Copper has run there since the lock existed
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            _ = flock(fd, LOCK_UN)
            return nil
        }
        guard errno == EWOULDBLOCK else { return nil }
        return ownerPID(in: file) ?? 0
    }

    /// Links' `applicationShouldHandleReopen`: LaunchServices delivers a Dock
    /// click or a plain `open` of the bundle to whichever running instance it
    /// picks, and with an agent's headless probe alive that can be the probe.
    /// A probe (a test world or a headless run) never shows or activates
    /// itself for it: it activates the main world if that is running, or
    /// launches it — a new instance, with a clean environment (`launch`).
    /// True when the reopen was handled here.
    @MainActor static func reopenFromProbe(hasVisibleWindows: Bool) -> Bool {
        guard Store.world != nil || Headless.on, let target = mainWorld else { return false }
        // This process is the main world (a headless main, or the test seam's
        // target): an ordinary reopen, nothing to hand on.
        guard target.folder.standardizedFileURL.path != Store.folder.standardizedFileURL.path else { return false }

        // A main Copper from before the lock existed holds none: found by
        // its environment instead (no SEARCH_PROBE), so a reopen never starts
        // a second browser on the same profile.
        if let pid = isRunning(worldFolder: target.folder) ?? (target.environment == nil ? unlockedMainInstance() : nil) {
            Updates.note("probe reopen in \(Store.folder.lastPathComponent): handed to the \(target.name) world pid \(pid)")
            // A reopen, not just an activation: a main Copper whose windows
            // were all closed brings one back instead of coming forward
            // with nothing on screen.
            if pid > 0 {
                sendReopen(to: pid)
                if target.environment == nil { handFocus(to: pid) }
            }
            return true
        }

        // A second click while the first one's launch is still coming up
        // waits for that launch rather than starting another.
        if launching {
            Updates.note("probe reopen in \(Store.folder.lastPathComponent): the \(target.name) world is already on its way")
            return true
        }
        launch(target)
        whenRunning(target) { pid in
            if target.environment == nil { handFocus(to: pid) }
        }
        return true
    }

    // MARK: - the person's focus, handed on

    /// A Dock click, an `open` or a link that LaunchServices routed to a
    /// probe arrives with the activation the person meant for Copper. It is
    /// passed on with `activate(from: .current)` — macOS's cooperative
    /// hand-off, which only works while this process is still the active
    /// one; asked for from a background process, macOS may simply refuse,
    /// and the main Copper stays behind whatever was in front. So:
    ///
    /// - this probe active: handed over now;
    /// - not yet (the Apple Event got here before its activation did): held
    ///   for the activation, which Headless.swift reports through
    ///   `activationArrived`, for at most a second — then asked for anyway;
    /// - the main Copper still launching: `whenRunning` waits for its lock,
    ///   and Headless keeps the activation meanwhile (`handingOff`).
    @MainActor private static var waitingForActivation: (pid: pid_t, until: Date)?
    /// A launch of the main world is under way (`whenRunning`).
    @MainActor private static var launchingUntil: Date?

    @MainActor static var launching: Bool { (launchingUntil ?? .distantPast) > Date() }

    /// Whether a hand-off still needs this probe's activation.
    @MainActor static var handingOff: Bool {
        launching || (waitingForActivation.map { $0.until > Date() } ?? false)
    }

    /// Brings the main Copper (`pid`) to the front, from this probe.
    @MainActor static func handFocus(to pid: pid_t) {
        guard let running = NSRunningApplication(processIdentifier: pid), !running.isActive else { return }
        guard NSApp.isActive else {
            let until = Date().addingTimeInterval(1)
            waitingForActivation = (pid, until)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let waiting = waitingForActivation, waiting.pid == pid, waiting.until == until else { return }
                waitingForActivation = nil
                // No activation came with it (an `open -g`, a link opened
                // in the background): ask, and let macOS decide.
                NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
            }
            return
        }
        waitingForActivation = nil
        if !running.activate(from: .current, options: [.activateAllWindows]) {
            running.activate(options: [.activateAllWindows])
            Updates.note("probe hand-off: cooperative activation of pid \(pid) refused; asked instead")
        }
    }

    /// Headless.swift, on this probe's activation: true when it was passed
    /// straight on to a main Copper that was waiting for it.
    @MainActor static func activationArrived() -> Bool {
        guard let waiting = waitingForActivation, waiting.until > Date() else { return false }
        handFocus(to: waiting.pid)
        return true
    }

    /// Runs `then` once the target world holds its lock — every 100 ms, for
    /// twenty seconds at most: a cold start on a slow disk is a few of
    /// those. Gives up with a line in update.log, and lets go of an
    /// activation it was holding for the launch.
    @MainActor static func whenRunning(_ target: Target, tries: Int = 0, then: @escaping (pid_t) -> Void) {
        if tries == 0 { launchingUntil = Date().addingTimeInterval(20) }
        if let pid = isRunning(worldFolder: target.folder), pid > 0 {
            launchingUntil = nil
            then(pid)
            // Whatever activation this headless probe kept for the launch
            // and did not pass on (a test seam's world takes none) goes back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if Headless.on, NSApp.isActive, !handingOff { NSApp.deactivate() }
            }
            return
        }
        guard tries < 200 else {
            launchingUntil = nil
            Updates.note("probe hand-off: the \(target.name) world never came up")
            if Headless.on, NSApp.isActive { NSApp.deactivate() }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { whenRunning(target, tries: tries + 1, then: then) }
    }

    /// The reopen event LaunchServices itself would send, aimed at exactly
    /// that process — so LaunchServices gets no second say in which Copper
    /// it reaches.
    @MainActor private static func sendReopen(to pid: pid_t) { reopen(pid) }

    /// `sendReopen`, for `acquireIfNeeded`, which runs before anything is
    /// on the main actor's books (SearchApp.init).
    private static func reopen(_ pid: pid_t) {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        do {
            _ = try event.sendEvent(options: [.noReply], timeout: 5)
        } catch {
            Updates.note("probe reopen: sending a reopen to pid \(pid) failed: \(error.localizedDescription)")
        }
    }

    /// `open -n` of the target's bundle — a new instance, never a reopen
    /// event to whichever one LaunchServices would pick — run with a minimal,
    /// Dock-like environment. LaunchServices hands the caller's whole
    /// environment to the app it launches (`open` and NSWorkspace alike, with
    /// or without an explicit environment), so a launch from here would
    /// otherwise carry this probe's SEARCH_PROBE — reopening the probe's own
    /// world — and whatever the agent that started the probe had in its shell.
    static func launch(_ target: Target) {
        let inherited = ProcessInfo.processInfo.environment
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG"] {
            if let value = inherited[key] { environment[key] = value }
        }
        var arguments = ["-n"]
        if let extra = target.environment {
            arguments.append("-g") // the test seam's world never comes forward
            for (key, value) in extra.sorted(by: { $0.key < $1.key }) {
                environment[key] = value
                arguments += ["--env", "\(key)=\(value)"]
            }
        }
        arguments.append(target.bundle.path)
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = arguments
        open.environment = environment
        open.standardInput = FileHandle.nullDevice
        open.standardOutput = FileHandle.nullDevice
        open.standardError = FileHandle.nullDevice
        let name = target.name
        open.terminationHandler = { process in
            Updates.note("probe reopen: open -n of the \(name) world exited \(process.terminationStatus)")
        }
        Updates.note("probe reopen in \(Store.folder.lastPathComponent): launching the \(name) world: open \(arguments.joined(separator: " "))")
        do {
            try open.run()
        } catch {
            Updates.note("probe reopen: could not run open for the \(name) world: \(error.localizedDescription)")
        }
    }

    // MARK: - the main world, and the test seam

    struct Target {
        let name: String
        let folder: URL
        /// nil for the real main world: only the minimal environment `launch` builds.
        let environment: [String: String]?
        let bundle: URL
    }

    /// The world a reopen is handed to. Normally the browser somebody uses:
    /// `~/Library/Application Support/Copper`, launched from the installed
    /// Copper (not this probe's copy, which may be a build folder) with no
    /// environment of ours — and only by a probe of Copper's own bundle id,
    /// the only kind a Dock click on Copper can reach. Test seam, for
    /// end-to-end tests that must never reach that browser: a probe started
    /// with `COPPER_MAIN_WORLD=<name>` (and optionally
    /// `COPPER_MAIN_WORLD_PORT=<mcp port>`) treats the world `Copper (<name>)`
    /// as main and launches it from its own bundle, headless, hidden and
    /// without activating anything.
    static var mainWorld: Target? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let environment = ProcessInfo.processInfo.environment
        let seam = (environment["COPPER_MAIN_WORLD"] ?? "").lowercased()
            .filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
        guard !seam.isEmpty, seam != "1", seam != "test" else {
            guard Bundle.main.bundleIdentifier == Fork.bundle else { return nil }
            return Target(name: "main", folder: support.appendingPathComponent(Fork.name, isDirectory: true),
                          environment: nil, bundle: installedBundle)
        }
        // The seam's world is told it is the main one (COPPER_MAIN_WORLD
        // naming itself): launched with a clean environment it would
        // otherwise take the installed Copper for main and hand a reopen — or
        // a link (Fork/LinkRelay.swift) — on to the browser the test exists
        // to stay away from.
        var launch = ["SEARCH_PROBE": seam, "SEARCH_HEADLESS": "1", "SEARCH_HEADLESS_WINDOW": "hidden", "COPPER_MAIN_WORLD": seam]
        if let port = environment["COPPER_MAIN_WORLD_PORT"], UInt16(port) != nil { launch["SEARCH_MCP_PORT"] = port }
        return Target(name: seam, folder: support.appendingPathComponent("\(Fork.name) (\(seam))", isDirectory: true),
                      environment: launch, bundle: Bundle.main.bundleURL)
    }

    /// Copper where people install it — the order bin/copper looks in — or
    /// this bundle when it is in neither place.
    private static var installedBundle: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for url in [URL(fileURLWithPath: "/Applications/\(Fork.name).app"), home.appendingPathComponent("Applications/\(Fork.name).app")]
        where Bundle(url: url)?.bundleIdentifier == Fork.bundle {
            return url
        }
        return Bundle.main.bundleURL
    }

    /// Another running instance of this bundle that is a main-world Copper
    /// (no SEARCH_PROBE in its environment, not a build-folder run).
    static func unlockedMainInstance() -> pid_t? {
        let me = getpid()
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? Fork.bundle)
        where app.processIdentifier != me && app.executableURL?.path.contains("/.build/") != true {
            guard let environment = environment(of: app.processIdentifier) else { continue }
            if !environment.contains(where: { $0.hasPrefix("SEARCH_PROBE=") }) { return app.processIdentifier }
        }
        return nil
    }

    /// A same-user process's environment (`KERN_PROCARGS2`: argc, the
    /// executable path, argv, then envp up to an empty string), or nil.
    private static func environment(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 } // the executable path
        while index < size, buffer[index] == 0 { index += 1 } // its padding
        var strings: [String] = []
        var start = index
        while index < size {
            if buffer[index] == 0 {
                if index == start, strings.count >= argc { break }
                strings.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        guard strings.count >= argc else { return nil }
        return Array(strings.dropFirst(argc))
    }

    private static func ownerPID(in file: URL) -> pid_t? {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
        else { return nil }
        return pid
    }
}
