import AppKit
import AVFoundation
import CoreAudio
import Foundation

// The microphone, for dictation and Listen: AVAudioEngine's input node tapped
// at whatever format the device runs at, turned into the one format the speech
// model takes — 16 kHz mono Float32 — in blocks of exactly 50 ms.
//
// The tap callback only copies: its buffer is copied and handed to a private
// serial queue, where one long-lived converter (VoiceBlockMaker) resamples and
// cuts blocks. Nothing on the tap's thread waits for anything.
//
// No voice processing (Apple's echo cancellation) in v1. Turning it on ducks
// every other sound the Mac plays while the mic is open, changes the input's
// format and level (its own gain control), and adds latency; the RMS gate in
// LiveSession was tuned on plain input, and dictation is close-mic speech.
//
// Capture never outlives what the person can see: a device that disappears,
// sleep and a switch to another login session all stop it, and nothing ever
// restarts it on its own — `onStop` says why it stopped. Audio is never
// written anywhere; blocks go to `onBlock` and nowhere else.

enum VoiceCaptureStop: Sendable, Equatable {
    case requested, deviceLost, sleep, sessionResigned, failed(String)
}

enum VoiceCaptureError: LocalizedError {
    case headless, notAuthorized, busy, noInput, unsupportedFormat, engine(String)

    var errorDescription: String? {
        switch self {
        case .headless: return "Headless Copper never uses the microphone."
        case .notAuthorized: return "Copper isn't allowed to use the microphone."
        case .busy: return "The microphone is already in use by Copper."
        case .noInput: return "No microphone is connected."
        case .unsupportedFormat: return "The microphone's audio format isn't supported."
        case .engine(let reason): return "The microphone couldn't start: \(reason)"
        }
    }
}

