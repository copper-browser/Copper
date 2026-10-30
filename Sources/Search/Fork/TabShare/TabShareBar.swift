import SwiftUI

// While a tab is shared, a capsule at the foot of the window says which and
// with whom, and offers the one thing worth offering: Stop. The same capsule
// as the camera question and the password offer (App.swift `bars`), and it
// stays for as long as the share does — that is how you know it is still on.
//
// It stands aside on the page that is doing the sharing: a call page keeps
// its own controls along the bottom edge (Meet's, Zoom's), the capsule would
// sit on them, and that page has its own way to stop. Everywhere else —
// above all on the shared tab itself — it is there.
struct ShareBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var share = TabShare.shared

    var body: some View {
        VStack(spacing: 8) {
            ForEach(visible, id: \.id) { live in
                if let tab = AgentTabs.find(live.source) {
                    ShareCapsule(tab: tab, host: live.host,
                                 show: browser.activeID == tab.id ? nil : { AgentTabs.show(tab) },
                                 stop: { share.stop(live.id, reason: "stopped from the bar") })
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(Motion.settle, value: share.shares.map(\.id))
    }

    private var visible: [TabShare.Share] {
        share.shares.filter { $0.consumer == nil || $0.consumer != browser.activeID }
    }
}

struct ShareCapsule: View {
    @ObservedObject var tab: Tab
    let host: String
    /// Brings the shared tab forward; nil while it is the one on screen.
    let show: (() -> Void)?
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
            // On the shared tab itself the words are only words; elsewhere
            // they take you to it.
            if let show {
                Button(action: show) { words }
                    .buttonStyle(.plain)
                    .help("Show the shared tab")
            } else {
                words
            }
            Button(action: stop) {
                Text("Stop")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ground)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Palette.ink, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop sharing")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .fixedSize(horizontal: true, vertical: false)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
    }

    private var words: some View {
        (Text("Sharing ") + Text(title).fontWeight(.medium) + Text(" with \(host)"))
            .font(.system(size: 12.5))
            .foregroundStyle(Palette.ink)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    /// A long title is cut, never the words around it.
    private var title: String {
        let label = tab.label
        return label.count > 48 ? String(label.prefix(46)) + "…" : label
    }
}
