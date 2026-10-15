import Foundation

// Session state is confined to HTTPServer.queue; workers return there before mutation.
final class StreamSession: @unchecked Sendable {
    let id: String
    let client: ClientConnection
    let devices: Devices
    let input: DeviceInput
    let queue: DispatchQueue
    private let lifecycle: DispatchGroup
    private let captureLifecycle = DispatchGroup()
    private let makeCapture: (DeviceWindow) -> WindowCapture
    private let scrcpyInstallation: ScrcpySession.Installation
    private var backendChoice: AndroidBackendChoice
    private var scrcpy: ScrcpySession?
    private var scrcpyFinish: (() -> Void)?
    private var backendResolved = false
    private var backendRetiring = false
    private var captureFallback: String?
    private var effectiveCapture = "starting", effectiveInput = "starting"
    private var backendAvailable: Bool?
    private var backendProbePending = false
    private var lastVideoSize = (0,0)
    private var inputSizeHint = (0,0)
    private var backendReason: String?
    private var backendStarted = 0.0
    private var scrcpyFPS = 0, scrcpyQuality = 0
    private var backendSettingsAt = 0.0
    private var lastSourceDescription = Data()
    private var lastScrcpyGeneration: UInt64?
    private let initialScrcpySize: ScrcpyVideoSize
    private var lastScrcpyWindowSize: ScrcpyVideoSize?
    private var pendingScrcpySize: ScrcpyVideoSize?
    private var scrcpySizeChangedAt = 0.0
    var usesScrcpy: Bool { scrcpy != nil || backendRetiring }
    private var isAndroid: Bool { devices.device(id)?.platform == "android" }