final class VoiceCapture: @unchecked Sendable {
    static var authorization: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    /// Shows the system prompt when the person hasn't decided yet; call it only
    /// from an explicit gesture (the first time someone asks to dictate).
    static func requestAccess() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }

    private let queue = DispatchQueue(label: "com.collinrijock.copper.voice.capture", qos: .userInitiated)
    private let onQueueKey = DispatchSpecificKey<Bool>()
    private let lock = NSLock()
    private var current: Run?                // guarded by `lock`
    /// The input to open, by name (a page's chosen microphone, PageMic);
    /// nil is the Mac's default input. Looked up again on every rebuild, so
    /// a device that goes is a device lost.
    let device: String?

    init(device: String? = nil) {
        self.device = device
        queue.setSpecific(key: onQueueKey, value: true)
    }

    deinit { stop() }

    /// Opens the microphone. `onBlock` gets 16 kHz mono Float32 blocks of
    /// exactly 800 samples and `onStop` gets the reason capture ended, once,
    /// after the last block; both run on the private serial queue and must not
    /// block on the main thread. Throws in headless mode, without permission
    /// (never prompts — see `requestAccess`), with no input device, or when
    /// already running.
    func start(onBlock: @escaping @Sendable ([Swift.Float]) -> Void,
               onStop: @escaping @Sendable (VoiceCaptureStop) -> Void) throws {
        if Headless.on { throw VoiceCaptureError.headless }
        guard Self.authorization == .authorized else { throw VoiceCaptureError.notAuthorized }
        try onQueue {
            guard lock.withLock({ current == nil }) else { throw VoiceCaptureError.busy }
            let run = Run(onBlock: onBlock, onStop: onStop)
            try open(run)
            lock.withLock { current = run }
            watch(run)
        }
    }

    /// Releases the microphone before it returns (the tap is removed and the
    /// engine stopped and reset, which turns the menu-bar mic indicator off),
    /// then delivers what the converter still held and `onStop(.requested)`.
    /// Idempotent; safe from any thread, including from inside `onBlock`.
    func stop() { halt(.requested, only: nil) }

    // MARK: - Engine

    /// One capture: its engine, its converter and its callbacks. Touched only on `queue`.
    private final class Run: @unchecked Sendable {
        var engine = AVAudioEngine()
        let maker = VoiceBlockMaker()
        let onBlock: @Sendable ([Swift.Float]) -> Void
        let onStop: @Sendable (VoiceCaptureStop) -> Void
        var observers: [(NotificationCenter, NSObjectProtocol)] = []
        var configObserver: NSObjectProtocol?
        var restarts: [Date] = []
        var finished = false                 // onStop delivered; drop anything later

        init(onBlock: @escaping @Sendable ([Swift.Float]) -> Void, onStop: @escaping @Sendable (VoiceCaptureStop) -> Void) {
            self.onBlock = onBlock
            self.onStop = onStop
        }
    }

    /// The buffer a tap copied; owned by the queue from then on.
    private struct Captured: @unchecked Sendable { let buffer: AVAudioPCMBuffer }

    /// Taps the run's engine at the device's own format and starts it. On queue.
    private func open(_ run: Run) throws {
        let input = run.engine.inputNode
        if let device {
            guard let id = AudioInputs.id(named: device), AudioInputs.use(id, on: input) else { throw VoiceCaptureError.noInput }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceCaptureError.noInput }
        // 100 ms is the shortest buffer a tap accepts.
        let frames = AVAudioFrameCount(max(1_024, format.sampleRate / 10))
        // format nil = the bus's own format; naming one that no longer matches
        // the hardware (a device that just changed) raises instead of failing.
        input.installTap(onBus: 0, bufferSize: frames, format: nil) { [weak self, weak run] buffer, _ in
            guard let self, let run, let copy = VoiceBlockMaker.copy(buffer) else { return }
            let captured = Captured(buffer: copy)
            self.queue.async { self.take(captured, for: run) }
        }
        run.engine.prepare()
        do {
            try run.engine.start()
        } catch {
            input.removeTap(onBus: 0)
            run.engine.stop()
            throw VoiceCaptureError.engine(error.localizedDescription)
        }
        run.configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: run.engine, queue: nil
        ) { [weak self, weak run] _ in
            guard let self, let run else { return }
            self.queue.async { self.reconfigure(run) }
        }
    }

    /// Removes the tap and stops the engine; the microphone is free when this returns.
    private func close(_ run: Run) {
        if let observer = run.configObserver { NotificationCenter.default.removeObserver(observer) }
        run.configObserver = nil
        run.engine.inputNode.removeTap(onBus: 0)
        run.engine.stop()
        run.engine.reset()
    }

    /// Sleep and a switch to another login session stop capture; it never resumes by itself.
    private func watch(_ run: Run) {
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, reason) in [(NSWorkspace.willSleepNotification, VoiceCaptureStop.sleep),
                               (NSWorkspace.sessionDidResignActiveNotification, VoiceCaptureStop.sessionResigned)] {
            let token = workspace.addObserver(forName: name, object: nil, queue: nil) { [weak self, weak run] _ in
                guard let self, let run else { return }
                self.halt(reason, only: run)
            }
            run.observers.append((workspace, token))
        }
    }

    /// A device or route change: the engine has stopped itself and the input
    /// may have a new format. Rebuild on a fresh engine once; if that fails —
    /// or changes keep coming — the device is gone. On queue.
    private func reconfigure(_ run: Run) {
        guard lock.withLock({ current === run }), !run.finished else { return }
        let now = Date()
        run.restarts = run.restarts.filter { now.timeIntervalSince($0) < 5 } + [now]
        close(run)
        guard run.restarts.count <= 3 else { halt(.deviceLost, only: run); return }
        // The converter follows the new rate by itself; samples it held for the
        // old device are a few milliseconds and are let go.
        run.engine = AVAudioEngine()
        do { try open(run) } catch { halt(.deviceLost, only: run) }
    }

    /// Converts one copied buffer into blocks. On queue.
    private func take(_ captured: Captured, for run: Run) {
        guard !run.finished else { return }
        do {
            for block in try run.maker.append(captured.buffer) {
                guard !run.finished else { return }     // onBlock may have stopped us
                run.onBlock(block)
            }
        } catch {
            halt(.failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription), only: run)
        }
    }

    /// Ends the current run (or only `target`, if it is still current): mic
    /// released first, then the converter's tail and `onStop`, after every
    /// block already captured. Exactly once per run.
    private func halt(_ reason: VoiceCaptureStop, only target: Run?) {
        let run = lock.withLock { () -> Run? in
            guard let run = current, target == nil || run === target else { return nil }
            current = nil
            return run
        }
        guard let run else { return }
        onQueue {
            for (center, token) in run.observers { center.removeObserver(token) }
            run.observers = []
            close(run)
            guard !run.finished else { return }
            for block in run.maker.finish() {
                guard !run.finished else { return }
                run.onBlock(block)
            }
            guard !run.finished else { return }
            run.finished = true
            run.onStop(reason)
        }
    }

    /// Runs `body` on the private queue — inline when already there (a stop
    /// from inside onBlock), so it never deadlocks on itself.
    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: onQueueKey) == true { return try body() }
        return try queue.sync(execute: body)
    }
}

