import AppKit
import QuartzCore
import SwiftUI

// A space switch, the way Arc draws one: the column slides.
//
// Switching swaps `browser.tabs` wholesale (Spaces.select), and left to
// itself the column animated that as every old row leaving and every new one
// arriving — up to a few hundred transitions, each a spring, and every
// colour on the column interpolated from one space's ink to the next's,
// frame after frame for half a second. The main thread spent most of that
// half second in SwiftUI.
//
// Instead the switch is one move, on one ground, with nothing pictured:
//
//   The ground (SpaceGround) is the column's background, drawn live for
//   the whole column — under the lights, the address, the favourites, the
//   rows and the strip — and blended from the old space's theme to the new
//   one's by how far the slide has gone. It never moves.
//
//   The band — the space's name and its rows, one scroll view — travels.
//   One of the two columns in motion is the real, live band; the other is a
//   preview (SpacePreview): the same rows drawn from the space's tabs, with
//   the same parts and measures, in that space's ink, on a clear ground,
//   taking no clicks.
//
//   The lights, the address, the favourites and the strip stay where they
//   are; their ink is mixed from the old space's to the new one's as the
//   slide goes (SlideInk), so a dark column's white glyphs become a light
//   one's brown with the ground, not after it.
//
// On a click or a key the new rows go in with animations off and the live
// band slides in from the side while a preview of the rows that were there
// slides out. After ~0.22 s the preview is dropped and nothing is left of it.
//
// A two-finger swipe (Swipes.swift) drives the same layers by hand, the
// other way round: the live band — the rows on screen — is what the fingers
// pull out, and the space they are heading for comes in as its preview,
// built from its parked tabs so a space never visited this launch looks
// exactly as it will. The previews of both neighbours are kept drawn and
// hidden while nothing moves (SpacePreview.premount), so the first frame of
// a swipe has nothing to build. When the fingers let go, the rest of the
// way is a spring; only once it has landed does the real switch happen,
// under the arriving preview — swapping a column of a hundred rows and its
// page is the one costly frame of a switch (several hundred milliseconds on
// a long column), and done at the end it costs no visible motion where done
// at the lift it froze the dragged frame and then jumped. The live band,
// now the new space's and laid out as the preview was, shows through as the
// preview fades. When the fingers let go short of the way, everything
// springs back and the live band is where it never left.
//
// Which way: towards a space after this one in `Spaces.all`, the old column
// leaves to the left; before it, to the right. Reduce Motion keeps the
// crossfade and drops the travel.
//
// Earlier versions pictured the column (the window's pixels, or the views
// drawn twice over black and white for a matte) and slid the pictures. The
// picture cost up to 55 ms at the moment the fingers moved, a space with no
// picture yet came in blank, and the ground baked into a picture met the
// other ground at a seam. None of that is here.

@MainActor
final class SpaceSlide: ObservableObject {
    static let shared = SpaceSlide()

    /// A slide is on: a click's, or a swipe's with a space to head for.
    @Published private(set) var sliding = false
    /// How far along: 0 with the old column home, 1 with the new one home.
    @Published private(set) var phase: CGFloat = 1
    /// +1 when the new space is after the old one (the old column leaves to
    /// the left), -1 before it, 0 under Reduce Motion.
    @Published private(set) var way: CGFloat = 0
    /// The two spaces the slide is between: the ground blends `from`'s look
    /// towards `to`'s by `phase`, the static parts mix their ink the same
    /// way. Nil at rest; during a swipe `to` is nil at the ends, where there
    /// is nowhere to go.
    @Published private(set) var from: Space?
    @Published private(set) var to: Space?
    /// A click's rows on their way out, as a preview: the space that was on
    /// screen, taken from the live column the instant before the switch (so
    /// its scroll and its live row are exact). Nil for a swipe, whose
    /// outgoing rows are the live band itself.
    @Published private(set) var leaving: SpacePreviewModel?

