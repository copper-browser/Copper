import Foundation
import WebKit

// A page's long poll for sound: the shared tab's (TabShareAudio, below) and a
// page served Copper's own microphone (Fork/Capture/PageMic.swift) ask the
// same way the pictures are asked for (TabShareCapture): "anything after
// N?", answered at once when there is, else as soon as there is. The page
// keeps one ask out; sound it was too slow to take is dropped Copper's side
// (PCMQueue), never queued without end.
@MainActor
final class PCMFeed {
    let sink: PCMSink
    private var waiting: [(after: Int, reply: TabShareCapture.Reply)] = []
    private(set) var ended: String?
    private(set) var lastAsked = Date()
    private(set) var asked = 0
    private(set) var served = 0

    init(seconds: Double = TabAudioRules.heldSeconds) {
        sink = PCMSink(seconds: seconds)
        sink.onArrival { [weak self] in self?.flush() }
    }

    /// The page's ask: the sound after `after`, now or when it comes.
    func next(after: Int, reply: TabShareCapture.Reply) {
        lastAsked = Date()
        asked += 1
        if let ended {
            reply(["ended": true, "reason": ended])
            return
        }
        if let chunk = sink.take(after: after) {
            served += 1
            reply(chunk.reply)
            return
        }
        // A page asking again without waiting: the oldest ask hears
        // "nothing new" (seq 0), which its script reads as "ask again".
        while waiting.count >= TabAudioRules.maxWaiting {
            waiting.removeFirst().reply(["seq": 0])
        }
        waiting.append((after, reply))
        sink.want(true)
    }

    private func flush() {
        guard ended == nil else { return }
        let ready = waiting
        waiting = []
        for each in ready {
            if let chunk = sink.take(after: each.after) {
                served += 1
                each.reply(chunk.reply)
            } else {
                waiting.append(each)
            }
        }
        sink.want(!waiting.isEmpty)
    }

    /// Over: whoever waits hears why, and every later ask too.
    func end(_ reason: String) {
        guard ended == nil else { return }
        ended = reason
        sink.want(false)
        let ready = waiting
        waiting = []
        for each in ready { each.reply(["ended": true, "reason": reason]) }
    }

    var report: [String: Any] {
        var out = sink.report
        out["asked"] = asked
        out["served"] = served
        out["waiting"] = waiting.count
        out["lastAskedAgo"] = (Date().timeIntervalSince(lastAsked) * 100).rounded() / 100
        out["ended"] = ended ?? NSNull()
        return out
    }
}

/// A shared tab's sound: one listener on TabAudioTap for as long as the share
/// lasts. It is all of Copper's page sound (TabAudioTap says why).
@MainActor
final class TabShareAudio {
    let feed = PCMFeed()

    init() {
        TabAudioTap.shared.attach(feed.sink)
        refresh()
    }

    /// The share's watchdog, once a second: the tap follows WebKit's GPU
    /// process if it changed, and is rebuilt if its sound stopped coming.
    func refresh() {
        TabAudioTap.shared.refresh(pids: TabShareAudio.gpuProcesses())
    }

    func stop(_ reason: String) {
        feed.end(reason)
        TabAudioTap.shared.detach(feed.sink)
    }

    /// The GPU process(es) WebKit says serve Copper's pages: every built
    /// page's `_gpuProcessIdentifier` (one process for all of them, in
    /// practice), and the process pool's. Asked only where this WebKit answers.
    static func gpuProcesses() -> Set<pid_t> {
        var pids = Set<pid_t>()
        let name = "_gpuProcessIdentifier", selector = NSSelectorFromString(name)
        func add(_ object: NSObject?) {
            guard let object, object.responds(to: selector), let number = object.value(forKey: name) as? NSNumber,
                  number.int32Value > 0 else { return }
            pids.insert(number.int32Value)
        }
        add(Web.pool as? NSObject)
        for tab in AgentTabs.all { add(tab.built) }
        return pids
    }
}
