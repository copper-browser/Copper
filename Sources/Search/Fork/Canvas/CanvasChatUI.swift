import AppKit
import SwiftUI
import UserNotifications

// What chat shows outside the canvas page (CanvasChat.swift has the state):
// the mention pill at the window's foot, drawn over the panels like the
// invite pill and stacked with it (CanvasInviteBar); the macOS notification
// when Copper isn't the app in front; the `canvas_chat` tool; and the bench.

// MARK: - the pill

/// "<who> mentioned you in “<canvas>” — ‘<excerpt>’  Open  ×" (or "assigned you", with the row as the excerpt).
struct CanvasMentionPill: View {
    let mention: CanvasChat.Mention
    @ObservedObject var browser: Browser
    @State private var opening = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color(hex: CanvasColors.stable(mention.fromId.isEmpty ? mention.who : mention.fromId)))
                Text(CanvasMentionPill.initials(mention.who))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                (Text(mention.who).fontWeight(.semibold) + Text(" \(mention.verb) in “\(mention.canvasName)”"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !mention.excerpt.isEmpty {
                    Text(mention.excerpt)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: 380, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            if opening { ProgressView().controlSize(.mini) }
            Button("Open") { open() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ground)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Palette.ink, in: Capsule())
                .disabled(opening)
                .help("Open “\(mention.canvasName)” at \(mention.isAssignment ? "the checklist" : "the message")")
            Button {
                CanvasChat.shared.dismissNewMention()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Not now — the canvas keeps it until you read it")
            .accessibilityLabel("Not now")
        }
        .padding(.leading, 9)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(mention.who) \(mention.verb) in \(mention.canvasName)\(mention.excerpt.isEmpty ? "" : ": \(mention.excerpt)")")
    }

    static func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: { " ._-@".contains($0) }).filter { !$0.isEmpty }
        guard let first = parts.first?.first else { return "?" }
        if parts.count == 1 { return String(first).uppercased() }
        return (String(first) + String(parts[parts.count - 1].first ?? first)).uppercased()
    }

    private func open() {
        guard !opening else { return }
        opening = true
        Task {
            await CanvasChat.shared.open(mention, in: browser)
            opening = false
        }
    }
}

/// The mention pill in the invite pill's stack (over the panels), or its room in `bars`, unseen.
struct CanvasMentionStack: View {
    @ObservedObject var browser: Browser
    var placeholder = false
    @ObservedObject private var chat = CanvasChat.shared

    var body: some View {
        Group {
            if let mention = chat.newMention {
                if placeholder {
                    CanvasMentionPill(mention: mention, browser: browser).hidden().accessibilityHidden(true)
                } else {
                    CanvasMentionPill(mention: mention, browser: browser)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(Motion.settle, value: chat.newMention)
        .onAppear { chat.start() }
    }
}

private extension Color {
    /// `#rrggbb` (the presence colours).
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt32(digits, radix: 16) ?? 0x888888
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

/// The accent the canvas page uses for mentions, for the dots that say one is waiting.
enum CanvasChatColors {
    static let mention = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.878, green: 0.565, blue: 0.353, alpha: 1)
            : NSColor(srgbRed: 0.784, green: 0.455, blue: 0.235, alpha: 1)
    })
}

// MARK: - macOS notifications

/// A mention while Copper isn't in front: one notification, which opens the
/// canvas at the message. macOS is asked once, when the first one arrives;
/// declined, nothing is ever asked again. Test worlds record what would have
/// been shown (`bench canvas chat mentions`) and never touch the real center.
final class CanvasChatNotices: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CanvasChatNotices()
    private static let prefix = "copper.canvas.mention."
    /// Test worlds have no app in front: they say whether to act as if Copper were.
    @MainActor static var frontmostForTests = false

    @MainActor static var frontmost: Bool { Store.testing ? frontmostForTests : NSApp.isActive }

    @MainActor static func install() {
        guard !Store.testing, Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil { center.delegate = shared }
    }

