import AppKit

// Links from other apps, landed where the person is looking.
//
// Three things stood between a click in Slack (or Mail, or a terminal's
// `open https://…`) and a page in Copper:
//
// 1. LaunchServices hands a URL to *a* running Copper — it resolves the
//    default browser to a bundle id, then picks one process of that bundle.
//    With an agent's probe alive (a headless run, a test world — launched
//    from the installed bundle, so the same id) that is often the probe,
//    which was there first. The probe opened the page in a world nobody can
//    see; Copper came forward with nothing new in it. `Instance` already
//    corrects the same misroute for a Dock click (`reopenFromProbe`); links
//    get the same treatment: a probe hands the address to the main world's
//    process by pid — an Apple Event aimed at one process, never at a bundle
//    id LaunchServices would resolve all over again — launching that world
//    first when nothing holds its lock.
//
// 2. Links always landed in the first window. With a ⌘N window in front the
//    page opened behind it. Now a link lands in the window in front — or the
//    first one still on screen, one in the Dock, or the first window brought
//    back from closed. (The first window's key observer also outlives its
//    red button now — Fork/Windows.swift — so "in front" stays true after
//    it is closed and brought back.)
//
// 3. A file opened with Copper — an .html, or the .webloc Safari writes when
//    a link is dragged to the Desktop; the bundle has claimed both since the
//    start — was turned away for not being http, so Finder activated Copper
//    and nothing happened. A .webloc (or Windows' .url) is read for the
//    address inside it; a page file opens as itself.
@MainActor
enum LinkRelay {
    /// `Links.take`, first line. True when this process is a probe (a test
    /// world or a headless run) and the address has been handed to the main
    /// world instead — see `Instance.handLink`.
    ///
    /// Apple Events arrive on the main thread; `Links.take` is not marked so.
    nonisolated static func hand(_ url: URL) -> Bool {
        MainActor.assumeIsolated {
            guard Store.world != nil || Headless.on else { return false }
            return Instance.handLink(url)
        }
    }

    /// What an address from outside is to open: itself for the web (and
    /// Copper's own `copper://` links), the address inside a .webloc/.url,
    /// a page file as itself. Nil for anything Copper has no business with.
    nonisolated static func accept(_ url: URL) -> URL? {
        switch url.scheme?.lowercased() ?? "" {
        case "http", "https", "copper": return url
        case "file": return inside(url)
        default: return nil
        }
    }

    nonisolated private static func inside(_ file: URL) -> URL? {
        switch file.pathExtension.lowercased() {
        case "html", "htm", "xhtml", "shtml":
            return file
        case "webloc":
            // A property list with one string under `URL`.
            guard let data = try? Data(contentsOf: file),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let text = plist["URL"] as? String
            else { return nil }
            return accept(URL(string: text) ?? file)
        case "url":
            // INI: a `URL=` line under `[InternetShortcut]`.
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            for line in text.split(whereSeparator: \.isNewline) where line.lowercased().hasPrefix("url=") {
                return accept(URL(string: String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)) ?? file)
            }
            return nil
        default:
            return nil
        }
    }

    /// `Links.deliver`: the page goes into the window in front. `first` is
    /// the browser the link handler was handed at launch — the first window's
    /// — kept as the last resort, and shown again when its window was closed.
    ///
    /// "In front" is the stacking order, not who was last key: with Settings
    /// or another panel key, the browser window just behind it is the one
    /// you are looking at. A window in the Dock counts after any on screen.
    static func land(_ url: URL, first: Browser?) {
        let shown = Windows.all.filter { Windows.window(of: $0)?.isVisible == true }
        let stacked = NSApp.orderedWindows.lazy.filter(\.isVisible).compactMap { Windows.owner(of: $0) }.first
        let docked = Windows.all.first { Windows.window(of: $0)?.isMiniaturized == true }
        let target = stacked
            ?? Windows.front.flatMap { front in shown.first { $0 === front } }
            ?? shown.first
            ?? docked
            ?? first
            ?? Windows.main
        target.arrive(url)
        if let window = Windows.window(of: target) ?? (target.primary ? Links.window : nil) {
            // Closed with the app still running (or put in the Dock): the
            // link brings it back, rather than landing in a tab nobody can
            // see. On screen already, it comes forward with the app.
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            // No window to bring back — or none ever made (Fork/LaunchWatchdog.swift).
            Windows.openFirst("link")
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension Instance {
    /// A link from outside, arrived at a probe: handed to the main world's
    /// process — by pid, so LaunchServices gets no second say — or to a
    /// fresh one, launched here and sent the address as soon as it holds
    /// its lock. True when handed on; false for the main world itself, which
    /// opens the link as ever. Same rules as `reopenFromProbe`: the main
    /// world is the installed Copper's, or the test seam's
    /// (`COPPER_MAIN_WORLD`), and a probe of another bundle id hands on
    /// nothing.
    @MainActor static func handLink(_ url: URL) -> Bool {
        guard Store.world != nil || Headless.on, let target = mainWorld else { return false }
        guard target.folder.standardizedFileURL.path != Store.folder.standardizedFileURL.path else { return false }
        if let pid = runningMain(target), pid > 0 {
            Updates.note("link relay in \(Store.folder.lastPathComponent): \(url.absoluteString) to the \(target.name) world pid \(pid)")
            send(url, to: pid, activate: target.environment == nil)
            return true
        }
        // A launch already on its way (an earlier link, a Dock click) gets
        // this address too rather than a second launch.
        if !launching {
            Updates.note("link relay in \(Store.folder.lastPathComponent): \(url.absoluteString) — launching the \(target.name) world")
            launch(target)
        } else {
            Updates.note("link relay in \(Store.folder.lastPathComponent): \(url.absoluteString) — the \(target.name) world is already on its way")
        }
        // An address queues on the far side until the window is up
        // (`Links.waiting`), so sending as soon as the lock is held is fine.
        whenRunning(target) { pid in send(url, to: pid, activate: target.environment == nil) }
        return true
    }

    /// The main world's pid when it is running — the lock's holder, or, for
    /// a Copper from before the lock existed, the instance with no probe in
    /// its environment.
    @MainActor private static func runningMain(_ target: Target) -> pid_t? {
        isRunning(worldFolder: target.folder) ?? (target.environment == nil ? unlockedMainInstance() : nil)
    }

    /// The address as a `GetURL` Apple Event to exactly that process — what
    /// LaunchServices itself sends, aimed by hand.
    @MainActor private static func send(_ url: URL, to pid: pid_t, activate: Bool) {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: AEKeyword(keyDirectObject))
        do {
            _ = try event.sendEvent(options: [.noReply], timeout: 5)
        } catch {
            Updates.note("link relay: sending to pid \(pid) failed: \(error.localizedDescription)")
            return
        }
        if activate { handFocus(to: pid) }
    }
}
