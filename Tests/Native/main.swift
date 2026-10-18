import Foundation
import IOSurface
import ObjectiveC
import CoreImage
import ScreenCaptureKit
import Darwin

// TEST ONLY: public-C seed lookup plus a targeted deterministic mid-copy race.
// NativeCapture.swift remains the actual production path; no simulator connection.
private typealias NativeSeedGetter = @convention(c) (IOSurface)->UInt32
private let actualNativeSeed = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern:-2),"IOSurfaceGetSeed")!,to:NativeSeedGetter.self)
private let nativeSeedLock=NSLock()
private var nativeBusyIDs=Set<UInt32>()
func forceNativeBusy(_ surface:IOSurface?,_ busy:Bool) {
    guard let surface else{return};nativeSeedLock.withLock {
        if busy {nativeBusyIDs.insert(IOSurfaceGetID(surface))} else {nativeBusyIDs.remove(IOSurfaceGetID(surface))}
    }
}
func IOSurfaceGetSeed(_ surface:IOSurface)->UInt32 {
    let actual=actualNativeSeed(surface)
    return nativeSeedLock.withLock {nativeBusyIDs.contains(IOSurfaceGetID(surface)) ? actual ^ 1:actual}
}

let fm=FileManager.default,root=URL(fileURLWithPath:CommandLine.arguments[1])
var checks=0
func expect(_ ok:Bool,_ name:String) {checks+=1;if !ok{fatalError("FAIL Native \(name)")}}
func rejects(_ name:String,_ body:()throws->Void){do{try body();expect(false,name)}catch{expect(true,name)}}
func surface(_ width:Int=320,_ height:Int=640,format:UInt32=0x42475241,variant:Bool=false)->IOSurface {
    let stride=((width*4+63)/64)*64
    let s=IOSurfaceCreate([kIOSurfaceWidth:width,kIOSurfaceHeight:height,kIOSurfaceBytesPerElement:4,kIOSurfaceBytesPerRow:stride,kIOSurfaceAllocSize:stride*height,kIOSurfacePixelFormat:format] as CFDictionary)!
    IOSurfaceLock(s,[],nil)
    let p=IOSurfaceGetBaseAddress(s).assumingMemoryBound(to:UInt8.self)
    memset(p,239,stride*height)
    for y in 0..<height {for x in 0..<width {
        let i=y*stride+x*4,top=y<height/2,right=x>=width/2
        // Top-left red, top-right yellow, bottom-left blue, bottom-right magenta.
        let rgb: (UInt8,UInt8,UInt8) = variant ? (0,255,0) : top ? right ? (255,255,0):(255,0,0) : right ? (255,0,255):(0,0,255)
        p[i]=rgb.2;p[i+1]=rgb.1;p[i+2]=rgb.0;p[i+3]=format==0x42475258 ? 0:255
    }}
    IOSurfaceUnlock(s,[],nil);return s
}
@objc final class FakeDisplay:NSObject { @objc var framebufferSurface:IOSurface?;init(_ s:IOSurface?){framebufferSurface=s} }
@objc final class FakePort:NSObject { @objc let portIdentifier:String;@objc let descriptor:NSObject;init(_ d:NSObject,identifier:String="com.apple.framebuffer.display"){descriptor=d;portIdentifier=identifier} }
@objc final class FakeIO:NSObject {
    private var ports:NSArray;var updates=0,inventoryReads=0
    @objc var deviceIOPorts:NSArray {get{inventoryReads+=1;return ports}set{ports=newValue}}
    init(_ d:FakeDisplay){ports=[FakePort(d)]}
    @objc func updateIOPorts(){updates+=1}
}
@objc final class WrongABI:NSObject {var called=false;@objc func framebufferSurface()->Int {called=true;return 5} }
@objc final class WrongVoid:NSObject {var called=false;@objc func updateIOPorts()->Int {called=true;return 5} }
@objc final class FakeSet:NSObject { @objc var availableDevices:NSArray=[] }
@objc final class FakeContext:NSObject {
    static let value=FakeContext();@objc let defaultDeviceSet=FakeSet()
    @objc(sharedServiceContextForDeveloperDir:error:) class func shared(_ dev:NSString,error:AutoreleasingUnsafeMutablePointer<NSError?>)->NSObject? {return value}
    @objc(defaultDeviceSetWithError:) func devices(_ error:AutoreleasingUnsafeMutablePointer<NSError?>)->NSObject? {return defaultDeviceSet}
}
func append(_ file:String,_ value:[String:Any]) {
    let url=root.appendingPathComponent(file)
    if !fm.fileExists(atPath:url.path){fm.createFile(atPath:url.path,contents:nil)}
    if let h=try? FileHandle(forWritingTo:url){_ = try? h.seekToEnd();try? h.write(contentsOf:jsonData(value)+Data([10]));try? h.close()}
}
func forwarding(_ target:NSObject)throws->NSObject {
    guard let cls=NSClassFromString("NativeTestForwarder"),let meta=object_getClass(cls) else {throw WispError("Missing inert forwarding fixture")}
    let (sel,imp)=try NativeInvoke.method(meta,"wrap:",returns:"@",arguments:["@"])
    typealias F = @convention(c) (AnyClass,Selector,AnyObject)->AnyObject?
    guard let proxy=unsafeBitCast(imp,to:F.self)(cls,sel,target) as? NSObject else {throw WispError("Inert forwarding fixture failed")};return proxy
}
// Synthetic provider exercises actual runtime selector dispatch and snapshot/VT.
final class FixtureSource:NativeSurfaceSource {
    let display=FakeDisplay(nil),overlay=FakeDisplay(nil),inactive=FakeDisplay(nil);let io:FakeIO;let bridge:NativeFramebufferSource
    let name=UUID().uuidString;var previous=Data(),closed=false,lastDiscoveryUpdates=0,lastDiscoveryReads=0
    init(){io=FakeIO(display);io.deviceIOPorts=[try! forwarding(FakePort(overlay)),try! forwarding(FakePort(display)),try! forwarding(FakePort(inactive))];bridge=NativeFramebufferSource(testIO:io);append("events.ndjson",["kind":"open","name":name])}
    func surface()throws->IOSurface? {
        defer {
            if io.updates != lastDiscoveryUpdates || io.inventoryReads != lastDiscoveryReads {
                append("discovery.ndjson",["name":name,"updates":io.updates,"inventory_reads":io.inventoryReads])
                lastDiscoveryUpdates=io.updates;lastDiscoveryReads=io.inventoryReads
            }
        }
        let bytes=(try? Data(contentsOf:root.appendingPathComponent("mode.json"))) ?? Data("{}".utf8),m=dictionary(bytes)
        if m["hold"] as? Bool==true || m["hold_ms"] != nil {append("events.ndjson",["kind":"hold","name":name]);Thread.sleep(forTimeInterval:min(3,max(0.1,Double(m["hold_ms"] as? Int ?? 300)/1000)))}
        if m["fail"] as? Bool==true {throw WispError("Native fixture unavailable <img src=x onerror=bad>")}
        if m["bad_descriptor"] as? Bool==true {
            forceNativeBusy(display.framebufferSurface,false);display.framebufferSurface=nil;overlay.framebufferSurface=nil
            io.deviceIOPorts=[try forwarding(FakePort(WrongABI()))]
            return try bridge.surface()
        }
        if m["inactive"] as? Bool==true {forceNativeBusy(display.framebufferSurface,false);display.framebufferSurface=nil;overlay.framebufferSurface=nil;previous=Data();return try bridge.surface()}
        if bytes != previous {
            forceNativeBusy(display.framebufferSurface,false)
            display.framebufferSurface=NativeTests.surface(m["width"] as? Int ?? 320,m["height"] as? Int ?? 640,variant:m["variant"] as? Bool==true)
            overlay.framebufferSurface=NativeTests.surface(19,11,variant:true)
            previous=bytes
        }
        forceNativeBusy(display.framebufferSurface,m["busy"] as? Bool==true)
        return try bridge.surface()
    }
    func close(){if closed{return};closed=true;forceNativeBusy(display.framebufferSurface,false);bridge.close();display.framebufferSurface=nil;overlay.framebufferSurface=nil;append("events.ndjson",["kind":"close","name":name])}
}
// Namespaced to avoid calling the protocol's surface accessor by accident.
enum NativeTests {static func surface(_ w:Int,_ h:Int,variant:Bool)->IOSurface {makeSurface(w,h,variant)}}
func makeSurface(_ w:Int,_ h:Int,_ variant:Bool)->IOSurface {surface(w,h,variant:variant)}

