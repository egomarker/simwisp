import Foundation
import Darwin
import CoreImage

// USB, mDNS Wi-Fi, IPv4 and IPv6 identities are documentation-only fixtures.
// All processes/sockets/files below are owned loopback peers; never real ADB.
func runPhysicalTests(root parent: URL, node: String) throws {
    let fm = FileManager.default, root = parent.appendingPathComponent("physical-native")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let ids = ["USBPHYSICALTEST123", "adb-PHYSICAL-TEST._adb-tls-connect._tcp", "192.0.2.10:37123", "[2001:db8::1]:5555"]
    var checks = 0
    func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
    func rejects(_ label: String, _ body: () throws -> Void) { do { try body(); preconditionFailure("Accepted " + label) } catch { checks += 1 } }
    func wait(_ label: String, _ body: () -> Bool) throws { let end = monotonic() + 10; while monotonic() < end { if body() { return }; Thread.sleep(forTimeInterval: 0.01) }; throw WispError("Physical timeout: " + label) }
    func result(_ text: String, _ status: Int32 = 0) -> CommandResult { CommandResult(status: status, output: Data(text.utf8), error: Data()) }
    for (value, edge) in [("1", 2400), ("0.5", 1200), ("0.25", 600)] {
        check(AndroidCaptureScale.normalized(value).maxSize(nativeEdge: 2400) == edge, "scale applies before guest JPEG encoding")
    }
    for value in ["", "0", "-1", "2", "NaN", "Infinity", "0.50", "0.25;id", "0.5 "] {
        check(AndroidCaptureScale.normalized(value) == .full, "untrusted scale normalizes to x1")
    }
    check(AndroidCaptureScale.normalized(nil) == .full, "missing scale preserves x1")
    check(AndroidCaptureScale.half.maxSize(nativeEdge: 8000) == 4000, "factor precedes4096cap, not half a capped image")
    check(AndroidCaptureScale.quarter.maxSize(nativeEdge: 8) == 8 && AndroidCaptureScale.full.maxSize(nativeEdge: 8000) == 4096, "scale respects helper bounds")
    for id in ids {
        check(DeviceControl.validADBSerial(id), "physical ADB serial admitted")
        check(!DeviceControl.validID(id, platform: "android"), "capture/input admission never grants destructive Stop")
    }
    check(DeviceControl.validADBSerial("emulator-5554"), "existing emulator serial admitted")
    let bad = ["", "-s", "--transport-id=1", " usb", "usb\n", "a b", "a\tdevice", "a/b", "a\\b", "a;id", "a'", "a\"", "a`id`", "a$(id)", "a&b", "a|b", "a=1", "a\0b", "phone💥", "emulator-05554", "emulator-0", "emulator-65536", String(repeating: "a", count: 256)]
    for id in bad { check(!DeviceControl.validADBSerial(id), "invalid/option/shell serial rejected") }
    let inventory = "List of devices attached\n" + (["emulator-5554"] + ids).map { $0 + "\tdevice product:fixture" }.joined(separator: "\n") + "\nOFFLINE\toffline\nNOAUTH\tunauthorized\nNOPERM\tno permissions\n"
    check(AndroidDeviceInventory.connected(Data(inventory.utf8)) == ["emulator-5554"] + ids, "only online authorized entries become selectors")
    for text in ["", "daemon starting\n" + inventory, inventory + ids[0] + "\tdevice\n", "List of devices attached\ntruncated\n", "List of devices attached\nusb mystery\n", String(repeating: "x", count: 65537)] {
        check(AndroidDeviceInventory.connected(Data(text.utf8)).isEmpty, "ambiguous/malformed/unbounded inventory fails closed")
    }
    check(AndroidDeviceInventory.connected(Data([0xff])).isEmpty, "inventory must be UTF8")
    check(AndroidDeviceInventory.displaySize(Data("Physical size: 1080x2400\nOverride size: 720x1600\n".utf8))?.1 == 1600, "effective display override wins")
    for text in ["Physical size: 0x2400", "Physical size: 1080x8193", "Physical size: -8x80", "Physical size: 1080x2400;id", "Physical size: 1080x2400\nOverride size: bad", "unknown", String(repeating: "x", count: 1025)] {
        check(AndroidDeviceInventory.displaySize(Data(text.utf8)) == nil, "malformed display size cannot reach source budget")
    }
    var queries = [[String]]()
    let devices = AndroidDeviceInventory.read(adb: "/inert/adb", run: { _, args, _ in
        queries.append(args)
        if args == ["devices"] { return result(inventory) }
        if args.contains("emu") { return result("Pixel_fixture\nOK\n") }
        if args.last == AndroidMetroIdentity.properties { return result("Phone fixture\n15\n35\n") }
        if args.suffix(3) == ["shell", "wm", "size"] { return result("Physical size: 1080x2400\n") }
        throw WispError("Unexpected inventory operation")
    })
    check(devices.count == 5 && devices.filter(\.physicalAndroid).count == 4, "USB/Wi-Fi devices coexist with emulator inventory")
    check(devices.first?.avd == "Pixel_fixture" && devices.first?.width == 0, "emulator keeps AVD and unknown pre-window size")
    for device in devices.dropFirst() {
        check(device.avd == nil && device.width == 1080 && device.height == 2400 && device.name == "Phone fixture", "phone has full display metadata, not test downscale/AVD")
        check(device.json["physical"] as? Bool == true, "public physical capability metadata")
    }
    check(queries.filter { $0.contains("emu") }.allSatisfy { $0[1] == "emulator-5554" }, "physical discovery never invokes emulator console")
    check(queries.dropFirst().allSatisfy { $0.first == "-s" && (["emulator-5554"] + ids).contains($0[1]) }, "every metadata query explicitly targets one inventory serial")
    check(AndroidDeviceInventory.read(adb: "/inert/adb", run: { _, _, _ in result(inventory, 1) }).isEmpty, "failed inventory cannot reuse stale devices")
    let unknown = AndroidDeviceInventory.read(adb: "/inert/adb", run: { _, args, _ in args == ["devices"] ? result("List of devices attached\nUSBPHYSICALTEST123 device\n") : result("", 1) })
    check(unknown.first?.width == 0 && unknown.first?.name == ids[0], "failed phone metadata uses safe unknown-size fallback")
    let control = DeviceControl(adb: "/inert/adb", run: { _, _, _ in preconditionFailure("Physical Stop executed a command") })
    for id in ids {
        rejects("physical Stop") { _ = try control.stop(Device(id: id, name: "fixture", platform: "android", width: 1080, height: 2400)) }
        rejects("physical Stop status") { _ = try control.androidStopStatus(id) }
    }
    // Even a forged host-window mapping cannot enable Mac HID or legacy input.
    var settings = Settings(); settings.androidSDK = root.appendingPathComponent("sdk").path; settings.projectDirectory = root.path
    let sourceDevices = Devices(settings: settings, discovery: {
        let window = DeviceWindow(id: 123, pid: 0, title: "inert", bounds: CGRect(x: 0, y: 0, width: 1080, height: 2400), crop: CGRect(x: 0, y: 0, width: 1080, height: 2400))
        return ([Device(id: ids[0], name: "fixture", platform: "android", width: 1080, height: 2400)], [], [ids[0]: window])
    })
    let refreshed = DispatchSemaphore(value: 0); sourceDevices.requestRefresh { refreshed.signal() }
    check(refreshed.wait(timeout: .now() + 3) == .success, "inert device snapshot ready")
    let legacyInput = DeviceInput(devices: sourceDevices)
    for type in DeviceInput.supportedTypes {
        let done = DispatchSemaphore(value: 0); var response: [String: Any]?
        legacyInput.perform(["type": type, "text": "fixture"], id: ids[0]) { response = $0; done.signal() }
        check(done.wait(timeout: .now() + 3) == .success && response?["type"] as? String == "input_error", "phone refuses every legacy/HID input path")
    }
    sourceDevices.stop()
    let sdk = root.appendingPathComponent("sdk/platform-tools"), adb = sdk.appendingPathComponent("adb")
    try fm.createDirectory(at: sdk, withIntermediateDirectories: true)
    let script = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Tests/Android/server.mjs").path
    try Data("#!/bin/bash\nexec '\(node)' '\(script)' '\(root.path)' cli \"$@\"\n".utf8).write(to: adb)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: adb.path)
    for name in ["video.json", "phone-video.json", "jpeg.json", "fake-server.jar"] { try fm.copyItem(at: parent.appendingPathComponent(name), to: root.appendingPathComponent(name)) }
    let jar = root.appendingPathComponent("fake-server.jar")
    let peer = Process(); peer.executableURL = URL(fileURLWithPath: node); peer.arguments = [script, root.path, "peer"]; peer.standardOutput = FileHandle.nullDevice
    try peer.run(); defer { if peer.isRunning { peer.terminate(); peer.waitUntilExit() } }
    try wait("owned physical peer") { fm.fileExists(atPath: root.appendingPathComponent("peer.json").path) }
    func events() -> [[String: Any]] { ((try? String(contentsOf: root.appendingPathComponent("events.ndjson"), encoding: .utf8)) ?? "").split(separator: "\n").map { dictionary(Data($0.utf8)) } }
    let install: ScrcpySession.Installation = { ScrcpyInstallation(server: jar.path, version: ScrcpyWire.version) }
    for id in ids {
        let life = DispatchGroup(), network = DispatchQueue(label: "physical.fixture")
        let admission = ScrcpySession(adb: adb.path, serial: id, video: true, controls: true, fps: 60, quality: 1, network: network, lifecycle: life, installation: { throw WispError("phone video installation reached") }, run: { _, _, _ in preconditionFailure("Missing phone dependency reached ADB") })
        admission.start(); try wait("phone video admission") { admission.state.error != nil }; admission.stop()
        check(life.wait(timeout: .now() + 3) == .success && admission.state.error == "phone video installation reached", "phone video reaches dependency check without tools/property writes")
        try jsonData(["width": 1080, "height": 2400]).write(to: root.appendingPathComponent("display.json"))
        let before = events().count
        let input = ScrcpySession(adb: adb.path, serial: id, video: false, controls: true, fps: 60, quality: 1, network: network, lifecycle: life, installation: install)
        input.start(); try wait("physical control ready") { input.state.ready || input.state.error != nil }
        check(input.state.ready && input.state.error == nil && input.state.size.1 == 2400, "physical control-only handshake uses full validated display geometry")
        for type in ["touch_down", "touch_move", "touch_up", "tap", "key", "text", "home", "back", "menu", "app_switcher"] {
            check(try input.perform(["type": type, "x": 0.2, "y": 0.3, "key": "enter", "text": "phone fixture"]), "physical persistent touch/key/navigation")
        }
        rejects("physical rotate") { _ = try input.perform(["type": "rotate"]) }
        let jpeg = AndroidJPEGSession(adb: adb.path, serial: id, fps: 30, maxSize: 2400, network: network, lifecycle: life, installation: { jar.path })
        jpeg.start(); try wait("physical JPEG") { jpeg.state.ready || jpeg.state.error != nil }
        check(jpeg.state.ready && jpeg.state.error == nil && jpeg.maxSize == 2400, "physical JPEG admits selected serial without 914px product cap")
        let first = try jpeg.h264(quality: 20, fps: 30, forceKeyframe: true, dataSaver: false)
        check(first?.keyframe == true && first?.width == 320 && first?.description[1] == 66, "physical source uses real unchanged JPEG decode/VT H264")
        Thread.sleep(forTimeInterval: 0.04)
        let second = try jpeg.h264(quality: 20, fps: 30, forceKeyframe: false, dataSaver: false)
        check(second != nil && second!.timestamp > first!.timestamp, "physical source emits new H264/PTS, never packet replay")
        try jsonData(["rotation": true]).write(to: root.appendingPathComponent("jpeg-mode.json")); try jsonData(["width": 640, "height": 320]).write(to: root.appendingPathComponent("display.json"))
        try wait("physical JPEG rotation") { jpeg.diagnostics["video_width"] as? Int == 640 }
        let rotated = try jpeg.h264(quality: 20, fps: 30, forceKeyframe: false, dataSaver: false)
        input.invalidatePhysicalSize(); try wait("physical input rotation") { input.state.size.0 == 640 }
        check(rotated?.keyframe == true && rotated?.height == 320, "physical rotation replaces encoder with correct geometry/IDR")
        _ = try input.perform(["type": "touch_down", "x": 0.4, "y": 0.5]); jpeg.stop(); input.stop()
        check(life.wait(timeout: .now() + 6) == .success, "physical teardown joins only owned helper/socket/geometry work")
        let commands = events().dropFirst(before).filter { $0["kind"] as? String == "command" }.compactMap { $0["args"] as? [String] }
        check(commands.allSatisfy { $0.first == "-s" && $0[1] == id }, "physical process/startup/cleanup commands target selected serial only")
        check(!commands.contains { $0.contains("emu") || $0.contains("setprop") || $0.contains("settings") || $0.contains("kill-server") || $0.contains("video=true") }, "phone never receives emulator actions, shaping/settings or video startup")
        check(commands.contains { $0.contains("video=false") && $0.contains("clipboard_autosync=false") && $0.contains("power_on=false") }, "control-only launcher retains clipboard/power protections")
        check(commands.contains { $0.contains("forward") && $0.contains("--remove") }, "phone teardown removes only owned forward")
        try? fm.removeItem(at: root.appendingPathComponent("jpeg-mode.json"))
    }
    // Phone video uses its own safe codec policy, never the emulator QP trial.
    let output=ScrcpyServerOutput();output.append(Data(repeating:65,count:1_000_000));output.append(Data("\nstack corruption detected (-fstack-protector)\nAborted USBPHYSICALTEST123 /data/local/tmp/private.jar\n".utf8))
    check(output.count==8192,"server output bounded to8KiB")
    let error=output.summary(serial:"USBPHYSICALTEST123")
    check(error.count<=1000 && error.contains("stack corruption") && error.contains("Aborted"),"bounded server error remains actionable")
    check(!error.contains("USBPHYSICALTEST123") && !error.contains("private.jar"),"server error redacts selected serial/helper path")
    for size in [ScrcpyVideoSize(width:8,height:8)!,ScrcpyVideoSize(width:1080,height:2400)!,ScrcpyVideoSize(width:8192,height:8192)!] {
        for q in [1,95] { for fps in [1,60] {
            let args=ScrcpySession.arguments(version:ScrcpyWire.version,scid:"7fffffff",jar:"/data/local/tmp/long-owned-helper-name.jar",video:true,controls:true,fps:fps,quality:q,videoSize:size,physical:true)
            check(args.dropFirst(2).joined(separator:" ").utf8.count<255,"all phone dimensions/bitrate/FPS cases fit Samsung argv")
            check(args.contains("audio=false") && args.contains("clipboard_autosync=false") && args.contains("power_on=false") && args.contains("send_device_meta=false"),"short command never drops safety flags")
        }}
    }
    let nativeSize = ScrcpyVideoSize(width: 320, height: 640)!
    for scale in AndroidCaptureScale.allCases {
        let size = scale.scrcpySize(nativeSize), divisor = scale == .full ? 1 : scale == .half ? 2 : 4
        check(size.width == 320/divisor && size.height == 640/divisor, "factor applies to both scrcpy source dimensions")
        check(scale.scrcpySize(ScrcpyVideoSize(width:640,height:320)!) == size, "scrcpy rotation retains scaled budget")
        let options = ScrcpySession.arguments(version:ScrcpyWire.version,scid:"00000001",jar:"owned.jar",video:true,controls:true,fps:30,quality:1,videoSize:size,physical:true)
        check(options.contains("max_size=\(640/divisor)") && options.contains("video_bit_rate=500000"), "phone source scale and normal bitrate reach scrcpy")
        check(!options.contains{$0.contains("bitrate-mode=") || $0.contains("qp-") || $0.contains("repeat-previous-frame")}, "phone does not inherit emulator QP/CBR or repeat trial")
        check(options.contains("video_codec_options=profile=1"), "compact phone requests Baseline which forbids B-frames")
        check(options.dropFirst(2).joined(separator:" ").utf8.count<255, "phone app_process stays below Samsung byte limit")
    }
    check(AndroidCaptureScale.full.scrcpySize(ScrcpyVideoSize(width:5000,height:8000)!).maxSize == 8000, "scrcpy x1 not restricted by JPEG4096 bound")
    check(AndroidCaptureScale.quarter.scrcpySize(ScrcpyVideoSize(width:8,height:8)!).width == 8, "scrcpy minimum remains bounded")
    try jsonData(["scaled":true]).write(to:root.appendingPathComponent("scrcpy-mode.json"))
    for (index,id) in ids.enumerated() {
        for scale in (index == 0 ? AndroidCaptureScale.allCases : [.quarter]) {
            let life=DispatchGroup(),network=DispatchQueue(label:"phone.video.fixture"),size=scale.scrcpySize(nativeSize),before=events().count
            let source=ScrcpySession(adb:adb.path,serial:id,video:true,controls:true,fps:30,quality:1,videoSize:size,network:network,lifecycle:life,installation:install)
            source.start();try wait("scaled phone video"){source.state.error != nil || source.state.size.1 == size.height}
            check(source.state.error == nil && source.state.ready, "USB/Wi-Fi phone video ready")
            var frame:H264Frame?;try wait("phone direct H264"){frame=source.takeFrame();return frame != nil}
            check(frame!.width == size.width && frame!.height == size.height && frame!.keyframe, "phone H264 metadata matches pre-encoded scaled fixture")
            check(frame!.description[1] == 66 && frame!.payload.count>0, "phone H264 is Baseline and unmodified picture payload")
            let diag=source.diagnostics
            check(diag["format_shaping_disabled"] is NSNull && diag["requested_qp_max"] is NSNull && diag["requested_bitrate_mode"] is NSNull, "phone never claims emulator property/codec trial")
            _ = try source.perform(["type":"tap","x":0.2,"y":0.3]);rejects("phone video Rotate"){_ = try source.perform(["type":"rotate"])}
            try wait("scaled touch packet"){events().dropFirst(before).contains{$0["kind"] as? String == "control" && $0["type"] as? Int == 2}}
            let touch=events().dropFirst(before).first{$0["type"] as? Int == 2}!["hex"] as! String
            let bytes=Data(stride(from:0,to:touch.count,by:2).map{offset -> UInt8 in let i=touch.index(touch.startIndex,offsetBy:offset);return UInt8(touch[i..<touch.index(i,offsetBy:2)],radix:16)!})
            check(bytes.scrcpyUInt(18,2) == size.width && bytes.scrcpyUInt(20,2) == size.height && bytes.scrcpyUInt(10,4) == Int(Double(size.width)*0.2) && bytes.scrcpyUInt(14,4) == Int(Double(size.height)*0.3), "touch uses scrcpy video coordinate space for server display mapping")
            source.stop();check(life.wait(timeout:.now()+5) == .success, "phone video teardown joins owned work")
            let calls=events().dropFirst(before).filter{$0["kind"] as? String == "command"}.compactMap{$0["args"] as? [String]}
            check(calls.allSatisfy{$0.first == "-s" && $0[1] == id}, "phone video startup/cleanup stays serial scoped")
            check(!calls.contains{$0.contains("setprop") || $0.contains("getprop") || $0.contains("settings") || $0.contains("emu") || $0.contains("kill-server")}, "phone video performs no property/settings/emulator operations")
            check(calls.contains{!$0.contains("video=false") && $0.contains("com.genymobile.scrcpy.Server") && $0.contains("power_on=false") && $0.contains("clipboard_autosync=false") && $0.contains("max_size=\(size.maxSize)")}, "phone launcher is scaled with clipboard/power disabled")
            check(calls.contains{$0.contains("forward") && $0.contains("--remove")}, "phone video removes only its own forward")
        }
    }
    try? fm.removeItem(at:root.appendingPathComponent("scrcpy-mode.json"))
    try jsonData(["checks": checks, "serial_forms": ["USB", "mDNS Wi-Fi", "IPv4 Wi-Fi", "IPv6 Wi-Fi"], "real_device_actions": false, "real_capture": false, "real_input": false]).write(to: parent.appendingPathComponent("physical-native-review.json"))
    print("Physical Android native checks: \(checks) passed")
}

