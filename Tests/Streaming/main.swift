import Foundation

var checks = 0
func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    guard condition() else { fatalError("FAIL " + name) }
    checks += 1
}
func report(_ epoch: UInt32, _ id: UInt32, pending: Int = 0, queue: Int = 0, age: Double = 0) -> StreamFeedback {
    StreamFeedback(["epoch": epoch, "frame_id": id, "pending_frames": pending, "decode_queue": queue, "oldest_pending_ms": age])!
}

// A deterministic packet/feedback timeline with 40, 100 and 400ms round trips.
// Native frame deadlines continue at 60fps; no individual frame ACK exists.
for rtt in [0.04, 0.1, 0.4] {
    var flow = StreamFlow(fps: 60, quality: 20)
    var frame: UInt32 = 0, delivered: UInt32 = 0
    var transit: [(Double, UInt32)] = [], telemetry: [(Double, UInt32)] = []
    var nextReport = 0.25, sendTimes: [Double] = []
    for tick in 0..<3000 {
        let now = Double(tick) / 1000
        while let first = transit.first, first.0 <= now { delivered = first.1; transit.removeFirst() }
        if now >= nextReport {
            if delivered > 0 { telemetry.append((now + rtt / 2, delivered)) }
            nextReport += 0.25
        }
        while let first = telemetry.first, first.0 <= now {
            check("known cumulative receipt accepted", flow.feedback(report(1, first.1), currentEpoch: 1, now: now))
            telemetry.removeFirst()
        }
        if flow.beginFrame(now: now) {
            frame &+= 1
            check("paced frame fits budget", flow.recordSend(epoch: 1, id: frame, bytes: 1000, now: now))
            transit.append((now + rtt / 2, frame)); sendTimes.append(now)
        }
        check("transport metadata bounded", flow.count <= StreamFlow.maxFrames && flow.bytes <= StreamFlow.maxBytes)
        check("RTT is not considered a decoder backlog", flow.fps == 60 && flow.quality == 20)
    }
    check("60fps target progresses independently of RTT", frame >= 175 && frame <= 180)
    check("no catch-up bursts", zip(sendTimes, sendTimes.dropFirst()).allSatisfy { $1 - $0 >= 1.0 / 60 - 0.000001 })
}
var flow = StreamFlow(fps: 60, quality: 20)
check("first capture deadline ready", flow.beginFrame(now: 0))
check("early duplicate deadline rejected", !flow.beginFrame(now: 0.001))
check("late capture allowed", flow.beginFrame(now: 2))
check("missed intervals not replayed", !flow.beginFrame(now: 2))
for n in 1...StreamFlow.maxFrames { check("no-feedback bounded admissions", flow.recordSend(epoch: 1, id: UInt32(n), bytes: 1000, now: Double(n) / 60)) }
check("no feedback stops at finite frame budget", !flow.hasCapacity && !flow.recordSend(epoch: 1, id: 121, bytes: 1000, now: 2))
check("no premature transport timeout", !flow.unresponsive(now: 2.5))
check("undelivered TCP backlog eventually times out", flow.unresponsive(now: 3.1))
check("forged future receipt ignored", !flow.feedback(report(1, 999), currentEpoch: 1, now: 2.1))
check("wrong epoch receipt ignored", !flow.feedback(report(2, 120), currentEpoch: 2, now: 2.1))
check("real receipt frees cumulative budget", flow.feedback(report(1, 60), currentEpoch: 1, now: 2.1))
check("only acknowledged prefix removed", flow.count == 60 && flow.bytes == 60_000 && flow.hasCapacity)
check("backwards receipt cannot remove newer sends", !flow.feedback(report(1, 59), currentEpoch: 1, now: 2.2))
check("idle duplicate receipt remains valid", flow.feedback(report(1, 60), currentEpoch: 1, now: 2.3))
check("old epoch receipt drains but cannot throttle replacement", flow.feedback(report(1, 120, pending: 48, queue: 16, age: 2000), currentEpoch: 2, now: 2.4) && flow.fps == 60 && flow.count == 0)
check("receipt removes transport timeout on idle Data saver", !flow.unresponsive(now: 100))
check("wrapped frame id accepted exactly", flow.recordSend(epoch: 2, id: UInt32.max, bytes: 1000, now: 100) && flow.recordSend(epoch: 2, id: 0, bytes: 1000, now: 100.02))
check("wrap receipt retires proper ordered prefix", flow.feedback(report(2, 0), currentEpoch: 2, now: 100.25) && flow.count == 0)
check("current decoder overload reduces pacing", flow.feedback(report(2, 0, pending: 12, queue: 8, age: 300), currentEpoch: 2, now: 101) && flow.fps == 48 && flow.quality == 17)
check("overload adaptation rate limited", flow.feedback(report(2, 0, pending: 12, queue: 8, age: 300), currentEpoch: 2, now: 101.2) && flow.fps == 48)
_ = flow.feedback(report(2, 0), currentEpoch: 2, now: 102)
_ = flow.feedback(report(2, 0), currentEpoch: 2, now: 104.9)
check("healthy recovery requires sustained feedback", flow.fps == 48)
_ = flow.feedback(report(2, 0), currentEpoch: 2, now: 105)
check("healthy pacing recovers gradually", flow.fps == 50 && flow.quality == 18)
flow.settings(fps: 10, quality: 8, now: 106)
flow.congested(now: 107)
for n in 0..<20 { _ = flow.feedback(report(2, 0), currentEpoch: 2, now: 110 + Double(n)) }
check("adaptation never exceeds user targets", flow.fps == 10 && flow.quality == 8)
flow.settings(fps: 0, quality: 1000, now: 140)
check("user targets clamped", flow.fps == 1 && flow.quality == 95)
var bytes = StreamFlow(fps: 60, quality: 20)
check("first budget frame accepted", bytes.recordSend(epoch: 1, id: 1, bytes: StreamFlow.maxBytes, now: 0))
check("byte budget bounds even tiny subsequent frames", !bytes.hasCapacity && !bytes.canSend(bytes: 1))
bytes.deferSend(bytes: 2_000_000, now: 0)
check("old epoch debt survives recovery", !bytes.beginFrame(now: 1) && bytes.count == 1)
check("draining old receipt enables oversized fresh IDR alone", bytes.feedback(report(1, 1), currentEpoch: 2, now: 1) && bytes.canSend(bytes: 2_000_000))
check("single oversized IDR admitted", bytes.recordSend(epoch: 2, id: 2, bytes: 2_000_000, now: 1))
check("oversized IDR excludes following sends", !bytes.hasCapacity && !bytes.canSend(bytes: 1))
check("hard packet cap enforced", !StreamFlow(fps: 60, quality: 20).canSend(bytes: 16_000_025))
let valid: [String: Any] = ["epoch": 1, "frame_id": 2, "pending_frames": 0, "decode_queue": 0, "oldest_pending_ms": 0]
check("valid feedback parses", StreamFeedback(valid) != nil)
let timing: [String: Any] = [
    "decoded_outputs": 12, "rendered_frames": 10, "dropped_frames": 2, "latest_frame_drops": 2, "raf_callbacks": 10,
    "sample_ms": 1001.5, "decoded_output_fps": 11.98, "rendered_fps": 9.99, "dropped_fps": 2.0,
    "latest_drop_fps": 2.0, "raf_fps": 9.99, "receive_to_output_ms": 3.2, "output_to_render_ms": 7.4,
    "receive_to_render_ms": 10.6, "output_age_ms": 4.0, "render_age_ms": 8.0, "raf_age_ms": 8.0,
]
var timedValue = valid; timedValue["client_timing"] = timing
let timed = StreamFeedback(timedValue)
check("client rendering timing parses", timed?.clientTiming?.decodedOutputs == 12 && timed?.clientTiming?.renderedFPS == 9.99)
var timingFlow = StreamFlow(fps: 60, quality: 20)
check("timed receipt has a matching sent frame", timingFlow.recordSend(epoch: 1, id: 2, bytes: 1000, now: 0))
check("current epoch stores passive client rendering timing", timingFlow.feedback(timed!, currentEpoch: 1, now: 0.1) && timingFlow.receiverTiming?.latestFrameDrops == 2)
check("client rendering timing is snapshot ready", timingFlow.receiverTiming?.snapshot["receive_to_render_ms"] as? Double == 10.6)
var staleTiming = timing; staleTiming["decoded_outputs"] = 99; staleTiming["rendered_frames"] = 90; staleTiming["raf_callbacks"] = 90
var staleValue = valid; staleValue["client_timing"] = staleTiming
let staleTimingFeedback = StreamFeedback(staleValue)
check("old epoch receipt cannot replace current decoder timing", timingFlow.feedback(staleTimingFeedback!, currentEpoch: 2, now: 0.2) && timingFlow.receiverTiming?.decodedOutputs == 12)
var nullableTiming = timing
nullableTiming["receive_to_output_ms"] = NSNull(); nullableTiming["output_to_render_ms"] = NSNull()
nullableTiming["receive_to_render_ms"] = NSNull(); nullableTiming["output_age_ms"] = NSNull()
nullableTiming["render_age_ms"] = NSNull(); nullableTiming["raf_age_ms"] = NSNull()
var nullableValue = valid; nullableValue["client_timing"] = nullableTiming
let nullableFeedback = StreamFeedback(nullableValue)
check("unavailable client latency remains valid and unknown", nullableFeedback != nil && nullableFeedback!.clientTiming!.receiveToRenderMS == nil)
let nullableSnapshot = nullableFeedback!.clientTiming!.snapshot
check("unavailable client timing snapshots as explicit nulls", nullableSnapshot["receive_to_output_ms"] is NSNull && nullableSnapshot["receive_to_render_ms"] is NSNull && nullableSnapshot["raf_age_ms"] is NSNull)
for (key, bad) in [
    ("decoded_outputs", true as Any), ("rendered_frames", -1), ("sample_ms", Double.infinity),
    ("decoded_output_fps", 1001), ("receive_to_output_ms", "3.2"), ("raf_age_ms", -0.1),
] {
    var invalidTiming = timing; invalidTiming[key] = bad
    var invalidValue = valid; invalidValue["client_timing"] = invalidTiming
    check("invalid client timing rejected: \(key)", StreamFeedback(invalidValue) == nil)
}
var impossibleTiming = timing; impossibleTiming["rendered_frames"] = 13
var impossibleValue = valid; impossibleValue["client_timing"] = impossibleTiming
check("impossible rendered/output counters rejected", StreamFeedback(impossibleValue) == nil)
var malformedTiming = valid; malformedTiming["client_timing"] = "not telemetry"
check("malformed client timing rejected", StreamFeedback(malformedTiming) == nil)
for (key, bad) in [("epoch", -1 as Any), ("epoch", 4_294_967_296), ("frame_id", 1.5), ("frame_id", true), ("pending_frames", 49), ("decode_queue", 17), ("oldest_pending_ms", Double.infinity), ("oldest_pending_ms", -0.1), ("oldest_pending_ms", "10")] {
    var value = valid; value[key] = bad
    check("invalid telemetry rejected: \(key)", StreamFeedback(value) == nil)
}
var missing = valid; missing.removeValue(forKey: "frame_id")
check("incomplete telemetry rejected", StreamFeedback(missing) == nil)
let result: [String: Any] = ["passed": true, "checks": checks, "simulated_rtt_ms": [40,100,400], "real_network": false, "real_capture": false, "real_input": false]
if let output = ProcessInfo.processInfo.environment["TEST_OUTPUT"] {
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: output + "/stream-flow-review.json"))
}
print("\(checks) independent streaming pacing/feedback checks passed")
