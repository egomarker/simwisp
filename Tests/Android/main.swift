import Foundation
import CoreImage
import CoreMedia
import ScreenCaptureKit
import Darwin

let root=URL(fileURLWithPath:CommandLine.arguments[1]),node=CommandLine.arguments[2]
let fm=FileManager.default
try fm.createDirectory(at:root,withIntermediateDirectories:true)
let sdk=root.appendingPathComponent("sdk/platform-tools"),adb=sdk.appendingPathComponent("adb")
try fm.createDirectory(at:sdk,withIntermediateDirectories:true)
let script=URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("Tests/Android/server.mjs").path
try Data("#!/bin/bash\nexec '\(node)' '\(script)' '\(root.path)' cli \"$@\"\n".utf8).write(to:adb)
try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:adb.path)
let jar=root.appendingPathComponent("fake-server.jar");try Data("fake; never installed on a device".utf8).write(to:jar)
let installation:ScrcpySession.Installation={ScrcpyInstallation(server:jar.path,version:ScrcpyWire.version)}
func annex(_ avcc:Data)->Data{var r=Data(),i=0;while i<avcc.count{let n=Int(avcc.scrcpyUInt(i,4));i+=4;r.append(contentsOf:[0,0,0,1]);r.append(avcc[i..<i+n]);i+=n};return r}
let encoder=try H264Encoder(width:320,height:640)
var frames:[[String:Any]]=[],config=Data()
for i in 0..<30 {
    let f=try encoder.encode(CIImage(color:CIColor(red:0.22,green:0.35,blue:0.31)).cropped(to:CGRect(x:0,y:0,width:320,height:640)),quality:20,fps:30,forceKeyframe:i==0)
    if i==0{let d=f.description;let n=Int(d.scrcpyUInt(6,2)),p=8+n+1,m=Int(d.scrcpyUInt(p,2));config.append(contentsOf:[0,0,0,1]);config.append(d[8..<8+n]);config.append(contentsOf:[0,0,0,1]);config.append(d[p+2..<p+2+m])}
    frames.append(["key":f.keyframe,"payload":annex(f.payload).map{String(format:"%02x",$0)}.joined()])
}
encoder.close();try jsonData(["config":config.map{String(format:"%02x",$0)}.joined(),"frames":frames]).write(to:root.appendingPathComponent("video.json"))
try? fm.removeItem(at:root.appendingPathComponent("peer.json"))
let peer=Process();peer.executableURL=URL(fileURLWithPath:node);peer.arguments=[script,root.path,"peer"];peer.standardOutput=FileHandle.nullDevice;peer.standardError=FileHandle.standardError;try peer.run()
func wait(_ label:String,_ test:()->Bool)throws{let end=monotonic()+10;while monotonic()<end{if test(){return};Thread.sleep(forTimeInterval:0.01)};throw WispError("Timeout: "+label)}
try wait("fixture peer"){fm.fileExists(atPath:root.appendingPathComponent("peer.json").path)}