if CommandLine.arguments.contains("--serve") {
    var settings=Settings();settings.port=45156;settings.projectDirectory=root.path;settings.pairingToken="isolated-native-capture"
    let devices=Devices(settings:settings,discovery:{
        if fm.fileExists(atPath:root.appendingPathComponent("offline").path){return ([],[],[:])}
        let headless=fm.fileExists(atPath:root.appendingPathComponent("headless").path),m=(try? Data(contentsOf:root.appendingPathComponent("window.json"))).map(dictionary) ?? [:]
        let w=m["width"] as? Int ?? 320,h=m["height"] as? Int ?? 640
        let win=DeviceWindow(id:123,pid:0,title:"synthetic",bounds:CGRect(x:0,y:0,width:w,height:h),crop:CGRect(x:0,y:0,width:w,height:h))
        return ([Device(id:"native-fixture",name:"Native synthetic simulator",platform:"ios",width:w,height:h),Device(id:"native-second",name:"Second synthetic simulator",platform:"ios",width:w,height:h)],[],headless ? [:]:["native-fixture":win,"native-second":win])
    })
    let input=DeviceInput(devices:devices,handler:{m,id in append("input.ndjson",["id":id,"message":m]);return nil})
    var pixel:CVPixelBuffer?;CVPixelBufferCreate(nil,320,640,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&pixel)
    CIContext().render(CIImage(color:.blue).cropped(to:CGRect(x:0,y:0,width:320,height:640)),to:pixel!)
    var format:CMVideoFormatDescription?;CMVideoFormatDescriptionCreateForImageBuffer(allocator:nil,imageBuffer:pixel!,formatDescriptionOut:&format)
    var time=CMSampleTimingInfo(duration:.invalid,presentationTimeStamp:.zero,decodeTimeStamp:.invalid),sample:CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator:nil,imageBuffer:pixel!,formatDescription:format!,sampleTiming:&time,sampleBufferOut:&sample)
    let attachments=CMSampleBufferGetSampleAttachmentsArray(sample!,createIfNecessary:true) as! [NSMutableDictionary];attachments[0][SCStreamFrameInfo.status.rawValue]=SCFrameStatus.complete.rawValue
    final class FakeStream:CaptureStream {
        let capture:WindowCapture,sample:CMSampleBuffer
        init(_ c:WindowCapture,_ s:CMSampleBuffer){capture=c;sample=s}
        @MainActor func startCapture()async throws {append("window.ndjson",["kind":"open"]);capture.receive(sample,type:.screen)}
        @MainActor func stopCapture()async throws {
            if fm.fileExists(atPath:root.appendingPathComponent("window-close-hold").path) {
                append("events.ndjson",["kind":"window-close-begin"]);try await Task.sleep(nanoseconds:2_000_000_000)
            }
            append("window.ndjson",["kind":"close"]);append("events.ndjson",["kind":"window-close-done"])
        }
        @MainActor func removeStreamOutput(_ output:any SCStreamOutput,type:SCStreamOutputType)throws{}
    }
    let service=Service(settings:settings,pairingStateURL:root.appendingPathComponent("pairing-state.json"),tlsDirectory:root.appendingPathComponent("tls"),devices:devices,input:input,metroEndpoint:URL(string:"http://127.0.0.1:45156/empty-metro")!,makeNative:{_ in NativeCapture(source:{FixtureSource()})},makeCapture:{w in WindowCapture(target:w,makeStream:{c in FakeStream(c,sample!)})})
    service.stateChanged={s in if s=="Running" {print("Isolated Native service ready");fflush(stdout)}}
    try service.start()
    let signal=DispatchSource.makeSignalSource(signal:SIGTERM,queue:.main);Darwin.signal(SIGTERM,SIG_IGN);signal.setEventHandler{service.stop{exit(0)}};signal.resume();dispatchMain()
}

