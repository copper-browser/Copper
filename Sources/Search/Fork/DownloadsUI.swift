import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The small signal at the edge of the window. It is deliberately a door,
/// not a badge bolted onto the toolbar: when there is nothing to say, there is
/// nothing to look at.
struct DownloadsDoor: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var downloads = Downloads.shared
    var size: CGFloat = 26
    var arrowEdge: Edge = .bottom

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var active: Bool { !downloads.active.isEmpty }
    private var failed: Bool {
        downloads.items.contains { if case .failed = $0.state { return true }; return false }
    }
    private var icon: String {
        if active { return "arrow.down" }
        if downloads.pulsing { return "checkmark" }
        if failed { return "exclamationmark" }
        return "arrow.down.circle"
    }
    private var tint: Color {
        failed && !active && !downloads.pulsing ? Color.orange.opacity(0.9) : Palette.muted
    }
    private var help: String {
        let count = downloads.active.count
        let speed = Int64(downloads.active.reduce(0) { $0 + $1.speed })
        if count > 0 {
            let rate = ByteCountFormatter.string(fromByteCount: speed, countStyle: .file)
            return "\(count) download\(count == 1 ? "" : "s") · \(rate)/s"
        }
        let finished = downloads.items.filter { if case .finished = $0.state { return true }; return false }.count
        return finished == 0 ? "Downloads" : "\(finished) finished download\(finished == 1 ? "" : "s")"
    }

    var body: some View {
        Button {
            downloads.toggleDoor(in: browser)
            if downloads.popoverOpen { downloads.seen() }
        } label: {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    if active {
                        DownloadRing(fraction: downloads.fraction, size: size - 3, reduceMotion: reduceMotion)
                    } else if failed {
                        Circle()
                            .stroke(Color.orange.opacity(0.9), style: StrokeStyle(lineWidth: 1.5))
                            .frame(width: size - 3, height: size - 3)
                    }
                    Image(systemName: icon)
                        .font(.system(size: size < 24 ? 11 : 12, weight: .medium))
                        .foregroundStyle(tint)
                        .scaleEffect(downloads.pulsing && !reduceMotion ? 1.08 : 1)
                }
                .frame(width: size, height: size)
                if downloads.unseen > 0 {
                    Circle()
                        .fill(Palette.ink)
                        .frame(width: 5, height: 5)
                        .offset(x: -2, y: 2)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .background(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(hovering || downloads.showsDoor(in: browser) ? Palette.hover : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .popover(isPresented: downloads.door(in: browser), arrowEdge: arrowEdge) {
            DownloadsPopover(browser: browser, downloads: downloads)
        }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.settle, value: downloads.popoverOpen)
        .animation(Motion.settle, value: downloads.pulsing)
        .animation(Motion.quick, value: downloads.unseen)
    }
}

private struct DownloadRing: View {
    let fraction: Double?
    let size: CGFloat
    let reduceMotion: Bool
    @State private var turning = false

    var body: some View {
        Group {
            if let fraction {
                Circle()
                    .stroke(Palette.hairline, style: StrokeStyle(lineWidth: 1.5))
                    .overlay {
                        Circle()
                            .trim(from: 0, to: fraction)
                            .stroke(Palette.ink, style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
            } else {
                Circle()
                    .stroke(Palette.muted.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [2, 2]))
                    .rotationEffect(.degrees(turning ? 360 : 0))
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) { turning = true }
                    }
            }
        }
        .frame(width: size, height: size)
    }
}

/// The anchored list is intentionally narrower and quieter than the full
/// Downloads panel. It answers "what is happening?" before "what happened?".
struct DownloadsPopover: View {
    @ObservedObject var browser: Browser
    @ObservedObject var downloads: Downloads

    private var session: [Downloads.Item] { downloads.shown }

