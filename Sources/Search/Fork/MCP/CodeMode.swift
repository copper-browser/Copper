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
// script passes), and the user's Stop ends the run the way it refuses a
// direct call. A script can do nothing a run of direct calls could not; it
// only saves the round trips between them. The few tools a person should
// approve one at a time — signing in, filling a card, deleting cloud history,
// reading the Listen transcript — are not in its `copper` at all.
//
// The script's own code runs on a queue of its own, not the main thread, so a
// loop that never ends costs a core and not the window; JavaScriptCore's
// watchdog polls it every tenth of a second and ends it at the deadline, at a
// memory budget, or when the user has stopped it.

@MainActor
enum CodeMode {
    static let runName = "copper_run"
    static let typesName = "copper_types"
    static let names: Set<String> = [runName, typesName]
    /// The MCP resource the declarations are read as.
    static let resourceURI = "copper://types/copper.d.ts"

    /// Tools a script never gets, whatever the caller has: each is one call
    /// the person should see and approve on its own, and none saves a round
    /// trip worth having.
    static let excluded: Set<String> = ["browser_sign_in", "browser_autofill", CloudHistoryTool.name, VoiceTools.statusName, VoiceTools.transcriptName]

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
        /// One console.log line, and one error's message or stack.
        static let lineBytes = 2_000
        /// One copper.sleep.
        static let sleepSeconds: TimeInterval = 30
        /// Scripts running at once, across every caller.
        static let concurrent = 4
        /// How much the process may grow while a script runs before the
        /// watchdog ends it: a script allocating in a loop would otherwise
        /// take the browser down with it.
        static let memoryBytes: UInt64 = 512 << 20
        /// How often the watchdog looks.
        static let poll: TimeInterval = 0.1
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
                "description": "Run one JavaScript script against Copper's tools and get one answer back, instead of a model round trip per call. Use it when the steps are known in advance — build a board, read N tabs into a note — not when each step needs a decision. The script is the body of an async function: `await` and `return` work at the top level. It sees one object, `copper`, whose methods are the tools — \(summary) — each `(args) => Promise<{text, json?, images?, summary?}>` with the same arguments, validation, permission checks and Stop as calling the tool directly (`json` is the result parsed when the tool answers JSON; a failed call rejects with an Error whose `.tool` names it). Also `copper.call(name, args)`, `copper.sleep(ms)` (≤ 30 s) and `console.log`. Nothing else: no DOM, fetch, timers, require or import; browser_sign_in, browser_autofill, cloud_history_delete and the voice tools are not in it — call those directly. The answer is JSON: {ok, value (what the script returned, JSON-serialisable), logs, calls, callLog:[{tool, ms, error?}], ms}; a thrown error answers {ok:false, error:{message, name, line, column, tool?}} as a tool error. Limits: `timeout` seconds (default \(Int(Limits.defaultTimeout)), at most \(Int(Limits.maxTimeout))), `maxCalls` (default \(Limits.defaultCalls), at most \(Limits.maxCalls)); logs are cut at \(Limits.logLines) lines, the value at \(Limits.valueBytes / 1000) KB. Type declarations: the \(typesName) tool or the \(resourceURI) resource.",
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
                // A host that asks the person before a tool runs should treat
                // this one as the many it stands for.
                "annotations": ["title": "Run a script against Copper's tools", "readOnlyHint": false, "destructiveHint": true, "openWorldHint": true] as [String: Any],
            ],
            [
                "name": typesName,
                "description": "copper.d.ts: TypeScript declarations for the `copper` object \(runName) scripts see, generated from this Copper's tool schemas — \(names.count) tools. Check a script against it before sending it (docs/agents.md › Code mode).",
                "inputSchema": ["type": "object", "properties": ["reason": Tools.reasonProperty] as [String: Any]] as [String: Any],
                "annotations": ["title": "The copper object's types", "readOnlyHint": true] as [String: Any],
            ],
        ]
    }

    /// The tools a script may call: the caller's, less these two and the
    /// excluded few.
    static func scriptTools(_ tools: [[String: Any]]) -> [[String: Any]] {
        tools.filter { tool in
            guard let name = tool["name"] as? String else { return false }
            return !names.contains(name) && !excluded.contains(name)
        }
    }

    static func toolNames(_ tools: [[String: Any]]) -> [String] {
        scriptTools(tools).compactMap { $0["name"] as? String }
    }

    /// `copper_types`'s answer.
    static func types(for tools: [[String: Any]]) -> [Tools.Content] {
        let text = CodeModeTypes.declarations(scriptTools(tools))
        Tools.summary?.line = "copper.d.ts · \(toolNames(tools).count) tools"
        return [.text(text)]
    }

    // MARK: - the runs

    /// Every script running right now, by the keys the user's Stop comes
    /// in under: the caller's own (Drive.refuse) and the Jev run it may
    /// have started ("jev:" + the caller's, Drive.stop's .jev branch).
    private static var live: [String: [CodeModeRunner]] = [:]

    static var running: Int { Set(live.values.flatMap { $0 }.map { ObjectIdentifier($0) }).count }

    /// Whether this session has a script on: its run must not lapse
    /// between the script's calls (Drive.lapse).
    static func isRunning(_ key: String) -> Bool { !(live[key] ?? []).isEmpty }

    /// The user's Stop reached this session: its scripts end now, with the
    /// words a direct call would be refused with.
    static func stop(key: String, because text: String) {
        for runner in live[key] ?? [] { runner.stop(text) }
    }

    private static func register(_ runner: CodeModeRunner, keys: [String]) {
        for key in keys { live[key, default: []].append(runner) }
    }

    private static func unregister(_ runner: CodeModeRunner) {
        for key in live.keys {
            live[key]?.removeAll { $0 === runner }
            if live[key]?.isEmpty == true { live[key] = nil }
        }
    }

    /// `copper_run`. `tools` is what this caller may call; `call` runs one of
    /// them the way MCP would, for this same caller. Never nests: a script
    /// cannot call copper_run (the name is not in its `copper`, and invoke
    /// refuses it while a run is on).
    static func run(_ args: [String: Any], tools: [[String: Any]], caller: Drive.Who, call: @escaping Call, refusal: @escaping Refusal) async throws -> [Tools.Content] {
        guard let script = args["script"] as? String, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Tools.Failure(text: "script required")
        }
        guard running < Limits.concurrent else {
            throw Tools.Failure(text: "\(Limits.concurrent) scripts are already running — wait for one to finish")
        }
        let timeout = min(max((args["timeout"] as? NSNumber)?.doubleValue ?? Limits.defaultTimeout, 1), Limits.maxTimeout)
        let maxCalls = min(max((args["maxCalls"] as? NSNumber)?.intValue ?? Limits.defaultCalls, 1), Limits.maxCalls)
        let names = toolNames(tools)
        let started = Date()
        let runner = CodeModeRunner(tools: names.map { (name: $0, place: CodeModeTypes.split($0)) }, timeout: timeout, maxCalls: maxCalls, call: call, refusal: refusal)
        register(runner, keys: [caller.key, Drive.Who.jev(for: caller).key])
        let outcome = await runner.run(script)
        unregister(runner)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let calls = outcome.callLog.count
        Tools.summary?.line = "script · \(calls) call\(calls == 1 ? "" : "s") · \(String(format: "%.1f s", Double(ms) / 1000))" + (outcome.error == nil ? "" : " · failed")
        var out: [String: Any] = ["ok": outcome.error == nil, "logs": outcome.logs, "calls": calls, "callLog": outcome.callLog, "ms": ms]
        if outcome.logsDropped > 0 { out["logsDropped"] = outcome.logsDropped }
        if outcome.callCapReached { out["callCapReached"] = true }
        if outcome.abandoned > 0 { out["abandoned"] = outcome.abandoned }
        if let error = outcome.error {
            out["error"] = error
        } else {
            // The value went through JSON.stringify in the script's own
            // context, cut there if it was too long (the marker says so);
            // here it only comes back to an object for the answer.
            var json = outcome.value ?? "null"
            if json.hasPrefix("\u{0}") {
                json.removeFirst()
                out["value"] = json
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

    /// What a run came to: the value's JSON or an error, what it logged and
    /// how each call went.
    struct Outcome {
        var value: String?
        var error: [String: Any]?
        var logs: [String] = []
        var logsDropped = 0
        var callLog: [[String: Any]] = []
        var callCapReached = false
        /// Calls still out when the run ended: they finish on their own
        /// bounds, as a direct call whose client went away would, and their
        /// answers are dropped.
        var abandoned = 0
    }
}

/// One script, in one context, on one queue. The JavaScriptCore context
/// and every JSValue are touched only on `queue`; the tool calls run on
/// the main actor and come back to the queue with their answers. The
/// bookkeeping is under a lock, because the deadline, the memory watchdog
/// and the user's Stop end a run from other threads — and must, since the
/// queue may be inside a script that is not giving it back.
final class CodeModeRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "copper.codemode", qos: .utility)
    private let tools: [(name: String, place: (namespace: String, method: String))]
    private let names: Set<String>
    private let timeout: TimeInterval
    private let maxCalls: Int
    private let call: CodeMode.Call
    private let refusal: CodeMode.Refusal
    private let deadline: Date

    // On the queue only.
    private var context: JSContext?
    private var group: JSContextGroupRef?
    /// The shim's helpers, kept here and never on the script's global:
    /// the intrinsic Promise.prototype.then, and the value and error
    /// writers. A script that replaces `then` or `JSON.stringify` on its
    /// prototypes changes nothing out here.
    private var helpers: JSValue?
    private var lastException: JSValue?
    private var pending: [Int: (resolve: JSValue, reject: JSValue)] = [:]
    private var footprintAtStart: UInt64 = 0
    private var retained = false

    // Under `lock`.
    private let lock = NSLock()
    private var outcome = CodeMode.Outcome()
    private var logBytes = 0
    private var finished = false
    private var continuation: CheckedContinuation<CodeMode.Outcome, Never>?
    private var inflight = 0
    private var nextCall = 0
    /// Why the watchdog ended the script, when it did.
    private var killed: Kill?
    private enum Kill { case deadline, memory, stopped }

    init(tools: [(name: String, place: (namespace: String, method: String))], timeout: TimeInterval, maxCalls: Int, call: @escaping CodeMode.Call, refusal: @escaping CodeMode.Refusal) {
        self.tools = tools
        self.names = Set(tools.map(\.name))
        self.timeout = timeout
        self.maxCalls = maxCalls
        self.call = call
        self.refusal = refusal
        self.deadline = Date().addingTimeInterval(timeout)
    }

    func run(_ script: String) async -> CodeMode.Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<CodeMode.Outcome, Never>) in
            lock.withLock { self.continuation = continuation }
            queue.async { [self] in start(script) }
            // The deadline, off the queue: a script that has the queue and
            // is not giving it back still gets its answer written.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout + 0.05) { [weak self] in self?.timedOut() }
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

    /// The watchdog's question, every `poll` seconds while script runs: go
    /// on, or end it. True ends it; false re-arms the same interval. The
    /// limit only counts time inside the engine, so the clock is read here
    /// rather than trusted to the limit.
    private static let shouldTerminate: Terminate = { _, pointer in
        guard let pointer else { return true }
        return Unmanaged<CodeModeRunner>.fromOpaque(pointer).takeUnretainedValue().shouldTerminate()
    }

    private func shouldTerminate() -> Bool {
        lock.withLock {
            if finished { return true }
            if Date() >= deadline { killed = .deadline; return true }
            if CodeModeRunner.footprint() > footprintAtStart + CodeMode.Limits.memoryBytes { killed = .memory; return true }
            return false
        }
    }

    /// Before every entry into the engine. The runner is handed to the
    /// callback unretained: the group, and with it the callback, go in the
    /// teardown, which releases the runner's own hold afterwards.
    private func arm(_ interval: TimeInterval = CodeMode.Limits.poll) {
        guard let group, let setLimit = CodeModeRunner.setLimit else { return }
        setLimit(group, interval, CodeModeRunner.shouldTerminate, Unmanaged.passUnretained(self).toOpaque())
    }

    /// The process's physical footprint, the number Activity Monitor shows.
    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    // MARK: starting

    private func start(_ script: String) {
        guard CodeModeRunner.setLimit != nil else {
            return finish(error: ["message": "Code mode is unavailable: this JavaScriptCore has no execution-time limit", "name": "Unavailable"])
        }
        guard let context = JSContext() else {
            return finish(error: ["message": "Couldn't make a JavaScript context", "name": "Unavailable"])
        }
        // The runner lives at least until the teardown lets this go: the
        // watchdog holds it unretained.
        _ = Unmanaged.passRetained(self)
        retained = true
        self.context = context
        group = JSContextGetGroup(context.jsGlobalContextRef)
        footprintAtStart = CodeModeRunner.footprint()
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
        // The methods, named out here (CodeModeTypes.split), so the object
        // and copper.d.ts never disagree.
        context.setObject(tools.map { [$0.name, $0.place.namespace, $0.place.method] }, forKeyedSubscript: "__copperTools" as NSString)
        context.setObject(["value": CodeMode.Limits.valueBytes, "line": CodeMode.Limits.lineBytes, "args": Connection.maxRequest], forKeyedSubscript: "__copperLimits" as NSString)
        arm()
        helpers = context.evaluateScript(CodeModeRunner.shim, withSourceURL: URL(string: "copper://run/copper.js"))
        if ended(after: takeException()) { return }
        guard let helpers, helpers.isObject else { return finish(error: ["message": "Couldn't set up the copper object", "name": "Unavailable"]) }

        // The script is the body of an async function, so `await` and
        // `return` work at the top level. The opener has a line of its own,
        // and the error writer takes that line back off, so what an error
        // reports is the script's own line and column. The function is only
        // made here; it is called below, through the engine's own API, and
        // its promise is watched through the intrinsic `then` the shim kept
        // — nothing a script redefines on a prototype is in that path.
        arm()
        let made = context.evaluateScript("(async () => {\n" + script + "\n})", withSourceURL: URL(string: "copper://run/script.js"))
        if ended(after: takeException()) { return }
        let ref = context.jsGlobalContextRef
        guard let made, made.isObject, JSObjectIsFunction(ref, made.jsValueRef) else {
            return finish(error: ["message": "The script is not a function body", "name": "SyntaxError"])
        }
        let done: @convention(block) (JSValue?) -> Void = { [weak self] value in self?.done(value) }
        let failed: @convention(block) (JSValue?) -> Void = { [weak self] error in self?.failed(error) }
        arm()
        var exception: JSValueRef?
        let promise = JSObjectCallAsFunction(ref, made.jsValueRef, nil, 0, nil, &exception)
        if ended(after: exception.map { JSValue(jsValueRef: $0, in: context) } ?? takeException()) { return }
        guard let promise, JSValueIsObject(ref, promise), let then = helpers.forProperty("then"), then.isObject else {
            return finish(error: ["message": "The script did not make a promise", "name": "Error"])
        }
        // Held through the call: a bare JSValueRef is nothing the collector
        // knows about.
        let doneValue = JSValue(object: done, in: context)
        let failedValue = JSValue(object: failed, in: context)
        let handlers: [JSValueRef?] = [doneValue?.jsValueRef, failedValue?.jsValueRef]
        arm()
        withExtendedLifetime((doneValue, failedValue)) {
            handlers.withUnsafeBufferPointer { buffer in
                _ = JSObjectCallAsFunction(ref, then.jsValueRef, promise, buffer.count, buffer.baseAddress, &exception)
            }
        }
        _ = ended(after: exception.map { JSValue(jsValueRef: $0, in: context) } ?? takeException())
        // A script that returns without awaiting has already finished in
        // the handlers above; otherwise its calls and sleeps carry it on.
    }

    /// The shim: builds `copper` and `console` from the three doors, then
    /// removes the doors, and hands back the helpers the runner keeps for
    /// itself. Arguments go to the tool as JSON and the answer comes back
    /// as JSON, so the handler sees exactly what an HTTP call sends.
    private static let shim = #"""
    (function () {
      const native = globalThis.__copperNative;
      const tools = Array.from(globalThis.__copperTools);
      const limits = globalThis.__copperLimits;
      delete globalThis.__copperNative;
      delete globalThis.__copperTools;
      delete globalThis.__copperLimits;
      // Shared memory and WebAssembly have no place here: Atomics.wait can
      // hold the thread where the watchdog cannot reach it.
      delete globalThis.SharedArrayBuffer;
      delete globalThis.Atomics;
      delete globalThis.WebAssembly;
      const call = native.call.bind(native), log = native.log.bind(native), sleep = native.sleep.bind(native);
      const stringify = JSON.stringify, parse = JSON.parse;
      function args(a) {
        if (a === undefined || a === null) return "{}";
        if (typeof a !== "object" || Array.isArray(a)) throw new TypeError("tool arguments must be an object");
        const s = stringify(a);
        if (s.length > limits.args) throw new RangeError("tool arguments are too large");
        return s;
      }
      async function run(name, a) {
        if (typeof name !== "string") throw new TypeError("tool name must be a string");
        const answer = parse(await call(name, args(a)));
        if (answer.error !== undefined) {
          const e = new Error(answer.error);
          e.name = "CopperToolError";
          e.tool = name;
          throw e;
        }
        return answer;
      }
      const copper = { call: run, tools: Object.freeze(tools.map((t) => t[0])), sleep: (ms) => sleep(Number(ms)) };
      for (const [name, ns, method] of tools) {
        if (ns in copper && typeof copper[ns] !== "object") continue;
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
          try { const s = stringify(v); return s === undefined ? String(v) : s; } catch (_) { return String(v); }
        }).join(" ").slice(0, limits.line);
      }
      const console = {};
      for (const level of ["log", "info", "warn", "error", "debug"]) console[level] = (...parts) => log(level, fmt(parts));
      Object.freeze(console);
      Object.defineProperty(globalThis, "console", { value: console, writable: false, configurable: false, enumerable: false });
      // For the runner: the value as JSON (cut, with a marker, when long),
      // and an error as the answer reports it — the script's own line.
      const value = (v) => {
        const s = stringify(v === undefined ? null : v);
        if (s === undefined) return "null";
        return s.length > limits.value ? "\u0000" + s.slice(0, limits.value) : s;
      };
      const script = /copper:\/\/run\/script\.js:(\d+):(\d+)/;
      const describe = (e) => {
        const out = {};
        if (e !== null && (typeof e === "object" || typeof e === "function")) {
          out.message = String(e.message ?? "Error").slice(0, limits.line);
          out.name = String(e.name || "Error").slice(0, 100);
          if (typeof e.tool === "string") out.tool = e.tool.slice(0, 100);
          const stack = typeof e.stack === "string" ? e.stack : "";
          const m = stack.match(script);
          if (m) { out.line = Number(m[1]) - 1; out.column = Number(m[2]); }
          else if (typeof e.line === "number") { out.line = e.line - 1; if (typeof e.column === "number") out.column = e.column; }
          if (stack) out.stack = stack.replace(/copper:\/\/run\/script\.js:(\d+)/g, (_, l) => "script.js:" + (Number(l) - 1)).slice(0, limits.line);
        } else {
          out.message = String(e).slice(0, limits.line);
          out.name = "Error";
        }
        return stringify(out);
      };
      return { then: Promise.prototype.then, value, describe };
    })();
    """#

    // MARK: the doors

    /// `copper.call(name, args)`: a promise for the tool's answer. On the
    /// queue, called by the script.
    private func callFromScript(_ name: String, _ argsJSON: String) -> JSValue? {
        guard let context else { return nil }
        return JSValue(newPromiseIn: context) { [self] resolve, reject in
            guard let resolve, let reject else { return }
            func refuse(_ text: String) { reject.call(withArguments: [JSValue(newErrorFromMessage: text, in: context) as Any]) }
            let verdict: String? = lock.withLock {
                if finished { return "the run has ended" }
                if !names.contains(name) { return "no tool named \(name) — copper.tools lists them" }
                if outcome.callLog.count + inflight >= maxCalls {
                    outcome.callCapReached = true
                    return "call cap of \(maxCalls) reached (maxCalls)"
                }
                return nil
            }
            if let verdict { return refuse(verdict) }
            // Out of time: the run ends here, and this promise never
            // settles — the script is being ended with it.
            guard Date() < deadline else { return timedOut() }
            // The same JSON a request carries, read the same way, so the
            // handler sees the same Foundation values a direct call gives it.
            guard let data = argsJSON.data(using: .utf8),
                  let arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return refuse("tool arguments must be a JSON object")
            }
            let id: Int = lock.withLock {
                inflight += 1
                nextCall += 1
                return nextCall
            }
            pending[id] = (resolve, reject)
            let began = Date()
            let call = self.call
            let refusal = self.refusal
            Task { @MainActor in
                var answer: [String: Any]
                do {
                    answer = try await call(name, arguments)
                } catch {
                    answer = ["content": [["type": "text", "text": (error as? Tools.Failure)?.text ?? error.localizedDescription]], "isError": true]
                }
                // Stop pressed during or before this call: the handler
                // answered the refusal, and the run ends with it.
                let refused = refusal()
                self.queue.async { [self] in settle(id, name: name, began: began, answer: answer, refused: refused) }
            }
        }
    }

    /// A tool call came back: its row in the log, and the promise kept
    /// or broken. A refusal — the user pressed Stop — ends the run.
    private func settle(_ id: Int, name: String, began: Date, answer: [String: Any], refused: String?) {
        let promise = pending.removeValue(forKey: id)
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
        let over: Bool = lock.withLock {
            inflight -= 1
            guard !finished else { return true }
            var row: [String: Any] = ["tool": name, "ms": ms]
            if isError { row["error"] = String(text.prefix(400)) }
            outcome.callLog.append(row)
            return false
        }
        if over { return }
        if let refused { return stop(refused) }
        guard let promise else { return }
        var reply: [String: Any]
        if isError {
            reply = ["error": text]
        } else {
            reply = ["text": text]
            if let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) { reply["json"] = json }
            if !images.isEmpty { reply["images"] = images }
            if let summary = (answer["_meta"] as? [String: Any])?["summary"] as? String { reply["summary"] = summary }
        }
        arm()
        promise.resolve.call(withArguments: [CodeMode.encode(reply)])
        _ = ended(after: takeException())
    }

    /// `copper.sleep(ms)`, capped, and never past the deadline.
    private func sleepFromScript(_ ms: Double) -> JSValue? {
        guard let context else { return nil }
        return JSValue(newPromiseIn: context) { [self] resolve, _ in
            guard let resolve else { return }
            let wanted = min(max(ms.isFinite ? ms / 1000 : 0, 0), CodeMode.Limits.sleepSeconds)
            let seconds = min(wanted, max(0, deadline.timeIntervalSinceNow))
            queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self, !self.lock.withLock({ self.finished }) else { return }
                self.arm()
                resolve.call(withArguments: [])
                _ = self.ended(after: self.takeException())
            }
        }
    }

    private func log(_ level: String, _ text: String) {
        lock.withLock {
            guard outcome.logs.count < CodeMode.Limits.logLines, logBytes < CodeMode.Limits.logBytes else {
                outcome.logsDropped += 1
                return
            }
            let line = level == "log" ? text : "[\(level)] " + text
            logBytes += line.utf8.count
            outcome.logs.append(line)
        }
    }

    // MARK: ending

    /// The script's promise kept: its value, written by the shim's writer.
    private func done(_ value: JSValue?) {
        guard let context, let helpers, let writer = helpers.forProperty("value"), writer.isObject else { return finish(error: nil) }
        var exception: JSValueRef?
        let args: [JSValueRef?] = [value?.jsValueRef ?? JSValue(undefinedIn: context).jsValueRef]
        arm()
        let written = args.withUnsafeBufferPointer { buffer in
            JSObjectCallAsFunction(context.jsGlobalContextRef, writer.jsValueRef, nil, buffer.count, buffer.baseAddress, &exception)
        }
        if let exception { return failed(JSValue(jsValueRef: exception, in: context)) }
        let text = written.map { JSValue(jsValueRef: $0, in: context) }.flatMap { $0.isString ? $0.toString() : nil } ?? "null"
        lock.withLock { outcome.value = text }
        finish(error: nil)
    }

    /// The script's promise broken, or an error out of the engine: the
    /// error as the shim's writer reports it.
    private func failed(_ error: JSValue?) {
        finish(error: describe(error))
    }

    private func describe(_ error: JSValue?) -> [String: Any] {
        let fallback: [String: Any] = ["message": "Script failed", "name": "Error"]
        guard let error, let context, let helpers, let writer = helpers.forProperty("describe"), writer.isObject else { return fallback }
        var exception: JSValueRef?
        let args: [JSValueRef?] = [error.jsValueRef]
        arm()
        let written = args.withUnsafeBufferPointer { buffer in
            JSObjectCallAsFunction(context.jsGlobalContextRef, writer.jsValueRef, nil, buffer.count, buffer.baseAddress, &exception)
        }
        guard exception == nil, let written, let text = JSValue(jsValueRef: written, in: context).toString(),
              let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return fallback }
        return object
    }

    /// After every entry into the engine (the promise handlers ran as it
    /// returned): an exception that came out of it ends the run, unless the
    /// run is over already. A script the watchdog ended shows up here, not
    /// as a rejection, and is the reason the watchdog had. Answers whether
    /// the run is over.
    @discardableResult
    private func ended(after exception: JSValue?) -> Bool {
        let (over, reason): (Bool, Kill?) = lock.withLock { (finished, killed) }
        if over { return true }
        guard let exception else { return false }
        switch reason {
        case .deadline: finish(error: ["message": "timed out after \(Int(timeout)) s", "name": "Timeout"])
        case .memory: finish(error: ["message": "the script used more than \(CodeMode.Limits.memoryBytes >> 20) MB", "name": "OutOfMemory"])
        case .stopped: break // finish already ran with the refusal
        case nil:
            if Date() >= deadline { finish(error: ["message": "timed out after \(Int(timeout)) s", "name": "Timeout"]) }
            else { failed(exception) }
        }
        return true
    }

    private func takeException() -> JSValue? {
        defer { lastException = nil }
        if let exception = lastException { return exception }
        if let exception = context?.exception { context?.exception = nil; return exception }
        return nil
    }

    /// The deadline passed. From the global queue, or from a call made past it.
    private func timedOut() {
        lock.withLock { if killed == nil { killed = .deadline } }
        finish(error: ["message": "timed out after \(Int(timeout)) s", "name": "Timeout"])
    }

    /// The user pressed Stop (Drive.refuse, through CodeMode.stop), or a
    /// call came back refused. From any thread.
    func stop(_ text: String) {
        lock.withLock { if killed == nil { killed = .stopped } }
        finish(error: ["message": text, "name": "Stopped"])
    }

    /// The end, from any thread, once. The answer is written and handed
    /// back at once; the engine is told to stop at its next check, so a
    /// script still going — in a loop, in a `catch`, in a promise it left
    /// dangling — ends within the poll, and nothing it starts after this
    /// goes anywhere (callFromScript refuses once `finished`). The context
    /// goes when the queue is free; a queue that is held forever leaks one
    /// context, and nothing else.
    private func finish(error: [String: Any]?) {
        let handoff: (CodeMode.Outcome, CheckedContinuation<CodeMode.Outcome, Never>?)? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            if let error, outcome.error == nil { outcome.error = error }
            outcome.abandoned = inflight
            let waiter = self.continuation
            self.continuation = nil
            return (outcome, waiter)
        }
        guard let handoff else { return }
        let (out, waiter) = handoff
        if let group, let setLimit = CodeModeRunner.setLimit { setLimit(group, 0.001, CodeModeRunner.shouldTerminate, Unmanaged.passUnretained(self).toOpaque()) }
        waiter?.resume(returning: out)
        queue.async { [self] in
            pending = [:]
            helpers = nil
            lastException = nil
            context?.exceptionHandler = nil
            if let group, let setLimit = CodeModeRunner.setLimit { setLimit(group, 0.001, nil, nil) }
            context = nil
            group = nil
            if retained { retained = false; Unmanaged.passUnretained(self).release() }
        }
    }
}
