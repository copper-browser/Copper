import AppKit
import SwiftUI
import WebKit

// What each window's stage is really showing, and a real hand on the Canvas
// door's rows — for the bench, so "I picked it and it isn't there" can be
// checked from the view tree rather than from a picture (a picture of a probe
// window can be a stale surface, and `bench window` used to lay the
// off-screen Backstage window over it).
//
//   ./bench stage                       every window: its active tab, what its
//                                       stage holds, where the active tab's view is
//   ./bench canvas ui click NAME [w=N] [post|window|view]
//                                       a real click on that canvas's row in the
//                                       door's card of window N (0 = first)
//   ./bench canvas stagecheck           test worlds: the door with two windows open,
//                                       and a canvas an agent is holding, picked by
//                                       you — each must end on your stage; prints failures

@MainActor
enum StageReport {
    /// Every StageView in a window, depth first.
    static func stages(in window: NSWindow?) -> [StageView] {
        guard let root = window?.contentView?.superview ?? window?.contentView else { return [] }
        var out: [StageView] = []
        var queue: [NSView] = [root]
        while let view = queue.popLast() {
            if let stage = view as? StageView { out.append(stage) }
            queue.append(contentsOf: view.subviews)
        }
        return out
    }

    /// The tab whose page a view is.
    static func tab(of view: NSView) -> Tab? { AgentTabs.all.first { $0.built === view } }

    static func kind(of window: NSWindow?) -> String {
        guard let window else { return "none" }
        if window is Backstage.Window { return "backstage" }
        if let owner = Windows.owner(of: window), let index = Windows.all.firstIndex(where: { $0 === owner }) { return "browser \(index)" }
        return "other (\(type(of: window)))"
    }

    /// Whether a tab's page is on `browser`'s stage, there to be seen.
    static func visible(_ tab: Tab, on browser: Browser) -> Bool {
        guard let web = tab.built, let window = web.window else { return false }
        return window === Windows.window(of: browser) && web.superview is StageView && web.alphaValue > 0.01
            && !web.isHiddenOrHasHiddenAncestor && web.bounds.width > 10 && web.bounds.height > 10
    }

    /// Where a tab's page is, and whether it can be seen on `browser`'s stage.
    static func describe(_ tab: Tab?, on browser: Browser) -> [String: Any] {
        guard let tab else { return ["tab": NSNull()] }
        var out: [String: Any] = ["tab": AgentTabs.short(tab), "url": (tab.pending ?? tab.address)?.absoluteString ?? "",
                                  "asleep": tab.asleep, "blank": tab.isBlank, "floating": tab.floating,
                                  "built": tab.built != nil, "held": Backstage.shared.holds(tab.id),
                                  "visible": visible(tab, on: browser),
                                  "covered": tab.cover != nil] // Fork (covers): its last picture is over the stage
        guard let web = tab.built else { return out }
        out["window"] = kind(of: web.window)
        out["superview"] = web.superview.map { "\(type(of: $0))" } ?? "none"
        out["alpha"] = Double(web.alphaValue)
        out["hidden"] = web.isHidden
        out["unpainted"] = web.unpainted
        out["frame"] = NSStringFromRect(web.frame)
        return out
    }

    static func report() -> [String: Any] {
        let windows: [[String: Any]] = Windows.all.enumerated().map { index, browser in
            let window = Windows.window(of: browser)
            let stages = stages(in: window).map { stage -> [String: Any] in
                ["holds": stage.subviews.map { view in tab(of: view).map(AgentTabs.short) ?? "\(type(of: view))" },
                 "frame": NSStringFromRect(stage.frame)]
            }
            return ["index": index, "number": window?.windowNumber ?? 0, "visible": window?.isVisible ?? false,
                    "key": window?.isKeyWindow ?? false, "space": Spaces.shared.space(in: browser).name,
                    "active": describe(browser.active, on: browser), "stages": stages,
                    "side": describe(Split.shared.holder === browser ? browser.tabs.first { $0.id == Split.shared.side } : nil, on: browser),
                    "tabs": browser.tabs.count, "taken": browser.taken.map { String($0.uuidString.prefix(8)).lowercased() } ?? ""]
        }
        return ["windows": windows, "backstage": Backstage.shared.report, "popovers": DoorHand.open]
    }
}

/// A real hand on the Canvas door's card: its rows' frames in the card, and
/// the card's place in its popover's window, per browser window.
@MainActor
enum DoorHand {
    static let space = "canvas-door-card"
    /// Each canvas row's frame in the card (top-left origin), as last laid out.
    static var rows: [String: CGRect] = [:]

    private final class Box { weak var view: NSView? }
    private static var roots: [ObjectIdentifier: Box] = [:]

    /// The card's root view in a window's door popover, while it is up.
    static func root(for browser: Browser) -> NSView? {
        guard let view = roots[ObjectIdentifier(browser)]?.view, let window = view.window, window.isVisible else { return nil }
        return view
    }

    /// How many door cards are on screen right now — one per window presenting it.
    static var open: Int { Windows.all.filter { root(for: $0) != nil }.count }

