import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreImage

final class CaptureHealth {
    static let shared = CaptureHealth()
    private let lock = NSLock()
    private var count = 0
    private var fatal: String?
    var snapshot: [String: Any] { lock.withLock { ["active": count, "fatal_error": fatal as Any? ?? NSNull()] } }
    var failure: String? { lock.withLock { fatal } }
    func created() { lock.withLock { count += 1 } }
    func released() { lock.withLock { count = max(0, count - 1) } }
    func failed(_ message: String) { lock.withLock { fatal = message } }
}

// Native capture keeps only the newest complete frame. Encoding is independently
// paced, with one H.264 encoder and no encoded-frame cache per device.
// Mutable frame state is lock-protected; encoding has its own serial lock.
final class WindowCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let target: DeviceWindow
    private let lock = NSLock()
    private let encodeLock = NSLock()
    private let callbacks = DispatchQueue(label: "Simwisp.capture.samples", qos: .userInteractive)
    private var stream: SCStream?
    private var latest: CVPixelBuffer?
    private var version: UInt64 = 0
    private var encoder: H264Encoder?
    private var encodedVersion: UInt64?
    private var encodedCount: UInt64 = 0
    private var encoderHardware = false
    private var active = true
    private var error: String?
    init(target: DeviceWindow) { self.target = target; super.init() }
    func start() async throws {
        if let failure = CaptureHealth.shared.failure { throw WispError(failure) }
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
        lock.withLock { stream = newStream }
        CaptureHealth.shared.created()
        do { try await newStream.startCapture() } catch { await stop(); throw error }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        receive(sampleBuffer, type: type)
    }
    func receive(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        autoreleasepool {
            guard type == .screen, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
                  let infos = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = infos.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
            lock.lock(); defer { lock.unlock() }
            guard active else { return }
            if status == .blank || status == .suspended { latest = nil; return }
            guard status == .complete, let image = sampleBuffer.imageBuffer else { return }
            latest = image; version &+= 1
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); self.error = error.localizedDescription; latest = nil; lock.unlock()
        log("Capture stopped: \(error.localizedDescription)")
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
    func stop() async {
        let old = lock.withLock { () -> SCStream? in active = false; latest = nil; let value = stream; stream = nil; return value }
        if let old {
            do { try await old.stopCapture() }
            catch {
                let message = "Capture cleanup failed; restart Simwisp before starting new streams: \(error.localizedDescription)"
                CaptureHealth.shared.failed(message); log(message)
            }
            try? old.removeStreamOutput(self, type: .screen)
            CaptureHealth.shared.released()
        }
        encodeLock.withLock { encoder?.close(); encoder = nil; encodedVersion = nil }
    }
}
