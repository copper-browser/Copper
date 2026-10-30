import AppKit
import Combine
import Foundation
import ObjectiveC
import WebKit

// Headless Copper: `Copper --headless`, or SEARCH_HEADLESS=1.
//
// The same browser, run by a daemon on a Mac nobody is sitting at (a headless
// Mac mini): no Dock icon, no menu bar, no window anyone can see, and nothing
// that waits for a click. The loopback MCP server and the agent link run
// exactly as they do in the windowed app — they are the only way in.
//
// WebKit still has to lay pages out and paint them: Jev indexes elements by
// their geometry and agents take screenshots. So the browser keeps its one
// window, parked where no display is (SEARCH_HEADLESS_WINDOW=offscreen, the
// default) — ordered in, so AppKit keeps running layout and WebKit keeps the
// page "visible", but outside every screen's bounds. SEARCH_HEADLESS_WINDOW=
// hidden never orders it in at all; WebKit then treats the page as a
// background tab (no rAF, document.hidden), which is fine for reads but not
// what the tools were tuned against.
//
// Everything here is installed only when headless is on; the windowed app
// never runs a line of it. Upstream files are untouched: the window, the
// activation calls and the modal APIs are intercepted at the AppKit level
// (method swizzling), so every existing call site — Links, Browser,
// Extensions, Dialogs — is covered without a hook in each.

enum Headless {
    /// Asked for on the command line or in the environment. Read once.
    static let on: Bool = {
        if CommandLine.arguments.contains("--headless") { return true }
        let raw = (ProcessInfo.processInfo.environment["SEARCH_HEADLESS"] ?? "").lowercased()
        return ["1", "true", "yes", "on"].contains(raw)
    }()

    enum WindowMode: String { case offscreen, hidden }

    static let windowMode: WindowMode = {
        let raw = (ProcessInfo.processInfo.environment["SEARCH_HEADLESS_WINDOW"] ?? "").lowercased()
        return WindowMode(rawValue: raw) ?? .offscreen
    }()

    /// The window's size while parked: the page's viewport is this less the
    /// sidebar. SEARCH_HEADLESS_SIZE=WxH overrides; 1440×900 by default.
    static let size: NSSize = {
        let raw = ProcessInfo.processInfo.environment["SEARCH_HEADLESS_SIZE"] ?? ""
        let parts = raw.lowercased().split(separator: "x").compactMap { Double($0) }
        if parts.count == 2, parts[0] >= 320, parts[1] >= 240 { return NSSize(width: parts[0], height: parts[1]) }
        return NSSize(width: 1440, height: 900)
    }()

    /// agent.json said nothing about `enabled` / `jev` before this launch
    /// touched it. Headless has no Settings to turn them on from, so an
    /// unsaid switch defaults to on; an explicit `false` is respected.
    private(set) static var loopbackUnsaid = false
    private(set) static var jevUnsaid = false

