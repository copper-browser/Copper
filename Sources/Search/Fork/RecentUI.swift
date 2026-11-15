import SwiftUI

/// The temporary MRU chooser shown while Control is held. It is deliberately
/// quiet: a single quick Control-Tab never leaves a flash on the page.
struct RecentStrip: View {
    let browser: Browser
    @ObservedObject private var recent = Recent.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tabs: [Tab] {
        var found = recent.order.compactMap { id in browser.tabs.first { $0.id == id } }
        found.append(contentsOf: browser.tabs.filter { tab in !found.contains { $0.id == tab.id } })
        return Array(found.prefix(8))
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.id) { tab in
                item(tab)
            }
        }
        .padding(6)
        .background(Palette.ground.opacity(0.96), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 20, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent tabs")
        .transition(reduceMotion ? .opacity : .scale(scale: 0.97).combined(with: .opacity))
        .animation(reduceMotion ? nil : Motion.settle, value: recent.showing)
    }

    private func item(_ tab: Tab) -> some View {
        let selected = tab.id == recent.landing
        return HStack(spacing: 7) {
            mark(tab)
            Text(tab.title.isEmpty ? (tab.address?.host() ?? "New tab") : tab.title)
                .font(.system(size: 11.5, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Palette.ink : Palette.muted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(width: 126, height: 34)
        .background(selected ? Palette.wash : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel(tab.title.isEmpty ? (tab.address?.host() ?? "New tab") : tab.title)
    }

    @ViewBuilder
    private func mark(_ tab: Tab) -> some View {
        if let icon = tab.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 18, height: 18)
        } else {
            Text(tab.monogram)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .frame(width: 18, height: 18)
                .background(Palette.wash.opacity(0.6), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}
