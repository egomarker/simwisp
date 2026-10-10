import Foundation
import AppKit
import ApplicationServices
import CryptoKit

final class Service {
    let settings: Settings
    let devices: Devices
    let input: DeviceInput
    let server = HTTPServer()
    private let workers = DispatchQueue(label: "Simwisp.tools", qos: .userInitiated, attributes: .concurrent)
    private var streams: [String: StreamSession] = [:] // network queue owns registry
    private let lifecycle = DispatchGroup()
    private let cookie: String
    private var usage = Usage() // sampled on the network queue for diagnostics only
    private var panelState: [String: Any] = ["visible": false, "refresh_timer": false, "refreshes": 0]
    var stateChanged: ((String) -> Void)?
    init(settings: Settings) {
        self.settings = settings; devices = Devices(settings: settings); input = DeviceInput(devices: devices)
        cookie = SHA256.hash(data: Data(("simwisp-session-v1:" + settings.pairingToken).utf8)).map { String(format: "%02x", $0) }.joined()
        server.authorize = { [weak self] request in self?.authenticated(request) == true }
        server.route = { [weak self] request, complete in self?.route(request, complete: complete) }
        server.upgrade = { [weak self] request, client in self?.upgrade(request, client: client) }
        server.stateChanged = { [weak self] state in self?.stateChanged?(state) }
    }
    func start() throws { try server.start(port: settings.port, lan: settings.shareLAN) }
    func updatePanelState(visible: Bool, refreshing: Bool, count: UInt64) {
        server.queue.async { self.panelState = ["visible": visible, "refresh_timer": refreshing, "refreshes": count] }
    }
    func stop(completion: @escaping () -> Void = {}) {
        devices.stop(); lifecycle.enter()
        server.stop { self.input.queue.async { self.lifecycle.leave() } }
        lifecycle.notify(queue: .main, execute: completion)
    }
    func snapshots(_ completion: @escaping ([[String: Any]]) -> Void) { server.queue.async { completion(self.streams.values.map(\.snapshot).sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }) } }
    private func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8); guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    private func authenticated(_ request: HTTPRequest) -> Bool {
        let cookies = (request.headers["cookie"] ?? "").components(separatedBy: ";")
        return cookies.contains { let parts = $0.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1); return parts.count == 2 && parts[0] == "simwisp_session" && equal(String(parts[1]), cookie) }
    }
    private func upgrade(_ request: HTTPRequest, client: ClientConnection) {
        devices.requestRefresh { [weak self, weak client] in
            guard let self, let client else { return }
            self.server.queue.async {
                guard !client.isClosed else { return }
                self.startStream(request, client: client)
            }
        }
    }
    private func startStream(_ request: HTTPRequest, client: ClientConnection) {
        let id = String(request.path.dropFirst(4))
        guard devices.device(id) != nil else { client.sendJSON(["type": "capture_error", "message": "Unknown device"]); client.close(); return }
        // Preserve Simmer's one-controller-per-device behavior; other devices are independent.
        if let old = streams.removeValue(forKey: id) { old.stop(); old.client.close() }
        let session = StreamSession(id: id, client: client, request: request, settings: settings, devices: devices, input: input, queue: server.queue, lifecycle: lifecycle)
        session.onClose = { [weak self, weak session] in
            guard let self, self.streams[id] === session else { return }
            self.streams.removeValue(forKey: id)
            self.devices.setStreamingDemand(!self.streams.isEmpty)
        }
        streams[id] = session; devices.setStreamingDemand(true); session.start()
    }
    private func route(_ request: HTTPRequest, complete: @escaping (HTTPResponse) -> Void) {
        if request.path == "/api/pair" {
            guard request.method == "POST", request.sameOrigin else { complete(.json(["error": "Same-origin POST required"], status: 403)); return }
            let token = dictionary(request.body)["token"] as? String ?? ""
            guard equal(token, settings.pairingToken) else { complete(.json(["error": "Invalid pairing code"], status: 401)); return }
            var response = HTTPResponse.json(["ok": true])
            response.headers["Set-Cookie"] = "simwisp_session=\(cookie); Path=/; HttpOnly; SameSite=Strict; Max-Age=2592000"
            complete(response); return
        }
        if request.path == "/" || request.path.hasPrefix("/css/") || request.path.hasPrefix("/js/") {
            guard request.method == "GET", !request.path.contains(".."), !request.path.contains("\\") else { complete(.json(["error": "Invalid resource"], status: 400)); return }
            let path = request.path == "/" ? "index.html" : String(request.path.dropFirst())
            guard let root = Bundle.main.resourceURL?.appendingPathComponent("Web"), let data = try? Data(contentsOf: root.appendingPathComponent(path)), data.count < 2_000_000 else { complete(.json(["error": "Not found"], status: 404)); return }
            let type = path.hasSuffix(".html") ? "text/html; charset=utf-8" : path.hasSuffix(".css") ? "text/css; charset=utf-8" : "text/javascript; charset=utf-8"
            var response = HTTPResponse(body: data, type: type)
            response.headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' blob: data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
            complete(response); return
        }
        guard authenticated(request) else { complete(.json(["error": "Pair this browser using the link in Simwisp’s menu-bar panel"], status: 401)); return }
        if request.method != "GET" && !request.sameOrigin { complete(.json(["error": "Origin denied"], status: 403)); return }
        switch (request.method, request.path) {
        case ("GET", "/api/info"):
            var info: [String: Any] = ["mode": "fast2 (Native ScreenCaptureKit + Quartz input)", "app": "Simwisp", "version": "0.1.0", "has_adb": devices.adb != nil, "binary_path": Bundle.main.bundleURL.path, "permissions": ["screen_recording": CGPreflightScreenCaptureAccess(), "accessibility": AXIsProcessTrusted(), "idb": false], "features": ["terminal": false]]
            if let bundle = devices.projectBundleID { info["bundle_id"] = bundle }
            complete(.json(info))
        case ("GET", "/api/sims"):
            devices.requestRefresh { complete(.json(self.devices.list().map(\.json))) }
        case ("GET", "/api/devices"):
            devices.requestRefresh { complete(.json(self.devices.library())) }
        case ("GET", "/api/sessions"): complete(.json(streams.values.map(\.snapshot)))
        case ("GET", "/api/status"):
            usage.sample()
            complete(.json(["cpu_one_core_percent": usage.cpu, "physical_footprint_bytes": usage.memory, "sessions": streams.count, "capture": CaptureHealth.shared.snapshot, "discovery": devices.diagnostics, "panel": panelState, "lan_sharing": settings.shareLAN]))
        case ("POST", "/api/request-permissions"):
            let permission = dictionary(request.body)["permission"] as? String
            DispatchQueue.main.async {
                if permission == "screen_recording" { CGRequestScreenCaptureAccess() }
                else if permission == "accessibility" { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
                complete(.json(["screen_recording": CGPreflightScreenCaptureAccess(), "accessibility": AXIsProcessTrusted(), "binary_path": Bundle.main.bundleURL.path]))
            }
        case ("POST", "/api/boot-avd"):
            guard let avd = dictionary(request.body)["avd"] as? String else { complete(.json(["error": "Missing AVD"], status: 400)); return }; boot(avd, complete: complete)
        default:
            if request.method == "POST", request.path.hasPrefix("/api/boot/") { boot(String(request.path.dropFirst(10)), complete: complete) }
            else { complete(.json(["error": "Not found"], status: 404)) }
        }
    }
    private func boot(_ id: String, complete: @escaping (HTTPResponse) -> Void) {
        workers.async {
            do { try self.devices.boot(id); complete(.json(["ok": true])) }
            catch { complete(.json(["error": error.localizedDescription], status: 409)) }
        }
    }
}
