import Foundation
import JavaScriptCore

// Code mode: one tool, `copper_run`, that takes a script and runs it against
// the tools an agent otherwise calls one at a time.
//
// Every tool call is a model round trip. Building a board is a dozen
// canvas_apply calls; reading five tabs and writing each one's title into a
// note is twenty. Here the agent sends one script that does all of that
// through a `copper` object — `await copper.canvas.apply({...})`,
// `await copper.browser.snapshot({...})` — and gets one answer back: what the
// script returned, what it logged, and how each call went.
//
// The script runs in a fresh JavaScriptCore context, which is the engine
// already in the OS and nothing else: no DOM, no fetch or XMLHttpRequest, no
// timers, no require or import, no files. The only thing in it besides the
// language is `copper`, and every call on it goes through MCP.invoke — the
// same path a direct `tools/call` takes, so the handlers validate the same
// arguments, the user sees the same rows in the pane (with the `reason` the
// script passes), and the user's Stop refuses the script's next call the way
// it refuses a direct one. A script can do nothing a run of direct calls
// could not; it only saves the round trips between them.
//
// The script's own code runs on a queue of its own, not the main thread, so a
// loop that never ends costs a core and not the window; JavaScriptCore's
// execution-time watchdog ends it at the deadline. The tool calls it makes
// hop to the main actor like any other.

@MainActor
enum CodeMode {
    static let runName = "copper_run"
    static let typesName = "copper_types"
    static let names: Set<String> = [runName, typesName]
    /// The MCP resource the declarations are read as.
    static let resourceURI = "copper://types/copper.d.ts"

    /// The ceilings. A run says how long it may take and how many calls it
    /// may make; these are the most it can ask for.
    enum Limits {
        static let defaultTimeout: TimeInterval = 60
        static let maxTimeout: TimeInterval = 300
        static let defaultCalls = 100
        static let maxCalls = 500
        /// console lines kept, and the bytes they may add up to.
        static let logLines = 200
        static let logBytes = 64_000
        /// The return value's JSON, after which it is cut.
        static let valueBytes = 256_000
        /// One console.log line.
        static let lineBytes = 2_000
        /// One copper.sleep.
        static let sleepSeconds: TimeInterval = 30
    }

    /// How one of the script's calls is run: by name and arguments, for the
    /// result a `tools/call` would answer (content, isError, _meta).
    typealias Call = @MainActor (String, [String: Any]) async throws -> [String: Any]
    /// Why the caller's calls are refused right now — the user pressed Stop —
    /// or nil (Drive.refusal).
    typealias Refusal = @MainActor () -> String?

    // MARK: - the catalogue

