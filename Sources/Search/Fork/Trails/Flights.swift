import SwiftUI

// Flights: features that ship inside the build but stay off until someone
// opts in from Settings › Tabs › Previews. One home for all of them, so the next preview
// has a switch to hang from without inventing its own key, page or bench verb.
//
// Each flight is one key under `flights.` in `Store.settings` — a probe
// world's own suite, never the real browser's — read once at launch and
// published, so flipping one re-renders whatever reads it without a restart.
// A flight that is off must cost nothing: no timers, no observers, no files.

@MainActor
final class Flights: ObservableObject {
    static let shared = Flights()

    /// Trails: the space's loose tabs drawn as lines of intent instead of a
    /// list (Fork/Trails/, docs/trails.md). Off by default.
    @Published var trails: Bool {
        didSet {
            guard trails != oldValue else { return }
            Store.settings.set(trails, forKey: Flights.trailsKey)
            Trails.shared.flightChanged(trails)
        }
    }

    /// How long a trail goes untouched before Tide carries it under Earlier.
    @Published var tide: Tide {
        didSet { Store.settings.set(tide.rawValue, forKey: Flights.tideKey) }
    }

    /// Read anywhere a hook has to decide in one line whether to do anything.
    static var trails: Bool { shared.trails }

    private static let trailsKey = "flights.trails"
    private static let tideKey = "flights.trails.tide"

    private init() {
        trails = Store.settings.bool(forKey: Flights.trailsKey)
        tide = Store.settings.string(forKey: Flights.tideKey).flatMap(Tide.init(rawValue:)) ?? .h12
    }

    /// `./bench flight` lists; `flight trails on|off`, `flight tide 6h|12h|24h|never`.
    func bench(_ request: [String: Any]) -> [String: Any] {
        let op = (request["op"] as? String ?? "list").lowercased()
        let arg = (request["arg"] as? String ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        switch op {
        case "list", "status": break
        case "trails":
            guard ["on", "off", "true", "false", "1", "0"].contains(arg) else { return ["error": "flight trails on|off"] }
            trails = ["on", "true", "1"].contains(arg)
        case "tide":
            let key = arg == "never" ? arg : "h" + arg.filter(\.isNumber)
            guard let wanted = Tide(rawValue: key) else { return ["error": "flight tide 6h|12h|24h|never"] }
            tide = wanted
        default:
            return ["error": "unknown flight \(op) — flight [trails on|off | tide 6h|12h|24h|never]"]
        }
        return ["flights": ["trails": trails], "tide": tide.rawValue]
    }
}

/// Tide: the gentle ebb. A trail left alone longer than this drifts under
/// the Earlier divider; nothing is closed.
enum Tide: String, CaseIterable, Identifiable {
    case h6, h12, h24, never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .h6: return "6h"
        case .h12: return "12h"
        case .h24: return "24h"
        case .never: return "Never"
        }
    }

    var hours: Double? {
        switch self {
        case .h6: return 6
        case .h12: return 12
        case .h24: return 24
        case .never: return nil
        }
    }
}

/// Settings › Tabs › Previews: the flights, each a switch with what it does in a line,
/// and whatever it can be tuned by greyed out until it is on.
struct LabsPage: View {
    /// Not observed: the rows watch the preferences they read, and the
    /// browser says it changed on every page load behind the panel.
    let browser: Browser

    var body: some View {
        let _ = SettingsPerf.tick("labsPage") // Fork (settings-perf)
        LabsPreviews(prefs: browser.prefs)
    }
}

/// What the Trails rows say and allow, by layout. Trails are drawn only in
/// the sidebar (Side.swift), so with tabs across the top turning them on
/// would change nothing anyone can see: the switch says so and waits for the
/// sidebar. One that is already on can still be turned off — it does work
/// in the background whether or not it is drawn.
enum TrailsRow {
    static func canSwitch(on: Bool, sidebar: Bool) -> Bool { on || sidebar }

    static func canTune(on: Bool, sidebar: Bool) -> Bool { on && sidebar }

    static func detail(on: Bool, sidebar: Bool) -> String {
        let what = "Today's tabs gather into lines of intent: a search, or an address you typed, and every page you opened from it."
        if sidebar { return what + " The trail you're on opens out; the rest fold to one row each. Shown in the sidebar." }
        if on { return "Shown in the sidebar, so with tabs across the top nothing shows. Turn on Tabs › Tabs in a sidebar, or turn this off." }
        return "Shown in the sidebar — turn on Tabs › Tabs in a sidebar to use it. " + what
    }

    static func tideDetail(on: Bool, sidebar: Bool) -> String {
        if canTune(on: on, sidebar: sidebar) { return "Trails left alone this long drift under Earlier, quieter, and their pages may sleep. Nothing is closed." }
        return "With Trails on in the sidebar: trails left alone this long drift under Earlier, quieter. Nothing is closed."
    }
}

private struct LabsPreviews: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject private var flights = Flights.shared

    var body: some View {
        let sidebar = prefs.sidebar
        let canSwitch = TrailsRow.canSwitch(on: flights.trails, sidebar: sidebar)
        let canTune = TrailsRow.canTune(on: flights.trails, sidebar: sidebar)
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("Previews", note: "Turning a preview off puts everything back exactly as it was.") {
                Line("Trails — tabs by what you were doing", TrailsRow.detail(on: flights.trails, sidebar: sidebar)) {
                    Switch(on: Binding(
                        get: { flights.trails },
                        set: { on in withAnimation(Motion.settle) { flights.trails = on } }
                    ))
                    .disabled(!canSwitch)
                    .allowsHitTesting(canSwitch)
                    .opacity(canSwitch ? 1 : 0.45)
                }
                .settingsAnchor("labs.trails")
                Rule()
                Line("Tide", TrailsRow.tideDetail(on: flights.trails, sidebar: sidebar)) {
                    Segmented(options: Tide.allCases.map { ($0, $0.title) }, selection: $flights.tide)
                        .disabled(!canTune)
                        .allowsHitTesting(canTune)
                        .opacity(canTune ? 1 : 0.45)
                }
                .animation(Motion.quick, value: canTune)
                .settingsAnchor("labs.tide")
            }
        }
    }
}