// Native metadata hot path: the production forwarding path must not repeat
// port/descriptor/inventory RPCs for every readable framebuffer poll.
@objc final class MetadataDisplay:NSObject {
    var image:IOSurface?,reads=0
    init(_ image:IOSurface?){self.image=image}
    @objc var framebufferSurface:IOSurface? {reads+=1;return image}
}
@objc final class MetadataPort:NSObject {
    var identifierValue="com.apple.framebuffer.display",descriptorValue:NSObject?
    var identifierReads=0,descriptorReads=0
    init(_ descriptor:NSObject?){descriptorValue=descriptor}
    @objc var portIdentifier:String {identifierReads+=1;return identifierValue}
    @objc var descriptor:NSObject? {descriptorReads+=1;return descriptorValue}
}
@objc final class MetadataIO:NSObject {
    var ports:[NSObject],reads=0,updates=0
    init(_ ports:[NSObject]){self.ports=ports}
    @objc var deviceIOPorts:NSArray {reads+=1;return ports as NSArray}
    @objc func updateIOPorts(){updates+=1}
}
// Owner23:02: discovery belongs to a healthy capture lifetime, never a poll.
do {
    let display=MetadataDisplay(surface(8,16)),port=MetadataPort(try forwarding(display))
    let io=MetadataIO([try forwarding(port)]),source=NativeFramebufferSource(testIO:io)
    defer{source.close()}
    for i in 0..<8 {
        let fresh=surface(8,16,variant:i%2==0);display.image=fresh
        expect(try source.surface() === fresh,"error-driven cache still fetches fresh pixels every frame")
    }
    append("error-cache-red-counts.ndjson",["frames":8,"io_updates":io.updates,"inventory_reads":io.reads,"identifier_reads":port.identifierReads,"descriptor_reads":port.descriptorReads,"surface_reads":display.reads])
    expect(io.reads==1,"healthy discovery inventory is resolved once, not polled")
    expect(io.updates==1 && port.identifierReads==1 && port.descriptorReads==1,"healthy source performs exactly one discovery")
    Thread.sleep(forTimeInterval:1.05)
    expect(try source.surface() === display.image,"healthy surface remains readable beyond former one-second TTL")
    expect(io.updates==1 && io.reads==1 && port.identifierReads==1 && port.descriptorReads==1,"elapsed time never expires healthy metadata")
}

let hotDisplay=MetadataDisplay(surface(32,64)),hotPort=MetadataPort(try forwarding(hotDisplay))
let hotIO=MetadataIO([try forwarding(hotPort)]),hotSource=NativeFramebufferSource(testIO:hotIO)
for _ in 0..<60 {expect(try hotSource.surface() === hotDisplay.image,"session cache still reads current framebuffer on every poll")}
append("metadata-call-counts.ndjson",["polls":60,"identifier_reads":hotPort.identifierReads,"descriptor_reads":hotPort.descriptorReads,"surface_reads":hotDisplay.reads,"inventory_reads":hotIO.reads,"io_updates":hotIO.updates])
expect(hotIO.updates==1 && hotIO.reads==1,"healthy metadata performs one update and one inventory lookup")
expect(hotPort.identifierReads==1 && hotPort.descriptorReads==1,"healthy identifiers/descriptors are discovered once per session")
expect(hotDisplay.reads==60,"current framebuffer stays live on every poll")
hotSource.close()

let liveMain=MetadataDisplay(surface(32,64)),liveSmall=MetadataDisplay(surface(9,11))
let liveMainPort=MetadataPort(try forwarding(liveMain)),liveSmallPort=MetadataPort(try forwarding(liveSmall)),ignoredPort=MetadataPort(NSObject())
ignoredPort.identifierValue="not-a-display"
let liveMainProxy=try forwarding(liveMainPort),liveSmallProxy=try forwarding(liveSmallPort),ignoredProxy=try forwarding(ignoredPort)
let liveIO=MetadataIO([liveMainProxy,liveSmallProxy,ignoredProxy])
let liveSource=NativeFramebufferSource(testIO:liveIO)
expect(try liveSource.surface() === liveMain.image,"session cache selects largest discovered live plane")
let rotatedMain=surface(64,32);liveMain.image=rotatedMain
expect(try liveSource.surface() === rotatedMain,"session cache never pins previous surface through rotation")
expect(liveMainPort.identifierReads==1 && liveMainPort.descriptorReads==1 && liveMain.reads==2,"rotation fetches current surface without metadata discovery")
liveSmall.image=surface(128,256)
expect(try liveSource.surface() === liveSmall.image,"a known smaller plane can become largest without rediscovery")
expect(ignoredPort.identifierReads==1 && ignoredPort.descriptorReads==0,"non-display classification never calls unrelated descriptor")
liveIO.ports=[ignoredProxy,liveSmallProxy,liveMainProxy]
expect(try liveSource.surface() === liveSmall.image,"inventory order cannot perturb discovered plane ranking")
expect(liveIO.reads==1 && liveIO.updates==1,"healthy acquisition never polls inventory even when it changes")

// Explicit no-polling tradeoff: a still-readable old binding cannot announce a
// silent replacement/identifier/topology change. Do NOT claim detection here.
let refreshedMain=MetadataDisplay(surface(256,512));liveMainPort.descriptorValue=try forwarding(refreshedMain)
let newlyClassified=MetadataDisplay(surface(513,1025))
ignoredPort.identifierValue="com.apple.framebuffer.display";ignoredPort.descriptorValue=try forwarding(newlyClassified)
let newMain=MetadataDisplay(surface(1027,2051)),newPort=MetadataPort(try forwarding(newMain)),newProxy=try forwarding(newPort)
liveIO.ports.append(newProxy)
expect(try liveSource.surface() === liveSmall.image,"silent metadata changes with healthy old surfaces are an explicit no-polling limitation")
expect(liveMainPort.descriptorReads==1 && ignoredPort.descriptorReads==0 && newPort.descriptorReads==0,"healthy bindings are not periodically reclassified or rediscovered")
// All known planes genuinely unavailable -> no stale surface returned; the
// next explicit read may rediscover once. NativeCapture's8s deadline is separate.
liveMain.image=nil;liveSmall.image=nil
expect(try liveSource.surface()==nil,"all known surfaces unavailable returns nil and retires discovery")
let prior=liveIO.updates
expect(try liveSource.surface() === newMain.image,"next explicit read rediscovers after real unavailability")
expect(liveIO.updates==prior+1 && liveIO.reads==2,"unavailability triggers exactly one new discovery on the next read")
expect(liveMainPort.identifierReads==2 && liveMainPort.descriptorReads==2 && ignoredPort.descriptorReads==1,"failure-driven discovery observes same-port descriptor and identifier changes")
expect(newPort.descriptorReads==1,"failure-driven discovery admits new current topology")
// Known-plane ambiguity is still checked on EVERY surface acquisition.
newlyClassified.image=surface(2051,1027)
let beforeTie=liveIO.updates
rejects("known distinct tied-largest surfaces still fail visibly without hidden retry"){_ = try liveSource.surface()}
expect(liveIO.updates==beforeTie,"a failing call never silently retries discovery")
newlyClassified.image=IOSurfaceLookup(IOSurfaceGetID(newMain.image!))
expect(try liveSource.surface() != nil,"later explicit read can rediscover same-kernel aliases after visible failure")
expect(liveIO.updates==beforeTie+1,"visible failure invalidates cached discovery before a later read")
// Explicitly demonstrate the removed topology polling guarantee, then recover
// only after actual old-surface loss. New source creation always discovers fresh.
liveIO.ports=[newProxy]
expect(try liveSource.surface().map{IOSurfaceGetID($0)}==IOSurfaceGetID(newMain.image!),"healthy bindings are not refreshed merely because external inventory changed")
let beforeLoss=liveIO.updates
refreshedMain.image=nil;newlyClassified.image=nil;newMain.image=nil
expect(try liveSource.surface()==nil,"real old-surface loss releases all known metadata")
let woke=MetadataDisplay(surface(77,155));newPort.descriptorValue=try forwarding(woke)
expect(try liveSource.surface() === woke.image,"failure-driven discovery sees current reduced topology and descriptor")
expect(liveIO.updates==beforeLoss+1,"no inventory audit before source becomes unavailable")
let badCached=WrongABI();newPort.descriptorValue=badCached;woke.image=nil
expect(try liveSource.surface()==nil,"unavailability retires descriptor before replacement inspection")
let beforeABI=liveIO.updates
rejects("newly discovered scalar framebuffer ABI remains visibly refused"){_ = try liveSource.surface()}
expect(!badCached.called && liveIO.updates==beforeABI+1,"wrong framebuffer IMP remains uncalled with no hidden retry")
newPort.descriptorValue=try forwarding(woke);woke.image=surface(77,155)
expect(try liveSource.surface() === woke.image,"explicit subsequent read rediscovers after original ABI failure")
woke.image=nil;expect(try liveSource.surface()==nil,"missing current surface cannot replay last pixels")
liveIO.ports=[]
rejects("empty discovery inventory cannot reuse previously cached planes"){_ = try liveSource.surface()}
liveSource.close();rejects("closed source cannot rediscover metadata"){_ = try liveSource.surface()}

