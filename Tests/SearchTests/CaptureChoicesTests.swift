import Foundation
import Testing
@testable import Search

// Pages asking for the camera and the microphone (Fork/Capture/CaptureChoices.swift):
// requests wait their turn and are never refused for arriving second, one
// answer settles every request it covers, Allow is kept per site and per
// device, "Don't allow" is never written down, and the older per-type keys
// carry their grants over and drop their refusals.

/// Stands in for WebKit's decision handler.
private final class Handle {
    let name: String
    init(_ name: String) { self.name = name }
}

private func names(_ requests: [CaptureQueue<Handle>.Request]) -> [String] { requests.map(\.handle.name) }

private let meet = "meet.google.com"

// MARK: - devices

@Test func webKitCaptureTypesMapToDevices() {
    #expect(CaptureDevices(webKitType: 0) == .camera)
    #expect(CaptureDevices(webKitType: 1) == .microphone)
    #expect(CaptureDevices(webKitType: 2) == .both)
    // Anything newer is read as both, never as less.
    #expect(CaptureDevices(webKitType: 7) == .both)
    #expect(CaptureDevices.both.words == "camera and microphone")
    #expect(CaptureDevices(names: ["camera", "microphone", "telepathy"]) == .both)
}

@Test func sitesAreHostsWithTheirPortWhenGiven() {
    #expect(CaptureChoices.site(host: "Meet.Google.com", port: 0) == meet)
    #expect(CaptureChoices.site(host: "localhost", port: 8123) == "localhost:8123")
}

// MARK: - the queue

@Test func aSecondRequestWaitsInsteadOfBeingRefused() {
    var queue = CaptureQueue<Handle>()
    let choices = CaptureChoices()
    let first = queue.ask(site: meet, devices: .microphone, tab: nil, handle: Handle("mic"), choices: choices)
    let second = queue.ask(site: meet, devices: .camera, tab: nil, handle: Handle("camera"), choices: choices)
    #expect(first.granted.isEmpty && first.denied.isEmpty)
    #expect(second.granted.isEmpty && second.denied.isEmpty)
    #expect(names(queue.waiting) == ["mic", "camera"])
    // The oldest is asked about first, for what it alone needs.
    #expect(queue.question(choices) == CaptureQuestion(site: meet, devices: .microphone, tab: nil, settles: 1))
}

@Test func oneAllowSettlesEveryRequestForTheSameSiteAndDevice() {
    var queue = CaptureQueue<Handle>()
    var choices = CaptureChoices()
    let tabA = UUID(), tabB = UUID()
    _ = queue.ask(site: meet, devices: .microphone, tab: tabA, handle: Handle("a-mic"), choices: choices)
    _ = queue.ask(site: meet, devices: .microphone, tab: tabB, handle: Handle("b-mic"), choices: choices)
    _ = queue.ask(site: "zoom.us", devices: .microphone, tab: tabB, handle: Handle("zoom"), choices: choices)
    _ = queue.ask(site: meet, devices: .camera, tab: tabA, handle: Handle("a-camera"), choices: choices)
    let question = queue.question(choices)!
    #expect(question.settles == 2)
    let settled = queue.allow(question, choices: &choices)
    #expect(names(settled.granted) == ["a-mic", "b-mic"])
    #expect(settled.denied.isEmpty)
    // The other site and the other device are still asked about, one at a time.
    #expect(names(queue.waiting) == ["zoom", "a-camera"])
    #expect(choices.covers(meet, .microphone))
    #expect(!choices.covers(meet, .camera))
}

@Test func allowingBothSettlesTheSingleDeviceRequestsToo() {
    var queue = CaptureQueue<Handle>()
    var choices = CaptureChoices()
    _ = queue.ask(site: meet, devices: .both, tab: nil, handle: Handle("both"), choices: choices)
    _ = queue.ask(site: meet, devices: .microphone, tab: nil, handle: Handle("mic"), choices: choices)
    _ = queue.ask(site: meet, devices: .camera, tab: nil, handle: Handle("camera"), choices: choices)
    let question = queue.question(choices)!
    #expect(question.devices == .both)
    #expect(question.settles == 3)
    let settled = queue.allow(question, choices: &choices)
    #expect(names(settled.granted) == ["both", "mic", "camera"])
    #expect(queue.isEmpty)
}

