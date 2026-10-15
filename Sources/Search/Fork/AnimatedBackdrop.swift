import SwiftUI
import WebKit

// A living backdrop for the column: a three.js scene drawn in the theme's
// colours. The scene itself is Backdrop/scene.js — a noise-displaced plane
// in perspective, Stripe's hero technique — and this file is the frame it
// hangs in: one non-interactive WKWebView per backdrop, kept for as long as
// the view is on screen and fed new colours through evaluateJavaScript
// rather than reloaded, and told to stop drawing whenever nobody can see it.
//
// The column's own ground (`ThemeBackdrop` with `live`) keeps its one web
// view for as long as any space is animated, through switches, swipes and
// still spaces in between: a still space hides it (which pauses it), an
// animated one is sent its look with a short fade, and a swipe mixes the
// arriving space in by the fingers. Before, a still space in between tore
// the page down — a new WebContent process and a scene starting again from
// nothing — and every swipe towards an animated space started a second one
// for the curtain, that rarely finished loading before the fingers lifted.
//
// The still gradient the theme would otherwise draw sits underneath: it is
// what shows while the page loads, and all there is if the scene files are
// missing or WebGL is refused.

struct AnimatedBackdrop: View {
    /// The scenes on offer, by the name `SpaceTheme.Motion.style` stores.
    static let styles: [(id: String, name: String)] = [
        ("ribbons", "Ribbons"), ("silk", "Silk"), ("aurora", "Aurora"), ("waves", "Waves"),
    ]

    let style: String
    /// The column colours (already `SpaceTheme.ground`-ed) the scene paints with.
    let colors: [Color]
    /// 0…2, 1 is the scene's own pace.
    let speed: Double
    /// 0…1, how soft the scene is drawn.
    let blur: Double
    let dark: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: colors.count > 1 ? colors : colors + colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            if BackdropScene.folder != nil {
                BackdropWeb.Host(drive: .init(look: BackdropScene.Look(
                    style: style, colors: colors.map(BackdropScene.hex), speed: speed, blur: blur, dark: dark)))
                    .allowsHitTesting(false)
            }
        }
    }
}

enum BackdropScene {
    /// Everything the page needs to draw, as one value so a SwiftUI update
    /// that changes nothing sends nothing.
    struct Look: Equatable {
        var style: String
        var colors: [String]
        var speed: Double
        var blur: Double
        var dark: Bool
        /// Which space this is the look of: the page keeps each space's
        /// clock offset by it, and a `set` of the same key is a retune (no
        /// fade) rather than a switch.
        var key: String = ""

        init(style: String, colors: [String], speed: Double, blur: Double, dark: Bool, key: String = "") {
            self.style = style
            self.colors = colors
            self.speed = speed
            self.blur = blur
            self.dark = dark
            self.key = key
        }

        /// A space's theme as the scene draws it, or nil for a still one.
        init?(theme: SpaceTheme, dark: Bool, key: String) {
            guard let motion = theme.motion else { return nil }
            self.init(style: motion.style, colors: theme.grounds(dark: dark).map(BackdropScene.hex),
                      speed: motion.speed, blur: theme.blur, dark: dark, key: key)
        }

        var json: String {
            let object: [String: Any] = ["style": style, "colors": colors, "speed": speed, "blur": blur, "dark": dark,
                                         "key": key, "epoch": BackdropScene.epoch]
            guard let data = try? JSONSerialization.data(withJSONObject: object),
                  let text = String(data: data, encoding: .utf8) else { return "{}" }
            return text
        }
    }

    /// What the column's web view is asked to show.
    struct Drive: Equatable {
        /// The space on screen, or nil when it is still and the scene has
        /// nothing to draw (the view is then hidden, and paused).
        var look: Look?
        /// While a swipe is on, the arriving space's look, if it has one,
        /// and how far the fingers have brought it in, 0…1.
        var toward: Look? = nil
        var x: Double = 0
        /// Seconds a change of `look` fades over.
        var fade: Double = 0
    }

    /// The scenes' common clock, in milliseconds since 1970: fixed once per
    /// launch, so every page — and the same page after a pause — counts
    /// from the same instant, and a space's scene is wherever it would have
    /// got to had it been drawing all along.
    static let epoch: Double = (Date().timeIntervalSince1970 * 1000).rounded()

