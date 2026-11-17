import Foundation

// Writing a file the caller named (browser_take_screenshot's `filename`,
// `copper shot PATH`) off the main thread, with a bounded wait.
//
// A path on a removable or network volume, or in a folder macOS guards
// (Desktop, Documents, Downloads), can make open() wait on a privacy (TCC)
// prompt nobody answers. Done on the main thread that froze the whole app:
// every later MCP call, /health included, went unanswered and the CLI said
// Copper wasn't running. Here the write runs on a utility queue and the
// caller stops waiting after `timeout`, answering with an error that says
// what to try instead. A write that does block stays parked on its own
// worker thread until macOS lets it go; nothing else waits on it.

enum OffMainWrite {
    static let defaultTimeout: TimeInterval = 15

    struct TimedOut: Error, CustomStringConvertible {
        let path: String
        let seconds: TimeInterval
        var description: String {
            "couldn't write \(path) within \(Int(seconds.rounded())) s — macOS may be asking for permission to write there; try a path under /tmp or your home folder"
        }
    }

    typealias Writer = @Sendable (Data, URL) throws -> Void

    static let plainWrite: Writer = { data, url in try data.write(to: url) }

    /// Writes `data` to `url` on a utility queue; throws `TimedOut` after
    /// `timeout`, or what the writer threw. Never blocks the calling thread.
    static func write(_ data: Data, to url: URL, timeout: TimeInterval = defaultTimeout,
                      writer: @escaping Writer = plainWrite) async throws {
        try await run(url.path, timeout: timeout) { try writer(data, url) }
    }

    /// Any short file job for `path` (look, make folders, write) the same
    /// way: on a utility queue, its answer, or `TimedOut` after `timeout`.
    /// browser_take_screenshot saves through it, since a folder it is given
    /// becomes a file name only once the folder has been looked at.
    static func run<T>(_ path: String, timeout: TimeInterval = defaultTimeout,
                       _ work: @escaping @Sendable () throws -> T) async throws -> T {
        let once = Once()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            DispatchQueue.global(qos: .utility).async {
                let result = Result { try work() }
                if once.claim() { continuation.resume(with: result) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(throwing: TimedOut(path: path, seconds: timeout)) }
            }
        }
    }

    /// The same for synchronous callers off the app (the `copper` CLI):
    /// blocks this thread at most `timeout`, never longer.
    static func writeBlocking(_ data: Data, to url: URL, timeout: TimeInterval = defaultTimeout,
                              writer: @escaping Writer = plainWrite) throws {
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        DispatchQueue.global(qos: .utility).async {
            box.set(Result { try writer(data, url) })
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            throw TimedOut(path: url.path, seconds: timeout)
        }
        try box.get()?.get()
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if taken { return false }
            taken = true
            return true
        }
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<Void, Error>?
        func set(_ v: Result<Void, Error>) { lock.lock(); value = v; lock.unlock() }
        func get() -> Result<Void, Error>? { lock.lock(); defer { lock.unlock() }; return value }
    }
}
