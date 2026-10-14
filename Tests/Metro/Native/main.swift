import Foundation
var checks = 0
func expect(_ v: Bool, _ label: String) { if !v { fatalError(label) }; checks += 1 }
let endpoint = URL(string: "http://127.0.0.1:45153/json/list")!
let a = Device(id: "00000000-0000-4000-8000-000000000001", name: "iPhone 11", platform: "ios", width: 320, height: 640)
let b = Device(id: "emulator-5554", name: "Pixel 6 API 36", platform: "android", width: 320, height: 640)
func raw(_ id: String = "one", _ value: [String: Any] = [:]) -> [String: Any] { var r: [String: Any] = ["id": id,"title": "Hermes","appId":"com.fixture.app","webSocketDebuggerUrl":"ws://localhost:45153/inspector/debug?device=fixture&page=" + id]; r.merge(value) { _,new in new }; return r }
func parsed(_ rows: [[String: Any]], devices: [Device] = [a,b], old: [String: MetroTarget] = [:]) throws -> [String: MetroTarget] { try MetroCodec.targets(jsonData(rows), endpoint: endpoint, previous: old, devices: devices) }
for host in ["localhost", "127.0.0.1", "[::1]"] { expect(MetroCodec.socketURL("ws://\(host):45153/inspector/debug?device=x",endpoint:endpoint)?.host == "127.0.0.1", "numeric loopback pinned") }
for url in ["ws://example.com:45153/inspector/debug", "ws://192.168.1.112:45153/inspector/debug", "ws://127.0.0.1:8081/inspector/debug", "wss://127.0.0.1:45153/inspector/debug", "file:///inspector/debug", "ws://user:pass@localhost:45153/inspector/debug", "ws://localhost:45153/inspector/debug#x", "ws://localhost:45153/not-inspector", "ws://localhost.evil:45153/inspector/debug"] { expect(MetroCodec.socketURL(url,endpoint:endpoint)==nil,"unsafe URL rejected") }
do {
 let p=try parsed([raw()])
 expect(p.count==1 && p.values.first!.confirmation,"generic target with multiple devices requires explicit picker")
 let unique=try parsed([raw()],devices:[a]);expect(!unique.values.first!.confirmation,"unique compatible fallback only")
 let two=try parsed([raw("one"),raw("two")],devices:[a]);expect(two.values.allSatisfy(\.confirmation),"multiple generic targets never first matched")
 let exact=try parsed([raw("one",["deviceId":a.id])]);expect(exact.values.first!.candidates==[a.id] && !exact.values.first!.confirmation,"exact stable device identity wins")
 let named=try parsed([raw("one",["deviceName":"  IPHONE  11 (iOS 18.6) ","platform":"ios"])]);expect(named.values.first!.candidates==[a.id],"exact normalized device/OS match")
 let wrong=try parsed([raw("one",["deviceName":"iPhone 11 Pro","platform":"ios"])]);expect(wrong.values.first!.candidates.isEmpty,"partial name never selected")
 let dup=Device(id:"second",name:a.name,platform:a.platform,width:320,height:640)
 let duplicates=try parsed([raw("one",["deviceName":a.name,"platform":"ios"])],devices:[a,dup]);expect(duplicates.values.first!.candidates.count==2 && duplicates.values.first!.confirmation,"indistinguishable names always picker")
 let invalid=try parsed([raw("one",["deviceId":b.id,"platform":"ios"])]);expect(invalid.values.first!.candidates.isEmpty,"mismatched platform/device identity rejected")
 let next=try parsed([raw()],old:p);expect(Set(next.keys)==Set(p.keys),"same target registry opaque key stable")
 expect(!jsonData(p.values.map(\.json)).description.contains("webSocketDebuggerUrl"),"no raw URL contract field")
 expect(!(p.values.first!.json.keys.contains("url")),"debugger URL private registry only")
 expect(try parsed([]).isEmpty,"successful empty snapshot valid")
 expect(try parsed([raw("one",["webSocketDebuggerUrl":"ws://evil.example:45153/inspector/debug"])]).isEmpty,"unsafe advertised inspector filtered")
}
// Actual Android Metro shape: no platform or ADB serial; logicalDeviceId is opaque.
let androidName = "sdk_gphone64_arm64 - 16 - API 36"
let properties = Data("sdk_gphone64_arm64\n16\n36\n".utf8)
expect(AndroidMetroIdentity.name(properties) == androidName, "three Android properties reproduce real Metro label")
expect(AndroidMetroIdentity.name(Data("sdk_gphone64_arm64\r\n16\r\n36\r\n".utf8)) == androidName, "ADB CRLF accepted")
expect(AndroidMetroIdentity.name(Data("  Pixel Model  \n 16 \n 036 \n".utf8)) == "Pixel Model - 16 - API 36", "trim properties and canonical SDK_INT")
expect(AndroidMetroIdentity.name(Data("機種\nBaklava\n36".utf8)) == "機種 - Baklava - API 36", "Unicode model and preview release accepted")
for text in ["", "sdk\n16\n", "\n16\n36\n", "sdk\n\n36\n", "sdk\n16\n36\nextra", "sdk\n16\n36\n\n", "unknown\n16\n36", "sdk\nUNKNOWN\n36", "sdk\n16\n0", "sdk\n16\n1001", "sdk\n16\n+36", "sdk\n16\n-36", "sdk\n16\n36x", "sdk\u{0000}\n16\n36", "sdk\n16\u{001B}\n36", "sdk\n16\n3 6", String(repeating:"x",count:129)+"\n16\n36", "sdk\n"+String(repeating:"x",count:65)+"\n36"] {
 expect(AndroidMetroIdentity.name(Data(text.utf8)) == nil, "invalid/empty/unknown properties never create alias")
}
expect(AndroidMetroIdentity.name(Data([0xff,0xfe])) == nil, "invalid UTF8 alias rejected")
expect(AndroidMetroIdentity.name(Data(repeating:65,count:1025)) == nil, "oversized property result rejected")
var calls: [[String]] = []
for serial in ["emulator-5554", "emulator-5556"] {
 let label = AndroidMetroIdentity.read(adb:"/owned/adb",serial:serial,run:{path,args,timeout in
  expect(path == "/owned/adb" && args == ["-s",serial,"shell",AndroidMetroIdentity.properties] && timeout == 3, "one fixed read-only batch scoped to exact serial with deadline")
  calls.append(args); return CommandResult(status:0,output:properties,error:Data())
 })
 expect(label == androidName, "read-only tool result supplies alias")
}
expect(calls.count == 2, "no unscoped or extra per-property command")
for serial in ["", "emulator-05554", "emulator-5554;evil", "physical-device", "emulator-70000"] {
 expect(AndroidMetroIdentity.read(adb:"/owned/adb",serial:serial,run:{_,_,_ in fatalError("invalid serial executed tool")}) == nil, "invalid serial never queried")
}
expect(AndroidMetroIdentity.read(adb:"/owned/adb",serial:b.id,run:{_,_,_ in CommandResult(status:1,output:properties,error:Data())}) == nil, "nonzero command result never supplies alias")
expect(AndroidMetroIdentity.read(adb:"/owned/adb",serial:b.id,run:{_,_,_ in throw WispError("timeout")}) == nil, "timeout/throw fails closed")
var mapped = b; mapped.metroName = AndroidMetroIdentity.name(properties)
let realAndroid = raw("android",["title":"google sdk_gphone64_arm64","reactNative":["deviceName":androidName,"logicalDeviceId":"opaque-inspector-id"]])
let beforeAlias = try parsed([realAndroid]); expect(beforeAlias.values.first!.candidates.isEmpty, "real-world mismatch reproduced without alias")
let matchedAlias = try parsed([realAndroid],devices:[a,mapped])
expect(matchedAlias.values.first!.candidates == [b.id] && !matchedAlias.values.first!.confirmation, "real metadata maps model/OS alias to exact emulator serial")
expect(mapped.name == b.name && mapped.id == b.id && mapped.json["metroName"] == nil, "AVD name/serial/public inventory unchanged")
expect(!String(decoding:try JSONEncoder().encode(mapped),as:UTF8.self).contains(androidName), "backend alias excluded from Codable inventory")
var second = Device(id:"emulator-5556",name:"Another AVD",platform:"android",width:320,height:640); second.metroName = androidName
let ambiguousAlias = try parsed([realAndroid],devices:[a,mapped,second])
expect(ambiguousAlias.values.first!.candidates == [b.id,second.id] && ambiguousAlias.values.first!.confirmation, "identical hardware labels require picker regardless of AVD names")
var unreadable = second; unreadable.metroName = nil
let partialAlias = try parsed([realAndroid],devices:[mapped,unreadable])
expect(partialAlias.values.first!.candidates == [b.id] && partialAlias.values.first!.confirmation, "unknown peer model cannot make alias falsely unique")
let explicitAlias = try parsed([raw("android",["deviceId":second.id,"deviceName":androidName])],devices:[mapped,second])
expect(explicitAlias.values.first!.candidates == [second.id] && !explicitAlias.values.first!.confirmation, "explicit advertised serial wins over shared model alias")
expect(try parsed([raw("android",["deviceId":"opaque-inspector-id","deviceName":androidName])],devices:[mapped]).values.first!.candidates.isEmpty, "unrecognized explicit identity never falls back to alias")
expect(try parsed([raw("android",["platform":"ios","deviceName":androidName])],devices:[a,mapped]).values.first!.candidates.isEmpty, "wrong advertised platform cannot match Android alias")
var fakeIOS = a; fakeIOS.metroName = androidName
expect(try parsed([realAndroid],devices:[fakeIOS]).values.first!.candidates.isEmpty, "alias is Android-only even if field exists on iOS record")
for name in ["sdk_gphone64_arm64", "sdk_gphone64_arm64 - 16 - API 35", "sdk_gphone64_arm64 - 15 - API 36", "sdk_gphone64_arm64 - 16 - API 36 Pro"] {
 expect(try parsed([raw("android",["deviceName":name])],devices:[mapped]).values.first!.candidates.isEmpty, "partial/different OS or API labels do not match")
}
expect(try parsed([realAndroid],devices:[a],old:matchedAlias).values.first!.candidates.isEmpty, "removed emulator cannot retain candidate from previous registry")
mapped.metroName = nil
expect(try parsed([realAndroid],devices:[mapped],old:matchedAlias).values.first!.candidates.isEmpty, "failed fresh property result cannot retain stale model alias")
mapped.metroName = "sdk_gphone64_arm64 - 15 - API 35"
expect(try parsed([realAndroid],devices:[mapped],old:matchedAlias).values.first!.candidates.isEmpty, "reused serial with different OS cannot reuse previous model mapping")
for data in [Data("{}".utf8),Data("not-json".utf8),jsonData([raw(),raw()]),jsonData((0..<65).map{raw(String($0))}),Data(repeating:32,count:1_048_577)] { do { _=try MetroCodec.targets(data,endpoint:endpoint,previous:[:],devices:[a]);fatalError("invalid inventory accepted") }catch{checks+=1} }
let stack=(0..<140).map { ["url":String(repeating:"u",count:800),"functionName":"fn","lineNumber":$0,"columnNumber":7] as [String:Any] }
let args=(0..<70).map{ _ in ["type":"object","description":String(repeating:"x",count:2000),"preview":["properties":(0..<30).map{["name":"p\($0)","value":String(repeating:"v",count:160)]}]] as [String:Any] }
let packet: [String:Any] = ["method":"Runtime.consoleAPICalled","params":["type":"warn","args":args,"timestamp":123.0,"stackTrace":["callFrames":stack]]]
let entry=MetroCodec.entry(packet,sequence:1)!
expect((entry["text"] as! String).utf8.count<=32768,"formatted text capped32KiB")
expect((entry["arguments"] as! [[String:Any]]).count==50,"arguments capped50")
expect((((entry["arguments"] as! [[String:Any]])[0])["preview"] as! [[String:Any]]).count==20,"preview properties capped20")
expect((entry["stack"] as! [[String:Any]]).count==100,"stack capped100")
expect(entry["level"] as? String == "warn","warn normalized")
for (source,level) in [("log","log"),("info","info"),("error","error"),("assert","error"),("warning","warn"),("debug","log")] {
 expect(MetroCodec.entry(["method":"Runtime.consoleAPICalled","params":["type":source,"args":[["type":"string","value":"<img src=x onerror=bad>\u{0000}"]]]],sequence:2)?["level"] as? String == level,"console level normalized")
}
let exception=MetroCodec.entry(["method":"Runtime.exceptionThrown","params":["exceptionDetails":["text":"Uncaught","exception":["description":"Fixture failure"],"stackTrace":["callFrames":stack]]]],sequence:3)!
expect(exception["text"] as? String == "Fixture failure" && exception["level"] as? String == "error","exception message immediately available")
expect(MetroCodec.entry(["method":"Debugger.paused","params":[:]],sequence:4)==nil,"unknown/debugger events ignored")
expect(!MetroCodec.text("hello\u{0000}\u{001B}world").contains("\u{0000}"),"control characters removed")
let slow=MetroOutput(),fast=MetroOutput()
for i in 0..<600 { let e:[String:Any] = ["sequence":i,"text":"entry"] ;slow.append(e);fast.append(e);_ = fast.take() }
expect(slow.entries.count==512 && slow.dropped==88,"slow subscriber oldest-entry ring bounded512")
expect(fast.entries.isEmpty && fast.dropped==0,"fast subscriber independent")
let big=MetroOutput();for i in 0..<200 {big.append(["sequence":i,"text":String(repeating:"x",count:32000)])}
expect(big.bytes<=1_048_576 && big.dropped>0,"subscriber byte budget1MiB enforced")
expect(MetroCodec.text(String(repeating:"🙂",count:20000),limit:32768).utf8.count<=32768,"UTF8 scalar truncation respects byte cap")
expect(!MetroCodec.metadata("id\n\tvalue").contains("\n"),"metadata control characters removed")
let report:[String:Any]=["passed":true,"checks":checks,"realMetroOrDeviceActions":false]
if let output=ProcessInfo.processInfo.environment["TEST_OUTPUT"] {try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true);try jsonData(report).write(to:URL(fileURLWithPath:output+"/metro-native.json"))}
print("\(checks) native Metro policy/normalization/buffer checks passed")