    // The swipe's own state, all false/zero outside one. One swipe at a
    // time, in `owner`'s window.
    /// True from the first sideways movement until the fingers let go.
    @Published private(set) var dragging = false
    /// True from the first sideways movement until the swipe's slide is over
    /// (a settle back, or the switch and its fade) — what tells the band it
    /// is the outgoing column, not the incoming one.
    @Published private(set) var swiping = false
    /// At the first or last space there is nowhere to go: the live column is
    /// pulled this far, with resistance, and springs back.
    @Published private(set) var stretch: CGFloat = 0
    /// A swipe's switch has happened: the live band is the new space's, home.
    @Published private(set) var switched = false
    /// After the switch, while the arriving preview is still whole over the
    /// live band; it fades out as this goes false.
    @Published private(set) var landing = false

    /// Where the column is, and where the band that travels is, in SwiftUI's
    /// global space (the window's content, from its top left) — per window,
    /// since every browser window has a column (Fork: windows). Kept up to
    /// date by each column as it is laid out; not published, since nothing
    /// has to redraw when they change. Absent while no column is on screen.
    private var columns: [ObjectIdentifier: CGRect] = [:]
    private var bands: [ObjectIdentifier: CGRect] = [:]
    /// The window whose switch is sliding (or last slid). The curtain and
    /// the band move only in its column; another window's stays still.
    private(set) weak var owner: Browser?

    func place(column rect: CGRect?, in browser: Browser) { columns[ObjectIdentifier(browser)] = rect }
    func place(band rect: CGRect, in browser: Browser) { bands[ObjectIdentifier(browser)] = rect }

    /// The sliding window's column and band — the first window's between slides.
    var column: CGRect { columns[ObjectIdentifier(owner ?? Windows.main)] ?? .zero }
    var band: CGRect { bands[ObjectIdentifier(owner ?? Windows.main)] ?? .zero }
    func column(in browser: Browser) -> CGRect { columns[ObjectIdentifier(browser)] ?? .zero }
    func band(in browser: Browser) -> CGRect { bands[ObjectIdentifier(browser)] ?? .zero }

    var moving: Bool { sliding || dragging }
    /// Whether it is this window's column that is sliding, or under the
    /// fingers; another window's column stays still.
    func moving(in browser: Browser) -> Bool { moving && owner === browser }

    /// Which previews the column keeps drawn (see SpacePreviewStack).
    let anchor = PreviewAnchor()
    /// The slide's progress in coarse steps, for the parts that stay put:
    /// their ink is mixed by it (SlideInk), and re-mixing the lights, the
    /// address and the strip on every frame of a drag was the one cost of
    /// the live ink. Twenty-four steps across a column is below what the
    /// eye tells apart in a colour; a timed slide sets the last step inside
    /// its animation, so the colours still glide.
    let ink = InkSteps()
    static let inkSteps: CGFloat = 24

    private func set(phase value: CGFloat) {
        phase = value
        let step = Int((min(1, max(0, value)) * SpaceSlide.inkSteps).rounded())
        if ink.step != step { ink.step = step }
    }

    /// Arc's is about this: quick off the mark, a soft landing, and over
    /// before the eye has finished following it.
    static let duration = 0.22
    static let curve = Animation.timingCurve(0.2, 0.9, 0.3, 1, duration: duration)
    /// How long the arriving preview takes to give way to the live rows
    /// under it after a swipe's switch.
    static let handover = 0.12

    /// Whether the live band is held to its own edges while it travels. On:
    /// the part still on its way never draws over the page, but the band's
    /// scroll view (an AppKit view) is resized to the clip every frame. Off:
    /// only moved. `bench spaces slide clip on|off` to compare.
    static var clipsBand = true

    /// Which slide is the current one, so a switch that interrupts another
    /// is not ended by the first one's completion.
    private var serial = 0
    /// `bench spaces slide at X`: the next slide stops at X and stays there,
    /// for a picture of it. Nil in normal use.
    private var hold: CGFloat?

    private var calm: Transaction {
        var t = Transaction()
        t.disablesAnimations = true
        return t
    }

