// xbprobe: the outside-in measurements xbench.py takes of any Mac browser, WebKit or Chromium.
//   xbprobe procs MAINPID BUNDLE...        every process of one browser instance, one JSON line each:
//                                          MAINPID itself, its descendants, every process macOS holds MAINPID
//                                          responsible for (WebKit's XPC services are launchd's children, not the
//                                          app's) and anything running from inside one of the BUNDLE paths
//   xbprobe rusage PID...                  proc_pid_rusage per pid: phys_footprint, CPU ns, wakeups, energy
//   xbprobe waitwindow SINCE_MS TIMEOUT_S BUNDLE...   epoch ms of the first on-screen window ≥ 300×200 with
//                                          alpha > 0 owned by a process running from one of the BUNDLE paths
//   xbprobe windows BUNDLE...              that bundle's windows now (all, on screen or not)
//   xbprobe display                        {"locked":…, "asleep":…}
//   xbprobe find BUNDLE...                 pids running from inside those bundles, oldest first
//   xbprobe quit PID                       ask the app to quit the way the Dock's Quit does (NSRunningApplication)
import AppKit
import CoreGraphics
import Darwin
import Foundation

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
func nanos(_ ticks: UInt64) -> UInt64 { ticks * UInt64(timebase.numer) / UInt64(timebase.denom) }
func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
let responsibleFn: ResponsibleFn? = {
  guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
  return unsafeBitCast(sym, to: ResponsibleFn.self)
}()
func responsible(_ pid: pid_t) -> pid_t { responsibleFn?(pid) ?? -1 }

func allPids() -> [pid_t] {
  let count = proc_listallpids(nil, 0)
  guard count > 0 else { return [] }
  var buf = [pid_t](repeating: 0, count: Int(count) + 256)
  let got = buf.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
  return Array(buf.prefix(Int(max(got, 0)))).filter { $0 > 0 }
}

func path(_ pid: pid_t) -> String? {
  var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
  let n = proc_pidpath(pid, &buf, UInt32(buf.count))
  return n > 0 ? String(cString: buf) : nil
}

func bsd(_ pid: pid_t) -> proc_bsdinfo? {
  var info = proc_bsdinfo()
  let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
  return n == Int32(MemoryLayout<proc_bsdinfo>.size) ? info : nil
}

func realBundle(_ p: String) -> String {
  let url = URL(fileURLWithPath: p).resolvingSymlinksInPath()
  return url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
}

func inside(_ exe: String, _ bundles: [String]) -> Bool {
  bundles.contains { exe == $0 || exe.hasPrefix($0 + "/") }
}

func printJSON(_ value: Any) {
  let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func rusage(_ pid: pid_t) -> [String: Any]? {
  var info = rusage_info_v6()
  let rc = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
  }
  guard rc == 0 else { return nil }
  return [
    "pid": pid,
    "footprint": info.ri_phys_footprint,
    "resident": info.ri_resident_size,
    "cpuNs": nanos(info.ri_user_time) + nanos(info.ri_system_time),
    "idleWakeups": info.ri_pkg_idle_wkups,
    "interruptWakeups": info.ri_interrupt_wkups,
    "billedEnergy": info.ri_billed_energy,
    "energyNj": info.ri_energy_nj,
    "at": nowMs(),
  ]
}

func procs(main: pid_t, bundles: [String]) -> [[String: Any]] {
  var parent: [pid_t: pid_t] = [:]
  var exe: [pid_t: String] = [:]
  var name: [pid_t: String] = [:]
  let pids = allPids()
  for p in pids {
    if let b = bsd(p) {
      parent[p] = pid_t(b.pbi_ppid)
      var comm = b.pbi_name
      name[p] = withUnsafePointer(to: &comm) { $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) } }
      if name[p] == "" {
        var c2 = b.pbi_comm
        name[p] = withUnsafePointer(to: &c2) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
      }
    }
    exe[p] = path(p)
  }
  func descends(_ p: pid_t) -> Bool {
    var cur = p, hops = 0
    while let up = parent[cur], up > 1, hops < 64 { if up == main { return true }; cur = up; hops += 1 }
    return false
  }
  var out: [[String: Any]] = []
  for p in pids {
    let r = responsible(p)
    var why: String? = nil
    if p == main { why = "main" }
    else if descends(p) { why = "child" }
    else if r == main { why = "responsible" }
    else if let e = exe[p], inside(e, bundles) { why = "bundle" }
    guard let reason = why else { continue }
    out.append(["pid": p, "ppid": parent[p] ?? -1, "responsible": r, "path": exe[p] ?? "", "name": name[p] ?? "", "why": reason])
  }
  return out
}

