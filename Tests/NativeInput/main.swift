import Foundation
import ObjectiveC
import Darwin

// Inert state-machine, allocation and Objective-C transport tests. No selected
// device, CoreSimulator lookup, service creation, host input or simulator send.
var checks: [[String:Any]]=[]
func check(_ name: String, _ value: @autoclosure () throws -> Bool) rethrows {
    let ok=try value();checks.append(["name":name,"passed":ok]);if !ok {fputs("FAIL: \(name)\n",stderr)}
}
func rejects(_ name: String, _ body: () throws -> Void) {
    var rejected=false;do {try body()} catch {rejected=true};check(name,rejected)
}
func rawMessage(_ count: Int=1) -> UnsafeMutableRawPointer {
    let p=calloc(1,max(0xc0,0x20+count*0xa0))!
    p.storeBytes(of:UInt32(0xa0),toByteOffset:0x18,as:UInt32.self)
    p.storeBytes(of:UInt8(count),toByteOffset:0x1c,as:UInt8.self)
    for i in 0..<count {
        p.storeBytes(of:UInt32(11),toByteOffset:0x20+i*0xa0,as:UInt32.self)
        p.storeBytes(of:UInt32(0x32),toByteOffset:0x6c+i*0xa0,as:UInt32.self)
    }
    return p
}
final class Peer: NativeInputTransport {
    var events: [NativeHIDEvent]=[],closes=0,failAt: Int?,attempts=0
    var beforeSend: ((NativeHIDEvent)->Void)?
    func send(_ event: NativeHIDEvent) throws {
        attempts+=1;events.append(event);beforeSend?(event)
        if attempts==failAt {throw WispError("inert transport failure")}
    }
    func close() throws {closes+=1}
    var touches: [NativeTouch] {events.compactMap {if case .touch(let touch)=$0{return touch};return nil}}
}
let geometry=NativeInputGeometry(828,1792)!
func m(_ type: String, _ x: Double=0.25, _ y: Double=0.3) -> [String:Any] {["type":type,"x":x,"y":y]}
func serviceBuilders(_ symbols: NativeHIDSymbols) {
    for (name,make) in [("create pointer",symbols.createPointer),("remove pointer",symbols.removePointer),("create mouse",symbols.createMouse),("remove mouse",symbols.removeMouse)] {
        do {let message=try symbols.message(make());check("installed service message: "+name,(1...2).contains(message.count))}
        catch {fputs("Service message rejected: \(error.localizedDescription)\n",stderr);check("installed service message: "+name,false)}
    }
}
if CommandLine.arguments.contains("--services") {
    // NEW service-message constructors only; no old92 builders/unit checks.
    serviceBuilders(try NativeHIDSymbols())
} else if CommandLine.arguments.contains("--builders") {
    // Optional no-device ABI construction check: loads frameworks and builds
    // messages, but NEVER resolves a SimDevice, initializes a HID client or sends.
    let symbols=try NativeHIDSymbols()
    for phase in [NativeTouchPhase.down,.move,.up] {
        for edge in [NativeTouchEdge.none,.bottom,.left,.right,.top] {
            let message=try symbols.build(.touch(.init(phase:phase,identifier:17,point:CGPoint(x:0.25,y:0.75),edge:edge)))
            check("installed wrapper has two checked digitizer records",message.count==2)
            for base in [0x20,0xc0] {
                check("installed target argument initialized routing",message.pointer!.load(fromByteOffset:base+0x4c,as:UInt32.self)==0x32)
                check("installed edge flags preserve sticky routing",message.pointer!.load(fromByteOffset:base+0x1b,as:UInt8.self)==edge.rawValue)
            }
        }
    }
    for usage: UInt32 in [4,30,40,42,44,79,0xe1] {for down in [true,false] {
        let message=try symbols.build(.key(usage,down));check("installed keyboard layout guarded",message.count==1)
    }}
    for down in [true,false] {let message=try symbols.build(.home(down));check("installed Home layout guarded",message.count==1)}
    guard let cls=NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient") else {throw WispError("Missing installed HID class")}
    _ = try NativeHIDChannel.sender(cls);check("installed sender Objective-C signature accepted without client construction",true)
    serviceBuilders(symbols)
} else {
    for platform in ["ios","android",""] {for value in [nil,"current","native","auto","scrcpy","NATIVE","../native"] as [String?] {
        check("closed iOS input policy preserves Quartz/Android",IOSInputMode.selected(value,platform:platform) == (platform=="ios" && value=="native" ? .native:.quartz))
    }}
    for size in [(0,1),(1,0),(-1,20),(8193,20),(20,8193)] {check("invalid geometry rejected",NativeInputGeometry(size.0,size.1)==nil)}
    check("valid size extremes accepted",NativeInputGeometry(1,8192) != nil)
    var factories=0;let peer=Peer()
    let input=NativeIOSInput(id:"inert-A",makeTransport:{id in check("exact device passed to factory",id=="inert-A");factories+=1;return peer},sleep:{_ in})
    check("construction/idle allocate no transport",factories==0 && !input.connected)
    try input.perform(m("touch_move"),geometry:geometry);try input.perform(m("touch_up"),geometry:geometry)
    check("orphan move/up have no input or connection",factories==0 && peer.events.isEmpty)
    try input.perform(m("touch_down",0.5,0.999),geometry:geometry)
    for i in 0..<80 {try input.perform(m("touch_move",0.5,0.9-Double(i)/150),geometry:geometry)}
    try input.perform(m("touch_up",0.5,0.2),geometry:geometry)
    check("continuous drag is one down +80moves +one up",peer.touches.count==82 && peer.touches.first?.phase == .down && peer.touches.last?.phase == .up && peer.touches.dropFirst().dropLast().allSatisfy{$0.phase == .move})
    check("continuous drag retains one nonzero identifier",Set(peer.touches.map(\.identifier))==[1])
    check("bottom routing frozen across entire drag",peer.touches.allSatisfy{$0.edge == .bottom})
    check("normalized coordinates are not video-scaled again",peer.touches.first?.point == CGPoint(x:0.5,y:0.999) && peer.touches.last?.point == CGPoint(x:0.5,y:0.2))
    try input.perform(m("touch_down"),geometry:geometry);try input.perform(m("touch_down",0.6,0.6),geometry:geometry)
    check("replacement down first releases prior contact",peer.touches.suffix(3).map(\.phase)==[.down,.up,.down])
    let last=peer.touches.last!.identifier
    check("each gesture has a fresh identifier",last==3)
    _ = input.close();_ = input.close()
    check("close emits final UP and closes transport exactly once",peer.touches.last?.phase == .up && peer.touches.last?.identifier==last && peer.closes==1 && !input.connected)
    rejects("closed input cannot reopen itself"){try input.perform(m("touch_down"),geometry:geometry)}
    check("close never recreates a client",factories==1)
    let wrapped=Peer(),wrapInput=NativeIOSInput(id:"wrap",makeTransport:{_ in wrapped},sleep:{_ in},identifierSeed:UInt32.max)
    try wrapInput.perform(m("tap"),geometry:geometry);_ = wrapInput.close()
    check("identifier overflow skips zero",wrapped.touches.first?.identifier==1)
    for bad in [["type":"touch_down","x":Double.nan,"y":0.2],["type":"touch_down","x":Double.infinity,"y":0.2],["type":"touch_down","x":-0.1,"y":0.2],["type":"touch_down","x":true,"y":0.2],["type":"touch_down","x":0.3],["type":"text","text":"abc🙂"],["type":"text","text":String(repeating:"a",count:1025)],["type":"key","key":"unknown"],["type":"shell"],["type":"accessibility_swipe"]] as [[String:Any]] {
        var opened=0;let p=Peer(),s=NativeIOSInput(id:"bad",makeTransport:{_ in opened+=1;return p},sleep:{_ in})
        rejects("malformed/unsupported request rejected before connection"){try s.perform(bad,geometry:geometry)}
        check("invalid request cannot allocate resources or emit partial text",opened==0 && p.events.isEmpty);_ = s.close()
    }
    let resized=Peer(),resizeInput=NativeIOSInput(id:"resize",makeTransport:{_ in resized},sleep:{_ in})
    try resizeInput.perform(m("touch_down"),geometry:geometry)
    rejects("real geometry change cancels rather than warps an active drag"){try resizeInput.perform(m("touch_move"),geometry:NativeInputGeometry(1792,828)!)}
    check("resize uses old point/identifier for release",resized.touches.map(\.phase)==[.down,.up] && resized.touches[0].point==resized.touches[1].point);_ = resizeInput.close()
    for byte in UInt8(32)...UInt8(126) {check("all printable US ASCII decomposes",NativeKeyStroke.ascii(byte) != nil)}
    check("non-ASCII/control bytes rejected",NativeKeyStroke.ascii(0x80)==nil && NativeKeyStroke.ascii(0)==nil)
    let keyboard=Peer(),keyboardInput=NativeIOSInput(id:"keys",makeTransport:{_ in keyboard},sleep:{_ in})
    try keyboardInput.perform(["type":"text","text":"A!a"],geometry:geometry)
    check("Shift is paired around each uppercase/symbol",keyboard.events == [.key(0xe1,true),.key(4,true),.key(4,false),.key(0xe1,false),.key(0xe1,true),.key(30,true),.key(30,false),.key(0xe1,false),.key(4,true),.key(4,false)])
    try keyboardInput.perform(["type":"home"],geometry:geometry);try keyboardInput.perform(["type":"app_switcher"],geometry:geometry)
    check("Home and App switcher use device button pairs, no host shortcut",Array(keyboard.events.suffix(6)) == [.home(true),.home(false),.home(true),.home(false),.home(true),.home(false)]);_ = keyboardInput.close()
    for failure in 1...4 {
        let p=Peer();p.failAt=failure;let s=NativeIOSInput(id:"failure",makeTransport:{_ in p},sleep:{_ in})
        rejects("transport error is not hidden by Quartz fallback"){try s.perform(["type":"text","text":"A"],geometry:geometry)}
        check("failed Shift/key phases release held keys and close once",p.closes==1 && !s.connected && s.failure != nil)
        if failure<=3 {check("failed key phase ultimately releases Shift",p.events.last == .key(0xe1,false))}
        _ = s.close();check("failed cleanup is idempotent",p.closes==1)
    }
    var cancelled: NativeIOSInput!
    let cancellation=Peer()
    cancelled=NativeIOSInput(id:"cancel",makeTransport:{_ in cancellation},sleep:{_ in cancelled.invalidate()})
    rejects("pause/cancel interrupts an active tap"){try cancelled.perform(m("tap"),geometry:geometry)}
    check("cancellation releases the contact and connection",cancellation.touches.map(\.phase)==[.down,.up] && cancellation.closes==1);cancelled=nil
    var slowFactory: NativeIOSInput!
    let slow=Peer();slowFactory=NativeIOSInput(id:"slow",makeTransport:{_ in slowFactory.invalidate();return slow},sleep:{_ in})
    rejects("cancellation during lazy factory prevents first DOWN"){try slowFactory.perform(m("touch_down"),geometry:geometry)}
    check("late factory is immediately closed without input",slow.events.isEmpty && slow.closes==1);slowFactory=nil
    let idle=NativeIOSInput(id:"idle",makeTransport:{_ in fatalError("inactive input must never connect")});_ = idle.close();check("unused close has no work",!idle.connected)
    rejects("invalid UUID rejected before private loader"){_ = try NativeHIDTransport(udid:"not-a-device")}
    for edge in [NativeTouchEdge.none,.bottom,.left,.right,.top] {
        let message=try NativeHIDMessage(taking:rawMessage(2));try message.validateTouch(edge:edge)
        check("checked layout patches both records within allocation",message.pointer!.load(fromByteOffset:0x3b,as:UInt8.self)==edge.rawValue && message.pointer!.load(fromByteOffset:0xdb,as:UInt8.self)==edge.rawValue)
    }
    rejects("one-record stub cannot dispatch a digitizer touch"){let message=try NativeHIDMessage(taking:rawMessage());try message.validateTouch(edge:.none)}
    rejects("short allocation rejected before reading/patching records"){_ = try NativeHIDMessage(taking:calloc(1,16)!)}
    rejects("unknown stride rejected before patching"){let raw=rawMessage(2);raw.storeBytes(of:UInt32(0xb0),toByteOffset:0x18,as:UInt32.self);_ = try NativeHIDMessage(taking:raw)}
    rejects("unknown target rejected before dispatch"){let message=try NativeHIDMessage(taking:rawMessage(2));message.pointer!.storeBytes(of:UInt32(0),toByteOffset:0x10c,as:UInt32.self);try message.validateTouch(edge:.bottom)}
    rejects("unknown record type rejected before dispatch"){let message=try NativeHIDMessage(taking:rawMessage(2));message.pointer!.storeBytes(of:UInt32(2),toByteOffset:0xc0,as:UInt32.self);try message.validateTouch(edge:.none)}
}