// A non-IOSurface getter result is a genuine access failure, not a reason to
// hide the error or retry inside the same call.
@objc final class InvalidatableMetadataDisplay:NSObject {
    var value:NSObject?,reads=0
    init(_ value:NSObject?){self.value=value}
    @objc var framebufferSurface:NSObject? {reads+=1;return value}
}
do {
    let old=InvalidatableMetadataDisplay(surface(11,23)),port=MetadataPort(old),io=MetadataIO([])
    io.ports=[port];let source=NativeFramebufferSource(testIO:io)
    expect(try source.surface() != nil,"guarded object-return surface initially valid")
    old.value=NSObject();let replacement=MetadataDisplay(surface(31,61));port.descriptorValue=replacement
    rejects("cached invalid surface type propagates original failure"){_ = try source.surface()}
    expect(io.updates==1 && io.reads==1 && port.descriptorReads==1,"invalid result does not recursively retry or conceal error")
    expect(try source.surface() === replacement.image,"next explicit attempt resolves replacement after actual cached-getter failure")
    expect(io.updates==2 && io.reads==2 && port.descriptorReads==2,"one bounded rediscovery per explicit failed-source recovery")
    source.close()
}

@objc final class LegacyMetadataPort:NSObject {
    var image:IOSurface?,identifierReads=0,surfaceReads=0
    init(_ image:IOSurface?){self.image=image}
    @objc var identifier:String {identifierReads+=1;return "com.apple.framebuffer.display"}
    @objc var ioSurface:IOSurface? {surfaceReads+=1;return image}
}
@objc final class LegacyMetadataIO:NSObject {
    @objc var ioPorts:NSArray
    init(_ port:NSObject){ioPorts=[port]}
}
let legacyPort=LegacyMetadataPort(surface(11,23)),legacySource=NativeFramebufferSource(testIO:LegacyMetadataIO(try forwarding(legacyPort)))
for _ in 0..<20 {expect(try legacySource.surface() === legacyPort.image,"identifier/ioPorts/ioSurface legacy getters remain live")}
expect(legacyPort.identifierReads==1 && legacyPort.surfaceReads==20,"legacy discovery is cached, never its surface")
legacySource.close()

@objc final class BadMetadataPort:NSObject {
    @objc let portIdentifier="com.apple.framebuffer.display";var called=false
    @objc func descriptor()->Int {called=true;return 7}
}
let badPort=BadMetadataPort(),badMetadataSource=NativeFramebufferSource(testIO:MetadataIO([try forwarding(badPort)]))
rejects("metadata descriptor scalar ABI still rejected"){_ = try badMetadataSource.surface()}
expect(!badPort.called,"session discovery cannot admit unchecked forwarded IMP")
badMetadataSource.close()
let boundDisplay=MetadataDisplay(surface(7,13)),boundPort=MetadataPort(boundDisplay)
let boundIO=MetadataIO(Array(repeating:boundPort,count:NativeFramebufferSource.maxPorts+1)),boundSource=NativeFramebufferSource(testIO:boundIO)
rejects("oversized discovery inventory is bounded before metadata calls"){_ = try boundSource.surface()}
expect(boundPort.identifierReads==0 && boundPort.descriptorReads==0,"oversized inventory performs no identifier/descriptor RPCs")
boundIO.ports=Array(repeating:boundPort,count:NativeFramebufferSource.maxPorts)
expect(try boundSource.surface() === boundDisplay.image,"explicit next attempt accepts exact discovery bound")
expect(boundPort.identifierReads==1 && boundPort.descriptorReads==1,"duplicate owners occupy one bounded metadata entry")
for _ in 0..<4 {_ = try boundSource.surface()}
expect(boundIO.reads==2 && boundIO.updates==2,"healthy bounded source never rediscovers after explicit failed attempt")
boundSource.close()

final class WeakMetadataOwner {weak var value:NSObject?;init(_ value:NSObject){self.value=value}}
let retireIO=MetadataIO([]),retireSource=NativeFramebufferSource(testIO:retireIO)
var retiredMetadata:[WeakMetadataOwner]=[],previousDisplay:MetadataDisplay?
for _ in 0..<32 {
    if let previousDisplay {previousDisplay.image=nil;expect(try retireSource.surface()==nil,"unavailable known surface retires old discovery generation")}
    try autoreleasepool {
        let display=MetadataDisplay(surface(7,13)),port=MetadataPort(display)
        retiredMetadata.append(WeakMetadataOwner(port));retireIO.ports=[port];previousDisplay=display
        expect(try retireSource.surface() === display.image,"failure-driven replacement reads current owner")
    }
    expect(retiredMetadata.dropLast().allSatisfy{$0.value==nil},"failure-driven rediscovery releases old owners without retained history")
}
autoreleasepool {retireIO.ports=[]}
expect(retiredMetadata.last!.value != nil,"healthy session owns discovered port identity even when external inventory changes")
retireSource.close()
expect(retiredMetadata.allSatisfy{$0.value==nil},"close releases every discovered owner and descriptor")