@Test func aRememberedSiteIsGrantedWithoutWaitingEvenBehindOthers() {
    var queue = CaptureQueue<Handle>()
    var choices = CaptureChoices()
    choices.allow(meet, .microphone)
    _ = queue.ask(site: "zoom.us", devices: .microphone, tab: nil, handle: Handle("zoom"), choices: choices)
    let settled = queue.ask(site: meet, devices: .microphone, tab: nil, handle: Handle("meet"), choices: choices)
    #expect(names(settled.granted) == ["meet"])
    #expect(names(queue.waiting) == ["zoom"])
}

@Test func aSiteAllowedTheMicrophoneIsOnlyAskedAboutTheCamera() {
    var queue = CaptureQueue<Handle>()
    var choices = CaptureChoices()
    choices.allow(meet, .microphone)
    _ = queue.ask(site: meet, devices: .both, tab: nil, handle: Handle("both"), choices: choices)
    let question = queue.question(choices)!
    #expect(question.devices == .camera)
    let settled = queue.allow(question, choices: &choices)
    #expect(names(settled.granted) == ["both"])
    #expect(choices.allowed[meet] == .both)
}

@Test func dontAllowRefusesWhatNeedsThatDeviceAndAsksAboutTheRest() {
    var queue = CaptureQueue<Handle>()
    let choices = CaptureChoices()
    _ = queue.ask(site: meet, devices: .camera, tab: nil, handle: Handle("camera"), choices: choices)
    _ = queue.ask(site: meet, devices: .both, tab: nil, handle: Handle("both"), choices: choices)
    _ = queue.ask(site: meet, devices: .microphone, tab: nil, handle: Handle("mic"), choices: choices)
    _ = queue.ask(site: "zoom.us", devices: .camera, tab: nil, handle: Handle("zoom"), choices: choices)
    let settled = queue.deny(queue.question(choices)!)
    #expect(names(settled.denied) == ["camera", "both"])
    #expect(settled.granted.isEmpty)
    // The microphone was not what you said no to: it is the next question.
    #expect(names(queue.waiting) == ["mic", "zoom"])
    #expect(queue.question(choices)?.devices == .microphone)
}

@Test func anotherWindowsAllowSettlesWhatItCovers() {
    var queue = CaptureQueue<Handle>()
    var choices = CaptureChoices()
    _ = queue.ask(site: meet, devices: .microphone, tab: nil, handle: Handle("mic"), choices: choices)
    _ = queue.ask(site: meet, devices: .both, tab: nil, handle: Handle("both"), choices: choices)
    choices.allow(meet, .microphone)
    #expect(names(queue.settle(choices).granted) == ["mic"])
    #expect(names(queue.waiting) == ["both"])
}

@Test func requestsNobodyWaitsOnLeaveAndAreRefused() {
    var queue = CaptureQueue<Handle>()
    let choices = CaptureChoices()
    let closed = UUID(), open = UUID()
    _ = queue.ask(site: meet, devices: .microphone, tab: closed, handle: Handle("gone"), choices: choices)
    _ = queue.ask(site: meet, devices: .microphone, tab: open, handle: Handle("here"), choices: choices)
    let settled = queue.drop { $0.tab == closed }
    #expect(names(settled.denied) == ["gone"])
    #expect(names(queue.waiting) == ["here"])
    #expect(names(queue.dropAll().denied) == ["here"])
    #expect(queue.isEmpty)
}

