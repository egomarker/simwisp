import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

// Exercise production WindowCapture start/delegate/stop paths, but never create
// an SCStream, request permission, enumerate devices, or touch simulator windows.
var checks = 0
@MainActor func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    guard condition() else { fatalError("FAIL: " + name) }; checks += 1
}
@MainActor final class Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { open = true; let old = waiters; waiters = []; old.forEach { $0.resume() } }
}
@MainActor final class FakeStream: CaptureStream {
    var starts = 0, stops = 0, removals = 0
    var startError: Error?, stopError: Error?, removeError: Error?
    var startGate: Gate?, stopGate: Gate?
    let startEntered = Gate(), stopEntered = Gate()
    var afterStart: ((FakeStream) -> Void)?, beforeStop: ((FakeStream) -> Void)?
    func startCapture() async throws {
        starts += 1; startEntered.release()
        if let startGate { await startGate.wait() }
        if let startError { throw startError }
        afterStart?(self)
    }
    func stopCapture() async throws {
        stops += 1; stopEntered.release(); beforeStop?(self)
        if let stopGate { await stopGate.wait() }
        if let stopError { throw stopError }
    }
    func removeStreamOutput(_ output: any SCStreamOutput, type: SCStreamOutputType) throws {
        expect(type == .screen, "only screen output detached")
        removals += 1
        if let removeError { throw removeError }
    }
}
func nativeError(_ code: SCStreamError.Code) -> NSError {
    NSError(domain: SCStreamError.errorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: "native fixture"])
}
@MainActor func target(_ id: UInt32 = 123) -> DeviceWindow {
    DeviceWindow(id: id, pid: 0, title: "fixture", bounds: CGRect(x: 0, y: 0, width: 200, height: 120), crop: CGRect(x: 0, y: 0, width: 200, height: 120))
}
@MainActor func fixture(_ health: CaptureHealth, id: UInt32 = 123) -> (WindowCapture, FakeStream) {
    let native = FakeStream()
    let capture = WindowCapture(target: target(id), health: health, makeStream: { _ in native })
    return (capture, native)
}
@MainActor func count(_ health: CaptureHealth) -> Int { health.snapshot["active"] as! Int }
@MainActor func expectStartFailure(_ task: Task<Void, Error>, _ name: String) async {
    do { try await task.value; fatalError("FAIL: " + name) } catch { checks += 1 }
}
@MainActor func sample() -> CMSampleBuffer {
    var image: CVPixelBuffer?, format: CMVideoFormatDescription?, buffer: CMSampleBuffer?
    expect(CVPixelBufferCreate(nil, 200, 120, kCVPixelFormatType_32BGRA, nil, &image) == noErr, "synthetic pixel created")
    expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image!, formatDescriptionOut: &format) == noErr, "synthetic format")
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image!, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &buffer) == noErr, "synthetic sample")
    let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer!, createIfNecessary: true)!
    let info = Unmanaged<NSMutableDictionary>.fromOpaque(CFArrayGetValueAtIndex(attachments, 0)).takeUnretainedValue()
    info[SCStreamFrameInfo.status.rawValue] = SCFrameStatus.complete.rawValue
    return buffer!
}
@MainActor func run() async throws {
    let frame = sample()
    expect(WindowCapture.alreadyStopped(nativeError(.attemptToStopStreamState)), "specific stop-state error recognized")
    expect(!WindowCapture.alreadyStopped(nativeError(.internalError)), "other SCK code not suppressed")
    expect(!WindowCapture.alreadyStopped(NSError(domain: "OtherDomain", code: SCStreamError.Code.attemptToStopStreamState.rawValue)), "same code in other domain not suppressed")
    expect(!WindowCapture.alreadyStopped(nativeError(.noCaptureSource)), "no-source code not blindly suppressed in stop operation")

    // Healthy capture + explicit close. Overlapping closes join the same native
    // stop and cannot report completion before output removal/accounting finish.
    do {
        let health = CaptureHealth(), (capture, native) = fixture(health)
        try await capture.start(); capture.receive(frame, type: .screen)
        expect(native.starts == 1 && count(health) == 1 && capture.hasFrame, "successful startup/frame")
        native.stopGate = Gate()
        let first = Task { @MainActor in await capture.stop() }
        await native.stopEntered.wait()
        var secondFinished = false
        let secondEntered = Gate()
        let second = Task { @MainActor in secondEntered.release(); await capture.stop(); secondFinished = true }
        await secondEntered.wait()
        expect(!secondFinished && native.stops == 1 && native.removals == 0, "duplicate stop awaits pending native stop")
        expect(!capture.hasFrame && count(health) == 1, "frames disabled before native stop settles")
        native.stopGate!.release(); await first.value; await second.value
        expect(secondFinished && native.stops == 1 && native.removals == 1 && count(health) == 0, "exactly-once shared cleanup")
        let version = capture.counters["fresh_capture_frames"] as! UInt64
        capture.receive(frame, type: .screen); await capture.stop()
        expect(!capture.hasFrame && capture.counters["fresh_capture_frames"] as! UInt64 == version, "late frame rejected after close")
        expect(native.stops == 1 && native.removals == 1, "completed stop remains idempotent")
        await expectStartFailure(Task { @MainActor in try await capture.start() }, "closed capture cannot restart itself")
        expect(native.starts == 1 && count(health) == 0, "no duplicate startup after close")
    }

    // Closing A's native window must not poison B or a fresh replacement A.
    do {
        let health = CaptureHealth(), (a, nativeA) = fixture(health, id: 1), (b, nativeB) = fixture(health, id: 2)
        try await a.start(); try await b.start(); a.receive(frame, type: .screen); b.receive(frame, type: .screen)
        let version = a.counters["fresh_capture_frames"] as! UInt64
        a.captureStopped(nativeA, error: nativeError(.noCaptureSource)); a.receive(frame, type: .screen)
        expect(a.failure != nil && !a.hasFrame && a.counters["fresh_capture_frames"] as! UInt64 == version, "terminal delegate rejects late samples")
        await a.stop()
        expect(nativeA.stops == 0 && nativeA.removals == 1 && count(health) == 1, "already-terminal stream is detached without native re-stop")
        expect(b.hasFrame && b.failure == nil && nativeB.stops == 0, "other simulator remains streaming")
        expect(health.snapshot["fatal_error"] is NSNull && health.snapshot["last_cleanup_error"] is NSNull, "terminal event creates no global lockout")
        let (reopened, replacement) = fixture(health, id: 1)
        try await reopened.start(); reopened.receive(frame, type: .screen)
        expect(replacement.starts == 1 && reopened.hasFrame && count(health) == 2, "closed simulator can reopen")
        await reopened.stop(); await b.stop()
        expect(count(health) == 0, "all two-device resources released")
    }

    // Native state may disappear after our running-state check but before stop.
    // Only the exact native stop-state error is benign.
    do {
        let health = CaptureHealth(), (capture, native) = fixture(health)
        native.stopError = nativeError(.attemptToStopStreamState)
        try await capture.start(); await capture.stop()
        expect(native.stops == 1 && native.removals == 1 && count(health) == 0, "native stop-state race still finishes cleanup")
        expect(capture.failure == nil && health.snapshot["last_cleanup_error"] is NSNull, "benign race not reported as fatal/error")
    }
    for error in [nativeError(.internalError), nativeError(.noCaptureSource), NSError(domain: "OtherDomain", code: SCStreamError.Code.attemptToStopStreamState.rawValue)] {
        let health = CaptureHealth(), (capture, native) = fixture(health)
        native.stopError = error
        try await capture.start(); await capture.stop()
        let message = health.snapshot["last_cleanup_error"] as? String
        expect(message?.contains(error.domain) == true && message?.contains(String(error.code)) == true, "genuine cleanup diagnostics keep domain/code")
        expect(capture.failure != nil && native.removals == 1 && count(health) == 0, "genuine stop error still detaches/releases once")
        expect(health.snapshot["fatal_error"] is NSNull, "genuine local error does not latch global fatal")
        let (next, nextNative) = fixture(health, id: 456)
        try await next.start()
        expect(nextNative.starts == 1 && next.failure == nil && count(health) == 1, "new unrelated capture admitted after local failure")
        await next.stop()
        expect(count(health) == 0, "subsequent healthy cleanup balanced")
    }
    do {
        let health = CaptureHealth(), (capture, native) = fixture(health)
        native.removeError = nativeError(.removingStream)
        try await capture.start(); await capture.stop(); await capture.stop()
        expect(native.stops == 1 && native.removals == 1 && count(health) == 0, "output removal failure is not retried/double-counted")
        expect((health.snapshot["last_cleanup_error"] as? String)?.contains("output removal failed") == true, "output removal failures remain visible")
    }

    // Failed start and terminal callback during startup must not receive a stop
    // call. A terminal callback cannot be undone by a late successful completion.
    do {
        let health = CaptureHealth(), (capture, native) = fixture(health)
        native.startError = nativeError(.failedToStart)
        await expectStartFailure(Task { @MainActor in try await capture.start() }, "native start failure propagated")
        expect(native.starts == 1 && native.stops == 0 && native.removals == 1 && count(health) == 0, "failed start only detaches output")
        expect(capture.failure != nil && health.snapshot["last_cleanup_error"] is NSNull, "original start error retained without cleanup escalation")
        let (next, _) = fixture(health); try await next.start(); await next.stop()
        expect(count(health) == 0, "failed startup does not poison future captures")
    }
    do {
        let health = CaptureHealth(), (capture, native) = fixture(health)
        native.afterStart = { [weak capture] native in capture?.captureStopped(native, error: nativeError(.noCaptureSource)) }
        await expectStartFailure(Task { @MainActor in try await capture.start() }, "terminal callback before successful completion propagates")
        expect(native.stops == 0 && native.removals == 1 && count(health) == 0 && !capture.hasFrame, "late successful completion cannot resurrect terminal stream")
    }

    // Stop during startup: await startup, then stop exactly once only if it did
    // become running. Both the starter and all stoppers await full cleanup.
    for failStartup in [false, true] {
        let health = CaptureHealth(), (capture, native) = fixture(health)
        native.startGate = Gate()
        if failStartup { native.startError = nativeError(.failedToStart) }
        let start = Task { @MainActor in try await capture.start() }
        await native.startEntered.wait()
        let entered = Gate()
        var stopped = false
        let stop = Task { @MainActor in entered.release(); await capture.stop(); stopped = true }
        await entered.wait()
        expect(!stopped && native.stops == 0 && native.removals == 0, "pending startup is awaited, not raced")
        native.startGate!.release()
        await expectStartFailure(start, "stop during startup prevents usable start")
        await stop.value
        expect(stopped && native.stops == (failStartup ? 0 : 1) && native.removals == 1 && count(health) == 0, "startup/stop outcome handled once")
    }
    do {
        let health = CaptureHealth(), native = FakeStream(), resolving = Gate(), entered = Gate()
        let capture = WindowCapture(target: target(), health: health, makeStream: { _ in entered.release(); await resolving.wait(); return native })
        let start = Task { @MainActor in try await capture.start() }
        await entered.wait()
        let stopEntered = Gate()
        let stop = Task { @MainActor in stopEntered.release(); await capture.stop() }
        await stopEntered.wait()
        expect(count(health) == 0 && native.starts == 0, "stop during discovery does not prematurely start capture")
        resolving.release()
        await expectStartFailure(start, "stop during discovery propagated")
        await stop.value
        expect(native.starts == 0 && native.stops == 0 && native.removals == 1 && count(health) == 0, "late prepared stream only detaches")
    }
    do {
        let health = CaptureHealth()
        let capture = WindowCapture(target: target(), health: health, makeStream: { _ in throw nativeError(.noCaptureSource) })
        await expectStartFailure(Task { @MainActor in try await capture.start() }, "discovery/output-registration failure propagated")
        await capture.stop()
        expect(count(health) == 0 && capture.failure != nil, "pre-stream failure owns no counted stream")
    }

    // Ignore callbacks from an unrelated/detached stream. Callback during an
    // explicit native stop records terminal state, not a new capture failure.
    do {
        let health = CaptureHealth(), (capture, native) = fixture(health), other = FakeStream()
        try await capture.start(); capture.receive(frame, type: .screen)
        capture.captureStopped(other, error: nativeError(.internalError))
        expect(capture.failure == nil && capture.hasFrame, "foreign stream callback ignored")
        native.beforeStop = { [weak capture] native in capture?.captureStopped(native, error: nativeError(.userStopped)) }
        await capture.stop()
        capture.captureStopped(native, error: nativeError(.internalError))
        expect(capture.failure == nil && native.stops == 1 && native.removals == 1 && count(health) == 0, "intentional/detached callbacks do not replace state")
    }
    do {
        let health = CaptureHealth(), (capture, native) = fixture(health)
        native.startGate = Gate()
        let first = Task { @MainActor in try await capture.start() }
        await native.startEntered.wait()
        let secondEntered = Gate()
        let second = Task { @MainActor in secondEntered.release(); try await capture.start() }
        await secondEntered.wait()
        native.startGate!.release(); try await first.value; try await second.value
        expect(native.starts == 1 && count(health) == 1, "concurrent starters share native startup")
        await expectStartFailure(Task { @MainActor in try await capture.start() }, "already-running capture rejects a second startup")
        await capture.stop()
        expect(native.removals == 1 && count(health) == 0, "shared startup owns only one cleanup")
    }
    do {
        let health = CaptureHealth(), (capture, native) = fixture(health)
        await capture.stop(); await capture.stop()
        await expectStartFailure(Task { @MainActor in try await capture.start() }, "stop-before-start prevents late startup")
        expect(native.starts == 0 && native.stops == 0 && native.removals == 0 && count(health) == 0, "stop-before-start owns no stream")
    }
    expect(CaptureHealth.shared.snapshot["active"] as? Int == 0, "no production/native capture stream created")
}
Task { @MainActor in
    do {
        try await run()
        let result: [String: Any] = ["checks": checks, "passed": true, "native_sck_sessions": 0, "fixture": "actual WindowCapture lifecycle with fake CaptureStream operations"]
        if let output = ProcessInfo.processInfo.environment["TEST_OUTPUT"], !output.isEmpty {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("capture-lifecycle-review.json"))
        }
        print("PASS: \(checks) capture lifecycle assertions; no native ScreenCaptureKit sessions")
        exit(0)
    } catch {
        fputs("FAIL: \(error)\n", stderr); exit(1)
    }
}
RunLoop.main.run()