    private let nativeInputWorker: DispatchQueue
    private let worker: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var capture: WindowCapture?
    private var geometry: DeviceWindow?
    private var configuring = false
    private var encoding = false
    private var closed = false
    private var sending = false
    private var sendStarted: Double?
    private var flow: StreamFlow
    private var paused = false
    private var dataSaver = false
    private var fps: Int { flow.fps }
    private var quality: Int { flow.quality }
    private var nextFrame: Double = 0
    private var lastStats = monotonic()
    private var lastStatsFrames = 0
    private var sentFPS = 0.0
    private var lastHeartbeat: Double = 0
    private var videoReady = false
    private var videoEpoch: UInt32 = 1
    private var wireFrameID: UInt32 = 0
    private var forceKeyframe = true
    private var frameCount = 0
    private var lastError: String?
    private var lastEncodeMS: Double = 0
    private var pendingInput: [[String: Any]] = []
    private var inputBusy = false
    private var captureHasFrame = false
    private let accessibility: AccessibilitySession
    private var started = monotonic()
    var onClose: (() -> Void)?
    init(id: String, client: ClientConnection, request: HTTPRequest, settings: Settings, devices: Devices, input: DeviceInput, queue: DispatchQueue, lifecycle: DispatchGroup, scrcpyInstallation: @escaping ScrcpySession.Installation = ScrcpyInstallation.find, makeCapture: @escaping (DeviceWindow) -> WindowCapture = { WindowCapture(target: $0) }) {
        self.makeCapture = makeCapture; self.scrcpyInstallation = scrcpyInstallation
        backendChoice = AndroidBackendChoice(capture: request.query["capture_backend"], input: request.query["input_backend"])
        initialScrcpySize = ScrcpyVideoSize(width:Int(request.query["w"] ?? "") ?? 0,height:Int(request.query["h"] ?? "") ?? 0) ?? .headless
        if let w=Int(request.query["w"] ?? ""), let h=Int(request.query["h"] ?? ""), (1...8192).contains(w), (1...8192).contains(h) { inputSizeHint=(w,h) }
        self.id = id; self.client = client; self.devices = devices; self.input = input; self.queue = queue; self.lifecycle = lifecycle
        flow = StreamFlow(fps: Int(request.query["fps"] ?? "") ?? settings.fps, quality: Int(request.query["quality"] ?? "") ?? settings.quality)
        dataSaver = request.query["data_saver"] == "1"
        nativeInputWorker = DispatchQueue(label: "Simwisp.scrcpy-input.\(id)", qos: .userInteractive)
        worker = DispatchQueue(label: "Simwisp.encode.\(id)", qos: .userInitiated)
        accessibility = AccessibilitySession(serial: id, platform: devices.device(id)?.platform ?? "ios", executable: devices.adb, queue: queue, lifecycle: lifecycle) { [weak client] value, completion in client?.sendJSON(value, completion: completion) }
    }
    private var accessibilityStreamReady: Bool {
        !closed && !paused && captureHasFrame && lastError == nil && ((isAndroid && effectiveCapture == "scrcpy" && scrcpy?.state.ready == true && scrcpy?.state.error == nil) || (capture != nil && capture?.failure == nil && capture?.hasFrame == true && devices.window(id) != nil))
    }
    private func reconcileAccessibility() {
        // Avoid capture/discovery locks when no pane is requested. No new timer.
        accessibility.update(streamActive: accessibility.requested && accessibilityStreamReady)
    }
    func start() {
        guard !closed else { return }
        client.onMessage = { [weak self] text in self?.message(dictionary(Data(text.utf8))) }
        client.onClose = { [weak self] in self?.stop() }
        client.sendJSON(["type": "input_capabilities", "live_touch": true, "video_flow": "paced-v1"])
        if let window = devices.window(id) { client.sendJSON(["type": "rotated", "landscape": window.landscape]) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), leeway: .microseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }; timer.resume(); self.timer = timer
    }
    var snapshot: [String: Any] {
        ["id": id, "name": devices.device(id)?.name ?? id, "platform": devices.device(id)?.platform ?? "ios", "peer": client.peer, "fps": fps, "quality": quality, "frames": frameCount, "state": lastError ?? (paused ? "Paused" : (captureHasFrame ? "Streaming" : "Starting")), "uptime": Int(monotonic() - started), "capture_counters": effectiveCapture == "scrcpy" ? (scrcpy?.diagnostics ?? [:]) : (capture?.counters ?? [:]), "input_counters": effectiveInput == "scrcpy" ? (scrcpy?.inputDiagnostics ?? [:]) : [:], "sent_fps": sentFPS, "target_fps": flow.targetFPS, "last_encode_ms": lastEncodeMS, "unreceived_frames": flow.count, "unreceived_bytes": flow.bytes, "receiver_pending_frames": flow.receiverPending, "receiver_decode_queue": flow.receiverQueue, "receiver_oldest_ms": flow.receiverOldestMS, "accessibility": accessibility.snapshot, "android_backends": isAndroid ? backendSnapshot : [:]]
    }
    // One-shot deadlines avoid quantizing 16.67 ms frames onto 16 ms polling
    // ticks. Local encode/write completions wake it; receiver RTT never gates
    // each frame. Cumulative feedback only enforces a finite transport budget.
    private func reschedule() {
        guard !closed else { return }
        let now = monotonic()
        var deadline = now + 0.25
        if videoReady && !paused && !configuring && !encoding && !sending && flow.hasCapacity {
            if effectiveCapture == "scrcpy" && backendResolved {
                // Push source: scrcpy already paces encoded frames. Wake only
                // for an available AU; never spend a pull-encoder deadline.
                if scrcpy?.hasFrame == true { deadline = now }
            } else { deadline = min(deadline, max(now, max(nextFrame, flow.nextFrame))) }
        }
        timer?.schedule(deadline: .now() + max(0.0001, deadline - now), leeway: .microseconds(100))
    }
    private func tick() {
        guard !closed else { return }
        defer { publishStats(); reconcileAccessibility(); reschedule() }
        let now = monotonic()
        if now - lastHeartbeat > 8 { client.sendJSON(["type": "frame_heartbeat"]); client.ping(); lastHeartbeat = now }
        guard videoReady else { nextFrame = now + 0.25; return }
        if !paused && (flow.unresponsive(now: now) || sendStarted.map({ now - $0 > StreamFlow.receiptTimeout }) == true) {
            // TCP cannot retract old bytes. Reconnect rather than retain seconds
            // of stale video or an indefinitely blocked local write.
            client.close(); return
        }
        if isAndroid {
            if paused { return }
            guard prepareAndroid() else { nextFrame = now + 0.25; return }
            if effectiveCapture == "unavailable" { notifyError(backendReason ?? "scrcpy capture unavailable");nextFrame=now+0.5;return }
            if effectiveCapture == "scrcpy" {
                guard !sending else { return }
                guard flow.hasCapacity else { flow.congested(now:now);scrcpy?.requestKeyframe();return }
                guard let video=scrcpy?.takeVideoFrame() else { return }
                let frame=video.frame
                // A natural IDR is not a new decoder. Only a source/session/
                // reference-chain discontinuity advances the browser epoch.
                if lastScrcpyGeneration != video.generation || lastSourceDescription != frame.description {
                    guard frame.keyframe else { requestKeyframe();return }
                    videoEpoch &+= 1;forceKeyframe=true
                    lastScrcpyGeneration=video.generation;lastSourceDescription=frame.description
                }
                deliver(frame, epoch:videoEpoch)
                return
            }
        }
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
        if !flow.hasCapacity { flow.congested(now: now); return }
        guard flow.beginFrame(now: now) else { return }
        encoding = true
        let requestedQuality = quality, requestedFPS = fps, requestedKey = forceKeyframe, requestedSaver = dataSaver, epoch = videoEpoch
        worker.async { [weak self] in
            let encodeStart = monotonic()
            let result = Result { try capture.h264(quality: requestedQuality, fps: requestedFPS, forceKeyframe: requestedKey, dataSaver: requestedSaver) }
            let encodeMS = (monotonic() - encodeStart) * 1000
            guard let self else { return }
            self.queue.async {
                self.encoding = false; self.lastEncodeMS = encodeMS
                defer { self.reconcileAccessibility(); self.reschedule() }
                guard !self.closed, !self.paused, self.capture === capture, self.videoEpoch == epoch else { return }
                switch result {
                case .success(let frame):
                    if let frame {
                        self.deliver(frame, epoch:epoch)
                    } else if !capture.hasFrame && monotonic() - self.started > 10 { self.notifyError("No complete frame; check Screen Recording permission") }
                case .failure(let error):
                    self.notifyError(error.localizedDescription); self.releaseCapture(); self.nextFrame = monotonic() + 2
                }
            }
        }
    }
    private func deliver(_ frame: H264Frame, epoch: UInt32) {
        if isAndroid && effectiveCapture == "scrcpy" && (lastVideoSize.0 != frame.width || lastVideoSize.1 != frame.height) {
            lastVideoSize=(frame.width,frame.height);client.sendJSON(["type":"rotated","landscape":frame.width>frame.height])
        }
        let packetBytes = frame.payload.count + 24
        guard flow.canSend(bytes: packetBytes) else {
            flow.deferSend(bytes: packetBytes, now: monotonic())
            // An encoded-but-unsent P frame changes the encoder's
            // references. Force an IDR before transmitting again.
            requestKeyframe(); return
        }
        // Configuration precedes every IDR. Epochs reject stale
        // decoder recovery and adaptation, not per-frame ACKs.
        if frame.keyframe { client.sendJSON(frame.configuration(epoch: epoch)); forceKeyframe = false }
        else if forceKeyframe { return }
        wireFrameID &+= 1
        let sentAt = monotonic()
        guard flow.recordSend(epoch: epoch, id: wireFrameID, bytes: packetBytes, now: sentAt) else { return }
        sending = true; sendStarted = sentAt; frameCount += 1; lastError = nil; captureHasFrame = true
        client.sendBinary(frame.packet(epoch: epoch, id: wireFrameID)) { [weak self] in
            guard let self, !self.closed else { return }
            self.sending = false; self.sendStarted = nil
            if monotonic() - sentAt > 0.1 { self.flow.congested(now: monotonic()) }
            self.reschedule()
        }
    }
    private func publishStats() {
        let now=monotonic(), elapsed=now-lastStats
        guard elapsed >= 1 else { return }
        sentFPS=Double(frameCount-lastStatsFrames)/elapsed
        lastStats=now;lastStatsFrames=frameCount
        client.sendJSON(["type":"server_stats","codec":"h264","fps":fps,"target_fps":flow.targetFPS,"sent_fps":sentFPS,"quality":quality,"frame_id":frameCount])
    }
    private func requestKeyframe() {
        videoEpoch &+= 1; forceKeyframe = true
        scrcpy?.requestKeyframe()
        // Never erase outstanding transport debt on reset; delayed feedback
        // from an older epoch can still retire already-delivered bytes.
    }
    private func beginCaptureWork() -> () -> Void {
        let lifecycle = self.lifecycle, captures = captureLifecycle
        lifecycle.enter(); captures.enter()
        return { lifecycle.leave(); captures.leave() }
    }
    private func configure(_ window: DeviceWindow) {
        configuring = true; requestKeyframe()
        let old = capture; capture = nil; geometry = nil; captureHasFrame = false; reconcileAccessibility()
        let new = makeCapture(window), finish = beginCaptureWork()
        Task { @MainActor [weak self] in
            if let old { await old.stop() }
            do {
                try await new.start()
                guard let self else { await new.stop(); finish(); return }
                self.queue.async {
                    self.configuring = false
                    if self.closed { Task { @MainActor in await new.stop(); finish() }; return }
                    self.capture = new; self.geometry = window; self.lastError = nil
                    finish(); self.reconcileAccessibility(); self.reschedule()
                }
            } catch {
                guard let self else { finish(); return }
                self.queue.async { self.configuring = false; self.nextFrame = monotonic() + 3; if !self.closed { self.notifyError(error.localizedDescription); self.reschedule() }; finish() }
            }
        }
    }
    private func releaseCapture() {
        let old = capture; capture = nil; geometry = nil; captureHasFrame = false; requestKeyframe()
        reconcileAccessibility()
        if let old {
            let finish = beginCaptureWork()
            Task { @MainActor in await old.stop(); finish() }
        }
    }
    private var backendSnapshot: [String: Any] {
        ["type":"android_backends","capture":backendChoice.capture.rawValue,"input":backendChoice.input.rawValue,
         "effective_capture":effectiveCapture,"effective_input":effectiveInput,"available":backendAvailable as Any? ?? NSNull(),
         "reason":backendReason as Any? ?? NSNull(),"version":ScrcpyWire.version]
    }
    private func publishBackends() { client.sendJSON(backendSnapshot) }
    private func releaseAndroid(completion: @escaping () -> Void = {}) {
        guard let old=scrcpy else {completion();return}
        if old.video { captureHasFrame=false }
        scrcpy=nil;let finish=scrcpyFinish;scrcpyFinish=nil;backendRetiring=true
        old.stop { [weak self] in finish?();self?.backendRetiring=false;completion();self?.reschedule() }
    }
    private func resetAndroid() {
        pendingInput.removeAll();input.cancel(id);backendResolved=false;captureHasFrame=false;captureFallback=nil;backendReason=nil
        effectiveCapture="starting";effectiveInput="starting";releaseAndroid();publishBackends()
    }
    private func desiredScrcpySize() -> ScrcpyVideoSize {
        // Use authoritative host crop geometry, not dev_w/dev_h decoder-size
        // feedback (which would feed codec alignment back into the next budget).
        if let crop=devices.window(id)?.crop,
           crop.width.isFinite, crop.height.isFinite,
           crop.width >= 8, crop.height >= 8, crop.width <= 8192, crop.height <= 8192,
           let size=ScrcpyVideoSize(width:Int(crop.width.rounded()),height:Int(crop.height.rounded())) {
            lastScrcpyWindowSize=size
        }
        // Losing a window must not resize or disable a headless source.
        return lastScrcpyWindowSize ?? initialScrcpySize
    }
    private func prepareAndroid() -> Bool {
        if backendRetiring { return false }
        if let source=scrcpy {
            let s=source.state
            backendAvailable=s.installed
            if let error=s.error {
                let retryControl = captureFallback == nil && backendChoice.capture == .auto && backendChoice.input != .current && s.connected
                if retryControl {
                    captureFallback=error;backendReason="Capture: "+error;backendResolved=false;releaseAndroid();return false
                }
                backendReason=(captureFallback.map { "Capture: "+$0+"; " } ?? "")+error
                effectiveCapture=backendChoice.capture == .scrcpy ? "unavailable":"current"
                effectiveInput=backendChoice.input == .scrcpy ? "unavailable":"current"
                backendResolved=true;releaseAndroid();publishBackends();return true
            }
            if !s.ready || (source.video && s.size.0==0) {
                if monotonic()-backendStarted>12 { backendReason="scrcpy startup timed out";effectiveCapture=backendChoice.capture == .scrcpy ? "unavailable":"current";effectiveInput=backendChoice.input == .scrcpy ? "unavailable":"current";backendResolved=true;releaseAndroid();publishBackends();return true }
                return false
            }
            if !backendResolved {
                effectiveCapture=source.video ? "scrcpy":"current";effectiveInput=backendChoice.input == .current ? "current":"scrcpy"
                backendResolved=true;backendReason=captureFallback.map{"Capture fell back: "+$0};publishBackends()
            }
            if source.video {
                let desired=desiredScrcpySize(), now=monotonic()
                if desired == source.videoSize { pendingScrcpySize=nil }
                else if desired != pendingScrcpySize { pendingScrcpySize=desired;scrcpySizeChangedAt=now }
                let resized=pendingScrcpySize != nil && now-scrcpySizeChangedAt >= 0.35
                if resized || (backendSettingsAt>0 && now>=backendSettingsAt) || (now-backendStarted>5 && (scrcpyFPS != flow.fps || scrcpyQuality != flow.quality)) {
                    pendingScrcpySize=nil;backendSettingsAt=0;backendResolved=false;releaseAndroid();return false
                }
            }
            return true
        }
        if backendResolved { return true }
        if backendChoice.capture == .current && backendChoice.input == .current {
            effectiveCapture="current";effectiveInput="current";backendResolved=true;publishBackends()
            if !backendProbePending {
                backendProbePending=true;lifecycle.enter();let done=lifecycle
                worker.async { [weak self] in
                    guard let self else {done.leave();return};let result=Result{try self.scrcpyInstallation()}
                    self.queue.async {self.backendProbePending=false;if !self.closed {self.backendAvailable=(try? result.get().version)==ScrcpyWire.version;self.publishBackends()};done.leave()}
                }
            }
            return true
        }
        guard let adb=devices.adb else {
            backendReason="Android SDK adb is unavailable";effectiveCapture=backendChoice.capture == .scrcpy ? "unavailable":"current";effectiveInput=backendChoice.input == .scrcpy ? "unavailable":"current";backendResolved=true;publishBackends();return true
        }
        if capture != nil { releaseCapture() }
        scrcpyFPS=flow.fps;scrcpyQuality=flow.quality;backendStarted=monotonic();lastScrcpyGeneration=nil
        let source=ScrcpySession(adb:adb,serial:id,video:backendChoice.capture != .current && captureFallback == nil,controls:backendChoice.input != .current,fps:scrcpyFPS,quality:scrcpyQuality,videoSize:desiredScrcpySize(),network:queue,lifecycle:lifecycle,installation:scrcpyInstallation)
        scrcpy=source;scrcpyFinish=beginCaptureWork()
        source.onChange={ [weak self,weak source] in guard let self,let source,!self.closed,self.scrcpy === source else{return};self.nextFrame=monotonic();self.tick() }
        source.start();publishBackends();return false
    }
    private func notifyError(_ message: String) {
        if lastError != message { lastError = message; client.sendJSON(["type": "capture_error", "message": message]); log("\(id): \(message)") }
    }
    private func message(_ data: [String: Any]) {
        guard !closed, let type = data["type"] as? String else { return }
        defer { reconcileAccessibility(); reschedule() }
        if type == "video_ready" {
            guard data["flow"] as? String == "paced-v1" else {
                notifyError("Streaming protocol updated; reload the browser page."); return
            }
            videoReady = true
        } else if type == "video_keyframe" {
            if let epoch = data["epoch"] as? NSNumber, epoch.doubleValue != Double(videoEpoch) { return }
            if data["overloaded"] as? Bool == true { flow.congested(now: monotonic()) }
            requestKeyframe()
        } else if type == "video_feedback" {
            guard let feedback = StreamFeedback(data) else { return }
            _ = flow.feedback(feedback, currentEpoch: videoEpoch, now: monotonic())
        } else if type == "settings" {
            // Browser/capture dimensions are a change hint, never Android's touch
            // space. Replayed settings/decoder notifications must not query ADB.
            if let w=(data["dev_w"] as? NSNumber)?.doubleValue, let h=(data["dev_h"] as? NSNumber)?.doubleValue,
               w.isFinite, h.isFinite, w.rounded()==w, h.rounded()==h, (1...8192).contains(w), (1...8192).contains(h) {
                let next=(Int(w),Int(h))
                if next != inputSizeHint {
                    let known=inputSizeHint.0>0;inputSizeHint=next
                    if known { scrcpy?.invalidatePhysicalSize() }
                }
            }
            let f = (data["fps"] as? NSNumber).flatMap { $0.doubleValue.isFinite ? Int(clamp($0.doubleValue, 1, 60)) : nil }
            let q = (data["quality"] as? NSNumber).flatMap { $0.doubleValue.isFinite ? Int(clamp($0.doubleValue, 1, 95)) : nil }
            if f != nil || q != nil {
                let changed = (f != nil && f != flow.targetFPS) || (q != nil && q != flow.targetQuality)
                flow.settings(fps: f, quality: q, now: monotonic())
                if changed { backendSettingsAt = monotonic() + 0.35 }
            }
            if let value = data["data_saver"] as? Bool, value != dataSaver { dataSaver = value; requestKeyframe() }
            if let value = data["stream_paused"] as? Bool, value != paused { paused = value; requestKeyframe(); if isAndroid { resetAndroid() } }
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
        let completion: ([String: Any]?) -> Void = { [weak self] response in
            guard let self else { return }
            self.queue.async {
                self.inputBusy = false
                if let response, !self.closed { self.client.sendJSON(response) }
                self.drainInput()
            }
        }
        if isAndroid {
            guard !paused, backendResolved, effectiveInput != "unavailable", captureHasFrame, lastError == nil else { completion(["type":"input_error","message":backendReason ?? "Android stream is not ready"]);return }
            if effectiveInput == "scrcpy", data["type"] as? String != "appearance", !(data["type"] as? String == "rotate" && effectiveCapture == "current"), let source=scrcpy {
                nativeInputWorker.async { [weak self] in
                    do {
                        if try source.perform(data) { completion(nil) }
                        else { self?.input.perform(data,id:self?.id ?? "",completion:completion) }
                    } catch {completion(["type":"input_error","message":error.localizedDescription])}
                };return
            }
        }
        if data["type"] as? String == "rotate", let source=scrcpy {
            // The emulator-skin command is asynchronous: query only AFTER it
            // completes, not before rotation has actually changed the display.
            let legacyInput=input, deviceID=id
            nativeInputWorker.async {
                source.cancelGesture()
                legacyInput.perform(data, id:deviceID) { response in
                    source.invalidatePhysicalSize(); completion(response)
                }
            };return
        }
        input.perform(data, id:id, completion:completion)
    }
    func stop(completion: @escaping () -> Void = {}) {
        if !closed {
            closed = true; accessibility.stop()
            timer?.cancel(); timer = nil; pendingInput.removeAll(); input.cancel(id); releaseAndroid(); releaseCapture(); onClose?(); onClose = nil
        }
        // Await only this device's capture work, including an in-flight configure.
        // Other simulator captures do not delay or get stopped by this request.
        captureLifecycle.notify(queue: queue, execute: completion)
    }
}
