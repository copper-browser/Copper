import AppKit
import WebKit

// Keeping a shared tab painting while you look at another one.
//
// Copper's stage holds only the tab you are on; every other tab's web view has
// no window, and WebKit treats a page with no window as a background tab — no
// painting, no requestAnimationFrame, `document.hidden`. A shared tab has to
// keep moving on the far end of the call while you are back on it, so while a
// share is live its view is hung in one borderless panel outside every
// display, ordered in, with WebKit's occlusion detection off for it (the trick
// Fork/Headless.swift and Fork/MCP/Backstage.swift use): to WebKit the page is
// visible and paints at full rate. Choosing the tab takes its view back to
// your stage the ordinary way (StageView takes what it is told to show);
// leaving it brings it back here on the capture's next tick.
//
// Occlusion detection stays off wherever the view is while it is shared, so a
// Copper window behind another app — you went to your notes mid-presentation
// — still gives the call a moving picture. It is put back when the share ends.
//
// Unlike Backstage's window this one never says it is key: the page is a
// background window's page, visible and unfocused, as in any browser.
@MainActor
enum TabShareStage {
    final class Window: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private static var window: Window?
    /// The views hung here, by tab.
    private static var hung: [Tab.ID: ObjectIdentifier] = [:]
    /// The pages this told to ignore occlusion, by tab — only those it
    /// changed, so it never turns detection back on for a page something
    /// else (headless mode, a warmed space, an agent) had turned off.
    private static var ignoring = Set<Tab.ID>()
    /// The size each kept tab last had on a stage, so hanging it here never
    /// lays the page out again at another width.
    private static var sizes: [Tab.ID: NSSize] = [:]

    static var hungCount: Int { hung.count }
    static func isHung(_ id: Tab.ID) -> Bool { hung[id] != nil }

    /// Where a shared tab's view should be, now: on a stage it stays; with no
    /// window it is hung here. Called on every capture tick.
    static func keep(_ tab: Tab, fallback: NSSize? = nil) {
        guard let web = tab.built else { return }
        // Before it joins a window: WebKit works out the page's visibility
        // as the view arrives. And on every tick after, not just the first:
        // whatever else had it off and lets go — an agent's hold ending
        // (Backstage.unhang), a page leaving the Room (SpaceWarm's Room.moved)
        // — turns detection back on, and a page hung off every display with
        // detection on is hidden: no painting, the call's picture frozen.
        if web.headlessIgnoresOcclusion == false {
            Backstage.ignoreOcclusion(web, true)
            ignoring.insert(tab.id)
        }
        if let window = web.window {
            if window === self.window {
                let size = sizes[tab.id] ?? fallback ?? stageSize
                if web.frame.size != size { web.frame = NSRect(origin: .zero, size: size) }
                fit()
            } else {
                // On a stage (or the floating window, or Backstage's): its size
                // there is the one to keep.
                if hung[tab.id] != nil { hung[tab.id] = nil }
                if web.bounds.width > 200, web.bounds.height > 200 { sizes[tab.id] = web.bounds.size }
            }
            return
        }
        // A tab some window has just been told to show is its stage's to take:
        // hung here between the selection and the stage's next pass, the page
        // would wait here while the stage stood empty.
        if Windows.all.contains(where: { $0.activeID == tab.id }) || Split.shared.has(tab.id) { return }
        guard !tab.floating else { return }
        let size = sizes[tab.id] ?? fallback ?? stageSize
        sizes[tab.id] = size
        let window = ensureWindow()
        guard let content = window.contentView else { return }
        web.frame = NSRect(origin: .zero, size: size)
        web.isHidden = false
        web.alphaValue = 1
        content.addSubview(web)
        web.needsLayout = true
        web.needsDisplay = true
        hung[tab.id] = ObjectIdentifier(web)
        fit()
    }

    /// The share is over: out of this window, and back to noticing occlusion
    /// unless someone else still needs it off.
    static func release(_ tab: Tab) {
        let id = tab.id
        defer {
            hung[id] = nil
            ignoring.remove(id)
            sizes[id] = nil
            idleIfEmpty()
        }
        guard let web = tab.built else { return }
        if hung[id] != nil, web.window === window { web.removeFromSuperview() }
        if ignoring.contains(id), !othersKeepSeen(web, tab: id) { Backstage.ignoreOcclusion(web, false) }
    }

    /// Someone else has the page ignoring occlusion too, and keeps the say
    /// over it when the share ends: an agent's hold (Backstage), the Room a
    /// launch or a space warm-up hung it in (SpaceWarm — it turns detection
    /// back on itself as the view leaves), headless mode (Backstage refuses
    /// to turn it on there). Merging fix/page-mic adds its call pages here:
    /// `|| CaptureCalls.shared.keeps(web)`.
    private static func othersKeepSeen(_ web: WKWebView, tab id: Tab.ID) -> Bool {
        Backstage.shared.holds(id) || web.window is Room.Panel
    }

    /// A tab that is gone: forget it without touching a view.
    static func forget(_ id: Tab.ID) {
        hung[id] = nil
        ignoring.remove(id)
        sizes[id] = nil
        if let content = window?.contentView {
            let wanted = Set(hung.values)
            for view in content.subviews where !wanted.contains(ObjectIdentifier(view)) { view.removeFromSuperview() }
        }
        idleIfEmpty()
    }

    private static func idleIfEmpty() {
        guard hung.isEmpty else { return }
        window?.orderOut(nil)
    }

    /// The size a page would have on your stage: the page in front, else a
    /// laptop's worth.
    static var stageSize: NSSize {
        for browser in [Windows.current] + Windows.all {
            if let web = browser.active?.built, let window = web.window, !(window is Window), !(window is Backstage.Window),
               web.bounds.width > 200, web.bounds.height > 200 { return web.bounds.size }
        }
        return NSSize(width: 1280, height: 800)
    }

    private static func ensureWindow() -> Window {
        if let window {
            if !window.isVisible { window.orderBack(nil) }
            return window
        }
        let size = stageSize
        let window = Window(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        // A panel hides when its app stops being active; this one never does,
        // or a shared tab would freeze the moment you went to another app.
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenNone]
        window.title = "Copper shared tab"
        window.contentView = NSView(frame: NSRect(origin: .zero, size: size))
        window.setFrameOrigin(Parking.origin(for: size))
        // Ordered in without being brought forward: your windows keep their
        // order and an inactive app stays inactive.
        window.orderBack(nil)
        self.window = window
        return window
    }

    /// As big as the largest page hung here, and off every display.
    private static func fit() {
        guard let window, let content = window.contentView else { return }
        let size = content.subviews.reduce(NSSize(width: 200, height: 200)) {
            NSSize(width: max($0.width, $1.frame.width), height: max($0.height, $1.frame.height))
        }
        if content.bounds.size != size { window.setContentSize(size) }
        if Parking.intersectsAScreen(window.frame) || window.frame.origin != Parking.origin(for: window.frame.size) {
            window.setFrameOrigin(Parking.origin(for: window.frame.size))
        }
    }

    static var report: [String: Any] {
        ["hung": hung.count, "ignoringOcclusion": ignoring.count,
         "window": window.map { NSStringFromRect($0.frame) } ?? "none", "visible": window?.isVisible ?? false]
    }
}
