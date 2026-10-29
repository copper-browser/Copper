import SwiftUI

// The spaces brake's prompt (CloudSync.Hold): a quiet card at the foot of
// the column, over the update pill's place, while a spaces document waits
// for the person. Two answers, the one that keeps things as they are here
// filled: Undo here / Sync it for this Mac's own publish, Keep mine /
// Accept for another device's. Nothing happens until one is pressed.
// With no column on screen (tabs across the top, or the column folded away)
// the same card sits in the window's bottom-left corner (`CloudHoldCorner`).

struct CloudHoldSlot: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var sync = CloudSync.shared
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        VStack(spacing: 0) {
            if let hold = sync.hold {
                SlideInk(browser: browser) { tint in CloudHoldCard(hold: hold, tint: tint) }
                    .padding(.horizontal, SideBar.inset)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                    .transition(still ? .opacity : .offset(y: 14).combined(with: .opacity))
            }
        }
        .animation(still ? .easeOut(duration: 0.2) : Motion.glide, value: sync.hold == nil)
    }
}

private struct CloudHoldCard: View {
    let hold: CloudSync.Hold
    let tint: SpaceTint

    private var outgoing: Bool { if case .outgoing = hold { return true } else { return false } }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: outgoing ? "icloud.and.arrow.up" : "icloud.and.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint.muted)
                Text(hold.text)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(tint.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                answer(outgoing ? "Undo here" : "Keep mine", filled: true) { await CloudSync.shared.keepHeldBack() }
                answer(outgoing ? "Sync it" : "Accept", filled: false) { await CloudSync.shared.letHeldThrough() }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(tint.pill)
                .overlay { shape.strokeBorder(tint.rim, lineWidth: 0.75) }
                .shadow(color: tint.lift, radius: 4, y: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(hold.text)
    }

    private func answer(_ title: String, filled: Bool, _ act: @escaping () async -> Void) -> some View {
        Button { Task { await act() } } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(filled ? tint.ground : tint.ink)
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(filled ? tint.ink : tint.chip, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The card where the column would be, while the column isn't showing.
struct CloudHoldCorner: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject private var sync = CloudSync.shared
    @ObservedObject private var spaces = Spaces.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var still

    private var columnless: Bool { !prefs.sidebar || (browser.folded && !browser.peeking) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if columnless, let hold = sync.hold {
                CloudHoldCard(hold: hold, tint: SpaceTint(space: spaces.space(in: browser), dark: scheme == .dark).offColumn)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous)) // over a page, not see-through
                    .frame(width: 270)
                    .padding(.leading, 12)
                    .padding(.bottom, 12)
                    .transition(still ? .opacity : .offset(y: 14).combined(with: .opacity))
            }
        }
        .animation(still ? .easeOut(duration: 0.2) : Motion.glide, value: columnless && sync.hold != nil)
    }
}
