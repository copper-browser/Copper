import AudioToolbox
import CoreAudio
import Foundation

// The sound Copper's pages play, for a shared tab's audio track.
//
// WebKit plays every page's sound — <audio>, <video>, Web Audio, a call's
// voices — in its one GPU process ("Copper Graphics and Media"), never in the
// page's own process and never in Copper's. So the sound of a tab is heard
// where macOS can hand it over: a CoreAudio process tap (macOS 14.2) on that
// GPU process, a stereo mixdown, left audible (`.unmuted`) and private, read
// through a private aggregate device clocked by the output the pages play to.
// It is every page's sound, not one tab's: WebKit renders them all in that
// one process and says nothing about which page a sample came from. The
// picker and the bar say so (TabAudioRules).
//
// One tap for everyone listening; it runs while anyone listens and is torn
// down with the last. Rebuilt when the GPU process changes (a crash, a new
// one) or its sound stops coming (the output device it was clocked by went).
// macOS asks once whether Copper may record the sound it plays
// ("audio capture", NSAudioCaptureUsageDescription in build.sh); refused, no
// tap is made and the page is told so (TabShareAudio).

/// One listener's sound: a bounded queue filled off the main thread (the
/// tap's IO, Copper's own microphone for PageMic) and emptied on the main
/// thread by the page's asks. Sound is gathered into pieces of
/// `TabAudioRules.chunkSeconds`; when a page is waiting, the main thread
/// hears of a new piece once (not once per IO cycle).
final class PCMSink: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: PCMQueue
    private let chunk: Double
    private var gathered = Data()
    private var gatheredFrames = 0, gatheredRate = 0.0, gatheredChannels = 0
    private var wanted = false
    private var told = false
    private var arrival: (@MainActor () -> Void)?
    private var lastLevel = -120.0
    private var pieces = 0

    init(seconds: Double = TabAudioRules.heldSeconds, chunk: Double = TabAudioRules.chunkSeconds) {
        queue = PCMQueue(limit: seconds)
        self.chunk = chunk
    }

    /// Called on the main thread when a piece arrives for a page that is waiting.
    func onArrival(_ handler: @escaping @MainActor () -> Void) {
        lock.withLock { arrival = handler }
    }

    /// Any thread.
    func push(_ data: Data, frames: Int, rate: Double, channels: Int) {
        guard frames > 0, rate > 0, channels > 0 else { return }
        let notify: Bool = lock.withLock {
            if gatheredFrames > 0, gatheredRate != rate || gatheredChannels != channels { commit() }
            gathered.append(data)
            gatheredFrames += frames
            gatheredRate = rate
            gatheredChannels = channels
            guard Double(gatheredFrames) >= rate * chunk else { return false }
            commit()
            guard wanted, !told else { return false }
            told = true
            return true
        }
        guard notify else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.arrived() }
        }
    }

    /// Under the lock.
    private func commit() {
        guard gatheredFrames > 0 else { return }
        queue.push(gathered, frames: gatheredFrames, rate: gatheredRate, channels: gatheredChannels)
        lastLevel = PCM.level(gathered)
        pieces += 1
        gathered = Data()
        gatheredFrames = 0
    }

    @MainActor private func arrived() {
        let handler = lock.withLock { () -> (@MainActor () -> Void)? in
            told = false
            return arrival
        }
        handler?()
    }

    /// The page has everything up to `after`; what is newer, if anything.
    func take(after: Int) -> PCMChunk? {
        lock.withLock { queue.take(after: after) }
    }

    /// A page is (or no longer is) waiting on the next piece.
    func want(_ yes: Bool) {
        lock.withLock {
            wanted = yes
            if !yes { told = false }
        }
    }

    var report: [String: Any] {
        lock.withLock {
            ["pieces": pieces, "seq": queue.seq, "heldMs": Int((queue.held * 1000).rounded()), "droppedFrames": queue.dropped,
             "levelDb": (lastLevel * 10).rounded() / 10]
        }
    }
}