/// The Mac's audio inputs by name — the names WebKit gives a page's
/// microphones — for opening one that is not the default.
enum AudioInputs {
    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Every device with an input stream, and its name.
    static func all() -> [(id: AudioDeviceID, name: String)] {
        var where_ = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &where_, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &where_, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
            var nameAt = address(kAudioObjectPropertyName)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAt, 0, nil, &nameSize, &name) == noErr,
                  let text = name?.takeRetainedValue() as String? else { return nil }
            return (id, text)
        }
    }

    static func id(named name: String) -> AudioDeviceID? {
        let inputs = all()
        guard let match = PageMicRules.device(named: name, among: inputs.map(\.name)) else { return nil }
        return inputs.first { $0.name == match }?.id
    }

    /// The default input's name.
    static var defaultName: String? {
        var where_ = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &where_, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return all().first { $0.id == id }?.name
    }

    /// The engine's input opens this device (before it starts).
    static func use(_ id: AudioDeviceID, on input: AVAudioInputNode) -> Bool {
        guard let unit = input.audioUnit else { return false }
        var device = id
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                    &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
    }
}

/// Audio in any PCM format → 16 kHz mono Float32 blocks of exactly 800
/// samples (50 ms). Channels are averaged (as Fermion's own file reader does),
/// then one long-lived AVAudioConverter changes the rate; a new input rate
/// (a device change) rebuilds it. Not thread-safe: one queue drives it.
final class VoiceBlockMaker {
    static let sampleRate = 16_000.0
    static let blockSize = 800

