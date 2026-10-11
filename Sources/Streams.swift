import Foundation

// Session state is confined to HTTPServer.queue; workers return there before mutation.
final class StreamSession: @unchecked Sendable {
    let id: String
    let client: ClientConnection
    let devices: Devices
    let input: DeviceInput
    let queue: DispatchQueue
    private let lifecycle: DispatchGroup
    private let worker: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var capture: WindowCapture?
    private var geometry: DeviceWindow?
    private var configuring = false
    private var encoding = false
    private var closed = false
    private var awaitingACK: Double?
    private var sending = false
    private var paused = false
    private var dataSaver = false
    private var fps: Int
    private var targetFPS: Int
    private var quality: Int
    private var targetQuality: Int
    private var nextFrame: Double = 0
    private var lastStats: Double = 0
    private var lastHeartbeat: Double = 0
    private var lastJPEG: Data?
    private var frameCount = 0
    private var goodFrames = 0
    private var lastError: String?
    private var lastEncodeMS: Double = 0
    private var lastACKMS: Double = 0
    private var pendingInput: [[String: Any]] = []
    private var inputBusy = false
    private var captureHasFrame = false
    private let accessibility: AccessibilitySession
    private var started = monotonic()
    var onClose: (() -> Void)?
    init(id: String, client: ClientConnection, request: HTTPRequest, settings: Settings, devices: Devices, input: DeviceInput, queue: DispatchQueue, lifecycle: DispatchGroup) {
        self.id = id; self.client = client; self.devices = devices; self.input = input; self.queue = queue; self.lifecycle = lifecycle
        fps = min(60, max(1, Int(request.query["fps"] ?? "") ?? settings.fps)); targetFPS = fps
        quality = min(95, max(1, Int(request.query["quality"] ?? "") ?? settings.quality)); targetQuality = quality
        dataSaver = request.query["data_saver"] == "1"
        worker = DispatchQueue(label: "Simwisp.encode.\(id)", qos: .userInitiated)
        accessibility = AccessibilitySession(serial: id, platform: devices.device(id)?.platform ?? "ios", executable: devices.adb, queue: queue, lifecycle: lifecycle) { [weak client] value, completion in client?.sendJSON(value, completion: completion) }
    }
    private var accessibilityStreamReady: Bool {
        !closed && !paused && captureHasFrame && lastError == nil && capture != nil && capture?.failure == nil && devices.window(id) != nil
    }
    private func reconcileAccessibility() {
        // Avoid capture/discovery locks when no pane is requested. No new timer.
        accessibility.update(streamActive: accessibility.requested && accessibilityStreamReady)
    }
    func start() {
        client.onMessage = { [weak self] text in self?.message(dictionary(Data(text.utf8))) }
        client.onClose = { [weak self] in self?.stop() }
        client.sendJSON(["type": "input_capabilities", "live_touch": true])
        if let window = devices.window(id) { client.sendJSON(["type": "rotated", "landscape": window.landscape]) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), leeway: .microseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }; timer.resume(); self.timer = timer
    }
    var snapshot: [String: Any] {
        ["id": id, "name": devices.device(id)?.name ?? id, "platform": devices.device(id)?.platform ?? "ios", "peer": client.peer, "fps": fps, "quality": quality, "frames": frameCount, "state": lastError ?? (paused ? "Paused" : (capture == nil ? "Starting" : "Streaming")), "uptime": Int(monotonic() - started), "capture_counters": capture?.counters ?? [:], "last_encode_ms": lastEncodeMS, "last_ack_ms": lastACKMS, "accessibility": accessibility.snapshot]
    }
    // One-shot deadlines avoid quantizing 16.67 ms frames onto 16 ms polling
    // ticks. ACK and encoder/send completions wake the same bounded scheduler.
    private func reschedule() {
        guard !closed else { return }
        let now = monotonic()
        var deadline = now + 0.25
        if !paused && !configuring && !encoding && !sending {
            if let sent = awaitingACK { deadline = min(deadline, sent + 0.35) }
            else { deadline = min(deadline, max(now, nextFrame)) }
        }
        timer?.schedule(deadline: .now() + max(0.0001, deadline - now), leeway: .microseconds(100))
    }
    private func tick() {
        guard !closed else { return }
        defer { reconcileAccessibility(); reschedule() }
        let now = monotonic()
        if now - lastHeartbeat > 8 { client.sendJSON(["type": "frame_heartbeat"]); client.ping(); lastHeartbeat = now }
        guard let window = devices.window(id) else {
            if capture != nil { releaseCapture() }
            notifyError("Device window unavailable"); nextFrame = now + 0.5; return
        }
        if capture?.failure != nil { notifyError(capture!.failure!); releaseCapture(); nextFrame = now + 2 }
        let needsConfiguration = geometry?.id != window.id || geometry?.bounds.size != window.bounds.size || geometry?.crop != window.crop
        if needsConfiguration && !configuring {
            guard now >= nextFrame else { return }
            configure(window); return
        }
        guard !paused, !configuring, !encoding, !sending, let capture, now >= nextFrame else { return }
        if let sent = awaitingACK {
            if now - sent < 0.35 { return }
            awaitingACK = nil; fps = max(1, min(targetFPS, fps - 5)); quality = max(1, min(targetQuality, quality - 3)); goodFrames = 0
            nextFrame = now + 1 / Double(fps); return
        }
        encoding = true; nextFrame = now + 1 / Double(fps)
        let requestedQuality = quality
        worker.async { [weak self] in
            let encodeStart = monotonic()
            let jpeg = capture.jpeg(quality: requestedQuality)
            let encodeMS = (monotonic() - encodeStart) * 1000
            guard let self else { return }
            self.queue.async {
                self.encoding = false; self.lastEncodeMS = encodeMS
                defer { self.reconcileAccessibility(); self.reschedule() }
                guard !self.closed, self.capture === capture else { return }
                if let jpeg {
                    if self.dataSaver, self.lastJPEG == jpeg { return }
                    self.lastJPEG = self.dataSaver ? jpeg : nil
                    self.sending = true; self.awaitingACK = monotonic(); self.frameCount += 1; self.lastError = nil; self.captureHasFrame = true
                    self.client.sendBinary(jpeg) { [weak self] in self?.sending = false; self?.reschedule() }
                    if monotonic() - self.lastStats >= 1 {
                        self.lastStats = monotonic(); self.client.sendJSON(["type": "server_stats", "fps": self.fps, "quality": self.quality, "frame_id": self.frameCount])
                    }
                } else if monotonic() - self.started > 10 { self.notifyError("No complete frame; check Screen Recording permission") }
            }
        }
    }
    private func configure(_ window: DeviceWindow) {
        configuring = true
        let old = capture; capture = nil; geometry = nil; captureHasFrame = false; reconcileAccessibility()
        let new = WindowCapture(target: window), lifecycle = self.lifecycle
        lifecycle.enter()
        Task { @MainActor [weak self] in
            if let old { await old.stop() }
            do {
                try await new.start()
                guard let self else { await new.stop(); lifecycle.leave(); return }
                self.queue.async {
                    self.configuring = false
                    if self.closed { Task { @MainActor in await new.stop(); lifecycle.leave() }; return }
                    self.capture = new; self.geometry = window; self.lastJPEG = nil; self.lastError = nil
                    lifecycle.leave(); self.reconcileAccessibility(); self.reschedule()
                }
            } catch {
                guard let self else { lifecycle.leave(); return }
                self.queue.async { self.configuring = false; self.nextFrame = monotonic() + 3; if !self.closed { self.notifyError(error.localizedDescription); self.reschedule() }; lifecycle.leave() }
            }
        }
    }
    private func releaseCapture() {
        let old = capture; capture = nil; geometry = nil; lastJPEG = nil; captureHasFrame = false
        reconcileAccessibility()
        if let old {
            let lifecycle = self.lifecycle; lifecycle.enter()
            Task { @MainActor in await old.stop(); lifecycle.leave() }
        }
    }
    private func notifyError(_ message: String) {
        if lastError != message { lastError = message; client.sendJSON(["type": "capture_error", "message": message]); log("\(id): \(message)") }
    }
    private func message(_ data: [String: Any]) {
        guard !closed, let type = data["type"] as? String else { return }
        defer { reconcileAccessibility(); reschedule() }
        if type == "frame_ack" {
            if let sent = awaitingACK {
                let elapsed = monotonic() - sent; awaitingACK = nil; lastACKMS = elapsed * 1000
                if elapsed > 0.18 { fps = max(1, min(targetFPS, fps - 2)); quality = max(1, min(targetQuality, quality - 1)); goodFrames = 0 }
                else { goodFrames += 1; if goodFrames >= 30 { goodFrames = 0; fps = min(targetFPS, fps + 2); quality = min(targetQuality, quality + 2) } }
            }
        } else if type == "settings" {
            if let n = data["fps"] as? NSNumber { targetFPS = Int(clamp(n.doubleValue, 1, 60)); fps = targetFPS }
            if let n = data["quality"] as? NSNumber { targetQuality = Int(clamp(n.doubleValue, 1, 95)); quality = targetQuality }
            if let value = data["data_saver"] as? Bool { dataSaver = value; lastJPEG = nil }
            if let value = data["stream_paused"] as? Bool { paused = value; if value { awaitingACK = nil } }
            if let value = data["accessibility_enabled"] as? Bool { accessibility.update(paneOpen: value, streamActive: value && accessibilityStreamReady, subscription: data["accessibility_subscription"] as? Int) }
        } else {
            guard DeviceInput.supportedTypes.contains(type) else { return }
            if type == "touch_move", pendingInput.last?["type"] as? String == "touch_move" { pendingInput[pendingInput.count - 1] = data }
            else if pendingInput.count < 128 { pendingInput.append(data) }
            else { client.close(); return }
            drainInput()
        }
    }
    private func drainInput() {
        guard !inputBusy, !pendingInput.isEmpty, !closed else { return }
        inputBusy = true; let data = pendingInput.removeFirst()
        input.perform(data, id: id) { [weak self] response in
            guard let self else { return }
            self.queue.async {
                self.inputBusy = false
                if let response, !self.closed { self.client.sendJSON(response) }
                self.drainInput()
            }
        }
    }
    func stop() {
        guard !closed else { return }; closed = true
        accessibility.stop()
        timer?.cancel(); timer = nil; pendingInput.removeAll(); input.cancel(id); releaseCapture(); onClose?(); onClose = nil
    }
}
