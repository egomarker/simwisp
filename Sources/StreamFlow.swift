import Foundation
import CoreFoundation

struct StreamClientTiming {
    let decodedOutputs, renderedFrames, droppedFrames, latestFrameDrops, rafCallbacks: Int
    let sampleMS, decodedOutputFPS, renderedFPS, droppedFPS, latestDropFPS, rafFPS: Double
    let receiveToOutputMS, outputToRenderMS, receiveToRenderMS: Double?
    let outputAgeMS, renderAgeMS, rafAgeMS: Double?

    init?(_ value: [String: Any]) {
        func number(_ key: String, _ maximum: Double, integer: Bool = false) -> Double? {
            guard let n = value[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let d = n.doubleValue
            guard d.isFinite, d >= 0, d <= maximum, !integer || d.rounded(.down) == d else { return nil }
            return d
        }
        func optionalNumber(_ key: String, _ maximum: Double) -> (valid: Bool, value: Double?) {
            guard let raw = value[key] else { return (true, nil) }
            if raw is NSNull { return (true, nil) }
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return (false, nil) }
            let d = n.doubleValue
            guard d.isFinite, d >= 0, d <= maximum else { return (false, nil) }
            return (true, d)
        }
        let maxCounter = 9_007_199_254_740_991.0
        guard let outputs = number("decoded_outputs", maxCounter, integer: true),
              let rendered = number("rendered_frames", maxCounter, integer: true),
              let dropped = number("dropped_frames", maxCounter, integer: true),
              let latestDrops = number("latest_frame_drops", maxCounter, integer: true),
              let rafs = number("raf_callbacks", maxCounter, integer: true),
              let sample = number("sample_ms", 60_000),
              let outputFPS = number("decoded_output_fps", 1_000),
              let renderedFPS = number("rendered_fps", 1_000),
              let droppedFPS = number("dropped_fps", 1_000),
              let latestDropFPS = number("latest_drop_fps", 1_000),
              let rafFPS = number("raf_fps", 1_000) else { return nil }
        let decode = optionalNumber("receive_to_output_ms", 60_000)
        let present = optionalNumber("output_to_render_ms", 60_000)
        let pipeline = optionalNumber("receive_to_render_ms", 60_000)
        let outputAge = optionalNumber("output_age_ms", 60_000)
        let renderAge = optionalNumber("render_age_ms", 60_000)
        let rafAge = optionalNumber("raf_age_ms", 60_000)
        guard decode.valid, present.valid, pipeline.valid, outputAge.valid, renderAge.valid, rafAge.valid else { return nil }
        decodedOutputs = Int(outputs); renderedFrames = Int(rendered); droppedFrames = Int(dropped)
        latestFrameDrops = Int(latestDrops); rafCallbacks = Int(rafs)
        guard renderedFrames <= decodedOutputs, latestFrameDrops <= droppedFrames, renderedFrames <= rafCallbacks else { return nil }
        sampleMS = sample; decodedOutputFPS = outputFPS; self.renderedFPS = renderedFPS
        self.droppedFPS = droppedFPS; self.latestDropFPS = latestDropFPS; self.rafFPS = rafFPS
        receiveToOutputMS = decode.value; outputToRenderMS = present.value; receiveToRenderMS = pipeline.value
        outputAgeMS = outputAge.value; renderAgeMS = renderAge.value; rafAgeMS = rafAge.value
    }

    var snapshot: [String: Any] {
        func nullable(_ value: Double?) -> Any { value.map { $0 as Any } ?? NSNull() }
        return [
            "decoded_outputs": decodedOutputs, "rendered_frames": renderedFrames, "dropped_frames": droppedFrames,
            "latest_frame_drops": latestFrameDrops, "raf_callbacks": rafCallbacks, "sample_ms": sampleMS,
            "decoded_output_fps": decodedOutputFPS, "rendered_fps": renderedFPS, "dropped_fps": droppedFPS,
            "latest_drop_fps": latestDropFPS, "raf_fps": rafFPS,
            "receive_to_output_ms": nullable(receiveToOutputMS), "output_to_render_ms": nullable(outputToRenderMS),
            "receive_to_render_ms": nullable(receiveToRenderMS), "output_age_ms": nullable(outputAgeMS),
            "render_age_ms": nullable(renderAgeMS), "raf_age_ms": nullable(rafAgeMS),
        ]
    }
}