    /// The two tools, described against the tools this caller has. The
    /// summary in copper_run's description is the compact map of the
    /// `copper` object; copper_types has the whole declaration file.
    static func catalogue(for tools: [[String: Any]]) -> [[String: Any]] {
        let names = toolNames(tools)
        let summary = CodeModeTypes.summary(names)
        return [
            [
                "name": runName,
                "description": "Run one JavaScript script against Copper's tools and get one answer back, instead of a model round trip per call. The script is the body of an async function: `await` and `return` work at the top level. It sees one object, `copper`, whose methods are the tools — \(summary) — each `(args) => Promise<{text, json?, images?, summary?}>` with the same arguments, validation, permission checks and Stop as calling the tool directly (`json` is the result parsed when the tool answers JSON; a failed call rejects with an Error whose `.tool` names it). Also `copper.call(name, args)`, `copper.sleep(ms)` (≤ 30 s) and `console.log`. Nothing else: no DOM, fetch, timers, require or import. The answer is JSON: {ok, value (what the script returned, JSON-serialisable), logs, calls, callLog:[{tool, ms, error?}], ms}; a thrown error answers {ok:false, error:{message, name, line, column, tool?}} as a tool error. Limits: `timeout` seconds (default \(Int(Limits.defaultTimeout)), at most \(Int(Limits.maxTimeout))), `maxCalls` (default \(Limits.defaultCalls), at most \(Limits.maxCalls)); logs are cut at \(Limits.logLines) lines, the value at \(Limits.valueBytes / 1000) KB. Type declarations: the \(typesName) tool or the \(resourceURI) resource.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "script": ["type": "string", "description": "JavaScript (not TypeScript): the body of an async function, with `await copper.…` calls and a `return`"] as [String: Any],
                        "timeout": ["type": "number", "description": "Seconds the whole run may take, tool calls included; default \(Int(Limits.defaultTimeout)), at most \(Int(Limits.maxTimeout))"] as [String: Any],
                        "maxCalls": ["type": "integer", "description": "Tool calls the script may make; default \(Limits.defaultCalls), at most \(Limits.maxCalls). Calls past it reject"] as [String: Any],
                        "reason": Tools.reasonProperty,
                    ] as [String: Any],
                    "required": ["script"],
                ] as [String: Any],
            ],
            [
                "name": typesName,
                "description": "copper.d.ts: TypeScript declarations for the `copper` object \(runName) scripts see, generated from this Copper's tool schemas — \(names.count) tools. Check a script against it before sending it (docs/agents.md › Code mode).",
                "inputSchema": ["type": "object", "properties": ["reason": Tools.reasonProperty] as [String: Any]] as [String: Any],
            ],
        ]
    }

    /// The names a script may call: the caller's tools, less these two.
    static func toolNames(_ tools: [[String: Any]]) -> [String] {
        tools.compactMap { $0["name"] as? String }.filter { !names.contains($0) }
    }

    /// `copper_types`'s answer.
    static func types(for tools: [[String: Any]]) -> [Tools.Content] {
        let text = CodeModeTypes.declarations(tools.filter { !names.contains(($0["name"] as? String) ?? "") })
        Tools.summary?.line = "copper.d.ts · \(toolNames(tools).count) tools"
        return [.text(text)]
    }

    // MARK: - a run

    /// `copper_run`. `tools` is what this caller may call; `call` runs one of
    /// them the way MCP would, for this same caller. Never nests: a script
    /// cannot call copper_run (the name is not in its `copper`, and invoke
    /// refuses it while a run is on).
    static func run(_ args: [String: Any], tools: [[String: Any]], call: @escaping Call, refusal: @escaping Refusal) async throws -> [Tools.Content] {
        guard let script = args["script"] as? String, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Tools.Failure(text: "script required")
        }
        let timeout = min(max((args["timeout"] as? NSNumber)?.doubleValue ?? Limits.defaultTimeout, 1), Limits.maxTimeout)
        let maxCalls = min(max((args["maxCalls"] as? NSNumber)?.intValue ?? Limits.defaultCalls, 1), Limits.maxCalls)
        let names = toolNames(tools)
        let started = Date()
        let runner = CodeModeRunner(names: names, timeout: timeout, maxCalls: maxCalls, call: call, refusal: refusal)
        let outcome = await runner.run(script)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let calls = outcome.callLog.count
        Tools.summary?.line = "script · \(calls) call\(calls == 1 ? "" : "s") · \(String(format: "%.1f s", Double(ms) / 1000))" + (outcome.error == nil ? "" : " · failed")
        var out: [String: Any] = ["ok": outcome.error == nil, "logs": outcome.logs, "calls": calls, "callLog": outcome.callLog, "ms": ms]
        if outcome.logsDropped > 0 { out["logsDropped"] = outcome.logsDropped }
        if outcome.callCapReached { out["callCapReached"] = true }
        if let error = outcome.error {
            out["error"] = error
        } else {
            // The value went through JSON.stringify in the script's own
            // context; here it only comes back to an object for the answer.
            let json = outcome.value ?? "null"
            if json.utf8.count > Limits.valueBytes {
                out["value"] = String(decoding: json.utf8.prefix(Limits.valueBytes), as: UTF8.self)
                out["valueTruncated"] = true
            } else {
                out["value"] = (try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])) ?? json
            }
        }
        let text = encode(out)
        if outcome.error != nil { throw Tools.Failure(text: text) }
        return [.text(text)]
    }

    nonisolated static func encode(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - the script's context

    /// What a run came to: the value's JSON or an error, what it logged and
    /// how each call went.
    struct Outcome {
        var value: String?
        var error: [String: Any]?
        var logs: [String] = []
        var logsDropped = 0
        var callLog: [[String: Any]] = []
        var callCapReached = false
    }
}

