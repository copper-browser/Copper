import AppKit
import SwiftUI
import WebKit

// Fork (ardia: automation): AppleScript. The dictionary is Fork/Copper.sdef, in
// Chrome's and Arc's words, so the Raycast and Alfred scripts written for them
// work here unchanged:
//
//   tell application "Copper"
//     get URL of active tab of front window
//     tell front window to make new tab with properties {URL:"https://example.com"}
//     set active tab index of front window to 2
//     close tab 3 of front window
//     execute active tab of front window javascript "document.title"
//   end tell
//
// A window is a browser window (never a room Copper parks pages in, a panel or
// Settings), front first; its tabs are the row it shows, pins first, as
// `browser.tabs` has them. JavaScript runs only with View › Allow JavaScript
// from Apple Events on (`Scripting.allowsJavaScript`), off by default as in
// Safari and Chrome: any app this Mac lets send Copper events could otherwise
// read every signed-in page.
//
// Apple events arrive on the main thread; these objects hand every call to
// the main actor (`onMain`).

enum Scripting {
    /// View › Allow JavaScript from Apple Events.
    static let javaScriptKey = "appleEvents.javascript"
    static var allowsJavaScript: Bool { Store.settings.bool(forKey: javaScriptKey) }

    /// The browser windows a script sees, the one in front first.
    @MainActor static var browsers: [Browser] {
        let shown = Windows.all.filter { browser in
            // The first window closed with its red button stays in `all`; a
            // headless world's is parked, and counts.
            guard browser.primary, !Headless.on else { return true }
            guard let window = Windows.window(of: browser) else { return false }
            return window.isVisible || window.isMiniaturized
        }
        let front = Windows.current
        return shown.filter { $0 === front } + shown.filter { $0 !== front }
    }

    static func fail(_ command: NSScriptCommand?, _ number: some BinaryInteger, _ text: String) {
        command?.scriptErrorNumber = Int(number)
        command?.scriptErrorString = text
    }

    /// A value from a page, as AppleScript holds it: text, a number, true or
    /// false, a list of those, missing value; anything else as its JSON. A
    /// descriptor, because Cocoa can't turn a plain string into type `any`.
    static func descriptor(_ value: Any?) -> NSAppleEventDescriptor {
        switch value {
        case nil, is NSNull: return .null()
        case let text as String: return NSAppleEventDescriptor(string: text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return NSAppleEventDescriptor(boolean: number.boolValue) }
            if let whole = Int32(exactly: number.doubleValue) { return NSAppleEventDescriptor(int32: whole) }
            return NSAppleEventDescriptor(double: number.doubleValue)
        case let list as [Any] where list.allSatisfy({ $0 is String || $0 is NSNumber }):
            let out = NSAppleEventDescriptor.list()
            for (i, item) in list.enumerated() { out.insert(descriptor(item), at: i + 1) }
            return out
        case let some?:
            guard JSONSerialization.isValidJSONObject(some), let data = try? JSONSerialization.data(withJSONObject: some),
                  let json = String(data: data, encoding: .utf8) else { return NSAppleEventDescriptor(string: "\(some)") }
            return NSAppleEventDescriptor(string: json)
        }
    }
}

/// View › Allow JavaScript from Apple Events.
struct AppleEventsJavaScriptItem: View {
    @AppStorage(Scripting.javaScriptKey, store: Store.settings) private var allowed = false
    var body: some View { Toggle("Allow JavaScript from Apple Events", isOn: $allowed) }
}

/// Runs main-actor work from an Apple event handler, which is on the main
/// thread already, and hands its answer back.
private func onMain<T>(_ body: @MainActor () -> T) -> T {
    nonisolated(unsafe) var out: T?
    MainActor.assumeIsolated { out = body() }
    return out!
}

extension NSApplication {
    /// The dictionary's `window` elements (Copper.sdef: scriptWindows).
    @objc var scriptWindows: [ScriptWindow] {
        onMain { Scripting.browsers.map { ScriptWindow($0) } }
    }

    @objc func valueInScriptWindowsWithUniqueID(_ id: Any) -> ScriptWindow? {
        scriptWindows.first { $0.uniqueID == "\(id)" }
    }

    /// `make new window [with properties {URL:…}]`: a ⌘N window.
    @objc func insertInScriptWindows(_ window: ScriptWindow) {
        onMain {
            guard let browser = Windows.newWindow() else {
                Scripting.fail(NSScriptCommand.current(), errAEEventFailed, "Copper can't open a window right now.")
                return
            }
            window.browser = browser
            if let url = window.pendingURL { browser.arrive(url) }
        }
    }

    @objc(insertObject:inScriptWindowsAtIndex:)
    func insert(_ window: ScriptWindow, inScriptWindowsAt index: Int) { insertInScriptWindows(window) }
}

@objc(CopperScriptWindow)
final class ScriptWindow: NSObject {
    weak var browser: Browser?
    /// `make new window with properties {URL:…}`, until the window exists.
    var pendingURL: URL?