@objc final class InertHID: NSObject {
    static var sends=0,live=0,fail=false,delay: TimeInterval=0,clientFailure=false
    @objc(initWithDevice:error:) init(device: NSObject) throws {
        super.init()
        if Self.clientFailure {throw WispError("inert initialization failure")}
        Self.live+=1
    }
    deinit {Self.live-=1}
    @objc(sendWithMessage:freeWhenDone:completionQueue:completion:)
    func send(_ pointer: UnsafeMutableRawPointer, freeWhenDone: Bool, completionQueue: DispatchQueue?, completion: ((NSError?)->Void)?) {
        Self.sends+=1;if freeWhenDone {free(pointer)}
        let error=Self.fail ? NSError(domain:"InertHID",code:7):nil
        if Self.delay>0 {completionQueue?.asyncAfter(deadline:.now()+Self.delay){completion?(error)}} else {completion?(error)}
    }
}
@objc final class WrongHID: NSObject {
    var invoked=false
    @objc(sendWithMessage:freeWhenDone:completionQueue:completion:)
    func send(_ pointer: UInt32, freeWhenDone: Bool, completionQueue: DispatchQueue?, completion: ((NSError?)->Void)?) {invoked=true;completion?(nil)}
}
if !CommandLine.arguments.contains("--builders") && !CommandLine.arguments.contains("--services") {
    let wrong=WrongHID();rejects("wrong sender ABI rejected before invocation"){_ = try NativeHIDChannel(client:wrong)};check("wrong IMP was never called",!wrong.invoked)
    try autoreleasepool {
        let client=try NativeHIDChannel.makeClient(InertHID.self,device:NSObject()),channel=try NativeHIDChannel(client:client)
        let message=try NativeHIDMessage(taking:rawMessage());try channel.send(message)
        check("freeWhenDone transfers allocation ownership once",message.pointer==nil && InertHID.sends==1)
        InertHID.fail=true;rejects("completion errors propagate"){try channel.send(NativeHIDMessage(taking:rawMessage()))};InertHID.fail=false
        channel.close();rejects("closed sender cannot dispatch"){try channel.send(NativeHIDMessage(taking:rawMessage()))}
    }
    check("alloc/init/ARC releases the client exactly once",InertHID.live==0)
    // Timeout exercises only this owned Objective-C peer and its late callback.
    try autoreleasepool {
        let client=try NativeHIDChannel.makeClient(InertHID.self,device:NSObject()),channel=try NativeHIDChannel(client:client,timeout:0.005)
        InertHID.delay=0.04;rejects("acknowledgement wait is bounded"){try channel.send(NativeHIDMessage(taking:rawMessage()))};channel.close();Thread.sleep(forTimeInterval:0.06);InertHID.delay=0
    }
    check("late ACK retains no client or input owner",InertHID.live==0)
}
let passed=checks.allSatisfy{$0["passed"] as? Bool == true},services=CommandLine.arguments.contains("--services"),builders=CommandLine.arguments.contains("--builders") || CommandLine.arguments.contains("--services")
let report: [String:Any] = ["passed":passed,"checks":checks,"private_message_construction":builders,"real_device_lookup":false,"real_client_connection":false,"real_input":false,"app_build":false,"app_restart":false]
let json=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
if CommandLine.arguments.count>1 {try json.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(services ? "native-input-services.json":builders ? "native-input-builders.json":"native-input-unit.json"))}
print("Native input \(services ? "no-device service":builders ? "no-device builder":"inert unit") checks: \(checks.count), passed: \(passed)")
exit(passed ? 0:1)
