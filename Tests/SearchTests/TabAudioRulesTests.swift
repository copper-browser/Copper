import Foundation
import Testing
@testable import Search

// A shared tab's sound (Fork/TabShare/TabAudioRules.swift): the picker's
// "Also share tab audio" switch, the bounded queue a page's sound waits in,
// the 16-bit framing, and which process is Copper's pages' sound.

// MARK: - the switch

@Test func theSwitchIsOnWhenThePageAskedForAudio() {
    let audio = TabAudioRules.audioSwitch(asked: true, canShareTab: true, callerHost: "rgs.apps.exowatt.com",
                                          callerPlaying: false, permission: .granted)
    #expect(audio.shown && audio.on && audio.enabled)
    #expect(TabAudioRules.sharesAudio(audio, on: true))
    #expect(!TabAudioRules.sharesAudio(audio, on: false))
    // Honest about what goes.
    #expect(TabAudioRules.note(audio, on: true) == "All of Copper's sound, not only this tab's")
}

@Test func noSwitchWhenThePageDidNotAskOrCannotBeHandedATab() {
    #expect(TabAudioRules.audioSwitch(asked: false, canShareTab: true, callerHost: "a.com", callerPlaying: false,
                                      permission: .granted) == TabAudioRules.AudioSwitch())
    let frameless = TabAudioRules.audioSwitch(asked: true, canShareTab: false, callerHost: "a.com", callerPlaying: false,
                                              permission: .granted)
    #expect(!frameless.shown)
    #expect(!TabAudioRules.sharesAudio(frameless, on: true))
    #expect(TabAudioRules.note(frameless, on: true).isEmpty)
}

@Test func aPagePlayingSoundItselfStartsWithTheSwitchOff() {
    // A call presenting a tab would be sent its own voices back.
    let audio = TabAudioRules.audioSwitch(asked: true, canShareTab: true, callerHost: "meet.google.com",
                                          callerPlaying: true, permission: .granted)
    #expect(audio.shown && audio.enabled && !audio.on)
    #expect(TabAudioRules.note(audio, on: false) == "Off: meet.google.com would hear itself")
    // It can still be turned on, and says what that means.
    #expect(TabAudioRules.sharesAudio(audio, on: true))
    #expect(TabAudioRules.note(audio, on: true).contains("hears its own too"))
}

@Test func macOSRefusingAudioCaptureLeavesTheSwitchOffAndDimmed() {
    let audio = TabAudioRules.audioSwitch(asked: true, canShareTab: true, callerHost: "a.com", callerPlaying: false,
                                          permission: .denied)
    #expect(audio.shown && !audio.enabled && !audio.on)
    // Even turned "on" by a stray key, nothing is shared.
    #expect(!TabAudioRules.sharesAudio(audio, on: true))
    #expect(TabAudioRules.note(audio, on: true) == "Copper isn't allowed to record audio")
    // Not asked yet: on, and macOS asks when it is chosen.
    #expect(TabAudioRules.audioSwitch(asked: true, canShareTab: true, callerHost: "a.com", callerPlaying: false,
                                      permission: .unknown).on)
}

// MARK: - the queue

private func piece(_ frames: Int, rate: Double = 48_000, channels: Int = 2) -> Data {
    Data(count: frames * channels * 2)
}

@Test func theQueueNeverHoldsMoreThanItsLimitAndDropsTheOldest() {
    var queue = PCMQueue(limit: 0.25)
    // A second of 20 ms pieces with nobody taking any.
    for _ in 0..<50 { queue.push(piece(960), frames: 960, rate: 48_000, channels: 2) }
    #expect(queue.seq == 50)
    #expect(queue.held <= 0.25 + 1e-9)
    #expect(queue.chunks.count == 12)
    #expect(queue.chunks.first?.seq == 39 && queue.chunks.last?.seq == 50)
    #expect(queue.dropped == 38 * 960)
}

