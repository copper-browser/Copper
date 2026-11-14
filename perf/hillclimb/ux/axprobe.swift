// AX probe: a real accessibility client for the key-window run (B13). It runs as a LaunchAgent in the
// GUI session (gui/UID), so TCC judges *this* app (dev.hc.axprobe), not sshd; it needs the
// Accessibility grant once (NEEDS-COLLIN.md). ux/ax.py builds it, starts it and talks to it.
//
// One JSON request per connection on ~/hc/axprobe/ax.sock, one JSON line back:
//   {"do":"status"}                 trusted, screen locked, front app, Reduce Motion, full keyboard access
//   {"do":"tree","pid":N}           every element of every window of N: role, subrole, name parts, frame, focused
//   {"do":"focused","pid":N}        the element that has the keyboard (AXFocusedUIElement)
//   {"do":"raise","pid":N}          make N frontmost and its main window key (AXFrontmost, AXRaise)
//   {"do":"key","key":"tab","mods":["shift"]}   a real key press posted at the HID tap (needs the grant)
//   {"do":"quit"}
import AppKit
import ApplicationServices

let home = FileManager.default.homeDirectoryForCurrentUser.path
let sockPath = CommandLine.arguments.dropFirst().first ?? "\(home)/hc/axprobe/ax.sock"

// Registers the app in Settings › Privacy & Security › Accessibility (off) so the grant is one toggle.
_ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}

func str(_ e: AXUIElement, _ name: String) -> String? {
    guard let v = attr(e, name) else { return nil }
    if let s = v as? String { return s.isEmpty ? nil : String(s.prefix(120)) }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}

func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}

/// One element as JSON; `origin` = its window's top-left (screen, top-left origin), so frames are window points.
func describe(_ e: AXUIElement, origin: CGPoint, depth: Int) -> [String: Any] {
    var d: [String: Any] = ["depth": depth]
    for (k, a) in [("role", kAXRoleAttribute), ("subrole", kAXSubroleAttribute), ("title", kAXTitleAttribute),
                   ("description", kAXDescriptionAttribute), ("value", kAXValueAttribute), ("help", kAXHelpAttribute),
                   ("identifier", kAXIdentifierAttribute), ("roleDescription", kAXRoleDescriptionAttribute),
                   ("placeholder", kAXPlaceholderValueAttribute)] {
        if let s = str(e, a) { d[k] = s }
    }
    if let f = frame(e) {
        d["frame"] = [f.minX - origin.x, f.minY - origin.y, f.width, f.height].map { Double(($0 * 10).rounded() / 10) }
    }
    if let b = attr(e, kAXEnabledAttribute) as? Bool { d["enabled"] = b }
    if let b = attr(e, kAXFocusedAttribute) as? Bool, b { d["focused"] = true }
    // What VoiceOver reads first: the label (description), else the title, else a titled child's text.
    if let t = attr(e, kAXTitleUIElementAttribute), CFGetTypeID(t) == AXUIElementGetTypeID() {
        d["titleElement"] = str(t as! AXUIElement, kAXValueAttribute) ?? str(t as! AXUIElement, kAXTitleAttribute)
    }
    return d
}

func tree(_ pid: pid_t, limit: Int = 6000) -> [String: Any] {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 3)
    // Asks AppKit/SwiftUI for the full tree, as VoiceOver does (harmless for native apps).
    AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    let windows = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    var out: [[String: Any]] = []
    var count = 0
    for (wi, w) in windows.enumerated() {
        let origin = frame(w)?.origin ?? .zero
        var els: [[String: Any]] = []
        var stack: [(AXUIElement, Int)] = [(w, 0)]
        while count < limit, let top = stack.popLast() {
            let (e, depth) = top
            var d = describe(e, origin: origin, depth: depth)
            d["i"] = els.count
            els.append(d)
            count += 1
            if depth < 60, let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] {
                stack.append(contentsOf: kids.reversed().map { ($0, depth + 1) })
            }
        }
        out.append(["index": wi, "title": str(w, kAXTitleAttribute) ?? "", "subrole": str(w, kAXSubroleAttribute) ?? "",
                    "main": (attr(w, kAXMainAttribute) as? Bool) ?? false, "frame": frame(w).map { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) } ?? [Double](),
                    "elements": els])
    }
    return ["windows": out, "count": count, "truncated": count >= limit]
}

