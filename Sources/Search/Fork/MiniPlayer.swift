import AppKit
import SwiftUI
import WebKit

// Fork (ardia polish): the sidebar's mini player. A tab you have left that
// plays — a pin with music, a video in another tab or another space — gets a
// strip just above the column's foot: its artwork, what is playing (the
// page's own Now Playing, `navigator.mediaSession`, else the tab's title),
// play/pause and ±15 s. A click on the words goes to the tab; ✕ puts the
// strip away until the tab plays again. It goes when the tab is the one in
// front, is out in the floating window, sleeps or closes.
//
// The page is read in Copper's own content world, once a second and only
// while a strip is on screen. Its sound (WebKit's `_isPlayingAudio`, the
// tab's `noisy`) is what puts a tab here, so a muted background video never
// does.

@MainActor
final class MiniPlayer: ObservableObject {
    static let shared = MiniPlayer()

    struct Now: Equatable {
        var title = ""
        var artist = ""
        var artwork: URL?
        var playing = false
        var at: Double = 0
        var length: Double = 0
        var video = false
        /// A <video> or <audio> in the page's main frame to drive; without
        /// one (a player in a frame) only pausing works, through WebKit.
        var found = false
    }

    /// The last tab that started playing, until it closes.
    @Published private(set) var tabID: Tab.ID?
    @Published private(set) var now = Now()
    /// Put away with ✕, until the tab plays again.
    @Published private(set) var hidden: Set<Tab.ID> = []
    private var ticker: Timer?

