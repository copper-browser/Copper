import Foundation

// The parts of a shared tab's sound — and of a page served Copper's own
// microphone (Fork/Capture/PageMic.swift) — that are arithmetic and
// bookkeeping, kept apart from CoreAudio and WebKit so `swift test --filter
// TabAudio` can hold them to their word (Tests/SearchTests/TabAudioRulesTests.swift).
// docs/screen-sharing.md › Tab audio tells the story.
enum TabAudioRules {
    // MARK: - the picker's switch

    /// macOS's answer for "audio capture" (kTCCServiceAudioCapture): may
    /// Copper record the sound it plays itself.
    enum Permission: Equatable {
        case granted, denied, unknown
    }

    /// "Also share tab audio", as the card draws it.
    struct AudioSwitch: Equatable {
        /// Drawn at all: the page asked for audio and a tab can be handed over.
        var shown = false
        /// Where it starts.
        var on = false
        /// macOS refuses Copper the sound: the switch is drawn, off and dimmed.
        var enabled = true
        /// The page doing the sharing is itself playing sound (a call): it
        /// would hear itself, so the switch starts off.
        var callerPlaying = false
        /// That page's site, for the line under the switch.
        var caller = ""
    }

    /// Chrome's switch: on when the page asked for audio. Two exceptions,
    /// both said under it. Copper hears its pages through WebKit's one GPU
    /// process, so what goes is every page's sound, not one tab's: a page
    /// that is itself playing sound — a call presenting a tab — would be
    /// sent its own sound back, and the switch starts off there (it can be
    /// turned on). And when macOS refuses Copper audio capture the switch
    /// is off and can't be turned on.
    static func audioSwitch(asked: Bool, canShareTab: Bool, callerHost: String, callerPlaying: Bool,
                            permission: Permission) -> AudioSwitch {
        guard asked, canShareTab else { return AudioSwitch() }
        if permission == .denied {
            return AudioSwitch(shown: true, on: false, enabled: false, callerPlaying: callerPlaying, caller: callerHost)
        }
        return AudioSwitch(shown: true, on: !callerPlaying, enabled: true, callerPlaying: callerPlaying, caller: callerHost)
    }

    /// The line under the switch: always honest about what goes.
    static func note(_ audio: AudioSwitch, on: Bool) -> String {
        guard audio.shown else { return "" }
        if !audio.enabled { return "Copper isn't allowed to record audio" }
        let caller = audio.caller.isEmpty ? "This page" : audio.caller
        if audio.callerPlaying {
            return on ? "All of Copper's sound: \(caller) hears its own too" : "Off: \(caller) would hear itself"
        }
        return "All of Copper's sound, not only this tab's"
    }

    /// Whether the answer hands the page sound: a tab, with the switch on.
    static func sharesAudio(_ audio: AudioSwitch, on: Bool) -> Bool {
        audio.shown && audio.enabled && on
    }

    // MARK: - pace and bounds

    /// The most sound waiting for the page, in seconds. Past it the oldest
    /// goes: a page that falls behind hears a skip, never a growing delay.
    static let heldSeconds = 0.25
    /// Sound is handed over in pieces of at least this long: about fifty
    /// replies a second, each a few kilobytes.
    static let chunkSeconds = 0.02
    /// The most one reply carries, in seconds.
    static let replySeconds = 0.25
    /// Asks for sound kept waiting at once (the page's script keeps one).
    static let maxWaiting = 2
    /// A page that stopped asking for sound this long ago has stopped
    /// listening (its audio track stopped, its page gone): the tap lets it go.
    static let quietSeconds: TimeInterval = 4
    /// No sound from the tap for this long while it runs: rebuilt (the
    /// output device it is clocked by went away, the GPU process restarted).
    static let stallSeconds: TimeInterval = 2

    static func stalled(sinceIO: TimeInterval, running: Bool) -> Bool {
        running && sinceIO > stallSeconds
    }

    // MARK: - which process

    /// One process CoreAudio knows (kAudioHardwarePropertyProcessObjectList).
    struct AudioProcess: Equatable {
        let object: UInt32
        let pid: Int32
        let bundle: String
        /// The app macOS holds responsible for it (an XPC service's host).
        let responsible: Int32
    }

    /// The processes whose sound is this Copper's pages': WebKit's GPU
    /// process(es) serving them, which render every page's sound. The pids
    /// WebKit names (`_gpuProcessIdentifier`) when it names any; otherwise a
    /// WebKit GPU process macOS holds this Copper responsible for. Never
    /// another app's WebKit (Safari's, Mail's, another Copper's).
    static func gpuProcesses(_ all: [AudioProcess], webKit pids: Set<Int32>, me: Int32) -> [UInt32] {
        let named = all.filter { $0.pid > 0 && pids.contains($0.pid) }
        if !named.isEmpty { return named.map(\.object).sorted() }
        return all.filter { $0.bundle.hasPrefix("com.apple.WebKit.GPU") && $0.responsible == me && $0.pid != me }
            .map(\.object).sorted()
    }
}