/// macOS's "audio capture" permission (kTCCServiceAudioCapture), which a
/// process tap needs. Its preflight and request are TCC's own calls, looked
/// up by name and used only where present; without them the tap is made and
/// macOS asks as it starts.
enum AudioCapturePermission {
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let framework = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var status: TabAudioRules.Permission {
        // A test world's stand-in tone needs no word from macOS.
        if TabAudioTap.mock { return .granted }
        guard let framework, let symbol = dlsym(framework, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    /// macOS's question, when it hasn't been asked; `done` on any thread.
    static func request(_ done: @escaping @Sendable (Bool) -> Void) {
        if TabAudioTap.mock { return done(true) }
        guard let framework, let symbol = dlsym(framework, "TCCAccessRequest") else { return done(true) }
        unsafeBitCast(symbol, to: Request.self)(service, nil) { granted in done(granted) }
    }

    /// System Settings › Privacy & Security › Screen & System Audio Recording,
    /// where "System Audio Recording Only" lists Copper.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
}

final class TabAudioTap: @unchecked Sendable {
    static let shared = TabAudioTap()

    private let control = DispatchQueue(label: "copper.tabaudio.control", qos: .userInitiated)
    private let io = DispatchQueue(label: "copper.tabaudio.io", qos: .userInteractive)
    private let lock = NSLock()
    /// Guarded by `lock`: everyone listening, and when sound last came.
    private var sinks: [ObjectIdentifier: PCMSink] = [:]
    private var lastIO = 0.0
    private var state = "idle"

    // The control queue's own.
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private var tapped: [AudioObjectID] = []
    private var format = Format()
    private var mockTimer: DispatchSourceTimer?
    private var builds = 0

    private struct Format {
        var rate = 48_000.0
        var channels = 2
        var interleaved = true
        var float = true
    }

    /// Test worlds only (SEARCH_SHARE_AUDIO_MOCK=1): a quiet 440 Hz tone
    /// instead of the tap, so the page's half runs end to end with no
    /// macOS question and no sound of yours.
    static let mock: Bool = Store.testing && ProcessInfo.processInfo.environment["SEARCH_SHARE_AUDIO_MOCK"] == "1"

    func attach(_ sink: PCMSink) {
        lock.withLock { sinks[ObjectIdentifier(sink)] = sink }
    }

    func detach(_ sink: PCMSink) {
        let empty = lock.withLock { () -> Bool in
            sinks[ObjectIdentifier(sink)] = nil
            return sinks.isEmpty
        }
        if empty { control.async { self.teardown(); self.setState("idle") } }
    }

    /// Once a second while anyone listens (TabShare's watchdog), and as a
    /// listener joins: the GPU processes WebKit names now. Builds, keeps or
    /// rebuilds the tap to match.
    func refresh(pids: Set<pid_t>) {
        control.async { self.reconcile(pids) }
    }

    var report: [String: Any] {
        let (state, listeners, since) = lock.withLock { (state, sinks.count, lastIO) }
        return ["state": state, "listeners": listeners, "sinceSoundMs": since > 0 ? Int((CFAbsoluteTimeGetCurrent() - since) * 1000) : NSNull(),
                "mock": TabAudioTap.mock]
    }

    private func setState(_ value: String) {
        lock.withLock { state = value }
    }

    // MARK: - the control queue

    private func reconcile(_ pids: Set<pid_t>) {
        let (empty, since) = lock.withLock { (sinks.isEmpty, lastIO) }
        guard !empty else { teardown(); setState("idle"); return }
        if TabAudioTap.mock {
            startMock()
            return
        }
        guard #available(macOS 14.2, *) else { setState("needs macOS 14.2"); return }
        let objects = TabAudioRules.gpuProcesses(Self.processes(), webKit: Set(pids.map { Int32($0) }), me: Int32(getpid()))
        guard !objects.isEmpty else {
            // No page has played a sound since WebKit's GPU process started:
            // CoreAudio doesn't know it yet. Looked for again next second;
            // the page's track is silent meanwhile.
            teardown()
            setState("waiting for a page to play sound")
            return
        }
        let running = proc != nil
        let stalled = TabAudioRules.stalled(sinceIO: since > 0 ? CFAbsoluteTimeGetCurrent() - since : .infinity, running: running)
        if running, objects == tapped, !stalled { return }
        teardown()
        build(objects)
    }

    @available(macOS 14.2, *)
    private func build(_ objects: [AudioObjectID]) {
        builds += 1
        let description = CATapDescription(stereoMixdownOfProcesses: objects)
        description.uuid = UUID()
        description.name = "Copper tab audio"
        description.isPrivate = true
        // Heard by the person as before: the tap listens, it doesn't take.
        description.muteBehavior = .unmuted
        var made = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &made)
        guard status == noErr, made != kAudioObjectUnknown else { return fail("no tap (\(status))") }
        tap = made
        tapped = objects
        format = Self.format(of: tap)
        // A process tap hands over 32-bit floats; anything else is not read as sound.
        guard format.float else { return fail("not float samples") }

        var settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Copper tab audio",
            kAudioAggregateDeviceUIDKey: "com.collinrijock.copper.tabaudio." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        // Clocked by the output the pages play to, as macOS's own samples do.
        if let output = Self.defaultOutputUID() {
            settings[kAudioAggregateDeviceMainSubDeviceKey] = output
            settings[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
        }
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return fail("no aggregate device (\(status))") }
        aggregate = device
        // The tap's sound reaches the IO at the device's own rate.
        if let rate = Self.nominalRate(of: device) { format.rate = rate }

        var made2: AudioDeviceIOProcID?
        let channels = format.channels, interleaved = format.interleaved, rate = format.rate
        status = AudioDeviceCreateIOProcIDWithBlock(&made2, aggregate, io) { [weak self] _, input, _, _, _ in
            self?.deliver(input, channels: channels, interleaved: interleaved, rate: rate)
        }
        guard status == noErr, let made2 else { return fail("no IO (\(status))") }
        proc = made2
        lock.withLock { lastIO = CFAbsoluteTimeGetCurrent() }
        status = AudioDeviceStart(aggregate, made2)
        guard status == noErr else { return fail("didn't start (\(status))") }
        setState("running")
    }

    private func fail(_ why: String) {
        teardown()
        setState("failed: " + why)
    }

    private func teardown() {
        mockTimer?.cancel()
        mockTimer = nil
        if let proc, aggregate != kAudioObjectUnknown {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
        }
        proc = nil
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        aggregate = AudioObjectID(kAudioObjectUnknown)
        if #available(macOS 14.2, *), tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        tap = AudioObjectID(kAudioObjectUnknown)
        tapped = []
        lock.withLock { lastIO = 0 }
    }

    // MARK: - the IO queue

    /// The tap's stream is the aggregate's input: the last buffer (or, not
    /// interleaved, the last one per channel) — an output device that has
    /// inputs of its own puts them first.
    private func deliver(_ input: UnsafePointer<AudioBufferList>, channels: Int, interleaved: Bool, rate: Double) {
        let listeners = lock.withLock { () -> [PCMSink] in
            lastIO = CFAbsoluteTimeGetCurrent()
            return Array(sinks.values)
        }
        guard !listeners.isEmpty else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard !buffers.isEmpty else { return }
        let data: Data, frames: Int, keep: Int
        if interleaved || channels <= 1 {
            guard let buffer = buffers.last(where: { Int($0.mNumberChannels) == channels }) ?? buffers.last,
                  let raw = buffer.mData else { return }
            let count = Int(buffer.mNumberChannels)
            guard count > 0 else { return }
            let samples = UnsafeBufferPointer(start: raw.assumingMemoryBound(to: Swift.Float.self), count: Int(buffer.mDataByteSize) / 4)
            keep = min(count, 2)
            frames = samples.count / count
            data = PCM.int16(interleaved: samples, channels: count, keep: keep)
        } else {
            let mine = Array(buffers.suffix(min(channels, 2)))
            let planes = mine.compactMap { buffer -> UnsafeBufferPointer<Swift.Float>? in
                guard let raw = buffer.mData else { return nil }
                return UnsafeBufferPointer(start: raw.assumingMemoryBound(to: Swift.Float.self), count: Int(buffer.mDataByteSize) / 4)
            }
            guard !planes.isEmpty else { return }
            keep = planes.count
            frames = planes.map(\.count).min() ?? 0
            data = PCM.int16(planar: planes)
        }
        guard frames > 0 else { return }
        for sink in listeners { sink.push(data, frames: frames, rate: rate, channels: keep) }
    }

    // MARK: - the stand-in (test worlds)

    private func startMock() {
        guard mockTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: io)
        var phase = 0.0
        let rate = 48_000.0, frames = 960
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            var samples = [Swift.Float](repeating: 0, count: frames * 2)
            for frame in 0..<frames {
                let value = Swift.Float(0.1 * sin(phase))
                phase += 2 * .pi * 440 / rate
                samples[frame * 2] = value
                samples[frame * 2 + 1] = value
            }
            if phase > 2 * .pi * 1000 { phase = phase.truncatingRemainder(dividingBy: 2 * .pi) }
            let data = samples.withUnsafeBufferPointer { PCM.int16(interleaved: $0, channels: 2, keep: 2) }
            let listeners = self.lock.withLock { () -> [PCMSink] in
                self.lastIO = CFAbsoluteTimeGetCurrent()
                return Array(self.sinks.values)
            }
            for sink in listeners { sink.push(data, frames: frames, rate: rate, channels: 2) }
        }
        timer.resume()
        mockTimer = timer
        setState("running (mock tone)")
    }

    // MARK: - CoreAudio

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    /// Every process CoreAudio knows, with what decides whether it is ours.
    static func processes() -> [TabAudioRules.AudioProcess] {
        var where_ = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &where_, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &where_, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.map { object in
            var pid: pid_t = -1
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAt = address(kAudioProcessPropertyPID)
            AudioObjectGetPropertyData(object, &pidAt, 0, nil, &pidSize, &pid)
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bundleAt = address(kAudioProcessPropertyBundleID)
            let named = AudioObjectGetPropertyData(object, &bundleAt, 0, nil, &bundleSize, &bundle) == noErr
            let id = named ? (bundle?.takeRetainedValue() as String?) ?? "" : ""
            return .init(object: object, pid: pid, bundle: id, responsible: responsible(for: pid))
        }
    }

    private typealias Responsible = @convention(c) (pid_t) -> pid_t
    private static let responsibleSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") // RTLD_DEFAULT

    /// The app macOS holds responsible for a process: an XPC service's host
    /// (what Activity Monitor groups WebKit's processes under).
    static func responsible(for pid: pid_t) -> Int32 {
        guard pid > 0, let symbol = responsibleSymbol else { return -1 }
        return unsafeBitCast(symbol, to: Responsible.self)(pid)
    }

    @available(macOS 14.2, *)
    private static func format(of tap: AudioObjectID) -> Format {
        var where_ = address(kAudioTapPropertyFormat)
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &where_, 0, nil, &size, &description) == noErr, description.mSampleRate > 0 else {
            return Format()
        }
        return Format(rate: description.mSampleRate, channels: max(1, Int(description.mChannelsPerFrame)),
                      interleaved: description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
                      float: description.mFormatFlags & kAudioFormatFlagIsFloat != 0)
    }

    private static func nominalRate(of device: AudioObjectID) -> Double? {
        var where_ = address(kAudioDevicePropertyNominalSampleRate)
        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device, &where_, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }

    private static func defaultOutputUID() -> String? {
        var where_ = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &where_, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        var uidAt = address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &uidAt, 0, nil, &uidSize, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }
}
