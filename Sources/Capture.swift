import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreImage

final class CaptureHealth {
    static let shared = CaptureHealth()
    private let lock = NSLock()
    private var count = 0
    private var lastCleanupError: String?
    // Keep fatal_error for status API compatibility. A per-stream cleanup error
    // is diagnostic, never a process-wide admission lock for new captures.
    var snapshot: [String: Any] { lock.withLock { ["active": count, "fatal_error": NSNull(), "last_cleanup_error": lastCleanupError as Any? ?? NSNull()] } }
    func created() { lock.withLock { count += 1 } }
    func released() { lock.withLock { count = max(0, count - 1) } }
    func cleanupFailed(_ message: String) { lock.withLock { lastCleanupError = message } }
}

// The native stream implements this small seam directly. Tests can drive the
// actual WindowCapture lifecycle without creating a ScreenCaptureKit session.
protocol CaptureStream: AnyObject {
    @MainActor func startCapture() async throws
    @MainActor func stopCapture() async throws
    @MainActor func removeStreamOutput(_ output: any SCStreamOutput, type: SCStreamOutputType) throws
}
extension SCStream: CaptureStream {}

// Native capture keeps only the newest complete frame. Encoding is independently
// paced, with one H.264 encoder and no encoded-frame cache per device.
// Mutable frame state is lock-protected; encoding has its own serial lock.
final class WindowCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let target: DeviceWindow
    private let lock = NSLock()
    private let encodeLock = NSLock()
    private let callbacks = DispatchQueue(label: "Simwisp.capture.samples", qos: .userInteractive)
    private enum Phase { case idle, starting, running, stopping, ended, stopped }
    private var phase = Phase.idle // lock protects native state and delegate callbacks
    private var stream: (any CaptureStream)?
    private let health: CaptureHealth
    private let makeStream: (@MainActor (WindowCapture) async throws -> any CaptureStream)?
    @MainActor private var startTask: Task<Void, Error>?
    @MainActor private var stopTask: Task<Void, Never>?
    private var latest: CVPixelBuffer?
    private var version: UInt64 = 0
    private var encoder: H264Encoder?
    private var encodedVersion: UInt64?
    private var encodedCount: UInt64 = 0
    private var encoderHardware = false
    private var active = true
    private var error: String?
    init(target: DeviceWindow, health: CaptureHealth = .shared, makeStream: (@MainActor (WindowCapture) async throws -> any CaptureStream)? = nil) {
        self.target = target; self.health = health; self.makeStream = makeStream; super.init()
    }
    @MainActor func start() async throws {
        let task: Task<Void, Error>
        if let existing = startTask { task = existing }
        else {
            guard lock.withLock({ active && phase == .idle }) else { throw WispError("Capture cannot be started twice or after stopping") }
            lock.withLock { phase = .starting }
            task = Task { @MainActor in
                do {
                    let newStream: any CaptureStream
                    if let makeStream = self.makeStream { newStream = try await makeStream(self) }
                    else { newStream = try await self.createStream() }
                    self.lock.withLock { self.stream = newStream }
                    self.health.created()
                    guard self.lock.withLock({ self.active }) else { throw WispError("Capture stopped before startup completed") }
                    try await newStream.startCapture()
                    let ready = self.lock.withLock { () -> Bool in
                        // A terminal delegate callback can precede start's
                        // completion; never resurrect that stream as running.
                        if self.phase == .starting { self.phase = .running }
                        return self.active && self.phase == .running
                    }
                    guard ready else { throw WispError(self.failure ?? "Capture stopped during startup") }
                } catch {
                    self.lock.withLock {
                        self.active = false; self.latest = nil
                        // A successfully started stream with a pending stop is
                        // still running and must be stopped by the cleanup task.
                        if self.phase == .starting { self.phase = .ended }
                        if self.error == nil { self.error = error.localizedDescription }
                    }
                    throw error
                }
            }
            startTask = task
        }
        do {
            try await task.value
            guard lock.withLock({ active && phase == .running }) else { throw WispError(failure ?? "Capture stopped during startup") }
            startTask = nil
        } catch {
            // Cleanup waits for the startup task, never from inside that task.
            // This also joins a simultaneous explicit stop instead of racing it.
            await stop(); throw error
        }
    }
    @MainActor private func createStream() async throws -> any CaptureStream {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == target.id }) else { throw WispError("Simulator window is not shareable. Check Screen Recording permission.") }
        let config = SCStreamConfiguration()
        config.width = Int(target.bounds.width); config.height = Int(target.bounds.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA; config.queueDepth = 3
        config.showsCursor = false; config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true; config.shouldBeOpaque = true
        if #available(macOS 14.2, *) { config.includeChildWindows = false }
        let newStream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: callbacks)
        return newStream
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard lock.withLock({ self.stream === stream && active && error == nil }) else { return }
        receive(sampleBuffer, type: type)
    }
    func receive(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        autoreleasepool {
            guard type == .screen, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
                  let infos = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = infos.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
            lock.lock(); defer { lock.unlock() }
            guard active, error == nil else { return }
            if status == .blank || status == .suspended { latest = nil; return }
            guard status == .complete, let image = sampleBuffer.imageBuffer else { return }
            latest = image; version &+= 1
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        captureStopped(stream, error: error)
    }
    func captureStopped(_ stream: any CaptureStream, error: Error) {
        let report = lock.withLock { () -> Bool in
            guard self.stream === stream, phase == .starting || phase == .running || phase == .stopping else { return false }
            let unexpected = active
            phase = .ended; active = false; latest = nil
            if unexpected { self.error = error.localizedDescription }
            return unexpected
        }
        if report { log(diagnostic("stopped", error)) }
    }
    private func diagnostic(_ action: String, _ error: Error) -> String {
        let native = error as NSError
        return "Capture \(target.id) \(action): \(native.localizedDescription) [\(native.domain):\(native.code)]"
    }
    static func alreadyStopped(_ error: Error) -> Bool {
        let native = error as NSError
        return native.domain == SCStreamError.errorDomain && native.code == SCStreamError.Code.attemptToStopStreamState.rawValue
    }
    private func cleanupFailed(_ action: String, _ error: Error) {
        let message = diagnostic(action, error)
        lock.withLock { if self.error == nil { self.error = message } }
        health.cleanupFailed(message); log(message)
    }
    var failure: String? { lock.lock(); defer { lock.unlock() }; return error }
    var hasFrame: Bool { lock.withLock { active && error == nil && latest != nil } }
    var counters: [String: Any] { lock.withLock { ["fresh_capture_frames": version, "h264_encodes": encodedCount, "hardware_encoder": encoderHardware] } }
    func h264(quality: Int, fps: Int, forceKeyframe: Bool, dataSaver: Bool) throws -> H264Frame? {
        encodeLock.lock(); defer { encodeLock.unlock() }
        return try autoreleasepool {
            let state = lock.withLock { () -> (CVPixelBuffer, UInt64)? in
                guard active, error == nil, let latest else { return nil }
                return (latest, version)
            }
            guard let (image, current) = state else { return nil }
            if dataSaver && encodedVersion == current && !forceKeyframe { return nil }
            let ci = CIImage(cvPixelBuffer: image), extent = ci.extent, crop = target.crop
            let sx = extent.width / target.bounds.width, sy = extent.height / target.bounds.height
            let left = max(0, (crop.minX * sx).rounded()), top = max(0, (crop.minY * sy).rounded())
            let right = min(extent.width, (crop.maxX * sx).rounded()), bottom = min(extent.height, (crop.maxY * sy).rounded())
            let roi = CGRect(x: left, y: extent.height - bottom, width: max(1, right - left), height: max(1, bottom - top))
            if encoder?.width != Int(roi.width) || encoder?.height != Int(roi.height) {
                encoder?.close(); encoder = try H264Encoder(width: Int(roi.width), height: Int(roi.height))
            }
            let frame = try encoder!.encode(ci.cropped(to: roi).transformed(by: CGAffineTransform(translationX: -roi.minX, y: -roi.minY)), quality: quality, fps: fps, forceKeyframe: forceKeyframe)
            encodedVersion = current
            lock.withLock { if active { encodedCount &+= 1; encoderHardware = encoder!.hardware } }
            return frame
        }
    }
    @MainActor func stop() async {
        if let existing = stopTask { await existing.value; return }
        guard lock.withLock({ phase != .stopped }) else { return }
        lock.withLock { active = false; latest = nil }
        let starting = startTask
        let task = Task { @MainActor in
            // If discovery/start is still pending, wait for its outcome. A late
            // successful start must be stopped; a failed/unstarted one must not.
            if let starting { _ = await starting.result }
            let state = self.lock.withLock { () -> ((any CaptureStream)?, Bool) in
                let needsStop = self.phase == .running
                if needsStop { self.phase = .stopping }
                return (self.stream, needsStop)
            }
            if let old = state.0 {
                if state.1 {
                    do { try await old.stopCapture() }
                    catch {
                        // The source may disappear between the state check and
                        // the native stop call. Only this specific state error
                        // is benign; unrelated codes/domains remain visible.
                        if !Self.alreadyStopped(error) { self.cleanupFailed("cleanup failed", error) }
                    }
                }
                do { try old.removeStreamOutput(self, type: .screen) }
                catch { self.cleanupFailed("output removal failed", error) }
                self.lock.withLock { self.stream = nil }
                self.health.released()
            }
            self.encodeLock.withLock { self.encoder?.close(); self.encoder = nil; self.encodedVersion = nil }
            self.lock.withLock { self.phase = .stopped }
        }
        stopTask = task
        await task.value
        startTask = nil; stopTask = nil
    }
}
