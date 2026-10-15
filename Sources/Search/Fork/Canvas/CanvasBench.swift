import AppKit
import SwiftUI
import WebKit

// `./bench canvas …` for a canvas's tab, its row and its board, beside the
// tool verbs in CanvasTools.bench (list, open, read, apply, create, invites,
// accept, decline, rename, delete, leave, members, hosts, ui), which hands
// everything it doesn't know here. These can answer later — from the page or
// from a menu — so every one takes `answer`.
//
//   canvas new                  a canvas made and opened the way ⌘K's New Canvas does
//   canvas tabs [ID]            every canvas tab: its space, its block, its row, asleep, lean
//   canvas menu [press]         File › New Canvas as the menu bar holds it (press chooses it)
//   canvas flush ID             the canvas's page writes its whole document now (a checkpoint)
//   canvas click X Y [N] · draw X,Y X,Y …
//                               real mouse input on the board in front, in its CSS px
//   canvas scroll DX DY [STEPS] [--zoom] [--app] · scroll stats
//       a two-finger gesture on the board in front, as a trackpad sends it:
//       phase began, STEPS × changed (30 by default) carrying DX, DY points
//       between them, ended — continuous pixel deltas, ~8 ms apart. --zoom
//       holds ⌘ (the board zooms on ⌘/ctrl-wheel); --app sends each event
//       through NSApp.sendEvent, the way the window gets a real one, so the
//       app's own monitors (the space swipe) see it too. Answers at once;
//       `scroll stats` is the last gesture's numbers.
//   canvas perf start | stop    rAF frame times on the board in front, and wheel lag
//   canvas lean                 what the board in front was spared (CanvasLean.swift)
//   canvas frames [ID]          live web frames: the reports the host passed on, the embedding
//                               preference and the board's cookie store (CanvasFrames.swift)
//   canvas ask-rename ID · ask-delete ID · answer delete|leave|cancel · sheet
//                               the row's Rename Canvas… (the field on the row, or the
//                               sheet) and Delete Canvas… sheet, and its buttons
//   canvas rowmenu ID PATH      right-click the canvas's row; the window with its menu, as a PNG
//   canvas picture PATH         the window with whatever hangs from it (rename popover, sheet)
//   canvas import [status|run]  the easel migration (CanvasImport.swift)
//   canvas checklist [SHAPE] · check SHAPE COL ROW…
//                               the checklist shape: read it, or click a box (CanvasChecklistBench.swift)

