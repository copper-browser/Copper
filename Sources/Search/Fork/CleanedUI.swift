import SwiftUI

// Recently Cleaned in the column (Fork/Cleaned.swift): one quiet row at the
// foot of Today, there only while this space has something in it, with how
// many. A click opens the list beside it: each row comes back with a click,
// Restore All brings the lot back into Today.

struct CleanedRow: View {
    let browser: Browser
    let tint: SpaceTint
    @ObservedObject private var cleaned = Cleaned.shared
    @State private var open = false

    var body: some View {
        let count = cleaned.list(in: Spaces.shared.current(in: browser)).count
        if count > 0 {
            Quiet(icon: "archivebox", title: "Recently Cleaned", height: SideBar.row, inset: SideBar.rowInset,
                  glow: tint.hover, ink: tint.muted, words: tint.muted) { open.toggle() }
                .overlay(alignment: .trailing) {
                    Text("\(count)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(tint.muted)
                        .padding(.trailing, 10)
                        .allowsHitTesting(false)
                }
                .popover(isPresented: $open, arrowEdge: browser.prefs.awayEdge) { // Fork (ardia layout): toward the page
                    CleanedList(browser: browser) { open = false }
                }
                .accessibilityLabel("Recently Cleaned, \(count) tab\(count == 1 ? "" : "s")")
                .transition(.opacity)
        }
    }
}

/// The list itself, newest first, on the popover's own ground.
struct CleanedList: View {
    let browser: Browser
    let done: () -> Void
    @ObservedObject private var cleaned = Cleaned.shared
    @ObservedObject private var marks = Marks.ticker // a mark that lands draws its row again
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let list = cleaned.list(in: Spaces.shared.current(in: browser))
        let tint = SpaceTint(scheme).offColumn
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recently Cleaned")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text("Kept for a week, then gone")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 8)
                Button("Restore All") {
                    Cleaned.shared.restore(list, in: browser, select: false)
                    done()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DriveStyle.accent)
                .disabled(list.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(list) { entry in
                        CleanedLine(entry: entry, tint: tint) {
                            Cleaned.shared.restore([entry], in: browser, select: true)
                            done()
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 6)
        .frame(width: 320)
        .onAppear { Marks.want(list.map(\.url)) }
    }
}

private struct CleanedLine: View {
    let entry: CleanedEntry
    let tint: SpaceTint
    let act: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            HStack(spacing: 10) {
                RowMark(icon: Marks.key(for: entry.url).flatMap { Favicons.shared.cached($0) }, tint: tint)
                Text(entry.label)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Text(entry.when, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Palette.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(entry.url.absoluteString)
        .accessibilityLabel("Restore \(entry.label)")
    }
}
