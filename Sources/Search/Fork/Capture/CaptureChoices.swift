import Foundation

// Fork (page-capture): what a page asking for the camera or the microphone is
// answered with, and the order the questions are put in. Pure rules — no
// WebKit, no window, no AVFoundation — so they are tested on their own
// (Tests/SearchTests/CaptureChoicesTests.swift). CaptureDesk.swift is where
// they meet WebKit and the bar at the bottom of the window.
//
// What these rules replace, and why each one changed:
//
// - One question at a time, with a second page asking while the first
//   waited refused outright. A call page asks for the microphone and the
//   camera in quick succession, often from two places at once, and the one
//   that lost the race got "no" without anybody being asked — no microphone,
//   and nothing on screen to say why. Every request now waits its turn, and
//   one answer settles every request it covers.
// - A remembered "no", forever, under "host|WebKit's capture type". One
//   "Don't allow" — or a slip of the pointer — kept the microphone from that
//   site from then on, with nothing in the page to undo it. And the keys
//   didn't overlap: "microphone" allowed said nothing about "camera and
//   microphone". Now only Allow is kept, per site and per device (a request
//   for both needs both). "Don't allow" answers the page in front of you and
//   is not written down: WebKit itself refuses that page's further asks
//   until it loads again (unless you click in the page to ask), and after a
//   reload you are simply asked again.

/// The devices a page can ask to use.
struct CaptureDevices: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let microphone = CaptureDevices(rawValue: 1 << 0)
    static let camera = CaptureDevices(rawValue: 1 << 1)
    static let both: CaptureDevices = [.microphone, .camera]

    init(rawValue: Int) { self.rawValue = rawValue }

    /// WebKit's `WKMediaCaptureType`, by its raw value: 0 camera, 1
    /// microphone, 2 camera and microphone. Anything newer asks for both,
    /// the safe reading — it is never granted on less than both.
    init(webKitType raw: Int) {
        switch raw {
        case 0: self = .camera
        case 1: self = .microphone
        default: self = .both
        }
    }

    /// The words the bar uses: "microphone", "camera", "camera and microphone".
    var words: String {
        switch self {
        case .microphone: return "microphone"
        case .camera: return "camera"
        default: return "camera and microphone"
        }
    }

    /// How each device is written in Copper's settings.
    var names: [String] {
        var out: [String] = []
        if contains(.microphone) { out.append("microphone") }
        if contains(.camera) { out.append("camera") }
        return out
    }

    init(names: [String]) {
        var devices: CaptureDevices = []
        for name in names {
            switch name {
            case "microphone": devices.insert(.microphone)
            case "camera": devices.insert(.camera)
            default: break
            }
        }
        self = devices
    }
}

/// What a site has been allowed, per device. Only Allow is kept.
struct CaptureChoices: Equatable {
    /// Site (see `site(host:port:)`) → the devices it may use.
    private(set) var allowed: [String: CaptureDevices] = [:]

    /// Where the choices live in Copper's settings: site → ["microphone", "camera"].
    static let key = "capture.sites"
    /// Every key Copper has kept capture choices under starts with this.
    static let prefix = "capture."

    init(allowed: [String: CaptureDevices] = [:]) {
        self.allowed = allowed.filter { !$0.value.isEmpty }
    }

    /// A site as the choices know it: the host, with the port when the page
    /// gave one (WebKit reports 0 for a scheme's own port). Two servers on
    /// one machine's ports are two sites, as they are to the browser.
    static func site(host: String, port: Int) -> String {
        let host = host.lowercased()
        return port > 0 ? "\(host):\(port)" : host
    }

    func covers(_ site: String, _ devices: CaptureDevices) -> Bool {
        (allowed[site] ?? []).isSuperset(of: devices)
    }

    /// What `site` still has to be asked about before `devices` can be granted.
    func missing(_ site: String, _ devices: CaptureDevices) -> CaptureDevices {
        devices.subtracting(allowed[site] ?? [])
    }

    mutating func allow(_ site: String, _ devices: CaptureDevices) {
        guard !devices.isEmpty else { return }
        allowed[site, default: []].formUnion(devices)
    }

    mutating func forget(_ site: String) { allowed[site] = nil }

    mutating func forgetAll() { allowed = [:] }

    /// For Copper's settings.
    var encoded: [String: [String]] { allowed.mapValues(\.names) }

    /// The choices as kept in Copper's settings, together with the keys of
    /// the older shape that were read and can now go.
    ///
    /// The older shape was one Bool per "capture.<host>|<WKMediaCaptureType
    /// raw value>". A true carries over as the devices it named (2, camera
    /// and microphone, is both); a false is dropped — it is the permanent
    /// silent "no" this replaces, and the site is simply asked again.
    static func load(from settings: [String: Any]) -> (choices: CaptureChoices, spent: [String]) {
        var choices = CaptureChoices()
        if let kept = settings[key] as? [String: [String]] {
            for (site, names) in kept { choices.allow(site, CaptureDevices(names: names)) }
        }
        var spent: [String] = []
        for (name, value) in settings where name.hasPrefix(prefix) && name != key {
            let rest = name.dropFirst(prefix.count)
            guard let bar = rest.lastIndex(of: "|"), let raw = Int(rest[rest.index(after: bar)...]) else { continue }
            spent.append(name)
            let host = String(rest[..<bar])
            // "This page" was the bar's stand-in for a page with no host; it
            // names no site.
            guard (value as? Bool) == true, !host.isEmpty, host != "This page" else { continue }
            choices.allow(site(host: host, port: 0), CaptureDevices(webKitType: raw))
        }
        return (choices, spent.sorted())
    }
}

