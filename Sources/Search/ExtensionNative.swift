import Foundation
import WebKit

// Chrome's native messaging, for the extensions that talk to an app on this
// Mac — a password manager unlocking with its desktop app, a clipper handing
// a page to a notes app.
//
// Those apps register with Chrome by leaving a small JSON file in Chrome's
// NativeMessagingHosts folder: a name, the program to run, and which
// extensions may run it. Copper reads the same files, runs the same program
// with the same argument, and speaks the same protocol — each message a
// four-byte length and a line of JSON, over the program's stdin and stdout.
// A host that lists the extension's id among its allowed origins is run;
// any other is not. Some hosts also check which browser is calling and may
// refuse one they don't know; that is theirs to decide.

@available(macOS 15.4, *)
enum ExtensionNative {
    struct Refused: LocalizedError {
        let why: String
        var errorDescription: String? { why }
    }

    /// Where Chromium browsers look, per user and for the whole Mac.
    private static var folders: [URL] {
        // Fork (native-host-folder): a test world may name its own folder, so
        // a probe talks to a stand-in host rather than the apps on this Mac.
        if Store.testing, let own = ProcessInfo.processInfo.environment["SEARCH_NATIVE_HOSTS"], !own.isEmpty {
            return [URL(fileURLWithPath: own, isDirectory: true)]
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support")
        return [
            support.appendingPathComponent("Google/Chrome/NativeMessagingHosts"),
            support.appendingPathComponent("Chromium/NativeMessagingHosts"),
            support.appendingPathComponent("Microsoft Edge/NativeMessagingHosts"),
            support.appendingPathComponent("BraveSoftware/Brave-Browser/NativeMessagingHosts"),
            support.appendingPathComponent("Arc/User Data/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Application Support/Chromium/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Microsoft/Edge/NativeMessagingHosts"),
        ]
    }

    /// The program for `name`, if one is registered and lets this extension in.
    private static func host(_ name: String, for extensionID: String) throws -> URL {
        guard name.range(of: #"^[a-z0-9_]+(\.[a-z0-9_]+)*$"#, options: .regularExpression) != nil else {
            throw Refused(why: "Invalid native messaging host name")
        }
        let origin = "chrome-extension://\(extensionID)/"
        for folder in folders {
            let file = folder.appendingPathComponent(name + ".json")
            guard let data = try? Data(contentsOf: file),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let path = manifest["path"] as? String
            else { continue }
            let allowed = manifest["allowed_origins"] as? [String] ?? []
            guard allowed.contains(origin) else {
                throw Refused(why: "Access to the specified native messaging host is forbidden.")
            }
            let program = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
            guard FileManager.default.isExecutableFile(atPath: program.path) else {
                throw Refused(why: "Specified native messaging host not found.")
            }
            return program
        }
        throw Refused(why: "Specified native messaging host not found.")
    }

    /// `runtime.sendNativeMessage`: run, send one, read one, stop.
    static func send(_ message: Any, to name: String, from extensionID: String) async throws -> Any? {
        let program = try host(name, for: extensionID)
        let pipe = HostPipe(program: program, origin: "chrome-extension://\(extensionID)/")
        try pipe.start()
        defer { pipe.stop() }
        try pipe.write(message)
        return try await pipe.readOne()
    }

    /// `runtime.connectNative`: run, and keep the two talking until either
    /// end lets go.
    @MainActor
    static func connect(_ port: WKWebExtension.MessagePort, from extensionID: String) throws {
        guard let name = port.applicationIdentifier else { throw Refused(why: "No host named") }
        let program = try host(name, for: extensionID)
        let pipe = HostPipe(program: program, origin: "chrome-extension://\(extensionID)/")
        try pipe.start()
        pipe.onMessage = { message in
            DispatchQueue.main.async { port.sendMessage(message, completionHandler: nil) }
        }
        pipe.onExit = {
            DispatchQueue.main.async { if !port.isDisconnected { port.disconnect() } }
        }
        port.messageHandler = { message, _ in
            guard let message else { return }
            try? pipe.write(message)
        }
        port.disconnectHandler = { _ in pipe.stop() }
        Live.keep(pipe)
        // Fork (native-keepalive): the worker stays up while the host is
        // connected, as in Chrome — Fork/NativeKeepAlive.swift.
        NativeKeepAlive.hold(pipe, for: extensionID)
        let kept = pipe.onExit
        pipe.onExit = {
            kept?()
            DispatchQueue.main.async { MainActor.assumeIsolated { NativeKeepAlive.release(pipe, for: extensionID) } }
        }
    }

    /// Hosts that are connected, held until they end.
    private enum Live {
        nonisolated(unsafe) static var pipes: [ObjectIdentifier: HostPipe] = [:]
        static func keep(_ pipe: HostPipe) {
            pipes[ObjectIdentifier(pipe)] = pipe
            let previous = pipe.onExit
            pipe.onExit = {
                previous?()
                DispatchQueue.main.async { pipes[ObjectIdentifier(pipe)] = nil }
            }
        }
    }
}

/// One host program and the framing Chrome uses to talk to it.
@available(macOS 15.4, *)
final class HostPipe: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private let lock = NSLock()
    var onMessage: ((Any) -> Void)?
    var onExit: (() -> Void)?
    private var waiters: [CheckedContinuation<Any?, Error>] = []
    private var finished = false
    /// For NativeFrames' log (a probe world's only).
    private let name: String