    @MainActor static func post(_ mention: CanvasChat.Mention) {
        let title = "\(mention.who) \(mention.verb)"
        let subtitle = mention.canvasName
        let body = mention.excerpt
        if Store.testing || Bundle.main.bundleIdentifier == nil {
            CanvasChat.shared.recordNotice(["title": title, "subtitle": subtitle, "body": body, "mention": mention.id])
            return
        }
        let center = UNUserNotificationCenter.current()
        let asked = CanvasChat.shared.askedToNotify
        Task { @MainActor in
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .denied: return
            case .notDetermined:
                guard !asked else { return }
                CanvasChat.shared.askedToNotify = true
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            default: break
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.subtitle = subtitle
            content.body = body
            content.sound = .default
            content.threadIdentifier = "copper.canvas.\(mention.canvasId)"
            content.userInfo = ["mention": mention.id, "canvas": mention.canvasId, "message": mention.messageId,
                                "canvasName": mention.canvasName, "from": mention.who, "excerpt": mention.excerpt]
            try? await center.add(UNNotificationRequest(identifier: prefix + mention.id, content: content, trigger: nil))
        }
    }

    /// Read here: its notification goes from Notification Center too.
    @MainActor static func withdraw(_ ids: [String]) {
        guard !Store.testing, Bundle.main.bundleIdentifier != nil, !ids.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids.map { prefix + $0 })
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Ours only arrive while Copper is behind; anyone else's keep the default (not shown in front).
        completionHandler(notification.request.identifier.hasPrefix(CanvasChatNotices.prefix) ? [.banner, .list, .sound] : [])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let id = response.notification.request.identifier
        guard id.hasPrefix(CanvasChatNotices.prefix), let mention = info["mention"] as? String, let canvas = info["canvas"] as? String,
              let message = info["message"] as? String else { completionHandler(); return }
        let fallback = CanvasChat.Mention(id: mention, canvasId: canvas, canvasName: info["canvasName"] as? String ?? "",
                                          fromId: "", fromName: info["from"] as? String ?? "", fromEmail: "",
                                          messageId: message, excerpt: info["excerpt"] as? String ?? "", createdAt: nil)
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            let known = CanvasChat.shared.mentions.first { $0.id == mention } ?? fallback
            await CanvasChat.shared.open(known, in: Windows.all.first ?? Windows.main)
            completionHandler()
        }
    }
}

// MARK: - the tool and the bench

extension CanvasChat {
    nonisolated static let toolName = "canvas_chat"

    nonisolated static var tool: [String: Any] {
        ["name": toolName,
         "description": "Post a message in a shared canvas's chat as the signed-in user (needs Copper Cloud; Personal and local canvases have no chat). mentions: people on the canvas by name or email — each is @mentioned (and notified on copper-cloud 0.6.0+). canvas_read returns recent chat under `chat`.",
         "inputSchema": ["type": "object", "properties": [
             "id": ["type": "string", "description": "Canvas id or name (from canvas_list); omit for the canvas tab in front"],
             "text": ["type": "string", "description": "The message (at most 4000 characters)"],
             "mentions": ["type": "array", "items": ["type": "string"], "description": "Names or emails of people on the canvas to @mention"],
             "reason": Tools.reasonProperty,
         ] as [String: Any], "required": ["text"]] as [String: Any]]
    }

    @MainActor
    static func runTool(_ args: [String: Any], in browser: Browser) async throws -> [Tools.Content] {
        let entry = try CanvasTools.resolve(args, in: browser)
        guard shared.offered(entry) else {
            throw CanvasTools.Failure(text: entry.isShared ? "Sign in to Copper Cloud to chat on “\(entry.name)”" : "“\(entry.name)” has no chat — only shared canvases do")
        }
        guard let text = args["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CanvasTools.Failure(text: "text required")
        }
        let host = try await CanvasTools.open(entry, in: browser, foreground: false)
        try await host.waitReady()
        await shared.prepare(host)
        let input: [String: Any] = ["text": text, "mentions": (args["mentions"] as? [Any] ?? []).compactMap { $0 as? String }]
        let data = try JSONSerialization.data(withJSONObject: input)
        let raw = try await host.call("""
            const c = window.copperCanvas;
            if (!c || typeof c.chatSend !== 'function') return JSON.stringify({ok: false, error: 'this canvas page has no chat'});
            return c.chatSend(input);
            """, ["input": String(decoding: data, as: UTF8.self)])
        let answer = (raw as? String).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        guard answer["ok"] as? Bool == true else { throw CanvasTools.Failure(text: answer["error"] as? String ?? "the message wasn't sent") }
        let mentioned = (answer["mentions"] as? [Any])?.count ?? 0
        Tools.summary?.line = "Posted in \(entry.name)’s chat\(mentioned > 0 ? ", mentioning \(mentioned)" : "")"
        return [.text(CanvasTools.json(["sent": true, "id": answer["id"] ?? "", "canvas": entry.name, "mentions": answer["mentions"] ?? []]))]
    }