    /// Where scene.html and three.js live. SwiftPM puts the target's
    /// resources in `Search_Search.bundle` beside the binary, which is what a
    /// bench run of `.build/release/Search` sees as its resource folder;
    /// build.sh copies the same bundle into Copper.app's Resources. Opened
    /// as a bundle rather than by path, because the toolchain decides
    /// whether the files sit at its root or under Contents/Resources. The
    /// bundle's root is tried too, not only its `resourceURL`: since Canvas
    /// copies a folder literally named `Resources` into the same bundle,
    /// NSBundle takes that folder for the resources and Backdrop is left
    /// beside it. Nil is a build without it, and the column stays still.
    static let folder: URL? = {
        let name = "Search_Search.bundle"
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0 }
        let folders = roots.flatMap { root -> [URL] in
            var found: [URL] = []
            let bundle = root.appendingPathComponent(name)
            if let inner = Bundle(url: bundle)?.resourceURL { found.append(inner.appendingPathComponent("Backdrop")) }
            found.append(bundle.appendingPathComponent("Backdrop"))
            found.append(root.appendingPathComponent("Backdrop"))
            return found
        }
        return folders.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("scene.html").path) }
    }()

    /// `#rrggbb` in sRGB, which is how the shaders want their colours.
    static func hex(_ color: Color) -> String {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        let byte = { (v: CGFloat) in Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }

    /// Bench runs never reach the screen — WebKit calls their windows
    /// occluded and stops requestAnimationFrame — so under test the scene
    /// keeps drawing on a timer and the pause rules that read the window are
    /// skipped. Reduce Motion and Low Power are honoured either way.
    static let forced = Store.testing
}

/// The web view behind an animated column. It draws nothing itself until the
/// page is up and the first look has been sent, and it holds one process for
/// its whole life: colours, speed, blur and appearance go over as a JSON
/// call, and a change of style swaps the shader without a reload.
final class BackdropWeb: WKWebView, WKNavigationDelegate {
    struct Host: NSViewRepresentable {
        let drive: BackdropScene.Drive

        func makeNSView(context: Context) -> BackdropWeb {
            let view = BackdropWeb()
            view.apply(drive)
            return view
        }

        // The same view, whatever SwiftUI redraws above it: a new WebContent
        // process for every colour tweak would be the one thing this must
        // never cost.
        func updateNSView(_ view: BackdropWeb, context: Context) {
            view.apply(drive)
        }
    }

    /// Every backdrop alive, for the bench.
    private static let alive = NSHashTable<BackdropWeb>.weakObjects()

    private var drive: BackdropScene.Drive?
    /// What the page was last `set` to, and what a swipe last mixed in.
    private var shown: BackdropScene.Look?
    private var scrubbed: BackdropScene.Look?
    private var loaded = false
    private var sent: String?
    private var observers: [NSObjectProtocol] = []
    private var occlusion: NSObjectProtocol?

    /// One throwaway store for every backdrop: the page keeps no state, and
    /// sharing one lets WebKit warm a second column's process from the first.
    private static let store = WKWebsiteDataStore.nonPersistent()