    /// A tab's sound came on or went (Tab's AudioWatch).
    func heard(_ tab: Tab, _ on: Bool) {
        guard on, !tab.bench else {
            if tab.id == tabID { now.playing = false; read() }
            return
        }
        if tabID != tab.id { now = Now() }
        tabID = tab.id
        hidden.remove(tab.id)
        read()
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { MiniPlayer.shared.tick() }
        }
        ticker?.tolerance = 0.3
    }

    /// The playing tab, wherever it is: a window's row, a space's, the pins.
    var tab: Tab? {
        guard let id = tabID else { return nil }
        return Windows.all.flatMap(\.tabs).first(where: { $0.id == id }) ?? Spaces.shared.everyTab.first(where: { $0.id == id })
    }

    /// The tab whose strip this window's column shows: not the one in front
    /// of it, not a pane beside it, not out floating, not put away.
    func shown(in browser: Browser) -> Tab? {
        guard let tab, tab.built != nil, !tab.floating, !hidden.contains(tab.id), tab.id != browser.activeID else { return nil }
        let panes = Split.shared.panes
        if panes.contains(tab.id), let front = browser.activeID, panes.contains(front) { return nil }
        return tab
    }

    private func tick() {
        guard let tab, tab.built != nil else {
            tabID = nil
            now = Now()
            ticker?.invalidate()
            ticker = nil
            return
        }
        // Nothing on screen asks: nothing is asked of the page.
        guard Windows.all.contains(where: { shown(in: $0) != nil }) else { return }
        read()
    }

    // MARK: - the page

    func toggle() { read("toggle") }
    func skip(_ seconds: Double) { read("skip", by: seconds) }

    func hide() {
        guard let tabID else { return }
        hidden.insert(tabID)
    }

    /// Reads what is playing, after doing `op` (toggle, skip) to it.
    private func read(_ op: String = "", by: Double = 0) {
        guard let tab, let web = tab.built else { return }
        web.callAsyncJavaScript(Self.script, arguments: ["op": op, "by": by], in: nil, in: .copper) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.tabID == tab.id else { return }
                let got = (try? result.get()) as? [String: Any] ?? [:]
                var now = Now()
                now.found = got["found"] as? Bool ?? false
                now.title = (got["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tab.title
                now.artist = (got["artist"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (tab.address?.host() ?? "")
                now.artwork = (got["art"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
                now.at = got["at"] as? Double ?? 0
                now.length = got["length"] as? Double ?? 0
                now.video = got["video"] as? Bool ?? false
                now.playing = now.found ? (got["playing"] as? Bool ?? false) : tab.noisy
                // A player out of reach (in a frame): WebKit can still pause it.
                if op == "toggle", !now.found, tab.noisy {
                    web.pauseAllMediaPlayback()
                    now.playing = false
                }
                if self.now != now { self.now = now }
            }
        }
    }

    /// The page's media, in Copper's world: the one playing, else the one
    /// played last; the page's own Now Playing; `op` done first.
    static let script = """
    var all = Array.prototype.slice.call(document.querySelectorAll('video, audio')), v = null, i;
    for (i = 0; i < all.length && !v; i++) if (!all[i].paused && !all[i].ended) v = all[i];
    for (i = 0; i < all.length && !v; i++) if (all[i].currentTime > 0) v = all[i];
    if (v && op === 'toggle') { if (v.paused) { var p = v.play(); if (p && p.catch) p.catch(function () {}); } else v.pause(); }
    if (v && op === 'skip') v.currentTime = Math.max(0, Math.min(isFinite(v.duration) ? v.duration : Infinity, v.currentTime + by));
    var m = navigator.mediaSession && navigator.mediaSession.metadata, art = '';
    if (m && m.artwork && m.artwork.length) { try { art = new URL(m.artwork[m.artwork.length - 1].src, location.href).href; } catch (e) {} }
    if (!art && v && v.poster) art = v.poster;
    return { found: !!v, playing: !!v && !v.paused, at: v ? v.currentTime : 0, length: v && isFinite(v.duration) ? v.duration : 0,
             video: !!v && v.tagName === 'VIDEO', title: m && m.title || '', artist: m && (m.artist || m.album) || '', art: art };
    """

    // MARK: - bench

    /// `player` what the strip shows; `player toggle|skip N|hide|go`;
    /// `player away|back`: the window left / back, as when Copper goes to
    /// the back or the window is covered (the video floats, then lands).
    static func bench(_ request: [String: Any], in browser: Browser) -> [String: Any] {
        let player = shared
        let arg = request["arg"] as? String ?? ""
        switch request["op"] as? String ?? "state" {
        case "toggle": player.toggle()
        case "skip": player.skip(Double(arg) ?? 15)
        case "hide": player.hide()
        case "go": if let tab = player.tab { browser.select(tab) }
        case "away": browser.away(true, now: true)
        case "back": browser.away(false, now: true)
        default: break
        }
        let now = player.now
        return ["tab": player.tabID?.uuidString ?? "", "shown": player.shown(in: browser) != nil, "title": now.title, "artist": now.artist,
                "artwork": now.artwork?.absoluteString ?? "", "playing": now.playing, "at": now.at, "length": now.length,
                "video": now.video, "found": now.found, "floating": browser.active?.floating ?? false,
                "floatingAny": Windows.all.flatMap(\.tabs).contains(where: \.floating)]
    }
}

/// Above the column's foot, under the agent's pill (Side.swift).
struct MiniPlayerSlot: View {
    let browser: Browser
    @ObservedObject private var player = MiniPlayer.shared
    @ObservedObject private var split = Split.shared
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        let tab = player.shown(in: browser)
        VStack(spacing: 0) {
            if let tab {
                SlideInk(browser: browser) { tint in
                    MiniPlayerStrip(browser: browser, tab: tab, now: player.now, tint: tint)
                }
                .padding(.horizontal, SideBar.inset)
                .padding(.top, 6)
                .transition(still ? .opacity : .offset(y: 10).combined(with: .opacity))
            }
        }
        .animation(still ? .easeOut(duration: 0.2) : Motion.glide, value: tab?.id)
    }
}

private struct MiniPlayerStrip: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    let now: MiniPlayer.Now
    let tint: SpaceTint
    @State private var hovering = false

    var body: some View {
        // ±15 s go on a narrow column; play/pause stays.
        let roomy = browser.prefs.sideWidth >= 230
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button { browser.select(tab) } label: {
                    HStack(spacing: 8) {
                        artwork
                        VStack(alignment: .leading, spacing: 1) {
                            Text(now.title.isEmpty ? tab.title : now.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(tint.ink)
                            Text(now.artist)
                                .font(.system(size: 11))
                                .foregroundStyle(tint.muted)
                        }
                        .lineLimit(1)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Go to the tab")
                if roomy { control("gobackward.15", "Back 15 seconds", size: 12) { MiniPlayer.shared.skip(-15) } }
                control(now.playing ? "pause.fill" : "play.fill", now.playing ? "Pause" : "Play", size: 14) { MiniPlayer.shared.toggle() }
                if roomy { control("goforward.15", "Forward 15 seconds", size: 12) { MiniPlayer.shared.skip(15) } }
            }
            if now.length > 0 {
                GeometryReader { room in
                    ZStack(alignment: .leading) {
                        Capsule().fill(tint.faint.opacity(0.35))
                        Capsule().fill(tint.ink.opacity(0.75)).frame(width: room.size.width * min(1, max(0, now.at / now.length)))
                    }
                }
                .frame(height: 2)
                .accessibilityHidden(true)
            }
        }
        .padding(8)
        .background(tint.pill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: tint.lift, radius: 2, y: 1)
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { MiniPlayer.shared.hide() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(tint.ink)
                        .frame(width: 16, height: 16)
                        .background(tint.ground, in: Circle())
                        .overlay(Circle().strokeBorder(tint.hairline, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
                .help("Hide the player")
                .accessibilityLabel("Hide the player")
                .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now playing")
    }

    @ViewBuilder private var artwork: some View {
        let mark = Mark(icon: tab.icon, size: 18)
            .frame(width: 32, height: 32)
            .background(tint.square, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        if let url = now.artwork {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    mark
                }
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
        } else {
            mark.accessibilityHidden(true)
        }
    }

    private func control(_ symbol: String, _ label: String, size: CGFloat, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint.ink)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
