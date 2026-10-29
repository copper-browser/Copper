import AppKit
import SwiftUI

// Arc's update button. When a newer Copper is on its way or ready, a pill
// sits at the foot of the column, just above the space icons, in a strong
// shade of the space's own colour: "Update Copper", a filling bar while it
// downloads, "Restart to Update" once it is verified, "Retry Update" with
// the reason under the pointer when it went wrong. One click does the step
// that is due through `Updates` — download, or swap and relaunch — and it
// goes away by itself once the new Copper is the one running.
//
// It is not a dialog and never takes the keyboard: Copper still "never
// restarts without your say-so" (README › Updates), the click is the say-so.
// Right-click has What's New…, Remind Me Later (until the next launch or the
// next version) and the Settings page.
//
// The column is not always on screen. With the tabs across the top the same
// thing is a short capsule among the toolbar's doors; with the column folded
// away (⌘S) it is a small round badge in the window's bottom-left corner,
// which opens to its label under the pointer.
//
// Everything it says is read off `Updates`; nothing here downloads, checks
// or swaps. The bench can force each state (`updates pill …`) so the pill can
// be looked at without a release to install — a forced pill rehearses its
// clicks instead of making them.

/// What the pill has to say, one case per thing the person can do next.
enum UpdateCue: Equatable {
    /// Newer than this one, not downloaded yet: the click fetches it.
    case available(String)
    /// On its way; the fraction once the server has said how big it is.
    case downloading(String, Double?)
    /// Downloaded and verified: the click backs up, swaps and relaunches.
    case ready(String)
    /// The swap is under way; the window is about to go.
    case installing(String)
    /// The download or the swap did not happen, and why. `swap` is true
    /// when the verified bundle is still there and it was the swap that
    /// failed, so Retry runs the update again rather than the download.
    case failed(String, why: String, swap: Bool)

    var version: String {
        switch self {
        case .available(let v), .downloading(let v, _), .ready(let v), .installing(let v), .failed(let v, _, _): return v
        }
    }

    /// The step, without its numbers: what the pill animates between, and
    /// what decides whether this is a first appearance worth a flourish.
    var phase: String {
        switch self {
        case .available: return "available"
        case .downloading: return "downloading"
        case .ready: return "ready"
        case .installing: return "installing"
        case .failed: return "failed"
        }
    }

    /// The pill's label. Compact is the toolbar's and the badge's.
    func title(compact: Bool) -> String {
        switch self {
        case .available: return compact ? "Update" : "Update Copper"
        case .downloading(_, let fraction):
            let percent = fraction.map { "\(Int(($0 * 100).rounded(.down)))%" }
            if compact { return percent ?? "Update" }
            return percent.map { "Downloading… \($0)" } ?? "Downloading…"
        case .ready: return "Restart to Update"
        case .installing: return "Restarting…"
        case .failed: return "Retry Update"
        }
    }

    /// The tooltip: the version, and the sentence behind a failure.
    func help(current: String, host: String) -> String {
        switch self {
        case .available(let v):
            return "Copper \(v) is available (you have \(current)) — click to download it"
        case .downloading(let v, let fraction):
            let done = fraction.map { " — \(Int(($0 * 100).rounded(.down)))%" } ?? ""
            return "Downloading Copper \(v) from \(host) and verifying it\(done)"
        case .ready(let v):
            return "Copper \(v) is downloaded and verified. Restart to Update backs up your tabs, swaps in the new Copper and relaunches — a few seconds."
        case .installing(let v):
            return "Installing Copper \(v)…"
        case .failed(let v, let why, _):
            return "Couldn’t update to Copper \(v): \(why) Click to try again."
        }
    }

    /// The pill's icon. `bare` is the round badge's: it is a circle
    /// already, and a circle in it reads as a hole.
    func glyph(bare: Bool) -> String {
        switch self {
        case .available, .downloading, .installing: return bare ? "arrow.down" : "arrow.down.circle.fill"
        case .ready: return bare ? "arrow.up" : "arrow.up.circle.fill"
        case .failed: return "exclamationmark.arrow.circlepath"
        }
    }
}