@Test func everyHandleComesOutExactlyOnce() {
    // Whatever order things happen in, nothing is answered twice or lost.
    var queue = CaptureQueue<Handle>()
    var choices = CaptureChoices()
    var answered: [String] = []
    func take(_ settled: CaptureQueue<Handle>.Settled) { answered += names(settled.granted) + names(settled.denied) }
    let sites = [meet, "zoom.us", "app.slack.com"]
    let devices: [CaptureDevices] = [.microphone, .camera, .both]
    var asked: [String] = []
    for i in 0..<30 {
        let name = "r\(i)"
        asked.append(name)
        take(queue.ask(site: sites[i % 3], devices: devices[(i / 3) % 3], tab: nil, handle: Handle(name), choices: choices))
        if i % 4 == 3, let question = queue.question(choices) {
            take(i % 8 == 3 ? queue.allow(question, choices: &choices) : queue.deny(question))
        }
    }
    while let question = queue.question(choices) { take(queue.deny(question)) }
    #expect(queue.isEmpty)
    #expect(answered.sorted() == asked.sorted())
}

// MARK: - remembering, and the older keys

@Test func onlyAllowIsKeptPerSiteAndDevice() {
    var choices = CaptureChoices()
    choices.allow(meet, .microphone)
    choices.allow("zoom.us", .both)
    choices.allow("example.com", [])
    #expect(choices.encoded == [meet: ["microphone"], "zoom.us": ["microphone", "camera"]])
    let (back, spent) = CaptureChoices.load(from: [CaptureChoices.key: choices.encoded])
    #expect(back == choices)
    #expect(spent.isEmpty)
    choices.forget(meet)
    #expect(!choices.covers(meet, .microphone))
}

@Test func olderKeysCarryTheirGrantsOverAndDropTheirRefusals() {
    let old: [String: Any] = [
        "capture.meet.google.com|1": true,           // microphone allowed
        "capture.meet.google.com|0": false,          // camera refused — forgotten, asked again
        "capture.zoom.us|2": true,                   // camera and microphone allowed
        "capture.app.slack.com|2": false,            // the permanent silent "no": gone
        "capture.This page|1": true,                 // no site to keep
        "capture.mock": true,                        // not a choice
        "sidebar": true,
    ]
    let (choices, spent) = CaptureChoices.load(from: old)
    #expect(choices.allowed == [meet: .microphone, "zoom.us": .both])
    #expect(!choices.covers(meet, .camera))
    #expect(!choices.covers("app.slack.com", .microphone))
    #expect(spent == ["capture.This page|1", "capture.app.slack.com|2", "capture.meet.google.com|0",
                      "capture.meet.google.com|1", "capture.zoom.us|2"])
}

@Test func olderKeysJoinWhatIsAlreadyKept() {
    let (choices, _) = CaptureChoices.load(from: [
        CaptureChoices.key: [meet: ["camera"]],
        "capture.meet.google.com|1": true,
    ])
    #expect(choices.allowed[meet] == .both)
}

// MARK: - what WebKit holds back

@Test func oneQuestionCoversWhatThePageStillHasInFlight() {
    // WebKit passes the microphone request on and holds the camera one back;
    // the page said it asked for both, so both are asked about at once.
    var queue = CaptureQueue<Handle>()
    var choices = CaptureChoices()
    var wants = CaptureWants()
    wants.began(.microphone)
    wants.began(.camera)
    _ = queue.ask(site: meet, devices: .microphone, tab: nil, handle: Handle("mic"), choices: choices)
    let question = queue.question(choices) { _ in wants.devices }!
    #expect(question.devices == .both)
    let settled = queue.allow(question, choices: &choices)
    #expect(names(settled.granted) == ["mic"])
    // The camera request, when WebKit passes it on, is granted on the spot.
    let later = queue.ask(site: meet, devices: .camera, tab: nil, handle: Handle("camera"), choices: choices)
    #expect(names(later.granted) == ["camera"])
}

@Test func wantsAreCountedPerCall() {
    var wants = CaptureWants()
    wants.began(.microphone)
    wants.began(.both)
    #expect(wants.devices == .both)
    wants.ended(.both)
    #expect(wants.devices == .microphone)
    wants.ended(.microphone)
    wants.ended(.microphone)   // an extra end never goes below nothing
    #expect(wants.isEmpty)
    wants.began(.camera)
    #expect(wants.devices == .camera)
}

