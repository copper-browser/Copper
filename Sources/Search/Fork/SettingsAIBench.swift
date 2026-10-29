import AppKit
import SwiftUI

// Settings › Intelligence, Agents and Labs from the bench (`bench ai …`):
// a whole page drawn to a PNG at any width, the accessibility tree a
// VoiceOver user meets, a click or a key at a point, Copper Cloud's keys
// stood in, and what the pages' Copy and Open buttons did in a test world.

@MainActor
enum SettingsAIBench {
    /// The `ai` verbs this file answers; nil hands the request back to the
    /// rest of `ai` (Fork.swift).
    static func handle(_ op: String, _ arg: String, in browser: Browser) -> [String: Any]? {
        switch op {
        case "picture": return picture(arg, in: browser)
        case "ax": return accessibility(arg, in: browser)
        // Input goes to whatever has focus, so only a test run takes it
        // (as `bench key` does): in someone's own browser it could type
        // into their page.
        case let input where (input == "click" || input == "key") && !Store.testing:
            return ["error": "\(input) only works in a test run"]
        case "click": return click(arg, in: browser)
        case "key": return key(arg, in: browser)
        case "cloud": return cloud(arg)
        case "views": return views(in: browser)
        case "churn": return churn(arg, in: browser)
        case "clipboard":
            return ["text": SettingsActions.pasteboard.string(forType: .string) ?? "", "opened": SettingsActions.opened,
                    "probe": SettingsActions.probe]
        case "check":
            if arg != "status" { IntelligenceCheck.shared.run() }
            return IntelligenceCheck.shared.report
        default: return nil
        }
    }

    // MARK: picture