extension Updates {
    /// The pill's state, or nil when there is nothing newer to install.
    var cue: UpdateCue? {
        guard available, !quietHere, let version = latest?.version else { return nil }
        if state == .upgrading { return .installing(version) }
        if downloading { return .downloading(version, progress) }
        if ready {
            // A refusal that was kept as the outcome (no room to swap, the
            // session backup, a move that was undone) is the swap failing;
            // "not downloaded yet" and friends fetch again on their own and
            // pass through `downloading` instead.
            if let problem, outcome?.ok == false, outcome?.detail == problem {
                return .failed(version, why: problem, swap: true)
            }
            return .ready(version)
        }
        if let stageError { return .failed(version, why: stageError, swap: false) }
        return .available(version)
    }
}

/// The pill's own state across every window: what was put off, what the
/// bench forced, which first appearances have had their flourish.
@MainActor
final class UpdatePill: ObservableObject {
    static let shared = UpdatePill()

    /// Remind Me Later: the version it was said about. Not saved — a new
    /// launch, or a newer version than this one, brings the pill back.
    @Published private(set) var snoozed: String?
    /// The bench's stand-in for `Updates.cue`, so every state can be
    /// pictured without a release. Clicks on it are rehearsed, not made.
    @Published var forced: UpdateCue?
    /// What's New for a forced pill, in place of the feed's notes.
    @Published var forcedNotes: String?
    /// The bench's way to open What's New on the pill in front.
    @Published var notesAsked = 0
    /// The bench's pointer: every pill drawn as under it (the badge spelled
    /// out, the hover light), for a screenshot.
    @Published var hoverForced = false
    /// Version-and-step pairs that have already had their entrance, so a
    /// second window, a folded column peeking out or a redraw does not
    /// replay it.
    var introduced: Set<String> = []

    private var rehearsal: Task<Void, Never>?

    private init() {}

    func cue(_ updates: Updates) -> UpdateCue? { forced ?? updates.cue }

    /// What is on screen: the cue, unless it was put off for this version.
    func shown(_ updates: Updates) -> UpdateCue? {
        guard let cue = cue(updates), cue.version != snoozed else { return nil }
        return cue
    }

    /// The click. Each state's one obvious step, through `Updates`.
    func press(in browser: Browser) {
        let updates = Updates.shared
        guard let cue = cue(updates) else { return }
        if forced != nil {
            rehearse(cue, in: browser)
            return
        }
        switch cue {
        case .available: updates.stage(force: true)
        case .downloading, .installing: break
        case .ready: updates.upgrade()
        case .failed(_, _, let swap):
            if swap { updates.upgrade() } else { updates.stage(force: true) }
        }
    }

    func later() {
        snoozed = cue(Updates.shared)?.version
    }

    func unsnooze() {
        snoozed = nil
    }

    /// Force a state for the bench, or `nil` to go back to the real one.
    func force(_ cue: UpdateCue?) {
        rehearsal?.cancel()
        rehearsal = nil
        forced = cue
    }