    struct Probe: NSViewRepresentable {
        let browser: Browser
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            DoorHand.keep(view, for: browser)
            return view
        }
        func updateNSView(_ view: NSView, context: Context) {
            if DoorHand.roots[ObjectIdentifier(browser)]?.view !== view { DoorHand.keep(view, for: browser) }
        }
    }

    private static func keep(_ view: NSView, for browser: Browser) {
        let box = Box()
        box.view = view
        roots[ObjectIdentifier(browser)] = box
    }

    /// A real click on `entry`'s row in `browser`'s door card.
    static func click(_ entry: Canvases.Entry, in browser: Browser) -> [String: Any] {
        guard let root = root(for: browser), let window = root.window else {
            return ["error": "the door's card is not open in that window", "popovers": open]
        }
        guard let frame = rows[entry.id] else { return ["error": "no row for \(entry.name) laid out"] }
        let card = root.convert(root.bounds, to: nil)
        let point = NSPoint(x: card.minX + frame.midX, y: card.maxY - frame.midY)
        var out = SideHand.tap(at: point, in: window)
        out["popovers"] = open
        out["canvas"] = entry.name
        return out
    }

    // MARK: - the check

    /// `canvas stagecheck` (test worlds): with two windows open, a press on
    /// the door shows one card, and a real click on a canvas with no tab makes
    /// its tab and puts it on that window's stage; then a canvas an agent is
    /// holding backstage — and an ordinary tab an agent is holding — picked
    /// by you, left and picked again, are on your stage each time.
    static func check(in browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "stagecheck runs in test worlds only"]); return }
        Task { @MainActor in
            var failures: [String] = []
            var notes: [String] = []
            func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
                let end = Date().addingTimeInterval(seconds)
                while Date() < end {
                    if done() { return true }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                return done()
            }
            let ui = CanvasUI.shared
            ui.popoverOpen = false
            var madeWindow = false
            if Windows.all.count < 2 {
                Windows.newWindow()
                madeWindow = await until(5) { Windows.all.count >= 2 && Windows.all.allSatisfy { Windows.window(of: $0) != nil } }
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            let home = Windows.all[0]
            if Windows.all.count < 2 { failures.append("could not open a second window") }

            // 1. The door, with two windows open: one card, and a real click
            // on a canvas with no tab opens it here, on the stage.
            let entry = Canvases.shared.createLocal(named: "Stage check \(Int(Date().timeIntervalSince1970) % 100_000)")
            ui.toggleDoor(in: home)
            if !(await until(4) { root(for: home) != nil && rows[entry.id] != nil }) {
                failures.append("the door's card never came up in window 0 (cards up: \(open))")
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            notes.append("door cards up for one press: \(open)")
            if open != 1 { failures.append("one press on window 0's door put up \(open) cards (want 1)") }
            SideHand.how = "post"
            let clicked = click(entry, in: home)
            if let error = clicked["error"] { failures.append("door click: \(error)") }
            let opened = await until(6) {
                guard let tab = CanvasTabs.tab(showing: entry.id) else { return false }
                return home.activeID == tab.id && StageReport.visible(tab, on: home)
            }
            let tab = CanvasTabs.tab(showing: entry.id)
            if !opened {
                failures.append(tab == nil
                    ? "a real click on the door's row made no tab (the card closed and nothing opened)"
                    : "the door's canvas tab is not on window 0's stage: \(StageReport.describe(tab, on: home))")
            }
            if ui.popoverOpen { failures.append("the door's card stayed open after the click") }
            ui.popoverOpen = false

            // 2. An agent holds the canvas backstage; you pick it, leave it, pick it again.
            if let tab {
                let other = home.open(URL(string: "data:text/html,<title>Stage%20check</title><h1>stage%20check</h1>")!, foreground: true)
                _ = await until(3) { !other.loading && StageReport.visible(other, on: home) }
                do { _ = try await CanvasTools.open(entry, in: home, foreground: false) } catch {
                    failures.append("canvas tool open: \((error as? CanvasTools.Failure)?.text ?? "\(error)")")
                }
                _ = await until(2) { tab.built?.window is Backstage.Window }
                notes.append("held canvas, off stage: \(StageReport.kind(of: tab.built?.window))")
                for round in 1...2 {
                    home.select(tab)
                    if !(await until(3) { StageReport.visible(tab, on: home) }) {
                        failures.append("round \(round): the held canvas, picked, is not on the stage: \(StageReport.describe(tab, on: home))")
                    }
                    // Stays shown past the hold's sweep (0.5 s).
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    if !StageReport.visible(tab, on: home) {
                        failures.append("round \(round): the held canvas left the stage while picked: \(StageReport.describe(tab, on: home))")
                    }
                    home.select(other)
                    _ = await until(3) { StageReport.visible(other, on: home) }
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    notes.append("round \(round), left: canvas \(StageReport.kind(of: tab.built?.window))")
                }

                // 3. An ordinary tab an agent is holding backstage, picked by you.
                home.select(tab)
                _ = await until(3) { StageReport.visible(tab, on: home) }
                AgentTabs.prepare(other)
                _ = await until(2) { other.built?.window is Backstage.Window }
                notes.append("held page, off stage: \(StageReport.kind(of: other.built?.window))")
                home.select(other)
                if !(await until(3) { StageReport.visible(other, on: home) }) {
                    failures.append("the held page, picked, is not on the stage: \(StageReport.describe(other, on: home))")
                }
                Backstage.shared.release(other.id)
                Backstage.shared.release(tab.id)
                home.close(other)
                Sections.shared.closeForGood(tab, in: CanvasTabs.owner(of: tab))
            }
            try? await Canvases.shared.delete(entry.id)
            if madeWindow, let extra = Windows.all.last, extra !== home { Windows.window(of: extra)?.performClose(nil) }
            answer(["ok": failures.isEmpty, "failures": failures, "notes": notes, "windows": Windows.all.count])
        }
    }
}
