import Foundation
import AppKit

var checks:[[String:Any]]=[]
func check(_ name:String,_ value:@autoclosure ()->Bool) {
    let ok=value();checks.append(["name":name,"passed":ok]);if !ok {fputs("FAIL: \(name)\n",stderr)}
}
let a="00000000-0000-4000-8000-000000000001",b="00000000-0000-4000-8000-000000000002",c="00000000-0000-4000-8000-000000000003"
let da=Device(id:a,name:"iPhone 11",platform:"ios",width:320,height:640),db=Device(id:b,name:"iPhone SE",platform:"ios",width:320,height:640)
let ea=SimulatorEntry(udid:a,name:da.name,state:"Booted",isAvailable:true),eb=SimulatorEntry(udid:b,name:db.name,state:"Booted",isAvailable:true)
let inventory=SimulatorInventory(devices:["inert":[ea,eb]])
func window(_ id:UInt32,_ name:String,_ x:CGFloat=0)->SimulatorWindowRef {SimulatorWindowRef(id:id,pid:901,title:name+" — iOS fixture",bounds:CGRect(x:x,y:-3000,width:320,height:640))}
func snapshot(_ windows:[SimulatorWindowRef],_ reliable:Bool=true,_ selection:Bool?=nil)->SimulatorWindowSnapshot {SimulatorWindowSnapshot(applications:[901],windows:windows,reliable:reliable,selectionReliable:selection)}
func mode(_ d:Device,_ s:SimulatorWindowSnapshot,_ inv:SimulatorInventory=inventory)->DeviceLaunchMode? {DeviceControl.recoveredIOSMode(d,inventory:inv,snapshot:s)}
check("complete native inventory recovers attached device as windowed",mode(da,snapshot([window(1,da.name)])) == .windowed)
check("complete native inventory recovers unattached booted device as headless",mode(db,snapshot([window(1,da.name)])) == .headless)
check("no native windows is positive headless evidence only with complete inventory",mode(db,snapshot([])) == .headless)
check("minimized/offscreen window is still windowed",mode(db,snapshot([window(2,db.name,-5000)])) == .windowed)
check("incomplete native inventory is not headless evidence",mode(db,snapshot([],false)) == nil)
check("uncertain window identity is not headless evidence",mode(db,snapshot([],true,false)) == nil)
check("unknown native window is not silently assigned to another device",mode(db,snapshot([window(3,"Unknown device")])) == nil)
check("unnamed native window blocks recovery",mode(db,snapshot([SimulatorWindowRef(id:4,pid:901,title:"",bounds:CGRect(x:0,y:0,width:320,height:640))])) == nil)
let duplicate=SimulatorInventory(devices:["inert":[ea,eb,SimulatorEntry(udid:c,name:db.name,state:"Shutdown",isAvailable:true)]])
check("same-name shutdown device still makes ownership ambiguous",mode(db,snapshot([]),duplicate) == nil)
let pro=SimulatorInventory(devices:["inert":[ea,eb,SimulatorEntry(udid:c,name:"iPhone 11 Pro",state:"Booted",isAvailable:true)]])
check("prefix device title does not turn iPhone11 into windowed",mode(da,snapshot([window(3,"iPhone 11 Pro")]),pro) == .headless)
check("wrong device UUID cannot inherit title ownership",mode(Device(id:c,name:da.name,platform:"ios",width:1,height:1),snapshot([])) == nil)
check("device name and selected inventory identity must agree",mode(Device(id:a,name:db.name,platform:"ios",width:1,height:1),snapshot([])) == nil)
check("shutdown selected device cannot be recovered as headless",mode(db,snapshot([]),SimulatorInventory(devices:["inert":[ea,SimulatorEntry(udid:b,name:db.name,state:"Shutdown",isAvailable:true)]])) == nil)
check("physical Android is excluded from iOS mode inference",mode(Device(id:"phone",name:"Phone",platform:"android",width:1,height:1),snapshot([])) == nil)
// Android uses the existing checked selected-process resolver, not visible windows.
let android=Device(id:"emulator-5554",name:"Pixel",platform:"android",width:320,height:640,avd:"Pixel")
var args=["qemu","-avd","Pixel","-no-window"],alive=true,resolves=0,reads=0
let processes=AndroidEmulatorProcessEffects(resolve:{device in resolves+=1;check("Android recovery keeps selected serial",device.id==android.id);return AndroidEmulatorProcess(pid:123,uid:501,startSeconds:1,startMicroseconds:2,executable:"inert-qemu",arguments:args)},isRunning:{_ in reads+=1;return alive},signal:{_,_,_ in fatalError("Mode lookup cannot signal")})
let noEffects=DeviceControl(adb:nil,windows:SimulatorWindowEffects(snapshot:{fatalError("Android recovery cannot inspect iOS windows")},close:{_ in fatalError("No close")},quitIfEmpty:{_ in fatalError("No quit")}),emulatorProcesses:processes,run:{_,_,_ in fatalError("No command")},launch:{_,_ in fatalError("No launch")})
check("Android -no-window is recovered from scoped process flags",noEffects.recoverLaunchModes([android],inventory:inventory)[android.id] == .headless)
args=["qemu","-avd","Pixel"];check("Android normal process is windowed",noEffects.recoverLaunchModes([android],inventory:inventory)[android.id] == .windowed)
args.append("-no-windowish");check("partial Android flag is not headless",noEffects.recoverLaunchModes([android],inventory:inventory)[android.id] == .windowed)
alive=false;check("reused/missing emulator identity is unknown",noEffects.recoverLaunchModes([android],inventory:inventory)[android.id] == nil)
let beforePhysical=resolves;check("physical Android never enters recovery resolver",noEffects.recoverLaunchModes([Device(id:"phone",name:"Phone",platform:"android",width:1,height:1)],inventory:inventory).isEmpty && resolves==beforePhysical)
check("recovered process identity was checked each time",reads==4)
final class Fixture {
    let lock=NSLock();var bAttached=false,reliable=true,bRunning=true,snapshots=0
    func inventory()->([Device],[[String:Any]],[String:DeviceWindow]) {lock.withLock {
        ([da]+(bRunning ? [db]:[]),bRunning ? []:[["id":b,"name":db.name,"platform":"ios"]],[:])
    }}
    func windows()throws->SimulatorWindowSnapshot {lock.withLock {snapshots+=1;return snapshot([window(1,da.name)]+(bAttached ? [window(2,db.name,-5000)]:[]),reliable)}}
}
let f=Fixture();var settings=Settings();settings.projectDirectory=CommandLine.arguments[1]
func devices()->Devices {Devices(settings:settings,control:DeviceControl(adb:nil,windows:SimulatorWindowEffects(snapshot:f.windows,close:{_ in fatalError("No close")},quitIfEmpty:{_ in fatalError("No quit")}),run:{_,_,_ in fatalError("No commands")},launch:{_,_ in fatalError("No launch")}),discovery:f.inventory,boot:{_,_ in fatalError("No boot")})}
func refresh(_ ds:Devices){let done=DispatchSemaphore(value:0);ds.requestRefresh{done.signal()};check("explicit discovery completed",done.wait(timeout:.now()+3) == .success)}
let first=devices();refresh(first)
check("first server publishes headless=true on an already-booted windowless device",first.device(b)?.headless==true)
check("first server publishes headless=false for actual native window",first.device(a)?.headless==false)
let second=devices();refresh(second)
check("fresh server instance recovers headless without old launch dictionary",second.device(b)?.headless==true)
let count=f.lock.withLock{f.snapshots};second.setStreamingDemand(true);Thread.sleep(forTimeInterval:1.35)
check("existing one-second discovery ticks do NOT poll native mode metadata",f.lock.withLock{f.snapshots}==count)
second.setStreamingDemand(false)
f.lock.withLock{f.bAttached=true};refresh(second)
check("explicit refresh discovers an attached/minimized window as windowed",second.device(b)?.headless==false)
f.lock.withLock{f.reliable=false};let uncertain=devices();refresh(uncertain)
check("fresh unreliable inventory publishes unknown rather than false",uncertain.device(b)?.headless==nil && uncertain.device(b)?.json["headless"] is NSNull)
check("ambiguous refresh cannot overwrite last reliable known mode",{refresh(second);return second.device(b)?.headless==false}())
f.lock.withLock{f.reliable=true;f.bRunning=false};refresh(first)
check("retired device disappears and mode ownership is forgotten",first.device(b)==nil)
f.lock.withLock{f.bRunning=true;f.bAttached=true};refresh(first)
check("same UUID reappearing cannot inherit old headless mode",first.device(b)?.headless==false)
first.stop();second.stop();uncertain.stop()
let passed=checks.allSatisfy{$0["passed"] as? Bool == true}
try JSONSerialization.data(withJSONObject:["passed":passed,"checks":checks,"real_device_actions":false,"real_window_actions":false,"real_input":false,"new_timer":false,"app_build":false,"app_restart":false],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("headless-mode-unit.json"))
print("Headless mode state checks: \(checks.count), passed: \(passed)");exit(passed ? 0:1)
