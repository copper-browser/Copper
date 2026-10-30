import AppKit
import SwiftUI
import WebKit

// `./bench --world NAME share …` (Bench.swift's `share` verb):
//
//   share [state]                     live shares, the picker, asks, WebKit's requests and Copper's answers
//   share answer tab ID|window|screen|cancel
//                                     test worlds: answer the open picker, or the next one
//   share keys KEYS                   test worlds: keys pressed on the open picker (↑ ↓ ↩ ⎋ ⌫, letters)
//   share stop [SHARE|all]            as the bar's Stop does
//   share caller on|off               keep the calling page painting while you are elsewhere
//   share occlusion ID on|off         test worlds: a tab's page ignores (on) or notices (off) whether its
//                                     window is covered — a windowed probe behind your own windows can
//                                     still call getDisplayMedia, which wants a visible page
//   share picture window PATH         the window as WindowServer has it — page, column, bars and
//                                     picker — without bringing it forward (an app may always
//                                     picture its own windows)
//   share picture picker|bar PATH [dark]
//                                     the card alone over the page it belongs to: the page's own
//                                     snapshot with the card drawn on it, light or dark
@MainActor
enum TabShareBench {
    static func handle(_ request: [String: Any], in browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        let share = TabShare.shared
        let op = request["op"] as? String ?? "state"
        let words = (request["arg"] as? String ?? "").split(separator: " ").map(String.init)
        switch op {
        case "state", "":
            answer(state(in: browser))
        case "answer":
            guard Store.testing else { answer(["error": "test worlds only"]); return }
            let choice: TabShare.Choice
            switch words.first {
            case "tab":
                guard words.count > 1, let tab = (try? AgentTabs.resolve(words[1], in: browser)) ?? nil else {
                    answer(["error": "share answer tab ID"])
                    return
                }
                choice = .tab(tab.id)
            case "window": choice = .window
            case "screen": choice = .screen
            case "cancel": choice = .cancel
            default:
                answer(["error": "share answer tab ID|window|screen|cancel"])
                return
            }
            if share.picking != nil {
                share.choose(choice)
                answer(["answered": true, "state": state(in: browser)])
            } else {
                TabShareTesting.queue(choice)
                answer(["queued": TabShareTesting.pending])
            }
        case "keys":
            guard Store.testing else { answer(["error": "test worlds only"]); return }
            guard let picking = share.picking else { answer(["error": "no picker is up"]); return }
            let owner = Windows.all.first { ObjectIdentifier($0) == picking.browser } ?? browser
            var pressed: [String] = []
            for key in (request["arg"] as? String ?? "") {
                guard share.picking != nil, let event = event(for: key) else { continue }
                _ = SharePicker.take(event, in: owner)
                pressed.append(String(key))
            }
            answer(["pressed": pressed, "state": state(in: browser)])
        case "stop":
            let target = words.first ?? "all"
            if target == "all" {
                let count = share.shares.count
                share.stopAll(reason: "stopped from the bench")
                answer(["stopped": count])
            } else if let live = share.shares.first(where: { $0.id.hasPrefix(target) }) {
                share.stop(live.id, reason: "stopped from the bench")
                answer(["stopped": 1])
            } else {
                answer(["error": "no share \(target)"])
            }
        case "occlusion":
            guard Store.testing else { answer(["error": "test worlds only"]); return }
            guard words.count >= 2, let tab = (try? AgentTabs.resolve(words[0], in: browser)) ?? nil, let web = tab.built else {
                answer(["error": "share occlusion ID on|off"])
                return
            }
            Backstage.ignoreOcclusion(web, words[1] == "on")
            answer(["ignoresOcclusion": web.headlessIgnoresOcclusion ?? NSNull()])
        case "caller":
            share.keepsCallerPainting = words.first != "off"
            answer(["keepsCallerPainting": share.keepsCallerPainting])
        case "picture":
            if words.first == "window", words.count >= 2 {
                answer(window(of: browser, to: words[1]))
                return
            }
            guard words.count >= 2 else { answer(["error": "share picture window|picker|bar PATH [dark]"]); return }
            picture(words[0], path: words[1], dark: words.dropFirst(2).contains("dark"), in: browser, answer: answer)
        default:
            answer(["error": "share state|answer|keys|stop|caller|occlusion|picture"])
        }
    }

    private static func state(in browser: Browser) -> [String: Any] {
        var out = TabShare.shared.report
        out["queuedAnswers"] = TabShareTesting.pending
        out["mockDevices"] = TabShareTesting.mock
        out["pid"] = Int(getpid())
        out["processes"] = TabShare.shared.shares.map { live -> [String: Any] in
            func pid(_ object: NSObject?, _ name: String) -> Int {
                guard let object, object.responds(to: NSSelectorFromString(name)), let n = object.value(forKey: name) as? NSNumber else { return 0 }
                return n.intValue
            }
            let source = AgentTabs.find(live.source)?.built
            return ["share": live.id, "sourceWebPID": pid(source, "_webProcessIdentifier"),
                    "consumerWebPID": pid(live.consumerView, "_webProcessIdentifier"), "gpuPID": pid(source, "_gpuProcessIdentifier")]
        }
        return out
    }

