import Foundation
import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreImage
import Darwin
import IOSurface

// Production Service/StreamSession/WindowCapture, but every destructive effect,
// discovery source and SCK stream is inert. Only the owned TLS fixture is served.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let a = "00000000-0000-4000-8000-000000000001", b = "00000000-0000-4000-8000-000000000002"
let ids = [a, b, "emulator-5554", "emulator-5556"]
final class Latch {
    private let lock = NSLock()
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { c in lock.withLock { if open { c.resume() } else { waiters.append(c) } } } }
    func release() { let old = lock.withLock { () -> [CheckedContinuation<Void, Never>] in open = true; let old = waiters; waiters = []; return old }; old.forEach { $0.resume() } }
}
final class World {
    private let lock = NSLock()
    var states: [String: String] = [:], refs: [SimulatorWindowRef] = []
    var events: [[String: Any]] = [], commands: [[String]] = []
    var failShutdown = false, failClose = false, shutdownHolds: [String: DispatchSemaphore] = [:], gates: [String: Latch] = [:]
    let names = [a: "iPhone 11", b: "iPhone SE", "emulator-5554": "Pixel 6 API 36", "emulator-5556": "Pixel second emulator"]
    var quits = 0
    private var headlessIDs = Set<String>()
    private var failBoot = false, nativeFailure = false, failHeadlessControl = false
    private var nativeHolds: [String: DispatchSemaphore] = [:]
    private var nativeInactive = Set<String>(), nativeLandscape = Set<String>(), nativeCleanupFailure = Set<String>()
    private var adbTime = 0.0, adbDelay = 0.0
    private var pendingADB: [String: Double] = [:]
    private var failADBList = false, malformedADBList = false, failADBKill = false, failSims = false
    var clock: Double { lock.withLock { adbTime } }
    func wait(_ seconds: Double) { lock.withLock { adbTime += seconds } }
    var listFails: Bool { lock.withLock { failSims } }
    let launches = DeviceLaunches()
    func reset(_ single: Bool) {
        lock.withLock {
            states = [a: "Booted", b: single ? "Shutdown" : "Booted", "emulator-5554": single ? "Shutdown" : "Booted", "emulator-5556": single ? "Shutdown" : "Booted"]
            refs = [window(a)] + (single ? [] : [window(b)])
            events = []; commands = []; headlessIDs = []; failBoot = false; nativeFailure = false; failHeadlessControl = false; nativeHolds = [:]; nativeInactive = []; nativeLandscape = []; nativeCleanupFailure = []; failShutdown = false; failClose = false; quits = 0
            adbTime = 0; adbDelay = 0; pendingADB = [:]; failADBList = false; malformedADBList = false; failADBKill = false; failSims = false
        }
    }
    func window(_ id: String) -> SimulatorWindowRef { SimulatorWindowRef(id: id == a ? 1001 : 1002, pid: 901, title: names[id]! + " — iOS fixture", bounds: CGRect(x: 0, y: 0, width: 320, height: 640)) }
    func record(_ event: String, _ id: String) { lock.withLock { events.append(["event": event, "id": id]) } }
    func gate(_ type: String, _ id: String) -> Latch? { lock.withLock { gates[type + ":" + id] } }
    var nativeFails: Bool { lock.withLock { nativeFailure } }
    func nativeCleanupFails(_ id: String) -> Bool { lock.withLock {nativeCleanupFailure.contains(id)} }
    func nativeDisplay(_ id: String) -> (Bool,Bool) { lock.withLock { (!nativeInactive.contains(id),nativeLandscape.contains(id)) } }
    func waitNative(_ id: String, closing: Bool = false) throws {
        let key=closing ? "close:"+id:id
        if let held=lock.withLock({nativeHolds[key]}),held.wait(timeout:.now()+12) != .success {throw WispError("Inert Native input gate timeout")}
    }
    func recordNative(_ kind: String, _ id: String, _ instance: String, _ event: NativeHIDEvent? = nil) {
        var record: [String:Any] = ["event":"native_"+kind,"id":id,"instance":instance]
        if let event {switch event {
        case .touch(let touch): record["phase"]=String(describing:touch.phase);record["identifier"]=touch.identifier;record["x"]=Double(touch.point.x);record["y"]=Double(touch.point.y);record["edge"]=touch.edge.rawValue
        case .key(let usage,let down):record["usage"]=usage;record["down"]=down
        case .home(let down):record["button"]="home";record["down"]=down
        }}
        lock.withLock {events.append(record)}
    }
    func headlessControl(_ action: String, _ id: String, _ geometry: NativeInputGeometry, _ admission: () throws -> Void) throws {
        try admission();record("headless_begin_"+action,id)
        try waitNative(id);try admission()
        try lock.withLock {
            guard headlessIDs.contains(id),states[id]=="Booted",id==a || id==b else {throw WispError("Inert headless target unavailable")}
            events.append(["event":"headless_"+action,"id":id,"width":geometry.width,"height":geometry.height])
            if failHeadlessControl {throw WispError("Inert headless control refused")}
            if action=="rotate" {
                if geometry.width>geometry.height {nativeLandscape.remove(id)} else {nativeLandscape.insert(id)}
            }
        }
    }
    func configure(_ value: [String: Any]) {
        lock.withLock {
            if let flag = value["failBoot"] as? Bool { failBoot = flag }
            if let flag = value["failHeadlessControl"] as? Bool { failHeadlessControl = flag }
            // Simulate an already-booted windowless device after a server restart:
            // no Devices.boot call means no in-memory launch intent is recorded.
            if let ids = value["windowlessIDs"] as? [String] {
                headlessIDs = Set(ids);refs = [a,b].filter {states[$0]=="Booted" && !headlessIDs.contains($0)}.map {window($0)}
            }
            if let flag = value["failNativeInput"] as? Bool { nativeFailure = flag }
            if let ids = value["failNativeCleanupIDs"] as? [String] { nativeCleanupFailure = Set(ids) }
            if let ids = value["nativeInactiveIDs"] as? [String] { nativeInactive = Set(ids) }
            if let ids = value["nativeLandscapeIDs"] as? [String] { nativeLandscape = Set(ids) }
            if let flag = value["failShutdown"] as? Bool { failShutdown = flag }
            if let flag = value["failClose"] as? Bool { failClose = flag }
            if let delay = value["adbDelay"] as? Double { adbDelay = delay }
            if let flag = value["failADBList"] as? Bool { failADBList = flag }
            if let flag = value["malformedADBList"] as? Bool { malformedADBList = flag }
            if let flag = value["failADBKill"] as? Bool { failADBKill = flag }
            if let flag = value["failSims"] as? Bool { failSims = flag }
            if let map = value["states"] as? [String: String] { states.merge(map) { _, new in new } }
            if let kind = value["hold"] as? String, let id = value["id"] as? String {
                if kind == "shutdown" { shutdownHolds[id] = DispatchSemaphore(value: 0) }
                else if kind == "native_input" { nativeHolds[id] = DispatchSemaphore(value:0) }
                else if kind == "native_close" { nativeHolds["close:"+id] = DispatchSemaphore(value:0) }
                else { gates[kind + ":" + id] = Latch() }
            }
        }
    }
    func release(_ type: String, _ id: String) {
        if type == "shutdown" { lock.withLock { shutdownHolds.removeValue(forKey: id) }?.signal() }
        else if type == "native_input" { lock.withLock { nativeHolds.removeValue(forKey:id) }?.signal() }
        else if type == "native_close" { lock.withLock { nativeHolds.removeValue(forKey:"close:"+id) }?.signal() }
        else { lock.withLock { gates.removeValue(forKey: type + ":" + id) }?.release() }
    }
    func releaseAll() {
        let pending = lock.withLock { () -> ([Latch], [DispatchSemaphore]) in let values = (Array(gates.values), Array(shutdownHolds.values)+Array(nativeHolds.values)); gates = [:]; shutdownHolds = [:]; nativeHolds = [:]; return values }
        pending.0.forEach { $0.release() }; pending.1.forEach { $0.signal() }
    }
    var snapshot: [String: Any] { lock.withLock { ["states": states, "events": events, "commands": commands, "windows": refs.map { ["id": $0.id, "title": $0.title] }, "quits": quits, "real_device_actions": false, "real_window_actions": false, "real_capture": false, "real_input": false] } }
    func discovery() -> ([Device], [[String: Any]], [String: DeviceWindow]) {
        lock.withLock {
            let running = ids.filter { states[$0] == "Booted" }.map { Device(id: $0, name: names[$0]!, platform: $0.hasPrefix("emulator-") ? "android" : "ios", width: 320, height: 640, project_app: $0 == a || $0 == "emulator-5554", avd: $0 == "emulator-5554" ? "Pixel_6_API_36" : $0 == "emulator-5556" ? "Pixel_second_emulator" : nil) }
            var available: [[String: Any]] = ids.filter { states[$0] == "Shutdown" && !$0.hasPrefix("emulator-") }.map { ["id": $0, "name": names[$0]!, "platform": "ios", "width": 320, "height": 640, "runtime": "fixture"] }
            available += ids.filter { states[$0] == "Shutdown" && $0.hasPrefix("emulator-") }.map { ["id": $0 == "emulator-5554" ? "Pixel_6_API_36" : "Pixel_second_emulator", "name": names[$0]!, "platform": "android"] }
            let windows = Dictionary(uniqueKeysWithValues: running.filter { !headlessIDs.contains($0.id) }.map { device in (device.id, DeviceWindow(id: device.id == a ? 1001 : device.id == b ? 1002 : device.id == "emulator-5554" ? 3001 : 3002, pid: 0, title: device.id, bounds: CGRect(x: 0, y: 0, width: 320, height: 640), crop: CGRect(x: 0, y: 0, width: 320, height: 640))) })
            return (running, available, windows)
        }
    }
    func boot(_ id: String, _ mode: DeviceLaunchMode) throws {
        try lock.withLock {
            if failBoot { throw WispError("fixture boot refused <img src=x onerror=window.__injected=true>") }
            let target = id == "Pixel_6_API_36" ? "emulator-5554" : id == "Pixel_second_emulator" ? "emulator-5556" : id
            states[target] = "Booted"
            if mode == .headless { headlessIDs.insert(target) } else { headlessIDs.remove(target) }
            if (target == a || target == b) && mode == .windowed { refs.append(window(target)) }
            events.append(["event": "boot", "id": target, "mode": mode.rawValue])
        }
    }
    var windows: SimulatorWindowEffects {
        SimulatorWindowEffects(snapshot: { self.record("mode_snapshot","");return self.lock.withLock { SimulatorWindowSnapshot(applications: [901], windows: self.refs, reliable: true) } }, close: { target in
            try self.lock.withLock {
                if self.failClose { throw WispError("fixture window close refused") }
                self.refs.removeAll { $0.id == target.id && $0.pid == target.pid }; self.events.append(["event": "window_close", "id": target.id])
            }
        }, quitIfEmpty: { pid in self.lock.withLock { guard pid == 901, self.refs.isEmpty else { return false }; self.quits += 1; return true } })
    }
    func run(_ path: String, _ args: [String], _ timeout: Double) throws -> CommandResult {
        record("tool_enter", args.last ?? ""); lock.withLock { commands.append([path] + args) }
        if args.count == 3, args[0] == "simctl", args[1] == "shutdown" {
            if let held = lock.withLock({ shutdownHolds[args[2]] }), held.wait(timeout: .now() + 12) != .success { throw WispError("fixture shutdown gate timeout") }
        }
        return lock.withLock {
            if args == ["simctl", "list", "devices", "--json"] {
                return CommandResult(status: 0, output: jsonData(["devices": ["fixture": [a, b].map { ["udid": $0, "name": names[$0]!, "state": states[$0]!, "isAvailable": true] }]]), error: Data())
            }
            if args.count == 3, args[0] == "simctl", args[1] == "shutdown" {
                if failShutdown { return CommandResult(status: 1, output: Data(), error: Data("fixture shutdown refused <img src=x onerror=window.__injected=true>".utf8)) }
                states[args[2]] = "Shutdown"; events.append(["event": "shutdown", "id": args[2]])
                return CommandResult(status: 0, output: Data(), error: Data())
            }
            if args.count == 4, args[0] == "-s", args[2] == "emu", args[3] == "kill" {
                if failADBKill { return CommandResult(status: 1, output: Data(), error: Data("fixture kill refused".utf8)) }
                if adbDelay > 0 { pendingADB[args[1]] = adbTime + adbDelay } else { states[args[1]] = "Shutdown" }
                events.append(["event": "adb_kill", "id": args[1]])
                return CommandResult(status: 0, output: Data(), error: Data())
            }
            if args == ["devices"] {
                if failADBList { return CommandResult(status: 1, output: Data(), error: Data("fixture list failed".utf8)) }
                if malformedADBList { return CommandResult(status: 0, output: Data("unreadable list".utf8), error: Data()) }
                for (id, deadline) in pendingADB where adbTime >= deadline { states[id] = "Shutdown"; pendingADB.removeValue(forKey: id) }
                return CommandResult(status: 0, output: Data(("List of devices attached\n" + ids.filter { $0.hasPrefix("emulator-") && ["Booted", "Offline"].contains(states[$0] ?? "") }.map { $0 + "\t" + (states[$0] == "Offline" ? "offline" : "device") + "\n" }.joined()).utf8), error: Data())
            }
            fatalError("No real commands allowed: \(path) \(args)")
        }
    }
}
let world = World(); world.reset(false)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 640, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(white: 0.96, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 320, height: 640).fill()
func text(_ value: String, _ y: CGFloat, _ size: CGFloat) { (value as NSString).draw(at: NSPoint(x: 20, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.darkGray]) }
text("SYNTHETIC · INERT FIXTURE", 603, 10); text("Your app", 530, 32); text("Devices stay independent", 492, 16)
for (index, value) in ["Scoped shutdown", "Safe Simulator quit", "Explicit confirmation"].enumerated() { text(value, CGFloat(365 - 62 * index), 19) }
text("Test image — not a live device", 64, 11); NSGraphicsContext.restoreGraphicsState()
var pixels: CVPixelBuffer?, format: CMVideoFormatDescription?, sample: CMSampleBuffer?
guard CVPixelBufferCreate(nil, 320, 640, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels) == noErr else { fatalError("fixture pixels") }
CIContext().render(CIImage(cgImage: rep.cgImage!), to: pixels!)
guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels!, formatDescriptionOut: &format) == noErr else { fatalError("fixture format") }
var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels!, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr else { fatalError("fixture sample") }
var landscapePixels: CVPixelBuffer?
guard CVPixelBufferCreate(nil,640,320,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&landscapePixels)==noErr else {fatalError("inert landscape pixels")}
CIContext().render(CIImage(color:CIColor(red:0.2,green:0.4,blue:0.8)).cropped(to:CGRect(x:0,y:0,width:640,height:320)),to:landscapePixels!)
let attachment = Unmanaged<NSMutableDictionary>.fromOpaque(CFArrayGetValueAtIndex(CMSampleBufferGetSampleAttachmentsArray(sample!, createIfNecessary: true)!, 0)).takeUnretainedValue()
attachment[SCStreamFrameInfo.status.rawValue] = SCFrameStatus.complete.rawValue
final class FakeStream: CaptureStream {
    let id: String
    weak var capture: WindowCapture?
    init(_ id: String) { self.id = id }
    @MainActor func startCapture() async throws { world.record("capture_start", id); if let gate = world.gate("start", id) { await gate.wait() }; capture?.receive(sample!, type: .screen) }
    @MainActor func stopCapture() async throws { world.record("capture_stop", id); if let gate = world.gate("stop", id) { await gate.wait() } }
    @MainActor func removeStreamOutput(_ output: any SCStreamOutput, type: SCStreamOutputType) throws { world.record("capture_detach", id); capture = nil }
}
let sdk = root.appendingPathComponent("sdk/platform-tools")
try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
let fakeADB = sdk.appendingPathComponent("adb")
try Data("#!/bin/sh\nprintf '%s\\n' 'V/talkback: Pipeline action=SPEAK text=\"Inert test speech\"'\nexec /bin/sleep 300\n".utf8).write(to: fakeADB)
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeADB.path)
var settings = Settings(); settings.port = 45152; settings.shareLAN = false; settings.terminalEnabled = true
settings.projectDirectory = root.path; settings.androidSDK = root.appendingPathComponent("sdk").path; settings.pairingToken = "isolated-device-stop-token"
let control = DeviceControl(adb: fakeADB.path, launches: world.launches, windows: world.windows, run: world.run, wait: world.wait, clock: { world.clock })
let devices = Devices(settings: settings, control: control, discovery: world.discovery, boot: world.boot)
final class HeadlessSurface: NativeSurfaceSource {
    private let id: String
    private var closed = false
    init(_ id: String) {self.id=id}
    func surface() throws -> IOSurface? { let (active,landscape)=world.nativeDisplay(id);if closed || !active {return nil};return CVPixelBufferGetIOSurface(landscape ? landscapePixels!:pixels!)!.takeUnretainedValue() as IOSurface }
    func close() { closed = true }
}
final class InertNativeInput: NativeInputTransport {
    private let id: String, instance=UUID().uuidString
    private var closed=false
    init(_ id: String) { self.id=id;world.recordNative("connect",id,instance) }
    func send(_ event: NativeHIDEvent) throws {
        guard !closed else {throw WispError("Inert Native peer closed")}
        world.recordNative("event",id,instance,event)
        if case .touch(let touch)=event,touch.phase == .down {try world.waitNative(id)}
        if world.nativeFails {throw WispError("Inert Native input refused <img src=x onerror=window.__injected=true>")}
    }
    func close() throws {
        guard !closed else{return};closed=true;world.recordNative("close_begin",id,instance)
        defer {world.recordNative("close",id,instance)}
        try world.waitNative(id,closing:true)
        if world.nativeCleanupFails(id) {throw WispError("Inert Native cleanup refused")}
    }
}
let inertInput=DeviceInput(devices:devices,handler:{message,id in world.record("quartz_"+(message["type"] as? String ?? "unknown"),id);return nil})
let service = Service(settings: settings, pairingStateURL: root.appendingPathComponent("pairing-state.json"), tlsDirectory: root.appendingPathComponent("tls"), devices: devices, input: inertInput, captureStopTimeout: 1.5, scrcpyInstallation: { throw WispError("Isolated fixture: scrcpy unavailable") }, rawDiscovery: { _ in
    guard let data = try? Data(contentsOf: root.appendingPathComponent("raw-peer.json")), let port = dictionary(data)["port"] as? Int else { throw WispError("Owned raw peer unavailable") }
    return try EmulatorRawEndpoint(port: port, token: "owned-raw-fixture-secret")
}, makeNative: { id in NativeCapture(source: { HeadlessSurface(id) }) }, makeNativeInput: { InertNativeInput($0) }, headlessIOSControl: world.headlessControl, androidAccessibilityRun: { _, args, _ in
    // Never execute an SDK/guest command for accessibility-menu fixture reads.
    guard args.count == 7, args[4] == "get" else { throw WispError("Fixture accessibility writes unavailable") }
    let value = args[6] == "font_scale" ? "1.0" : args[6] == "enabled_accessibility_services" ? "null" : "0"
    return CommandResult(status:0, output:Data(value.utf8), error:Data())
}, makeCapture: { window in
    let native = FakeStream(window.title)
    return WindowCapture(target: window, makeStream: { capture in native.capture = capture; return native })
})
// A synthetic terminal proves the UI does not close its independent connection;
// it never invokes TerminalManager.attach, a PTY or an owner login profile.
var terminalClients: [UUID: ClientConnection] = [:], terminalStarts = 0
let originalUpgrade = service.server.upgrade!
service.server.upgrade = { request, client in
    if request.path == "/ws/pty" {
        terminalClients[client.id] = client; terminalStarts += 1
        client.onClose = { terminalClients.removeValue(forKey: client.id) }
        client.onMessage = { [weak client] message in if dictionary(Data(message.utf8))["type"] as? String == "close" { client?.close() } }
        client.sendJSON(["type": "session", "id": "fixture-terminal-\(terminalStarts)"])
        client.sendBinary(Data("Inert terminal fixture — no shell\r\n".utf8)); return
    }
    originalUpgrade(request, client)
}
let originalRoute = service.server.route!
service.server.route = { request, complete in
    switch request.path {
    case "/fixture/status": var value = world.snapshot; value["terminal"] = ["active": terminalClients.count, "starts": terminalStarts]; complete(.json(value))
    case "/fixture/release-all": world.releaseAll(); complete(.json(["ok": true]))
    case "/fixture/config": world.configure(dictionary(request.body)); complete(.json(["ok": true]))
    case "/fixture/release": let value = dictionary(request.body); world.release(value["type"] as? String ?? "", value["id"] as? String ?? ""); complete(.json(["ok": true]))
    case "/fixture/reset": world.reset(dictionary(request.body)["single"] as? Bool == true); devices.invalidate(); complete(.json(["ok": true]))
    case "/api/sims":
        if world.listFails { complete(.json(["error": "Fixture discovery failed"], status: 503)) } else { originalRoute(request, complete) }
    case "/api/info": originalRoute(request) { response in
        guard response.status == 200 else { complete(response); return }
        var info = dictionary(response.body); info["permissions"] = ["screen_recording": true, "accessibility": true]; info["mode"] = "fast2 (Inert device-control fixture)"; info["fixture_simulated_permissions"] = true
        complete(.json(info))
    }
    default: originalRoute(request, complete)
    }
}
service.stateChanged = { state in if state == "Running" { print("Isolated device-control service ready"); fflush(stdout) } else { log(state); exit(1) } }
try service.start()
let signal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main); Darwin.signal(SIGTERM, SIG_IGN)
signal.setEventHandler { service.stop { exit(0) } }; signal.resume(); dispatchMain()
