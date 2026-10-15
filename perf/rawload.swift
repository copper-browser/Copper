// Control: a bare WKWebView "browser" — new web view per load, like a new tab.
// rawload URL N [--fresh] [--store UUID]
import AppKit
import WebKit

let args = CommandLine.arguments
let url = URL(string: args[1])!
let runs = Int(args[2]) ?? 3
let fresh = args.contains("--fresh")
let warm = args.contains("--warm")
let auto = args.contains("--auto")
let early = args.contains("--early")

func makePool() -> WKProcessPool? {
    guard auto, let cls = NSClassFromString("_WKProcessPoolConfiguration") as? NSObject.Type else { return nil }
    let pc = cls.init()
    pc.setValue(true, forKey: "prewarmsProcessesAutomatically")
    if pc.responds(to: NSSelectorFromString("setUsesWebProcessCache:")) { pc.setValue(true, forKey: "usesWebProcessCache") }
    let raw = (WKProcessPool.self as AnyObject).perform(NSSelectorFromString("alloc"))!.takeUnretainedValue()
    return raw.perform(NSSelectorFromString("_initWithConfiguration:"), with: pc)?.takeUnretainedValue() as? WKProcessPool
}
let storeID = UUID(uuidString: "5E4C0000-0000-4000-8000-0000000000AA")!

let timingJS = """
(() => {
  const n = performance.getEntriesByType('navigation')[0] || {};
  const p = Object.fromEntries(performance.getEntriesByType('paint').map(e => [e.name, Math.round(e.startTime)]));
  const res = performance.getEntriesByType('resource');
  const bytes = res.reduce((a, r) => a + (r.transferSize || 0), 0);
  const list = res.map(r => [r.name.slice(0,70), Math.round(r.startTime), Math.round(r.duration), r.transferSize, r.initiatorType, Math.round(r.domainLookupEnd-r.domainLookupStart), Math.round(r.connectEnd-r.connectStart)]);
  return JSON.stringify({list, origin: performance.timeOrigin, type: n.type, ttfb: Math.round(n.responseStart||0),
    dcl: Math.round(n.domContentLoadedEventEnd||0), load: Math.round(n.loadEventEnd||0),
    fcp: p['first-contentful-paint'], resources: res.length, bytes: bytes + (n.transferSize||0), docBytes: n.transferSize});
})()
"""

final class Runner: NSObject, WKNavigationDelegate {
    let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1280, height: 800),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    let config: WKWebViewConfiguration = {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID)
        if let pool = makePool() { c.processPool = pool }
        return c
    }()
    var web: WKWebView?
    var t0 = Date()
    var run = 0
    var started: Date?
    var committed: Date?
    var reported = false

    func next() {
        guard run < runs else { NSApp.terminate(nil); return }
        let go = { [self] in
            t0 = Date()
            reported = false
            let w = WKWebView(frame: window.contentView!.bounds, configuration: config)
            w.navigationDelegate = self
            w.autoresizingMask = [.width, .height]
            web?.removeFromSuperview()
            web = w
            window.contentView!.addSubview(w)
            w.load(URLRequest(url: url))
        }
        if fresh {
            config.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { go() }
        } else { go() }
    }

    var events: [String] = []
    func ev(_ name: String, _ webView: WKWebView) { events.append("\(Int(Date().timeIntervalSince(t0) * 1000)) \(name) \(webView.url?.absoluteString ?? "")") }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { started = Date(); ev("start", webView) }
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) { ev("redirect", webView) }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { committed = Date(); ev("commit", webView) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === web, !reported else { return }
        reported = true
        let done = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            webView.evaluateJavaScript(timingJS) { [self] value, _ in
                var m = (try? JSONSerialization.jsonObject(with: Data(((value as? String) ?? "{}").utf8))) as? [String: Any] ?? [:]
                let t0ms = t0.timeIntervalSince1970 * 1000
                if let origin = m["origin"] as? Double {
                    m["app_overhead_ms"] = Int(origin - t0ms)
                    if let fcp = m["fcp"] as? Double { m["req_to_fcp_ms"] = Int(origin + fcp - t0ms) }
                    if let load = m["load"] as? Double { m["req_to_load_ms"] = Int(origin + load - t0ms) }
                }
                m["start_ms"] = started.map { Int($0.timeIntervalSince(t0) * 1000) }
                m["commit_ms"] = committed.map { Int($0.timeIntervalSince(t0) * 1000) }
                m["finish_ms"] = Int(done.timeIntervalSince(t0) * 1000)
                m["run"] = run
                m["fresh"] = fresh
                m["events"] = events
                events = []
                m["mode"] = warm ? "warm" : auto ? "auto" : "plain"
                let data = try! JSONSerialization.data(withJSONObject: m, options: [.sortedKeys])
                print(String(data: data, encoding: .utf8)!)
                fflush(stdout)
                run += 1
                if warm { _ = config.processPool.perform(NSSelectorFromString("_warmInitialProcess")) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.next() }
            }
        }
    }
}

var spare: WKWebView?
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let runner = Runner()
if early { _ = runner.config.processPool.perform(NSSelectorFromString("_warmInitialProcess")) }
if args.contains("--net") { runner.config.websiteDataStore.httpCookieStore.getAllCookies { _ in } }
if args.contains("--view") { let w = WKWebView(frame: .zero, configuration: runner.config); w.loadHTMLString("", baseURL: nil); spare = w }
runner.window.orderFrontRegardless()
DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { runner.next() }
app.run()
