import Foundation
import WebKit

// browser_permissions: what a site may use, per site — list, grant, revoke —
// for the permissions WebKit lets a browser decide.
//
// - camera, microphone: the same per-site Allow the bar at the bottom of the
//   window keeps (CaptureBook, Fork/Capture). Granted here, the page's next
//   getUserMedia is answered at once, as after the person's Allow.
// - geolocation: kept per site here (`permissions.geolocation`), answered in
//   WebKit's private geolocation question (below). Before this every
//   location request was refused. Copper has no location access of its own
//   (no Location Services), so the position a page gets is the one the agent
//   gives with latitude/longitude, as Playwright's setGeolocation; without
//   one, a granted page hears "position unavailable".
// - notifications: refused. Copper shows no web notifications, and granting
//   would tell a site its messages arrive when they don't.

@MainActor
enum Permissions {
    static let kinds = ["geolocation", "camera", "microphone", "notifications"]
    private static let geoKey = "permissions.geolocation"

    static var geoSites: Set<String> {
        get { Set(Store.settings.stringArray(forKey: geoKey) ?? []) }
        set { newValue.isEmpty ? Store.settings.removeObject(forKey: geoKey) : Store.settings.set(newValue.sorted(), forKey: geoKey) }
    }

    /// The position given pages, from the last grant that named one.
    /// shortcut: one position for every granted site (WebKit has one provider per process pool); per site if an agent ever needs two.
    private(set) static var position: (latitude: Double, longitude: Double, accuracy: Double)?