/// One script, in one context, on one queue. The JavaScriptCore context
/// and every JSValue are touched only on `queue`; the tool calls run on
/// the main actor and come back to the queue with their answers.
final class CodeModeRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "copper.codemode", qos: .userInitiated)
    private let names: [String]
    private let timeout: TimeInterval
    private let maxCalls: Int
    private let call: CodeMode.Call
    private let refusal: CodeMode.Refusal
    private let deadline: Date
    private var context: JSContext?
    private var group: JSContextGroupRef?
    private var outcome = CodeMode.Outcome()
    private var logBytes = 0
    private var finished = false
    private var terminated = false
    private var lastException: JSValue?
    private var continuation: CheckedContinuation<CodeMode.Outcome, Never>?
    /// The tool calls in flight, so the deadline can cancel them, and
    /// each one's promise. The JSValues stay here, on the queue: a task
    /// that carried them could let the last one go on the main thread,
    /// which takes the engine's lock — behind a script that is spinning.
    private var inflight: [Int: Task<Void, Never>] = [:]
    private var pending: [Int: (resolve: JSValue, reject: JSValue)] = [:]
    private var nextCall = 0
    /// The user pressed Stop: every later call is refused and the run
    /// ends with the refusal.
    private var stopped: String?

    init(names: [String], timeout: TimeInterval, maxCalls: Int, call: @escaping CodeMode.Call, refusal: @escaping CodeMode.Refusal) {
        self.names = names
        self.timeout = timeout
        self.maxCalls = maxCalls
        self.call = call
        self.refusal = refusal
        self.deadline = Date().addingTimeInterval(timeout)
    }

    func run(_ script: String) async -> CodeMode.Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<CodeMode.Outcome, Never>) in
            queue.async { [self] in
                self.continuation = continuation
                start(script)
            }
        }
    }

    // MARK: the watchdog

    /// JavaScriptCore's execution-time limit, `JSContextGroupSetExecutionTimeLimit`.
    /// It is in JavaScriptCore's private header, so it is looked up by
    /// name, the way Backstage reaches WebKit's occlusion switch; without
    /// it a script that never yields runs until the process does, so a
    /// context is refused when the symbol is missing.
    private typealias Terminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, Terminate?, UnsafeMutableRawPointer?) -> Void
    private static let setLimit: SetLimit? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else { return nil }
        return unsafeBitCast(symbol, to: SetLimit.self)
    }()

    /// Before every entry into the engine: however long is left. The
    /// limit is measured while JavaScript runs, so a slice that spins
    /// ends at the deadline whatever it does; time spent in a tool call,
    /// outside the engine, is the wall clock's to count.
    private func arm() {
        guard let group, let setLimit = CodeModeRunner.setLimit else { return }
        let left = max(0.01, deadline.timeIntervalSinceNow)
        // The callback must answer true to end the script. Nothing is
        // caught: the engine unwinds to the API call that entered it.
        setLimit(group, left, { _, _ in true }, nil)
    }

    // MARK: starting

    private func start(_ script: String) {
        guard CodeModeRunner.setLimit != nil else {
            return finish(error: ["message": "Code mode is unavailable: this JavaScriptCore has no execution-time limit", "name": "Unavailable"])
        }
        guard let context = JSContext() else {
            return finish(error: ["message": "Couldn't make a JavaScript context", "name": "Unavailable"])
        }
        self.context = context
        group = JSContextGetGroup(context.jsGlobalContextRef)
        context.name = "copper_run"
        context.exceptionHandler = { [weak self] _, exception in self?.lastException = exception }

        // The three native doors, taken off the global by the shim once
        // it has them: a tool call, a console line, a sleep.
        let nativeCall: @convention(block) (String, String) -> JSValue? = { [weak self] name, argsJSON in
            self?.callFromScript(name, argsJSON)
        }
        let nativeLog: @convention(block) (String, String) -> Void = { [weak self] level, text in
            self?.log(level, text)
        }
        let nativeSleep: @convention(block) (Double) -> JSValue? = { [weak self] ms in
            self?.sleepFromScript(ms)
        }
        let native = JSValue(newObjectIn: context)
        native?.setValue(nativeCall, forProperty: "call")
        native?.setValue(nativeLog, forProperty: "log")
        native?.setValue(nativeSleep, forProperty: "sleep")
        context.setObject(native, forKeyedSubscript: "__copperNative" as NSString)
        context.setObject(names, forKeyedSubscript: "__copperTools" as NSString)
        arm()
        context.evaluateScript(CodeModeRunner.shim, withSourceURL: URL(string: "copper://run/copper.js"))
        afterEntry()
        if finished { return }

        // The script is the body of an async function, so `await` and
        // `return` work at the top level. The opener shares its first
        // line, so the line numbers in an error are the script's own.
        // The value is stringified in the script's own context: a cycle
        // or a BigInt is the script's error, not a crash out here.
        let wrapped = "(async () => {" + script + "\n})().then((v) => { const s = JSON.stringify(v === undefined ? null : v); return s === undefined ? \"null\" : s; })"
        arm()
        let promise = context.evaluateScript(wrapped, withSourceURL: URL(string: "copper://run/script.js"))
        afterEntry()
        if finished { return }
        let done: @convention(block) (JSValue?) -> Void = { [weak self] value in
            guard let self else { return }
            self.outcome.value = value?.isString == true ? value?.toString() : "null"
            self.finish(error: nil)
        }
        let failed: @convention(block) (JSValue?) -> Void = { [weak self] error in
            guard let self else { return }
            self.finish(error: error.map(CodeModeRunner.describe) ?? ["message": "Script failed", "name": "Error"])
        }
        arm()
        promise?.invokeMethod("then", withArguments: [done, failed])
        afterEntry()
        // A script that returns without awaiting has already finished
        // in the handlers above; otherwise its calls carry it on.
        queue.asyncAfter(deadline: .now() + timeout + 0.05) { [weak self] in self?.timedOut() }
    }

    /// The shim: builds `copper` and `console` from the three doors, then
    /// removes the doors. `copper.browser.navigateBack` is the tool
    /// `browser_navigate_back`: the first word is the namespace, the rest
    /// camel-cased. Arguments go to the tool as JSON and the answer comes
    /// back as JSON, so the handler sees exactly what an HTTP call sends.
    private static let shim = #"""
    (function () {
      const native = globalThis.__copperNative;
      const names = Array.from(globalThis.__copperTools);
      delete globalThis.__copperNative;
      delete globalThis.__copperTools;
      const call = native.call.bind(native), log = native.log.bind(native), sleep = native.sleep.bind(native);
      function args(a) {
        if (a === undefined || a === null) return "{}";
        if (typeof a !== "object" || Array.isArray(a)) throw new TypeError("tool arguments must be an object");
        return JSON.stringify(a);
      }
      async function run(name, a) {
        if (typeof name !== "string") throw new TypeError("tool name must be a string");
        const answer = JSON.parse(await call(name, args(a)));
        if (answer.error !== undefined) {
          const e = new Error(answer.error);
          e.name = "CopperToolError";
          e.tool = name;
          throw e;
        }
        return answer;
      }
      const copper = { call: run, tools: Object.freeze(names.slice()), sleep: (ms) => sleep(Number(ms)) };
      for (const name of names) {
        const i = name.indexOf("_");
        const ns = i < 0 ? "copper" : name.slice(0, i);
        const method = (i < 0 ? name : name.slice(i + 1)).replace(/_([a-z0-9])/g, (_, c) => c.toUpperCase());
        if (!copper[ns]) copper[ns] = {};
        copper[ns][method] = (a) => run(name, a);
      }
      for (const key of Object.keys(copper)) if (typeof copper[key] === "object") Object.freeze(copper[key]);
      Object.freeze(copper);
      Object.defineProperty(globalThis, "copper", { value: copper, writable: false, configurable: false, enumerable: true });
      function fmt(parts) {
        return parts.map((v) => {
          if (typeof v === "string") return v;
          if (v instanceof Error) return v.stack ? v.name + ": " + v.message + "\n" + v.stack : String(v);
          try { const s = JSON.stringify(v); return s === undefined ? String(v) : s; } catch (_) { return String(v); }
        }).join(" ");
      }
      const console = {};
      for (const level of ["log", "info", "warn", "error", "debug"]) console[level] = (...parts) => log(level, fmt(parts));
      Object.freeze(console);
      Object.defineProperty(globalThis, "console", { value: console, writable: false, configurable: false, enumerable: false });
    })();
    """#

    // MARK: the doors

    /// `copper.call(name, args)`: a promise for the tool's answer. On the
    /// queue, called by the script.
    private func callFromScript(_ name: String, _ argsJSON: String) -> JSValue? {
        guard let context else { return nil }
        return JSValue(newPromiseIn: context) { [self] resolve, reject in
            guard let resolve, let reject else { return }
            if let stopped {
                reject.call(withArguments: [JSValue(newErrorFromMessage: stopped, in: context) as Any])
                return
            }
            guard names.contains(name) else {
                reject.call(withArguments: [JSValue(newErrorFromMessage: "no tool named \(name) — copper.tools lists them", in: context) as Any])
                return
            }
            guard outcome.callLog.count + inflight.count < maxCalls else {
                outcome.callCapReached = true
                reject.call(withArguments: [JSValue(newErrorFromMessage: "call cap of \(maxCalls) reached (maxCalls)", in: context) as Any])
                return
            }
            guard Date() < deadline else {
                reject.call(withArguments: [JSValue(newErrorFromMessage: "timed out after \(Int(timeout)) s", in: context) as Any])
                return
            }
            // The same JSON a request carries, read the same way, so the
            // handler sees the same Foundation values a direct call gives it.
            guard let data = argsJSON.data(using: .utf8),
                  let arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                reject.call(withArguments: [JSValue(newErrorFromMessage: "tool arguments must be a JSON object", in: context) as Any])
                return
            }
            let id = nextCall
            nextCall += 1
            pending[id] = (resolve, reject)
            let began = Date()
            let call = self.call
            let task = Task { @MainActor in
                var answer: [String: Any]
                do {
                    answer = try await call(name, arguments)
                } catch {
                    answer = ["content": [["type": "text", "text": (error as? Tools.Failure)?.text ?? error.localizedDescription]], "isError": true]
                }
                // Stop pressed during or before this call: the handler
                // answered the refusal, and the run ends with it.
                let refused = refusal()
                self.queue.async { [self] in
                    settle(id, name: name, began: began, answer: answer, refused: refused)
                }
            }
            inflight[id] = task
        }
    }

    /// A tool call came back: its row in the log, and the promise kept
    /// or broken. A refusal — the user pressed Stop — ends the run.
    private func settle(_ id: Int, name: String, began: Date, answer: [String: Any], refused: String?) {
        inflight[id] = nil
        let promise = pending.removeValue(forKey: id)
        guard !finished, let context, let promise else { return }
        let (resolve, reject) = promise
        let ms = Int(Date().timeIntervalSince(began) * 1000)
        let content = answer["content"] as? [[String: Any]] ?? []
        let isError = (answer["isError"] as? Bool) ?? false
        var texts: [String] = []
        var images: [[String: String]] = []
        for item in content {
            switch item["type"] as? String {
            case "text": texts.append(item["text"] as? String ?? "")
            case "image": images.append(["mimeType": item["mimeType"] as? String ?? "", "data": item["data"] as? String ?? ""])
            default: break
            }
        }
        let text = texts.joined(separator: "\n")
        var row: [String: Any] = ["tool": name, "ms": ms]
        if isError { row["error"] = String(text.prefix(400)) }
        outcome.callLog.append(row)
        if let refused {
            stopped = refused
            // The script may catch this rejection and go on computing,
            // but never call again: the next call is refused on the
            // spot, and the run's answer is the refusal.
            outcome.error = ["message": refused, "name": "Stopped", "tool": name]
            cutShort()
            arm()
            reject.call(withArguments: [JSValue(newErrorFromMessage: refused, in: context) as Any])
            afterEntry()
            if !finished { finish(error: outcome.error) }
            return
        }
        var reply: [String: Any]
        if isError {
            reply = ["error": text]
        } else {
            reply = ["text": text]
            if let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) { reply["json"] = json }
            if !images.isEmpty { reply["images"] = images }
            if let summary = (answer["_meta"] as? [String: Any])?["summary"] as? String { reply["summary"] = summary }
        }
        let encoded = CodeMode.encode(reply)
        arm()
        resolve.call(withArguments: [encoded])
        afterEntry()
    }

    /// `copper.sleep(ms)`, capped, and never past the deadline.
    private func sleepFromScript(_ ms: Double) -> JSValue? {
        guard let context else { return nil }
        return JSValue(newPromiseIn: context) { [self] resolve, _ in
            guard let resolve else { return }
            let wanted = min(max(ms.isFinite ? ms / 1000 : 0, 0), CodeMode.Limits.sleepSeconds)
            let seconds = min(wanted, max(0, deadline.timeIntervalSinceNow))
            queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self, !self.finished else { return }
                self.arm()
                resolve.call(withArguments: [])
                self.afterEntry()
            }
        }
    }

    private func log(_ level: String, _ text: String) {
        guard outcome.logs.count < CodeMode.Limits.logLines, logBytes < CodeMode.Limits.logBytes else {
            outcome.logsDropped += 1
            return
        }
        var line = text.utf8.count > CodeMode.Limits.lineBytes ? String(decoding: text.utf8.prefix(CodeMode.Limits.lineBytes), as: UTF8.self) + "…" : text
        if level != "log" { line = "[\(level)] " + line }
        logBytes += line.utf8.count
        outcome.logs.append(line)
    }

    // MARK: ending

    /// After every entry into the engine (the promise handlers ran as it
    /// returned): an exception that came out of it ends the run. A script
    /// the watchdog ended shows up here, not as a rejection, and is a
    /// timeout; one ended for the user's Stop is the stop.
    private func afterEntry() {
        guard !finished, let exception = takeException() else { return }
        if stopped != nil {
            finish(error: outcome.error)
        } else if Date() >= deadline || terminated {
            finish(error: ["message": "timed out after \(Int(timeout)) s", "name": "Timeout"])
        } else {
            finish(error: CodeModeRunner.describe(exception))
        }
    }

    private func takeException() -> JSValue? {
        defer { lastException = nil }
        if let exception = lastException { return exception }
        if let exception = context?.exception { context?.exception = nil; return exception }
        return nil
    }

    /// The deadline passed with the script still waiting on something.
    private func timedOut() {
        guard !finished else { return }
        terminated = true
        cutShort()
        finish(error: ["message": "timed out after \(Int(timeout)) s", "name": "Timeout"])
    }

    /// No more time: whatever enters the engine next ends at once, and
    /// the calls still out are cancelled — their answers would go nowhere.
    private func cutShort() {
        terminated = true
        if let group, let setLimit = CodeModeRunner.setLimit { setLimit(group, 0.001, { _, _ in true }, nil) }
        for task in inflight.values { task.cancel() }
    }

    private func finish(error: [String: Any]?) {
        guard !finished else { return }
        finished = true
        if let error { outcome.error = error }
        let out = outcome
        let continuation = self.continuation
        self.continuation = nil
        // The context goes with the queue's next turn, after the engine
        // has fully returned from whatever entry called this.
        queue.async { [self] in
            for task in inflight.values { task.cancel() }
            inflight = [:]
            pending = [:]
            context?.exceptionHandler = nil
            context = nil
            group = nil
        }
        continuation?.resume(returning: out)
    }

    /// An error object as the answer reports it: message, name, the line
    /// and column in the script, the tool when a call failed.
    private static func describe(_ error: JSValue) -> [String: Any] {
        var out: [String: Any] = [:]
        if error.isObject {
            out["message"] = error.forProperty("message")?.toString() ?? "Error"
            let name = error.forProperty("name")?.toString() ?? ""
            out["name"] = name.isEmpty || name == "undefined" ? "Error" : name
            if let line = error.forProperty("line"), line.isNumber { out["line"] = line.toInt32() }
            if let column = error.forProperty("column"), column.isNumber { out["column"] = column.toInt32() }
            if let tool = error.forProperty("tool"), tool.isString { out["tool"] = tool.toString() }
            if let stack = error.forProperty("stack"), stack.isString {
                let text = stack.toString() ?? ""
                if !text.isEmpty { out["stack"] = String(text.prefix(2_000)) }
            }
        } else {
            out["message"] = error.toString() ?? "Error"
            out["name"] = "Error"
        }
        return out
    }
}
