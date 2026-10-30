import AppKit
import AVFoundation
import SwiftUI
import WebKit

// Fork (page-capture): `./bench --world W privacy capture …` — the camera and
// microphone desk from the shell (docs/capture.md › Checking it).
//
//   state                         what is asked, kept, and allowed; each watched tab's capture
//                                 (none|active|muted), where its view is (stage|room|none|other)
//                                 and whether it is being kept seen; macOS's answers
//   deny | show                   the bar's buttons, as clicked
//   dismiss | reload              the macOS bar's Not now; once macOS allows it, Reload
//   forget                        Settings › Privacy › Forget choices
// Test worlds only — what lets a page hear or see you is yours to click, and
// the bench is any script of yours (as `key` is, for typing into a page):
//   allow                         the bar's Allow
//   undo                          the refusal bar's Allow and reload
//   resume                        the paused bar's Use it here
//   keep on|off                   keep a call's page seen off stage (default on)
//   seed ask|refused|system|restricted|restored|paused|none [microphone|camera|both] [SITE]
//                                 the bar in a state, for pictures (nothing is answered)
//   render PATH [dark]            the bar as it is, drawn off screen to a PNG
//   seen on|off                   the window's pages count as seen though it is covered, and back
//   park on|off                   the window moved off every display (covered), and back
//   minimize on|off               the window minimised, and back
@MainActor
enum CaptureBench {
    static func handle(_ arg: String, in browser: Browser) -> [String: Any] {
        let words = arg.split(separator: " ").map(String.init)
        let op = words.first ?? "state"
        let desk = browser.capture
        let testOnly = ["allow", "undo", "resume", "keep", "seed", "render", "park", "minimize", "seen"]
        if testOnly.contains(op), !Store.testing { return ["error": "privacy capture \(op) only works in a test world"] }
        switch op {
        case "state": break
        case "allow": desk.allow()
        case "deny": desk.deny()
        case "show": desk.showAsker()
        case "undo": desk.allowRefused()
        case "dismiss": desk.dismissSystem()
        case "reload": desk.reloadRestored()
        case "resume": desk.resumePaused()
        case "forget": browser.forgetCaptureChoices()
        case "keep":
            Store.settings.set(words.dropFirst().first != "off", forKey: "capture.keep")
        case "seed":
            let devices: CaptureDevices = {
                switch words.count > 2 ? words[2] : "microphone" {
                case "camera": return .camera
                case "both": return .both
                default: return .microphone
                }
            }()
            let site = words.count > 3 ? words[3] : "meet.google.com"
            switch words.count > 1 ? words[1] : "none" {
            case "ask": desk.seed(.ask(CaptureQuestion(site: site, devices: devices, tab: nil, settles: 1)))
            case "refused": desk.seed(.refused(site: site, devices: devices))
            case "system": desk.seed(.system(devices, restricted: false))
            case "restricted": desk.seed(.system(devices, restricted: true))
            case "restored": desk.seed(.restored(devices))
            case "paused": desk.seed(.paused(site: site, devices: devices, tab: UUID()))
            default: desk.seed(nil)
            }
        case "render":
            guard words.count > 1 else { return ["error": "privacy capture render PATH [dark]"] }
            return render(desk.bar, to: words[1], dark: words.contains("dark"))
        case "seen":
            // A probe window sits behind the windows of whoever is at the
            // Mac, covered, and WebKit counts its pages hidden — a page that
            // asks for the microphone then waits to be seen. `seen on` has
            // every page in the window ignore that, as if the window were in
            // front; `seen off` gives occlusion back (a kept call excepted).
            let on = words.dropFirst().first != "off"
            for tab in AgentTabs.all {
                guard let web = tab.built, web.window != nil, !Room.holds(web), !CaptureCalls.shared.keeps(web) else { continue }
                web.detectsOcclusion(!on)
                if let window = web.window {
                    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
                }
            }
        case "park", "minimize":
            guard let window = Windows.window(of: browser) else { return ["error": "no window"] }
            let on = words.dropFirst().first != "off"
            if op == "minimize" {
                if on { window.miniaturize(nil) } else { window.deminiaturize(nil) }
            } else if on {
                if parkedFrom == nil { parkedFrom = window.frame }
                window.setFrameOrigin(Parking.origin(for: window.frame.size))
            } else if let frame = parkedFrom {
                window.setFrame(frame, display: true)
                parkedFrom = nil
            }
        default:
            return ["error": "privacy capture state|allow|deny|show|undo|dismiss|reload|resume|forget|keep on|off|seed …|render PATH|seen on|off|park on|off|minimize on|off"]
        }
        return state(browser)
    }