@Test func theNewestPieceIsKeptHoweverLongItIs() {
    var queue = PCMQueue(limit: 0.25)
    queue.push(piece(48_000), frames: 48_000, rate: 48_000, channels: 2)
    #expect(queue.chunks.count == 1)
    queue.push(piece(960), frames: 960, rate: 48_000, channels: 2)
    #expect(queue.chunks.map(\.seq) == [2])
}

@Test func whatThePageHasIsLetGoAndTheRestJoined() {
    var queue = PCMQueue(limit: 1)
    for _ in 0..<5 { queue.push(piece(960), frames: 960, rate: 48_000, channels: 2) }
    let first = queue.take(after: 0)
    #expect(first?.seq == 5)
    #expect(first?.frames == 4_800)
    #expect(first?.data.count == 4_800 * 4)
    // The page says it has up to 5: nothing new, nothing held.
    #expect(queue.take(after: 5) == nil)
    #expect(queue.chunks.isEmpty && queue.held == 0)
}

@Test func aReplyNeverJoinsMoreThanAQuarterSecondNorMixesFormats() {
    var queue = PCMQueue(limit: 2)
    for _ in 0..<30 { queue.push(piece(960), frames: 960, rate: 48_000, channels: 2) }
    let reply = queue.peek(after: 0, most: 0.25)
    #expect(reply?.frames == 12 * 960)
    #expect(reply?.seq == 12)
    // A new rate (another output device) is a piece of its own.
    var mixed = PCMQueue(limit: 2)
    mixed.push(piece(960), frames: 960, rate: 48_000, channels: 2)
    mixed.push(piece(882, channels: 2), frames: 882, rate: 44_100, channels: 2)
    #expect(mixed.peek(after: 0)?.frames == 960)
    #expect(mixed.peek(after: 1)?.rate == 44_100)
}

@Test func nonsenseIsNotQueued() {
    var queue = PCMQueue()
    queue.push(Data(), frames: 0, rate: 48_000, channels: 2)
    queue.push(piece(10), frames: 10, rate: 0, channels: 2)
    queue.push(piece(10), frames: 10, rate: 48_000, channels: 0)
    #expect(queue.seq == 0 && queue.chunks.isEmpty)
}

@Test func theReplyIsWhatThePagesScriptReads() {
    let chunk = PCMChunk(seq: 3, frames: 2, rate: 16_000, channels: 1, data: PCM.int16([0.5, -0.5]))
    let reply = chunk.reply
    #expect(reply["seq"] as? Int == 3)
    #expect(reply["frames"] as? Int == 2)
    #expect(reply["rate"] as? Double == 16_000)
    #expect(reply["channels"] as? Int == 1)
    #expect(Data(base64Encoded: reply["data"] as? String ?? "") == chunk.data)
}

// MARK: - the sink (the tap's IO thread to the main thread)

@Test func theSinkGathersTwentyMillisecondPieces() {
    let sink = PCMSink(seconds: 0.25, chunk: 0.02)
    // 10 ms at a time, as a short IO cycle hands it over.
    for _ in 0..<4 { sink.push(piece(480), frames: 480, rate: 48_000, channels: 2) }
    let got = sink.take(after: 0)
    #expect(got?.frames == 1_920)
    #expect(got?.seq == 2)
    #expect(sink.take(after: 2) == nil)
}

@Test func theSinkStaysBoundedWhenNobodyListens() {
    let sink = PCMSink(seconds: 0.25, chunk: 0.02)
    for _ in 0..<500 { sink.push(piece(960), frames: 960, rate: 48_000, channels: 2) }
    let held = sink.report["heldMs"] as? Int ?? 0
    #expect(held <= 250)
    #expect((sink.report["droppedFrames"] as? Int ?? 0) > 400 * 960)
}

// MARK: - framing