@Test func aRefusalCoversWhatWasHeldBackForAFewSecondsOnly() {
    let now = Date()
    let refusal = CaptureRefusal(site: meet, devices: .both, until: now.addingTimeInterval(10))
    #expect(refusal.refuses(meet, .camera, at: now))
    #expect(refusal.refuses(meet, .microphone, at: now.addingTimeInterval(9)))
    #expect(!refusal.refuses("zoom.us", .camera, at: now))
    #expect(!refusal.refuses(meet, .camera, at: now.addingTimeInterval(10)))
    let microphoneOnly = CaptureRefusal(site: meet, devices: .microphone, until: now.addingTimeInterval(10))
    #expect(!microphoneOnly.refuses(meet, .camera, at: now))
}

// MARK: - a request that may not be what it says

@Test func aRequestNotToBeKeptIsAlwaysAskedAndNeverRemembered() {
    // A "camera" request the page never made through getUserMedia (a screen
    // share, on WebKit versions that ask that way).
    var queue = CaptureQueue<Handle>()
    var choices = CaptureChoices()
    choices.allow(meet, .camera)
    let first = queue.ask(site: meet, devices: .camera, tab: nil, handle: Handle("share"), choices: choices, keep: false)
    #expect(first.granted.isEmpty)   // the camera's Allow doesn't let a screen share in
    _ = queue.ask(site: meet, devices: .microphone, tab: nil, handle: Handle("mic"), choices: choices)
    let question = queue.question(choices)!
    #expect(question.keep == false && question.devices == .camera && question.settles == 1)
    var after = CaptureChoices()
    let settled = queue.allow(question, choices: &after)
    #expect(names(settled.granted) == ["share"])
    #expect(after.allowed.isEmpty)   // nothing written down
    #expect(names(queue.waiting) == ["mic"])
    // Refusing one touches only it.
    _ = queue.ask(site: meet, devices: .camera, tab: nil, handle: Handle("share2"), choices: choices, keep: false)
    let next = queue.question(choices)!
    #expect(next.keep)               // the microphone came first
    _ = queue.allow(next, choices: &choices)
    #expect(names(queue.deny(queue.question(choices)!).denied) == ["share2"])
    #expect(queue.isEmpty)
}

// MARK: - review fixes

@Test func pagesWithNoHostAreAskedAboutOneByOne() {
    // A file or data: page has no site to tell it from another: one Allow
    // lets in the page it was asked for, and nothing is remembered.
    var queue = CaptureQueue<Handle>()
    var choices = CaptureChoices()
    let fileA = UUID(), fileB = UUID()
    _ = queue.ask(site: "", devices: .microphone, tab: fileA, handle: Handle("a"), choices: choices, keep: false)
    _ = queue.ask(site: "", devices: .microphone, tab: fileB, handle: Handle("b"), choices: choices, keep: false)
    let question = queue.question(choices)!
    #expect(question.keep == false && question.settles == 1 && question.tab == fileA)
    #expect(names(queue.allow(question, choices: &choices).granted) == ["a"])
    #expect(choices.allowed.isEmpty)
    #expect(names(queue.waiting) == ["b"])
    // Refusing touches only the page asked about, too.
    _ = queue.ask(site: "", devices: .microphone, tab: fileA, handle: Handle("a2"), choices: choices, keep: false)
    #expect(names(queue.deny(queue.question(choices)!).denied) == ["b"])
    #expect(names(queue.waiting) == ["a2"])
}