    /// One key as the picker hears it.
    private static func event(for key: Character) -> NSEvent? {
        let codes: [Character: (UInt16, String)] = ["↓": (125, "\u{F701}"), "↑": (126, "\u{F700}"), "↩": (36, "\r"), "⎋": (53, "\u{1B}"),
                                                    "⌫": (51, "\u{7F}"), "⇥": (48, "\t")]
        let (code, text) = codes[key] ?? (0, String(key))
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                                isARepeat: false, keyCode: code)
    }

    // MARK: - pictures

    private static func picture(_ which: String, path: String, dark: Bool, in browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        let share = TabShare.shared
        let scheme: ColorScheme = dark ? .dark : .light
        let card: AnyView
        let page: Tab?
        let top: Bool
        switch which {
        case "picker":
            guard let picking = share.picking else { answer(["error": "no picker is up"]); return }
            card = AnyView(SharePickerCard(picking: picking, query: share.query, highlighted: share.highlighted, rows: share.rows,
                                           tint: Spaces.shared.space(in: browser).tint, scheme: scheme, stamp: 0, scrolls: false) { _ in }
                .frame(width: SharePicker.width))
            page = picking.caller.flatMap { AgentTabs.find($0) } ?? browser.active
            top = true
        case "bar":
            guard let live = share.shares.first, let tab = AgentTabs.find(live.source) else { answer(["error": "nothing is shared"]); return }
            card = AnyView(ShareCapsule(tab: tab, host: live.host, show: {}, stop: {}))
            page = browser.active
            top = false
        default:
            answer(["error": "share picture picker|bar PATH [dark]"])
            return
        }
        guard let cardImage = hosted(card, dark: dark) else { answer(["error": "the card did not draw"]); return }
        guard let web = page?.built else {
            write(cardImage, to: path, answer: answer)
            return
        }
        web.takeSnapshot(with: nil) { image, _ in
            MainActor.assumeIsolated {
                guard let base = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    write(cardImage, to: path, answer: answer)
                    return
                }
                let scale = CGFloat(base.width) / max(1, web.bounds.width)
                let width = base.width, height = base.height
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
                if top {
                    // The page dimmed behind the card, as in the window.
                    context.setFillColor(NSColor.black.withAlphaComponent(0.16).cgColor)
                    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                }
                // The card was drawn at 2× in its own margin (shadow room).
                let w = CGFloat(cardImage.width) / 2 * scale, h = CGFloat(cardImage.height) / 2 * scale
                let x = (CGFloat(width) - w) / 2
                let y = top ? CGFloat(height) - CGFloat(height) * 0.22 - h + 40 * scale : 30 * scale - 40 * scale
                context.draw(cardImage, in: CGRect(x: x, y: y, width: w, height: h))
                guard let made = context.makeImage() else { return }
                write(made, to: path, answer: answer)
            }
        }
    }

    /// The card at 2×, with 40 pt of margin for its shadow.
    private static func hosted(_ view: AnyView, dark: Bool) -> CGImage? {
        let renderer = ImageRenderer(content: view.padding(40).environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 2
        return renderer.cgImage
    }

    /// The browser window's pixels, from WindowServer, as Swipes and the
    /// calendar card picture theirs: nothing is brought forward.
    private static func window(of browser: Browser, to path: String) -> [String: Any] {
        guard let window = Windows.window(of: browser) else { return ["error": "no window"] }
        guard let image = WindowPicture.of(window) else { return ["error": "no image"] }
        var out: [String: Any] = ["frame": NSStringFromRect(window.frame)]
        write(image, to: path) { out.merge($0) { _, new in new } }
        return out
    }

    private static func write(_ image: CGImage, to path: String, answer: @escaping ([String: Any]) -> Void) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { answer(["error": "no png"]); return }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { answer(["error": "\(error)"]); return }
        answer(["path": path, "size": [image.width, image.height]])
    }
}

/// CGWindowListCreateImage is deprecated for ScreenCaptureKit, which asks for
/// Screen Recording even to picture your own window; an app's own windows
/// are still its to read this way, as Swipes and the calendar card do. Looked
/// up by name so the bench alone carries it, and the build no warning.
private enum WindowPicture {
    private typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    static func of(_ window: NSWindow) -> CGImage? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil } // RTLD_DEFAULT
        let create = unsafeBitCast(symbol, to: Create.self)
        let options: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
        return create(.null, CGWindowListOption.optionIncludingWindow.rawValue, CGWindowID(window.windowNumber), options.rawValue)?
            .takeRetainedValue()
    }
}
