import Foundation
import WebKit

// An extension's worker stays up while it talks to a native host — Chrome's
// rule since Chrome 105: a port from `runtime.connectNative` keeps the
// service worker alive for as long as it is open.
//
// WebKit's rule is different. Thirty seconds after the last event it unloads
// the background unless the background itself posted on an open port in the
// last two minutes; what the host sends doesn't count, nor does a request
// the worker is still working on. So 1Password, holding its port to the
// desktop app (or waiting on it while the person answers 1Password's "Allow
// this browser?"), lost the worker, the port and the host process mid-way,
// and started over on the next event — into a core not yet initialised
// ("WASM is not initialized" from the toolbar icon's update).
//
// While a host is connected, the unload is put off: WebKit's own
// `loadBackgroundContent` reschedules it, and does nothing more when the
// background is up. A host whose worker is gone anyway — WebKit didn't say
// the port closed — is stopped instead of keeping it alive by itself.

@available(macOS 15.4, *)
@MainActor
enum NativeKeepAlive {
    /// Hosts connected per extension.
    private static var held: [String: [ObjectIdentifier: HostPipe]] = [:]
    private static var timer: Timer?
    /// Under WebKit's 30 s.
    static let every: TimeInterval = 20

    static func hold(_ pipe: HostPipe, for extensionID: String) {
        held[extensionID, default: [:]][ObjectIdentifier(pipe)] = pipe
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
    }

    static func release(_ pipe: HostPipe, for extensionID: String) {
        held[extensionID]?[ObjectIdentifier(pipe)] = nil
        if held[extensionID]?.isEmpty == true { held[extensionID] = nil }
        if held.isEmpty { timer?.invalidate(); timer = nil }
    }

    /// For the bench: how many hosts each extension has connected.
    static var counts: [String: Int] { held.mapValues(\.count) }

    private static func tick() {
        for (id, all) in held {
            // One that ended before its exit could be heard is let go here.
            let pipes = all.filter { $0.value.running }
            all.values.filter { !$0.running }.forEach { release($0, for: id) }
            if pipes.isEmpty { continue }
            // Fork (ardia profiles): the extension in every profile it runs in.
            let contexts = Extensions.contexts(of: id)
            guard !contexts.isEmpty else {
                pipes.values.forEach { $0.stop() }
                continue
            }
            // `_backgroundWebView` (Fork/ExtensionWorker.swift) is nil once
            // the background is unloaded; a WebKit without it just keeps it up.
            let awake = contexts.filter { !$0.responds(to: NSSelectorFromString("_backgroundWebView")) || ExtensionWorker.view(of: $0) != nil }
            if awake.isEmpty {
                pipes.values.forEach { $0.stop() }
                continue
            }
            awake.forEach { $0.loadBackgroundContent { _ in } }
        }
    }
}