    override init() { super.init() }
    init(_ browser: Browser) {
        self.browser = browser
        super.init()
    }

    @objc var uniqueID: String { onMain { browser?.windowID?.uuidString ?? "main" } }
    @objc var name: String { onMain { browser?.active?.label ?? "" } }
    /// Hidden in the dictionary: what `make new window with properties
    /// {URL:…}` sets, and the active tab's address after that.
    @objc(URL) var address: String {
        get { onMain { browser?.active?.address?.absoluteString ?? pendingURL?.absoluteString ?? "" } }
        set {
            guard let url = URL(string: newValue), let scheme = url.scheme, scheme.lowercased() != "javascript" else {
                Scripting.fail(NSScriptCommand.current(), errAECoercionFail, "“\(newValue)” isn't an address.")
                return
            }
            onMain {
                guard let browser else { pendingURL = url; return }
                if let active = browser.active { active.go(to: url) } else { browser.arrive(url) }
            }
        }
    }
    @objc var orderedIndex: Int { onMain { (Scripting.browsers.firstIndex { $0 === browser } ?? -1) + 1 } }

    @objc var tabs: [ScriptTab] {
        onMain { (browser?.tabs ?? []).map { ScriptTab($0, in: browser) } }
    }

    @objc func valueInTabsWithUniqueID(_ id: Any) -> ScriptTab? {
        tabs.first { $0.uniqueID == "\(id)" }
    }

    @objc var activeTab: ScriptTab? {
        onMain { browser?.active.map { ScriptTab($0, in: browser) } }
    }

    @objc var activeTabIndex: Int {
        get { onMain { (browser.flatMap { b in b.tabs.firstIndex { $0.id == b.activeID } } ?? -1) + 1 } }
        set {
            onMain {
                guard let browser, browser.tabs.indices.contains(newValue - 1) else {
                    Scripting.fail(NSScriptCommand.current(), errAENoSuchObject, "There is no tab \(newValue) in this window.")
                    return
                }
                browser.select(index: newValue - 1)
            }
        }
    }

    /// `make new tab at end of tabs of window 1 with properties {URL:…}`, and
    /// `tell window 1 to make new tab`.
    @objc(insertObject:inTabsAtIndex:)
    func insert(_ tab: ScriptTab, inTabsAt index: Int) {
        onMain {
            guard let browser else { return }
            let made: Tab
            if let url = tab.pendingURL {
                made = browser.open(url, foreground: true, atEnd: true)
            } else {
                browser.newTab()
                guard let active = browser.active else { return }
                made = active
            }
            // Where the script asked, when it asked for somewhere in the row.
            if index < browser.tabs.count - 1, browser.tabs.last?.id == made.id { browser.move(made, to: max(index, browser.pinnedCount)) }
            tab.tab = made
            tab.browser = browser
        }
    }

    @objc func insertInTabs(_ tab: ScriptTab) {
        insert(tab, inTabsAt: onMain { browser?.tabs.count ?? 0 })
    }

    @objc func handleCloseScriptCommand(_ command: NSCloseCommand) -> Any? {
        onMain {
            guard let browser, let window = Windows.window(of: browser) else { return }
            window.performClose(nil)
        }
        return nil
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let app = NSScriptClassDescription(for: NSApplication.self) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: app, containerSpecifier: nil, key: "scriptWindows", uniqueID: uniqueID)
    }
}

@objc(CopperScriptTab)
final class ScriptTab: NSObject {
    weak var tab: Tab?
    weak var browser: Browser?
    /// `make new tab with properties {URL:…}`, until the tab exists.
    var pendingURL: Foundation.URL?

    override init() { super.init() }
    init(_ tab: Tab, in browser: Browser?) {
        self.tab = tab
        self.browser = browser
        super.init()
    }

    @objc var uniqueID: String { onMain { tab?.id.uuidString ?? "" } }
    @objc var title: String { onMain { tab?.label ?? "" } }
    @objc var loading: Bool { onMain { tab?.loading ?? false } }

    @objc(URL) var address: String {
        get { onMain { tab?.address?.absoluteString ?? pendingURL?.absoluteString ?? "" } }
        set {
            let command = NSScriptCommand.current()
            guard let url = Foundation.URL(string: newValue), url.scheme != nil else {
                Scripting.fail(command, errAECoercionFail, "“\(newValue)” isn't an address.")
                return
            }
            // A javascript: address runs in the page: the same switch as execute.
            if url.scheme?.lowercased() == "javascript" {
                guard Scripting.allowsJavaScript else {
                    Scripting.fail(command, errAEPrivilegeError, ScriptTab.javaScriptOff)
                    return
                }
                let source = String(newValue.dropFirst("javascript:".count)).removingPercentEncoding ?? ""
                onMain { tab?.web.evaluateJavaScript(source, completionHandler: nil) }
                return
            }
            onMain {
                guard let tab else { pendingURL = url; return }
                tab.go(to: url)
            }
        }
    }