    // MARK: - the switch

    /// Called by `Spaces.select` before anything changes. True when there is
    /// a column on screen to slide — the caller then makes its change with
    /// animations off, since the slide is the only motion there is.
    func begin(forward: Bool, to space: Space, in browser: Browser) -> Bool {
        let started = CACurrentMediaTime()
        timed = browser.prefs.bench
        // A slide already on in another window ends there, cleanly.
        if moving, owner !== browser { end() }
        owner = browser
        guard column.width > 1, column.height > 1, band.height > 1,
              let window = Windows.window(of: browser), window.isVisible else { return false }
        serial += 1
        let mine = serial
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let old = Spaces.shared.space(in: browser)
        // The rows as they stand, planned for the preview that slides out.
        // Planning is the cheap part; the view is built with the frame.
        // Fork (space-columns): a window that keeps its columns slides the
        // old space's own column out instead (`leavingColumn`), so there is
        // no preview to build.
        let model = SpaceColumns.keeps ? nil : SpacePreviewModel.live(old, in: browser, width: column.width, height: band.height)
        withTransaction(calm) {
            dragging = false
            swiping = false
            switched = false
            landing = false
            stretch = 0
            from = old
            to = space
            leaving = model
            sliding = true
            set(phase: 0)
            ink.objectWillChange.send()
            way = still ? 0 : (forward ? 1 : -1)
            // The neighbours kept drawn stay the old space's through the
            // slide, so nothing is built or dropped while it moves.
            anchor.home = old.id
            anchor.arriving = nil
        }
        timing = Timing(asked: started, planned: CACurrentMediaTime())
        // One turn of the run loop: it commits the frame that has the new
        // column in place under the preview (the switch's own frame, looking
        // exactly as the old one did), and the slide sets off from there.
        // A second turn, to let the column's scroll-to-live-row settle
        // first, was measured costing up to 40 ms of standing still; the
        // scroll runs without an animation during a slide, so it is already
        // where it will be.
        DispatchQueue.main.async {
            self.timing?.committed = CACurrentMediaTime()
            self.go(mine)
        }
        return true
    }

    private func go(_ mine: Int) {
        guard mine == serial, sliding else { return }
        timing?.moved = CACurrentMediaTime()
        watch()
        if let hold {
            withTransaction(calm) { set(phase: hold) }
            return
        }
        withAnimation(SpaceSlide.curve, completionCriteria: .logicallyComplete) {
            set(phase: 1)
        } completion: { [weak self] in
            guard let self, mine == self.serial else { return }
            self.end()
        }
    }