    /// A forced pill's click: the same walk a real one takes, minus the
    /// network and the swap — a download that fills in two seconds, then a
    /// restart that only says what it would have done.
    private func rehearse(_ cue: UpdateCue, in browser: Browser) {
        rehearsal?.cancel()
        let version = cue.version
        switch cue {
        case .available, .failed(_, _, false):
            rehearsal = Task { [weak self] in
                for step in 0...25 {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    guard !Task.isCancelled else { return }
                    self?.forced = .downloading(version, Double(step) / 25)
                }
                guard !Task.isCancelled else { return }
                self?.forced = .ready(version)
            }
        case .ready, .failed(_, _, true):
            forced = .installing(version)
            browser.announce("Preview — a real Copper \(version) would relaunch now")
            rehearsal = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                guard !Task.isCancelled else { return }
                self?.forced = .ready(version)
            }
        case .downloading, .installing:
            break
        }
    }

    /// The changelog as it was at the release's commit: every change, where
    /// the feed's notes are only the gist.
    static func changelog(for latest: Updates.Latest?) -> URL? {
        let commit = latest?.commit ?? ""
        let ref = commit.isEmpty ? "fork" : commit
        return URL(string: "https://github.com/copper-browser/Copper/blob/\(ref)/CHANGELOG.md")
    }

    /// `updates pill …` from the bench.
    func bench(_ words: [String], in browser: Browser) -> [String: Any] {
        let updates = Updates.shared
        var words = words
        let op = words.isEmpty ? "status" : words.removeFirst()
        // `v=1.2.3` anywhere picks the version a forced state is about.
        var version = UpdatePill.previewVersion
        if let index = words.firstIndex(where: { $0.hasPrefix("v=") }) {
            version = String(words.remove(at: index).dropFirst(2))
        }
        switch op {
        case "status": break
        case "available": force(.available(version))
        case "downloading":
            let fraction = words.first.flatMap(Double.init).map { min(1, max(0, $0)) }
            force(.downloading(version, fraction))
        case "ready": force(.ready(version))
        case "installing": force(.installing(version))
        case "failed":
            let swap = words.first == "swap"
            if swap { words.removeFirst() }
            let why = words.isEmpty ? "Couldn’t download Copper \(version) from github.com: The Internet connection appears to be offline." : words.joined(separator: " ")
            force(.failed(version, why: why, swap: swap))
        case "off", "real": force(nil)
        case "click": press(in: browser)
        case "later", "snooze": later()
        case "unsnooze": unsnooze()
        case "hover": hoverForced = words.first != "off"
        case "notes", "whatsnew":
            forcedNotes = words.isEmpty ? forcedNotes : words.joined(separator: " ")
            notesAsked += 1
        case "replay":
            // Forget the entrances, so the next appearance flourishes again.
            introduced.removeAll()
            let was = forced
            force(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.force(was) }
        default:
            return ["error": "updates pill available|downloading [F]|ready|installing|failed [swap] [WHY]|off|click|later|unsnooze|notes [TEXT]|hover on|off|replay [v=VERSION]"]
        }
        let cue = cue(updates)
        let shown = shown(updates)
        return [
            "forced": forced != nil,
            "state": cue?.phase ?? "none",
            "version": cue?.version ?? "",
            "shown": shown != nil,
            "snoozed": snoozed ?? "",
            "title": shown?.title(compact: false) ?? "",
            "compact": shown?.title(compact: true) ?? "",
            "help": shown?.help(current: updates.current, host: updates.feedHost) ?? "",
        ]
    }

    /// A version that reads as the next one, for a forced pill.
    private static var previewVersion: String {
        var parts = Fork.version.split(separator: ".").map(String.init)
        if let last = parts.last, let n = Int(last) {
            parts[parts.count - 1] = String(n + 1)
            return parts.joined(separator: ".")
        }
        return "1.0.1"
    }
}

// MARK: - colour

/// The pill's colours from the space: a deep, full shade of the column's own
/// hue — the column is the same hue thinned, so this stands off it without
/// being a colour from somewhere else — or the system accent on a grey
/// space. The fill is opaque on purpose: over a picture or an animated scene
/// a translucent pill would take its contrast from whatever is behind it.
///
/// The words are white, so the fill is taken as deep as white needs — to a
/// luminance near 0.16, about 5:1 — rather than to one brightness for every
/// hue: blue and pink are dark at any brightness, green and teal are so
/// light to the eye that one number made them highlighter. Never below
/// 0.52 brightness, where a green turns to mud; those land near 4:1. Yellow
/// cannot be deep and still be yellow, so it goes the other way: a bright
/// gold with the hue's own near-black words.
struct UpdateInk {
    let fill: Color
    let label: Color
    /// Whether the label is dark — the sheen and the edge are lighter on it.
    let light: Bool

    /// The fill's target luminance under white words.
    private static let deep = 0.16