    nonisolated static var tool: [String: Any] { [
        "name": "browser_permissions",
        "description": "List, grant or revoke a site's permissions (geolocation, camera, microphone; notifications are always refused). No grant/revoke lists them.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "grant": ["type": "array", "items": ["type": "string", "enum": kindsList]] as [String: Any],
                "revoke": ["type": "array", "items": ["type": "string", "enum": kindsList]] as [String: Any],
                "site": ["type": "string", "description": "host or host:port; default your tab's"],
                "latitude": ["type": "number", "description": "Required with a geolocation grant: the position pages get"],
                "longitude": ["type": "number"],
                "accuracy": ["type": "number", "description": "Metres, default 50"],
                "reason": Tools.reasonProperty,
                "tab": Tools.tabProperty,
            ] as [String: Any],
            "required": [String](),
        ] as [String: Any],
    ] }
    nonisolated private static let kindsList = ["geolocation", "camera", "microphone", "notifications"]

    static func call(_ args: [String: Any], in browser: Browser) async throws -> [Tools.Content] {
        let grant = try names(args["grant"]), revoke = try names(args["revoke"])
        let site: String
        if let named = (args["site"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !named.isEmpty {
            site = URL(string: named.contains("://") ? named : "https://\(named)").flatMap { url in url.host().map { CaptureChoices.site(host: $0, port: url.port ?? 0) } } ?? named
        } else {
            let tab = try Tools.current(browser)
            guard let url = tab.address, let host = url.host(), !host.isEmpty else {
                throw Tools.Failure(text: "Your tab has no site (\(tab.address?.absoluteString ?? "about:blank")). Open one with browser_navigate, or pass site.")
            }
            site = CaptureChoices.site(host: host, port: url.port ?? 0)
        }
        if grant.contains("notifications") {
            throw Tools.Failure(text: "Copper doesn't show web notifications, so it can't grant them: a site would think its messages arrive. Leave notifications out and grant the rest.")
        }
        if grant.contains("geolocation") {
            let lat = try Tools.number(args, "latitude", within: 90), lon = try Tools.number(args, "longitude", within: 180)
            if let lat, let lon {
                let accuracy = try Tools.number(args, "accuracy", within: 1_000_000) ?? 50
                position = (lat, lon, max(accuracy, 1))
            } else {
                // Fork (geo-needs-place): a grant with nowhere to be is a page told "position unavailable" —
                // or, after another site's grant, quietly given that site's position.
                throw Tools.Failure(text: "geolocation needs latitude and longitude: Copper has no location of its own, so the page would only get \"position unavailable\". Call browser_permissions again with grant [\"geolocation\"], latitude and longitude (for example latitude 25.76, longitude -80.19). Nothing was granted.")
            }
            GeoProvider.install()
            geoSites.insert(site)
        }
        var devices: CaptureDevices = []
        if grant.contains("camera") { devices.insert(.camera) }
        if grant.contains("microphone") { devices.insert(.microphone) }
        if !devices.isEmpty { CaptureBook.choices.allow(site, devices) }
        if revoke.contains("geolocation") { geoSites.remove(site) }
        var gone: CaptureDevices = []
        if revoke.contains("camera") { gone.insert(.camera) }
        if revoke.contains("microphone") { gone.insert(.microphone) }
        if !gone.isEmpty { CaptureBook.choices.revoke(site, gone) }
        var lines = ["### Permissions for \(site)"]
        for kind in kinds { lines.append("- \(kind): \(state(kind, site))") }
        if geoSites.contains(site), position == nil {
            lines.append("Copper has no location of its own: pass latitude and longitude with the geolocation grant to give pages a position.")
        }
        return [.text(lines.joined(separator: "\n"))]
    }

    private static func names(_ raw: Any?) throws -> [String] {
        guard let raw else { return [] }
        let list = (raw as? [String]) ?? (raw as? String).map { [$0] } ?? []
        let wrong = list.filter { !kinds.contains($0) }
        guard wrong.isEmpty else { throw Tools.Failure(text: "Unknown permission \(wrong.joined(separator: ", ")); use one of \(kinds.joined(separator: ", ")).") }
        return list
    }

    static func state(_ kind: String, _ site: String) -> String {
        switch kind {
        case "geolocation": return geoSites.contains(site) ? (position.map { "granted (at \($0.latitude), \($0.longitude))" } ?? "granted (no position given)") : "ask (refused)"
        case "camera": return CaptureBook.choices.covers(site, .camera) ? "granted" : "ask"
        case "microphone": return CaptureBook.choices.covers(site, .microphone) ? "granted" : "ask"
        default: return "refused (Copper shows no web notifications)"
        }
    }

    static func geolocation(_ origin: WKSecurityOrigin) -> Bool {
        !origin.host.isEmpty && geoSites.contains(CaptureChoices.site(host: origin.host, port: origin.port))
    }

    // MARK: - WebKit's location provider (C SPI, WKGeolocationManager.h)

    /// Hands WebKit the agent's position. WebKit on the Mac has no provider of
    /// its own; without one a granted page gets "position unavailable".
    @MainActor enum GeoProvider {
        private typealias Callback = @convention(c) (OpaquePointer?, UnsafeRawPointer?) -> Void
        private struct V0 { var version: Int32; var clientInfo: UnsafeRawPointer?; var start: Callback; var stop: Callback }
        private static var installed = false
        private static var managers: [OpaquePointer] = []

        private static func symbol<T>(_ name: String, _: T.Type) -> T? {
            dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: T.self) } // RTLD_DEFAULT
        }

        static func install() {
            if installed { return push() }
            guard let pool = Web.pool as AnyObject?,
                  let manager = symbol("WKContextGetGeolocationManager", (@convention(c) (UnsafeRawPointer) -> OpaquePointer?).self),
                  let set = symbol("WKGeolocationManagerSetProvider", (@convention(c) (OpaquePointer, UnsafeRawPointer) -> Void).self),
                  let geo = manager(Unmanaged.passUnretained(pool).toOpaque()) else { return }
            let provider = UnsafeMutablePointer<V0>.allocate(capacity: 1) // WebKit reads it for as long as it runs
            provider.initialize(to: V0(version: 0, clientInfo: nil, start: { manager, _ in
                guard let manager else { return }
                MainActor.assumeIsolated { GeoProvider.started(manager) }
            }, stop: { _, _ in }))
            set(geo, provider)
            installed = true
        }

        private static func started(_ manager: OpaquePointer) {
            if !managers.contains(manager) { managers.append(manager) }
            push()
        }

        private static func push() {
            guard let position else {
                // Said at once: unanswered, the page waits out its own timeout.
                guard let failed = symbol("WKGeolocationManagerProviderDidFailToDeterminePosition", (@convention(c) (OpaquePointer) -> Void).self) else { return }
                managers.forEach(failed)
                return
            }
            guard let create = symbol("WKGeolocationPositionCreate", (@convention(c) (Double, Double, Double, Double) -> OpaquePointer?).self),
                  let changed = symbol("WKGeolocationManagerProviderDidChangePosition", (@convention(c) (OpaquePointer, OpaquePointer) -> Void).self),
                  let release = symbol("WKRelease", (@convention(c) (OpaquePointer) -> Void).self) else { return }
            for manager in managers {
                guard let fix = create(Date().timeIntervalSince1970, position.latitude, position.longitude, position.accuracy) else { continue }
                changed(manager, fix)
                release(fix)
            }
        }
    }
}

extension Browser {
    /// WebKit's private location question (WKUIDelegatePrivate). Unanswered,
    /// WebKit refuses; answered, only the sites granted with browser_permissions.
    @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func geolocationRequest(_ webView: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo, decisionHandler: @escaping (Int) -> Void) {
        decisionHandler(Permissions.geolocation(origin) ? WKPermissionDecision.grant.rawValue : WKPermissionDecision.deny.rawValue)
    }
}