    private func end() {
        let mine = serial
        withTransaction(calm) {
            sliding = false
            set(phase: 1)
            ink.objectWillChange.send()
            dragging = false
            swiping = false
            switched = false
            landing = false
            stretch = 0
            from = nil
            to = nil
            leaving = nil
            anchor.arriving = nil
        }
        timing?.ended = CACurrentMediaTime()
        unwatch()
        // The neighbours kept drawn become the new space's — a moment
        // later, so building them is not in the slide's last frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, mine == self.serial, !self.moving else { return }
            self.anchor.home = nil
        }
    }

    // MARK: - the swipe

    /// The column `travel` points sideways from where it started (negative is
    /// to the left) — the fingers' travel, turned round if the swipe
    /// direction setting says so. The first call starts the swipe; every
    /// call after only moves things, with no animation — the fingers are the
    /// animation. False when there is no column to drive.
    @discardableResult
    func drag(_ travel: CGFloat, in browser: Browser) -> Bool {
        let spaces = Spaces.shared
        let current = spaces.current(in: browser)
        guard let here = spaces.all.firstIndex(where: { $0.id == current }) else { return false }
        if !dragging {
            // A slide or swipe still on in another window ends there, cleanly;
            // these fingers are on this one. (Fork: windows)
            if moving, owner !== browser { end() }
            // A settle still running from the last swipe or a click is left
            // to finish; these fingers do nothing.
            guard !sliding else { return false }
            owner = browser
            let started = CACurrentMediaTime()
            timed = browser.prefs.bench
            guard column.width > 1, column.height > 1, band.height > 1,
                  let window = Windows.window(of: browser), window.isVisible else { return false }
            serial += 1
            timing = Timing(asked: started, planned: CACurrentMediaTime())
            withTransaction(calm) {
                dragging = true
                swiping = true
                switched = false
                landing = false
                from = spaces.space(in: browser)
                leaving = nil
                anchor.home = current
                // The previews were planned against the column's scroll as
                // it was; if it has scrolled since, they land elsewhere now.
                let scroll = SideScrollElasticity.column?.contentView.bounds.minY ?? 0
                if abs(scroll - anchor.scrollSeen) > 0.5 { anchor.generation += 1 }
            }
            watch()
        } else if owner !== browser {
            // Fingers down on one window's column, moving over another's:
            // not this window's swipe.
            return false
        }
        let width = max(column.width, 1)
        // Travel to the left pushes the column left, so the space after this
        // one comes in from the right. `travel` is already the column's way,
        // not the fingers' — Swipes.swift turns it round for Inverted.
        let forward = travel < 0
        let there = here + (forward ? 1 : -1)
        withTransaction(calm) {
            if travel != 0, spaces.all.indices.contains(there) {
                let space = spaces.all[there]
                if to?.id != space.id {
                    to = space
                    anchor.arriving = space.id
                }
                sliding = true
                way = forward ? 1 : -1
                set(phase: min(1, abs(travel) / width))
                stretch = 0
            } else {
                // Nowhere to go this way: no preview, only the live column
                // pulled against a spring that gets stiffer the further it goes.
                sliding = false
                to = nil
                anchor.arriving = nil
                set(phase: 0)
                stretch = SpaceSlide.rubber(travel, over: width)
            }
        }
        return true
    }

    /// Resistance at the ends, as a scroll view has it: about a third of
    /// the fingers' travel at first, never more than a quarter column.
    nonisolated static func rubber(_ x: CGFloat, over width: CGFloat) -> CGFloat {
        let limit = width * 0.25
        let pulled = limit * (1 - 1 / (abs(x) * 0.33 / limit + 1))
        return x < 0 ? -pulled : pulled
    }

    /// How far, and how fast, the fingers must have gone for a release to
    /// carry on to the next space rather than spring back.
    static let commitAt: CGFloat = 0.38
    static let flick: CGFloat = 350 // points a second

    /// Fingers up (or the gesture cancelled): carry on, or go back. `velocity`
    /// is the fingers' in points a second, signed like `travel`. The rest of
    /// the way is a spring that sets off at the fingers' speed, so there is
    /// no jolt at the hand-over. Carrying on, the switch itself waits for
    /// the spring to land (see `land`).
    func release(velocity: CGFloat, cancelled: Bool, in browser: Browser) {
        guard dragging, owner === browser else { return }
        let mine = serial
        let width = max(column.width, 1)
        guard sliding, let to else {
            // The stretch at an end, home again.
            withAnimation(SpaceSlide.spring(from: stretch, to: 0, speed: velocity), completionCriteria: .logicallyComplete) {
                stretch = 0
            } completion: { [weak self] in
                guard let self, mine == self.serial else { return }
                self.end()
            }
            return
        }
        // In phase per second: positive is on towards `to`.
        let speed = -velocity * way / width
        let fast = SpaceSlide.flick / width
        let commit = !cancelled && (speed > fast || (speed > -fast && phase > SpaceSlide.commitAt))
        timing?.committed = CACurrentMediaTime()
        timing?.moved = CACurrentMediaTime()
        withTransaction(calm) { dragging = false }
        withAnimation(SpaceSlide.spring(from: phase, to: commit ? 1 : 0, speed: speed), completionCriteria: .logicallyComplete) {
            set(phase: commit ? 1 : 0)
        } completion: { [weak self] in
            guard let self, mine == self.serial else { return }
            if commit { self.land(to, in: browser, mine) } else { self.end() }
        }
    }

    /// The spring has landed with the arriving preview home over the live
    /// band's place: the real switch, under it. The next turn of the run
    /// loop commits the swapped column — the one costly frame — and then the
    /// preview is taken away over the live rows, now the same rows in the
    /// same places.
    private func land(_ space: Space, in browser: Browser, _ mine: Int) {
        guard mine == serial, sliding else { return }
        timing?.landed = CACurrentMediaTime()
        withTransaction(calm) {
            set(phase: 1)
            switched = true
            landing = true
            Spaces.shared.select(space.id, in: browser, sliding: true)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, mine == self.serial else { return }
            self.timing?.switched = CACurrentMediaTime()
            withAnimation(.linear(duration: SpaceSlide.handover), completionCriteria: .logicallyComplete) {
                self.landing = false
            } completion: { [weak self] in
                guard let self, mine == self.serial else { return }
                self.end()
            }
        }
    }

    /// A spring with no bounce whose first instant moves at `speed` (units
    /// of the value a second). SwiftUI wants that as a fraction of the
    /// distance still to go.
    static func spring(from: CGFloat, to: CGFloat, speed: CGFloat) -> Animation {
        let distance = to - from
        let relative = abs(distance) > 0.001 ? speed / distance : 0
        return .interpolatingSpring(duration: 0.3, bounce: 0, initialVelocity: Double(min(12, max(0, relative))))
    }

    // MARK: - where the layers are

    /// The live band's sideways offset in `browser`'s column this frame: a
    /// click's new rows coming in, a swipe's old rows going out, the stretch
    /// at an end, or home.
    func bandOffset(in browser: Browser) -> CGFloat {
        guard owner === browser else { return 0 }
        let width = column.width
        if dragging { return sliding ? -way * width * phase : stretch }
        guard sliding else { return 0 }
        if swiping { return switched ? 0 : -way * width * phase }
        return way * width * (1 - phase)
    }

    /// Where the arriving space's preview is, and how much of it shows:
    /// beside the live band while a swipe is on, home and fading once the
    /// switch is under it, and out of sight for a click (whose arriving
    /// rows are the live band).
    func arrivingPlace(of space: UUID, in browser: Browser) -> (x: CGFloat, shown: Double) {
        guard owner === browser, sliding, swiping, to?.id == space else { return (0, 0) }
        if switched { return (0, landing ? 1 : 0) }
        return (way * column.width * (1 - phase), 1)
    }

    /// Where a click's outgoing preview is: on its way out, or — with no
    /// travel under Reduce Motion — in place and fading.
    func leavingPlace(in browser: Browser) -> (x: CGFloat, shown: Double) {
        guard owner === browser, sliding, !swiping else { return (0, 0) }
        return (-way * column.width * phase, way == 0 ? Double(1 - phase) : 1)
    }

    /// Fork (space-columns): whether `space`'s kept column is the one a
    /// click's slide is taking out — it goes where the preview would, and
    /// in its place.
    func leavingColumn(_ space: UUID, in browser: Browser) -> Bool {
        owner === browser && sliding && !swiping && leaving == nil && from?.id == space
    }

    // MARK: - the bench

    /// What the last switch cost, in milliseconds from the moment it was
    /// asked for: the plan of the outgoing preview, the frame with the new
    /// column in it, the first frame that moved, the swipe's landing and
    /// switch; and how the frames came while it moved.
    private struct Timing {
        var asked: CFTimeInterval
        var planned: CFTimeInterval
        var committed: CFTimeInterval?
        var moved: CFTimeInterval?
        var landed: CFTimeInterval?
        var switched: CFTimeInterval?
        var ended: CFTimeInterval?
        var frames: [CFTimeInterval] = []
        var period: CFTimeInterval = 0
    }

    private var timing: Timing?
    private var link: CADisplayLink?
    /// Frames are only counted while a script may drive the app.
    private var timed = false

    /// A display link over the slide, while the bench is on: every frame's
    /// time, so a frame the main thread was too busy to make shows as a gap.
    private func watch() {
        guard timed, let view = (owner.flatMap(Windows.window(of:)) ?? Links.window)?.contentView else { return }
        link?.invalidate()
        // The view's link stops while its window is covered; then the swipe
        // bench's event pacing (`spaces swipe stats`) is the measure instead.
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func unwatch() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        timing?.frames.append(link.timestamp)
        timing?.period = link.targetTimestamp - link.timestamp
    }

    /// `spaces slide` — the last switch's timings; `spaces slide at X` —
    /// the next slides stop at X (0…1) and stay, for a picture;
    /// `spaces slide off` — back to sliding, and any held slide ends;
    /// `spaces slide clip on|off` — whether the live band is clipped as it
    /// travels.
    func bench(_ arg: String) -> [String: Any] {
        let words = arg.split(separator: " ").map(String.init)
        if words.first == "at", words.count > 1, let x = Double(words[1]) {
            hold = min(1, max(0, CGFloat(x)))
        } else if words.first == "off" {
            hold = nil
            if moving { end() }
        } else if words.first == "clip", words.count > 1 {
            SpaceSlide.clipsBand = words[1] == "on"
        }
        let browser = owner ?? Windows.main
        var note: [String: Any] = ["moving": moving, "hold": hold.map { Double($0) } ?? -1,
                                   "dragging": dragging, "swiping": swiping, "switched": switched, "landing": landing,
                                   "phase": (Double(phase) * 1000).rounded() / 1000,
                                   "way": Double(way), "stretch": (Double(stretch) * 10).rounded() / 10,
                                   "from": from?.name ?? "", "to": to?.name ?? "", "leaving": leaving?.space.name ?? "",
                                   "premount": SpacePreview.premount, "clip": SpaceSlide.clipsBand,
                                   "space": Spaces.shared.space(in: browser).name,
                                   "owner": Windows.all.firstIndex { $0 === browser } ?? -1,
                                   "window": Windows.window(of: browser).map { w in [Int(w.frame.minX), Int(w.frame.minY), Int(w.frame.width), Int(w.frame.height),
                                                                                   w.occlusionState.contains(.visible) ? 1 : 0] } ?? [],
                                   "screens": NSScreen.screens.map { [Int($0.frame.minX), Int($0.frame.minY), Int($0.frame.width), Int($0.frame.height)] },
                                   "column": [Int(column.minX), Int(column.minY), Int(column.width), Int(column.height)],
                                   "band": [Int(band.minX), Int(band.minY), Int(band.width), Int(band.height)]]
        guard let t = timing else { return note }
        func ms(_ x: CFTimeInterval?) -> Double { x.map { (($0 - t.asked) * 10000).rounded() / 10 } ?? -1 }
        note["planned"] = ms(t.planned)
        note["committed"] = ms(t.committed)
        note["moved"] = ms(t.moved)
        note["landed"] = ms(t.landed)
        note["switched"] = ms(t.switched)
        note["ended"] = ms(t.ended)
        let gaps = zip(t.frames.dropFirst(), t.frames).map { $0 - $1 }
        note["frames"] = t.frames.count
        note["period"] = (t.period * 10000).rounded() / 10
        note["longest"] = ((gaps.max() ?? 0) * 10000).rounded() / 10
        note["missed"] = t.period > 0 ? gaps.reduce(0) { $0 + max(0, Int(($1 / t.period).rounded()) - 1) } : 0
        return note
    }
}