    /// `bench canvas chat …` — see `bench` usage.
    @MainActor
    static func bench(_ arg: String, in browser: Browser) async throws -> [String: Any] {
        var words = arg.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let verb = words.isEmpty ? "state" : words.removeFirst()
        let chat = shared
        chat.start()
        func host(_ key: String?) async throws -> (Canvases.Entry, CanvasHost) {
            let entry = try CanvasTools.resolve(key.map { ["id": $0] } ?? [:], in: browser)
            let host = try await CanvasTools.open(entry, in: browser, foreground: false)
            try await host.waitReady()
            return (entry, host)
        }
        func page(_ host: CanvasHost, _ js: String, _ args: [String: Any] = [:]) async throws -> Any? {
            try await host.call(js, args)
        }
        func decoded(_ value: Any?) -> Any {
            guard let text = value as? String, let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { return value ?? NSNull() }
            return json
        }
        switch verb {
        case "state":
            let (entry, host) = try await host(words.first)
            let state = try await page(host, "const c = window.copperCanvas; return c && c.chatState ? c.chatState() : '{}';")
            let pref = chat.pref(entry.id)
            return ["canvas": entry.name, "id": entry.id, "page": decoded(state),
                    "host": ["open": pref.open.map { $0 as Any } ?? NSNull(), "readId": pref.readId ?? NSNull(),
                             "members": chat.members(entry.id).map { ["id": $0.id, "name": $0.name, "email": $0.email] },
                             "mentions": chat.mentionCount(entry.id), "offered": chat.offered(entry),
                             "mentionsApi": chat.mentionsApi.map { $0 as Any } ?? NSNull()] as [String: Any]]
        case "send":
            // `send ID TEXT… [--mention NAME|EMAIL]…`
            guard let key = words.first else { return ["error": "send ID TEXT [--mention WHO]…"] }
            var text: [String] = []
            var mentions: [String] = []
            var i = 1
            while i < words.count {
                if words[i] == "--mention", i + 1 < words.count { mentions.append(words[i + 1]); i += 2; continue }
                text.append(words[i]); i += 1
            }
            let out = try await runTool(["id": key, "text": text.joined(separator: " "), "mentions": mentions], in: browser)
            if case .text(let said)? = out.first { return decoded(said) as? [String: Any] ?? ["said": said] }
            return [:]
        case "read":
            let (_, host) = try await host(words.first)
            let limit = words.count > 1 ? Int(words[1]) ?? 50 : 50
            return ["messages": decoded(try await page(host, "const c = window.copperCanvas; return JSON.stringify(c && c.chatRead ? c.chatRead(n) : []);", ["n": limit]))]
        case "toggle", "key", "focus", "type", "enter", "escape", "dom":
            // The real controls: the button, the C key, the composer.
            let (_, host) = try await host(words.first)
            let rest = words.dropFirst().joined(separator: " ")
            let js: String
            switch verb {
            case "toggle": js = "const b = document.querySelector('[data-testid=chat-toggle]'); if (!b) return 'no chat button'; b.click(); return 'ok';"
            case "key": js = "window.dispatchEvent(new KeyboardEvent('keydown', {key: 'c', bubbles: true, cancelable: true})); return 'ok';"
            case "focus": js = "const t = document.querySelector('[data-testid=canvas-chat] textarea'); if (!t) return 'no composer'; t.focus(); return 'ok';"
            case "type":
                // As typed: the value, the caret at its end, an input event React hears.
                js = """
                    const t = document.querySelector('[data-testid=canvas-chat] textarea'); if (!t) return 'no composer';
                    t.focus();
                    const set = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set;
                    set.call(t, t.value + text);
                    t.setSelectionRange(t.value.length, t.value.length);
                    t.dispatchEvent(new Event('input', {bubbles: true}));
                    t.dispatchEvent(new Event('select', {bubbles: true}));
                    return 'ok';
                    """
            case "enter", "escape":
                js = """
                    const t = document.querySelector('[data-testid=canvas-chat] textarea'); if (!t) return 'no composer';
                    t.dispatchEvent(new KeyboardEvent('keydown', {key: key, bubbles: true, cancelable: true}));
                    return 'ok';
                    """
            default:
                js = """
                    const p = document.querySelector('[data-testid=canvas-chat]');
                    const list = document.querySelector('[role=listbox]');
                    return JSON.stringify({
                      panel: !!p, width: p ? Math.round(p.getBoundingClientRect().width) : 0,
                      options: list ? [...list.querySelectorAll('[role=option]')].map(o => o.dataset.name) : null,
                      invited: list ? [...list.querySelectorAll('[aria-disabled=true]')].map(o => o.innerText.replace(/\\s+/g, ' ').trim()) : [],
                      chips: p ? [...p.querySelectorAll('[data-mention]')].map(c => ({id: c.dataset.mention, text: c.textContent, mine: c.className.includes('bg-accent ')})) : [],
                      badge: (document.querySelector('[data-testid=chat-toggle] span[aria-hidden]') || {}).textContent || null,
                      draft: (p && p.querySelector('textarea')) ? p.querySelector('textarea').value : null,
                      flash: p ? [...p.querySelectorAll('.chat-flash')].map(e => e.dataset.message) : [],
                      scroller: p ? (() => { const l = p.querySelector('[role=log]'); return {top: Math.round(l.scrollTop), height: l.scrollHeight, client: l.clientHeight, wide: l.scrollWidth > l.clientWidth}; })() : null,
                    });
                    """
            }
            let said = try await page(host, js, ["text": rest, "key": verb == "enter" ? "Enter" : "Escape"])
            try? await Task.sleep(nanoseconds: 250_000_000)
            if verb == "dom" { return decoded(said) as? [String: Any] ?? ["said": said ?? NSNull()] }
            return ["said": said ?? NSNull()]
        case "mentions":
            await chat.refresh()
            return ["mentions": chat.mentions.map(describe), "pill": chat.newMention.map(describe) ?? NSNull(),
                    "door": chat.mentions.isEmpty ? NSNull() : "mention" as Any, "notices": chat.notices,
                    "mentionsApi": chat.mentionsApi.map { $0 as Any } ?? NSNull(), "server": Cloud.shared.serverVersion ?? NSNull()]
        case "pill":
            switch words.first {
            case "dismiss": chat.dismissNewMention()
            case "open":
                guard let mention = chat.newMention else { return ["error": "no pill"] }
                if let problem = await chat.open(mention, in: browser) { return ["error": problem] }
                try? await Task.sleep(nanoseconds: 700_000_000)
            default: break
            }
            let front = browser.tabs.first { $0.id == browser.activeID }.flatMap(CanvasTabs.showing)
            return ["pill": chat.newMention.map(describe) ?? NSNull(), "mentions": chat.mentions.count, "front": front ?? NSNull()]
        case "frontmost":
            // Test worlds: act as if Copper were (on) or weren't (off) the app in front.
            CanvasChatNotices.frontmostForTests = words.first == "on"
            return ["frontmost": CanvasChatNotices.frontmostForTests]
        case "members":
            let (entry, host) = try await host(words.first)
            await chat.prepare(host)
            return ["members": chat.members(entry.id).map { ["id": $0.id, "name": $0.name, "email": $0.email] }]
        default:
            return ["error": "chat state|send|read|toggle|key|focus|type|enter|escape|dom|members [ID] · chat mentions|pill [open|dismiss]|frontmost on|off"]
        }
    }

    static func describe(_ mention: Mention) -> [String: Any] {
        ["id": mention.id, "canvas": mention.canvasName, "canvasId": mention.canvasId, "from": mention.who,
         "message": mention.messageId, "excerpt": mention.excerpt, "assignment": mention.isAssignment]
    }
}