extension CanvasTools {
    @MainActor
    static func benchTabs(_ request: [String: Any], in browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        let op = request["op"] as? String ?? "tabs"
        let raw = (request["arg"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let words = raw.split(separator: " ").map(String.init)
        func entry(_ key: String?) -> Canvases.Entry? {
            guard let key, !key.isEmpty else { return nil }
            return Canvases.shared.find(key) ?? Canvases.shared.all.first { $0.id.hasPrefix(key.lowercased()) }
        }
        switch op {
        case "new":
            CanvasTabs.newCanvas(in: browser)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let id = browser.active.flatMap(CanvasTabs.showing), let made = Canvases.shared.entry(id) else {
                    return answer(["error": "no canvas in front"])
                }
                answer(CanvasBench.describe(made, in: browser))
            }
        case "tabs":
            let list = entry(words.first).map { [$0] } ?? Canvases.shared.visible
            answer(["canvases": list.map { CanvasBench.describe($0, in: browser) }, "lean": CanvasHost.lean])
        case "menu":
            answer(CanvasBench.menu(press: words.first == "press"))
        case "flush":
            guard let target = entry(words.first) else { return answer(["error": "canvas flush ID"]) }
            let hosts = CanvasHost.hosts(of: target.id).filter(\.isReady)
            Task { @MainActor in
                for host in hosts { await host.checkpoint() }
                answer(["flushed": hosts.count, "store": hosts.first?.store.describe ?? [:]])
            }
        case "click", "draw":
            answer(CanvasBench.input(op, words, in: browser))
        case "scroll":
            answer(words.first == "stats" ? CanvasBench.lastScroll : CanvasBench.scroll(words, in: browser))
        case "perf":
            CanvasBench.perf(words.first ?? "", in: browser, answer: answer)
        case "lean":
            CanvasBench.lean(in: browser, answer: answer)
        case "frames":
            // Live web frames on the board in front (or ID's): what the host
            // has heard from them, and whether refusing sites may load.
            let id = entry(words.first)?.id ?? CanvasHost.active(in: browser)
            guard let id, let host = CanvasHost.hosts(of: id).first(where: \.isReady), let web = host.tab?.built else {
                return answer(["error": "canvas frames [ID] — a canvas that is up"])
            }
            answer(["canvas": id, "board": web.board, "embedding": CanvasHost.embeddingAllowed(web).map { $0 as Any } ?? NSNull(),
                    "store": web.configuration.websiteDataStore.identifier?.uuidString ?? (web.configuration.websiteDataStore.isPersistent ? "default" : "ephemeral"),
                    "events": host.frameEvents])
        case "ask-rename":
            guard let target = entry(words.first),
                  let tab = CanvasTabs.tabs(showing: target.id).first(where: { t in browser.tabs.contains { $0 === t } })
            else { return answer(["error": "canvas ask-rename ID — a canvas with a tab in this row"]) }
            let row = CanvasRenaming.shared.rows[tab.id] != nil && tab.pin == nil
            CanvasRenaming.shared.ask(tab, in: browser)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                answer(["asked": target.id, "field": row ? "row" : "sheet", "open": CanvasRenaming.shared.target == tab.id || CanvasRenameSheet.asking != nil])
            }
        case "ask-delete":
            guard let target = entry(words.first) else { return answer(["error": "canvas ask-delete ID"]) }
            CanvasDelete.ask(target.id, in: browser)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { answer(CanvasDelete.describe) }
        case "answer":
            // `answer rename NAME` / `answer cancel` for the row's name field
            // or the rename sheet, whichever is up; `answer delete|leave|cancel`
            // for the delete sheet.
            let choice = words.first ?? "cancel"
            let name = words.dropFirst().joined(separator: " ")
            let pressed: Bool
            if let target = CanvasRenaming.shared.target, choice == "rename" || choice == "cancel" {
                if choice == "rename", let tab = browser.tabs.first(where: { $0.id == target }), let id = CanvasTabs.showing(tab) {
                    CanvasRowActions.rename(id, to: name, in: browser)
                }
                CanvasRenaming.shared.target = nil
                pressed = true
            } else if CanvasRenameSheet.asking != nil, choice == "rename" || choice == "cancel" {
                pressed = CanvasRenameSheet.answer(choice, name: name)
            } else {
                pressed = CanvasDelete.answer(choice)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                answer(["pressed": pressed, "last": CanvasDelete.describe["last"] ?? "", "canvases": Canvases.shared.visible.count])
            }
        case "sheet":
            answer(CanvasDelete.describe)
        case "rowmenu":
            CanvasBench.rowMenu(words, in: browser, answer: answer)
        case "picture":
            // The window with whatever hangs from it — the rename field's
            // popover, the delete sheet — each drawn by its own views.
            guard let path = words.first, let window = Windows.window(of: browser) ?? Links.window else {
                return answer(["error": "canvas picture PATH"])
            }
            var extras = NSApp.windows.filter { $0 !== window && $0.isVisible && ($0.sheetParent === window || $0.className.contains("Popover")) }
            // A sheet held open for the bench (CanvasSheets) is drawn where it would hang.
            for held in [CanvasDelete.asking, CanvasRenameSheet.asking].compactMap({ $0 }) where !held.window.isVisible {
                held.layout()
                extras.append(held.window)
            }
            let anchor = CanvasRenaming.shared.target.flatMap { CanvasRenaming.shared.rows[$0] }
            guard let image = CanvasBench.composite(window, with: extras, anchor: anchor) else { return answer(["error": "no image"]) }
            answer(["path": CanvasBench.write(image, to: path) ? path : "", "size": [image.width, image.height], "extras": extras.map(\.className)])
        case "import":
            CanvasImport.bench(words.first ?? "status", answer: answer)
        case "checklist", "check", "assign", "picker":
            CanvasChecklistBench.run(op, words, in: browser, answer: answer)
        default:
            answer(["error": "canvas list|open ID|read [ID]|apply JSON|create NAME|invites|accept|decline INVITE|rename ID NAME|delete ID|leave ID"
                + "|members ID|hosts|ui open|close|mode …|picture PATH [dark]|new|tabs [ID]|menu [press]|flush ID|click X Y [N]|draw X,Y …"
                + "|scroll DX DY [STEPS] [--zoom] [--app]|scroll stats|perf start|stop|lean|ask-rename ID|ask-delete ID"
                + "|answer delete|leave|cancel|sheet|rowmenu ID PATH|picture PATH|import [status|run]"
                + "|checklist [SHAPE]|check SHAPE COL ROW…|assign SHAPE ROW…|picker"])
        }
    }
}

