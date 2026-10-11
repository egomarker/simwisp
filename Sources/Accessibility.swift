import Foundation
import Darwin

// TalkBack's diagnostic logs are a last-observed focus, not a UI-tree API.
// Pure bounded parser; no polling, process, device commands or retained history.
final class TalkBackParser {
    static let lineLimit = 65_536
    private static let tag = try! NSRegularExpression(pattern: #"\b[VDIWEF]/talkback(?=[:\s])"#, options: .caseInsensitive)
    private static let event = try! NSRegularExpression(pattern: #"eventId=type:EVENT_TYPE_ACCESSIBILITY\s+subtype:TYPE_VIEW_ACCESSIBILITY_FOCUSED\s+displayId:(\d+)\s+time[:=](\d+)"#)
    private static let fields = try! NSRegularExpression(pattern: #"(?:^|;\s+)([A-Za-z][A-Za-z0-9]*):\s*(.*?)(?=;\s+[A-Za-z][A-Za-z0-9]*:\s|;\s*\[ACTION_|$)"#)
    private static let rectangle = try! NSRegularExpression(pattern: #"^Rect\((-?\d+),\s*(-?\d+)\s*-\s*(-?\d+),\s*(-?\d+)\)$"#)
    private static let speech = try! NSRegularExpression(pattern: #"\baction=SPEAK\s+text="((?:\\.|[^"\\])*)""#)
    private static let tts = try! NSRegularExpression(pattern: #"\bttsOutput=\s*(.*?)\s+queueMode="#)
    private static let role = try! NSRegularExpression(pattern: #"\brole=(ROLE_[A-Z0-9_]+)"#)
    private static let actions = try! NSRegularExpression(pattern: #";\s*\[(ACTION_[^\]]*)\]"#)
    private let clock: () -> Double
    private var pending: [String: Any]?
    private var pendingID: String?
    private var pendingAt = 0.0
    private var sequence = 0
    init(clock: @escaping () -> Double = monotonic) { self.clock = clock }
    private static func matches(_ re: NSRegularExpression, _ s: String) -> [String]? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" }
    }
    private static func eventID(_ s: String) -> String? { matches(event, s).map { $0[1] + ":" + $0[2] } }
    static func bounds(_ s: String?) -> [String: Int]? {
        guard let s, let m = matches(rectangle, s), let x1 = Int(m[1]), let y1 = Int(m[2]), let x2 = Int(m[3]), let y2 = Int(m[4]),
              [x1,y1,x2,y2].allSatisfy({ abs(Double($0)) <= 1_000_000 }), x2 >= x1, y2 >= y1 else { return nil }
        return ["left": x1, "top": y1, "right": x2, "bottom": y2, "width": x2 - x1, "height": y2 - y1]
    }
    func reset() { pending = nil; pendingID = nil; pendingAt = 0 }
    func consume(_ line: String) -> [String: Any]? {
        guard line.utf8.count <= Self.lineLimit, line.range(of: "talkback", options: .caseInsensitive) != nil, Self.matches(Self.tag, line) != nil else { return nil }
        if line.contains("interpretation=AccessibilityFocused{"), let source = line.range(of: "eventSourceNode=") {
            let raw = String(line[source.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            reset()
            guard raw != "null" else { return nil }
            var fields: [String: String] = [:]
            for m in Self.fields.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)).prefix(48) {
                if let k = Range(m.range(at: 1), in: raw), let v = Range(m.range(at: 2), in: raw) { fields[String(raw[k])] = String(raw[v].prefix(2048)) }
            }
            guard !fields.isEmpty else { return nil }
            let password = fields["password"] == "true"
            func value(_ key: String) -> Any { guard let s = fields[key], !s.isEmpty, s != "null" else { return NSNull() }; return s }
            let flags = ["selected", "checked", "checkable", "enabled", "clickable", "longClickable", "focusable", "focused", "scrollable", "visible", "importantForAccessibility", "password"]
            let properties = Dictionary(uniqueKeysWithValues: flags.compactMap { key in fields[key].map { (key, String($0.prefix(32))) } })
            sequence += 1; pendingAt = clock(); pendingID = Self.eventID(line)
            let list = Self.matches(Self.actions, raw).map { $0[1].split(separator: ",").prefix(32).map { String($0.trimmingCharacters(in: .whitespaces).prefix(100)) } } ?? []
            pending = ["sequence": sequence, "event_id": pendingID as Any? ?? NSNull(), "observed_at": ISO8601DateFormatter().string(from: Date()),
                       "speech": NSNull(), "speech_source": "none", "password": password,
                       "label": password ? "[Password content hidden]" : (fields["contentDescription"].flatMap { $0 == "null" || $0.isEmpty ? nil : $0 } ?? fields["text"] ?? ""),
                       "text": password ? NSNull() : value("text"), "content_description": password ? NSNull() : value("contentDescription"),
                       "tooltip": password ? NSNull() : value("tooltipText"), "state_description": password ? NSNull() : value("stateDescription"),
                       "package": value("packageName"), "class": value("className"), "resource_id": value("viewIdResName"), "unique_id": value("uniqueId"),
                       "role": NSNull(), "bounds": Self.bounds(fields["boundsInScreen"]) as Any? ?? NSNull(), "properties": properties, "actions": list]
            return pending
        }
        // Enrich only the same fresh event. Never attach another node's speech.
        guard var node = pending, clock() - pendingAt <= 3, let id = pendingID, Self.eventID(line) == id else { return nil }
        if line.contains("TreeNodesDescription"), let m = Self.matches(Self.role, line) { node["role"] = m[1] }
        else if node["password"] as? Bool != true, line.contains("Pipeline("), let m = Self.matches(Self.speech, line) {
            node["speech"] = String(m[1].replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\\"#, with: "\\").prefix(4096)); node["speech_source"] = "speak"
        } else if node["password"] as? Bool != true, node["speech_source"] as? String != "speak", line.contains("TalkBackFeedbackProvider"), let m = Self.matches(Self.tts, line) {
            node["speech"] = String(m[1].prefix(4096)); node["speech_source"] = "composed"
        } else { return nil }
        guard !NSDictionary(dictionary: node).isEqual(to: pending!) else { return nil }
        pending = node; return node
    }
}

// Demand changes are synchronous. The lock gates every read/parse and generation;
// stale readiness callbacks cannot even parse after stop() has returned.
final class AccessibilityReader: @unchecked Sendable {
    private let lock = NSLock()
    private let worker: DispatchQueue
    private let lifecycle: DispatchGroup
    private let executable: String
    private let arguments: [String]
    private let update: (UInt64, String, [String: Any]?) -> Void
    private let callbackQueue: DispatchQueue
    private var updateScheduled = false
    private var pendingUpdate: (UInt64, String, [String: Any]?)?
    private var enabled = false
    private var generation: UInt64 = 0
    private var process: Process?
    private var starts = 0, stops = 0, lines: UInt64 = 0, bytes: UInt64 = 0
    // Worker owns sources/buffers; all access is additionally gated by lock.
    private var outputSource: DispatchSourceRead?, errorSource: DispatchSourceRead?
    private var outputPipe: Pipe?, errorPipe: Pipe?
    private var partial = Data(), droppingLine = false
    private let parser = TalkBackParser()
    init(executable: String, serial: String, lifecycle: DispatchGroup = DispatchGroup(), arguments: [String]? = nil, callbackQueue: DispatchQueue = .global(qos: .utility),
         update: @escaping (UInt64, String, [String: Any]?) -> Void) {
        self.executable = executable; self.lifecycle = lifecycle; self.update = update; self.callbackQueue = callbackQueue
        // -T 1 follows fresh events without clearing logs or replaying the buffer.
        self.arguments = arguments ?? ["-s", serial, "logcat", "-v", "time", "-T", "1"]
        worker = DispatchQueue(label: "Simwisp.accessibility.\(serial)", qos: .utility)
    }
    var diagnostics: [String: Any] { lock.withLock { ["running": process?.isRunning == true, "pid": process?.processIdentifier ?? 0, "requested": enabled, "starts": starts, "stops": stops, "lines": lines, "bytes": bytes, "buffer_bytes": partial.count] } }
    func isCurrent(_ token: UInt64) -> Bool { lock.withLock { enabled && token == generation } }
    func isGeneration(_ token: UInt64) -> Bool { lock.withLock { token == generation } }
    // One latest-update slot bounds delivery even if the network queue is busy.
    // Caller holds lock; delivery runs only on the supplied callback queue.
    private func emit(_ token: UInt64, _ state: String, _ node: [String: Any]?) {
        pendingUpdate = (token, state, node)
        guard !updateScheduled else { return }; updateScheduled = true
        callbackQueue.async {
            self.lock.lock(); let item = self.pendingUpdate; self.pendingUpdate = nil; self.updateScheduled = false
            let valid = item.map { $0.0 == self.generation && (self.enabled || $0.1 == "error") } ?? false
            self.lock.unlock()
            if valid, let item { self.update(item.0, item.1, item.2) }
        }
    }
    func start() {
        lock.lock(); guard !enabled else { lock.unlock(); return }; enabled = true; generation &+= 1; let token = generation; lock.unlock()
        worker.async { self.launch(token) }
    }
    func stop() {
        lock.lock(); guard enabled || process != nil else { lock.unlock(); return }
        enabled = false; generation &+= 1; stops += 1; pendingUpdate = nil; let child = process
        if child?.isRunning == true { child?.terminate() }
        lock.unlock()
        worker.async {
            self.lock.withLock { self.cancelIO() }
            if let child {
                // Bounded one-shot escalation, never an idle/process polling loop.
                self.worker.asyncAfter(deadline: .now() + 0.25) { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
            }
        }
    }
    private func launch(_ token: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard enabled, generation == token, process == nil else { return }
        let child = Process(), output = Pipe(), error = Pipe()
        child.executableURL = URL(fileURLWithPath: executable); child.arguments = arguments
        child.standardInput = FileHandle.nullDevice; child.standardOutput = output; child.standardError = error
        process = child; outputPipe = output; errorPipe = error
        lifecycle.enter()
        child.terminationHandler = { [self] child in
            self.worker.async {
                self.lock.lock()
                if self.process === child {
                    self.cancelIO(); self.process = nil; child.terminationHandler = nil
                    let wanted = self.enabled, current = self.generation
                    if wanted && current == token { self.enabled = false; self.emit(token, "error", ["message": "TalkBack logcat ended. Check the Android device and reopen the pane."]) }
                    else if wanted { self.worker.async { self.launch(current) } }
                }
                self.lock.unlock(); self.lifecycle.leave()
            }
        }
        do {
            try child.run(); starts += 1
            // Parent must not hold pipe write ends, or EOF never arrives.
            try? output.fileHandleForWriting.close(); try? error.fileHandleForWriting.close()
            outputSource = makeSource(output.fileHandleForReading, token: token, stderr: false)
            errorSource = makeSource(error.fileHandleForReading, token: token, stderr: true)
            emit(token, "listening", nil)
        } catch {
            child.terminationHandler = nil; process = nil; enabled = false; cancelIO(); lifecycle.leave()
            emit(token, "error", ["message": "Cannot start ADB logcat. Check the Android SDK path and reopen the pane."])
        }
    }
    private func makeSource(_ handle: FileHandle, token: UInt64, stderr: Bool) -> DispatchSourceRead {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: worker)
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.enabled, token == self.generation else { return }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            // One bounded read per readiness event, with no drain/poll loop.
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { if count == 0 { source?.cancel() }; return }
            if stderr { return } // Drain without retaining/exposing raw logcat diagnostics.
            self.bytes &+= UInt64(count)
            for byte in buffer.prefix(count) {
                if byte == 10 {
                    if !self.droppingLine {
                        self.lines &+= 1
                        let line = String(decoding: self.partial, as: UTF8.self)
                        if let node = self.parser.consume(line) { self.emit(token, "event", node) }
                    }
                    self.partial.removeAll(keepingCapacity: true); self.droppingLine = false
                } else if !self.droppingLine {
                    if self.partial.count < TalkBackParser.lineLimit { self.partial.append(byte) }
                    else { self.partial.removeAll(keepingCapacity: true); self.droppingLine = true }
                }
            }
        }
        source.setCancelHandler { try? handle.close() }; source.resume(); return source
    }
    private func cancelIO() {
        outputSource?.cancel(); outputSource = nil; errorSource?.cancel(); errorSource = nil
        if outputPipe != nil { try? outputPipe?.fileHandleForWriting.close() }
        if errorPipe != nil { try? errorPipe?.fileHandleForWriting.close() }
        outputPipe = nil; errorPipe = nil; partial.removeAll(); droppingLine = false; parser.reset()
    }
    deinit { if process?.isRunning == true { process?.terminate() } }
}

// Network queue owns subscription and sending. Shared by real StreamSession and
// headless fixtures, so tests exercise the same hard demand gate and backpressure.
final class AccessibilitySession {
    private let serial: String, platform: String
    private let executable: String?
    private let arguments: [String]?
    private let queue: DispatchQueue
    private let lifecycle: DispatchGroup
    private let send: ([String: Any], @escaping () -> Void) -> Void
    private var reader: AccessibilityReader?
    private var paneOpen = false, streamActive = false, closed = false
    private var state = "off", sending = false
    private var pending: [String: Any]?
    private var epoch: UInt64 = 0
    private var lastSent: Double?
    private var subscription = 0
    var requested: Bool { paneOpen }
    private var active: Bool { paneOpen && streamActive && !closed && platform == "android" }
    init(serial: String, platform: String, executable: String?, queue: DispatchQueue, lifecycle: DispatchGroup,
         arguments: [String]? = nil, send: @escaping ([String: Any], @escaping () -> Void) -> Void) {
        self.serial = serial; self.platform = platform; self.executable = executable; self.queue = queue; self.lifecycle = lifecycle; self.arguments = arguments; self.send = send
    }
    var snapshot: [String: Any] {
        ["requested": paneOpen, "state": state, "sending": active && lastSent.map { monotonic() - $0 < 5 } == true,
         "last_event_age": lastSent.map { monotonic() - $0 } as Any? ?? NSNull(), "reader": reader?.diagnostics ?? [:]]
    }
    func update(paneOpen: Bool? = nil, streamActive: Bool? = nil, subscription: Int? = nil) {
        if let subscription { self.subscription = max(0, min(1_000_000_000, subscription)) }
        if let paneOpen {
            self.paneOpen = paneOpen && platform == "android"
            if paneOpen && platform != "android" { send(["type": "accessibility_status", "subscription": self.subscription, "state": "error", "message": "Accessibility inspection is Android-only"], {}) }
        }
        if let streamActive { self.streamActive = streamActive }
        reconcile()
    }
    private func reconcile() {
        guard active else {
            if state != "off" {
                epoch &+= 1; reader?.stop(); pending = nil; sending = false; lastSent = nil; state = "off"
                if !closed { send(["type": "accessibility_status", "subscription": subscription, "state": "off", "message": paneOpen ? "Paused — waiting for an active Android stream" : ""], {}) }
            }
            return
        }
        guard state == "off" else { return }
        guard let executable else { state = "error"; send(["type": "accessibility_status", "subscription": subscription, "state": "error", "message": "Android SDK ADB not found"], {}); return }
        if reader == nil {
            reader = AccessibilityReader(executable: executable, serial: serial, lifecycle: lifecycle, arguments: arguments, callbackQueue: queue) { [weak self] token, state, node in
                guard let self, self.active, self.reader?.isGeneration(token) == true else { return }
                if state != "error", self.reader?.isCurrent(token) != true { return }
                if state == "event", let node {
                    self.state = "listening"; self.pending = ["type": "accessibility_event", "subscription": self.subscription, "node": node]; self.flush()
                } else {
                    self.state = state
                    self.send(["type": "accessibility_status", "subscription": self.subscription, "state": state, "message": node?["message"] ?? "TalkBack must be enabled with verbose diagnostic logging. Navigate to hear a focus event."], {})
                }
            }
        }
        state = "starting"; epoch &+= 1; reader?.start()
    }
    private func flush() {
        guard active, !sending, let message = pending else { return }
        pending = nil; sending = true; let current = epoch
        send(message) { [weak self] in
            guard let self, self.active, self.epoch == current else { return }
            self.lastSent = monotonic(); self.sending = false; self.flush()
        }
    }
    func stop() { closed = true; paneOpen = false; streamActive = false; reconcile() }
    deinit { reader?.stop() }
}