    static let javaScriptOff = "Running JavaScript from AppleScript is turned off. Turn on View › Allow JavaScript from Apple Events in Copper."

    @objc func handleCloseScriptCommand(_ command: NSCloseCommand) -> Any? {
        onMain {
            guard let tab, let browser = browser ?? Windows.owner(of: tab) else { return }
            browser.close(tab)
        }
        return nil
    }

    @objc func handleSelectScriptCommand(_ command: NSScriptCommand) -> Any? {
        onMain {
            guard let tab, let browser = browser ?? Windows.owner(of: tab) else { return }
            browser.select(tab)
        }
        return nil
    }

    /// `execute TAB javascript "…"`: the page's answer, once it has given it.
    @objc func handleExecuteScriptCommand(_ command: NSScriptCommand) -> Any? {
        guard Scripting.allowsJavaScript else {
            Scripting.fail(command, errAEPrivilegeError, ScriptTab.javaScriptOff)
            return nil
        }
        guard let source = command.evaluatedArguments?["javascript"] as? String else {
            Scripting.fail(command, errAEParamMissed, "execute needs javascript \"…\".")
            return nil
        }
        let ready: String? = onMain {
            guard let tab else { return "That tab is gone." }
            if tab.asleep { return "That tab is asleep. Select it first, then run the script." }
            if tab.isBlank { return "That tab has no page." }
            return nil
        }
        if let ready {
            Scripting.fail(command, errAEEventFailed, ready)
            return nil
        }
        // Answered before the event returns, as Safari's do JavaScript is: the
        // page's reply comes in on the main run loop, turned here until it
        // does. (Suspending the event instead crashed one sent from inside
        // Copper, whose event can't wait.)
        final class Reply { var done = false, value: NSAppleEventDescriptor?, failure: String? }
        let reply = Reply()
        onMain {
            tab?.web.evaluateJavaScript(source) { value, error in
                if let error {
                    // A script that ran and returned nothing WebKit can carry
                    // (a function, a Promise) is an answer of nothing, not a failure.
                    let nothing = (error as NSError).code == WKError.javaScriptResultTypeIsUnsupported.rawValue
                    if !nothing { reply.failure = error.localizedDescription }
                } else {
                    reply.value = Scripting.descriptor(value)
                }
                reply.done = true
            }
        }
        let limit = Date().addingTimeInterval(30)
        while !reply.done, Date() < limit { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        guard reply.done else {
            Scripting.fail(command, errAEEventFailed, "The page didn't answer within 30 seconds.")
            return nil
        }
        if let failure = reply.failure { Scripting.fail(command, errAEEventFailed, failure) }
        return reply.value
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        let window: ScriptWindow? = onMain {
            guard let tab, let browser = browser ?? Windows.owner(of: tab) else { return nil }
            return ScriptWindow(browser)
        }
        guard let container = window?.objectSpecifier,
              let description = NSScriptClassDescription(for: ScriptWindow.self) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: description, containerSpecifier: container,
                                   key: "tabs", uniqueID: uniqueID)
    }
}

// MARK: - the bench

extension Scripting {
    /// `script run SRC` runs `osascript -e SRC` as a child of this Copper: an
    /// Apple Event from another process, as Raycast sends one (over ssh, an
    /// osascript of its own waits on a consent prompt nobody can see).
    /// `script here SRC` runs it through NSAppleScript in this process.
    /// `script allow on|off` is View › Allow JavaScript from Apple Events.
    @MainActor static func bench(_ request: [String: Any], answer: @escaping ([String: Any]) -> Void) {
        let op = request["op"] as? String ?? ""
        let source = request["arg"] as? String ?? ""
        switch op {
        case "allow":
            Store.settings.set(source != "off", forKey: javaScriptKey)
            answer(["allowed": allowsJavaScript])
        case "here":
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            answer(["result": result.map { text($0) as Any } ?? NSNull(), "message": error?[NSAppleScript.errorMessage] ?? NSNull(), // not "error": bench prints that and stops
                    "number": error?[NSAppleScript.errorNumber] ?? NSNull()])
        case "run":
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.terminationHandler = { done in
                let said = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let complaint = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let status = done.terminationStatus
                DispatchQueue.main.async {
                    answer(["out": said.trimmingCharacters(in: .whitespacesAndNewlines),
                            "err": complaint.trimmingCharacters(in: .whitespacesAndNewlines), "status": Int(status)])
                }
            }
            do { try process.run() } catch { answer(["error": "\(error)"]); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { if process.isRunning { process.terminate() } }
        default:
            answer(["error": "script run|here SRC, script allow on|off"])
        }
    }

    /// A reply as osascript prints it, near enough: lists joined with ", ".
    private static func text(_ reply: NSAppleEventDescriptor) -> String {
        guard reply.descriptorType == typeAEList else { return reply.stringValue ?? "" }
        return (0..<reply.numberOfItems).map { reply.atIndex($0 + 1).map(text) ?? "" }.joined(separator: ", ")
    }
}
