import Foundation
import CoreFoundation

// Cumulative receiver telemetry, not a per-frame permission to send.
struct StreamFeedback {
    let epoch: UInt32, frameID: UInt32
    let pending: Int, decodeQueue: Int
    let oldestMS: Double
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