func focused(_ pid: pid_t) -> [String: Any] {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 3)
    guard let f = attr(app, kAXFocusedUIElementAttribute), CFGetTypeID(f) == AXUIElementGetTypeID() else { return ["focused": NSNull()] }
    let e = f as! AXUIElement
    var win: AnyObject?
    AXUIElementCopyAttributeValue(e, kAXWindowAttribute as CFString, &win)
    let origin = win.flatMap { frame($0 as! AXUIElement)?.origin } ?? .zero
    return ["focused": describe(e, origin: origin, depth: 0)]
}

func screenLocked() -> Bool? {
    guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
    return (d["CGSSessionScreenIsLocked"] as? Bool) ?? false
}

let keyCodes: [String: CGKeyCode] = ["tab": 48, "escape": 53, "return": 36, "space": 49, "down": 125, "up": 126,
                                     "left": 123, "right": 124, "k": 40, "t": 17, "l": 37, ",": 43]

func handle(_ req: [String: Any]) -> [String: Any] {
    let pid = pid_t(req["pid"] as? Int ?? 0)
    switch req["do"] as? String ?? "" {
    case "status":
        let front = NSWorkspace.shared.frontmostApplication
        return ["trusted": AXIsProcessTrusted(), "locked": screenLocked() ?? NSNull(), "front": front?.localizedName ?? "",
                "frontPid": front?.processIdentifier ?? 0, "pid": getpid(),
                "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                "fullKeyboardAccess": NSApplication.shared.isFullKeyboardAccessEnabled]
    case "tree": return tree(pid)
    case "focused": return focused(pid)
    case "raise":
        let app = AXUIElementCreateApplication(pid)
        let a = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let w = attr(app, kAXMainWindowAttribute) ?? (attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first {
            AXUIElementPerformAction(w as! AXUIElement, kAXRaiseAction as CFString)
        }
        NSRunningApplication(processIdentifier: pid)?.activate()
        usleep(300_000)
        return ["frontmost": a == .success, "front": NSWorkspace.shared.frontmostApplication?.processIdentifier == pid]
    case "key":
        guard AXIsProcessTrusted() else { return ["error": "not trusted (Accessibility grant: NEEDS-COLLIN.md)"] }
        guard let name = req["key"] as? String, let code = keyCodes[name] else { return ["error": "key: one of \(keyCodes.keys.sorted())"] }
        var flags: CGEventFlags = []
        for m in req["mods"] as? [String] ?? [] {
            flags.insert(["shift": .maskShift, "cmd": .maskCommand, "ctrl": .maskControl, "alt": .maskAlternate][m] ?? [])
        }
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            ev?.flags = flags
            ev?.post(tap: .cghidEventTap)
            usleep(20_000)
        }
        return ["posted": name]
    case "quit": exit(0)
    default: return ["error": "do: status|tree|focused|raise|key|quit"]
    }
}

// The socket: one request line per connection, answered on a background thread (AX calls are synchronous IPC).
unlink(sockPath)
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutableBytes(of: &addr.sun_path) { p in sockPath.utf8CString.withUnsafeBytes { p.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(p.count - 1))) } }
guard withUnsafePointer(to: &addr, { bind(fd, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self), socklen_t(MemoryLayout<sockaddr_un>.size)) }) == 0,
      listen(fd, 8) == 0 else { fatalError("can't listen on \(sockPath)") }
Thread.detachNewThread {
    while true {
        let c = accept(fd, nil, nil)
        guard c >= 0 else { continue }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while !data.contains(10) {
            let n = read(c, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        let req = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        var reply = (try? JSONSerialization.data(withJSONObject: handle(req))) ?? Data("{\"error\":\"bad reply\"}".utf8)
        reply.append(10)
        _ = reply.withUnsafeBytes { write(c, $0.baseAddress, reply.count) }
        close(c)
    }
}
NSApplication.shared.setActivationPolicy(.prohibited)  // no Dock icon, never takes focus itself
NSApplication.shared.run()