    /// One line on stderr — launchd sends it to the daemon's log. Never a key.
    static func log(_ text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("\(stamp) copper[headless]: \(text)\n".utf8))
    }

    // MARK: - boot (SearchApp.init, before any window)

    private static var booted = false

    /// Called from `Bridge.runIfAsked`, after the CLI and stdio bridge have
    /// had their turn, so only a real app launch gets here.
    @MainActor static func bootIfAsked() {
        guard on, !booted else { return }
        booted = true
        // Before finishLaunching: the app never gets a Dock icon or the menu
        // bar, and AppKit never offers to reopen windows after a crash.
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["ApplePersistenceIgnoreState"] = true
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        NSApplication.shared.setActivationPolicy(.accessory)
        readAgentDefaults()
        Swizzles.install()
        keychainQuiet()
        // App Nap would throttle a process nobody looks at down to nothing;
        // this one is a server.
        awake = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Copper headless: serving agents"
        )
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { becameActive() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { for window in NSApp.windows { Parking.park(window) } }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { Parking.keepParked(window) }
        }
        // launchd stops a job with SIGTERM, whose default ends the process
        // on the spot; the session's last debounced write would go with it.
        // Taken as a normal quit instead, so Links flushes the session.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler {
            log("SIGTERM — quitting")
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        term.resume()
        terminate = term
        log("on — pid \(ProcessInfo.processInfo.processIdentifier), window \(windowMode.rawValue) \(Int(size.width))×\(Int(size.height)), data \(Store.folder.path)")
    }

    private static var awake: NSObjectProtocol?
    private static var terminate: DispatchSourceSignal?

    /// LaunchServices activated this process: a Dock click, a plain `open`
    /// or a link it routed here because this headless Copper shares the
    /// installed one's bundle id. On the way it promoted the process from
    /// accessory to an ordinary app ("changing application type to
    /// Foreground from UIElement"), which leaves a second Copper icon in
    /// the Dock and in ⌘-Tab for the rest of the run, and binds the Dock's
    /// Copper tile to this process, so every later click lands here too.
    /// The policy is taken back at once.
    ///
    /// The activation itself belongs to the main Copper the reopen or link
    /// is being handed to (Instance.swift `handFocus`): it can only be
    /// passed on while this process still holds it, so it is never thrown
    /// away while a hand-off is under way. Otherwise it goes straight back —
    /// after a moment, because the Apple Event that starts a hand-off can
    /// arrive just behind the activation that came with it.
    @MainActor private static func becameActive() {
        if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
            log("made a Dock app by the system — back to accessory")
        }
        if Instance.activationArrived() { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard NSApp.isActive, !Instance.handingOff else { return }
            log("activated by the system — deactivating")
            NSApp.deactivate()
        }
    }

    @MainActor private static func readAgentDefaults() {
        let object = (try? Data(contentsOf: MCP.file))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        loopbackUnsaid = object["enabled"] == nil
        jevUnsaid = object["jev"] == nil
    }

    /// No keychain prompt can be answered here; a read that would ask fails
    /// instead (errSecInteractionNotAllowed). Looked up at run time: the call
    /// is deprecated, and there is no replacement for a whole process.
    private static func keychainQuiet() {
        typealias Allow = @convention(c) (DarwinBoolean) -> OSStatus
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecKeychainSetUserInteractionAllowed") else { return }
        let allow = unsafeBitCast(symbol, to: Allow.self)
        _ = allow(false)
    }

    // MARK: - start (MCP.start, once the browser exists)

    private static var bag = Set<AnyCancellable>()

    /// The agent server's switches, before it first listens.
    @MainActor static func adoptDefaults(_ mcp: MCP) {
        guard on else { return }
        if loopbackUnsaid, !mcp.config.enabled {
            mcp.config.enabled = true
            log("agent server on (agent.json had no \"enabled\")")
        }
        if jevUnsaid, !mcp.config.jev {
            mcp.config.jev = true
            log("Jev mode on (agent.json had no \"jev\")")
        }
    }

    /// Nothing the browser would put in front of a person stays up.
    @MainActor static func start(for browser: Browser) {
        guard on else { return }
        // First-run welcome: not for a Mac nobody sits at.
        browser.$welcoming
            .removeDuplicates()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak browser] _ in
                MainActor.assumeIsolated {
                    browser?.welcoming = false
                    log("welcome panel suppressed")
                }
            }
            .store(in: &bag)
        // A page asking for the camera or microphone waits on an answer
        // nobody can give; it gets "no" at once, unless the site was already
        // allowed (Fork/Capture/CaptureDesk.swift `asked`, which logs it).
        for window in NSApp.windows { Parking.park(window) }
        log("browser ready — agent server \(MCP.shared.config.enabled ? "on" : "off") at \(MCP.shared.endpoint), Jev \(MCP.shared.config.jev ? "on" : "off"), \(AgentLinks.shared.all.filter { $0.config.enabled }.count) agent links on")
    }

    /// What `copper health` and /health say about the process.
    @MainActor static var health: [String: Any] {
        guard on else { return [:] }
        let webs = NSApp.windows.flatMap { WKWebView.all(in: $0.contentView) }
        return ["window": windowMode.rawValue,
                "windowsOnScreen": NSApp.windows.filter { $0.isVisible && Parking.intersectsAScreen($0.frame) }.count,
                "webViews": webs.count,
                "webViewsIgnoringOcclusion": webs.filter { $0.headlessIgnoresOcclusion == true }.count]
    }
}

// MARK: - the window, parked

@MainActor
enum Parking {
    private static var parked = Set<ObjectIdentifier>()

    /// Top-level windows only: a sheet or child window hangs off its parent
    /// and goes wherever the parent is.
    static func applies(to window: NSWindow) -> Bool {
        Headless.on && window.sheetParent == nil && window.parent == nil
    }

    static func isParked(_ window: NSWindow) -> Bool { parked.contains(ObjectIdentifier(window)) }

    static func intersectsAScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.frame.intersects(frame) }
    }

    /// Below and to the left of every display, with room to spare.
    static func origin(for size: NSSize) -> NSPoint {
        let all = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        return NSPoint(x: all.minX - size.width - 4000, y: all.minY - size.height - 4000)
    }

    static func park(_ window: NSWindow) {
        guard applies(to: window) else { return }
        let id = ObjectIdentifier(window)
        if !parked.contains(id) {
            parked.insert(id)
            window.isExcludedFromWindowsMenu = true
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.collectionBehavior.formUnion([.transient, .ignoresCycle, .fullScreenNone])
            window.setContentSize(Headless.size)
        }
        let target = origin(for: window.frame.size)
        if window.frame.origin != target { window.setFrameOrigin(target) }
        if debug { Headless.log("DEBUG park \(type(of: window)) now \(window.frame)") }
    }
    static let debug = ProcessInfo.processInfo.environment["SEARCH_HEADLESS_DEBUG"] != nil

    /// Something moved a parked window back where it could be seen — a
    /// restored frame, a screen change — so it goes back.
    static func keepParked(_ window: NSWindow) {
        guard isParked(window), intersectsAScreen(window.frame) else { return }
        DispatchQueue.main.async { park(window) }
    }
}

