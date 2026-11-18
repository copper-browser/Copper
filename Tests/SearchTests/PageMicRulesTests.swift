import Foundation
import Testing
@testable import Search

// Who hears a page's microphone request (Fork/Capture/PageMicRules.swift):
// WebKit, which pauses every other page's capture when it starts one, or
// Copper's own microphone, which pauses nothing.

private func route(main: Bool = true, audio: Bool = true, video: Bool = false, others: Bool = true, me: Bool = false,
                   macOS: Bool = true, headless: Bool = false) -> PageMicRules.Route {
    PageMicRules.route(mainFrame: main, audio: audio, video: video, othersCapturing: others, selfCapturing: me,
                       macOSAllows: macOS, headless: headless)
}

@Test func aSecondPageAskingForTheMicrophoneGetsCoppersOwn() {
    // Meet is on a call in one tab; a transcriber asks for the microphone in another.
    #expect(route() == .copper)
}

@Test func withNoOtherPageCapturingWebKitHasItsOwnWay() {
    #expect(route(others: false) == .webkit)
}

@Test func theCameraTooIsWebKitsAsBefore() {
    // WebKit would pause the call for the camera anyway; the page keeps its
    // echo cancellation and its device choice.
    #expect(route(video: true) == .webkit)
    #expect(route(audio: false, video: true) == .webkit)
    #expect(route(audio: false) == .webkit)
}

@Test func aFrameAPageAlreadyCapturingMacOSAndHeadlessAreWebKits() {
    #expect(route(main: false) == .webkit)
    #expect(route(me: true) == .webkit)
    #expect(route(macOS: false) == .webkit)
    #expect(route(headless: true) == .webkit)
}

@Test func theChosenMicrophoneIsFoundByTheNameWebKitGaveIt() {
    let names = ["MacBook Pro Microphone", "AirPods Pro", "Shure MV7"]
    #expect(PageMicRules.device(named: "AirPods Pro", among: names) == "AirPods Pro")
    #expect(PageMicRules.device(named: "shure mv7", among: names) == "Shure MV7")
    #expect(PageMicRules.device(named: "  AirPods Pro ", among: names) == "AirPods Pro")
    // Unknown, empty or not given: the Mac's default input.
    #expect(PageMicRules.device(named: "Studio Display Microphone", among: names) == nil)
    #expect(PageMicRules.device(named: "", among: names) == nil)
    #expect(PageMicRules.device(named: nil, among: names) == nil)
}

@Test func theTrackIsNamedForTheDeviceItHears() {
    #expect(PageMicRules.label(device: "AirPods Pro", fallback: "MacBook Pro Microphone") == "AirPods Pro")
    #expect(PageMicRules.label(device: nil, fallback: "MacBook Pro Microphone") == "MacBook Pro Microphone")
    #expect(PageMicRules.label(device: nil, fallback: nil) == "Microphone")
}

@Test func aPageThatStopsAskingForSoundLetsTheMicrophoneGo() {
    #expect(!PageMicRules.quiet(sinceAsked: 1))
    #expect(PageMicRules.quiet(sinceAsked: PageMicRules.quietSeconds + 1))
}