    init(_ tint: SpaceTint) {
        guard let hue = tint.hue else {
            let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB).map {
                SpaceTheme.Stop(r: $0.redComponent, g: $0.greenComponent, b: $0.blueComponent)
            } ?? SpaceTheme.Stop(r: 0.0, g: 0.48, b: 1.0)
            self.init(fill: accent)
            return
        }
        let (s, _) = SpaceTheme.strength(hue)
        // A dark column wants its colour a touch quieter than a light one.
        let saturation = tint.dark ? min(1, s + 0.1) : min(1, s + 0.24)
        let h = hue - hue.rounded(.down)
        if (0.115...0.2).contains(h) {
            let gold = SpaceTheme.Stop(hue: h, saturation: saturation, brightness: tint.dark ? 0.84 : 0.88)
            self.init(fill: gold.color, label: Color(hue: h, saturation: 0.9, brightness: 0.18), light: true)
            return
        }
        var low = 0.52, high = 0.9
        if SpaceTheme.Stop(hue: h, saturation: saturation, brightness: low).luminance < Self.deep {
            for _ in 0..<12 {
                let mid = (low + high) / 2
                if SpaceTheme.Stop(hue: h, saturation: saturation, brightness: mid).luminance < Self.deep { low = mid } else { high = mid }
            }
        }
        self.init(fill: SpaceTheme.Stop(hue: h, saturation: saturation, brightness: low))
    }

    /// White words on the fill unless they would read worse than near-black.
    private init(fill: SpaceTheme.Stop) {
        let white = 1.05 / (fill.luminance + 0.05)
        let black = (fill.luminance + 0.05) / 0.06
        let dark = black > white && white < 3.6
        self.init(fill: fill.color, label: dark ? Color(white: 0.1) : .white, light: dark)
    }

    private init(fill: Color, label: Color, light: Bool) {
        self.fill = fill
        self.label = label
        self.light = light
    }
}

// MARK: - the views

/// The wide pill at the foot of the column, with the space's ink handed in
/// as the slide mixes it. Takes no room while there is nothing to say.
struct UpdatePillSlot: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var updates = Updates.shared
    @ObservedObject private var pill = UpdatePill.shared
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        let cue = pill.shown(updates)
        VStack(spacing: 0) {
            if let cue {
                SlideInk(browser: browser) { tint in
                    UpdatePillView(browser: browser, cue: cue, tint: tint, style: .wide)
                }
                .padding(.horizontal, SideBar.inset)
                .padding(.top, 6)
                .padding(.bottom, 2)
                // It rises a little out of the strip below it while the rows
                // above give up their room on the same spring; nothing else
                // moves. Not clipped: the pill's glow would be cut square.
                .transition(still ? .opacity : .offset(y: 14).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
            AddonPillSlot(browser: browser) // Fork (addons): an addon waiting for Install, under Copper's own
        }
        .animation(still ? .easeOut(duration: 0.2) : Motion.glide, value: cue == nil)
    }
}

/// The toolbar's capsule, among the doors at the far end of the tab strip.
struct UpdateToolbarPill: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var updates = Updates.shared
    @ObservedObject private var pill = UpdatePill.shared
    @ObservedObject private var spaces = Spaces.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var still
    /// The strip's row has no animation of its own for this, so the capsule
    /// grows in by itself; nothing at all is drawn — not even a gap between
    /// the doors — while there is no update.
    @State private var risen = false

    var body: some View {
        if let cue = pill.shown(updates) {
            UpdatePillView(browser: browser, cue: cue,
                           tint: SpaceTint(space: spaces.space(in: browser), dark: scheme == .dark).offColumn,
                           style: .compact)
                .scaleEffect(risen || still ? 1 : 0.8)
                .opacity(risen ? 1 : 0)
                .onAppear { withAnimation(still ? .easeOut(duration: 0.2) : Motion.settle) { risen = true } }
                .onDisappear { risen = false }
        }
        AddonPillSlot(browser: browser, compact: true) // Fork (addons): after Copper's own, nothing drawn when none waits
    }
}

/// The folded column's badge, in the window's bottom-left corner — where the
/// column's foot would be. Only while the column is folded and not out.
struct UpdateCorner: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject private var updates = Updates.shared
    @ObservedObject private var pill = UpdatePill.shared
    @ObservedObject private var spaces = Spaces.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var still

    private var folded: Bool {
        prefs.sidebar && browser.folded && !browser.peeking && browser.active?.immersed != true
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if folded, let cue = pill.shown(updates) {
                UpdatePillView(browser: browser, cue: cue,
                               tint: SpaceTint(space: spaces.space(in: browser), dark: scheme == .dark).offColumn,
                               style: .corner)
                    .padding(.leading, 12)
                    .padding(.bottom, 12)
                    .transition(still ? .opacity : .scale(scale: 0.6, anchor: .bottomLeading).combined(with: .opacity))
            }
        }
        .animation(still ? .easeOut(duration: 0.2) : Motion.glide, value: folded && pill.shown(updates) != nil)
    }
}