@Test func floatsBecomeLittleEndianSixteenBitClamped() {
    let data = PCM.int16([0, 1, -1, 2, -2, .nan, 0.5])
    let values = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)).map { Int16(littleEndian: $0) } }
    #expect(values == [0, 32_767, -32_767, 32_767, -32_767, 0, 16_384])
    #expect(data.count == 14)
}

@Test func interleavedStereoKeepsTwoChannelsAndMonoIsCopiedToBoth() {
    let stereo: [Swift.Float] = [0.5, -0.5, 0.25, -0.25]
    let kept = stereo.withUnsafeBufferPointer { PCM.int16(interleaved: $0, channels: 2, keep: 2) }
    #expect(PCM.floats(kept).count == 4)
    // Four channels in, the first two out.
    let quad: [Swift.Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
    let two = quad.withUnsafeBufferPointer { PCM.int16(interleaved: $0, channels: 4, keep: 2) }
    let back = PCM.floats(two)
    #expect(back.count == 4)
    #expect(abs(back[0] - 0.1) < 0.001 && abs(back[1] - 0.2) < 0.001 && abs(back[2] - 0.5) < 0.001)
    // One channel, kept twice.
    let mono: [Swift.Float] = [0.5, 0.25]
    let both = PCM.floats(mono.withUnsafeBufferPointer { PCM.int16(interleaved: $0, channels: 1, keep: 2) })
    #expect(both.count == 4 && abs(both[0] - both[1]) < 0.0001 && abs(both[2] - 0.25) < 0.001)
}

@Test func planarChannelsAreInterleaved() {
    let left: [Swift.Float] = [0.5, 0.5], right: [Swift.Float] = [-0.5, -0.5]
    let data = left.withUnsafeBufferPointer { l in right.withUnsafeBufferPointer { r in PCM.int16(planar: [l, r]) } }
    let back = PCM.floats(data)
    #expect(back.count == 4)
    #expect(back[0] > 0.49 && back[1] < -0.49 && back[2] > 0.49 && back[3] < -0.49)
}

@Test func theLevelIsDecibelsBelowFullScale() {
    #expect(PCM.level(Data()) == -120)
    #expect(PCM.level(PCM.int16([Swift.Float](repeating: 0, count: 100))) == -120)
    let loud = PCM.level(PCM.int16([Swift.Float](repeating: 0.1, count: 100)))
    #expect(abs(loud - -20) < 0.1)
}

// MARK: - which process

@Test func theTapIsWebKitsGPUProcessForThisCopperNeverAnotherApps() {
    let me: Int32 = 500
    let all: [TabAudioRules.AudioProcess] = [
        .init(object: 10, pid: 500, bundle: "com.collinrijock.copper", responsible: 500),
        .init(object: 11, pid: 601, bundle: "com.apple.WebKit.GPU", responsible: 500),
        .init(object: 12, pid: 700, bundle: "com.apple.WebKit.GPU", responsible: 690), // Safari's
        .init(object: 13, pid: 701, bundle: "com.apple.Music", responsible: 701),
    ]
    // WebKit named its GPU process: that one.
    #expect(TabAudioRules.gpuProcesses(all, webKit: [601], me: me) == [11])
    // It didn't: a WebKit GPU process macOS holds this Copper responsible for.
    #expect(TabAudioRules.gpuProcesses(all, webKit: [], me: me) == [11])
    // A pid CoreAudio doesn't know (no page has played sound yet): the fallback.
    #expect(TabAudioRules.gpuProcesses(all, webKit: [999], me: me) == [11])
    // Nobody's: nothing (the tap waits).
    #expect(TabAudioRules.gpuProcesses(Array(all.dropFirst(2)), webKit: [], me: me).isEmpty)
}

@Test func aTapWhoseSoundStoppedIsRebuilt() {
    #expect(!TabAudioRules.stalled(sinceIO: 0.5, running: true))
    #expect(TabAudioRules.stalled(sinceIO: 3, running: true))
    #expect(!TabAudioRules.stalled(sinceIO: 30, running: false))
}
