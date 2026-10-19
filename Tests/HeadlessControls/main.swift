import Foundation
import ObjectiveC
import Darwin

// NEW checks only. Commands, SimDevice lookup and send-right release are inert.
// One owned local Mach port tests bounded send; it is NOT a simulator port.
var checks: [[String:Any]]=[]
func check(_ name: String, _ value: @autoclosure () -> Bool) {
    let ok=value();checks.append(["name":name,"passed":ok]);if !ok {fputs("FAIL: \(name)\n",stderr)}
}
func rejects(_ name: String, _ body: () throws -> Void) {
    var rejected=false;do {try body()} catch {rejected=true};check(name,rejected)
}
func word(_ data: Data, _ offset: Int) -> UInt32 {data.withUnsafeBytes {$0.loadUnaligned(fromByteOffset:offset,as:UInt32.self).littleEndian}}
let id="00000000-0000-4000-8000-000000000002",portrait=NativeInputGeometry(320,640)!,landscape=NativeInputGeometry(640,320)!
@objc final class InertDevice: NSObject {
    var calls:[String]=[],port:UInt32=17,fail=false
    @objc(lookup:error:) func lookup(_ name: NSString, error: AutoreleasingUnsafeMutablePointer<NSError?>) -> UInt32 {
        calls.append(name as String)
        if fail {error.pointee=NSError(domain:"InertLookup",code:7)}
        return port
    }
}
@objc final class WrongDevice: NSObject {
    var invoked=false
    @objc(lookup:error:) func lookup(_ name: NSString, error: AutoreleasingUnsafeMutablePointer<NSError?>) -> Int64 {invoked=true;return 17}
}
for orientation:UInt32 in [1,2,3,4] {
    let data=try HeadlessIOSControl.orientationMessage(orientation,port:17)
    check("orientation \(orientation) has exact backing/wire/header fields",data.count==112 && word(data,0)==0x13 && word(data,4)==108 && word(data,8)==17 && word(data,0x14)==0x7b)
    check("orientation \(orientation) has bounded workspace event payload",word(data,0x18)==50|0x20000 && word(data,0x48)==4 && word(data,0x4c)==orientation)
    let permitted=Set([0,4,8,0x14,0x18,0x48,0x4c].flatMap{Array($0..<$0+4)})
    check("orientation \(orientation) leaves padding/other payload zero",data.enumerated().allSatisfy{permitted.contains($0.offset)||$0.element==0})
}
for value:UInt32 in [0,5,UInt32.max] {rejects("invalid orientation \(value) cannot construct a packet"){_ = try HeadlessIOSControl.orientationMessage(value,port:17)}}
for value:UInt32 in [0,UInt32.max] {rejects("invalid port \(value) cannot construct a packet"){_ = try HeadlessIOSControl.orientationMessage(1,port:value)}}
let device=InertDevice();var sent:[Data]=[],released:[UInt32]=[]
try HeadlessIOSControl.rotate(device,orientation:3,send:{sent.append($0)},release:{released.append($0)})
check("guarded lookup targets only the workspace service",device.calls==["PurpleWorkspacePort"])
check("successful send releases owned lookup right once",sent.count==1 && released==[17])
rejects("send failure is surfaced without retry"){try HeadlessIOSControl.rotate(device,orientation:1,send:{_ in throw WispError("inert send timeout")},release:{released.append($0)})}
check("send failure still releases its right once",released==[17,17])
device.fail=true
rejects("lookup NSError is not hidden by nonzero port"){try HeadlessIOSControl.rotate(device,orientation:1,send:{sent.append($0)},release:{released.append($0)})}
check("lookup error drops its supplied right without dispatch",released==[17,17,17] && sent.count==1)
device.fail=false;device.port=0
rejects("missing workspace cannot send/release a null right"){try HeadlessIOSControl.rotate(device,orientation:1,send:{sent.append($0)},release:{released.append($0)})}
check("null lookup performs no send or deallocation",released.count==3 && sent.count==1)
device.port=UInt32.max
rejects("dead lookup right is refused"){try HeadlessIOSControl.rotate(device,orientation:1,send:{sent.append($0)},release:{released.append($0)})}
let wrong=WrongDevice()
rejects("wrong lookup ABI is rejected before invocation"){try HeadlessIOSControl.rotate(wrong,orientation:1,send:{sent.append($0)},release:{released.append($0)})}
check("wrong lookup IMP and send were never invoked",!wrong.invoked && sent.count==1)
device.port=17;var admitted=0
rejects("cancellation after lookup prevents send"){try HeadlessIOSControl.rotate(device,orientation:3,admission:{admitted+=1;if admitted==2 {throw NativeInputError.cancelled}},send:{sent.append($0)},release:{released.append($0)})}
check("cancellation releases lookup right and emits no packet",released.count==4 && sent.count==1)
var commands:[[String]]=[],timeouts:[Double]=[],lookups=0
let run:HeadlessIOSControl.Command={path,args,timeout in commands.append([path]+args);timeouts.append(timeout);return CommandResult(status:0,output:Data(),error:Data())}
try HeadlessIOSControl.perform("shake",id:id,geometry:portrait,resolve:{_ in lookups+=1;return device},run:run)
check("Shake targets exact UUID with constant notification and no shell",commands==[["/usr/bin/xcrun","simctl","notify_post",id,"com.apple.UIKit.SimulatorShake"]])
check("Shake is bounded and does not resolve/retain a SimDevice",timeouts==[5] && lookups==0)
for bad in ["all","booted","emulator-5554","../id",""] {rejects("selector \(bad) rejected before effects"){try HeadlessIOSControl.perform("shake",id:bad,geometry:portrait,run:run)}}
rejects("unknown action is rejected before effects"){try HeadlessIOSControl.perform("rotate;open",id:id,geometry:portrait,run:run)}
check("rejected actions executed no extra commands",commands.count==1)
rejects("Shake command status failure propagates"){try HeadlessIOSControl.perform("shake",id:id,geometry:portrait,run:{_,_,_ in CommandResult(status:1,output:Data(),error:Data("refused".utf8))})}
rejects("Shake command timeout propagates"){try HeadlessIOSControl.perform("shake",id:id,geometry:portrait,run:{_,_,_ in throw WispError("inert command timeout")})}
rejects("cancelled action has no command effect"){try HeadlessIOSControl.perform("shake",id:id,geometry:portrait,admission:{throw NativeInputError.cancelled},run:run)}
check("cancellation never reaches command runner",commands.count==1)
// Exercise the production bounded Mach sender only with a right owned here.
var port:mach_port_name_t=0
check("owned local test receive right allocated",mach_port_allocate(mach_task_self_,MACH_PORT_RIGHT_RECEIVE,&port)==KERN_SUCCESS)
check("owned local send right allocated",mach_port_insert_right(mach_task_self_,port,port,mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND))==KERN_SUCCESS)
let local=try HeadlessIOSControl.orientationMessage(1,port:port)
for _ in 0..<5 {try HeadlessIOSControl.sendOrientation(local)}
let started=Date()
rejects("full OWNED local queue returns bounded send timeout"){try HeadlessIOSControl.sendOrientation(local)}
check("local timeout does not block the worker indefinitely",Date().timeIntervalSince(started)<1)
check("owned local IPC rights destroyed",mach_port_destroy(mach_task_self_,port)==KERN_SUCCESS)
rejects("short orientation allocation rejected before Mach call"){try HeadlessIOSControl.sendOrientation(Data())}
final class Peer:NativeInputTransport {
    var events:[NativeHIDEvent]=[],closes=0,onSend:((NativeHIDEvent)->Void)?
    func send(_ event:NativeHIDEvent)throws {events.append(event);onSend?(event)}
    func close()throws {closes+=1}
}
var opens=0,actions=0
let idle=NativeIOSInput(id:id,makeTransport:{_ in opens+=1;return Peer()},sleep:{_ in})
try idle.performAction {admission in try admission();actions+=1}
try idle.performAction {admission in try admission();actions+=1}
check("idle system actions never create a HID peer",opens==0 && actions==2 && !idle.connected)
_ = idle.close()
rejects("closed owner refuses new system action"){try idle.performAction {_ in actions+=1}}
check("closed action never executed",actions==2)
let peer=Peer(),held=NativeIOSInput(id:id,makeTransport:{_ in peer},sleep:{_ in})
try held.perform(["type":"touch_down","x":0.3,"y":0.7],geometry:portrait)
try held.performAction {admission in try admission();check("system action follows the last-point held UP",peer.events.count==2 && {if case .touch(let t)=peer.events.last! {return t.phase == .up && t.point==CGPoint(x:0.3,y:0.7)};return false}())}
_ = held.close();check("system action cleanup cannot duplicate UP",peer.events.count==2 && peer.closes==1)
var cancelling:NativeIOSInput!
let cancelPeer=Peer();cancelling=NativeIOSInput(id:id,makeTransport:{_ in cancelPeer},sleep:{_ in})
try cancelling.perform(["type":"touch_down","x":0.4,"y":0.6],geometry:portrait)
cancelPeer.onSend={event in if case .touch(let t)=event,t.phase == .up {cancelling.invalidate()}}
rejects("cancellation during held UP prevents later system action"){try cancelling.performAction {_ in actions+=1}}
check("cancellation closed its peer with no system action",cancelPeer.closes==1 && actions==2);cancelling=nil
let failed=NativeIOSInput(id:id,makeTransport:{_ in fatalError("system action must not create HID")})
rejects("system action failure latches on its owner"){try failed.performAction {_ in throw WispError("inert action failure")}}
check("failed action is closed and unavailable without a peer",failed.failure=="inert action failure" && !failed.connected)
// Class ABI reflection only; never enumerate a SimDevice or connect a client.
_ = try NativeSimulatorDevice.load()
guard let cls=NSClassFromString("SimDevice") else {throw WispError("Installed SimDevice class missing")}
_ = try HeadlessIOSControl.lookupSignature(cls)
check("installed Xcode workspace lookup ABI accepted without device lookup",true)
let passed=checks.allSatisfy{$0["passed"] as? Bool == true}
let receipt:[String:Any] = ["passed":passed,"checks":checks,"real_device_lookup":false,"real_input":false,"simulator_port_lookup":false,"owned_local_mach_only":true,"app_build":false,"app_restart":false]
try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("headless-controls-unit.json"))
print("Headless iOS control new checks: \(checks.count), passed: \(passed)")
exit(passed ? 0:1)