struct UpdatePillView: View {
    enum Style { case wide, compact, corner }

    @ObservedObject var browser: Browser
    let cue: UpdateCue
    let tint: SpaceTint
    var style: Style = .wide

    @ObservedObject private var updates = Updates.shared
    @ObservedObject private var pill = UpdatePill.shared
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var hovering = false
    @State private var notesOpen = false
    /// Bumped to play the entrance: the sheen across, the arrow's hop.
    @State private var flourish = 0

    private var ink: UpdateInk { UpdateInk(tint) }
    /// A failure is said in the column's own quiet surface with an orange
    /// mark: the strong fill is for the step you want to take.
    private var quiet: Bool { if case .failed = cue { return true }; return false }
    /// Quiet off the column — the toolbar, the badge over a page — has no
    /// column to be a shade of, so it takes the app's own surfaces.
    private var fill: Color { quiet ? (style == .wide ? tint.pill : (style == .corner ? Palette.ground : Palette.wash)) : ink.fill }
    private var rim: Color { style == .wide ? tint.rim : Palette.hairline }
    private var label: Color { quiet ? (style == .wide ? tint.ink : Palette.ink) : ink.label }
    private var lit: Bool { hovering || pill.hoverForced }

    private var height: CGFloat {
        switch style {
        case .wide: return 34
        case .compact: return 24
        case .corner: return 30
        }
    }

    private var radius: CGFloat { style == .wide ? 10 : height / 2 }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
    /// The badge says only its icon until the pointer is on it.
    private var spelled: Bool { style != .corner || lit }

