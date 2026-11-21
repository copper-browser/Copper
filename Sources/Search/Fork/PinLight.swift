import SwiftUI

// A pin with something new on it wears a small copper dot.
//
// A page says it has news the way Gmail, Slack and X tell a tab bar: its title
// starts with an unread count, "(3) Inbox". The daily paper (Super Charles'
// /canvas) puts "(1) " in front of its title when a newer edition is out. The
// dot sits on the pin's square in the sidebar grid and the top strip, and
// hides while the pin is the tab you are on. It reads only `tab.title`, which
// the square already observes, so a title change redraws that one square.
// A sleeping or dozed pin keeps its last title (`Tab.discard` stops the
// title watch before the page goes), so its dot stays.
enum PinLight {
    /// "(1) Paper", "(12) Slack", Gmail's "Inbox (3) - …": yes. "(0) x",
    /// "Paper", "Year (2026)": no.
    nonisolated static func unread(_ title: String) -> Bool {
        guard let hit = title.prefixMatch(of: #/(?:Inbox )?\(([0-9][0-9,]*)\)(?:\s|$)/#) else { return false }
        return hit.1.contains { $0 != "0" && $0 != "," }
    }
}

/// The dot itself: 6 pt of copper accent, in the square's corner (clear of the mark).
struct PinLightDot: View {
    let title: String
    let live: Bool

    var body: some View {
        if !live && PinLight.unread(title) {
            Circle()
                .fill(Palette.accent)
                .frame(width: 6, height: 6)
                .transition(.opacity)
                .allowsHitTesting(false)
                .accessibilityLabel("New")
        }
    }
}