/// One piece of sound on its way to a page: little-endian 16-bit samples,
/// interleaved, at the rate it was heard.
struct PCMChunk: Equatable {
    let seq: Int
    let frames: Int
    let rate: Double
    let channels: Int
    let data: Data

    var seconds: Double { rate > 0 ? Double(frames) / rate : 0 }

    /// What the page's script reads.
    var reply: [String: Any] {
        ["seq": seq, "frames": frames, "rate": rate, "channels": channels, "data": data.base64EncodedString()]
    }
}

/// The sound waiting for one page, never more than `limit` seconds of it.
/// The page says what it has (`after`, the last piece's number); a piece is
/// let go once the page has it, or when it is the oldest and there is too
/// much — so a page that stops listening costs a quarter of a second of
/// memory, and one that falls behind skips ahead instead of lagging.
struct PCMQueue {
    let limit: Double
    private(set) var chunks: [PCMChunk] = []
    private(set) var seq = 0
    /// Frames let go unheard.
    private(set) var dropped = 0
    private(set) var held = 0.0

    init(limit: Double = TabAudioRules.heldSeconds) {
        self.limit = limit
    }

    mutating func push(_ data: Data, frames: Int, rate: Double, channels: Int) {
        guard frames > 0, rate > 0, channels > 0 else { return }
        seq += 1
        let chunk = PCMChunk(seq: seq, frames: frames, rate: rate, channels: channels, data: data)
        chunks.append(chunk)
        held += chunk.seconds
        // Always keep the newest, however long it is.
        while held > limit + 1e-9, chunks.count > 1 {
            let old = chunks.removeFirst()
            held -= old.seconds
            dropped += old.frames
        }
    }

    /// The page has everything up to `after`.
    mutating func acknowledge(_ after: Int) {
        while let first = chunks.first, first.seq <= after {
            chunks.removeFirst()
            held -= first.seconds
        }
        if chunks.isEmpty { held = 0 }
    }

    /// Everything newer than `after` that reads alike (one rate, one channel
    /// count), joined, up to `most` seconds — nil when there is nothing new.
    func peek(after: Int, most: Double = TabAudioRules.replySeconds) -> PCMChunk? {
        let newer = chunks.drop { $0.seq <= after }
        guard let first = newer.first else { return nil }
        var data = Data(), frames = 0, last = first.seq
        for chunk in newer {
            guard chunk.rate == first.rate, chunk.channels == first.channels else { break }
            if frames > 0, Double(frames + chunk.frames) / first.rate > most + 1e-9 { break }
            data.append(chunk.data)
            frames += chunk.frames
            last = chunk.seq
        }
        return PCMChunk(seq: last, frames: frames, rate: first.rate, channels: first.channels, data: data)
    }

    /// `acknowledge` then `peek`: what the page asking with `after` gets.
    mutating func take(after: Int, most: Double = TabAudioRules.replySeconds) -> PCMChunk? {
        acknowledge(after)
        return peek(after: after, most: most)
    }
}

/// Float samples to what a page is handed: 16-bit, little-endian, clamped.
enum PCM {
    @inline(__always) static func sample(_ value: Swift.Float) -> Int16 {
        guard value.isFinite else { return 0 }
        return Int16((max(-1, min(1, value)) * 32767).rounded())
    }

    /// `frames` interleaved frames of `channels` channels, keeping the first
    /// `keep` of them (a mono source is copied to both sides when `keep` is 2).
    static func int16(interleaved samples: UnsafeBufferPointer<Swift.Float>, channels: Int, keep: Int) -> Data {
        guard channels > 0, keep > 0 else { return Data() }
        let frames = samples.count / channels
        var out = Data(count: frames * keep * 2)
        out.withUnsafeMutableBytes { raw in
            let to = raw.bindMemory(to: Int16.self)
            for frame in 0..<frames {
                for c in 0..<keep {
                    to[frame * keep + c] = sample(samples[frame * channels + min(c, channels - 1)]).littleEndian
                }
            }
        }
        return out
    }

    /// One buffer per channel, interleaved into one.
    static func int16(planar channels: [UnsafeBufferPointer<Swift.Float>]) -> Data {
        guard let first = channels.first else { return Data() }
        let frames = channels.map(\.count).min() ?? first.count, count = channels.count
        var out = Data(count: frames * count * 2)
        out.withUnsafeMutableBytes { raw in
            let to = raw.bindMemory(to: Int16.self)
            for frame in 0..<frames {
                for c in 0..<count { to[frame * count + c] = sample(channels[c][frame]).littleEndian }
            }
        }
        return out
    }

    static func int16(_ mono: [Swift.Float]) -> Data {
        mono.withUnsafeBufferPointer { int16(interleaved: $0, channels: 1, keep: 1) }
    }

    /// Back to floats (the bench's level, the tests).
    static func floats(_ data: Data) -> [Swift.Float] {
        data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Swift.Float(Int16(littleEndian: $0)) / 32768 }
        }
    }

    /// The loudness of a piece, in dBFS (the bench's).
    static func level(_ data: Data) -> Double {
        let samples = floats(data)
        guard !samples.isEmpty else { return -120 }
        let power = samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count)
        return max(-120, 10 * log10(max(power, 1e-12)))
    }
}