// Busy snapshot reads happen AFTER discovery; neither seed nor pool contention
// can cause metadata refresh, encoder/epoch churn, or extend the8s deadline.
do {
    let display=MetadataDisplay(surface(16,32)),port=MetadataPort(display),io=MetadataIO([port])
    let source=NativeFramebufferSource(testIO:io);var time=0.0
    let capture=NativeCapture(source:{source},clock:{time})
    let initial=try capture.h264(quality:20,fps:60,forceKeyframe:true,dataSaver:false)!
    forceNativeBusy(display.image,true)
    for i in 1...12 {
        time=Double(i)/2
        let video=try capture.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:false)
        expect(video?.generation==initial.generation,"busy source keeps capture generation without rediscovery")
    }
    expect(io.updates==1 && io.reads==1 && port.descriptorReads==1,"busy/torn snapshot reads never invalidate metadata")
    time=8.01
    rejects("error-driven discovery never weakens readable-source8s deadline"){_ = try capture.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:false)}
    expect(io.updates==1 && io.reads==1,"busy deadline failure does not cause hidden metadata retry")
    forceNativeBusy(display.image,false);capture.stop()
}

// Owner2075: proxies may advertise a getter without a concrete Method/IMP.
let forwardedDisplay=FakeDisplay(surface(17,31)),forwardedPort=try forwarding(FakePort(forwardedDisplay))
expect(class_getInstanceMethod(object_getClass(forwardedPort),NSSelectorFromString("portIdentifier"))==nil,"port getter genuinely absent from proxy class metadata")
expect(forwardedPort.responds(to:NSSelectorFromString("portIdentifier")),"proxy advertises forwarded port getter")
expect(try NativeInvoke.object(forwardedPort,"portIdentifier")?.description=="com.apple.framebuffer.display","forwarded portIdentifier is safely supported")
let forwardedIO=FakeIO(forwardedDisplay);forwardedIO.deviceIOPorts=[forwardedPort]
let forwardedBridge=NativeFramebufferSource(testIO:forwardedIO)
expect(try forwardedBridge.surface() === forwardedDisplay.framebufferSurface,"forwarded port discovery selects exact display")
forwardedBridge.close()
let forwardedWrong=WrongABI()
rejects("forwarded scalar ABI still refused"){_ = try NativeInvoke.object(forwarding(forwardedWrong),"framebufferSurface")}
expect(!forwardedWrong.called,"forwarded wrong-ABI getter never invoked")
rejects("missing forwarded getter refused"){_ = try NativeInvoke.object(forwarding(NSObject()),"portIdentifier")}
expect(try NativeInvoke.optionalObject(forwarding(NSObject()),"portIdentifier")==nil,"truly absent optional getter remains optional")
for platform in ["ios","android",""] {for value in [nil,"native","current","auto","raw","NATIVE","../native"] as [String?] {
    expect(IOSCaptureMode.selected(value,platform:platform) == (platform=="ios" && value=="native" ? .native:.window),"closed iOS-only policy")
}}
let wrong=WrongABI();rejects("ABI scalar return refused"){_ = try NativeInvoke.object(wrong,"framebufferSurface")};expect(!wrong.called,"wrong IMP never invoked")
let wrongVoid=WrongVoid();rejects("ABI wrong void refused"){try NativeInvoke.update(wrongVoid)};expect(!wrongVoid.called,"wrong update never invoked")
rejects("missing selector refused"){_ = try NativeInvoke.object(NSObject(),"io")}
let context=try NativeInvoke.context(FakeContext.self,developer:"/synthetic")
expect(context === FakeContext.value,"class object/error ABI")
expect(try NativeInvoke.deviceSet(context) === FakeContext.value.defaultDeviceSet,"instance object/error ABI")
// Owner2078: multiple framebuffer ports can be main + secondary planes.
// Exercise the production selector, not an isolated imitation of its ranking.
func selectedPlane(_ ports:[NSObject])throws->IOSurface? {
    let io=FakeIO(FakeDisplay(nil));io.deviceIOPorts=ports as NSArray
    let source=NativeFramebufferSource(testIO:io);defer{source.close()};return try source.surface()
}
func planePorts(_ displays:[NSObject])throws->[NSObject] {try displays.map{try forwarding(FakePort($0))}}
let mainPlane=surface(73,121),smallPlane=surface(97,11),mainDisplay=FakeDisplay(mainPlane),smallDisplay=FakeDisplay(smallPlane),inactiveDisplay=FakeDisplay(nil)
for displays in [[smallDisplay,mainDisplay],[mainDisplay,smallDisplay]] {
    expect(try selectedPlane(planePorts(displays)) === mainPlane,"main+overlay selects largest area independent of port order")
}
let alias=IOSurfaceLookup(IOSurfaceGetID(mainPlane))!
expect(IOSurfaceGetID(alias)==IOSurfaceGetID(mainPlane),"alias references the same kernel surface")
expect(try selectedPlane(planePorts([mainDisplay,FakeDisplay(alias)])) != nil,"two descriptors aliasing one surface are not two screens")
expect(try selectedPlane(planePorts([mainDisplay,mainDisplay])) === mainPlane,"duplicate descriptor is harmless")
let repeatedPort=try forwarding(FakePort(mainDisplay))
expect(try selectedPlane([repeatedPort,repeatedPort]) === mainPlane,"duplicate port is harmless")
for displays in [[inactiveDisplay,mainDisplay],[mainDisplay,inactiveDisplay]] {
    expect(try selectedPlane(planePorts(displays)) === mainPlane,"inactive secondary port does not hide readable main")
}
expect(try selectedPlane(planePorts([inactiveDisplay,FakeDisplay(nil)]))==nil,"all inactive planes return nil instead of a false ambiguity")
let equalDisplay=FakeDisplay(surface(121,73))
for displays in [[mainDisplay,equalDisplay],[equalDisplay,mainDisplay],[smallDisplay,mainDisplay,equalDisplay],[mainDisplay,equalDisplay,mainDisplay]] {
    rejects("distinct tied-largest surfaces remain ambiguous"){_ = try selectedPlane(planePorts(displays))}
}
let otherSmall=FakeDisplay(surface(11,97))
for displays in [[smallDisplay,otherSmall,mainDisplay],[mainDisplay,smallDisplay,otherSmall]] {
    expect(try selectedPlane(planePorts(displays)) === mainPlane,"smaller-plane ties do not make the largest ambiguous")
}
let dynamicIO=FakeIO(mainDisplay),dynamicSource=NativeFramebufferSource(testIO:dynamicIO)
dynamicIO.deviceIOPorts=try planePorts([smallDisplay,mainDisplay]) as NSArray
expect(try dynamicSource.surface() === mainPlane,"initial main selected")
let resizedPlane=surface(121,73);mainDisplay.framebufferSurface=resizedPlane
expect(try dynamicSource.surface() === resizedPlane,"rotation replaces selected surface without pinning old identity")
mainDisplay.framebufferSurface=nil;smallDisplay.framebufferSurface=nil
expect(try dynamicSource.surface()==nil,"inactive planes never return the previous selected surface")
mainDisplay.framebufferSurface=mainPlane
expect(try dynamicSource.surface() === mainPlane,"readable main can return after inactive state");dynamicSource.close()
let ignored=FakePort(FakeDisplay(surface(150,150)),identifier:"com.apple.framebuffer.external")
expect(try selectedPlane([ignored,FakePort(mainDisplay)]) === mainPlane,"do not broaden exact framebuffer identifier matching")
rejects("no matching framebuffer remains a visible failure"){_ = try selectedPlane([ignored])}
let badMain=surface(64,128,format:0x52474241),badDisplay=FakeDisplay(badMain),validSmall=FakeDisplay(surface(5,7))
expect(try selectedPlane(planePorts([validSmall,badDisplay])) === badMain,"unsupported largest is not silently replaced with a smaller plane")
rejects("unsupported chosen layout still rejected"){_ = try NativeCapture.snapshot(selectedPlane(planePorts([validSmall,badDisplay]))!)}
let scalarPlane=WrongABI()
rejects("scalar framebuffer getter in matching port remains refused"){_ = try selectedPlane([FakePort(mainDisplay),FakePort(scalarPlane)])}
expect(!scalarPlane.called,"selection never invokes a scalar getter through object ABI")
let s=surface(17,31),d=FakeDisplay(s),io=FakeIO(d),bridge=NativeFramebufferSource(testIO:io)
expect(try bridge.surface() === s,"runtime dispatch retains correct surface")
expect(io.updates==1,"IO refreshed once not per frame")
_ = try bridge.surface();expect(io.updates==1,"IO refresh bounded")
d.framebufferSurface=nil;expect(try bridge.surface()==nil,"inactive surface explicit")
d.framebufferSurface=s
io.deviceIOPorts=[FakePort(d),FakePort(FakeDisplay(surface(17,31)))];rejects("distinct equal-size displays refused"){_ = try bridge.surface()}
io.deviceIOPorts=[];rejects("missing display refused"){_ = try bridge.surface()}
bridge.close();rejects("closed source refused"){_ = try bridge.surface()}
let p=try NativeCapture.snapshot(s)!
expect(p.bytes.count==17*31*4,"padding excluded")
for (x,y,rgb) in [(1,1,[255,0,0]),(16,1,[255,255,0]),(1,30,[0,0,255]),(16,30,[255,0,255])] {
    let i=(y*17+x)*4;expect([Int(p.bytes[i+2]),Int(p.bytes[i+1]),Int(p.bytes[i])]==rgb,"four corners stay top-down")
}
let x=try NativeCapture.snapshot(surface(17,31,format:0x42475258))!
expect(x.bytes==p.bytes,"BGRX explicitly opaque, not transparent black")
rejects("unsupported RGBA not guessed"){_ = try NativeCapture.snapshot(surface(8,16,format:0x52474241))}
rejects("oversize geometry refused before copy"){_ = try NativeCapture.snapshot(surface(1,8193))}
// Scaling is output-only: full source identity/pixels stay authoritative.
for value in [nil,"","0","2","NaN","0.50","0.250","../","1e0"] as [String?] {
    expect(IOSCaptureScale.normalized(value) == .full,"invalid Native scale defaults to x1")
}
final class ScaleSource:NativeSurfaceSource {
    var value:IOSurface?;var closed=false
    init(_ value:IOSurface){self.value=value}
    func surface()throws->IOSurface? {value}
    func close(){value=nil;closed=true}
}
// Regression RED: same-layout transient read must NOT invalidate last-readable
// owned pixels, decoder generation or stream/input availability. Not packet replay.
do {
    let src=ScaleSource(surface(73,121)),cap=NativeCapture(source:{src})
    defer {forceNativeBusy(src.value,false);cap.stop()}
    let first=try cap.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:false)!
    forceNativeBusy(src.value,true)
    let busy=try cap.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:false)
    expect(busy != nil,"transient seed mismatch preserves last owned image with NEW H264")
    expect(busy!.frame.timestamp>first.frame.timestamp && busy!.generation==first.generation,"busy read keeps PTS fresh and decoder generation stable")
    expect(cap.diagnostics["cached_image_available"] as? Bool==true,"busy read keeps stream and touch availability")
    expect(cap.diagnostics["encoder_creations"] as? Int==1 && cap.diagnostics["prepared_pixel_buffers"] as? Int==1,"busy uses owned prepared image without encoder recreation")
    forceNativeBusy(src.value,false)
    let recovered=try cap.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:false)!
    expect(recovered.generation==first.generation,"busy recovery does not hard-reset decoder")
}