// Cumulative receiver telemetry, not a per-frame permission to send.
struct StreamFeedback {
    let epoch: UInt32, frameID: UInt32
    let pending: Int, decodeQueue: Int
    let oldestMS: Double
    let clientTiming: StreamClientTiming?
    init?(_ value: [String: Any]) {
        func number(_ key: String, _ maximum: Double, integer: Bool = true) -> Double? {
            guard let n = value[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let d = n.doubleValue
            guard d.isFinite, d >= 0, d <= maximum, !integer || d.rounded(.down) == d else { return nil }
            return d
        }
        guard let e = number("epoch", Double(UInt32.max)), let id = number("frame_id", Double(UInt32.max)),
              let p = number("pending_frames", 48), let q = number("decode_queue", 16),
              let ms = number("oldest_pending_ms", 60_000, integer: false) else { return nil }
        epoch = UInt32(e); frameID = UInt32(id); pending = Int(p); decodeQueue = Int(q); oldestMS = ms
        if let rawTiming = value["client_timing"] {
            guard let object = rawTiming as? [String: Any], let timing = StreamClientTiming(object) else { return nil }
            clientTiming = timing
        } else {
            clientTiming = nil
        }
    }
}

// Pure, clock-driven policy shared by the real stream and isolated tests.
// Only tiny send metadata is retained; never an encoded frame queue.
struct StreamFlow {
    static let maxFrames = 120
    static let maxBytes = 1_048_576
    static let receiptTimeout = 3.0
    private struct Sent { let epoch: UInt32, id: UInt32, bytes: Int, at: Double }
    private var sent: [Sent] = []
    private var receipt: (UInt32, UInt32)?
    private var requiredBytes = 1
    private var lastAdjustment = -Double.infinity
    private var healthySince: Double?
    private var adaptiveEpoch: UInt32?
    private(set) var bytes = 0
    private(set) var nextFrame = 0.0
    private(set) var fps: Int, quality: Int
    private(set) var targetFPS: Int, targetQuality: Int
    private(set) var lastFeedbackAt: Double?
    private(set) var receiverPending = 0, receiverQueue = 0
    private(set) var receiverOldestMS = 0.0
    private(set) var receiverTiming: StreamClientTiming?
    var count: Int { sent.count }
    var hasCapacity: Bool { count < Self.maxFrames && canSend(bytes: requiredBytes) }
    init(fps: Int, quality: Int) {
        self.fps = min(60, max(1, fps)); targetFPS = self.fps
        self.quality = min(95, max(1, quality)); targetQuality = self.quality
    }
    mutating func settings(fps: Int? = nil, quality: Int? = nil, now: Double) {
        if let fps { targetFPS = min(60, max(1, fps)); self.fps = targetFPS }
        if let quality { targetQuality = min(95, max(1, quality)); self.quality = targetQuality }
        healthySince = nil; nextFrame = min(nextFrame, now + 1 / Double(self.fps))
    }
    mutating func beginFrame(now: Double) -> Bool {
        guard now >= nextFrame, hasCapacity else { return false }
        // Missed deadlines are skipped, never replayed in a catch-up burst.
        nextFrame = now + 1 / Double(fps)
        return true
    }
    func canSend(bytes: Int) -> Bool {
        // An oversized IDR may travel alone, within the transport's hard cap.
        bytes > 0 && bytes <= 16_000_024 && count < Self.maxFrames && (sent.isEmpty || self.bytes + bytes <= Self.maxBytes)
    }
    mutating func recordSend(epoch: UInt32, id: UInt32, bytes: Int, now: Double) -> Bool {
        guard canSend(bytes: bytes) else { return false }
        sent.append(Sent(epoch: epoch, id: id, bytes: bytes, at: now)); self.bytes += bytes
        requiredBytes = 1
        return true
    }
    mutating func deferSend(bytes: Int, now: Double) {
        requiredBytes = bytes; congested(now: now)
    }
    func unresponsive(now: Double) -> Bool {
        sent.first.map { now - $0.at > Self.receiptTimeout } ?? false
    }
    mutating func congested(now: Double) {
        healthySince = nil
        guard now - lastAdjustment >= 1 else { return }
        lastAdjustment = now
        fps = max(1, min(targetFPS, Int(Double(fps) * 0.8)))
        quality = max(1, min(targetQuality, quality - 3))
    }
    mutating func feedback(_ report: StreamFeedback, currentEpoch: UInt32, now: Double) -> Bool {
        if let index = sent.firstIndex(where: { $0.epoch == report.epoch && $0.id == report.frameID }) {
            for item in sent[...index] { bytes -= item.bytes }
            sent.removeFirst(index + 1); receipt = (report.epoch, report.frameID)
        } else if receipt?.0 != report.epoch || receipt?.1 != report.frameID { return false }
        lastFeedbackAt = now
        // Old epochs can drain transport debt, but cannot tune a new decoder.
        guard report.epoch == currentEpoch else { return true }
        receiverTiming = report.clientTiming
        if adaptiveEpoch != currentEpoch { adaptiveEpoch = currentEpoch; healthySince = nil }
        receiverPending = report.pending; receiverQueue = report.decodeQueue; receiverOldestMS = report.oldestMS
        if report.decodeQueue >= 8 || (report.pending >= 8 && report.oldestMS > 250) {
            congested(now: now)
        } else if report.decodeQueue <= 2 && report.pending <= 4 && report.oldestMS < 150 {
            if healthySince == nil { healthySince = now }
            if now - healthySince! >= 3 && now - lastAdjustment >= 1 && (fps < targetFPS || quality < targetQuality) {
                lastAdjustment = now; fps = min(targetFPS, fps + 2); quality = min(targetQuality, quality + 1)
            }
        } else { healthySince = nil }
        return true
    }
}
