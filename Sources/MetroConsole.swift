import Foundation

// Read-only Metro metadata/CDP. This queue owns every registry/parser/buffer;
// video, HID, PTY and socket-write queues never perform Metro work.
struct MetroTarget {
    let key: String, id: String, appID: String, title: String, deviceName: String, platform: String, runtime: String
    let deviceID: String, url: URL, endpoint: String
    var candidates: [String] = []
    var confirmation = false
    var identity: String { id + "\n" + appID + "\n" + endpoint }
    var json: [String: Any] {
        ["key": key, "target_id": id, "app_id": appID, "title": title, "device_name": deviceName, "platform": platform, "runtime": runtime,
         "endpoint": endpoint, "candidate_device_ids": candidates, "requires_confirmation": confirmation]
    }
}
enum MetroCodec {
    static func text(_ value: Any?, limit: Int = 512) -> String {
        guard let s = value as? String else { return "" }
        let clean = s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }.map(String.init).joined()
        if clean.utf8.count <= limit { return clean }
        let marker = "… [truncated]", budget = max(0, limit - marker.utf8.count)
        var prefix = "", used = 0
        for scalar in clean.unicodeScalars { let part = String(scalar); guard used + part.utf8.count <= budget else { break }; prefix += part; used += part.utf8.count }
        return prefix + String(marker.prefix(limit < marker.utf8.count ? max(0, limit / 3) : marker.count))
    }
    static func metadata(_ value: Any?, limit: Int = 512) -> String { text(value, limit: limit).unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined() }
    static func norm(_ s: String) -> String { s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
    static func platform(_ s: String) -> String {
        let s = norm(s); return ["ios", "iphone", "ipad"].contains(s) ? "ios" : s == "android" ? "android" : ""
    }
    static func name(_ s: String) -> String {
        // Only strip a trailing explicit OS decoration, not partial model names.
        let s = norm(s).replacingOccurrences(of: "_", with: " ")
        guard let r = s.range(of: #"\s*\((ios|android)[^)]*\)$"#, options: .regularExpression) else { return s }
        return String(s[..<r.lowerBound])
    }
    static func socketURL(_ raw: String, endpoint: URL) -> URL? {
        guard raw.utf8.count <= 4096, var c = URLComponents(string: raw), let e = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              c.scheme == "ws", ["localhost", "127.0.0.1", "::1", "[::1]"].contains(c.host ?? ""),
              (c.port ?? 80) == (e.port ?? 80), c.user == nil, c.password == nil, c.fragment == nil,
              c.path.hasPrefix("/inspector/"), !c.path.contains("\\") else { return nil }
        // Pin numeric loopback, disable redirects/proxies. No DNS rebinding.
        c.host = "127.0.0.1"; return c.url
    }
    static func targets(_ data: Data, endpoint: URL, previous: [String: MetroTarget], devices: [Device]) throws -> [String: MetroTarget] {
        guard data.count <= 1_048_576, let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count <= 64 else { throw WispError("Invalid Metro target inventory") }
        var result: [String: MetroTarget] = [:], seen = Set<String>()
        for row in rows {
            let rn = row["reactNative"] as? [String: Any] ?? [:]
            let id = metadata(row["id"], limit: 256), rawURL = row["webSocketDebuggerUrl"] as? String ?? ""
            guard !id.isEmpty, !rawURL.isEmpty, seen.insert(id).inserted else { throw WispError("Invalid Metro target inventory") }
            guard let url = socketURL(rawURL, endpoint: endpoint) else { continue } // unsafe targets are never registered
            var app = metadata(row["appId"] ?? rn["appId"] ?? row["applicationId"])
            if app.isEmpty, let desc = row["description"] as? String, desc.range(of: #"^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+)+$"#, options: .regularExpression) != nil { app = metadata(desc) }
            let endpointID = "127.0.0.1:" + String(endpoint.port ?? 8081)
            let identity = id + "\n" + app + "\n" + endpointID
            let key = previous.values.first(where: { $0.identity == identity })?.key ?? UUID().uuidString
            var t = MetroTarget(key: key, id: id, appID: app, title: metadata(row["title"]), deviceName: metadata(row["deviceName"] ?? rn["deviceName"]),
                                platform: platform(metadata(row["platform"] ?? rn["platform"])), runtime: metadata(row["runtime"] ?? rn["runtime"] ?? "Hermes"),
                                deviceID: metadata(row["deviceId"] ?? row["deviceIdentifier"] ?? row["udid"] ?? row["serial"] ?? rn["deviceId"]), url: url, endpoint: endpointID)
            let compatible = devices.filter { t.platform.isEmpty || t.platform == $0.platform }
            if !t.deviceID.isEmpty { t.candidates = compatible.filter { $0.id == t.deviceID }.map(\.id) }
            else if !t.deviceName.isEmpty {
                t.candidates = compatible.filter { device in
                    name(device.name) == name(t.deviceName) ||
                    (device.platform == "android" && device.metroName.map { name($0) == name(t.deviceName) } == true)
                }.map(\.id)
                // An unreadable peer's model is also inconclusive; a known
                // alias must not masquerade as unique when that peer may share it.
                let aliasMatch = compatible.contains { $0.platform == "android" && $0.metroName.map { name($0) == name(t.deviceName) } == true }
                t.confirmation = t.candidates.count > 1 || (aliasMatch && compatible.contains { $0.platform == "android" && $0.metroName == nil })
            } else { t.candidates = compatible.map(\.id); t.confirmation = true }
            result[key] = t
        }
        // Unique compatible unknown target/device is the only safe fallback.
        for (key, var t) in result where t.deviceID.isEmpty && t.deviceName.isEmpty {
            let others = result.values.filter { $0.platform.isEmpty || t.platform.isEmpty || $0.platform == t.platform }
            if t.candidates.count == 1 && others.count == 1 { t.confirmation = false }
            result[key] = t
        }
        return result
    }
    static func location(_ value: [String: Any]) -> [String: Any] {
        var v: [String: Any] = ["url": text(value["url"], limit: 512)]
        for k in ["lineNumber", "columnNumber"] { if let n = value[k] as? Int, (0...10_000_000).contains(n) { v[k == "lineNumber" ? "line" : "column"] = n } }
        return v
    }
    static func argument(_ value: [String: Any]) -> [String: Any] {
        let kind = text(value["type"], limit: 32)
        var output: [String: Any] = ["type": kind]
        if let id = MetroObjectCodec.identifier(value["objectId"]) { output["objectId"] = id }
        for key in ["subtype", "className", "description"] { if value[key] != nil { output[key] = text(value[key], limit: key == "description" ? 4096 : 128) } }
        if let v = value["value"] as? String { output["value"] = text(v, limit: 1024) }
        else if let v = value["value"] as? NSNumber { output["value"] = v.doubleValue.isFinite ? v : NSNull() }
        else if value["value"] is NSNull { output["value"] = NSNull() }
        else { output["value"] = text(value["unserializableValue"] ?? value["description"], limit: 1024) }
        if let preview = value["preview"] as? [String: Any], let properties = preview["properties"] as? [[String: Any]] {
            output["preview"] = properties.prefix(20).map { ["name": text($0["name"], limit: 80), "value": text($0["value"] ?? $0["type"], limit: 80), "type": text($0["type"], limit: 32)] }
            output["preview_overflow"] = preview["overflow"] as? Bool == true || properties.count > 20
        }
        return output
    }
    static func entry(_ message: [String: Any], sequence: UInt64) -> [String: Any]? {
        guard let method = message["method"] as? String, let p = message["params"] as? [String: Any] else { return nil }
        let exception: [String: Any], args: [[String: Any]], level: String
        if method == "Runtime.consoleAPICalled" {
            let raw = p["type"] as? String ?? "log"
            level = ["warn", "warning"].contains(raw) ? "warn" : ["error", "assert"].contains(raw) ? "error" : raw == "info" ? "info" : "log"
            exception = p; args = (p["args"] as? [[String: Any]] ?? []).prefix(50).map(argument)
        } else if method == "Runtime.exceptionThrown", let details = p["exceptionDetails"] as? [String: Any] {
            exception = details; level = "error"
            let object = details["exception"] as? [String: Any] ?? [:]
            args = MetroObjectCodec.identifier(object["objectId"]) != nil ? [argument(object)] : [["type": "string", "value": text(object["description"] ?? details["text"] ?? "Exception", limit: 32768)]]
        } else { return nil }
        let descriptions = args.map { arg -> String in
            let v = arg["value"] ?? ""; let plain = v is NSNull ? "null" : String(describing: v)
            let properties = (arg["preview"] as? [[String: String]] ?? []).map { ($0["name"] ?? "") + ": " + ($0["value"] ?? "") }.joined(separator: ", ")
            return properties.isEmpty ? plain : plain + " {" + properties + "}"
        }
        let stack = (exception["stackTrace"] as? [String: Any])?["callFrames"] as? [[String: Any]] ?? []
        let stamp = p["timestamp"] as? Double
        var output: [String: Any] = ["sequence": sequence, "timestamp_ms": stamp?.isFinite == true ? stamp! : Date().timeIntervalSince1970 * 1000,
                                  "level": level, "text": text(descriptions.joined(separator: " "), limit: 32768), "arguments": args,
                                  "stack": Array(stack.prefix(100)).map { frame -> [String: Any] in var v = location(frame); v["function"] = text(frame["functionName"], limit: 256); return v }]
        if let frame = stack.first { output["source"] = location(frame) } else if exception["url"] != nil { output["source"] = location(exception) }
        return output
    }
}

// Per-subscriber pending ring. One send/ACK is outstanding, never one queued
// socket write per entry. Slow readers evict only their own oldest pending data.
final class MetroOutput {
    private(set) var entries: [([String: Any], Int)] = []
    private(set) var bytes = 0, dropped: UInt64 = 0
    func append(_ entry: [String: Any]) {
        let size = jsonData(entry).count
        guard size <= 1_048_576 else { dropped &+= 1; return }
        entries.append((entry, size)); bytes += size
        while entries.count > 512 || bytes > 1_048_576 { bytes -= entries.removeFirst().1; dropped &+= 1 }
    }
    func take() -> [String: Any]? { guard !entries.isEmpty else { return nil }; let first = entries.removeFirst(); bytes -= first.1; return first.0 }
}

final class MetroConsoleManager: NSObject, URLSessionDataDelegate, URLSessionWebSocketDelegate {
    private let queue = DispatchQueue(label: "Simwisp.metro-console", qos: .utility)
    private let network: DispatchQueue, endpoint: URL
    private var session: URLSession!, inspectorSession: URLSession!
    private var targets: [String: MetroTarget] = [:], generation = 0, discoveredAt = 0.0
    private var discovery: URLSessionDataTask?, responseBody = Data(), discoveryOK = false, overflow = false
    private var waiters: [(Result<[String: Any], Error>) -> Void] = [], devices: [Device] = []
    private var upstreams: [String: Upstream] = [:], subscribers: [UUID: Subscriber] = [:], stopping = false
    // All mutable fields are accessed exclusively on queue, including Task callbacks.
    private final class Upstream: @unchecked Sendable {
        let key: String, url: URL
        let references = MetroObjectReferences()
        var propertyCalls: [Int: PropertyCall] = [:], nextCall = 2
        var task: URLSessionWebSocketTask?, token = UUID(), retry: DispatchWorkItem?, enableDeadline: DispatchWorkItem?, retries = 0, sequence: UInt64 = 0, attached = false
        init(_ t: MetroTarget) { key = t.key; url = t.url }
    }
    private struct PropertyCall { let client: UUID, request: String, token: UUID }
    private final class Subscriber {
        let client: ClientConnection, output = MetroOutput(), key: String, device: String
        var propertyRequest: String?, propertyDeadline: DispatchSourceTimer?, handles = Set<String>(), handleOrder: [String] = []
        var sequence: UInt64?, sentDropped: UInt64 = 0, deadline: DispatchSourceTimer?, sending = false
        init(_ client: ClientConnection, target: String, device: String) { self.client = client; key = target; self.device = device }
    }
    init(network: DispatchQueue, endpoint: URL = URL(string: "http://127.0.0.1:8081/json/list")!) {
        self.network = network; self.endpoint = endpoint; super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 5
        config.httpMaximumConnectionsPerHost = 16 // eight CDP targets plus bounded metadata requests
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil; config.connectionProxyDictionary = [:]
        let callbacks = OperationQueue(); callbacks.maxConcurrentOperationCount = 1; callbacks.underlyingQueue = queue
        session = URLSession(configuration: config, delegate: self, delegateQueue: callbacks)
        // A five-second metadata resource deadline must not terminate a live
        // inspector. Keep its default long-lived limits; bound opening/enable
        // separately on our queue instead of inheriting discovery timeouts.
        let inspector = config.copy() as! URLSessionConfiguration
        inspector.timeoutIntervalForRequest = 60; inspector.timeoutIntervalForResource = 7 * 24 * 60 * 60
        inspector.httpMaximumConnectionsPerHost = 8
        inspectorSession = URLSession(configuration: inspector, delegate: self, delegateQueue: callbacks)
    }
    func discover(devices: [Device], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        queue.async {
            guard !self.stopping, self.waiters.count < 64 else { completion(.failure(WispError("Metro discovery unavailable"))); return }
            self.devices = devices; self.waiters.append(completion)
            guard self.discovery == nil else { return }
            self.responseBody = Data(); self.discoveryOK = false; self.overflow = false
            var request = URLRequest(url: self.endpoint); request.timeoutInterval = 5; request.cachePolicy = .reloadIgnoringLocalCacheData
            self.discovery = self.session.dataTask(with: request); self.discovery?.resume()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard dataTask === discovery else { completionHandler(.cancel); return }
        discoveryOK = (response as? HTTPURLResponse)?.statusCode == 200 && response.expectedContentLength <= 1_048_576
        completionHandler(discoveryOK ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === discovery else { return }
        if responseBody.count + data.count > 1_048_576 { overflow = true; dataTask.cancel(); responseBody.removeAll(); return }
        responseBody.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if task === discovery {
            let result: Result<[String: Any], Error>
            do {
                guard error == nil, discoveryOK, !overflow, !stopping else { throw WispError("Metro discovery unavailable") }
                let fresh = try MetroCodec.targets(responseBody, endpoint: endpoint, previous: targets, devices: devices)
                targets = fresh; generation += 1; discoveredAt = Date().timeIntervalSince1970 * 1000
                for key in Array(upstreams.keys) where fresh[key] == nil || fresh[key]?.url != upstreams[key]?.url {
                    terminate(key)
                    for s in subscribers.values where s.key == key { status(s, "reconnecting", "Target unavailable; waiting for shared discovery") }
                }
                result = .success(["generation": generation, "discovered_at_ms": discoveredAt, "targets": fresh.values.sorted { $0.key < $1.key }.map(\.json)])
            } catch { result = .failure(WispError("Metro discovery unavailable")) }
            discovery = nil; responseBody = Data(); let callbacks = waiters; waiters.removeAll(); callbacks.forEach { $0(result) }
        } else if let u = upstreams.values.first(where: { $0.task === task }) { failed(u) }
    }
    func install(_ client: ClientConnection, allowedDevice: @escaping (String) -> Bool) {
        // Network-queue message admission is bounded before dispatch to Metro.
        var pending = 0
        client.startTerminalKeepalive()
        client.onBinary = { [weak client] _ in client?.close() }
        client.onMessage = { [weak self, weak client] text in
            guard let self, let client else { return }
            guard pending < 16, text.utf8.count <= 4096 else { client.close(); return }; pending += 1
            let message = dictionary(Data(text.utf8))
            if message["type"] as? String == "attach", !allowedDevice(message["device_id"] as? String ?? "") { client.sendJSON(["type": "console_error", "code": "target_unavailable", "message": "Stream is not active", "retryable": true]); client.closeAfterSending(); return }
            self.queue.async {
                // Reopen admission before pumping a reply: a fast peer can ACK
                // that reply before a trailing reset reaches the network queue.
                // A bounded burst allows coalesced entry/property ACKs from one read;
                // still never an unbounded dispatch per browser message.
                self.network.async { pending -= 1 }
                self.message(message, client: client)
            }
        }
        let identifier = client.id
        client.onClose = { [weak self] in self?.queue.async { self?.remove(identifier) } }
        network.asyncAfter(deadline: .now() + 8) { [weak client] in
            guard let client, !client.isClosed else { return }
            self.queue.async { if self.subscribers[client.id] == nil { self.network.async { client.close() } } }
        }
    }
    private func message(_ m: [String: Any], client: ClientConnection) {
        guard !stopping else { network.async { client.close() }; return }
        let kind = m["type"] as? String
        if kind == "get_properties", let s = subscribers[client.id], Set(m.keys) == Set(["type", "request_id", "object_ref"]),
           let request = m["request_id"] as? String, !request.isEmpty, request.utf8.count <= 64,
           let ref = m["object_ref"] as? String, ref.utf8.count <= 64, s.propertyRequest == nil {
            s.propertyRequest = request
            if s.propertyDeadline == nil {
                let deadline = DispatchSource.makeTimerSource(queue: queue)
                deadline.setEventHandler { [weak self, weak s] in
                    guard let self, let s, let request = s.propertyRequest else { return }
                    if let u = self.upstreams[s.key], let call = u.propertyCalls.first(where: { $0.value.client == s.client.id && $0.value.request == request })?.key {
                        self.propertyFailed(u, call: call, error: "Object inspection timed out")
                    } else { self.remove(s.client.id); self.network.async { s.client.close() } }
                }
                s.propertyDeadline = deadline; deadline.schedule(deadline: .now() + 5); deadline.resume()
            } else { s.propertyDeadline?.schedule(deadline: .now() + 5) }
            guard let u = upstreams[s.key], u.attached, let task = u.task, s.handles.contains(ref), let id = u.references.resolve(ref) else {
                propertyReply(s, request: request, error: "Object reference is no longer available"); return
            }
            guard u.propertyCalls.count < 64 else { propertyReply(s, request: request, error: "Object inspection is busy; expand again to retry"); return }
            let call = u.nextCall; u.nextCall += 1; let token = u.token
            u.propertyCalls[call] = PropertyCall(client: client.id, request: request, token: token)
            let payload = String(decoding: jsonData(["id": call, "method": "Runtime.getProperties", "params": ["objectId": id, "ownProperties": true, "accessorPropertiesOnly": false, "generatePreview": true]]), as: UTF8.self)
            Task { [weak self, weak u] in
                do { try await task.send(.string(payload)) }
                catch { self?.queue.async { if let u, u.token == token { self?.propertyFailed(u, call: call, error: "Object inspection failed") } } }
            }
            return
        }
        if kind == "properties_ack", let s = subscribers[client.id], Set(m.keys) == Set(["type", "request_id"]),
           let request = m["request_id"] as? String, s.propertyRequest == request {
            s.propertyRequest = nil; s.propertyDeadline?.schedule(deadline: .distantFuture)
            network.async { client.sendJSON(["type": "properties_ready", "request_id": request]) }; return
        }
        if kind == "entry_ack", let s = subscribers[client.id], Set(m.keys).isSubset(of: ["type", "sequence"]), let n = m["sequence"] as? UInt64, n == s.sequence {
            s.sequence = nil; s.deadline?.schedule(deadline: .distantFuture); pump(s); return
        }
        if kind == "close", m.count == 1 { remove(client.id); network.async { client.close() }; return }
        guard kind == "attach", Set(m.keys).isSubset(of: ["type", "device_id", "target_key", "generation", "confirmed"]), subscribers[client.id] == nil,
              let key = m["target_key"] as? String, let id = m["device_id"] as? String, m["generation"] as? Int == generation,
              let target = targets[key], target.candidates.contains(id), !target.confirmation || m["confirmed"] as? Bool == true,
              devices.contains(where: { $0.id == id }), upstreams[key] != nil || upstreams.count < 8, subscribers.count < 64 else {
            network.async { client.sendJSON(["type": "console_error", "code": "target_unavailable", "message": "Target unavailable, ambiguous, or console limit reached", "retryable": true]); client.closeAfterSending() }; return
        }
        let s = Subscriber(client, target: key, device: id); subscribers[client.id] = s
        if let u = upstreams[key] { status(s, u.attached ? "attached" : "connecting") }
        else { let u = Upstream(target); upstreams[key] = u; status(s, "connecting"); connect(u) }
    }
    private func grant(_ s: Subscriber, _ handles: [String]) {
        for handle in handles where s.handles.insert(handle).inserted {
            s.handleOrder.append(handle)
            if s.handleOrder.count > MetroObjectReferences.limit { s.handles.remove(s.handleOrder.removeFirst()) }
        }
    }
    private func propertyReply(_ s: Subscriber, request: String, result: [String: Any] = [:], error: String = "") {
        guard subscribers[s.client.id] === s, s.propertyRequest == request else { return }
        s.propertyDeadline?.schedule(deadline: .now() + 10)
        grant(s, MetroObjectCodec.handles(result))
        var reply = result; reply["type"] = "properties"; reply["request_id"] = request
        if !error.isEmpty { reply["error"] = error }
        network.async { [weak s] in if let s, !s.client.isClosed { s.client.sendJSON(reply) } }
    }
    private func propertyFailed(_ u: Upstream, call: Int, error: String) {
        guard let pending = u.propertyCalls.removeValue(forKey: call), let s = subscribers[pending.client] else { return }
        propertyReply(s, request: pending.request, error: error)
    }
    private func resetObjects(_ u: Upstream) {
        u.references.clear()
        for call in Array(u.propertyCalls.keys) { propertyFailed(u, call: call, error: "Object reference is no longer available") }
        for s in subscribers.values where s.key == u.key { s.handles.removeAll(); s.handleOrder.removeAll() }
    }
    private func status(_ s: Subscriber, _ state: String, _ message: String = "") {
        network.async { [weak s] in guard let s, !s.client.isClosed else { return }; s.client.sendJSON(["type": "status", "state": state, "message": message]) }
    }
    private func connect(_ u: Upstream) {
        guard !stopping, upstreams[u.key] === u, subscribers.values.contains(where: { $0.key == u.key }) else { return }
        u.retry?.cancel(); u.retry = nil; resetObjects(u); u.token = UUID(); u.attached = false
        let task = inspectorSession.webSocketTask(with: u.url); task.maximumMessageSize = 1_048_576; u.task = task
        let token = u.token
        let deadline = DispatchWorkItem { [weak self, weak u] in if let u, !u.attached, u.token == token { self?.failed(u, message: "Metro connection did not become ready") } }
        u.enableDeadline = deadline; queue.asyncAfter(deadline: .now() + 5, execute: deadline)
        task.resume()
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard let u = upstreams.values.first(where: { $0.task === webSocketTask }) else { webSocketTask.cancel(); return }
        let token = u.token
        u.enableDeadline?.cancel()
        let deadline = DispatchWorkItem { [weak self, weak u] in if let u, !u.attached, u.token == token { self?.failed(u, message: "Runtime did not acknowledge read-only attachment") } }
        u.enableDeadline = deadline; queue.asyncAfter(deadline: .now() + 5, execute: deadline)
        Task { [weak self, weak u] in
            do { try await webSocketTask.send(.string("{\"id\":1,\"method\":\"Runtime.enable\"}")) }
            catch { self?.queue.async { if let u, u.token == token { self?.failed(u) } }; return }
            self?.queue.async { if let u, u.token == token { self?.receive(u, task: webSocketTask, token: token) } }
        }
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { if let u = upstreams.values.first(where: { $0.task === webSocketTask }) { failed(u) } }
    private func receive(_ u: Upstream, task: URLSessionWebSocketTask, token: UUID) {
        Task { [weak self, weak u] in
            do {
                let message = try await task.receive()
                self?.queue.async {
                    guard let self, let u, self.upstreams[u.key] === u, u.token == token, !self.stopping, self.subscribers.values.contains(where: { $0.key == u.key }) else { return }
                    let data: Data
                    switch message { case .string(let s): data = Data(s.utf8); case .data(let d): data = d; @unknown default: return }
                    if data.count <= 1_048_576 {
                        let raw = dictionary(data)
                        if raw["id"] as? Int == 1 {
                            if raw["error"] != nil { self.failed(u, message: "Another debugger or runtime refused attachment"); return }
                            u.enableDeadline?.cancel(); u.enableDeadline = nil; u.attached = true; u.retries = 0
                            for s in self.subscribers.values where s.key == u.key { self.status(s, "attached") }
                        } else if let id = raw["id"] as? Int, let pending = u.propertyCalls.removeValue(forKey: id) {
                            if pending.token == token, let s = self.subscribers[pending.client] {
                                if raw["error"] != nil { self.propertyReply(s, request: pending.request, error: "Object reference is unavailable or inspection is unsupported") }
                                else if let result = raw["result"] as? [String: Any], result["result"] is [[String: Any]] {
                                    self.propertyReply(s, request: pending.request, result: MetroObjectCodec.properties(result, references: u.references))
                                } else { self.propertyReply(s, request: pending.request, error: "Invalid object properties response") }
                            }
                        } else if ["Runtime.executionContextsCleared", "Runtime.executionContextDestroyed"].contains(raw["method"] as? String ?? "") {
                            self.resetObjects(u)
                        } else if var entry = MetroCodec.entry(raw, sequence: u.sequence + 1) {
                            entry["arguments"] = (entry["arguments"] as? [[String: Any]] ?? []).map { u.references.decorate($0) }
                            u.sequence &+= 1
                            for s in self.subscribers.values where s.key == u.key { s.output.append(entry); self.pump(s) }
                        }
                    }
                    self.receive(u, task: task, token: token)
                }
            } catch { self?.queue.async { if let u, u.token == token { self?.failed(u) } } }
        }
    }
    private func failed(_ u: Upstream, message: String = "Runtime disconnected") {
        guard upstreams[u.key] === u, u.retry == nil, !stopping else { return }
        resetObjects(u); u.token = UUID(); u.enableDeadline?.cancel(); u.enableDeadline = nil; u.task?.cancel(); u.task = nil; u.attached = false
        for s in subscribers.values where s.key == u.key { status(s, message == "Runtime disconnected" ? "reconnecting" : "error", message) }
        let work = DispatchWorkItem { [weak self, weak u] in guard let self, let u else { return }; u.retry = nil; self.connect(u) }
        u.retry = work; queue.asyncAfter(deadline: .now() + min(30, pow(2, Double(min(5, u.retries)))), execute: work); u.retries += 1
    }
    private func pump(_ s: Subscriber) {
        guard subscribers[s.client.id] === s, !s.sending, s.sequence == nil, let entry = s.output.take(), let sequence = entry["sequence"] as? UInt64 else { return }
        grant(s, MetroObjectCodec.handles(entry))
        s.sequence = sequence; s.sending = true
        if s.deadline == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.setEventHandler { [weak self, weak s] in guard let self, let s, s.sequence != nil else { return }; self.remove(s.client.id); self.network.async { s.client.close() } }
            s.deadline = t; t.schedule(deadline: .now() + 30); t.resume()
        } else { s.deadline?.schedule(deadline: .now() + 30) }
        let dropped = s.output.dropped; s.sentDropped = dropped
        network.async { [weak self, weak s] in
            guard let self, let s, !s.client.isClosed else { return }
            s.client.sendJSON(["type": "entry", "entry": entry, "dropped": dropped]) { [weak self, weak s] in
                self?.queue.async { guard let s else { return }; s.sending = false; self?.pump(s) }
            }
        }
    }
    private func terminate(_ key: String) {
        guard let u = upstreams.removeValue(forKey: key) else { return }; resetObjects(u); u.token = UUID(); u.enableDeadline?.cancel(); u.enableDeadline = nil; u.retry?.cancel(); u.retry = nil; u.task?.cancel(); u.task = nil
        // Retire any closing/late-opening transports from the old session once
        // no upstream remains. This cannot disturb another attached target.
        if upstreams.isEmpty, !stopping {
            let retired = inspectorSession!
            inspectorSession = URLSession(configuration: retired.configuration, delegate: self, delegateQueue: retired.delegateQueue)
            retired.invalidateAndCancel()
        }
    }
    private func remove(_ id: UUID) {
        guard let s = subscribers.removeValue(forKey: id) else { return }; s.deadline?.cancel(); s.deadline = nil; s.propertyDeadline?.cancel(); s.propertyDeadline = nil
        if let u = upstreams[s.key] { for (call, pending) in u.propertyCalls where pending.client == id { u.propertyCalls.removeValue(forKey: call) } }
        if !subscribers.values.contains(where: { $0.key == s.key }) { terminate(s.key) }
    }
    func stop(_ complete: @escaping () -> Void) {
        queue.async {
            self.stopping = true; self.discovery?.cancel(); self.discovery = nil; self.responseBody = Data()
            let callbacks = self.waiters; self.waiters.removeAll(); callbacks.forEach { $0(.failure(WispError("Metro stopped"))) }
            for id in Array(self.subscribers.keys) { self.remove(id) }; for key in Array(self.upstreams.keys) { self.terminate(key) }
            self.targets.removeAll(); self.session.invalidateAndCancel(); self.inspectorSession.invalidateAndCancel(); complete()
        }
    }
    func diagnostics(_ completion: @escaping ([String: Any]) -> Void) {
        queue.async { completion(["targets": self.targets.count, "upstreams": self.upstreams.count, "subscribers": self.subscribers.count, "discovery_in_flight": self.discovery != nil,
                                  "object_handles": self.upstreams.values.reduce(0) { $0 + $1.references.count }, "property_requests": self.upstreams.values.reduce(0) { $0 + $1.propertyCalls.count },
                                  "received_entries": self.upstreams.values.reduce(UInt64(0)) { $0 + $1.sequence }, "inflight_entries": self.subscribers.values.filter { $0.sequence != nil }.count,
                                  "pending_entries": self.subscribers.values.reduce(0) { $0 + $1.output.entries.count }, "pending_bytes": self.subscribers.values.reduce(0) { $0 + $1.output.bytes }]) }
    }
}