    var body: some View {
        Button { pill.press(in: browser) } label: {
            HStack(spacing: style == .wide ? 7 : 5) {
                mark
                if spelled {
                    Text(cue.title(compact: style != .wide))
                        .font(.system(size: style == .wide ? 13 : 12, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity)
                }
            }
            .foregroundStyle(label)
            .padding(.horizontal, style == .wide ? 12 : (spelled ? 10 : 0))
            .frame(minWidth: height, maxWidth: style == .wide ? .infinity : nil)
            .frame(height: height)
            // A crowded toolbar must not squeeze the capsule under its words.
            .fixedSize(horizontal: style != .wide, vertical: false)
            .background { ground }
            .overlay { sheen }
            .contentShape(shape)
        }
        .buttonStyle(UpdatePress())
        .onHover { hovering = $0 }
        .help(cue.help(current: updates.current, host: updates.feedHost))
        .accessibilityLabel(cue.title(compact: false))
        .accessibilityHint(cue.help(current: updates.current, host: updates.feedHost))
        .contextMenu { menu }
        .popover(isPresented: $notesOpen, arrowEdge: style == .compact ? .bottom : .trailing) {
            UpdateNotes(browser: browser, cue: cue) { notesOpen = false }
        }
        .onAppear { introduce() }
        .onChange(of: cue.phase) { _, _ in introduce() }
        .onChange(of: pill.notesAsked) { _, _ in notesOpen = true }
        .animation(Motion.quick, value: lit)
        .animation(Motion.settle, value: cue.phase)
        .animation(Motion.settle, value: spelled)
    }

    // MARK: pieces

    @ViewBuilder private var mark: some View {
        let size: CGFloat = style == .wide ? 15 : 13
        switch cue {
        case .downloading(_, let fraction):
            UpdateRing(fraction: fraction, size: size - 1, ink: label)
        case .installing:
            UpdateRing(fraction: nil, size: size - 1, ink: label)
        case .failed:
            Image(systemName: cue.glyph(bare: style == .corner))
                .font(.system(size: size - 2, weight: .bold))
                .foregroundStyle(Color.orange)
        default:
            Image(systemName: cue.glyph(bare: style == .corner))
                .font(.system(size: style == .corner ? size - 1 : size, weight: style == .corner ? .bold : .semibold))
                .symbolRenderingMode(.hierarchical)
                .keyframeAnimator(initialValue: 0.0, trigger: flourish) { content, lift in
                    content.offset(y: lift)
                } keyframes: { _ in
                    // Two small hops, after the sheen has started across.
                    LinearKeyframe(0, duration: 0.45)
                    SpringKeyframe(-3, duration: 0.16, spring: .snappy)
                    SpringKeyframe(0, duration: 0.22, spring: .bouncy)
                    SpringKeyframe(-2, duration: 0.14, spring: .snappy)
                    SpringKeyframe(0, duration: 0.3, spring: .bouncy)
                }
        }
    }

    /// The fill, a soft top light so it reads as a button and not a label,
    /// an edge that holds on a pale column, and a glow in its own colour.
    /// While downloading the fill is a bar: the part fetched at full
    /// strength, the rest the same colour shaded away from the words — still
    /// opaque, so the label keeps its contrast across the whole pill.
    private var ground: some View {
        ZStack(alignment: .leading) {
            if case .downloading(_, let fraction) = cue, !quiet {
                shape.fill(fill)
                shape.fill(ink.light ? Color.white.opacity(tint.dark ? 0.28 : 0.4) : Color.black.opacity(0.24))
                GeometryReader { geo in
                    shape.fill(fill)
                        .frame(width: max(height, geo.size.width * (fraction ?? 0)))
                        .opacity(fraction == nil ? 0 : 1)
                        .animation(.easeOut(duration: 0.25), value: fraction)
                }
            } else {
                shape.fill(fill)
            }
            shape.fill(LinearGradient(colors: [.white.opacity(quiet ? 0 : (lit ? 0.22 : 0.14)), .clear],
                                      startPoint: .top, endPoint: .bottom))
            shape.strokeBorder(quiet ? rim : Color.white.opacity(ink.light ? 0.35 : 0.18), lineWidth: 0.75)
        }
        .brightness(lit && !quiet ? (ink.light ? -0.03 : 0.04) : 0)
        .shadow(color: quiet ? tint.lift : ink.fill.opacity(style == .corner ? 0.45 : 0.32),
                radius: lit ? 7 : 5, y: 2)
        .shadow(color: .black.opacity(style == .corner ? 0.18 : 0), radius: 10, y: 3)
    }

    /// A band of light across the pill once, on its entrance.
    private var sheen: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, .white.opacity(ink.light ? 0.45 : 0.32), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: max(40, geo.size.width * 0.4))
                .rotationEffect(.degrees(14))
                .keyframeAnimator(initialValue: -1.0, trigger: flourish) { content, at in
                    content.offset(x: at * geo.size.width)
                } keyframes: { _ in
                    LinearKeyframe(-0.6, duration: 0.25)
                    CubicKeyframe(1.3, duration: 0.95)
                }
        }
        .clipShape(shape)
        .allowsHitTesting(false)
        .opacity(quiet ? 0 : 1)
    }

    @ViewBuilder private var menu: some View {
        switch cue {
        case .available, .ready, .failed:
            Button(cue.title(compact: false)) { pill.press(in: browser) }
            Divider()
        default:
            EmptyView()
        }
        Button("What’s New in Copper \(cue.version)…") {
            // After the menu has gone, or the popover has nothing to hang from.
            DispatchQueue.main.async { notesOpen = true }
        }
        Button("Remind Me Later") { pill.later() }
        Divider()
        Button("Settings…") { browser.openSettings(.about, at: "updates.check") }
    }

    /// The first time this version reaches this step in this run — and only
    /// the two steps that ask for a click — the sheen goes across and the
    /// arrow hops. Never under Reduce Motion; the pill's rise is enough.
    private func introduce() {
        guard cue.phase == "available" || cue.phase == "ready" else { return }
        let key = "\(cue.version)/\(cue.phase)"
        guard !pill.introduced.contains(key) else { return }
        pill.introduced.insert(key)
        guard !still else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { flourish += 1 }
    }
}

/// A press that gives a little, like Arc's.
private struct UpdatePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

/// The download's ring in the pill's own label colour: the fraction once
/// known, a turning arc before then and while the swap runs.
private struct UpdateRing: View {
    let fraction: Double?
    let size: CGFloat
    let ink: Color
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(ink.opacity(0.3), lineWidth: 1.8)
            Circle()
                .trim(from: 0, to: fraction.map { max(0.04, $0) } ?? 0.3)
                .stroke(ink, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .rotationEffect(.degrees(-90 + (fraction == nil && turning ? 360 : 0)))
                .animation(.easeOut(duration: 0.25), value: fraction)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard fraction == nil, !still else { return }
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turning = true }
        }
    }
}