if CommandLine.arguments.contains("--serve") {
    // Real native service, fake discovery/capture/input/ADB. Nothing can reach a host device.
    var settings=Settings();settings.port=45154;settings.projectDirectory=root.path;settings.androidSDK=root.appendingPathComponent("sdk").path;settings.pairingToken="isolated-android-backends"
    let devices=Devices(settings:settings,discovery:{
        let serial=(try? String(contentsOf:root.appendingPathComponent("serial"),encoding:.utf8)) ?? "emulator-5554"
        let headless=fm.fileExists(atPath:root.appendingPathComponent("headless").path)
        let dimensions=(try? Data(contentsOf:root.appendingPathComponent("window-size.json"))).map(dictionary) ?? [:]
        let width=(dimensions["width"] as? Int) ?? 320,height=(dimensions["height"] as? Int) ?? 640
        let win=DeviceWindow(id:123,pid:0,title:"fixture",bounds:CGRect(x:0,y:0,width:width,height:height),crop:CGRect(x:0,y:0,width:width,height:height))
        return ([Device(id:serial,name:"Pixel fixture",platform:"android",width:headless ? 0:width,height:headless ? 0:height,avd:"Pixel_fixture")],[],headless ? [:]:[serial:win])
    })
    let fakeInput=DeviceInput(devices:devices,handler:{m,id in
        let f=root.appendingPathComponent("legacy.ndjson");if !fm.fileExists(atPath:f.path){fm.createFile(atPath:f.path,contents:nil)};let h=try FileHandle(forWritingTo:f);try h.seekToEnd();try h.write(contentsOf:jsonData(["id":id,"message":m])+Data([10]));try h.close()
        if m["type"] as? String == "rotate", let data=try? Data(contentsOf:root.appendingPathComponent("rotation.json")) {
            let rotation=dictionary(data)
            try Data().write(to:root.appendingPathComponent("rotation-started"))
            Thread.sleep(forTimeInterval:0.45)
            try jsonData(rotation).write(to:root.appendingPathComponent("display.json"),options:.atomic)
            try Data().write(to:root.appendingPathComponent("rotation-completed"))
        }
        return nil
    })
    // A single synthetic SCK complete frame drives the unchanged window pipeline.
    var pixel:CVPixelBuffer?;CVPixelBufferCreate(nil,320,640,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&pixel)
    CIContext().render(CIImage(color:.blue).cropped(to:CGRect(x:0,y:0,width:320,height:640)),to:pixel!)
    var format:CMVideoFormatDescription?;CMVideoFormatDescriptionCreateForImageBuffer(allocator:nil,imageBuffer:pixel!,formatDescriptionOut:&format)
    var time=CMSampleTimingInfo(duration:.invalid,presentationTimeStamp:.zero,decodeTimeStamp:.invalid),sample:CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator:nil,imageBuffer:pixel!,formatDescription:format!,sampleTiming:&time,sampleBufferOut:&sample)
    let attachments=CMSampleBufferGetSampleAttachmentsArray(sample!,createIfNecessary:true) as! [NSMutableDictionary];attachments[0][SCStreamFrameInfo.status.rawValue]=SCFrameStatus.complete.rawValue
    final class FakeStream:CaptureStream {
        let capture:WindowCapture,sample:CMSampleBuffer
        init(_ capture:WindowCapture,_ sample:CMSampleBuffer){self.capture=capture;self.sample=sample}
        @MainActor func startCapture()async throws{capture.receive(sample,type:.screen)}
        @MainActor func stopCapture()async throws{}
        @MainActor func removeStreamOutput(_ output:any SCStreamOutput,type:SCStreamOutputType)throws{}
    }
    let service=Service(settings:settings,pairingStateURL:root.appendingPathComponent("pairing-state.json"),tlsDirectory:root.appendingPathComponent("tls"),devices:devices,input:fakeInput,metroEndpoint:URL(string:"http://127.0.0.1:45154/fixture/empty-metro")!,scrcpyInstallation:{if fm.fileExists(atPath:root.appendingPathComponent("unavailable").path){throw WispError("scrcpy fixture unavailable <img src=x onerror=bad>")};return try installation()},makeCapture:{w in WindowCapture(target:w,makeStream:{c in FakeStream(c,sample!)})})
    service.stateChanged={state in if state=="Running"{print("Isolated Android service ready");fflush(stdout)}}
    try service.start();let signal=DispatchSource.makeSignalSource(signal:SIGTERM,queue:.main);Darwin.signal(SIGTERM,SIG_IGN);signal.setEventHandler{service.stop{peer.terminate();peer.waitUntilExit();exit(0)}};signal.resume();dispatchMain()
}
defer{if peer.isRunning{peer.terminate();peer.waitUntilExit()}}
var checks=0
func expect(_ value:Bool,_ name:String){if !value{fatalError(name)};checks+=1}
func rejects(_ name:String,_ body:()throws->Void){do{try body();fatalError("Accepted "+name)}catch{checks+=1}}
// Preserve the existing Mac-window curve exactly at valid UI settings.
for (w,h) in [(1,1),(320,640),(411,914),(480,960),(1080,1920),(1920,1080),(8192,8192)] {
    for q in 1...95 {
        let paddedPixels=((w+1) & ~1)*((h+1) & ~1)
        let area=Double(paddedPixels)/(1080*1920)
        let expected=Int(max(500_000,min(40_000_000,(2_000_000+Double(q)/95*18_000_000)*area)))
        expect(H264VideoPolicy.bitRate(width:w,height:h,quality:q)==expected,"legacy Mac-window bitrate curve")
        if let size=ScrcpyVideoSize(width:w,height:h) {
            let scrcpyExpected = q == 1 ? 800_000 : expected
            expect(size.bitRate(quality:q)==scrcpyExpected,"scrcpy shared curve with explicit quality1 trial")
            let args=ScrcpySession.arguments(version:ScrcpyWire.version,scid:"00000001",jar:"fixture.jar",video:true,controls:false,fps:60,quality:q,videoSize:size)
            expect(args.contains("max_size=\(max(w,h))") && args.contains("video_bit_rate=\(scrcpyExpected)"),"pixel/bitrate budget reaches the server options")
            let codec="video_codec_options=profile=1,max-bframes=0,i-frame-interval=1" + (q == 1 ? ",video-qp-i-max=40,video-qp-p-max=40" : "")
            expect(args.contains(codec) && !args.contains(where:{$0.contains("bitrate-mode=")}),"QP40 ceiling only for quality1; no CBR and unchanged Baseline/no-B/GOP")
        }
    }
}
let portrait=ScrcpyVideoSize(width:411,height:914)!
expect(portrait==ScrcpyVideoSize(width:914,height:411),"rotation keeps the same pixel budget")
expect(portrait.bitRate(quality:1)==800_000 && portrait.maxSize==914,"owner quality1 trial uses914px/800kbps")
expect(H264VideoPolicy.bitRate(width:411,height:914,quality:1)==500_000,"800kbps/QP40 scrcpy trial does not change Mac-window bitrate")
let controlOnlyArgs=ScrcpySession.arguments(version:ScrcpyWire.version,scid:"00000001",jar:"fixture.jar",video:false,controls:true,fps:60,quality:1,videoSize:portrait)
expect(controlOnlyArgs.contains("video=false") && controlOnlyArgs.contains("video_codec_options=profile=1,max-bframes=0,i-frame-interval=1"),"control-only input never requests video QP limits")
for (w,h) in [(0,800),(-1,800),(1,1),(8193,800),(Int.max,800)] { expect(ScrcpyVideoSize(width:w,height:h)==nil,"malformed size cannot reach encoder arguments") }
expect(ScrcpyVideoSize.headless.width==360 && ScrcpyVideoSize.headless.height==800,"headless fallback matches existing UI")
for c in AndroidBackendMode.allCases{for i in AndroidBackendMode.allCases{let v=AndroidBackendChoice(capture:c.rawValue,input:i.rawValue);expect(v.capture==c && v.input==i,"independent selections")}}
expect(AndroidBackendChoice(capture:"bad",input:"bad")==AndroidBackendChoice(),"invalid preferences default safely")
var header=Data();header.scrcpyAppend(UInt32(1)<<31);header.scrcpyAppend(UInt32(320));header.scrcpyAppend(UInt32(640))
if case .session(let w,let h)=try ScrcpyWire.header(header){expect(w==320 && h==640,"5.x session metadata")}else{fatalError("session flag")}
for flag:UInt64 in [0,1<<61,1<<62]{var h=Data();h.scrcpyAppend(flag|123);h.scrcpyAppend(UInt32(50));if case .packet(let n,let pts,let cfg,let key)=try ScrcpyWire.header(h){expect(n==50 && pts==123 && cfg==(flag==1<<62) && key==(flag==1<<61),"5.x key/config bit positions")}else{fatalError("packet")}}
for n in [0,11,13]{rejects("header length"){_ = try ScrcpyWire.header(Data(repeating:0,count:n))}}
for n:UInt32 in [0,8_388_609,UInt32.max]{var h=Data(repeating:0,count:8);h.scrcpyAppend(n);rejects("payload allocation bound"){_ = try ScrcpyWire.header(h)}}
for value in [Data(),Data([0,0,1]),Data([1,2,3]),Data([0,0,1,7,0,0,1])]{rejects("malformed Annex-B"){_ = try ScrcpyWire.nals(value)}}
let nal=try ScrcpyWire.nals(config);expect(nal.count==2 && nal[0][0]&31==7 && nal[1][0]&31==8,"real H.264 parameter sets")
expect(try ScrcpyWire.configuration(nal[0],nal[1]).count>7,"real low-reorder AVCC")
for action:UInt8 in [0,1,2]{let d=try ScrcpyWire.touch(action:action,x:1,y:1,width:320,height:640);expect(d.count==32 && d[0]==2 && d[1]==action,"touch layout");expect(d.scrcpyUInt(10,4)==319 && d.scrcpyUInt(14,4)==639,"touch endpoint clamp");expect(d.scrcpyUInt(18,2)==320 && d.scrcpyUInt(20,2)==640,"touch space");expect(d.scrcpyUInt(22,2)==(action==1 ? 0:65535),"touch pressure/release")}
rejects("nonfinite input"){_ = try ScrcpyWire.touch(action:0,x:.nan,y:0,width:320,height:640)}
rejects("invalid dimensions"){_ = try ScrcpyWire.touch(action:0,x:0,y:0,width:0,height:640)}
expect(ScrcpyWire.key(3,down:true).count==14,"key payload14")
expect(try ScrcpyWire.text("тест").count==13,"Unicode UTF8 size")
rejects("text bound"){_ = try ScrcpyWire.text(String(repeating:"a",count:301))}
let d=try ScrcpyWire.displaySize("DisplayInfo{fixture, displayId 0, real 1080 x 2400}");expect(d.0==1080 && d.1==2400,"physical display geometry")
let rotated=try ScrcpyWire.displaySize("mBaseDisplayInfo=DisplayInfo{fixture, displayId 0, real 320 x 640}\nmOverrideDisplayInfo=DisplayInfo{fixture, displayId 0, real 640 x 320}")
expect(rotated.0==640 && rotated.1==320,"control-only input prefers live rotation override")
rejects("secondary display never substituted"){_ = try ScrcpyWire.displaySize("DisplayInfo{fixture, displayId 1, real 320 x 640}")}
rejects("no guessed headless dimensions"){_ = try ScrcpyWire.displaySize("unknown")}
let fake=H264Frame(payload:Data([1]),description:Data(),codec:"avc1.42",keyframe:false,timestamp:1,width:320,height:640,codedWidth:320,codedHeight:640)
let key=H264Frame(payload:fake.payload,description:fake.description,codec:fake.codec,keyframe:true,timestamp:1,width:320,height:640,codedWidth:320,codedHeight:640)
var queue=ScrcpyFrames();expect(!queue.append(fake),"delta rejected before IDR");expect(queue.append(key),"IDR admits chain");for _ in 0..<3{expect(queue.append(fake),"bounded reference chain")};expect(!queue.append(fake) && queue.needsKey,"overflow invalidates entire chain");expect(queue.take()==nil,"stale dependencies purged");expect(queue.append(key),"recovery only IDR")
let generation=queue.generation
expect(queue.count==1,"queue occupancy is observable without taking a frame")
expect(queue.take() != nil && queue.take()==nil,"empty push source has no synthetic AU")
expect(queue.generation==generation,"draining does not reset decoder generation")
expect(queue.append(key) && queue.generation==generation,"ordinary IDR preserves decoder generation")
queue.reset();expect(queue.generation != generation && queue.count==0,"source discontinuity changes generation and purges queued references")
func recordedEvents() throws -> [[String:Any]] {
    guard fm.fileExists(atPath:root.appendingPathComponent("events.ndjson").path) else { return [] }
    return try String(contentsOf:root.appendingPathComponent("events.ndjson"),encoding:.utf8).split(separator:"\n").map{dictionary(Data($0.utf8))}
}
func recordedCommands() throws -> [[String]] { try recordedEvents().compactMap{$0["kind"] as? String == "command" ? $0["args"] as? [String] : nil} }
for video in [true,false]{
    let lifecycle=DispatchGroup(),network=DispatchQueue(label:"fixture.network")
    let s=ScrcpySession(adb:adb.path,serial:"emulator-5554",video:video,controls:true,fps:30,quality:20,network:network,lifecycle:lifecycle,installation:installation)
    let commandsBefore=try recordedCommands().count
    s.start();try wait("native scrcpy handshake"){s.state.ready || s.state.error != nil};expect(s.state.error==nil,"fake peer handshake: \(s.state.error ?? "")")
    let startupCommands=Array(try recordedCommands().dropFirst(commandsBefore))
    let propertyCommands=startupCommands.filter{$0.contains("debug.stagefright.enableshaping")}
    expect(propertyCommands.count == (video ? 2:0),"only video startup writes and verifies device-wide shaping property")
    if video {
        let write=startupCommands.firstIndex{$0.suffix(4)==["shell","setprop","debug.stagefright.enableshaping","0"]}
        let read=startupCommands.firstIndex{$0.suffix(3)==["shell","getprop","debug.stagefright.enableshaping"]}
        let launch=startupCommands.firstIndex{$0.contains("com.genymobile.scrcpy.Server")}
        expect(write != nil && read != nil && launch != nil && write! < read! && read! < launch!,"setprop and readback precede encoder launch")
        expect(s.diagnostics["format_shaping_disabled"] as? Bool == true,"property verification is observable, not an actual bitrate claim")
    } else { expect(s.diagnostics["format_shaping_disabled"] is NSNull,"control-only never claims to have changed shaping") }
    expect(s.diagnostics["requested_qp_max"] is NSNull,"default quality/control-only diagnostics do not pretend to know actual QP")
    if video{var frame:H264Frame?;try wait("direct H.264 frame"){frame=s.takeFrame();return frame != nil};expect(frame!.keyframe && frame!.width==320 && frame!.description.count>7,"Annex-B passes native AVCC pipeline");var offset=0;while offset<frame!.payload.count{let n=Int(frame!.payload.scrcpyUInt(offset,4));let kind=frame!.payload[offset+4]&31;expect(kind != 7 && kind != 8,"original in-band parameter sets cannot override low-reorder avcC");offset+=4+n}}
    expect(try s.perform(["type":"touch_down","x":0.2,"y":0.3]),"direct touch down");expect(try s.perform(["type":"touch_move","x":0.4,"y":0.5]),"direct touch move");expect(try s.perform(["type":"touch_up","x":0.4,"y":0.5]),"direct touch up")
    for type in ["home","back","menu","app_switcher","key","text"]{expect(try s.perform(["type":type,"key":"enter","text":"hello"]),"persistent control \(type)")}
    expect(try s.perform(["type":"accessibility_swipe","x1":0.2,"y1":0.3,"x2":0.6,"y2":0.7]),"two-finger scrcpy swipe")
    expect(!(try s.perform(["type":"appearance"])),"appearance intentionally retains existing command")
    _ = try s.perform(["type":"touch_down","x":0.2,"y":0.3]);s.stop();expect(lifecycle.wait(timeout:.now()+6) == .success,"bounded native teardown")
}
// Control-only geometry lifecycle, with a deliberately blocked metadata peer.
// The fake command captures its result BEFORE blocking, exposing stale-result races.
final class GeometryProbe: @unchecked Sendable {
    let lock=NSLock(),started=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
    var queries=0,dimensions=(320,640),blockNext=false,failNext=false
    func query() throws -> CommandResult {
        let state=lock.withLock{() -> ((Int,Int),Bool,Bool) in queries += 1;let r=(dimensions,blockNext,failNext);blockNext=false;failNext=false;return r}
        if state.1 { started.signal();guard release.wait(timeout:.now()+4) == .success else { throw WispError("fixture query gate timeout") } }
        if state.2 { throw WispError("fixture geometry failure") }
        return CommandResult(status:0,output:Data("mOverrideDisplayInfo=DisplayInfo{fixture, displayId 0, real \(state.0.0) x \(state.0.1)}".utf8),error:Data())
    }
}
let geometry=GeometryProbe(),geometryLife=DispatchGroup(),geometryNetwork=DispatchQueue(label:"fixture.geometry")
let geometrySession=ScrcpySession(adb:adb.path,serial:"emulator-5554",video:false,controls:true,fps:60,quality:1,network:geometryNetwork,lifecycle:geometryLife,installation:installation,run:{path,args,timeout in
    if args.suffix(3)==["shell","dumpsys","display"] { return try geometry.query() }
    return try command(path,args,timeout:timeout)
})
geometrySession.start();try wait("geometry session ready"){geometrySession.state.ready || geometrySession.state.error != nil}
expect(geometrySession.state.error==nil && geometry.lock.withLock{geometry.queries}==1,"startup fetches one verified geometry")
let latencyEvents=try recordedEvents().count
func quickGesture(_ label:String)throws->Double {
    let start=monotonic()
    _ = try geometrySession.perform(["type":"touch_down","x":0.5,"y":0.2])
    for i in 1...6 { _ = try geometrySession.perform(["type":"touch_move","x":0.5,"y":0.2+Double(i)*0.1]) }
    _ = try geometrySession.perform(["type":"touch_up","x":0.5,"y":0.9])
    let ms=(monotonic()-start)*1000;expect(ms<100,label+" does not wait for ADB");return ms
}
let warmMS=try quickGesture("warm gesture")
Thread.sleep(forTimeInterval:1.10)
let postPauseMS=try quickGesture("post-pause gesture"),repeatMS=try quickGesture("immediate repeat")
expect(geometry.lock.withLock{geometry.queries}==1,"gesture age/MOVE/UP never invalidate session-long geometry")
try wait("three complete latency gestures on wire"){((try? recordedEvents().dropFirst(latencyEvents).filter{$0["kind"] as? String=="control" && $0["type"] as? Int==2 && $0["action"] as? Int==1}.count) ?? 0)==3}
// An async refresh may finish during a gesture; that whole gesture retains its snapshot.
let frozenStart=try recordedEvents().count
_ = try geometrySession.perform(["type":"touch_down","x":0.5,"y":0.2])
geometry.lock.withLock{geometry.dimensions=(640,320);geometry.blockNext=true}
let invalidateStart=monotonic();geometrySession.invalidatePhysicalSize()
expect((monotonic()-invalidateStart)*1000<100,"invalidation schedules without blocking input/network")
expect(geometry.started.wait(timeout:.now()+3) == .success,"background geometry query entered")
expect(geometrySession.inputDiagnostics["geometry_refresh_pending"] as? Bool == true,"refresh pending is observable")
_ = try geometrySession.perform(["type":"touch_move","x":0.5,"y":0.4])
geometry.release.signal();try wait("background dimensions published"){geometrySession.state.size.0==640 && geometrySession.inputDiagnostics["geometry_refresh_pending"] as? Bool == false}
_ = try geometrySession.perform(["type":"touch_move","x":0.5,"y":0.6])
_ = try geometrySession.perform(["type":"touch_up","x":0.5,"y":0.9])
try wait("frozen gesture wire UP"){(try? recordedEvents().dropFirst(frozenStart).contains{$0["kind"] as? String=="control" && $0["type"] as? Int==2 && $0["action"] as? Int==1}) ?? false}
let frozenPackets=try recordedEvents().dropFirst(frozenStart).filter{$0["kind"] as? String=="control" && $0["type"] as? Int==2}
expect(frozenPackets.allSatisfy{let h=$0["hex"] as! String;return String(h.dropFirst(36).prefix(8))=="01400280"},"MOVEs and UP retain320x640 even after background result640x320")
let nextStart=try recordedEvents().count
_ = try quickGesture("next geometry gesture")
try wait("new gesture wire UP"){(try? recordedEvents().dropFirst(nextStart).contains{$0["kind"] as? String=="control" && $0["type"] as? Int==2 && $0["action"] as? Int==1}) ?? false}
expect(try recordedEvents().dropFirst(nextStart).filter{$0["kind"] as? String=="control" && $0["type"] as? Int==2}.allSatisfy{let h=$0["hex"] as! String;return String(h.dropFirst(36).prefix(8))=="02800140"},"only a new gesture adopts refreshed dimensions")
// Coalesce pre-query notifications and reject a result superseded in-flight.
geometry.lock.withLock{geometry.dimensions=(480,960);geometry.blockNext=true}
let beforeStale=geometry.lock.withLock{geometry.queries}
for _ in 0..<20 { geometrySession.invalidatePhysicalSize() }
expect(geometry.started.wait(timeout:.now()+3) == .success,"coalesced query started")
expect(geometry.lock.withLock{geometry.queries}==beforeStale+1,"notification burst is one query, not20")
geometry.lock.withLock{geometry.dimensions=(360,800);geometry.blockNext=true};geometrySession.invalidatePhysicalSize();geometry.release.signal()
expect(geometry.started.wait(timeout:.now()+3) == .success,"superseding query started")
expect(geometrySession.state.size.0==640 && geometrySession.state.size.1==320,"superseded480x960 result never published")
_ = try quickGesture("gesture during superseding query");geometry.release.signal()
try wait("newest geometry committed"){geometrySession.state.size.0==360 && geometrySession.state.size.1==800 && geometrySession.inputDiagnostics["geometry_refresh_pending"] as? Bool == false}
// Background errors preserve usable input and are surfaced, not permanent failure.
geometry.lock.withLock{geometry.failNext=true};geometrySession.invalidatePhysicalSize()
try wait("geometry failure diagnostic"){geometrySession.inputDiagnostics["geometry_refresh_error"] as? String != nil}
expect(geometrySession.state.error==nil && geometrySession.state.ready && geometrySession.state.size.0==360,"failed refresh preserves last validated geometry and connection")
_ = try quickGesture("gesture after failed refresh")
geometrySession.invalidatePhysicalSize();try wait("explicit geometry recovery"){geometrySession.inputDiagnostics["geometry_refresh_error"] is NSNull && geometrySession.inputDiagnostics["geometry_refresh_pending"] as? Bool == false}
// Stop joins an in-flight query and refuses late results/new work.
geometry.lock.withLock{geometry.dimensions=(800,360);geometry.blockNext=true};geometrySession.invalidatePhysicalSize()
expect(geometry.started.wait(timeout:.now()+3) == .success,"teardown query gate")
geometrySession.stop();geometrySession.invalidatePhysicalSize();geometry.release.signal()
expect(geometryLife.wait(timeout:.now()+6) == .success,"teardown joins background geometry and both sockets")
expect(geometrySession.state.size.0==360 && geometrySession.state.size.1==800,"stopped session rejects late dimensions")
let finalQueries=geometry.lock.withLock{geometry.queries};geometrySession.invalidatePhysicalSize();Thread.sleep(forTimeInterval:0.2)
expect(geometry.lock.withLock{geometry.queries}==finalQueries,"no refresh work after stop")
try jsonData(["warm_swipe_ms":warmMS,"post_pause_swipe_ms":postPauseMS,"immediate_repeat_ms":repeatMS,"startup_queries":1,"final_queries":finalQueries,"real_input":false,"real_capture":false,"real_device_actions":false]).write(to:root.appendingPathComponent("geometry-review.json"))
for scenario in ["missing","version","serial","push","port","shaping-write","shaping-read","shaping-value"] {
    let lifecycle=DispatchGroup(),network=DispatchQueue(label:"fixture.failure"),calls=NSLock();var count=0
    let s=ScrcpySession(adb:adb.path,serial:scenario=="serial" ? "emulator-5554;bad":"emulator-5554",video:true,controls:true,fps:30,quality:20,network:network,lifecycle:lifecycle,installation:{
        if scenario=="missing"{throw WispError("missing")};return ScrcpyInstallation(server:jar.path,version:scenario=="version" ? "future":ScrcpyWire.version)
    },run:{_,args,_ in calls.withLock{count+=1};if scenario=="push"{throw WispError("push failed")}
        if args.contains("setprop"),scenario=="shaping-write" { return CommandResult(status:1,output:Data(),error:Data("denied".utf8)) }
        if args.contains("getprop") { return CommandResult(status:scenario=="shaping-read" ? 1:0,output:Data((scenario=="shaping-value" ? "1":"0").utf8),error:Data()) }
        return CommandResult(status:0,output:Data("99999".utf8),error:Data())})
    s.start();try wait("failure admission \(scenario)"){s.state.error != nil};s.stop();expect(lifecycle.wait(timeout:.now()+6) == .success,"failure cleanup bounded")
    if scenario.hasPrefix("shaping-"){expect(s.state.error?.contains("Cannot disable Android VBR format shaping")==true,"property failure/readback mismatch is explicit and refuses video startup")}
    if ["missing","version","serial"].contains(scenario){expect(calls.withLock{count}==0,"no tool calls before valid installed/serial admission")}
}
let events=try String(contentsOf:root.appendingPathComponent("events.ndjson"),encoding:.utf8).split(separator:"\n").map{dictionary(Data($0.utf8))}
expect(events.contains{$0["kind"] as? String=="control" && $0["action"] as? Int==1},"finger releases reach wire")
expect(events.contains{($0["hex"] as? String)?.hasPrefix("0200fffffffffffffffd")==true},"TalkBack second pointer has distinct virtual ID")
expect(events.contains{($0["hex"] as? String)?.hasPrefix("0201fffffffffffffffd")==true},"TalkBack second pointer is released")
expect(events.filter{$0["kind"] as? String=="command"}.allSatisfy{let a=$0["args"] as! [String];return a.first=="-s" && a[1]=="emulator-5554"},"every fake ADB operation explicitly serial-scoped")
expect(!events.contains{($0["args"] as? [String])?.contains("kill-server")==true},"no global ADB shutdown")
try jsonData(["checks":checks,"real_device_actions":false,"real_capture":false,"real_input":false]).write(to:root.appendingPathComponent("native-review.json"))
print("Android backend native checks: \(checks) passed")