// Golden streams are actually H264-encoded at each source size; no fake header resizing.
func makePhysicalScrcpyFixtures(_ root: URL) throws {
    var fixtures: [String: Any] = [:]
    for (w,h) in [(320,640),(160,320),(80,160),(640,320),(320,160),(160,80),(144,320),(120,240),(240,480)] {
        let encoder=try H264Encoder(width:w,height:h)
        defer { encoder.close() }
        let bounds=CGRect(x:0,y:0,width:w,height:h)
        let topLeft=CIImage(color:.red).cropped(to:CGRect(x:0,y:Double(h)/2,width:Double(w)/2,height:Double(h)/2))
        let topRight=CIImage(color:.green).cropped(to:CGRect(x:Double(w)/2,y:Double(h)/2,width:Double(w)/2,height:Double(h)/2))
        let bottomLeft=CIImage(color:.blue).cropped(to:CGRect(x:0,y:0,width:Double(w)/2,height:Double(h)/2))
        let bottomRight=CIImage(color:CIColor(red:1,green:1,blue:0)).cropped(to:CGRect(x:Double(w)/2,y:0,width:Double(w)/2,height:Double(h)/2))
        let image=topLeft.composited(over:topRight).composited(over:bottomLeft).composited(over:bottomRight).cropped(to:bounds)
        var config=Data(),frames=[[String:Any]]()
        for i in 0..<30 {
            let frame=try encoder.encode(image,quality:20,fps:30,forceKeyframe:i==0)
            if i==0 { let d=frame.description,n=Int(d.scrcpyUInt(6,2)),p=8+n+1,m=Int(d.scrcpyUInt(p,2));config.append(contentsOf:[0,0,0,1]);config.append(d[8..<8+n]);config.append(contentsOf:[0,0,0,1]);config.append(d[p+2..<p+2+m]) }
            frames.append(["key":frame.keyframe,"payload":annex(frame.payload).map{String(format:"%02x",$0)}.joined()])
        }
        fixtures["\(w)x\(h)"]=["config":config.map{String(format:"%02x",$0)}.joined(),"frames":frames]
    }
    try jsonData(fixtures).write(to:root.appendingPathComponent("phone-video.json"))
}