    private static func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        // Fork (perf): the page comes from `SceneFiles`, not a file URL. A file
        // URL has WebKit issue its content process a sandbox extension for the
        // folder, on the main thread, as that process finishes launching — and
        // on some days that one call took five to six seconds (MBX2, October
        // 2026: every launch of a session with an animated space froze that
        // long, the installed Copper included). Served from the app, the page
        // needs no extension, and its three files are one origin.
        config.setURLSchemeHandler(SceneFiles.shared, forURLScheme: SceneFiles.scheme)
        if BackdropScene.forced {
            // Under test the window is never visible, so WebKit would nap the
            // process and stretch its timers; the bench needs it at pace.
            config.preferences.inactiveSchedulingPolicy = .none
            if config.preferences.responds(to: NSSelectorFromString("_setHiddenPageDOMTimerThrottlingEnabled:")) {
                config.preferences.setValue(false, forKey: "hiddenPageDOMTimerThrottlingEnabled")
            }
        }
        return config
    }

    init() {
        super.init(frame: .zero, configuration: BackdropWeb.configuration())
        navigationDelegate = self
        // The gradient underneath shows until the first frame, and nothing
        // white flashes in between.
        setValue(false, forKey: "drawsBackground")
        underPageBackgroundColor = .clear
        allowsMagnification = false
        allowsBackForwardNavigationGestures = false
        if #available(macOS 13.3, *) { isInspectable = Store.testing }
        BackdropWeb.alive.add(self)
        guard BackdropScene.folder != nil, let page = URL(string: "\(SceneFiles.scheme)://scene/scene.html") else { return }
        load(URLRequest(url: page))
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, .NSProcessInfoPowerStateDidChange] {
            // Power-state changes arrive on a background queue.
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
    }

    // Nothing here is for the pointer: rows, doors and drags belong to the
    // SwiftUI column drawn over it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    func apply(_ drive: BackdropScene.Drive) {
        guard drive != self.drive else { return }
        let before = self.drive
        self.drive = drive
        // A still space has nothing for the scene to draw: hidden, which is
        // also paused (see `mode`), and kept for the next animated one.
        let target = drive.look ?? drive.toward
        if isHidden != (target == nil) { isHidden = target == nil }
        guard loaded, let target else { return }
        if let look = drive.look, let toward = drive.toward {
            if shown != look {
                call("set", look.json, "0")
                shown = look
            }
            call("toward", toward.json, String(format: "%.4f", min(1, max(0, drive.x))))
            scrubbed = toward
        } else if target != shown || scrubbed != nil {
            // A switch fades; so does the end of a swipe, from wherever the
            // fingers left the mix. Coming out of hiding does not — what was
            // last drawn is another space's, and nobody saw it go.
            let hidden = before.map { ($0.look ?? $0.toward) == nil } ?? true
            call("set", target.json, hidden || shown == nil ? "0" : String(format: "%.3f", drive.fade))
            shown = target
            scrubbed = nil
        }
        refresh()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        shown = nil
        scrubbed = nil
        if let drive {
            self.drive = nil
            apply(drive)
        }
        if BackdropScene.forced {
            call("force", "true")
            // So a bench can find the processes to weigh: the same private
            // selectors Heat reads, and just as optional.
            let pids = ["_webProcessIdentifier", "_gpuProcessIdentifier"].map { name -> String in
                guard responds(to: NSSelectorFromString(name)), let pid = value(forKey: name) as? NSNumber else { return "?" }
                return pid.stringValue
            }
            NSLog("AnimatedBackdrop: web process %@, gpu process %@", pids[0], pids[1])
        }
        sent = nil
        refresh()
    }

    // MARK: Pausing

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in self?.refresh() }
        }
        refresh()
    }

    override func viewDidHide() { super.viewDidHide(); refresh() }
    override func viewDidUnhide() { super.viewDidUnhide(); refresh() }

    /// What the page should be doing right now. `still` draws one frame and
    /// stops — the scene is there, it just doesn't move; `pause` draws
    /// nothing new, for a column nobody can see.
    private var mode: String {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled { return "still" }
        guard let window, !isHiddenOrHasHiddenAncestor else { return "pause" }
        if BackdropScene.forced { return "run" }
        guard window.occlusionState.contains(.visible), NSApp.isActive else { return "pause" }
        return "run"
    }

    private func refresh() {
        guard loaded else { return }
        let mode = mode
        guard mode != sent else { return }
        sent = mode
        call("mode", "'\(mode)'")
    }

    /// `window.backdrop.NAME(ARGS…)` — or, before the module has run, a note
    /// for it to pick up when it does.
    private func call(_ name: String, _ arguments: String...) {
        let list = arguments.joined(separator: ",")
        let js = "(function(){var b=window.backdrop;if(b){b.\(name)(\(list));}else{(window.__backdropPending=window.__backdropPending||[]).push(['\(name)',[\(list)]]);}})()"
        evaluateJavaScript(js) { _, error in
            if let error, Store.testing { NSLog("AnimatedBackdrop: %@", "\(error)") }
        }
    }

    // MARK: The bench

    /// `./bench backdrop`: every backdrop alive — its WebContent process,
    /// whether it is hidden, and the page's own `backdrop.status()` (the
    /// scene's clock, frames, the look it is on). The page answers
    /// asynchronously, so this waits for each.
    static func bench(answer: @escaping ([String: Any]) -> Void) {
        let views = alive.allObjects
        guard !views.isEmpty else { return answer(["backdrops": [], "epoch": BackdropScene.epoch]) }
        var rows: [[String: Any]] = Array(repeating: [:], count: views.count)
        var left = views.count
        for (i, view) in views.enumerated() {
            var row: [String: Any] = ["hidden": view.isHidden, "window": view.window != nil, "loaded": view.loaded,
                                      "mode": view.sent ?? "", "key": view.shown?.key ?? ""]
            if view.responds(to: NSSelectorFromString("_webProcessIdentifier")),
               let pid = view.value(forKey: "_webProcessIdentifier") as? NSNumber { row["pid"] = pid.intValue }
            view.evaluateJavaScript("window.backdrop ? JSON.stringify(window.backdrop.status()) : null") { result, error in
                if let text = result as? String, let data = text.data(using: .utf8),
                   let status = try? JSONSerialization.jsonObject(with: data) { row["status"] = status }
                if let error { row["error"] = "\(error)" }
                rows[i] = row
                left -= 1
                if left == 0 { answer(["backdrops": rows, "epoch": BackdropScene.epoch]) }
            }
        }
    }
}

/// The backdrop's page — scene.html, scene.js, three.js — handed to its web
/// view from the app's own bundle at `copper-scene://scene/…` (see
/// `BackdropWeb.configuration`). Nothing outside the Backdrop folder is served.
final class SceneFiles: NSObject, WKURLSchemeHandler {
    static let shared = SceneFiles()
    static let scheme = "copper-scene"

    private static let types = ["html": "text/html", "js": "text/javascript", "jpg": "image/jpeg",
                                "jpeg": "image/jpeg", "png": "image/png", "json": "application/json"]

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let folder = BackdropScene.folder?.standardizedFileURL else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        let file = folder.appendingPathComponent(url.path).standardizedFileURL
        guard file.path.hasPrefix(folder.path + "/"), let data = try? Data(contentsOf: file) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        let type = SceneFiles.types[file.pathExtension.lowercased()] ?? "application/octet-stream"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type, "Content-Length": String(data.count)])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