    /// Where the window was before `park on`.
    private static var parkedFrom: NSRect?

    static func state(_ browser: Browser) -> [String: Any] {
        let desk = browser.capture
        var tabs: [[String: Any]] = []
        for tab in AgentTabs.all {
            guard let web = tab.built else { continue }
            let report = CaptureCalls.shared.report(web)
            guard report["watched"] as? Bool == true || CaptureCalls.onCall(web) else { continue }
            var line: [String: Any] = [
                "id": AgentTabs.short(tab),
                "host": tab.address?.host() ?? "",
                "selected": Windows.all.contains { $0.activeID == tab.id },
                "microphone": name(web.microphoneCaptureState),
                "camera": name(web.cameraCaptureState),
                "view": place(web),
            ]
            line.merge(report) { a, _ in a }
            if let window = web.window {
                line["windowVisible"] = window.isVisible
                line["windowOccluded"] = !window.occlusionState.contains(.visible)
                line["windowMinimised"] = window.isMiniaturized
            }
            tabs.append(line)
        }
        var out: [String: Any] = [
            "bar": describe(desk.bar),
            "waiting": desk.waiting,
            "allowed": CaptureBook.choices.encoded,
            "mock": CaptureSystem.mock,
            "keep": CaptureCalls.on,
            "kept": CaptureCalls.shared.keptCount,
            "watching": CaptureCalls.shared.watchingCount,
            "macOS": ["microphone": name(CaptureSystem.status(.microphone)), "camera": name(CaptureSystem.status(.camera))],
            "tabs": tabs,
        ]
        if let window = Windows.window(of: browser) {
            out["window"] = ["visible": window.isVisible, "occluded": !window.occlusionState.contains(.visible),
                             "minimised": window.isMiniaturized, "onAScreen": Parking.intersectsAScreen(window.frame)]
        }
        return out
    }

    private static func place(_ web: WKWebView) -> String {
        guard let window = web.window else { return "none" }
        if Room.holds(web) { return "room" }
        if Windows.isBrowserWindow(window) { return "stage" }
        return "other"
    }

    private static func describe(_ bar: CaptureDesk.Bar?) -> Any {
        switch bar {
        case nil: return NSNull()
        case let .ask(question)?:
            return ["kind": "ask", "site": question.site, "devices": question.devices.names, "settles": question.settles,
                    "tab": question.tab.map { String($0.uuidString.prefix(8)).lowercased() } ?? NSNull()]
        case let .refused(site, devices)?:
            return ["kind": "refused", "site": site, "devices": devices.names]
        case let .system(devices, restricted)?:
            return ["kind": "system", "devices": devices.names, "restricted": restricted]
        case let .restored(devices)?:
            return ["kind": "restored", "devices": devices.names]
        case let .paused(site, devices, tab)?:
            return ["kind": "paused", "site": site, "devices": devices.names, "tab": String(tab.uuidString.prefix(8)).lowercased()]
        }
    }

    private static func name(_ state: WKMediaCaptureState) -> String {
        switch state {
        case .none: return "none"
        case .active: return "active"
        case .muted: return "muted"
        @unknown default: return "unknown"
        }
    }

    private static func name(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    /// The bar as it stands, on the window's wash, drawn without a window.
    private static func render(_ bar: CaptureDesk.Bar?, to path: String, dark: Bool) -> [String: Any] {
        guard let bar else { return ["error": "no bar — seed one first"] }
        let view = CaptureBarView(bar: bar, elsewhere: false) { _ in }
            .padding(24)
            .background(Palette.wash)
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return ["error": "no image"] }
        host.cacheDisplay(in: host.bounds, to: picture)
        guard let png = picture.representation(using: .png, properties: [:]) else { return ["error": "no png"] }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { return ["error": "\(error)"] }
        return ["path": path, "size": [picture.pixelsWide, picture.pixelsHigh]]
    }
}