func windows(bundles: [String], onScreenOnly: Bool, cache: inout [pid_t: Bool]) -> [[String: Any]] {
  let opts: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly] : [.optionAll]
  guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
  var out: [[String: Any]] = []
  for w in list {
    guard let pid = w[kCGWindowOwnerPID as String] as? Int32 else { continue }
    let ours: Bool
    if let known = cache[pid] { ours = known } else { ours = path(pid).map { inside($0, bundles) } ?? false; cache[pid] = ours }
    guard ours else { continue }
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    out.append(["id": w[kCGWindowNumber as String] ?? 0, "pid": pid, "layer": w[kCGWindowLayer as String] ?? 0,
                "alpha": w[kCGWindowAlpha as String] ?? 0, "onscreen": w[kCGWindowIsOnscreen as String] ?? false,
                "x": b["X"] ?? 0, "y": b["Y"] ?? 0, "w": b["Width"] ?? 0, "h": b["Height"] ?? 0])
  }
  return out
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first ?? "" {
case "procs":
  guard args.count >= 2, let main = pid_t(args[1]) else { exit(64) }
  for p in procs(main: main, bundles: args.dropFirst(2).map(realBundle)) { printJSON(p) }
case "rusage":
  for p in args.dropFirst() { if let pid = pid_t(p), let r = rusage(pid) { printJSON(r) } }
case "find":
  let bundles = args.dropFirst().map(realBundle)
  var found: [(pid_t, UInt64)] = []
  for p in allPids() { if let e = path(p), inside(e, bundles), let b = bsd(p) { found.append((p, b.pbi_start_tvsec * 1_000_000 + b.pbi_start_tvusec)) } }
  for (p, started) in found.sorted(by: { $0.1 < $1.1 }) { printJSON(["pid": p, "path": path(p) ?? "", "started": Double(started) / 1000, "ppid": bsd(p).map { Int($0.pbi_ppid) } ?? -1]) }
case "windows":
  var cache: [pid_t: Bool] = [:]
  printJSON(windows(bundles: args.dropFirst().map(realBundle), onScreenOnly: false, cache: &cache))
case "waitwindow":
  guard args.count >= 4, let timeout = Double(args[2]) else { exit(64) }
  let bundles = args.dropFirst(3).map(realBundle)
  var cache: [pid_t: Bool] = [:]
  let deadline = Date().addingTimeInterval(timeout)
  var polls = 0
  while Date() < deadline {
    polls += 1
    let shown = windows(bundles: bundles, onScreenOnly: true, cache: &cache).filter {
      ($0["w"] as? Double ?? 0) >= 300 && ($0["h"] as? Double ?? 0) >= 200 && ($0["alpha"] as? Double ?? 0) > 0 && ($0["layer"] as? Int ?? 0) == 0
    }
    if let w = shown.first { printJSON(["at": nowMs(), "window": w, "polls": polls]); exit(0) }
    if polls % 50 == 0 { cache = cache.filter { $0.value } }  // forget non-matching pids now and then (pid reuse)
    usleep(2000)
  }
  printJSON(["at": NSNull(), "polls": polls]); exit(2)
case "quit":
  guard args.count >= 2, let pid = pid_t(args[1]), let app = NSRunningApplication(processIdentifier: pid) else { exit(3) }
  exit(app.terminate() ? 0 : 1)
case "display":
  let session = CGSessionCopyCurrentDictionary() as? [String: Any]
  printJSON(["asleep": CGDisplayIsAsleep(CGMainDisplayID()) != 0, "locked": (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false,
             "session": session != nil])
default:
  FileHandle.standardError.write("usage: xbprobe procs|rusage|find|windows|waitwindow|display …\n".data(using: .utf8)!)
  exit(64)
}