/// The question on screen: which site, which devices it still needs, and
/// whose tab asked first.
struct CaptureQuestion: Equatable {
    let site: String
    let devices: CaptureDevices
    let tab: UUID?
    /// How many waiting requests one answer settles.
    let settles: Int
    /// False for a request that is answered but never remembered (see
    /// `CaptureQueue.ask`'s `keep`).
    var keep = true

    /// The same question about fewer devices (what macOS lets through).
    func asking(_ devices: CaptureDevices) -> CaptureQuestion {
        CaptureQuestion(site: site, devices: devices, tab: tab, settles: settles, keep: keep)
    }

    /// What the bar says: the same site, devices and tab. (How many requests
    /// one answer settles can change under it without changing the words.)
    func reads(like other: CaptureQuestion) -> Bool {
        site == other.site && devices == other.devices && tab == other.tab && keep == other.keep
    }
}

/// Requests waiting for an answer, oldest first. `Handle` is whatever answers
/// the page — WebKit's decision handler in the app, a stand-in in tests.
/// Every handle that goes in comes out exactly once, in `granted` or `denied`:
/// WebKit holds the page until it is called, and raises if it never is.
struct CaptureQueue<Handle> {
    struct Request {
        let id: Int
        let site: String
        let devices: CaptureDevices
        let tab: UUID?
        let handle: Handle
        /// Answered from what the site was allowed, and remembered when allowed.
        var keep = true
    }

    /// What an answer settled.
    struct Settled {
        var granted: [Request] = []
        var denied: [Request] = []
    }

    private(set) var waiting: [Request] = []
    private var counter = 0

    var isEmpty: Bool { waiting.isEmpty }

    /// A request in. Already covered by what the site was allowed: granted
    /// on the spot, never queued. Otherwise it waits behind the others —
    /// never refused for arriving second.
    ///
    /// `keep: false` — a request that may not be what it says: WebKit's
    /// public question calls a screen share "camera" on some versions, and a
    /// camera request the page never made through getUserMedia is read that
    /// way (CaptureDesk). It is always asked about, and an Allow lets it in
    /// without being remembered, so a screen share can never stand in for
    /// the camera. A page with no host (a file, a data: page) is asked about
    /// the same way: with no site to tell pages apart, one Allow must not
    /// let in every such page waiting.
    mutating func ask(site: String, devices: CaptureDevices, tab: UUID?, handle: Handle,
                      choices: CaptureChoices, keep: Bool = true) -> Settled {
        counter += 1
        let request = Request(id: counter, site: site, devices: devices, tab: tab, handle: handle, keep: keep)
        if keep, choices.covers(site, devices) { return Settled(granted: [request]) }
        waiting.append(request)
        return Settled()
    }

    /// The oldest request's site, and the devices it still needs; every
    /// waiting request from that site that one Allow would cover is counted in.
    ///
    /// `also`: what the same page has asked for and WebKit has yet to pass
    /// on. WebKit hands a page's requests over one at a time, so a page that
    /// asks for the microphone and the camera together has its camera request
    /// held back until the microphone is answered — asked about in one go
    /// instead, one Allow covers both (CaptureWants).
    func question(_ choices: CaptureChoices, also: (Request) -> CaptureDevices = { _ in [] }) -> CaptureQuestion? {
        guard let first = waiting.first else { return nil }
        guard first.keep else {
            return CaptureQuestion(site: first.site, devices: first.devices, tab: first.tab, settles: 1, keep: false)
        }
        let devices = choices.missing(first.site, first.devices.union(also(first)))
        let after = (choices.allowed[first.site] ?? []).union(devices)
        let settles = waiting.filter { $0.keep && $0.site == first.site && after.isSuperset(of: $0.devices) }.count
        return CaptureQuestion(site: first.site, devices: devices, tab: first.tab, settles: settles)
    }

    /// Allow: the site keeps the devices asked about, and every request
    /// (from any tab) they now cover is granted together. A question not to
    /// be kept lets in its own request only.
    mutating func allow(_ question: CaptureQuestion, choices: inout CaptureChoices) -> Settled {
        guard question.keep else {
            guard let index = waiting.firstIndex(where: { CaptureQueue.same($0, question) }) else { return Settled() }
            return Settled(granted: [waiting.remove(at: index)])
        }
        choices.allow(question.site, question.devices)
        return settle(choices)
    }