// MARK: - interception

private enum Swizzles {
    static func install() {
        // The window: parked before it is ever ordered in, and never ordered
        // in at all in hidden mode.
        exchange(NSWindow.self, #selector(NSWindow.makeKeyAndOrderFront(_:)), #selector(NSWindow.headless_makeKeyAndOrderFront(_:)))
        exchange(NSWindow.self, #selector(NSWindow.orderFront(_:)), #selector(NSWindow.headless_orderFront(_:)))
        exchange(NSWindow.self, #selector(NSWindow.orderFrontRegardless), #selector(NSWindow.headless_orderFrontRegardless))
        exchange(NSWindow.self, #selector(NSWindow.order(_:relativeTo:)), #selector(NSWindow.headless_order(_:relativeTo:)))
        exchange(NSWindow.self, #selector(NSWindow.constrainFrameRect(_:to:)), #selector(NSWindow.headless_constrainFrameRect(_:to:)))
        exchange(NSWindow.self, #selector(NSWindow.setFrameAutosaveName(_:)), #selector(NSWindow.headless_setFrameAutosaveName(_:)))
        // A window outside every display is "occluded", and WebKit treats an
        // occluded page as a background tab: no painting, no rAF, and — in
        // a shipped build — a WebContent process suspended after a while.
        // Each web view is told to ignore occlusion as it joins a window.
        exchange(WKWebView.self, #selector(NSView.viewDidMoveToWindow), #selector(WKWebView.headless_viewDidMoveToWindow))

        // Activation: never. There is nobody to hand focus to.
        let activateOld: @convention(block) (NSApplication, Bool) -> Void = { _, _ in
            Headless.log("NSApp.activate(ignoringOtherApps:) ignored")
        }
        replace(NSApplication.self, NSSelectorFromString("activateIgnoringOtherApps:"), imp_implementationWithBlock(activateOld))
        let activate: @convention(block) (NSApplication) -> Void = { _ in
            Headless.log("NSApp.activate() ignored")
        }
        replace(NSApplication.self, NSSelectorFromString("activate"), imp_implementationWithBlock(activate))

        // Modal questions: declined on the spot, and said in the log. `.abort`
        // is no button at all, which every caller here reads as "no" — the
        // confirm() is false, the certificate is not excused, the extension
        // gets no permission.
        let alertModal: @convention(block) (NSAlert) -> NSApplication.ModalResponse = { alert in
            Headless.log("declined alert: \(summary(alert))")
            return .abort
        }
        replace(NSAlert.self, #selector(NSAlert.runModal), imp_implementationWithBlock(alertModal))
        let alertSheet: @convention(block) (NSAlert, NSWindow?, (@convention(block) (NSApplication.ModalResponse) -> Void)?) -> Void = { alert, _, done in
            // A Settings page's own question, in a test run, waits for the
            // bench instead (X-13, Fork/SettingsControls.swift `TestConfirm`).
            if let done, MainActor.assumeIsolated({ TestConfirm.adopt(alert, done: { done($0) }) }) { return }
            Headless.log("declined alert sheet: \(summary(alert))")
            DispatchQueue.main.async { done?(.abort) }
        }
        replace(NSAlert.self, #selector(NSAlert.beginSheetModal(for:completionHandler:)), imp_implementationWithBlock(alertSheet))

        for panel in [NSOpenPanel.self, NSSavePanel.self] as [AnyClass] {
            let panelModal: @convention(block) (NSSavePanel) -> NSApplication.ModalResponse = { panel in
                Headless.log("cancelled \(type(of: panel))")
                return .cancel
            }
            replace(panel, #selector(NSSavePanel.runModal), imp_implementationWithBlock(panelModal))
            let panelSheet: @convention(block) (NSSavePanel, NSWindow, (@convention(block) (NSApplication.ModalResponse) -> Void)?) -> Void = { panel, _, done in
                Headless.log("cancelled \(type(of: panel)) sheet")
                DispatchQueue.main.async { done?(.cancel) }
            }
            replace(panel, #selector(NSSavePanel.beginSheetModal(for:completionHandler:)), imp_implementationWithBlock(panelSheet))
        }
        // Anything else that would spin a modal loop gets it ended at once.
        let modalFor: @convention(block) (NSApplication, NSWindow) -> NSApplication.ModalResponse = { _, window in
            Headless.log("refused modal session for \(type(of: window))")
            return .abort
        }
        replace(NSApplication.self, #selector(NSApplication.runModal(for:)), imp_implementationWithBlock(modalFor))
    }

    static func summary(_ alert: NSAlert) -> String {
        let text = [alert.messageText, alert.informativeText].filter { !$0.isEmpty }.joined(separator: " — ")
        return text.count > 160 ? String(text.prefix(160)) + "…" : text
    }

    private static func exchange(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let o = class_getInstanceMethod(cls, original), let r = class_getInstanceMethod(cls, replacement) else {
            Headless.log("could not intercept \(NSStringFromSelector(original))")
            return
        }
        // When the class only inherits `original`, give it its own copy
        // rather than swapping the superclass's — NSView's
        // viewDidMoveToWindow is every view's.
        if class_addMethod(cls, original, method_getImplementation(r), method_getTypeEncoding(r)) {
            class_replaceMethod(cls, replacement, method_getImplementation(o), method_getTypeEncoding(o))
        } else {
            method_exchangeImplementations(o, r)
        }
    }

    private static func replace(_ cls: AnyClass, _ selector: Selector, _ imp: IMP) {
        guard let method = class_getInstanceMethod(cls, selector) else {
            Headless.log("could not intercept \(NSStringFromSelector(selector))")
            return
        }
        class_replaceMethod(cls, selector, imp, method_getTypeEncoding(method))
    }
}

// After `exchange`, calling a headless_ method calls AppKit's original.
extension NSWindow {
    @objc fileprivate func headless_makeKeyAndOrderFront(_ sender: Any?) {
        guard Parking.applies(to: self) else { return headless_makeKeyAndOrderFront(sender) }
        Parking.park(self)
        if Headless.windowMode == .hidden { makeKey(); return }
        headless_makeKeyAndOrderFront(sender)
    }

    @objc fileprivate func headless_orderFront(_ sender: Any?) {
        guard Parking.applies(to: self) else { return headless_orderFront(sender) }
        Parking.park(self)
        if Headless.windowMode == .hidden { return }
        headless_orderFront(sender)
    }

    @objc fileprivate func headless_orderFrontRegardless() {
        guard Parking.applies(to: self) else { return headless_orderFrontRegardless() }
        Parking.park(self)
        if Headless.windowMode == .hidden { return }
        headless_orderFrontRegardless()
    }

    @objc fileprivate func headless_order(_ place: NSWindow.OrderingMode, relativeTo other: Int) {
        guard place != .out, Parking.applies(to: self) else { return headless_order(place, relativeTo: other) }
        Parking.park(self)
        if Headless.windowMode == .hidden { return }
        headless_order(place, relativeTo: other)
    }

    /// AppKit pulls a titled window back onto a screen when it is shown;
    /// a parked one stays where it was put.
    @objc fileprivate func headless_constrainFrameRect(_ frame: NSRect, to screen: NSScreen?) -> NSRect {
        if Parking.isParked(self) { return frame }
        return headless_constrainFrameRect(frame, to: screen)
    }

    /// A parked frame must never be saved as the place the windowed app
    /// comes back to — nor a saved one restore over the parking spot.
    @objc fileprivate func headless_setFrameAutosaveName(_ name: NSWindow.FrameAutosaveName) -> Bool {
        true
    }
}

extension WKWebView {
    private static let occlusionGetter = NSSelectorFromString("_windowOcclusionDetectionEnabled")
    private static let occlusionSetter = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")

    /// WebKit's own switch (WKWebViewPrivate), called directly: KVC would
    /// look for `set_windowOcclusionDetectionEnabled:` and throw.
    var headlessIgnoresOcclusion: Bool? {
        guard responds(to: WKWebView.occlusionGetter) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return !unsafeBitCast(method(for: WKWebView.occlusionGetter), to: Getter.self)(self, WKWebView.occlusionGetter)
    }

    @objc fileprivate func headless_viewDidMoveToWindow() {
        // Before WebKit's own handler, which is what works out whether the
        // page is visible in its new window.
        if let window, Headless.windowMode == .offscreen, headlessIgnoresOcclusion == false,
           responds(to: WKWebView.occlusionSetter) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(method(for: WKWebView.occlusionSetter), to: Setter.self)(self, WKWebView.occlusionSetter, false)
            if Parking.debug { Headless.log("DEBUG web view ignores occlusion in \(type(of: window)) at \(window.frame)") }
        }
        headless_viewDidMoveToWindow()
    }

    /// The web views in a view tree, and whether each ignores occlusion.
    @MainActor static func all(in view: NSView?) -> [WKWebView] {
        guard let view else { return [] }
        if let web = view as? WKWebView { return [web] }
        return view.subviews.flatMap { all(in: $0) }
    }
}
