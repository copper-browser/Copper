import AppKit
import Foundation

// `Copper --mcp-stdio`: the same binary, run a second time by an MCP client
// that only speaks stdio (Claude Desktop, some editors). It reads JSON-RPC
// lines from stdin, posts each to the running Copper's HTTP endpoint with
// the token from agent.json, and writes the answers back — a pipe, nothing
// more. If Copper isn't running it is launched and waited for, so a client
// configured with the stdio form Just Works from a cold start.
//
// Runs before the app has a window and never returns: SearchApp.init calls
// it first thing, and it exits the process when stdin closes.

enum Bridge {
    static func runIfAsked() {
        CLI.runIfAsked()
        guard CommandLine.arguments.contains("--mcp-stdio") else {
            // A real app launch: headless (Headless.swift) sets itself up
            // here, before SwiftUI builds a window.
            MainActor.assumeIsolated {
                Headless.bootIfAsked()
                // No launch ends without a browser window (Fork/LaunchWatchdog.swift).
                LaunchWatchdog.arm()
            }
            // Its launch line in the trail, and the reports of any crash
            // since the last one taken in (Crashes.swift), off the main thread.
            Crashes.launched()
            return
        }
        run()
        exit(0)
    }

    private struct Config: Decodable {
        var enabled: Bool
        var port: UInt16
        var token: String
    }

    private static func config() -> Config? {
        guard let data = try? Data(contentsOf: Store.file("agent.json")),
              var config = try? JSONDecoder().decode(Config.self, from: data) else { return nil }
        if let port = MCP.portOverride { config.port = port }
        return config
    }

    private static func run() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let err = FileHandle.standardError
        func log(_ s: String) { err.write(Data((s + "\n").utf8)) }

        guard var conf = config() else {
            log("copper: no agent.json yet — open Copper once and turn on Settings › Agents")
            answerAll(withError: "Copper's agent server is not set up — open Copper, Settings › Agents, turn it on")
            return
        }
        if !conf.enabled {
            log("copper: agent server is off — Settings › Agents")
            answerAll(withError: "Copper's agent server is off — Settings › Agents › Let agents drive this window")
            return
        }

        // Wake the app when it isn't up, then wait for its port. During a
        // quit the old process can still be registered while its listener is
        // already gone; opening another Copper there would race the session
        // restore, so an existing instance always gets the waiting path.
        if !reachable(conf.port) {
            let existing = copperProcessExists()
            if existing {
                log("copper: Copper is already quitting; waiting for its agent port…")
            } else {
                log("copper: launching Copper…")
                launch()
            }
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline, !reachable(conf.port) { Thread.sleep(forTimeInterval: 0.25) }
            if let fresh = config() { conf = fresh } // the token may have rotated
        }
        guard reachable(conf.port) else {
            answerAll(withError: "Copper did not come up on port \(conf.port)")
            return
        }

        let url = URL(string: "http://127.0.0.1:\(conf.port)/mcp")!
        // Who this bridge is speaking for: the agent that spawned it, read
        // from the environment it was given (Hands.swift), and the name the
        // client gives at initialize — sent on every line, so each terminal
        // agent's calls are its own hand on the tabs, not "the last client".
        var clientName = ""
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if clientName.isEmpty, trimmed.contains("\"initialize\""),
               let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
               let info = (object["params"] as? [String: Any])?["clientInfo"] as? [String: Any],
               let name = info["name"] as? String { clientName = name }
            var request = URLRequest(url: url, timeoutInterval: 120)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(conf.token)", forHTTPHeaderField: "Authorization")
            request.setValue(AgentEnvironment.header(client: "copper-bridge", name: clientName), forHTTPHeaderField: "X-Copper-Agent")
            request.httpBody = Data(trimmed.utf8)
            let (data, status) = send(request)
            if status == 202 || data.isEmpty { continue }
            // One line out per message, whatever the server's formatting.
            if let object = try? JSONSerialization.jsonObject(with: data),
               let compact = try? JSONSerialization.data(withJSONObject: object) {
                print(String(decoding: compact, as: UTF8.self))
            } else {
                print(String(decoding: data, as: UTF8.self))
            }
        }
    }

    private static func send(_ request: URLRequest) -> (Data, Int) {
        final class Box: @unchecked Sendable { var body = Data(); var status = 0 }
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        URLSession.shared.dataTask(with: request) { data, response, error in
            box.body = data ?? Data()
            box.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error {
                let id = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])?["id"]
                box.body = Bridge.errorLine(id: id, "Copper unreachable: \(error.localizedDescription)")
                box.status = 500
            }
            done.signal()
        }.resume()
        done.wait()
        return (box.body, box.status)
    }

    private static func reachable(_ port: UInt16) -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!, timeoutInterval: 1)
        request.httpMethod = "GET"
        let (_, status) = send(request)
        return status == 200
    }

    private static func copperProcessExists() -> Bool {
        let current = ProcessInfo.processInfo.processIdentifier
        // This binary's own app: a development build waits for its own kind.
        return NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? Fork.bundle)
            .contains { $0.processIdentifier != current }
    }

    private static func launch() {
        // The app this binary lives in — or, from a build folder, nothing to
        // launch: the developer starts it themselves.
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: bundle, configuration: config) { _, _ in }
    }

    /// Every message that comes in gets the same refusal, and initialize
    /// gets it as a proper error, so the client shows a reason rather than
    /// hanging.
    private static func answerAll(withError text: String) {
        while let line = readLine(strippingNewline: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let id = object["id"] else { continue }
            print(String(decoding: errorLine(id: id, text), as: UTF8.self))
        }
    }

    private static func errorLine(id: Any?, _ text: String) -> Data {
        let object: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": -32000, "message": text]]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}