@MainActor
enum CanvasBench {
    /// One canvas, with every tab holding it: where its row is (its space,
    /// its block, its place in the row), asleep or not, lean or not.
    static func describe(_ entry: Canvases.Entry, in browser: Browser) -> [String: Any] {
        let tabs = CanvasTabs.tabs(showing: entry.id).map { tab -> [String: Any] in
            let owner = Windows.all.first { $0.tabs.contains { $0 === tab } }
            let space = Spaces.shared.spaceID(of: tab).flatMap { id in Spaces.shared.all.first { $0.id == id } }
            let row = (owner?.tabs ?? space.map { Spaces.shared.row($0.id) } ?? []).filter { $0.pin == nil }
            return ["tab": Bench.short(tab), "title": tab.title, "asleep": tab.asleep, "active": tab.id == browser.activeID,
                    "window": owner.flatMap { o in Windows.all.firstIndex { $0 === o } } ?? -1,
                    "space": space?.name ?? "", "pinned": tab.pin != nil,
                    "section": tab.pin != nil ? "favourites" : Sections.shared.isSaved(tab) ? "saved" : "today",
                    "row": row.firstIndex { $0 === tab } ?? -1,
                    "savedCount": row.filter { Sections.shared.isSaved($0) }.count,
                    "lean": tab.built?.board ?? false, "mark": tab.icon === CanvasPage.icon,
                    "pill": tab.address.flatMap(CanvasLinks.label) ?? ""]
        }
        return ["id": entry.id, "name": entry.name, "kind": entry.kind.rawValue,
                "url": CanvasLinks.url(entry.id).absoluteString, "tabs": tabs]
    }

    /// File › New Canvas as AppKit holds it; `press` chooses it, the way a
    /// click on the menu does.
    static func menu(press: Bool) -> [String: Any] {
        guard let file = NSApp.mainMenu?.items.first(where: { $0.submenu?.items.contains { $0.title == "New Canvas" } == true })?.submenu,
              let index = file.items.firstIndex(where: { $0.title == "New Canvas" })
        else {
            let bar = (NSApp.mainMenu?.items ?? []).map { item in
                item.title + ": " + (item.submenu?.items.map(\.title).joined(separator: ", ") ?? "")
            }
            return ["error": "no New Canvas in the menu bar", "menus": bar]
        }
        let item = file.items[index]
        let flags = item.keyEquivalentModifierMask
        let keys = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let shortcut = keys.filter { flags.contains($0.0) }.map(\.1).joined() + item.keyEquivalent.uppercased()
        if press { file.performActionForItem(at: index) }
        return ["menu": file.title, "item": item.title, "shortcut": shortcut, "enabled": item.isEnabled,
                "pressed": press, "canvases": Canvases.shared.visible.count]
    }

    /// The board in front, with a view that can take events.
    private static func front(_ browser: Browser) -> (Tab, PageView)? {
        guard let tab = browser.tabs.first(where: { $0.id == browser.activeID }), CanvasTabs.showing(tab) != nil,
              let web = tab.built, Input.canPost(to: web)
        else { return nil }
        return (tab, web)
    }

    // MARK: - the mouse

    /// `click X Y [COUNT]`, or `draw X,Y X,Y …` — one press, a drag through
    /// every point a frame apart, and a release. The board's gestures only
    /// believe trusted events, so a script's PointerEvent would prove nothing.
    static func input(_ op: String, _ words: [String], in browser: Browser) -> [String: Any] {
        guard let (_, web) = front(browser) else { return ["error": "the tab in front is not a canvas"] }
        if op == "click" {
            guard words.count >= 2, let x = Double(words[0]), let y = Double(words[1]) else { return ["error": "canvas click X Y [COUNT]"] }
            Input.click(web, at: CGPoint(x: x, y: y), button: "left", count: words.count > 2 ? Int(words[2]) ?? 1 : 1, modifiers: [])
            return ["clicked": [x, y]]
        }
        let points = words.compactMap { word -> CGPoint? in
            let xy = word.split(separator: ",").compactMap { Double($0) }
            return xy.count == 2 ? CGPoint(x: xy[0], y: xy[1]) : nil
        }
        guard points.count >= 2 else { return ["error": "canvas draw X,Y X,Y …"] }
        Task { @MainActor in await stroke(web, through: points) }
        return ["drawing": points.count, "ms": points.count * 16]
    }