    private let format16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: VoiceBlockMaker.sampleRate, channels: 1, interleaved: false)

    private var converter: AVAudioConverter?
    private var converterRate = 0.0
    private var pending: [Swift.Float] = []

    /// Blocks completed by this buffer (possibly none).
    func append(_ buffer: AVAudioPCMBuffer) throws -> [[Swift.Float]] {
        guard buffer.frameLength > 0 else { return [] }
        let mono = try Self.mixdown(buffer)
        let rate = buffer.format.sampleRate
        guard rate > 0 else { throw VoiceCaptureError.unsupportedFormat }
        if rate == Self.sampleRate {
            converter = nil
            converterRate = 0
            pending.append(contentsOf: mono)
        } else {
            pending.append(contentsOf: try convert(mono, rate: rate))
        }
        return takeBlocks()
    }

    /// The end of the stream: what the converter still holds, and the last
    /// partial block padded with silence to a whole block. Ready for a new stream after.
    func finish() -> [[Swift.Float]] {
        if let converter, let out = format16k {
            let feed = Feed(nil)
            while true {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: 4_096) else { break }
                var error: NSError?
                let status = converter.convert(to: buffer, error: &error) { _, state in feed.next(state) }
                append(buffer, to: &pending)
                if status != .haveData { break }
            }
            converter.reset()
        }
        if !pending.isEmpty, pending.count % Self.blockSize != 0 {
            pending.append(contentsOf: [Swift.Float](repeating: 0, count: Self.blockSize - pending.count % Self.blockSize))
        }
        return takeBlocks()
    }

    private func takeBlocks() -> [[Swift.Float]] {
        guard pending.count >= Self.blockSize else { return [] }
        let whole = pending.count / Self.blockSize
        var blocks: [[Swift.Float]] = []
        blocks.reserveCapacity(whole)
        for i in 0..<whole { blocks.append(Array(pending[i * Self.blockSize ..< (i + 1) * Self.blockSize])) }
        pending.removeFirst(whole * Self.blockSize)
        return blocks
    }

    private func convert(_ mono: [Swift.Float], rate: Double) throws -> [Swift.Float] {
        if converter == nil || converterRate != rate {
            guard let from = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
                  let to = format16k,
                  let made = AVAudioConverter(from: from, to: to) else { throw VoiceCaptureError.unsupportedFormat }
            // The same settings Fermion's file reader uses for this model.
            made.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            made.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter = made
            converterRate = rate
        }
        guard let converter, let out = format16k,
              let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(mono.count)),
              let channel = input.floatChannelData?[0] else { throw VoiceCaptureError.unsupportedFormat }
        mono.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: mono.count)
        }
        input.frameLength = AVAudioFrameCount(mono.count)
        let capacity = AVAudioFrameCount(Double(mono.count) * Self.sampleRate / rate) + 1_024
        let feed = Feed(input)
        var converted: [Swift.Float] = []
        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: capacity) else { throw VoiceCaptureError.unsupportedFormat }
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { _, state in feed.next(state) }
            if status == .error { throw VoiceCaptureError.engine(error?.localizedDescription ?? "audio conversion failed") }
            append(buffer, to: &converted)
            if status != .haveData { break }
        }
        return converted
    }

    private func append(_ buffer: AVAudioPCMBuffer, to samples: inout [Swift.Float]) {
        guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    /// Hands the converter one buffer, then "nothing yet" (a live stream goes
    /// on); with no buffer it signals the end of the stream.
    private final class Feed: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        private let ends: Bool
        init(_ buffer: AVAudioPCMBuffer?) { self.buffer = buffer; ends = buffer == nil }
        func next(_ state: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            if let given = buffer {
                buffer = nil
                state.pointee = .haveData
                return given
            }
            state.pointee = ends ? .endOfStream : .noDataNow
            return nil
        }
    }

    /// The buffer's channels averaged, at its own rate.
    static func mixdown(_ buffer: AVAudioPCMBuffer) throws -> [Swift.Float] {
        let frames = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
        guard channels > 0 else { throw VoiceCaptureError.unsupportedFormat }
        let interleaved = buffer.format.isInterleaved, stride = buffer.stride
        var out = [Swift.Float](repeating: 0, count: frames)
        func sum<T>(_ data: UnsafePointer<UnsafeMutablePointer<T>>, _ value: (T) -> Swift.Float) {
            for c in 0..<channels {
                let p = interleaved ? data[0] + c : data[c]
                let step = interleaved ? stride : 1
                for i in 0..<frames { out[i] += value(p[i * step]) }
            }
        }
        if let data = buffer.floatChannelData {
            sum(data) { $0 }
        } else if let data = buffer.int16ChannelData {
            sum(data) { Swift.Float($0) / 32_768 }
        } else if let data = buffer.int32ChannelData {
            sum(data) { Swift.Float($0) / 2_147_483_648 }
        } else {
            throw VoiceCaptureError.unsupportedFormat
        }
        if channels > 1 {
            let scale = 1 / Swift.Float(channels)
            for i in 0..<frames { out[i] *= scale }
        }
        return out
    }

    /// A copy of a buffer the caller doesn't own (a tap's), same format.
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: max(buffer.frameLength, 1)) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = buffer.audioBufferList, destination = copy.mutableAudioBufferList
        let from = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source))
        let to = UnsafeMutableAudioBufferListPointer(destination)
        guard from.count == to.count else { return nil }
        for i in 0..<from.count {
            guard let src = from[i].mData, let dst = to[i].mData else { return nil }
            let bytes = min(from[i].mDataByteSize, to[i].mDataByteSize)
            memcpy(dst, src, Int(bytes))
            to[i].mDataByteSize = bytes
        }
        return copy
    }
}