/// What's New: the feed's gist of the release, the way Settings would say
/// it, with the full changelog a click away and the pill's step beside it.
struct UpdateNotes: View {
    @ObservedObject var browser: Browser
    let cue: UpdateCue
    let close: () -> Void
    @ObservedObject private var updates = Updates.shared
    @ObservedObject private var pill = UpdatePill.shared

    private var notes: String? {
        if pill.forced != nil { return pill.forcedNotes ?? updates.latest?.notes ?? UpdateNotes.sample }
        return updates.latest?.notes
    }

    private var published: String? {
        guard pill.forced == nil, let raw = updates.latest?.publishedAt,
              let date = ISO8601DateFormatter().date(from: raw) else { return nil }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    // The version is a long dotted date; on the title's line
                    // it wraps, so it leads the quieter line instead.
                    Text("What’s New in Copper")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text("\(cue.version)" + (published.map { ", released \($0)" } ?? "") + " · you have \(updates.current)")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
            }
            ScrollView {
                Text(notes ?? "This release came without notes. The changelog has every change since the last one.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(notes == nil ? Palette.muted : Palette.ink)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Pill("Full Changelog") {
                    if let url = UpdatePill.changelog(for: updates.latest) { browser.open(url, foreground: true) }
                    close()
                }
                Spacer()
                switch cue {
                case .available, .ready, .failed:
                    Pill(cue.title(compact: false), filled: true) {
                        close()
                        pill.press(in: browser)
                    }
                default:
                    EmptyView()
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    /// A forced pill's notes when the bench gave none: the real paragraph's
    /// shape, so the popover can be judged at its usual length.
    private static let sample = "The sidebar says when a new Copper is ready: a pill at its foot, in the space's own colour — Update Copper, a bar while it downloads, Restart to Update once it is verified. One click does the step that is due; right-click has What’s New, Remind Me Later and Settings."
}

// MARK: - the bench's sheet

/// Every state of every pill on every space, drawn off any window —
/// `./bench render pill|pill-dark PATH`. The window picture comes from
/// WindowServer, which hands back blank pixels while the screen is locked
/// or the probe is behind another app; this needs neither. Each space's
/// column is its flat colour (a picture or a scene is not drawn), and the
/// badge is shown both at rest and spelled out as under the pointer.
struct UpdatePillSheet: View {
    @ObservedObject var browser: Browser
    let dark: Bool

    private var cues: [UpdateCue] {
        let v = "1.0.20261002.16"
        return [.available(v), .downloading(v, 0.42), .ready(v), .failed(v, why: "The download did not match its checksum.", swap: false)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Spaces.shared.all) { space in
                let tint = SpaceTint(space: space, dark: dark)
                let off = tint.offColumn
                HStack(spacing: 0) {
                    ForEach(Array(cues.enumerated()), id: \.offset) { _, cue in
                        UpdatePillView(browser: browser, cue: cue, tint: tint, style: .wide)
                            .frame(width: 210)
                            .padding(12)
                            .background(space.look.flat(dark: dark))
                    }
                    HStack(spacing: 10) {
                        ForEach(Array(cues.enumerated()), id: \.offset) { _, cue in
                            UpdatePillView(browser: browser, cue: cue, tint: off, style: .compact)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(width: 560, height: 56)
                    .background(Palette.ground)
                    HStack(spacing: 10) {
                        UpdatePillView(browser: browser, cue: cues[2], tint: off, style: .corner)
                        UpdatePillView(browser: browser, cue: cues[3], tint: off, style: .corner)
                    }
                    .padding(.horizontal, 12)
                    .frame(width: 400, height: 56, alignment: .leading)
                    .background(Palette.wash)
                }
            }
            if let space = Spaces.shared.all.first {
                // What's New, as its popover draws it.
                UpdateNotes(browser: browser, cue: cues[2]) {}
                    .background(Palette.ground)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(space.look.flat(dark: dark))
            }
        }
        .environment(\.colorScheme, dark ? .dark : .light)
        .fixedSize()
    }
}