// Pool ownership: actual IOSurface lock/copy, exact packed bytes and immutable
// consumers, including a layout change while all three older leases are held.
func ownedPixels(_ reader:NativeSnapshotReader,_ surface:IOSurface)throws->NativeCapture.Pixels {
    switch try reader.read(surface) {
    case .pixels(let pixels,_):return pixels
    case .busy:expect(false,"owned pool unexpectedly exhausted");fatalError()
    }
}
do {
    let reader=NativeSnapshotReader(),red=surface(17,31),green=surface(17,31,variant:true)
    var held:[NativeCapture.Pixels]=[]
    for i in 0..<3 {held.append(try ownedPixels(reader,i==1 ? green:red))}
    expect(reader.diagnostics["snapshot_buffers"]==3 && reader.diagnostics["snapshot_leased_buffers"]==3,"three immutable consumer leases stay bounded")
    expect(held[0].bytes[2]==255 && held[0].bytes[1]==0 && held[1].bytes[1]==255,"later copies never mutate prior consumers")
    switch try reader.read(green) {case .busy(_,let reason):expect(reason == .storage,"pool pressure is explicitly busy, not unsafe reuse");case .pixels:expect(false,"fourth retained consumer must not allocate")}
    expect(reader.diagnostics["snapshot_buffer_allocations"]==3,"pool cannot grow past three buffers")
    held.removeFirst()
    let reused=try ownedPixels(reader,green)
    expect(reused.bytes[1]==255 && reader.diagnostics["snapshot_buffer_reuses"]==1,"released immutable lease is reused")
    // A larger new layout cannot evade the bound by abandoning old leases.
    switch try reader.read(surface(19,33)) {case .busy(_,let reason):expect(reason == .storage,"retired leases count toward global pool bound");case .pixels:expect(false,"retired buffers must not escape bound")}
    expect(reader.diagnostics["snapshot_buffers"]==3,"geometry retains at most three leased buffers total")
    held.removeAll();reader.reset()
    expect(reader.diagnostics["snapshot_buffers"]==1,"reset releases idle buffers but not an external immutable consumer")
    expect(reused.bytes[1]==255,"reset does not revoke or corrupt consumer bytes")
}
do {
    let reader=NativeSnapshotReader(),large=surface(96,192)
    for _ in 0..<40 {try autoreleasepool {let p=try ownedPixels(reader,large);expect(p.bytes.count==96*192*4,"packed snapshot size remains exact")}}
    expect(reader.diagnostics["snapshot_buffer_allocations"]==1 && reader.diagnostics["snapshot_buffer_reuses"]==39,"steady snapshots allocate once and reuse without full-frame zero/free")
    let small=try ownedPixels(reader,surface(8,16))
    expect(reader.diagnostics["snapshot_buffer_bytes"]==8*16*4 && small.bytes.count==8*16*4,"downsize releases old oversized idle storage")
    let tiny=try ownedPixels(reader,surface(1,1))
    expect(tiny.bytes==Data([255,0,255,255]),"tiny Data inline copying cannot expose uninitialized or reused memory")
    let bgrx=try ownedPixels(reader,surface(17,31,format:0x42475258))
    expect(bgrx.bytes==p.bytes,"BGRX normalization after unlock preserves packed four corners and opacity")
}
// Busy behavior, deadline and real absence are distinct. No wall-clock sleeps.
do {
    var now=100.0
    let src=ScaleSource(surface(73,121)),cap=NativeCapture(source:{src},clock:{now})
    defer {forceNativeBusy(src.value,false);cap.stop()}
    let first=try cap.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:false)!
    forceNativeBusy(src.value,true)
    var last=first.frame.timestamp
    for i in 0..<12 {
        now=100+Double(i)/10
        let video=try cap.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:false)!
        expect(video.generation==first.generation && video.frame.timestamp>last,"every busy DSoff encode is NEW without epoch churn");last=video.frame.timestamp
        expect(cap.diagnostics["cached_image_available"] as? Bool==true,"busy preserves existing stream/input readiness")
    }
    expect(cap.diagnostics["busy_seed_snapshots"] as? Int==12 && cap.diagnostics["inactive_surfaces"] as? Int==0,"busy reason counters distinguish actual absence")
    expect(cap.diagnostics["busy_cached_image_encodes"] as? Int==12 && cap.diagnostics["source_frames"] as? Int==1,"busy encode is not falsely a fresh source image")
    expect(try cap.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:true)==nil,"busy DSon idles without discarding readable pixels")
    expect(cap.diagnostics["cached_image_available"] as? Bool==true,"busy DSon keeps touch continuity despite nil video")
    let idr=try cap.h264(quality:1,fps:30,forceKeyframe:true,dataSaver:true)!
    expect(idr.frame.keyframe && idr.generation==first.generation,"forced busy IDR/FPS/quality reuse encoder and epoch")
    now=107.9
    expect(try cap.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:false) != nil,"busy last-good image allowed only before readable deadline")
    now=108.01
    rejects("cached busy encodes do not hide eight-second source failure"){_ = try cap.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:false)}
    expect(cap.diagnostics["cached_image_available"] as? Bool==false && cap.diagnostics["snapshot_buffer_bytes"] as? Int==0,"busy timeout releases last-readable cache/storage")
}
do {
    var now=0.0
    let image=surface(73,121),src=ScaleSource(image),cap=NativeCapture(source:{src},clock:{now})
    defer {forceNativeBusy(image,false);cap.stop()}
    forceNativeBusy(image,true)
    expect(try cap.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:false)==nil,"first busy read cannot invent cached pixels")
    expect(cap.diagnostics["cached_image_available"] as? Bool==false && cap.diagnostics["encoder_creations"] as? Int==0,"no encoder or input readiness before first coherent image")
    now=8.1;rejects("first coherent image deadline remains bounded"){_ = try cap.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:false)}
}
for newImage in [surface(121,73),surface(73,121,format:0x42475258)] {
    let old=surface(73,121),src=ScaleSource(old),cap=NativeCapture(source:{src})
    let first=try cap.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:false)!
    src.value=newImage;forceNativeBusy(newImage,true)
    expect(try cap.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:false)==nil,"busy changed geometry/format cannot replay mismatched last image")
    expect(cap.diagnostics["cached_image_available"] as? Bool==false && cap.diagnostics["busy_geometry_changes"] as? Int==1,"busy layout discontinuity still gates input")
    forceNativeBusy(newImage,false)
    let wake=try cap.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:false)!
    expect(wake.generation != first.generation && wake.frame.keyframe,"coherent changed-layout recovery is a real epoch")
    src.value=nil
    expect(try cap.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:false)==nil,"true inactivity still discards image immediately")
    expect(cap.diagnostics["inactive_surfaces"] as? Int==1 && cap.diagnostics["snapshot_buffer_bytes"] as? Int==0,"inactive reason and immediate storage release remain explicit")
    cap.stop();expect(cap.diagnostics["snapshot_buffers"] as? Int==0,"stop releases all snapshot pool storage")
}
do {
    let image=surface(73,121),src=ScaleSource(image),cap=NativeCapture(source:{src})
    _ = try cap.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:false)
    forceNativeBusy(image,true)
    expect(try cap.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:false,scaling:.half)==nil,"busy scale change cannot send old-size prepared pixels")
    forceNativeBusy(image,false);cap.stop()
}
do {
    let src=ScaleSource(surface(18,34)),cap=NativeCapture(source:{src})
    let a=try cap.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:false,scaling:.half)!
    src.value=surface(19,35)
    let b=try cap.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:false,scaling:.half)!
    expect(a.frame.width==b.frame.width && a.frame.height==b.frame.height && a.generation != b.generation,"source geometry change remains real even if scale rounds to same encoded size")
    expect(cap.diagnostics["encoder_creations"] as? Int==2,"actual source geometry recreates encoder even at identical rounded output size")
    cap.stop()
}