// MARK: - the layers

// Three layers, on one ground. The ground (SpaceGround, the column's
// background) is live and never pictured: it blends the outgoing theme
// towards the incoming one by `phase`. Over it travel the bands — the live
// one and a preview — carrying their own space's ink and nothing else; and
// over everything the lights, the address, the favourites and the strip
// stay put with their ink mixed between the two spaces'. Nothing holds a
// ground, so there is no edge where one ground meets another and nothing
// to ghost.

/// The band that travels — the space's name and its rows — as the real, live
/// column: in from the side after a click's switch, out under the fingers
/// during a swipe, pulled against the rubber band at an end with nowhere to
/// go, and held to its own edges while it moves so the part still on its
/// way never draws over the page. At rest it is not clipped at all, so
/// nothing that hangs over its edge (a row in the hand, its shadow) is cut.
struct SpaceSlideBand: ViewModifier {
    let browser: Browser
    @ObservedObject private var slide = SpaceSlide.shared

    init(browser: Browser) { self.browser = browser }

    func body(content: Content) -> some View {
        content
            .offset(x: slide.bandOffset(in: browser))
            .clipShape(BandEdge(on: SpaceSlide.clipsBand && slide.moving(in: browser)))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { slide.place(band: $0, in: browser) }
    }

    /// The band's own rectangle while it moves; otherwise one so large it
    /// clips nothing. A shape rather than a `.clipped()` put on and taken off,
    /// which would make the column a different view, and rebuild it.
    private struct BandEdge: Shape {
        var on: Bool
        func path(in rect: CGRect) -> Path { Path(on ? rect : rect.insetBy(dx: -10_000, dy: -10_000)) }
    }
}