@Test func aQuestionNotToBeKeptAnswersItsOwnTabsRequestOnly() {
    // Two possible screen shares from one site in two tabs: each is its own question.
    var queue = CaptureQueue<Handle>()
    var choices = CaptureChoices()
    let tabA = UUID(), tabB = UUID()
    _ = queue.ask(site: meet, devices: .camera, tab: tabB, handle: Handle("b"), choices: choices, keep: false)
    _ = queue.ask(site: meet, devices: .camera, tab: tabA, handle: Handle("a"), choices: choices, keep: false)
    let question = queue.question(choices)!
    #expect(question.tab == tabB)
    #expect(names(queue.allow(question, choices: &choices).granted) == ["b"])
    #expect(names(queue.waiting) == ["a"])
}

@Test func theBarsWordsAreWhatAnAnswerIsCheckedAgainst() {
    let asked = CaptureQuestion(site: meet, devices: .microphone, tab: nil, settles: 1)
    // Another request from the site joining changes nothing you read.
    #expect(asked.reads(like: CaptureQuestion(site: meet, devices: .microphone, tab: nil, settles: 3)))
    // The page widening its question under the pointer does.
    #expect(!asked.reads(like: CaptureQuestion(site: meet, devices: .both, tab: nil, settles: 1)))
    #expect(!asked.reads(like: CaptureQuestion(site: "zoom.us", devices: .microphone, tab: nil, settles: 1)))
    #expect(!asked.reads(like: CaptureQuestion(site: meet, devices: .microphone, tab: nil, settles: 1, keep: false)))
    #expect(asked.asking(.camera) == CaptureQuestion(site: meet, devices: .camera, tab: nil, settles: 1))
}

@Test func macOSRefusingOneDeviceCostsTheCallOnlyThatDevice() {
    // The page asks for the microphone and has the camera in flight; macOS
    // lets Copper have the microphone but not the camera. Allow lets the
    // microphone in (and keeps it), and refuses only what needs the camera
    // (CaptureDesk.admit).
    var queue = CaptureQueue<Handle>()
    var choices = CaptureChoices()
    _ = queue.ask(site: meet, devices: .microphone, tab: nil, handle: Handle("mic"), choices: choices)
    _ = queue.ask(site: meet, devices: .both, tab: nil, handle: Handle("both"), choices: choices)
    let question = queue.question(choices) { _ in .camera }!
    #expect(question.devices == .both)
    let blocked: CaptureDevices = .camera
    let granted = queue.allow(question.asking(question.devices.subtracting(blocked)), choices: &choices)
    let denied = queue.deny(question.asking(blocked))
    #expect(names(granted.granted) == ["mic"])
    #expect(names(denied.denied) == ["both"])
    #expect(choices.allowed[meet] == .microphone)
    #expect(queue.isEmpty)
}

@Test func aPagesOwnMuteIsTakenOnItsWordItsUnmuteOnlyWhenSeen() {
    var own = CaptureOwnMutes(live: .both)
    // The page mutes both, one call after the other; the camera is still
    // live when the microphone's mute is first seen. That is not an unmute.
    own.said(muted: .microphone)
    own.said(muted: .camera)
    own.saw(live: .camera)
    #expect(own.muted == .both)
    own.saw(live: [])
    #expect(own.muted == .both)
    // Live again since last looked at: the page unmuted itself.
    own.saw(live: .microphone)
    #expect(own.muted == .camera)
    // Muted before it ever captured, then it starts: afresh.
    var early = CaptureOwnMutes()
    early.said(muted: .microphone)
    early.saw(live: .microphone)
    #expect(early.muted.isEmpty)
    early.said(muted: .camera)
    early.forget()
    #expect(early.muted.isEmpty)
}

@Test func thePageOnScreenTakesItsDevicesBackOnItsOwnOnlyWhenNobodyElseCaptures() {
    #expect(CaptureTurn.on(paused: [], othersLive: .microphone) == .nothing)
    #expect(CaptureTurn.on(paused: .microphone, othersLive: []) == .resume)
    #expect(CaptureTurn.on(paused: .microphone, othersLive: .microphone) == .offer)
    // An audio-only call in another tab is never paused because the tab on
    // screen had its camera paused: the bar offers it instead.
    #expect(CaptureTurn.on(paused: .camera, othersLive: .microphone) == .offer)
}