    /// A press, a drag through `points` at about 60 Hz, and a release, as the
    /// window would deliver them. Points are the page's CSS px, top-left.
    private static func stroke(_ web: WKWebView, through points: [CGPoint]) async {
        guard let window = web.window, let first = points.first, let last = points.last else { return }
        if window.firstResponder !== web { window.makeFirstResponder(web) }
        func at(_ p: CGPoint) -> CGPoint { web.convert(web.isFlipped ? p : CGPoint(x: p.x, y: web.bounds.height - p.y), to: nil) }
        func post(_ type: NSEvent.EventType, _ p: CGPoint, pressure: Swift.Float) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: at(p), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: pressure)
        }
        Input.move(web, to: first)
        if let e = post(.leftMouseDown, first, pressure: 1) { web.mouseDown(with: e) }
        for p in points.dropFirst() {
            try? await Task.sleep(nanoseconds: 16_000_000)
            if let e = post(.leftMouseDragged, p, pressure: 1) { web.mouseDragged(with: e) }
        }
        if let e = post(.leftMouseUp, last, pressure: 0) { web.mouseUp(with: e) }
    }

    // MARK: - two fingers

    fileprivate static var lastScroll: [String: Any] = ["error": "no scroll yet"]

    static func scroll(_ words: [String], in browser: Browser) -> [String: Any] {
        let numbers = words.compactMap(Double.init)
        guard numbers.count >= 2 else { return ["error": "canvas scroll DX DY [STEPS] [--zoom] [--app]"] }
        guard let (_, web) = front(browser) else { return ["error": "the tab in front is not a canvas"] }
        let steps = max(1, min(2000, numbers.count > 2 ? Int(numbers[2]) : 30))
        let zoom = words.contains("--zoom"), app = words.contains("--app")
        lastScroll = ["running": true]
        CanvasWheelRun(web: web, dx: numbers[0], dy: numbers[1], steps: steps, zoom: zoom, app: app)?.start()
        return ["events": steps + 2, "ms": (steps + 2) * 8, "zoom": zoom, "app": app, "lean": web.board]
    }

    // MARK: - frames

    static func perf(_ what: String, in browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        guard let (_, web) = front(browser) else { return answer(["error": "the tab in front is not a canvas"]) }
        guard what == "start" || what == "stop" else { return answer(["error": "canvas perf start|stop"]) }
        if what == "start", !Headless.on, let window = web.window {
            // A window behind another one is not drawing — its display link
            // is stopped and rAF with it — so it comes forward, as for the
            // bench's pictures and its scripted space swipes.
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        web.evaluateJavaScript(what == "start" ? perfStart : perfStop) { value, error in
            MainActor.assumeIsolated {
                if let error { return answer(["error": error.localizedDescription]) }
                guard let text = value as? String, let data = text.data(using: .utf8),
                      var out = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                else { return answer(["value": value.map { String(describing: $0) } ?? NSNull()]) }
                out["lean"] = web.board
                answer(out)
            }
        }
    }

    /// Every frame's distance from the last, and every wheel event's lag:
    /// the event's own timestamp (carried through WebKit) to the moment the
    /// page's first listener hears it.
    private static let perfStart = """
    (function () {
      var P = window.__copperPerf;
      if (P) { cancelAnimationFrame(P.raf); window.removeEventListener('wheel', P.onWheel, true); }
      P = window.__copperPerf = { deltas: [], last: null, raf: 0, began: performance.now(), lag: [] };
      function loop(t) { if (P.last !== null) P.deltas.push(t - P.last); P.last = t; P.raf = requestAnimationFrame(loop); }
      P.raf = requestAnimationFrame(loop);
      P.onWheel = function (e) { P.lag.push(performance.now() - e.timeStamp); };
      window.addEventListener('wheel', P.onWheel, { passive: true, capture: true });
      return JSON.stringify({ started: true });
    })()
    """

    private static let perfStop = """
    (function () {
      var P = window.__copperPerf;
      if (!P) return JSON.stringify({ error: 'canvas perf start first' });
      cancelAnimationFrame(P.raf);
      window.removeEventListener('wheel', P.onWheel, true);
      window.__copperPerf = null;
      function pick(s, p) { return s.length ? s[Math.min(s.length - 1, Math.floor(p / 100 * s.length))] : 0; }
      function r(n) { return Math.round(n * 10) / 10; }
      var s = P.deltas.slice().sort(function (a, b) { return a - b; });
      var l = P.lag.slice().sort(function (a, b) { return a - b; });
      return JSON.stringify({
        frames: s.length, p50: r(pick(s, 50)), p95: r(pick(s, 95)), max: r(s[s.length - 1] || 0),
        over16: P.deltas.filter(function (d) { return d > 17.5; }).length,
        over33: P.deltas.filter(function (d) { return d > 34; }).length,
        ms: Math.round(performance.now() - P.began),
        // The event's clock and the page's differ by a constant, so lag is
        // read above the gesture's quickest event: how much later than its
        // best the board took each one.
        wheel: l.length, lagP50: r(pick(l, 50) - (l[0] || 0)), lagP95: r(pick(l, 95) - (l[0] || 0)),
        lagMax: r((l[l.length - 1] || 0) - (l[0] || 0))
      });
    })()
    """

    /// What the board in front carries of every page's machinery — and that
    /// its bridge still works: the page's API is there and its host is ready.
    static func lean(in browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        guard let (tab, web) = front(browser) else { return answer(["error": "the tab in front is not a canvas"]) }
        let controller = web.configuration.userContentController
        let scripts = controller.userScripts.count
        let js = """
        JSON.stringify({ swipe: !!window.__officeSwipe, forms: !!window.__officeForms, veil: !!window.__officeVeil,
          images: !!window.__officeImages, keys: !!window.__copperBoardKeys,
          calm: !!document.getElementById('office-calm'),
          canvas: !!(window.copperCanvas && typeof window.copperCanvas.init === 'function'),
          bridge: !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.canvas),
          scroll: !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(ScrollRelay.name)) })
        """
        web.evaluateJavaScript(js) { value, _ in
            MainActor.assumeIsolated {
                let page = (value as? String).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) }
                answer(["lean": CanvasHost.lean, "board": web.board, "magnifies": web.allowsMagnification, "userScripts": scripts,
                        "ready": CanvasHost.host(for: tab)?.isReady ?? false, "page": page ?? NSNull()])
            }
        }
    }

    // MARK: - pictures

    /// The browser window as the compositor has it, with `extras` (a popover,
    /// a sheet, a menu) each drawn by its own views where it sits on screen.
    /// WindowServer will not hand over those windows' pixels from a locked
    /// screen (nor, without the screen-recording grant, a popover's), but a
    /// window may always draw its own views.
    ///
    /// A headless window is parked off every screen, and AppKit keeps a
    /// popover on one: a popover that is nowhere near its window is laid
    /// beside `anchor` (window points, top left — the row it hangs from),
    /// where it would be on a window somebody could see.
    static func composite(_ window: NSWindow, with extras: [NSWindow], anchor: CGRect? = nil) -> CGImage? {
        guard let base = Fork.layered([CGWindowID(window.windowNumber)]) else { return nil }
        let scale = CGFloat(base.width) / max(1, window.frame.width)
        func spot(_ extra: NSWindow) -> NSRect {
            let size = extra.frame.size
            if !extra.className.contains("Popover") {
                // A sheet: AppKit's place for a real one; from the top of the
                // window, centred, for one held open for the bench.
                guard extra.sheetParent !== window else { return extra.frame }
                return NSRect(x: window.frame.midX - size.width / 2, y: window.frame.maxY - 28 - size.height, width: size.width, height: size.height)
            }
            guard !extra.frame.intersects(window.frame) else { return extra.frame }
            guard let anchor else {
                return NSRect(x: window.frame.midX - size.width / 2, y: window.frame.midY - size.height / 2, width: size.width, height: size.height)
            }
            return NSRect(x: window.frame.minX + anchor.maxX - 4, y: window.frame.maxY - anchor.midY - size.height / 2,
                          width: size.width, height: size.height)
        }
        let spots = extras.map(spot)
        let union = spots.reduce(window.frame) { $0.union($1) }
        guard let context = CGContext(data: nil, width: Int(union.width * scale), height: Int(union.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Screen points and the context both count up from the bottom left.
        func place(_ frame: NSRect) -> CGRect {
            CGRect(x: (frame.minX - union.minX) * scale, y: (frame.minY - union.minY) * scale,
                   width: frame.width * scale, height: frame.height * scale)
        }
        context.draw(base, in: place(window.frame))
        for (extra, at) in zip(extras, spots) {
            guard let view = extra.contentView?.superview ?? extra.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let drawn = rep.cgImage else { continue }
            if extra.className.contains("Popover") {
                // Its frosted material does not draw this way: the card's
                // ground, flat, under its views (as Fork.layered does).
                let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let card = place(at).insetBy(dx: 13 * scale, dy: 13 * scale)
                context.setFillColor(dark ? CGColor(gray: 0.2, alpha: 1) : CGColor(gray: 0.98, alpha: 1))
                context.addPath(CGPath(roundedRect: card, cornerWidth: 10 * scale, cornerHeight: 10 * scale, transform: nil))
                context.fillPath()
            }
            context.draw(drawn, in: place(at))
        }
        return context.makeImage()
    }

    @discardableResult
    static func write(_ image: CGImage, to path: String) -> Bool {
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    // MARK: - the row's menu, pictured

    /// A right-click on the canvas's row, through the window as a real one
    /// comes; once the menu is up, the window and the menu are pictured
    /// together and the menu is put away.
    static func rowMenu(_ words: [String], in browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        guard words.count >= 2,
              let target = Canvases.shared.find(words[0]) ?? Canvases.shared.all.first(where: { $0.id.hasPrefix(words[0].lowercased()) }),
              let tab = browser.tabs.first(where: { CanvasTabs.showing($0) == target.id }),
              let frame = CanvasRenaming.shared.rows[tab.id],
              let window = Windows.window(of: browser) ?? Links.window, let content = window.contentView
        else { return answer(["error": "canvas rowmenu ID PATH — a canvas with a row on screen"]) }
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        window.makeKeyAndOrderFront(nil)
        let shot = CanvasMenuShot(window: window, path: words[1])
        shot.out["row"] = [frame.minX, frame.minY, frame.width, frame.height]
        shot.point = CGPoint(x: frame.minX + 60, y: frame.maxY + 2) // drawn just under the row, so the row still shows
        let watch = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            let menu = note.object as? NSMenu
            MainActor.assumeIsolated { shot.began(menu) }
        }
        let point = CGPoint(x: frame.minX + 60, y: content.bounds.height - frame.midY)
        let stamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: stamp,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .rightMouseUp, location: point, modifierFlags: [], timestamp: stamp + 0.05,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
        else { NotificationCenter.default.removeObserver(watch); return answer(["error": "no event"]) }
        // Returns once the menu has closed — CanvasMenuShot closes it.
        window.sendEvent(down)
        window.sendEvent(up)
        NotificationCenter.default.removeObserver(watch)
        if shot.out["items"] == nil { shot.out["error"] = "no menu came up" }
        answer(shot.out)
    }
}

/// One `canvas rowmenu`: the menu, once it is tracking, pictured over its
/// window after a beat to draw, then cancelled.
@MainActor
private final class CanvasMenuShot {
    let window: NSWindow
    let path: String
    var out: [String: Any] = [:]
    private var menu: NSMenu?
    /// Where the right-click went, in window points from the top left.
    var point = CGPoint.zero

    init(window: NSWindow, path: String) {
        self.window = window
        self.path = path
    }

    func began(_ menu: NSMenu?) {
        guard self.menu == nil, let menu else { return }
        self.menu = menu
        if Headless.on {
            // The window is parked off every screen and AppKit puts a menu on
            // one — somebody else's. Read it and put it away at once; its
            // items are drawn over the row instead.
            out["items"] = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
            if let base = Fork.layered([CGWindowID(window.windowNumber)]),
               let image = CanvasMenuShot.drawn(menu, over: base, at: point, in: window), CanvasBench.write(image, to: path) {
                out["path"] = path
                out["size"] = [image.width, image.height]
                out["menuFrom"] = "its items, drawn (headless)"
            }
            // Not from inside the notification: a menu told to stop before it
            // has started tracking keeps tracking. A beat later, in the
            // tracking loop's own mode.
            let timer = Timer(timeInterval: 0.05, repeats: false) { [self] _ in MainActor.assumeIsolated { self.menu?.cancelTrackingWithoutAnimation() } }
            RunLoop.main.add(timer, forMode: .common)
            return
        }
        let timer = Timer(timeInterval: 0.4, repeats: false) { [self] _ in MainActor.assumeIsolated { self.picture() } }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func picture() {
        guard let menu else { return }
        out["items"] = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let menus = info.filter {
            ($0[kCGWindowOwnerPID as String] as? Int32) == getpid()
                && ($0[kCGWindowLayer as String] as? Int ?? 0) >= Int(CGWindowLevelForKey(.popUpMenuWindow))
        }.compactMap { ($0[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) } }
        out["menuWindows"] = menus.count
        var image = Fork.layered([CGWindowID(window.windowNumber)] + menus)
        if menus.isEmpty {
            // The compositor lists no menu — a locked screen, a headless run —
            // so the menu's window draws itself over the picture, and failing
            // that its items are drawn where it opened; the answer says which.
            let menuWindows = NSApp.windows.filter { $0.isVisible && $0.className.contains("Menu") }
            if !menuWindows.isEmpty, let drawn = CanvasBench.composite(window, with: menuWindows) {
                image = drawn
                out["menuFrom"] = "its own window's views"
            } else if let base = image {
                image = CanvasMenuShot.drawn(menu, over: base, at: point, in: window)
                out["menuFrom"] = "its items, drawn"
            }
        }
        if let image, CanvasBench.write(image, to: path) {
            out["path"] = path
            out["size"] = [image.width, image.height]
        }
        menu.cancelTracking()
    }

    /// The menu's items as a macOS menu draws them, laid over the window's
    /// picture with its top-left corner at the click, in the window's look.
    fileprivate static func drawn(_ menu: NSMenu, over base: CGImage, at point: CGPoint, in window: NSWindow) -> CGImage? {
        let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let ink = dark ? Color.white.opacity(0.88) : Color.black.opacity(0.85)
        let rows = menu.items.map { item in (title: item.isSeparatorItem ? "" : item.title, separator: item.isSeparatorItem, enabled: item.isEnabled) }
        let card = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                if row.separator {
                    Rectangle().fill((dark ? Color.white : Color.black).opacity(0.1)).frame(height: 1).padding(.horizontal, 10).padding(.vertical, 5)
                } else {
                    HStack(spacing: 0) {
                        Text(row.title).font(.system(size: 13))
                            .foregroundStyle(row.title.hasPrefix("Delete") || row.title.hasPrefix("Leave") ? Color.red : ink)
                            .opacity(row.enabled ? 1 : 0.4)
                        Spacer(minLength: 24)
                        if row.title == "Group" || row.title == "Move to Space" {
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 22)
                }
            }
        }
        .padding(.vertical, 5)
        .frame(width: 210, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(dark ? Color(white: 0.17) : Color(white: 0.97)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder((dark ? Color.white : Color.black).opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        .padding(20)
        let scale = CGFloat(base.width) / max(1, window.frame.width)
        let renderer = ImageRenderer(content: card.environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = scale
        guard let picture = renderer.cgImage,
              let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let whole = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        context.draw(base, in: whole)
        // The card's 20 pt margin holds its shadow; its corner lands on the click.
        let x = (point.x - 20) * scale, top = (point.y - 20) * scale
        context.draw(picture, in: CGRect(x: x, y: CGFloat(base.height) - top - CGFloat(picture.height),
                                         width: CGFloat(picture.width), height: CGFloat(picture.height)))
        return context.makeImage()
    }
}

/// One `canvas scroll`: the gesture, event by event, on a timer 8 ms apart.
/// CGEvent is the one public way to make a continuous, phased wheel event;
/// AppKit reads it back as a trackpad's.
///
/// NSEvent(cgEvent:) takes the event's window from field 51, the window
/// server's own (not in the public CGEventField list), and its location in
/// that window from the window-relative point a real event carries beside
/// the global one (CGEventSetWindowLocation, looked up at run time). With
/// both, the event belongs to the board's window at the board's middle, as
/// a trackpad's would — on a parked headless window too. Straight to the
/// view by default; with --app through NSApp.sendEvent, so the app's
/// monitors (the space swipe) see it first and the window routes it. Should
/// a later macOS take either away, the event is made windowless at the
/// window point instead, which the view reads the same way (`windowed` in
/// the stats says which; --app then reaches no monitor that cares).
@MainActor
private final class CanvasWheelRun {
    private let web: PageView
    private let window: NSWindow
    private let zoom: Bool
    private let app: Bool
    private var plan: [(phase: Int64, dx: Int32, dy: Int32)] = []
    private let windowPoint: CGPoint
    private let screenPoint: CGPoint
    private var took: [Double] = []
    private var sent: [Double] = []
    private var slid = false
    private var windowed = 0
    /// The last windowed event that came out somewhere else, for the stats.
    private var missed: [String: Any]?
    private let space = Spaces.shared.current
    private let left = SpaceSwipe.leftToPage
    private var timer: Timer?
    private var keep: CanvasWheelRun?

    init?(web: PageView, dx: Double, dy: Double, steps: Int, zoom: Bool, app: Bool) {
        guard let window = web.window else { return nil }
        self.web = web
        self.window = window
        self.zoom = zoom
        self.app = app
        windowPoint = web.convert(CGPoint(x: web.bounds.midX, y: web.bounds.midY), to: nil)
        let onScreen = window.convertPoint(toScreen: windowPoint)
        // CGEvent's space: the main display's top left is the origin.
        let top = NSScreen.screens.first?.frame.height ?? 0
        screenPoint = CGPoint(x: onScreen.x, y: top - onScreen.y)
        // Whole points per event, the remainder carried, so the gesture
        // travels exactly DX, DY.
        plan = [(1, 0, 0)]
        var sentX = 0.0, sentY = 0.0
        for i in 1...steps {
            let x = (dx * Double(i) / Double(steps)).rounded(), y = (dy * Double(i) / Double(steps)).rounded()
            plan.append((2, Int32(x - sentX), Int32(y - sentY)))
            sentX = x
            sentY = y
        }
        plan.append((4, 0, 0))
    }

    func start() {
        keep = self
        Input.move(web, to: CGPoint(x: web.bounds.midX, y: web.bounds.midY))
        let timer = Timer(timeInterval: 0.008, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func event(_ step: (phase: Int64, dx: Int32, dy: Int32), at point: CGPoint) -> CGEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: step.dy, wheel2: step.dx, wheel3: 0)
        else { return nil }
        cg.location = point
        // Made now: a made event's clock starts at nought otherwise, and the
        // page's lag reading would be the time since boot.
        cg.timestamp = CGEventTimestamp(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        cg.flags = zoom ? .maskCommand : []
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: step.phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        return cg
    }

    /// The window server's window-number field (kCGSEventWindowIDField).
    private static let windowField = CGEventField(rawValue: 51)

    /// CoreGraphics' own setter for the window-relative location a real
    /// event carries beside its global one (top-left origin), which AppKit
    /// reads once the event has a window. Not public; looked up, not linked,
    /// and only ever used here.
    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private static let setWindowLocation: SetWindowLocation? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return nil }
        return unsafeBitCast(symbol, to: SetWindowLocation.self)
    }()

    /// The event, belonging to the board's window if AppKit will have it so.
    private func made(_ step: (phase: Int64, dx: Int32, dy: Int32)) -> NSEvent? {
        if let field = CanvasWheelRun.windowField, let cg = event(step, at: screenPoint) {
            cg.setIntegerValueField(field, value: Int64(window.windowNumber))
            CanvasWheelRun.setWindowLocation?(cg, CGPoint(x: windowPoint.x, y: window.frame.height - windowPoint.y))
            // A parked (headless) window is off every display, and an event's
            // location is kept on one: there the windowless event stands in.
            if let ev = NSEvent(cgEvent: cg) {
                if ev.window === window, abs(ev.locationInWindow.x - windowPoint.x) < 1, abs(ev.locationInWindow.y - windowPoint.y) < 1 {
                    return ev
                }
                missed = ["window": ev.window === window, "at": [ev.locationInWindow.x, ev.locationInWindow.y],
                          "wanted": [windowPoint.x, windowPoint.y]]
            }
        }
        let top = NSScreen.screens.first?.frame.height ?? 0
        return event(step, at: CGPoint(x: windowPoint.x, y: top - windowPoint.y)).flatMap { NSEvent(cgEvent: $0) }
    }

    private func tick() {
        guard !plan.isEmpty else { return finish() }
        let step = plan.removeFirst()
        let start = CACurrentMediaTime()
        sent.append(start)
        guard let ev = made(step) else { return }
        if ev.window === window { windowed += 1 }
        if app, ev.window === window { NSApp.sendEvent(ev) } else { web.scrollWheel(with: ev) }
        took.append((CACurrentMediaTime() - start) * 1_000_000)
        slid = slid || SpaceSlide.shared.moving
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        DispatchQueue.main.async { [self] in
            let gaps = zip(sent.dropFirst(), sent).map { ($0 - $1) * 1000 }
            CanvasBench.lastScroll = [
                "events": sent.count, "windowed": windowed, "missed": missed ?? NSNull(), "app": app, "zoom": zoom, "lean": web.board,
                "viewMicros": CanvasWheelRun.stats(took), "gapMs": CanvasWheelRun.stats(gaps), "over12": gaps.filter { $0 > 12 }.count,
                "spaceChanged": Spaces.shared.current != space, "slid": slid || SpaceSlide.shared.moving,
                "leftToPage": SpaceSwipe.leftToPage - left,
            ]
            keep = nil
        }
    }

    static func stats(_ values: [Double]) -> [String: Any] {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return [:] }
        func round(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        let pick = { (p: Double) in round(sorted[min(sorted.count - 1, Int(p * Double(sorted.count)))]) }
        return ["p50": pick(0.5), "p95": pick(0.95), "max": round(sorted.last ?? 0), "mean": round(sorted.reduce(0, +) / Double(sorted.count))]
    }
}