/// The parts of the column that stay put — the lights, the address, the
/// strip — drawn in an ink mixed from the old space's to the new one's by
/// the slide's progress, so they change with the ground under them. At
/// rest, the current space's. The content is built once from whatever tint
/// this hands it; only the tint changes.
struct SlideInk<Content: View>: View {
    let browser: Browser
    @ViewBuilder let content: (SpaceTint) -> Content
    /// The slide's coarse steps, not the slide: the content is re-mixed a
    /// couple of dozen times across a swipe rather than every frame.
    @ObservedObject private var ink = SpaceSlide.shared.ink
    @ObservedObject private var spaces = Spaces.shared
    @Environment(\.colorScheme) private var scheme

    init(browser: Browser, @ViewBuilder content: @escaping (SpaceTint) -> Content) {
        self.browser = browser
        self.content = content
    }

    var body: some View {
        let dark = scheme == .dark
        let slide = SpaceSlide.shared
        let tint: SpaceTint = {
            if slide.sliding, slide.owner === browser, let from = slide.from, let to = slide.to, from.id != to.id {
                return SpaceTint(theme: from.look.mixed(to.look, Double(CGFloat(ink.step) / SpaceSlide.inkSteps)), dark: dark)
            }
            return SpaceTint(space: spaces.space(in: browser), dark: dark)
        }()
        content(tint)
    }
}

