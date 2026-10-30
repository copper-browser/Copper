import SwiftUI

/// Fork (page-capture): the bar a page's camera or microphone puts at the
/// bottom of the window (App.swift `bars`), in the same capsule as the
/// window's other one-line bars. One of three things at a time:
///
/// - a site asking: "meet.google.com wants to use your microphone",
///   Allow / Don't allow — named by the site, and with Show when the tab that
///   asked isn't the one on screen (a call in another space still asks here);
/// - a refusal just made: "Microphone blocked for meet.google.com" with
///   Allow and reload, for a few seconds — a slip is one click to undo;
/// - the call on screen paused by WebKit because another tab started the
///   microphone (one page at a time): "Use it here" takes it back;
/// - macOS refusing Copper the device: said plainly, with the way to
///   System Settings › Privacy & Security, until you dismiss it or allow it —
///   and then, for a few seconds, Reload for the pages it refused;
/// - Fork (page-voice): a listed site asking for Copper's on-device speech
///   to text (Fork/Voice/PageVoice.swift), Allow / Don't allow as for a device.
struct CaptureSlot: View {
    @ObservedObject var browser: Browser
    @ObservedObject var desk: CaptureDesk

    /// Nothing at all when there is nothing to say, so the bars stacked above
    /// keep their spacing. The desk changes the bar inside the window's settle
    /// animation (CaptureDesk.refresh), which carries the transition.
    var body: some View {
        if let bar = desk.bar {
            CaptureBarView(bar: bar, elsewhere: elsewhere(bar)) { act($0, on: bar) }
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// The tab that asked is not the one on this window's stage.
    private func elsewhere(_ bar: CaptureDesk.Bar) -> Bool {
        let asker: UUID?
        switch bar {
        case let .ask(question): asker = question.tab
        case let .voice(_, tab): asker = tab
        default: asker = nil
        }
        guard let tab = asker else { return false }
        return tab != browser.activeID && !Split.shared.has(tab)
    }

    /// `bar`: what the bar said when it was clicked — an answer is for the
    /// question you read, never one that took its place under the pointer.
    private func act(_ action: CaptureBarView.Action, on bar: CaptureDesk.Bar) {
        switch action {
        case .allow:
            if let shown = bar.question { desk.allow(shown) } else if case .voice = bar { desk.answerVoice(bar, allow: true) }
        case .deny:
            if let shown = bar.question { desk.deny(shown) } else if case .voice = bar { desk.answerVoice(bar, allow: false) }
        case .show: desk.showAsker()
        case .allowRefused: desk.allowRefused()
        case .openSettings: desk.openSystemSettings()
        case .dismiss: desk.dismissSystem()
        case .reload: desk.reloadRestored()
        case .resume: desk.resumePaused()
        }
    }
}

/// The bar itself, drawn from what it says alone, so the bench can picture it
/// off screen (`bench privacy capture render`).
struct CaptureBarView: View {
    enum Action { case allow, deny, show, allowRefused, openSettings, dismiss, reload, resume }

    let bar: CaptureDesk.Bar
    var elsewhere = false
    let act: (Action) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
            Text(words)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            buttons
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
    }

    @ViewBuilder
    private var buttons: some View {
        switch bar {
        case .ask, .voice:
            if elsewhere { quiet("Show") { act(.show) } }
            strong("Allow") { act(.allow) }
            quiet("Don't allow") { act(.deny) }
        case .refused:
            accent("Allow and reload") { act(.allowRefused) }
        case let .system(_, restricted):
            if !restricted { strong("Open System Settings") { act(.openSettings) } }
            quiet("Not now") { act(.dismiss) }
        case .restored:
            accent("Reload") { act(.reload) }
        case .paused:
            strong("Use it here") { act(.resume) }
        }
    }

    private func strong(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ground)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Palette.ink, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// The one quiet way back, as the Clear tabs toast's Undo.
    private func accent(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(DriveStyle.accent)
            .buttonStyle(.plain)
    }

    private func quiet(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
        }
        .buttonStyle(.plain)
    }

    private var devices: CaptureDevices {
        switch bar {
        case let .ask(question): return question.devices
        case let .refused(_, devices): return devices
        case let .system(devices, _): return devices
        case let .restored(devices): return devices
        case let .paused(_, devices, _): return devices
        case .voice: return []
        }
    }

    private var symbol: String {
        let camera = devices.contains(.camera)
        switch bar {
        case .ask, .restored: return camera ? "video" : "mic"
        case .refused, .system, .paused: return camera ? "video.slash" : "mic.slash"
        case .voice: return "waveform"
        }
    }

    private static func named(_ site: String) -> String { site.isEmpty ? "This page" : site }

    private var words: String {
        switch bar {
        case let .ask(question):
            return "\(Self.named(question.site)) wants to use your \(question.devices.words)"
        case let .refused(site, devices):
            let what = devices.words
            return "\(what.prefix(1).uppercased() + what.dropFirst()) blocked for \(Self.named(site))"
        case let .system(devices, restricted):
            return restricted
                ? "This Mac's settings don't let \(Fork.name) use the \(devices.words)"
                : "macOS isn't letting \(Fork.name) use your \(devices.words)"
        case let .restored(devices):
            return "\(Fork.name) can use your \(devices.words) now"
        case let .paused(site, devices, _):
            return "\(Self.named(site)) can't use your \(devices.words) — another tab is using it"
        case let .voice(host, _):
            return "\(Self.named(host)) wants to use your \(PageVoice.asks)"
        }
    }
}
