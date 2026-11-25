import AppKit
import SwiftUI

// Fork (ardia: automation): Window › Task Manager (also ⌘K). Every tab with a
// page loaded, in any window or space, with what its web process holds (the
// footprint Sleep already weighs, Heat.weight) and the CPU it used since the
// last look, the heaviest first. Sleep puts the chosen tabs to sleep by the
// same rules as the idle sweep (a tab on screen, playing sound or holding
// something typed says why it stays awake); End Process stops the page's
// process, as Chrome's does: the tab shows that its page went away and loads
// again when you go back to it (Browser.webViewWebContentProcessDidTerminate).
// Tabs that share a process show the process's numbers on each of their rows.
// Refreshed every 2 s while the window is open, never sampled after.

@MainActor
final class TaskManager: ObservableObject {
    static let shared = TaskManager()

    struct Row: Identifiable, Equatable {
        let id: UUID
        let title: String
        let host: String
        let pid: pid_t
        let bytes: UInt64
        /// Percent of one core since the last look; nil on the first.
        let cpu: Double?
        /// Tabs in the same process.
        let sharing: Int
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var asleep = 0
    /// What the last Sleep or End came to.
    @Published private(set) var said = ""

    private(set) var window: NSWindow?
    private var timer: Timer?
    private var last: [pid_t: (cpu: Double, at: Double)] = [:]

    func show() {
        refresh()
        if window == nil {
            let made = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                backing: .buffered, defer: false)
            made.title = "Task Manager"
            made.isReleasedWhenClosed = false
            made.tabbingMode = .disallowed
            let hosting = NSHostingView(rootView: TaskManagerView(model: self))
            hosting.sizingOptions = [.minSize] // the table's ideal size would take the whole screen
            made.contentView = hosting
            made.center()
            made.setFrameAutosaveName("Task Manager")
            window = made
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.window?.isVisible == true else {
                    self.timer?.invalidate()
                    self.timer = nil
                    self.last = [:]
                    return
                }
                self.refresh()
            }
        }
    }

    func refresh() {
        let tabs = AgentTabs.all
        asleep = tabs.filter { $0.asleep }.count
        let weighed = tabs.filter { $0.built != nil && !$0.asleep }.compactMap { tab in Heat.shared.weight(of: tab).map { (tab, $0) } }
        let sharing = Dictionary(grouping: weighed, by: { $0.1.pid }).mapValues(\.count)
        let now = ProcessInfo.processInfo.systemUptime * 1e9
        var cpu: [pid_t: Double] = [:]
        var next: [pid_t: (cpu: Double, at: Double)] = [:]
        for pid in sharing.keys {
            guard let used = Heat.shared.processCPU(pid) else { continue }
            if let before = last[pid] { cpu[pid] = max(0, (used - before.cpu) / max(now - before.at, 1) * 100) }
            next[pid] = (used, now)
        }
        last = next
        rows = weighed.map { tab, weight in
            Row(id: tab.id, title: tab.label, host: tab.address?.host() ?? "", pid: weight.pid, bytes: weight.bytes,
                cpu: cpu[weight.pid], sharing: sharing[weight.pid] ?? 1)
        }.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.title < $1.title }
    }

    /// The pages' total: each process once.
    var summary: String {
        var seen = Set<pid_t>()
        let total = rows.filter { seen.insert($0.pid).inserted }.reduce(UInt64(0)) { $0 + $1.bytes }
        let pages = rows.count == 1 ? "1 page" : "\(rows.count) pages"
        return "\(pages) loaded, \(TaskManager.size(total))" + (asleep > 0 ? " · \(asleep) asleep" : "")
    }

    nonisolated static func size(_ bytes: UInt64) -> String {
        bytes >= 1_073_741_824 ? String(format: "%.1f GB", Double(bytes) / 1_073_741_824) : "\(bytes / 1_048_576) MB"
    }

    func sleep(_ ids: Set<UUID>) {
        for tab in AgentTabs.all where ids.contains(tab.id) {
            let title = tab.label
            (Windows.owner(of: tab) ?? Windows.current).sleep(tab) { [weak self] outcome in
                self?.said = outcome == "asleep" ? "\(title): asleep" : "\(title) stays awake: \(outcome)"
                self?.refresh()
            }
        }
    }

    func end(_ ids: Set<UUID>) {
        let pids = Set(rows.filter { ids.contains($0.id) }.map(\.pid))
        for pid in pids { kill(pid, SIGKILL) }
        said = pids.count == 1 ? "Ended process \(pids.first!)" : "Ended \(pids.count) processes"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refresh() }
    }

    /// `tasks` lists the rows (CPU from the second call on); `tasks show`;
    /// `tasks sleep ID` / `tasks end ID` (an id prefix from the list);
    /// `tasks shot PATH` a PNG of the window.
    static func bench(_ request: [String: Any]) -> [String: Any] {
        let model = shared
        let op = request["op"] as? String ?? "list"
        let arg = request["arg"] as? String ?? ""
        let picked = Set(AgentTabs.all.filter { !arg.isEmpty && $0.id.uuidString.lowercased().hasPrefix(arg.lowercased()) }.map(\.id))
        switch op {
        case "show": model.show()
        case "sleep", "end":
            guard !picked.isEmpty else { return ["error": "tasks \(op) ID"] }
            if op == "sleep" { model.sleep(picked) } else { model.end(picked) }
            return ["asked": picked.count]
        case "shot":
            guard let window = model.window, !arg.isEmpty,
                  let image = Fork.layered([CGWindowID(window.windowNumber)]),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else { return ["error": "tasks show, then tasks shot PATH"] }
            do { try png.write(to: URL(fileURLWithPath: arg)) } catch { return ["error": "\(error)"] }
            return ["path": arg, "size": [image.width, image.height]]
        default: model.refresh()
        }
        return ["rows": model.rows.map { row -> [String: Any] in
            ["id": String(row.id.uuidString.prefix(8)).lowercased(), "title": row.title, "pid": Int(row.pid),
             "mb": Int(row.bytes / 1_048_576), "cpu": row.cpu.map { $0 } ?? NSNull(), "sharing": row.sharing]
        }, "asleep": model.asleep, "said": model.said, "summary": model.summary,
           "showing": model.window?.isVisible ?? false]
    }
}