/// The previews over the column while a slide is on — the arriving space's
/// rows coming in beside the live band during a swipe, the old space's rows
/// going out after a click's switch — and, hidden, the neighbours kept
/// ready for the next swipe. On clear: the ground under them is the
/// column's own. Takes no clicks: the column under it is the real one.
struct SpaceSlideCurtain: View {
    let browser: Browser
    @ObservedObject private var slide = SpaceSlide.shared
    @Environment(\.colorScheme) private var scheme

    init(browser: Browser) { self.browser = browser }

    var body: some View {
        let column = slide.column(in: browser)
        let band = slide.band(in: browser)
        let top = max(0, band.minY - column.minY)
        let height = max(1, min(band.height, column.height - top))
        let width = max(1, column.width)
        ZStack(alignment: .topLeading) {
            SpacePreviewStack(browser: browser, width: width, height: height, dark: scheme == .dark)
                .equatable()
            if slide.owner === browser, slide.sliding, let leaving = slide.leaving {
                // A click's old rows, on their way out.
                let place = slide.leavingPlace(in: browser)
                SpacePreview(model: leaving, width: width, height: height, dark: scheme == .dark)
                    .equatable()
                    .offset(x: place.x)
                    .opacity(place.shown)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
        .offset(y: top)
        .allowsHitTesting(false)
    }
}

/// The slide's progress in coarse steps (see `SpaceSlide.ink`).
@MainActor
final class InkSteps: ObservableObject {
    @Published var step = 0
}