    init(program: URL, origin: String) {
        name = program.lastPathComponent
        process.executableURL = program
        process.arguments = [origin]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.finish()
                return
            }
            self.take(chunk)
        }
        process.terminationHandler = { [weak self] ended in
            // Fork (native-frames): how the host ended, for a probe's log.
            if let self, NativeFrames.on { NativeFrames.event(self.name, "exited \(ended.terminationStatus)") }
            // Fork (native-last-word): a host that answers and exits at once
            // (1Password's BrowserSupport after PartnerBrowserAuthorization…)
            // can be seen to end before its last frame is read; ending the
            // port now would drop that answer. The output's own end, read
            // after every frame, finishes it; this is only the fallback for
            // an output a child of the host still holds open.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { self?.finish() }
        }
        try process.run()
        if NativeFrames.on { NativeFrames.event(name, "started \(process.processIdentifier) \(process.arguments?.joined(separator: " ") ?? "")") }
    }

    /// Fork (native-keepalive): a host that already ended keeps nothing alive.
    var running: Bool { process.isRunning }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    func write(_ message: Any) throws {
        let json = try JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed])
        guard json.count <= 1 << 20 else { throw ExtensionNative.Refused(why: "Message too long for a native host") }
        var length = UInt32(json.count).littleEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(json)
        if NativeFrames.on { NativeFrames.note(">", name, json) } // Fork (native-frames)
        try input.fileHandleForWriting.write(contentsOf: frame)
    }

    func readOne() async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            waiters.append(continuation)
            lock.unlock()
        }
    }

    private func take(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        var messages: [Any] = []
        while buffer.count >= 4 {
            let length = Int(buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
            guard buffer.count >= 4 + length else { break }
            let body = buffer.subdata(in: 4..<(4 + length))
            buffer.removeSubrange(0..<(4 + length))
            if NativeFrames.on { NativeFrames.note("<", name, body) } // Fork (native-frames)
            if let message = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) {
                messages.append(message)
            } else if NativeFrames.on {
                NativeFrames.event(name, "dropped a frame that isn't JSON")
            }
        }
        var handed: [(CheckedContinuation<Any?, Error>, Any)] = []
        for message in messages where !waiters.isEmpty {
            handed.append((waiters.removeFirst(), message))
        }
        let rest = messages.dropFirst(handed.count)
        lock.unlock()
        handed.forEach { $0.0.resume(returning: $0.1) }
        rest.forEach { onMessage?($0) }
    }

    /// Reached twice for one host — once when its output closes, once when
    /// the process ends — on two different queues. Only the first pass does
    /// anything, and `onExit` changes hands under the lock so neither pass
    /// can release the closure while the other is still calling it.
    private func finish() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let pending = waiters
        waiters = []
        let exit = onExit
        onExit = nil
        lock.unlock()
        pending.forEach { $0.resume(throwing: ExtensionNative.Refused(why: "Native host has exited.")) }
        exit?()
    }
}
