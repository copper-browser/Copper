import AppKit
import WebKit

// The tools an agent gets, named and shaped like Playwright MCP's so the
// skills already written for that work here unchanged: browser_snapshot,
// browser_click, browser_type, browser_navigate, browser_take_screenshot
// and the rest. Under them is the tab you have open, not a browser of the
// agent's own.
//
// Elements are addressed by `ref` — an id the snapshot hands out (e1, e2…)
// and remembers on the element itself — or by a CSS selector when the agent
// knows one. Clicks and keys go in as real events at the window (Input.swift)
// so pages see trusted input; when a tab has no window to receive them, the
// DOM gets an event of the same shape instead.
//
// Which tab: the one the call names (`tab`), else the agent's own (the one
// it opened or selected), else the one on the user's screen. A tab of the
// agent's own is worked on where it is — in the background, never brought in
// front of the user (Backstage.swift).

enum Tools {
    struct Failure: Error {
        let text: String
    }

    /// Where a tool leaves its one-line summary for `_meta.summary`
    /// (MCP.handle reads it back). Task-local, so two calls in flight never
    /// see each other's line.
    final class SummaryBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        var line: String? {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set {
                lock.lock(); defer { lock.unlock() }
                value = newValue.map { $0.count > 200 ? String($0.prefix(199)) + "…" : $0 }
            }
        }
    }
    @TaskLocal static var summary: SummaryBox?

    enum Content {
        case text(String)
        case image(Data, mime: String)

        var json: [String: Any] {
            switch self {
            case .text(let s): return ["type": "text", "text": s]
            case .image(let d, let mime): return ["type": "image", "data": d.base64EncodedString(), "mimeType": mime]
            }
        }
    }

    /// What every tool tells the agent about its own tab.
    static let tabNote = "Work that the user need not watch goes in a tab of your own: browser_tabs new (or jev_run with newTab) opens one in the background without switching the user's tab, and every later call of yours lands there — snapshots, screenshots, clicks and typing all work while the user looks at something else. browser_tabs select binds you to another tab the same way; pass focus: true only when the user should see it."

    /// What every tool tells the agent about `reason`: the user is watching.
    static let reasonNote = "The user watches every call in a pane beside the page: pass `reason` (one short sentence: what you are doing and why) on each call, and `element` for anything you click or type into. If a call answers \"Stopped by the user\", stop and say so — do not retry."

    /// `voice`: the Listen transcript's sentence (VoiceTools), for loopback
    /// clients only — a linked bot never has those tools.
    @MainActor
    static func instructions(jev: Bool, voice: Bool = false) -> String {
        let listen = voice && !VoiceTools.instruction.isEmpty ? " " + VoiceTools.instruction : ""
        guard jev else {
            return "Copper is the user's own browser, signed in as them; the current tab is the one they are looking at — work there unless the task names another tab. First action: call browser_snapshot with interactive: true on the current tab, then act with its refs. Call browser_tabs only when another tab is named. Take a screenshot when layout matters. Nothing is sandboxed — act as the user would. For sign-in forms call browser_sign_in first; it fills a saved account in-process and never returns the password. For checkout, address, or sign-up forms call browser_autofill (kind card|identity) — it fills from the vault and never returns the values. \(tabNote) \(reasonNote) \(CanvasTools.instructions)\(listen)"
        }
        return "Copper is the user's own browser, signed in as them; the current tab is the one they are looking at — work there unless the task names another tab. ANY task: the FIRST call is jev_run with the whole goal, every concrete place/date/name/filter and stop condition; no browser_tabs or snapshot first. Add url only for a named page that is not current. jev_observe = fast indexed read; jev_extract = JSON values; jev_step = one decision. BLOCKED → browser_snapshot/click/type for that part, then jev_run again. DONE is Jev's claim — verify with jev_observe/jev_extract. Screenshot when layout matters; nothing is sandboxed — act as the user. For sign-in forms call browser_sign_in first; it fills a saved account in-process and never returns the password. For checkout, address, or sign-up forms call browser_autofill (kind card|identity) — it fills from the vault and never returns the values. \(tabNote) \(reasonNote) \(CanvasTools.instructions)\(listen)"
    }

    // MARK: - the catalogue

    /// Every tool takes `reason`: one sentence the user reads in the pane
    /// beside the page while the agent works. Optional, never acted on.
    static let reasonProperty: [String: Any] = [
        "type": "string",
        "description": "One short sentence on what you are doing and why — shown to the user watching the browser",
    ]

    /// Every page tool takes `tab`, for a call on a tab other than the
    /// caller's own.
    static let tabProperty: [String: Any] = [
        "type": "string",
        "description": "Tab id (or index) from browser_tabs list; omit for your own tab — the one you opened or selected — or else the user's current tab",
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        var all = properties
        if all["reason"] == nil { all["reason"] = reasonProperty }
        if all["tab"] == nil, !["browser_tabs", "browser_resize"].contains(name) { all["tab"] = tabProperty }
        return [
            "name": name,
            "description": description,
            "inputSchema": ["type": "object", "properties": all, "required": required] as [String: Any],
        ]
    }

    private static func string(_ description: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var out: [String: Any] = ["type": "string", "description": description]
        for (k, v) in extra { out[k] = v }
        return out
    }
    private static func number(_ description: String) -> [String: Any] { ["type": "number", "description": description] }
    private static func bool(_ description: String) -> [String: Any] { ["type": "boolean", "description": description] }

    static let elementProperties: [String: Any] = [
        "element": string("Human-readable element description, used to obtain permission to interact with the element"),
        "ref": string("Exact target element reference from the page snapshot (e.g. e12)"),
        "selector": string("CSS selector, if you know one and have no ref"),
    ]

    static func catalogue(jev: Bool) -> [[String: Any]] {
        // The canvas tools last (Fork/Canvas/CanvasTools.swift).
        (jev ? Ultrafast.catalogue + playwright : playwright) + CanvasTools.catalogue
    }

    static var playwright: [[String: Any]] {
        [
            tool("browser_tabs", "List, create, close, or select a browser tab. new opens a tab of your own in the background — the user's tab does not change — and your later calls land on it; select makes another tab yours the same way. Neither brings the tab in front of the user unless focus is true.", [
                "action": string("Operation to perform", ["enum": ["list", "new", "close", "select"]]),
                "index": number("Tab index (from list) for close/select; omit to act on your tab"),
                "tab": string("Tab id (from list) for close/select, instead of index"),
                "url": string("Address to open, for new"),
                "focus": bool("Also show the tab to the user (switch their window to it). Default false — leave the user where they are"),
            ], required: ["action"]),
            tool("browser_sign_in", "Sign in on the current tab with a saved account the user has shared with agents. Fills (and by default submits) the password in-process; you never receive the secret. what=otp fills the account's one-time code. what=passkey arms the account's shared Bitwarden passkey for the site's next passkey sign-in (then click the site's passkey button); the key never leaves Copper.", [
                "account": string("Username to use when several are saved"),
                "what": string("password (default), otp, or passkey", ["enum": ["password", "otp", "passkey"]]),
                "submit": bool("Whether to submit after filling; defaults to true"),
            ]),
            tool("browser_autofill", "Fill a saved card, identity (name/address/contact), or a custom field from the user's vault into the current tab's form, in-process; you never receive the values. kind=card fills number/holder/expiry/code; kind=identity fills name, address, email, phone, company; kind=field fills the custom field called name.", [
                "kind": string("What to fill", ["enum": ["card", "identity", "field"]]),
                "name": string("Saved item or custom field name (required for field)"),
                "submit": bool("Whether to submit after filling; defaults to false"),
            ], required: ["kind"]),
            tool("browser_navigate", "Navigate to a URL in the current tab", ["url": string("The URL to navigate to")], required: ["url"]),
            tool("browser_navigate_back", "Go back to the previous page"),
            tool("browser_navigate_forward", "Go forward to the next page"),
            tool("browser_snapshot", "Capture accessibility snapshot of the current page. Better than a screenshot for reading and for finding refs to act on.", [
                "selector": string("Only the subtree under this CSS selector"),
                "interactive": bool("Only interactive elements (links, buttons, fields) — smaller"),
                "limit": number("Cap on the number of nodes; default 600"),
            ]),
            tool("browser_click", "Perform click on a web page", elementProperties.merging([
                "doubleClick": bool("Double click instead of single"),
                "button": string("Button to click, defaults to left", ["enum": ["left", "right", "middle"]]),
                "modifiers": ["type": "array", "items": ["type": "string", "enum": ["Alt", "Control", "ControlOrMeta", "Meta", "Shift"]], "description": "Modifier keys to hold"] as [String: Any],
            ]) { a, _ in a }),
            tool("browser_type", "Type text into editable element", elementProperties.merging([
                "text": string("Text to type into the element"),
                "submit": bool("Whether to press Enter after typing"),
                "slowly": bool("Type one character at a time, firing key events; default sets the value at once"),
            ]) { a, _ in a }, required: ["text"]),
            tool("browser_fill_form", "Fill multiple form fields", [
                "fields": ["type": "array", "description": "Fields to fill", "items": ["type": "object", "properties": [
                    "name": string("Human-readable field name"),
                    "type": string("Field type", ["enum": ["textbox", "checkbox", "radio", "combobox", "slider"]]),
                    "ref": string("Exact target field reference from the snapshot"),
                    "value": string("Value to fill; for checkbox 'true'/'false'"),
                ]]] as [String: Any],
            ], required: ["fields"]),
            tool("browser_press_key", "Press a key on the keyboard", [
                "key": string("Name of the key to press or a character to generate, such as ArrowLeft, Enter, Escape, Tab, a"),
                "modifiers": ["type": "array", "items": ["type": "string"], "description": "Alt, Control, Meta, Shift"] as [String: Any],
            ], required: ["key"]),
            tool("browser_hover", "Hover over element on page", elementProperties),
            tool("browser_select_option", "Select an option in a dropdown", elementProperties.merging([
                "values": ["type": "array", "items": ["type": "string"], "description": "Values or labels to select"] as [String: Any],
            ]) { a, _ in a }, required: ["values"]),
            tool("browser_drag", "Perform drag and drop between two elements", [
                "startElement": string("Source element description"), "startRef": string("Source ref"),
                "endElement": string("Target element description"), "endRef": string("Target ref"),
            ], required: ["startRef", "endRef"]),
            tool("browser_take_screenshot", "Take a screenshot of the current page (PNG). Coordinates in the image are CSS pixels of the page.", [
                "type": string("Image format", ["enum": ["png", "jpeg"]]),
                "fullPage": bool("Whole scrollable page rather than the viewport"),
                "ref": string("Screenshot just this element"),
                "filename": string("Also save to this path"),
            ]),
            tool("browser_evaluate", "Evaluate JavaScript expression on page or element", [
                "function": string("() => { /* code */ } or (element) => { /* code */ } when ref is given"),
                "ref": string("Element to pass to the function"),
            ], required: ["function"]),
            tool("browser_wait_for", "Wait for text to appear or disappear, or for a time to pass", [
                "text": string("Text to wait for"), "textGone": string("Text to wait to disappear"), "time": number("Seconds to wait"),
            ]),
            tool("browser_scroll", "Scroll the page or an element", [
                "ref": string("Element to scroll into view, or to scroll within"),
                "deltaY": number("Pixels to scroll down (negative for up); default one screen"),
                "deltaX": number("Pixels to scroll right"),
            ]),
            tool("browser_get_text", "The page's readable text (or an element's), for reading without a snapshot", ["ref": string("Element ref"), "selector": string("CSS selector")]),
            tool("browser_console_messages", "Console messages captured on the current page since it loaded"),
            tool("browser_find", "Find on the page: the refs of elements whose text matches", ["text": string("Text to look for")], required: ["text"]),
            tool("browser_resize", "Resize the browser window", ["width": number("Width"), "height": number("Height")], required: ["width", "height"]),
            tool("browser_close", "Close your tab (the one your calls land on)"),
            tool("browser_groups", "Copper's tab groups: list them, or move the current tab into one", [
                "action": string("list, assign, remove", ["enum": ["list", "assign", "remove"]]),
                "group": string("Group name for assign (created if new)"),
            ], required: ["action"]),
        ] + Probe.catalogue + [Crashes.tool]
    }

    // MARK: - dispatch

    @MainActor
    static func call(_ name: String, _ args: [String: Any], in browser: Browser) async throws -> [Content] {
        // Every caller's calls pass here (MCP, the agent pane, linked apps):
        // one breadcrumb each — the name, the tab, the time, ok or not.
        let started = Date()
        do {
            var content = try await pinnedCall(name, args, in: browser)
            let tab = AgentTabs.peek(args, in: browser, caller: AgentTabs.callerKey)?.id
            Breadcrumbs.tool(name, tab: tab, started: started, error: nil)
            // Fork: bitwarden-passkeys — the page got a bare NotAllowedError;
            // the agent gets why, once, on its next call on that tab.
            if let tab, let why = Passkeys.takeRefusal(tab) {
                content.append(.text("Passkey sign-in refused on this tab: \(why)"))
            }
            return content
        } catch {
            Breadcrumbs.tool(name, tab: AgentTabs.peek(args, in: browser, caller: AgentTabs.callerKey)?.id, started: started, error: error)
            throw error
        }
    }

    @MainActor
    private static func pinnedCall(_ name: String, _ args: [String: Any], in browser: Browser) async throws -> [Content] {
        // browser_tabs reads `tab` as the tab to close or select, not to work in.
        guard name != "browser_tabs", let named = try AgentTabs.resolve(args["tab"], in: browser) else {
            return try await dispatch(name, args, in: browser)
        }
        return try await AgentTabs.$pinned.withValue(named.id) { try await dispatch(name, args, in: browser) }
    }

    @MainActor
    private static func dispatch(_ name: String, _ args: [String: Any], in browser: Browser) async throws -> [Content] {
        if !["browser_tabs", "browser_close", "browser_resize", "browser_groups", "browser_crashes", CloudHistoryTool.name].contains(name), !CanvasTools.names.contains(name),
           !(name == "jev_run" && (args["newTab"] as? Bool) == true) {
            await AgentTabs.ready(in: browser)
        }
        switch name {
        case "browser_tabs": return try await tabs(args, in: browser)
        case "browser_close":
            let tab = try current(browser)
            let said = close(tab)
            return [.text("\(said) \(tabList(browser))")]
        case "browser_resize":
            guard let w = args["width"] as? NSNumber, let h = args["height"] as? NSNumber else { throw Failure(text: "width and height") }
            guard let window = Windows.window(of: browser) ?? Links.window ?? NSApp.windows.first(where: { $0.isVisible }) else { throw Failure(text: "no window") }
            var frame = window.frame
            frame.size = CGSize(width: w.doubleValue, height: h.doubleValue)
            window.setFrame(frame, display: true, animate: false)
            return [.text("Window is \(Int(w.doubleValue))×\(Int(h.doubleValue))")]
        case "browser_groups": return groups(args, in: browser)
        case "jev_run", "jev_step", "jev_observe", "jev_extract": return try await Ultrafast.call(name, args, in: browser)
        case _ where CanvasTools.names.contains(name): return try await CanvasTools.call(name, args, in: browser)
        case "browser_crashes": return [.text(try Crashes.answer(args))]
        case CloudHistoryTool.name: return try await CloudHistoryTool.call(args)
        default: break
        }

        // A sleeping tab comes back for the agent the way it does for a
        // click; one off screen is hung backstage so it paints (current).
        let tab = try current(browser)
        let web = tab.web

        switch name {
        case "browser_sign_in":
            let result = try await SignIn.run(args, in: browser, source: .mcp)
            guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else {
                throw Failure(text: "could not encode sign-in result")
            }
            return [.text(String(decoding: data, as: UTF8.self))]
        case "browser_autofill":
            let result = try await AgentAutofill.run(args, in: browser, source: .mcp)
            guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else {
                throw Failure(text: "could not encode autofill result")
            }
            return [.text(String(decoding: data, as: UTF8.self))]
        case "browser_perf_probe": return try await Probe.run(args, in: browser)
        case "browser_navigate":
            guard let raw = args["url"] as? String else { throw Failure(text: "url required") }
            guard let url = Address.url(from: raw) else { throw Failure(text: "not an address: \(raw)") }
            tab.go(to: url)
            try await settle(tab)
            return [.text(pageLine(tab))]
        case "browser_navigate_back":
            web.goBack()
            try await settle(tab)
            return [.text(pageLine(tab))]
        case "browser_navigate_forward":
            web.goForward()
            try await settle(tab)
            return [.text(pageLine(tab))]
        case "browser_snapshot":
            let interactive = (args["interactive"] as? Bool) ?? false
            let limit = (args["limit"] as? NSNumber)?.intValue ?? 600
            let selector = args["selector"] as? String
            let text = try await Page.snapshot(web, selector: selector, interactive: interactive, limit: limit)
            return [.text("\(pageLine(tab))\n\n\(text)")]
        case "browser_click":
            let target = try locator(args)
            let rect = try await Page.prepare(web, target)
            let button = (args["button"] as? String) ?? "left"
            let double = (args["doubleClick"] as? Bool) ?? false
            let mods = Input.modifiers(from: args["modifiers"] as? [String] ?? [])
            // cosmetic only: the target outlined and named, the pointer
            // brought to it, the press marked — what the user sees of the call.
            trail(web, rect, label: args["element"] as? String, operation: "CLICK")
            await Trail.glide(web, x: rect.midX / web.pageZoom, y: rect.midY / web.pageZoom)
            Trail.click(web, x: rect.midX / web.pageZoom, y: rect.midY / web.pageZoom)
            if Input.canPost(to: web) {
                Input.click(web, at: rect.center, button: button, count: double ? 2 : 1, modifiers: mods)
            } else {
                _ = try await Page.js(web, "window.__copper.click(\(Page.quote(target.script)), \(double), \(Page.quote(button)))")
            }
            try await settle(tab, budget: 3)
            return [.text("Clicked \(args["element"] as? String ?? target.script). \(pageLine(tab))")]
        case "browser_hover":
            let target = try locator(args)
            let rect = try await Page.prepare(web, target)
            trail(web, rect, label: args["element"] as? String, operation: "HOVER")
            await Trail.glide(web, x: rect.midX / web.pageZoom, y: rect.midY / web.pageZoom)
            if Input.canPost(to: web) { Input.move(web, to: rect.center) }
            else { _ = try await Page.js(web, "window.__copper.hover(\(Page.quote(target.script)))") }
            return [.text("Hovering \(args["element"] as? String ?? target.script)")]
        case "browser_type":
            let target = try locator(args)
            guard let text = args["text"] as? String else { throw Failure(text: "text required") }
            let submit = (args["submit"] as? Bool) ?? false
            let slowly = (args["slowly"] as? Bool) ?? false
            let rect = try await Page.prepare(web, target)
            trail(web, rect, label: args["element"] as? String, operation: "TYPE_TEXT")
            await Trail.glide(web, x: rect.midX / web.pageZoom, y: rect.midY / web.pageZoom)
            Trail.click(web, x: rect.midX / web.pageZoom, y: rect.midY / web.pageZoom)
            if Input.canPost(to: web) {
                Input.click(web, at: rect.center, button: "left", count: 1, modifiers: [])
                try await Task.sleep(nanoseconds: 60_000_000)
                _ = try await Page.js(web, "window.__copper.focus(\(Page.quote(target.script)))")
                if slowly {
                    Input.type(web, text)
                } else {
                    _ = try await Page.js(web, "window.__copper.setValue(\(Page.quote(target.script)), \(Page.quote(text)))")
                }
            } else {
                _ = try await Page.js(web, "window.__copper.setValue(\(Page.quote(target.script)), \(Page.quote(text)))")
            }
            // cosmetic only: what was written, beside the field — masked when
            // the field sounds like a secret, the same fence the link progress uses.
            Trail.typed(web, x: rect.midX / web.pageZoom, y: rect.midY / web.pageZoom,
                        text: JevProgress.looksSecret(((args["element"] as? String) ?? "") + " " + target.script) ? "•••" : text)
            if submit {
                if Input.canPost(to: web) { Input.key(web, "Enter", modifiers: []) }
                else { _ = try await Page.js(web, "window.__copper.submit(\(Page.quote(target.script)))") }
                try await settle(tab, budget: 3)
            }
            return [.text("Typed into \(args["element"] as? String ?? target.script)\(submit ? " and submitted" : ""). \(pageLine(tab))")]
        case "browser_fill_form":
            guard let fields = args["fields"] as? [[String: Any]] else { throw Failure(text: "fields required") }
            var lines: [String] = []
            for field in fields {
                guard let ref = field["ref"] as? String else { continue }
                let value = (field["value"] as? String) ?? ""
                let kind = (field["type"] as? String) ?? "textbox"
                let result = try await Page.js(web, "window.__copper.fill(\(Page.quote("ref:" + ref)), \(Page.quote(kind)), \(Page.quote(value)))")
                lines.append("\(field["name"] as? String ?? ref): \(Page.render(result))")
            }
            return [.text(lines.joined(separator: "\n"))]
        case "browser_press_key":
            guard let key = args["key"] as? String else { throw Failure(text: "key required") }
            let mods = Input.modifiers(from: args["modifiers"] as? [String] ?? [])
            if Input.canPost(to: web) {
                Input.key(web, key, modifiers: mods)
            } else {
                _ = try await Page.js(web, "window.__copper.key(\(Page.quote(key)))")
            }
            try await settle(tab, budget: 2)
            return [.text("Pressed \(key). \(pageLine(tab))")]
        case "browser_select_option":
            let target = try locator(args)
            let values = (args["values"] as? [String]) ?? []
            let result = try await Page.js(web, "window.__copper.select(\(Page.quote(target.script)), \(Page.quote(values)))")
            return [.text(Page.render(result))]
        case "browser_drag":
            guard let a = args["startRef"] as? String, let b = args["endRef"] as? String else { throw Failure(text: "startRef and endRef") }
            let from = try await Page.prepare(web, Locator(ref: a))
            let to = try await Page.prepare(web, Locator(ref: b))
            trail(web, from, label: args["startElement"] as? String, operation: "DRAG")
            Trail.click(web, x: from.midX / web.pageZoom, y: from.midY / web.pageZoom)
            await Trail.glide(web, x: to.midX / web.pageZoom, y: to.midY / web.pageZoom)
            Trail.click(web, x: to.midX / web.pageZoom, y: to.midY / web.pageZoom)
            if Input.canPost(to: web) {
                Input.drag(web, from: from.center, to: to.center)
            } else {
                _ = try await Page.js(web, "window.__copper.drag(\(Page.quote("ref:" + a)), \(Page.quote("ref:" + b)))")
            }
            return [.text("Dragged \(a) to \(b)")]
        case "browser_take_screenshot":
            let jpeg = (args["type"] as? String) == "jpeg"
            let full = (args["fullPage"] as? Bool) ?? false
            var rect: CGRect?
            if let ref = args["ref"] as? String { rect = try await Page.prepare(web, Locator(ref: ref)) }
            let data = try await Page.screenshot(web, rect: rect, fullPage: full, jpeg: jpeg)
            var note = ""
            if let path = args["filename"] as? String {
                // Off the main thread, bounded: a guarded or removable volume
                // can hang open() on a privacy prompt (OffMainWrite.swift).
                do {
                    try await OffMainWrite.write(data, to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
                } catch let timedOut as OffMainWrite.TimedOut {
                    throw Failure(text: timedOut.description)
                } catch {
                    note = "Couldn't save to \(path): \(error.localizedDescription). "
                }
            }
            return [.image(data, mime: jpeg ? "image/jpeg" : "image/png"), .text(note + pageLine(tab))]
        case "browser_evaluate":
            guard let function = args["function"] as? String else { throw Failure(text: "function required") }
            let script: String
            if let ref = args["ref"] as? String {
                script = "(\(function))(window.__copper.find(\(Page.quote("ref:" + ref))))"
            } else {
                script = "(\(function))()"
            }
            let result = try await Page.js(web, script)
            return [.text(Page.render(result))]
        case "browser_wait_for":
            if let seconds = (args["time"] as? NSNumber)?.doubleValue {
                try await Task.sleep(nanoseconds: UInt64(min(seconds, 30) * 1_000_000_000))
            }
            let deadline = Date().addingTimeInterval(15)
            if let text = args["text"] as? String {
                while Date() < deadline {
                    if let hit = try await Page.js(web, "document.body && document.body.innerText.includes(\(Page.quote(text)))") as? Bool, hit { break }
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
            }
            if let text = args["textGone"] as? String {
                while Date() < deadline {
                    if let hit = try await Page.js(web, "document.body && document.body.innerText.includes(\(Page.quote(text)))") as? Bool, !hit { break }
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
            }
            return [.text(pageLine(tab))]
        case "browser_scroll":
            let dy = (args["deltaY"] as? NSNumber)?.doubleValue
            let dx = (args["deltaX"] as? NSNumber)?.doubleValue ?? 0
            if let ref = args["ref"] as? String, dy == nil {
                _ = try await Page.prepare(web, Locator(ref: ref))
                return [.text("Scrolled \(ref) into view")]
            }
            let y = dy ?? (web.bounds.height * 0.85)
            let within = (args["ref"] as? String).map { "ref:" + $0 } ?? ""
            Trail.scroll(web, delta: y)
            _ = try await Page.js(web, "window.__copper.scroll(\(Page.quote(within)), \(dx), \(y))")
            try await Task.sleep(nanoseconds: 120_000_000)
            return [.text("Scrolled by \(Int(dx)),\(Int(y)). \(pageLine(tab))")]
        case "browser_get_text":
            let target = (try? locator(args))
            let result = try await Page.js(web, "window.__copper.text(\(Page.quote(target?.script ?? "")))")
            return [.text(Page.render(result))]
        case "browser_console_messages":
            let result = try await Page.js(web, "JSON.stringify(window.__copper.console())")
            return [.text(Page.render(result))]
        case "browser_find":
            guard let text = args["text"] as? String else { throw Failure(text: "text required") }
            let result = try await Page.js(web, "window.__copper.findText(\(Page.quote(text)))")
            return [.text(Page.render(result))]
        default:
            throw Failure(text: "Unknown tool \(name)")
        }
    }

    // MARK: - tabs

    /// The tab this call works on (AgentTabs.target), made ready: awake,
    /// and painting backstage when nobody is looking at it.
    @MainActor
    static func current(_ browser: Browser) throws -> Tab {
        guard let tab = AgentTabs.target(in: browser) else { throw Failure(text: "no active tab") }
        AgentTabs.prepare(tab)
        return tab
    }

    /// Close a tab wherever it is, and let go of it. A Saved tab is put
    /// down, as ⌘W does it — still in Saved, its page let go — and the
    /// answer says so.
    @MainActor
    @discardableResult
    static func close(_ tab: Tab) -> String {
        Backstage.shared.release(tab.id)
        let owner = AgentTabs.owner(of: tab)
        owner.close(tab)
        return owner.tabs.contains { $0.id == tab.id } ? "Closed — it is a Saved tab, so it stays in Saved, unloaded." : "Closed."
    }

    @MainActor
    static func tabList(_ browser: Browser) -> String {
        var lines: [String] = []
        let mine = AgentTabs.target(in: browser)?.id
        var listed = browser.tabs
        // Your tab is listed even when it is in another window or space.
        if let own = AgentTabs.own(), !listed.contains(where: { $0.id == own.id }) { listed.append(own) }
        for (i, tab) in listed.enumerated() {
            var marks: [String] = []
            if AgentTabs.onScreen(tab) { marks.append("on screen") }
            if tab.id == mine { marks.append("yours") }
            let marker = marks.isEmpty ? "" : "(\(marks.joined(separator: ", "))) "
            let index = browser.tabs.contains { $0.id == tab.id } ? "\(i)" : "-"
            let group = Groups.shared.group(of: tab).map { " [\($0.name)]" } ?? ""
            let pin = tab.pin != nil ? " (pinned)" : ""
            // Only a tab that is actually burning gets a figure; the rest stay quiet.
            let heat = Heat.shared.reading(for: tab).flatMap { $0.sustained >= 10 ? " {cpu \(Int($0.sustained))%}" : nil } ?? ""
            lines.append("- \(index): \(marker)[\(tab.title)] (\(tab.address?.absoluteString ?? "about:blank")) {tab \(AgentTabs.short(tab))}\(pin)\(group)\(heat)")
        }
        let gpu = Heat.shared.gpu.flatMap { $0 >= 10 ? "\nGPU process (shared by all tabs): \(Int($0))% of a core" : nil } ?? ""
        return "### Open tabs\n" + lines.joined(separator: "\n") + gpu
    }

    @MainActor
    private static func tabs(_ args: [String: Any], in browser: Browser) async throws -> [Content] {
        let action = (args["action"] as? String) ?? "list"
        let index = args["index"] as? NSNumber
        let focus = (args["focus"] as? Bool) ?? false
        func pick(orScreen: Bool = false) throws -> Tab {
            if let named = try AgentTabs.resolve(args["tab"] ?? index, in: browser) { return named }
            // select with nothing named: the tab the user is looking at.
            if orScreen, let active = browser.active { return active }
            guard let tab = AgentTabs.target(in: browser) else { throw Failure(text: "no active tab") }
            return tab
        }
        // The pane beside the page works on what the user is looking at: a
        // tab it opens is one the user asked to see.
        let pane = AgentTabs.callerKey == "pane"
        switch action {
        case "list":
            return [.text(tabList(browser))]
        case "new":
            let raw = (args["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard let url = raw.map({ Address.url(from: $0) }) ?? URL(string: "about:blank") else {
                throw Failure(text: "not an address: \(raw ?? "")")
            }
            // Behind the user's tab, not in front of it. Unless asked.
            let tab = browser.open(url, foreground: focus || pane)
            AgentTabs.bind(tab)
            AgentTabs.prepare(tab)
            if raw != nil { try await settle(tab) }
            let note = focus || pane ? "Opened and shown to the user." : "Opened in the background — the user's tab did not change; your calls now land on it."
            return [.text("\(note) {tab \(AgentTabs.short(tab))}\n\(pageLine(tab))\n\n\(tabList(browser))")]
        case "close":
            let said = close(try pick())
            return [.text("\(said) \(tabList(browser))")]
        case "select":
            let tab = try pick(orScreen: true)
            AgentTabs.bind(tab)
            if focus || pane { AgentTabs.show(tab) } else { AgentTabs.prepare(tab) }
            let note = focus || pane ? "Selected and shown to the user." : "Selected — your calls now land on this tab; the user's view did not change."
            return [.text("\(note) {tab \(AgentTabs.short(tab))}\n\(tabList(browser))")]
        default:
            throw Failure(text: "action must be list, new, close or select")
        }
    }

    @MainActor
    private static func groups(_ args: [String: Any], in browser: Browser) -> [Content] {
        let action = (args["action"] as? String) ?? "list"
        let groups = Groups.shared
        switch action {
        case "assign":
            guard let tab = AgentTabs.target(in: browser), let name = args["group"] as? String, !name.isEmpty else { return [.text("group name required")] }
            groups.assign(tab, to: groups.create(named: name), in: browser)
            return [.text("Grouped into \(name)")]
        case "remove":
            if let tab = AgentTabs.target(in: browser) { groups.remove(tab) }
            return [.text("Removed from its group")]
        case "list":
            let lines = groups.all.map { g in "- \(g.name): " + groups.members(of: g.id, in: browser).map { "[\($0.title)]" }.joined(separator: ", ") }
            return [.text(lines.isEmpty ? "No groups" : lines.joined(separator: "\n"))]
        default:
            return [.text("action must be list, assign or remove")]
        }
    }

    // MARK: - helpers

    struct Locator {
        /// `ref:e12` or `css:…` — what the page script expects.
        let script: String
        init(ref: String) { script = "ref:" + ref }
        init(css: String) { script = "css:" + css }
    }

    private static func locator(_ args: [String: Any]) throws -> Locator {
        if let ref = args["ref"] as? String, !ref.isEmpty { return Locator(ref: ref) }
        if let css = args["selector"] as? String, !css.isEmpty { return Locator(css: css) }
        throw Failure(text: "ref (from browser_snapshot) or selector required")
    }

    /// The trail's outline over the element a tool is about to act on. The
    /// rect from `Page.prepare` is in view points; the trail draws in the
    /// page's CSS pixels, so the zoom comes back out.
    @MainActor
    static func trail(_ web: WKWebView, _ rect: CGRect, label: String?, operation: String) {
        let z = max(web.pageZoom, 0.01)
        Trail.target(web, rect: ["x": rect.minX / z, "y": rect.minY / z, "w": rect.width / z, "h": rect.height / z],
                     label: label, operation: operation)
    }

    @MainActor
    static func pageLine(_ tab: Tab) -> String {
        let place = AgentTabs.onScreen(tab) ? "" : " (background — not on the user's screen)"
        return "### Page\n- URL: \(tab.address?.absoluteString ?? "about:blank")\n- Title: \(tab.title)\n- Tab: \(AgentTabs.short(tab))\(place)"
    }

    /// Until the page stops loading, plus a beat, or the budget is spent.
    @MainActor
    static func settle(_ tab: Tab, budget: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(budget)
        // Give a navigation a moment to begin before asking whether it's done.
        try await Task.sleep(nanoseconds: 120_000_000)
        while Date() < deadline {
            if !tab.loading { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