    /// `ai picture PAGE PATH [dark] [WIDTH]`: the whole page, every row, at
    /// the content width Settings gives it (345 pt in the smallest window,
    /// 635 pt in the widest panel).
    private static func picture(_ arg: String, in browser: Browser) -> [String: Any] {
        let words = arg.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return ["error": "ai picture intelligence|agents PATH [dark] [WIDTH]"] }
        let dark = words.contains("dark")
        let width = words.dropFirst(2).compactMap { Double($0) }.first ?? 635
        let page: AnyView
        switch words[0].lowercased() {
        case "intelligence": page = AnyView(IntelligencePage(browser: browser))
        case "agents": page = AnyView(AgentsPage(browser: browser))
        default: return ["error": "no page \(words[0]) — intelligence or agents"]
        }
        let host = NSHostingView(rootView: page
            .frame(width: CGFloat(width), alignment: .topLeading)
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
            .background(SettingsInk.content)
            .environment(\.settingsLook, true)
            .environment(\.colorScheme, dark ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return ["error": "no picture"] }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return ["error": "no png"] }
        let path = URL(fileURLWithPath: words[1]).standardizedFileURL.path
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { return ["error": "\(error)"] }
        return ["path": path, "size": [Int(host.bounds.width), Int(host.bounds.height)]]
    }

    // MARK: accessibility

    /// `ai ax [WORDS]`: every accessibility element of the open window that
    /// VoiceOver would meet, with its role, label, value and frame (window
    /// points, top-left origin, so `ai click` can aim at it). WORDS narrows
    /// it to elements whose role, label, title, value or help contain them.
    private static func accessibility(_ arg: String, in browser: Browser) -> [String: Any] {
        guard let window = Windows.window(of: browser) ?? Links.window, let root = window.contentView else { return ["error": "no window"] }
        let needle = arg.lowercased().trimmingCharacters(in: .whitespaces)
        var rows: [[String: Any]] = []
        var seen = Set<ObjectIdentifier>()
        func text(_ any: Any?) -> String {
            switch any {
            case let s as String: return s
            case let s as NSAttributedString: return s.string
            case let n as NSNumber: return n.stringValue
            default: return ""
            }
        }
        func walk(_ element: Any, depth: Int) {
            guard depth < 60, rows.count < 600, let el = element as? NSAccessibilityProtocol else { return }
            let object = el as AnyObject
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            // A page's own web content is not Settings.
            if object is WKWebViewMarker { return }
            if el.isAccessibilityElement() {
                let screen = el.accessibilityFrame()
                let local = window.convertFromScreen(screen)
                let row: [String: Any] = [
                    "role": el.accessibilityRole()?.rawValue ?? "",
                    "label": el.accessibilityLabel() ?? "",
                    "title": el.accessibilityTitle() ?? "",
                    "value": text(el.accessibilityValue()),
                    "help": el.accessibilityHelp() ?? "",
                    "enabled": el.isAccessibilityEnabled(),
                    "focused": el.isAccessibilityFocused(),
                    "frame": [Int(local.minX), Int(window.frame.height - local.maxY), Int(local.width), Int(local.height)],
                ]
                let words = [row["role"], row["label"], row["title"], row["value"], row["help"]].map { "\($0 ?? "")" }.joined(separator: " ").lowercased()
                if needle.isEmpty || words.contains(needle) { rows.append(row) }
            }
            for child in el.accessibilityChildren() ?? [] { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return ["count": rows.count, "elements": rows]
    }

    /// `ai views`: the window's AppKit views by class, most first — what a
    /// page costs AppKit to lay out, track and walk on every display cycle.
    private static func views(in browser: Browser) -> [String: Any] {
        guard let root = (Windows.window(of: browser) ?? Links.window)?.contentView else { return ["error": "no window"] }
        var counts: [String: Int] = [:]
        var tracking = 0
        func walk(_ view: NSView) {
            counts[String(describing: type(of: view)), default: 0] += 1
            tracking += view.trackingAreas.count
            view.subviews.forEach(walk)
        }
        walk(root)
        let top = counts.sorted { $0.value > $1.value }.prefix(30).map { "\($0.value) \($0.key)" }
        return ["views": counts.values.reduce(0, +), "trackingAreas": tracking, "byClass": top]
    }

    /// `ai churn mcp|brain|agent|links|servers|check [N]`: what one redraw of
    /// the open page costs when one of the objects the AI pages watch says it
    /// changed (`settings perf churn`, with these sources added).
    private static func churn(_ arg: String, in browser: Browser) -> [String: Any] {
        let sources: [String: (Browser) -> () -> Void] = [
            "mcp": { _ in { MCP.shared.objectWillChange.send() } },
            "brain": { _ in { Intelligence.shared.objectWillChange.send() } },
            "agent": { _ in { Agent.shared.objectWillChange.send() } },
            "links": { _ in { AgentLinks.shared.objectWillChange.send() } },
            "servers": { _ in { Servers.shared.objectWillChange.send() } },
            "check": { _ in { IntelligenceCheck.shared.objectWillChange.send() } },
            "account": { _ in { ClaudeAccount.shared.objectWillChange.send() } },
        ]
        for (name, make) in sources { SettingsPerf.publishers[name] = make }
        var out: [String: Any] = [:]
        SettingsPerf.handle("churn " + arg, in: browser) { out = $0 }
        return out
    }

    // MARK: input

    /// `ai click X Y`: a left click at window point X Y (top-left origin),
    /// sent through the window as a person's would be.
    private static func click(_ arg: String, in browser: Browser) -> [String: Any] {
        let bits = arg.split(separator: " ").compactMap { Double($0) }
        guard bits.count == 2, let window = Windows.window(of: browser) ?? Links.window else { return ["error": "ai click X Y"] }
        let location = NSPoint(x: bits[0], y: window.frame.height - bits[1])
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            window.sendEvent(event)
        }
        let hit = window.contentView?.hitTest(location)
        return ["at": [bits[0], bits[1]], "hit": hit.map { "\(type(of: $0))" } ?? "",
                "firstResponder": window.firstResponder.map { "\(type(of: $0))" } ?? ""]
    }

    /// `ai key tab|shift-tab|return|escape|space|TEXT`: a key through the
    /// app's own routing (its key monitor first), at whatever has focus.
    private static func key(_ arg: String, in browser: Browser) -> [String: Any] {
        guard let window = Windows.window(of: browser) ?? Links.window else { return ["error": "no window"] }
        var flags: NSEvent.ModifierFlags = []
        let named: (String, UInt16)?
        switch arg.lowercased() {
        case "tab": named = ("\t", 48)
        case "shift-tab": named = ("\u{19}", 48); flags = .shift
        case "return": named = ("\r", 36)
        case "escape": named = ("\u{1b}", 53)
        case "space": named = (" ", 49)
        default: named = nil
        }
        let strokes: [(String, UInt16)] = named.map { [$0] } ?? arg.map { (String($0), 0) }
        for (chars, code) in strokes {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil, characters: chars,
                                                   charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { continue }
                NSApp.sendEvent(event)
            }
        }
        let focused = (window.firstResponder as? NSAccessibilityProtocol).map { el -> [String: Any] in
            ["role": el.accessibilityRole()?.rawValue ?? "", "label": el.accessibilityLabel() ?? "", "title": el.accessibilityTitle() ?? ""]
        } ?? [:]
        return ["sent": arg, "firstResponder": window.firstResponder.map { "\(type(of: $0))" } ?? "", "focused": focused]
    }

    // MARK: Copper Cloud, stood in

    /// `ai cloud fake JSON` adopts a `GET /v1/intelligence` answer as if the
    /// linked cloud had sent it (test worlds only); `ai cloud clear` drops it.
    private static func cloud(_ arg: String) -> [String: Any] {
        guard Store.world != nil else { return ["error": "only in a test world"] }
        if arg == "clear" {
            Intelligence.shared.adoptCloud(nil)
        } else if arg.hasPrefix("fake ") {
            guard var provided = CloudProvided.parse(Data(arg.dropFirst(5).utf8)) else { return ["error": "not a JSON object"] }
            provided.host = "cloud.probe.example"
            provided.fetchedAt = Date()
            Intelligence.shared.adoptCloud(provided)
        } else {
            return ["error": "ai cloud fake JSON|clear"]
        }
        var out = Intelligence.shared.control(["op": "sources"])
        out["maxTurns"] = Intelligence.shared.cloudMaxTurns ?? NSNull()
        return out
    }
}

/// Lets the accessibility walk skip a page's own web content by type alone.
private typealias WKWebViewMarker = PageView
