import Foundation
import CryptoKit

var checks = [[String: Any]]()
func check(_ name: String, _ value: @autoclosure () throws -> Bool) throws {
    let passed = try value(); checks.append(["name": name, "passed": passed])
    if !passed { throw WispError(name) }
}
func rejects(_ name: String, _ action: () throws -> Void) throws {
    var failed = false; do { try action() } catch { failed = true }
    try check(name, failed)
}
func result(_ text: String = "", _ status: Int32 = 0, _ error: String = "") -> CommandResult {
    CommandResult(status: status, output: Data(text.utf8), error: Data(error.utf8))
}
let values = ["enabled_accessibility_services": AndroidAccessibility.talkBackService, "accessibility_enabled": "1", "font_scale": "2.0", "font_weight_adjustment": "300", "high_text_contrast_enabled": "1"]
let selectToSpeak = "com.google.android.marvin.talkback/com.google.android.accessibility.selecttospeak.SelectToSpeakService"
func unit() throws {
    for serial in ["emulator-5554", "USB-TEST", "192.0.2.10:5555", "[2001:db8::1]:5555"] {
        var calls = [[String]]()
        let state = try AndroidAccessibility.read(adb: "/owned/fake-adb", serial: serial) { path, args, timeout in
            try check("read exact path/timeout \(serial) \(calls.count)", path == "/owned/fake-adb" && timeout == 3)
            calls.append(args); return result(values[args[6]]! + "\r\n")
        }
        try check("snapshot four enabled booleans \(serial)", state.count == 4 && state.values.allSatisfy { $0 })
        try check("one bounded five-key read \(serial)", calls.count == 5 && calls.allSatisfy { Array($0.prefix(4)) == ["-s", serial, "shell", "settings"] && $0[4] == "get" })
    }
    for (name, services, global, expected) in [
        ("full component", AndroidAccessibility.talkBackService, "1", true),
        ("short component", "com.google.android.marvin.talkback/.TalkBackService", "1", true),
        ("colon list", selectToSpeak + ":" + AndroidAccessibility.talkBackService, "1", true),
        ("Select to Speak alone", selectToSpeak, "1", false),
        ("global disabled", AndroidAccessibility.talkBackService, "0", false),
        ("unset services", "null", "null", false),
        ("other error-named service", "com.example.error/.Service", "1", false)
    ] {
        let state = try AndroidAccessibility.read(adb: "fake", serial: "emulator-5554") { _, args, _ in
            result(args[6] == "enabled_accessibility_services" ? services : args[6] == "accessibility_enabled" ? global : "null")
        }
        try check("TalkBack service identity: \(name)", state["talkback"] == expected)
        try check("unset display defaults: \(name)", state["text_size"] == false && state["bold_font"] == false && state["high_contrast"] == false)
    }
    for setting in AndroidAccessibility.Setting.allCases {
        for enabled in [false, true] {
            var calls = [[String]]()
            let value = try AndroidAccessibility.set(.init(setting: setting, enabled: enabled), adb: "fake", serial: "emulator-5556") { _, args, _ in calls.append(args); return result(args[4] == "delete" ? "Deleted 1 rows" : "") }
            let expected: [[String]]
            switch setting {
            case .talkback: expected = enabled ? [["put", "secure", "enabled_accessibility_services", AndroidAccessibility.talkBackService], ["put", "secure", "accessibility_enabled", "1"]] : [["delete", "secure", "enabled_accessibility_services"], ["put", "secure", "accessibility_enabled", "0"]]
            case .textSize: expected = [["put", "system", "font_scale", enabled ? "2.0" : "1.0"]]
            case .boldFont: expected = [["put", "secure", "font_weight_adjustment", enabled ? "300" : "0"]]
            case .highContrast: expected = [["put", "secure", "high_text_contrast_enabled", enabled ? "1" : "0"]]
            }
            try check("exact selected-device writes \(setting.rawValue)=\(enabled)", calls == expected.map { ["-s", "emulator-5556", "shell", "settings"] + $0 })
            try check("affected row only/no readback \(setting.rawValue)=\(enabled)", value.count == 2 && value["setting"] as? String == setting.rawValue && value["enabled"] as? Bool == enabled && calls.allSatisfy { $0[4] != "get" })
        }
    }
    for serial in ["", "emulator-0", "emulator-05554", "-s", "two devices", "usb;echo", "usb\nx", String(repeating:"a",count:256)] {
        var count = 0
        try rejects("invalid selector rejected before runner \(serial.debugDescription)") { _ = try AndroidAccessibility.read(adb:"fake", serial:serial) { _,_,_ in count += 1; return result() } }
        try check("invalid selector has zero effects \(serial.debugDescription)", count == 0)
    }
    for body in ["{}", "[]", "{\"setting\":\"shell\",\"enabled\":true}", "{\"setting\":\"talkback\",\"enabled\":1}", "{\"setting\":\"talkback\",\"enabled\":\"true\"}", "{\"setting\":\"talkback\",\"enabled\":null}", String(repeating:"x",count:257)] {
        try rejects("strict mutation JSON \(body.prefix(65))") { _ = try AndroidAccessibility.change(Data(body.utf8)) }
    }
    let mutation = try AndroidAccessibility.change(Data("{\"setting\":\"text_size\",\"enabled\":false}".utf8))
    try check("valid JSON preserves false", mutation.setting == .textSize && !mutation.enabled)
    for bad in ["NaN", "Infinity", "", "Error: denied", "garbage"] {
        try rejects("invalid read value fails visibly \(bad.debugDescription)") { _ = try AndroidAccessibility.read(adb:"fake", serial:"emulator-5554") { _,args,_ in result(args[6] == "font_scale" ? bad : values[args[6]]!) } }
    }
    try rejects("nonzero ADB status rejected") { _ = try AndroidAccessibility.read(adb:"fake", serial:"emulator-5554") { _,_,_ in result("",1,"device offline") } }
    try rejects("zero-exit SecurityException on stderr rejected") { _ = try AndroidAccessibility.set(.init(setting:.boldFont,enabled:true),adb:"fake",serial:"emulator-5554") { _,_,_ in result("",0,"java.lang.SecurityException: denied") } }
    try rejects("unconfirmed write output rejected") { _ = try AndroidAccessibility.set(.init(setting:.boldFont,enabled:true),adb:"fake",serial:"emulator-5554") { _,_,_ in result("unexpected output") } }
    var partial = 0
    try rejects("TalkBack partial failure is not reported successful") { _ = try AndroidAccessibility.set(.init(setting:.talkback,enabled:true),adb:"fake",serial:"emulator-5554") { _,_,_ in partial += 1;return result("",partial == 2 ? 1 : 0) } }
    try check("no retry/rollback after TalkBack partial failure", partial == 2)
}
func serviceTests(_ root: URL) throws {
    let sdk = root.appendingPathComponent("sdk/platform-tools")
    try FileManager.default.createDirectory(at:sdk,withIntermediateDirectories:true)
    let adb = sdk.appendingPathComponent("adb");try Data("#!/bin/sh\nexit 97\n".utf8).write(to:adb)
    try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:adb.path)
    var settings=Settings(); settings.androidSDK=root.appendingPathComponent("sdk").path;settings.projectDirectory=root.path;settings.pairingToken="inert-a11y-route-fixture"
    let devices=Devices(settings:settings,discovery:{ ([Device(id:"TEST-USB-A",name:"Synthetic Android",platform:"android",width:414,height:920),Device(id:"192.0.2.9:5555",name:"Synthetic WiFi",platform:"android",width:414,height:920),Device(id:"other-platform",name:"Synthetic non-Android",platform:"mac",width:414,height:920)],[],[:]) })
    let ready=DispatchSemaphore(value:0);devices.requestRefresh { ready.signal() };try check("inert device inventory ready",ready.wait(timeout:.now()+5) == .success)
    var calls=[[String]]();let lock=NSLock()
    let service=Service(settings:settings,devices:devices,androidAccessibilityRun:{ path,args,timeout in
        guard path == adb.path && timeout == 3 else { throw WispError("Unexpected command path") }
        lock.withLock { calls.append(args) }
        return result(args[4] == "get" ? values[args[6]]! : args[4] == "delete" ? "Deleted 1 rows" : "")
    })
    let digest=SHA256.hash(data:Data(("simwisp-session-v1:"+settings.pairingToken).utf8)).map {String(format:"%02x",$0)}.joined()
    func request(_ name:String,_ method:String,_ id:String,_ body:String="",_ auth:Bool=true,_ origin:String?=nil,_ expected:Int) throws {
        let sem=DispatchSemaphore(value:0);var response:HTTPResponse?
        var headers=["host":"localhost","cookie":auth ? "simwisp_session="+digest : ""]
        if let origin {headers["origin"]=origin};if method == "POST" && origin == nil {headers["origin"]="https://localhost"}
        let r=HTTPRequest(method:method,path:"/api/android-accessibility/"+id,query:[:],headers:headers,body:Data(body.utf8),sourceAddress:"127.0.0.1")
        service.server.queue.async {service.server.route?(r) {value in response=value;sem.signal()}}
        try check(name+" completes",sem.wait(timeout:.now()+5) == .success)
        try check(name+" status",response?.status == expected)
    }
    try request("route auth required","GET","TEST-USB-A","",false,nil,401)
    try request("route GET origin denied","GET","TEST-USB-A","",true,"https://evil.invalid",403)
    try request("route POST origin denied","POST","TEST-USB-A","{}",true,"https://evil.invalid",403)
    try request("route rejects unknown device","GET","not-in-inventory","",true,nil,404)
    try request("route rejects non-Android","GET","other-platform","",true,nil,404)
    try request("route rejects bad bool","POST","TEST-USB-A","{\"setting\":\"talkback\",\"enabled\":1}",true,nil,400)
    try request("route rejects arbitrary setting","POST","TEST-USB-A","{\"setting\":\"other\",\"enabled\":true}",true,nil,400)
    try request("route rejects DELETE","DELETE","TEST-USB-A","",true,"https://localhost",405)
    try check("denied routes never touch ADB",lock.withLock {calls.isEmpty})
    try request("selected Android read","GET","TEST-USB-A","",true,nil,200)
    try check("route GET five selected-only reads",lock.withLock {calls.count == 5 && calls.allSatisfy {$0[1] == "TEST-USB-A" && $0[4] == "get"}})
    lock.withLock {calls=[]}
    try request("selected WiFi TalkBack disable","POST","192.0.2.9:5555","{\"setting\":\"talkback\",\"enabled\":false}",true,nil,200)
    try check("route POST exactly two selected-only writes",lock.withLock {calls.count == 2 && calls.allSatisfy {$0[1] == "192.0.2.9:5555" && $0[4] != "get"}})
    devices.stop()
}
let output=URL(fileURLWithPath:CommandLine.arguments[1]),phase=CommandLine.arguments.dropFirst(2).first ?? "all"
for name in ["unit","service"] where phase == "all" || phase == name {
    checks=[]
    do {
        if name == "unit" {try unit()} else {try serviceTests(output)}
        try jsonData(["passed":true,"checks":checks,"realADB":false,"startedProductService":false]).write(to:output.appendingPathComponent("native-"+name+".json"))
        print("Android accessibility \(name): \(checks.count) checks PASS")
    } catch {
        try? jsonData(["passed":false,"checks":checks,"error":error.localizedDescription]).write(to:output.appendingPathComponent("native-"+name+".json"))
        fputs("Android accessibility \(name) failed: \(error)\n",stderr);exit(1)
    }
}