struct TaskManagerView: View {
    @ObservedObject var model: TaskManager
    @State private var picked = Set<UUID>()

    var body: some View {
        VStack(spacing: 0) {
            Table(model.rows, selection: $picked) {
                TableColumn("Tab") { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title).lineLimit(1)
                        Text(row.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                TableColumn("Memory") { row in Text(TaskManager.size(row.bytes)).monospacedDigit() }
                    .width(min: 70, ideal: 80)
                TableColumn("CPU") { row in Text(row.cpu.map { String(format: "%.1f%%", $0) } ?? "–").monospacedDigit() }
                    .width(min: 50, ideal: 60)
                TableColumn("Process") { row in
                    Text(verbatim: row.sharing > 1 ? "\(row.pid) · \(row.sharing) tabs" : "\(row.pid)").monospacedDigit()
                }
                .width(min: 70, ideal: 110)
            }
            Divider()
            HStack(spacing: 8) {
                Text(model.said.isEmpty ? model.summary : model.said)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Button("Sleep") { model.sleep(picked) }
                    .disabled(picked.isEmpty)
                    .help("Put the chosen tabs to sleep; they load again when you go back to them")
                Button("End Process") { model.end(picked) }
                    .disabled(picked.isEmpty)
                    .help("Stop the chosen pages' processes, and every tab sharing them")
            }
            .padding(10)
        }
        .frame(minWidth: 520, minHeight: 280)
    }
}