for (w,h) in [(828,1792),(1792,828),(641,319)] {
    for scale in IOSCaptureScale.allCases {
        expect(IOSCaptureScale.normalized(scale.rawValue)==scale,"Native scale closed values normalize")
        let src=ScaleSource(surface(w,h)),cap=NativeCapture(source:{src})
        let video=try cap.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:false,scaling:scale)!
        let ow=max(1,Int(Double(w)*scale.factor)),oh=max(1,Int(Double(h)*scale.factor))
        expect(video.frame.width==ow && video.frame.height==oh,"Native scales both dimensions before hardware encode")
        expect(video.frame.codedWidth==(ow+1)/2*2 && video.frame.codedHeight==(oh+1)/2*2,"odd scaled content keeps even codec padding")
        expect(video.sourceWidth==w && video.sourceHeight==h,"input geometry remains unscaled source")
        expect(cap.diagnostics["source_width"] as? Int==w && cap.diagnostics["source_height"] as? Int==h,"source diagnostics are not decoded feedback")
        expect(cap.diagnostics["native_scale"] as? String==scale.rawValue && cap.diagnostics["owned_snapshot_bytes"] as? Int==w*h*4,"scaling leaves full bounded readback explicit")
        let repeatVideo=try cap.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:false,scaling:scale)!
        expect(repeatVideo.frame.timestamp>video.frame.timestamp && repeatVideo.generation==video.generation,"scaled DSoff still submits NEW frames without epoch churn")
        expect(cap.diagnostics["prepared_pixel_buffers"] as? Int==1 && cap.diagnostics["encoder_creations"] as? Int==1,"scaled static repeat reuses prepared buffer/encoder")
        expect(try cap.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:true,scaling:scale)==nil,"scaled DSon can idle0")
        let idr=try cap.h264(quality:1,fps:30,forceKeyframe:true,dataSaver:true,scaling:scale)!
        expect(idr.frame.keyframe && idr.generation==video.generation,"scaled quality FPS IDR keep generation")
        src.value=nil;expect(try cap.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:false,scaling:scale)==nil,"scaled inactive discards cached pixels")
        cap.stop();expect(src.closed,"scaled source closed")
    }
}
for scale in IOSCaptureScale.allCases {
    let src=ScaleSource(surface(64,8192)),cap=NativeCapture(source:{src})
    let video=try cap.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:false,scaling:scale)!
    expect(video.frame.width==(scale == .quarter ? 16:32) && video.frame.height==(scale == .quarter ? 2048:4096),"factor applies before4096cap without double scaling")
    cap.stop()
}

