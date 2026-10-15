import Foundation
import AppKit
import ApplicationServices
import CryptoKit

final class Service {
    let settings: Settings
    let devices: Devices
    let input: DeviceInput
    let server = HTTPServer()
    private(set) var tls: TLSIdentity?
    private let terminals: TerminalManager
    private let metro: MetroConsoleManager
    private let workers = DispatchQueue(label: "Simwisp.device-actions", qos: .userInitiated)
    private var stopping = Set<String>() // network queue owns destructive-action admission
    private let makeCapture: (DeviceWindow) -> WindowCapture
    private let scrcpyInstallation: ScrcpySession.Installation
    private let captureStopTimeout: Double
    private var streams: [String: StreamSession] = [:] // network queue owns registry
    private var retiring: [String: [StreamSession]] = [:] // disconnected/replaced captures still cleaning up
    private let lifecycle = DispatchGroup()
    private let cookie: String
    private let pairingQueue = DispatchQueue(label: "Simwisp.pairing", qos: .userInitiated)
    private var pairing: PairingAuthenticator!
    private let pairingStateURL: URL
    private let tlsDirectory: URL
    private var usage = Usage() // sampled on the network queue for diagnostics only
    private var panelState: [String: Any] = ["visible": false, "refresh_timer": false, "refreshes": 0]
    var stateChanged: ((String) -> Void)?
    init(settings: Settings, pairingStateURL: URL = Settings.file.deletingLastPathComponent().appendingPathComponent("pairing-state.json"), tlsDirectory: URL = TLSIdentity.directory, devices: Devices? = nil, input: DeviceInput? = nil, metroEndpoint: URL = URL(string: "http://127.0.0.1:8081/json/list")!, captureStopTimeout: Double = 20, scrcpyInstallation: @escaping ScrcpySession.Installation = ScrcpyInstallation.find, makeCapture: @escaping (DeviceWindow) -> WindowCapture = { WindowCapture(target: $0) }) {
        self.pairingStateURL = pairingStateURL; self.tlsDirectory = tlsDirectory
        self.settings = settings; self.makeCapture = makeCapture; self.scrcpyInstallation = scrcpyInstallation; self.captureStopTimeout = captureStopTimeout
        let selectedDevices = devices ?? Devices(settings: settings)
        self.devices = selectedDevices; self.input = input ?? DeviceInput(devices: selectedDevices)
        terminals = TerminalManager(settings: settings, network: server.queue)
        metro = MetroConsoleManager(network: server.queue, endpoint: metroEndpoint)
        cookie = SHA256.hash(data: Data(("simwisp-session-v1:" + settings.pairingToken).utf8)).map { String(format: "%02x", $0) }.joined()
        server.authorize = { [weak self] request in
            guard let self, self.authenticated(request) else { return false }
            return request.path != "/ws/pty" || self.settings.terminalEnabled == true
        }
        server.route = { [weak self] request, complete in self?.route(request, complete: complete) }
        server.upgrade = { [weak self] request, client in self?.upgrade(request, client: client) }
        server.stateChanged = { [weak self] state in self?.stateChanged?(state) }
    }
    func start() throws {
        if let error = settings.loadingError { throw WispError(error) }
        pairing = try PairingAuthenticator(settings: settings.pairing, token: settings.pairingToken, stateURL: pairingStateURL)
        let tls = try TLSIdentity(directory: tlsDirectory); self.tls = tls
        try server.start(port: settings.port, lan: settings.shareLAN, tls: tls)
    }
    func updatePanelState(visible: Bool, refreshing: Bool, count: UInt64) {
        server.queue.async { self.panelState = ["visible": visible, "refresh_timer": refreshing, "refreshes": count] }
    }
    func stop(completion: @escaping () -> Void = {}) {
        devices.stop(); lifecycle.enter()
        terminals.stop { self.lifecycle.leave() }
        lifecycle.enter(); metro.stop { self.lifecycle.leave() }
        lifecycle.enter()
        server.stop { self.pairingQueue.async { self.input.queue.async { self.lifecycle.leave() } } }
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
        if request.path == "/ws/pty" { terminals.attach(request, client: client); return }
        if request.path == "/ws/metro-console" { metro.install(client, allowedDevice: { [weak self] id in self?.streams[id] != nil && self?.stopping.contains(id) == false }); return }
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
        guard !stopping.contains(id) else { client.sendJSON(["type": "device_stopping", "id": id]); client.closeAfterSending(); return }
        guard devices.device(id) != nil else { client.sendJSON(["type": "capture_error", "message": "Unknown device"]); client.close(); return }
        // Preserve Simmer's one-controller-per-device behavior; other devices are independent.
        let previous = streams.removeValue(forKey: id)
        let waitForBackend = previous?.usesScrcpy == true
        if let old = previous { retire(old); old.client.close() }
        let session = StreamSession(id: id, client: client, request: request, settings: settings, devices: devices, input: input, queue: server.queue, lifecycle: lifecycle, scrcpyInstallation: scrcpyInstallation, makeCapture: makeCapture)
        session.onClose = { [weak self, weak session] in
            guard let self, let session, self.streams[id] === session else { return }
            self.streams.removeValue(forKey: id); self.retire(session)
            self.devices.setStreamingDemand(!self.streams.isEmpty)
        }
        streams[id] = session; devices.setStreamingDemand(true)
        client.onClose = { [weak session] in session?.stop() }
        if let old = previous, waitForBackend { old.stop { [weak self, weak session] in
            guard let self, let session, self.streams[id] === session, !client.isClosed else { return };session.start()
        } } else { session.start() }
    }
    private func route(_ request: HTTPRequest, complete: @escaping (HTTPResponse) -> Void) {
        if request.path == "/simwisp-ca.cer", request.method == "GET", let tls {
            var response = HTTPResponse(body: tls.certificate, type: "application/pkix-cert")
            response.headers["Content-Disposition"] = "attachment; filename=Simwisp-Local-CA.cer"
            complete(response); return
        }
        if request.path == "/api/pair/options", request.method == "GET" {
            complete(.json(["totp": pairing.totpEnabled])); return
        }
        if request.path == "/api/pair" {
            guard request.method == "POST", request.sameOrigin else { complete(.json(["error": "Same-origin POST required"], status: 403)); return }
            guard request.body.count <= 2048 else { complete(.json(["error": "Pairing body too large"], status: 413)); return }
            pairingQueue.async {
                let decision = self.pairing.authenticate(dictionary(request.body), sourceAddress: request.sourceAddress)
                var response: HTTPResponse
                switch decision {
                case .accepted:
                    response = .json(["ok": true])
                    response.headers["Set-Cookie"] = "simwisp_session=\(self.cookie); Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=2592000"
                case .denied: response = .json(["error": "Invalid pairing credential"], status: 401)
                case .unavailable: response = .json(["error": "TOTP unavailable. Use a pairing link or check Simwisp on the Mac."], status: 503)
                case .throttled(let seconds):
                    response = .json(["error": "Too many pairing attempts. Try again later."], status: 429)
                    response.headers["Retry-After"] = String(seconds)
                }
                complete(response)
            }
            return
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
            var info: [String: Any] = ["mode": "fast2 (ScreenCaptureKit / scrcpy H.264; Quartz / scrcpy input)", "video_codec": "h264", "transport": "https", "app": "Simwisp", "version": "0.2.0", "has_adb": devices.adb != nil, "binary_path": Bundle.main.bundleURL.path, "permissions": ["screen_recording": CGPreflightScreenCaptureAccess(), "accessibility": AXIsProcessTrusted(), "idb": false], "features": ["terminal": settings.terminalEnabled == true, "device_stop": true, "metroConsole": true, "androidBackends": true]]
            if settings.terminalEnabled == true { info["project_dir"] = settings.projectDirectory }
            if let bundle = devices.projectBundleID { info["bundle_id"] = bundle }
            complete(.json(info))
        case ("GET", "/api/metro/targets"):
            guard (request.headers["origin"] == nil || request.sameOrigin), request.headers["sec-fetch-site"] != "cross-site" else { complete(.json(["error": "Origin denied"], status: 403)); return }
            // A same-model emulator need not have an open browser panel. Match
            // against all running devices so it cannot make a shared alias look
            // unique. Attachment still requires the selected stream above.
            metro.discover(devices: devices.list()) { result in
                switch result { case .success(let value): complete(.json(value)); case .failure: complete(.json(["error": "Metro discovery unavailable"], status: 503)) }
            }
        case ("GET", "/api/sims"):
            devices.requestRefresh { complete(.json(self.devices.list().map(\.json))) }
        case ("GET", "/api/devices"):
            devices.requestRefresh { complete(.json(self.devices.library())) }
        case ("GET", "/api/sessions"): complete(.json(streams.values.map(\.snapshot)))
        case ("GET", "/api/terminals"): terminals.snapshots { complete(.json($0)) }
        case ("GET", "/api/status"):
            usage.sample()
            let status: [String: Any] = ["cpu_one_core_percent": usage.cpu, "physical_footprint_bytes": usage.memory, "sessions": streams.count, "capture": CaptureHealth.shared.snapshot, "discovery": devices.diagnostics, "panel": panelState, "terminal": terminals.diagnostics, "lan_sharing": settings.shareLAN]
            metro.diagnostics { counts in var value = status; value["metro"] = counts; complete(.json(value)) }
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
            else if request.method == "POST", request.path.hasPrefix("/api/stop/") { stopDevice(String(request.path.dropFirst(10)), complete: complete) }
            else if request.method == "GET", request.path.hasPrefix("/api/stop-status/") { stopStatus(String(request.path.dropFirst("/api/stop-status/".count)), complete: complete) }
            else { complete(.json(["error": "Not found"], status: 404)) }
        }
    }
    private func boot(_ id: String, complete: @escaping (HTTPResponse) -> Void) {
        guard !stopping.contains(id) else { complete(.json(["error": "This simulator is stopping"], status: 409)); return }
        devices.control.launches.begin(); lifecycle.enter()
        workers.async {
            defer { self.devices.control.launches.end(); self.lifecycle.leave() }
            do { try self.devices.boot(id); complete(.json(["ok": true])) }
            catch { complete(.json(["error": error.localizedDescription], status: 409)) }
        }
    }
    private func stopStatus(_ id: String, complete: @escaping (HTTPResponse) -> Void) {
        guard DeviceControl.validID(id, platform: "android") else { complete(.json(["error": "Invalid emulator identifier"], status: 404)); return }
        lifecycle.enter()
        workers.async {
            defer { self.lifecycle.leave() }
            do { complete(.json(try self.devices.control.androidStopStatus(id))) }
            catch { complete(.json(["error": "Could not confirm emulator shutdown. Refresh devices to check again."], status: 503)) }
        }
    }
    private func retire(_ session: StreamSession) {
        let id = session.id
        guard !(retiring[id] ?? []).contains(where: { $0 === session }) else { return }
        retiring[id, default: []].append(session)
        session.stop {
            self.retiring[id]?.removeAll { $0 === session }
            if self.retiring[id]?.isEmpty == true { self.retiring.removeValue(forKey: id) }
        }
    }
    private func stopDevice(_ id: String, complete: @escaping (HTTPResponse) -> Void) {
        guard let device = devices.device(id), DeviceControl.validID(id, platform: device.platform) else { complete(.json(["error": "Unknown or invalid running simulator"], status: 404)); return }
        guard stopping.insert(id).inserted else { complete(.json(["error": "This simulator is already stopping"], status: 409)); return }
        lifecycle.enter()
        let perform = {
            self.workers.async {
                let response: HTTPResponse
                do { response = .json(try self.devices.control.stop(device)) }
                catch { response = .json(["error": error.localizedDescription], status: 409) }
                self.devices.invalidate()
                self.server.queue.async {
                    self.stopping.remove(id); complete(response); self.lifecycle.leave()
                }
            }
        }
        if let session = streams.removeValue(forKey: id) {
            // An intentional device stop is terminal for existing viewers, not
            // a lost-connection event that should create a reconnect loop.
            session.client.sendJSON(["type": "device_stopping", "id": id]); session.client.closeAfterSending()
            retire(session)
            devices.setStreamingDemand(!streams.isEmpty)
        }
        // The requesting browser closes its view before POST. Its session may
        // already have left streams, while native cleanup is still outstanding.
        let barrier = DispatchGroup()
        for session in retiring[id] ?? [] {
            barrier.enter(); session.stop { barrier.leave() }
        }
        // A hung native startup/stop must not leave admission locked forever,
        // nor cause a delayed destructive action after a failure was returned.
        var waiting = true // all accesses on the network queue
        let timeout = DispatchWorkItem {
            guard waiting else { return }; waiting = false
            self.stopping.remove(id)
            complete(.json(["error": "Capture cleanup is still pending; the device was not shut down. Refresh devices and try again."], status: 409))
            self.lifecycle.leave()
        }
        server.queue.asyncAfter(deadline: .now() + captureStopTimeout, execute: timeout)
        barrier.notify(queue: server.queue) {
            guard waiting else { return }; waiting = false; timeout.cancel(); perform()
        }
    }
}