    private var older: [Keep] {
        let paths = Set(session.compactMap { $0.file?.path })
        return browser.loot.kept.filter { !paths.contains($0.path) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if session.isEmpty && browser.loot.kept.isEmpty {
                EmptyState("arrow.down.circle", "No downloads yet", "Files you download show up here.") // Fork (ui-system)
            } else {
                let rows = Array(session.prefix(8))
                ForEach(rows) { item in
                    DownloadRow(item: item, browser: browser, downloads: downloads)
                    if item.id != rows.last?.id { Rectangle().fill(Palette.hairline).frame(height: 1).padding(.leading, 56) }
                }
                if rows.count < 8 {
                    ForEach(Array(older.prefix(8 - rows.count))) { keep in
                        if rows.count > 0 || keep.id != older.first?.id {
                            Rectangle().fill(Palette.hairline).frame(height: 1).padding(.leading, 56)
                        }
                        DownloadRow(keep: keep, browser: browser, downloads: downloads)
                    }
                }
            }

            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(spacing: 10) {
                Button("Open Downloads Folder") {
                    NSWorkspace.shared.open(browser.prefs.downloads)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                if hasFinished {
                    Button("Clear") { downloads.clearFinished() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                }
                Button("Show All…") { browser.hoarding = true; downloads.popoverOpen = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        .frame(width: 340)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onAppear { downloads.seen() }
    }

    private var hasFinished: Bool {
        downloads.items.contains { item in
            if case .running = item.state { return false }
            return true
        }
    }
}

/// One row for both the live session item and the persisted Loot item. Keeping
/// the actions here means the popover and ⌘⇧J cannot drift apart.
struct DownloadRow: View {
    var item: Downloads.Item?
    var keep: Keep?
    @ObservedObject var browser: Browser
    @ObservedObject var downloads: Downloads

    init(item: Downloads.Item, browser: Browser, downloads: Downloads) {
        self.item = item; self.keep = nil; self.browser = browser; self.downloads = downloads
    }

    init(keep: Keep, browser: Browser, downloads: Downloads) {
        self.item = nil; self.keep = keep; self.browser = browser; self.downloads = downloads
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var file: URL? { item?.file ?? keep?.url }
    private var name: String { item?.name ?? keep?.name ?? "download" }
    private var exists: Bool { file.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            DownloadIcon(file: file, name: name, exists: exists)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(exists || item != nil ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Digits that hold still as they count, in the row's own type
                // rather than a typewriter's; the tail gives way before the
                // figures do.
                Text(detail)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let item, isRunning(item) {
                    DownloadProgress(item: item, reduceMotion: reduceMotion)
                }
            }
            Spacer(minLength: 4)
            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(hovering ? Palette.hover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { open() }
        .help(exists ? "Open \(name)" : "") // Fork (ui-system)
        .animation(Motion.quick, value: hovering)
    }

    @ViewBuilder private var actions: some View {
        if let item, isRunning(item) {
            Button { downloads.cancel(item) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 24, height: 24) // Fork (ui-system): 24 pt to hit
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Cancel download")
        } else if let item {
            if case .failed = item.state {
                Button("Retry") { downloads.retry(item, in: browser) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Palette.wash, in: Capsule())
            }
            // Fork (ui-system): Show in Finder on every file that's there, not
            // only under the pointer; the row itself opens it.
            if let file = item.file, exists { FinderDoor(icon: "folder", help: "Show in Finder") { reveal(file) } }
            if hovering { FinderDoor(icon: "xmark", help: "Remove from list") { downloads.remove(item) } }
        } else if let keep {
            if exists { FinderDoor(icon: "folder", help: "Show in Finder") { browser.loot.reveal(keep) } }
            if hovering { FinderDoor(icon: "xmark", help: "Remove from list") { browser.loot.forget(keep) } }
        }
    }

    private var detail: String {
        if let item {
            switch item.state {
            case .running:
                let rate = speed(item.speed)
                guard let total = item.total else { return "\(byte(item.done)) so far · \(rate)" }
                // "4.2 of 18.6 MB": the unit once, at the end, when both
                // figures share it — the way a person says it.
                let whole = byte(total)
                let part = byte(item.done)
                let unit = whole.split(separator: " ").last.map(String.init) ?? ""
                let done = !unit.isEmpty && part.hasSuffix(unit) ? String(part.dropLast(unit.count)).trimmingCharacters(in: .whitespaces) : part
                let left = item.speed > 1 ? duration(Double(max(0, total - item.done)) / item.speed) + " left" : "starting"
                return "\(done) of \(whole) · \(rate) · \(left)"
            case .finished:
                return "\(byte(item.total ?? item.done)) · \(item.from.isEmpty ? "Downloaded" : item.from)"
            case .failed:
                return item.done > 0 ? "Failed at \(byte(item.done))" : "Failed"
            case .cancelled:
                return "Cancelled"
            }
        }
        guard let keep else { return "" }
        return keep.from.isEmpty ? When.said(keep.date) : "\(keep.from) · \(When.said(keep.date))"
    }

    private func open() {
        if let file, exists { NSWorkspace.shared.open(file) }
        else if let keep, keep.stillThere { browser.loot.open(keep) }
    }

    private func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    private func isRunning(_ item: Downloads.Item) -> Bool { if case .running = item.state { return true }; return false }
    private func byte(_ value: Int64) -> String { DownloadFormat.bytes.string(fromByteCount: value) }
    private func speed(_ value: Double) -> String {
        value > 0 ? "\(DownloadFormat.bytes.string(fromByteCount: Int64(value)))/s" : "—"
    }
    /// "12 s", "2 min", "1 h 05 min" — round figures; nobody wants the seconds
    /// of an hour-long download.
    private func duration(_ value: Double) -> String {
        let seconds = max(0, Int(value.rounded()))
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\((seconds + 30) / 60) min" }
        return "\(seconds / 3600) h \(String(format: "%02d", (seconds % 3600) / 60)) min"
    }
}

private struct DownloadIcon: View {
    let file: URL?
    let name: String
    let exists: Bool

    var body: some View {
        Group {
            if let file, exists {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                    .resizable()
                    .interpolation(.high)
            } else if let type = UTType(filenameExtension: (name as NSString).pathExtension) {
                Image(nsImage: NSWorkspace.shared.icon(for: type))
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 18))
                    .foregroundStyle(Palette.muted)
            }
        }
        .frame(width: 32, height: 32) // Fork (ui-system): the file's own icon, big enough to tell a zip from a PDF
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct DownloadProgress: View {
    let item: Downloads.Item
    let reduceMotion: Bool
    @State private var shimmer = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.hairline)
                if let total = item.total, total > 0 {
                    Capsule().fill(Palette.ink)
                        .frame(width: geo.size.width * CGFloat(min(1, Double(item.done) / Double(total))))
                } else {
                    Capsule().fill(Palette.ink.opacity(0.65))
                        .frame(width: geo.size.width * 0.28)
                        .offset(x: shimmer ? geo.size.width : -geo.size.width * 0.28)
                        .animation(reduceMotion ? nil : .linear(duration: 1.2).repeatForever(autoreverses: false), value: shimmer)
                }
            }
        }
        .frame(height: 2)
        .clipShape(Capsule())
        .onAppear { if !reduceMotion { shimmer = true } }
    }
}

private struct FinderDoor: View {
    let icon: String
    let help: String
    let act: () -> Void
    var body: some View {
        Button(action: act) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 24, height: 24) // Fork (ui-system): 24 pt to hit
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

private enum DownloadFormat {
    static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.includesCount = true
        return formatter
    }()
}