    /// Don't allow: every waiting request from the site that needs one of
    /// those devices is refused. One that needs none of them — the
    /// microphone, when it was the camera you said no to — keeps waiting and
    /// is asked about next.
    mutating func deny(_ question: CaptureQuestion) -> Settled {
        guard question.keep else {
            guard let index = waiting.firstIndex(where: { CaptureQueue.same($0, question) }) else { return Settled() }
            return Settled(denied: [waiting.remove(at: index)])
        }
        var settled = Settled()
        waiting.removeAll { request in
            guard request.keep, request.site == question.site, !request.devices.isDisjoint(with: question.devices) else { return false }
            settled.denied.append(request)
            return true
        }
        return settled
    }

    /// The request a question not to be kept was asked about: its own tab's,
    /// never another page's that happens to share the site (or the lack of one).
    private static func same(_ request: Request, _ question: CaptureQuestion) -> Bool {
        !request.keep && request.site == question.site && request.tab == question.tab && request.devices == question.devices
    }

    /// After choices change anywhere (another window's Allow): whatever they
    /// now cover is granted.
    mutating func settle(_ choices: CaptureChoices) -> Settled {
        var settled = Settled()
        waiting.removeAll { request in
            guard request.keep, choices.covers(request.site, request.devices) else { return false }
            settled.granted.append(request)
            return true
        }
        return settled
    }

    /// Requests nobody is waiting on any more — the tab closed, its page went
    /// elsewhere — are refused (WebKit has stopped waiting, but each handle
    /// is still answered) and leave the queue.
    mutating func drop(where gone: (Request) -> Bool) -> Settled {
        var settled = Settled()
        waiting.removeAll { request in
            guard gone(request) else { return false }
            settled.denied.append(request)
            return true
        }
        return settled
    }

    /// Everything refused: the window is closing, or nobody can be asked.
    mutating func dropAll() -> Settled {
        defer { waiting = [] }
        return Settled(denied: waiting)
    }
}

/// What one page has asked for and not yet heard back about, counted per
/// device: its getUserMedia() calls in flight (CaptureHook's page script says
/// when each starts and ends). Two calls for the microphone are two, so the
/// first one ending leaves the other counted.
struct CaptureWants: Equatable {
    private var counts: [Int: Int] = [:]

    var devices: CaptureDevices {
        CaptureDevices(rawValue: counts.filter { $0.value > 0 }.keys.reduce(0) { $0 | $1 })
    }

    var isEmpty: Bool { devices.isEmpty }

    mutating func began(_ asked: CaptureDevices) {
        for device in [CaptureDevices.microphone, .camera] where asked.contains(device) {
            counts[device.rawValue, default: 0] += 1
        }
    }

    mutating func ended(_ asked: CaptureDevices) {
        for device in [CaptureDevices.microphone, .camera] where asked.contains(device) {
            let left = (counts[device.rawValue] ?? 0) - 1
            counts[device.rawValue] = left > 0 ? left : nil
        }
    }
}

/// A "Don't allow" that covered requests WebKit had yet to pass on (see
/// `CaptureQueue.question`'s `also`): when they arrive from the same page and
/// site, soon, they are refused as you said, not asked about again. Never
/// kept past `until` — a refusal is never a standing block.
struct CaptureRefusal: Equatable {
    let site: String
    let devices: CaptureDevices
    let until: Date

    func refuses(_ site: String, _ asked: CaptureDevices, at now: Date) -> Bool {
        now < until && site == self.site && !asked.isDisjoint(with: devices)
    }
}

/// What a page muted itself through the Media Session API, as CaptureCalls
/// keeps it, so Copper never resumes it. A mute is taken on the page's word
/// (any frame's): it only ever holds Copper back. An unmute never is — a page,
/// or a frame in it, saying so could have Copper resume a microphone the page
/// muted, where WebKit wants a click in the page for that. It is seen instead:
/// a device that goes live again since it was last looked at is no longer
/// muted by the page (it unmuted itself, or started afresh).
struct CaptureOwnMutes: Equatable {
    private(set) var muted: CaptureDevices = []
    /// What was live when last looked at.
    private(set) var live: CaptureDevices = []

    init(live: CaptureDevices = []) { self.live = live }

    mutating func said(muted devices: CaptureDevices) { muted.formUnion(devices) }

    mutating func saw(live now: CaptureDevices) {
        muted.subtract(now.subtracting(live))
        live = now
    }

    /// A new page, once the last one's capture has gone.
    mutating func forget() { muted = [] }
}

/// One page at a time (CaptureCalls): the page on screen, paused by WebKit
/// for another page's sake, takes its devices back on its own only while no
/// other page captures anything live — taking them back pauses every other
/// page's capture, and a call in another tab must never go quiet only because
/// you looked at this one. Otherwise the bar offers them back.
enum CaptureTurn: Equatable {
    case nothing, resume, offer

    static func on(paused: CaptureDevices, othersLive: CaptureDevices) -> CaptureTurn {
        guard !paused.isEmpty else { return .nothing }
        return othersLive.isEmpty ? .resume : .offer
    }
}