let health=CaptureHealth(),source=FixtureSource(),capture=NativeCapture(source:{source},health:health)
expect(health.snapshot["active"] as? Int==1,"native health counted")
let first=try capture.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:false)!
expect(first.frame.keyframe,"first native frame IDR")
expect(first.frame.width==320 && first.frame.height==640,"source geometry not host bounds")
var last=first.frame.timestamp
for _ in 0..<90 {let f=try capture.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:false)!;expect(f.frame.timestamp>last,"continuous NEW H264 timestamp");expect(f.generation==first.generation,"no epoch churn on identical pixels");last=f.frame.timestamp}
expect(capture.diagnostics["prepared_pixel_buffers"] as? Int==1,"unchanged pixels prepare only once")
expect(capture.diagnostics["encoder_creations"] as? Int==1,"static work shares one encoder")
expect(capture.diagnostics["hardware_encoder"] as? Bool==true,"existing hardware encoder")
expect(try capture.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:true)==nil,"DSon idle0 only")
let key=try capture.h264(quality:1,fps:30,forceKeyframe:true,dataSaver:true)!
expect(key.frame.keyframe && key.generation==first.generation,"routine IDR same generation/encoder")
try jsonData(["variant":true]).write(to:root.appendingPathComponent("mode.json"))
let changed=try capture.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:true)!
expect(changed.generation==first.generation,"new pixels not a decoder reset")
try jsonData(["inactive":true]).write(to:root.appendingPathComponent("mode.json"))
expect(try capture.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:false)==nil,"inactive never stale replay")
expect(capture.diagnostics["cached_image_available"] as? Bool==false,"inactive cache released")
try jsonData(["variant":true]).write(to:root.appendingPathComponent("mode.json"))
let wake=try capture.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:true)!
expect(wake.frame.keyframe && wake.generation != changed.generation,"same-size wake requires new IDR generation")
try jsonData(["width":641,"height":319]).write(to:root.appendingPathComponent("mode.json"))
let rotation=try capture.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:true)!
expect(rotation.frame.width==641 && rotation.frame.height==319 && rotation.frame.codedWidth==642 && rotation.frame.codedHeight==320 && rotation.frame.keyframe,"odd rotation pads, never changes content size")
expect(capture.diagnostics["encoder_creations"] as? Int==2,"only geometry recreates encoder")
capture.cancel();expect(try capture.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:false)==nil,"cancelled cannot publish")
capture.stop();capture.stop();expect(health.snapshot["active"] as? Int==0 && source.closed,"idempotent stop releases source+encoder")
let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),done=DispatchGroup(),h2=CaptureHealth()
let blocked=NativeCapture(source:{entered.signal();release.wait();return FixtureSource()},health:h2)
done.enter();DispatchQueue.global().async{defer{done.leave()};_ = try? blocked.h264(quality:20,fps:60,forceKeyframe:true,dataSaver:false)}
expect(entered.wait(timeout:.now()+3) == .success,"isolated connector entered")
blocked.cancel();done.enter();DispatchQueue.global().async{blocked.stop();done.leave()}
expect(done.wait(timeout:.now()+0.1) == .timedOut,"stop joins in-flight connector")
release.signal();expect(done.wait(timeout:.now()+3) == .success,"joined cleanup completes")
expect(h2.snapshot["active"] as? Int==0,"no late capture after cancellation")
try? fm.removeItem(at:root.appendingPathComponent("mode.json"))
let report:[String:Any]=["passed":true,"checks":checks,"real_capture":false,"real_input":false,"framework_load":false,"simulator_connection":false,"source":"synthetic IOSurface → guarded ObjC dispatch → snapshot → unchanged hardware H264"]
try jsonData(report).write(to:root.appendingPathComponent("native-review.json"));print("Native checks: \(checks) passed")
