import Foundation
import CoreImage
import ImageIO

// All image pixels, ADB processes and failures below are owned synthetic fixtures.
func makeJPEGFixtures(_ root:URL)throws {
    let context=CIContext(options:[.cacheIntermediates:false]),space=CGColorSpace(name:CGColorSpace.sRGB)!
    func jpeg(_ w:Int,_ h:Int,_ i:Int)throws->String {
        let bounds=CGRect(x:0,y:0,width:w,height:h)
        let background=CIImage(color:CIColor(red:0.8,green:0.1,blue:0.15)).cropped(to:bounds)
        let marker=CIImage(color:.white).cropped(to:CGRect(x:Double((i*13)%max(1,w-40)),y:Double((i*23)%max(1,h-40)),width:32,height:32))
        guard let b=context.jpegRepresentation(of:marker.composited(over:background),colorSpace:space,options:[kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption:0.70]) else{throw WispError("Cannot make synthetic JPEG")}
        return b.base64EncodedString()
    }
    var scaled: [String: Any] = [:]
    for (w,h) in [(80,160),(160,320),(270,600)] { scaled[String(h)] = ["width":w,"height":h,"portrait":try jpeg(w,h,0),"landscape":try jpeg(h,w,0)] }
    try jsonData(["portrait":try (0..<60).map{try jpeg(320,640,$0)},"landscape":try jpeg(640,320,0),"scaled":scaled]).write(to:root.appendingPathComponent("jpeg.json"))
}
func runJPEGTests(root:URL,adb:URL,jar:URL)throws {
    let fm=FileManager.default;var checks=0
    func check(_ value:Bool,_ label:String){precondition(value,label);checks+=1}
    func reject(_ label:String,_ body:()throws->Void){do{try body();preconditionFailure("Accepted "+label)}catch{checks+=1}}
    func wait(_ label:String,_ body:()throws->Bool)throws{let end=monotonic()+10;while monotonic()<end{if try body(){return};Thread.sleep(forTimeInterval:0.01)};throw WispError("JPEG timeout "+label)}
    // Exercise the command string with a real shell, not the fake peer's byte
    // producer. The helper stub only prints argv/environment; no device exists.
    let shellBin=root.appendingPathComponent("shell tools"),stub=shellBin.appendingPathComponent("app_process")
    try fm.createDirectory(at:shellBin,withIntermediateDirectories:true)
    try Data("#!/bin/sh\nprintf '%s\\n' \"$CLASSPATH\" \"$@\"\n".utf8).write(to:stub)
    try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:stub.path)
    let remote="/data/local/tmp/simwisp-jpeg-00000000000000000000000000000001",name="simwisp-jpeg-00000000000000000000000000000001"
    let args=AndroidJPEGSession.arguments(directory:remote,name:name,maxSize:640,fps:60)
    check(Array(args.prefix(3))==["exec-out","sh","-c"] && args.count==4,"one raw command argument crosses ADB sh -c")
    let expected=[remote+"/helper.jar","/","--nice-name="+name,"io.simwisp.SimwispJpeg","640","60",remote+"/pid"].joined(separator:"\n")+"\n"
    let env=["PATH="+shellBin.path+":/usr/bin:/bin","/bin/sh","-c"]
    let launched=try command("/usr/bin/env",env+[args[3]],timeout:3)
    check(launched.status==0 && launched.text==expected,"actual shell launches helper with intact CLASSPATH and argv")
    let doubleQuoted="'"+args[3].replacingOccurrences(of:"'",with:"'\\''")+"'"
    let broken=try command("/usr/bin/env",env+[doubleQuoted],timeout:3)
    check(broken.status != 0 && broken.text != expected,"regression reproduces old double-quoted command-as-argv0 failure")
    check(!args[3].hasPrefix("'"),"launcher adds no second quote layer")
    func option(_ value:[String:Any])throws{try jsonData(value).write(to:root.appendingPathComponent("jpeg-mode.json"),options:.atomic)}
    func events()->[[String:Any]]{((try? String(contentsOf:root.appendingPathComponent("events.ndjson"),encoding:.utf8)) ?? "").split(separator:"\n").map{dictionary(Data($0.utf8))}}
    func header(_ length:UInt32=100,_ sequence:UInt64=1,_ time:UInt64=1,_ w:UInt32=320,_ h:UInt32=640)->Data{var d=Data("SWJ1".utf8);d.scrcpyAppend(length);d.scrcpyAppend(sequence);d.scrcpyAppend(time);d.scrcpyAppend(w);d.scrcpyAppend(h);return d}
    for n in [0,7,31,33]{reject("short JPEG header"){_ = try AndroidJPEGWire.header(Data(repeating:0,count:n))}}
    for d in [header(0),header(8_388_609),header(100,0),header(100,1,0),header(100,1,1,0),header(100,1,1,4097),header(100,1,1,320,4097)]{reject("JPEG allocation bounds"){_ = try AndroidJPEGWire.header(d)}}
    var hb=Data("SWH1".utf8);hb.scrcpyAppend(UInt32(8));var hbTime=Data();hbTime.scrcpyAppend(UInt64(20))
    check(try AndroidJPEGWire.heartbeat(hb,hbTime,after:19)==20,"bounded heartbeat has independent monotonic liveness timestamp")
    reject("heartbeat duplicate"){_ = try AndroidJPEGWire.heartbeat(hb,hbTime,after:20)}
    reject("heartbeat regression"){_ = try AndroidJPEGWire.heartbeat(hb,hbTime,after:21)}
    reject("heartbeat short payload"){_ = try AndroidJPEGWire.heartbeat(hb,hbTime.dropLast(),after:0)}
    reject("heartbeat long payload"){_ = try AndroidJPEGWire.heartbeat(hb,hbTime+Data([0]),after:0)}
    var badHB=hb;badHB[7]=9;reject("heartbeat length"){_ = try AndroidJPEGWire.heartbeat(badHB,hbTime,after:0)}
    badHB=hb;badHB[0]=0;reject("heartbeat magic"){_ = try AndroidJPEGWire.heartbeat(badHB,hbTime,after:0)}
    let valid=try AndroidJPEGWire.header(header());check(valid.width==320 && valid.height==640 && valid.sequence==1,"SWJ1 network byte order")
    check(AndroidBackendChoice(capture:"jpeg",input:"jpeg").capture == .jpeg && AndroidBackendChoice(capture:"jpeg",input:"jpeg").input == .auto,"JPEG is capture-only, not an input mode")
    check(AndroidBackendChoice().capture == .auto && AndroidBackendChoice().input == .auto,"Auto remains default")
    let fixture=dictionary(try Data(contentsOf:root.appendingPathComponent("jpeg.json"))),bytes=Data(base64Encoded:(fixture["portrait"] as! [String])[0])!
    func image(_ data:Data,_ w:Int=320,_ h:Int=640)->AndroidJPEGFrame{AndroidJPEGFrame(bytes:data,sequence:1,capturedNS:1,width:w,height:h)}
    check(try AndroidJPEGWire.image(image(bytes)).extent.size==CGSize(width:320,height:640),"real ImageIO JPEG decode")
    reject("mismatched JPEG dimensions"){_ = try AndroidJPEGWire.image(image(bytes,640,320))}
    reject("invalid JPEG payload"){_ = try AndroidJPEGWire.image(image(Data([255,216,255,217])))}
    reject("truncated JPEG"){_ = try AndroidJPEGWire.image(image(bytes.dropLast()))}
    let network=DispatchQueue(label:"fixture.jpeg-native"),life=DispatchGroup()
    let source=AndroidJPEGSession(adb:adb.path,serial:"emulator-5554",fps:60,maxSize:640,network:network,lifecycle:life,installation:{jar.path})
    try option(["static":true,"fps":120])
    let before=events().count;source.start();source.start()
    try wait("first fragmented JPEG"){source.state.ready || source.state.error != nil};check(source.state.error==nil,"fragmented pipe frame accepted")
    Thread.sleep(forTimeInterval:0.15)
    check(source.diagnostics["queued_frames"] as? Int==1 && (source.diagnostics["dropped_frames"] as? UInt64 ?? 0)>0,"single latest slot replaces obsolete independent JPEGs")
    let first=try source.h264(quality:1,fps:60,forceKeyframe:false,dataSaver:false)
    check(first?.keyframe==true && first?.width==320 && first?.height==640,"new JPEG encoder creates real bounded Baseline H264 IDR")
    check(first!.description[1]==66 && !first!.payload.isEmpty,"existing VideoToolbox encoder, not JPEG sent to browser")
    check(source.diagnostics["encoder_creations"] as? UInt64==1,"initial JPEG image creates exactly one native encoder")
    try wait("new static capture"){source.hasFrame}
    check(try source.h264(quality:1,fps:60,forceKeyframe:false,dataSaver:true)==nil,"Data saver skips identical newly captured JPEG")
    try wait("keyframe sample"){source.hasFrame}
    check(try source.h264(quality:1,fps:60,forceKeyframe:true,dataSaver:true)?.keyframe==true,"explicit keyframe overrides static Data saver")
    try wait("saver off sample"){source.hasFrame}
    check(try source.h264(quality:95,fps:60,forceKeyframe:false,dataSaver:false) != nil,"final Mac quality remains independently adjustable")
    check(source.diagnostics["jpeg_quality"] as? Int==70 && source.diagnostics["hardware_encoder"] as? Bool==true,"fixed JPEG70 and measured Mac hardware encode")
    try option(["rotation":true,"fps":60]);try wait("rotated metadata"){source.diagnostics["video_width"] as? Int==640}
    let rotated=try source.h264(quality:20,fps:60,forceKeyframe:false,dataSaver:false)
    check(rotated?.keyframe==true && rotated?.width==640 && rotated?.height==320,"rotation rebuilds encoder with IDR and exact JPEG dimensions")
    check(source.diagnostics["encoder_creations"] as? UInt64==2,"actual geometry change creates a replacement encoder")
    try option(["stall":true]);Thread.sleep(forTimeInterval:0.75)
    let decodeBeforeRepeat=source.diagnostics["jpeg_decodes"] as! UInt64
    let repeated=try source.h264(quality:1,fps:60,forceKeyframe:true,dataSaver:false)
    check(repeated?.keyframe==true && repeated?.width==640 && repeated!.timestamp>rotated!.timestamp,"healthy source keeps newest decoded pixels usable between updates")
    check(source.diagnostics["jpeg_decodes"] as? UInt64==decodeBeforeRepeat,"re-encoding does not decode the old JPEG again")
    try option(["failure":"error"]);try wait("cached source error"){source.state.error != nil}
    check(!source.canEncode(dataSaver:false,forceKeyframe:true) && !source.hasFrame,"source failure invalidates cached encode eligibility")
    check(try source.h264(quality:1,fps:60,forceKeyframe:true,dataSaver:false)==nil,"failed source cannot silently freeze on cached pixels")
    source.stop();check(life.wait(timeout:.now()+6) == .success,"stop joins reader, process, guest cleanup and encoder")
    check(source.state.finished && !source.hasFrame && !source.state.ready,"late source callbacks cannot resurrect stopped capture")
    check(try source.h264(quality:1,fps:60,forceKeyframe:true,dataSaver:false)==nil,"closed helper cannot encode cached frames")
    let commands=events().dropFirst(before).filter{$0["kind"] as? String=="command"}.compactMap{$0["args"] as? [String]}
    check(commands.filter{$0.contains("exec-out")}.count==1,"start is idempotent")
    check(commands.contains{$0.contains(where:{$0.contains("/proc/$p/cmdline") && $0.contains("kill -TERM")})},"cleanup checks exact owned process identity before signal")
    check(commands.allSatisfy{$0.first=="-s" && $0[1]=="emulator-5554" && !$0.contains("setprop") && !$0.contains("forward") && !$0.contains("kill-server")},"JPEG never touches global ADB, forwards, shaping or other serials")
    for scenario in ["magic","length","dimensions","sequence","timestamp","duplicate","regression","error","eof","heartbeat-length","heartbeat-zero","heartbeat-duplicate"] {
        try option(["failure":scenario])
        let l=DispatchGroup(),s=AndroidJPEGSession(adb:adb.path,serial:"emulator-5554",fps:60,maxSize:640,network:network,lifecycle:l,installation:{jar.path})
        s.start();try wait("malformed "+scenario){s.state.error != nil}
        check(s.state.error?.isEmpty==false,"malformed/error/EOF is visible: "+scenario);s.stop();check(l.wait(timeout:.now()+6) == .success,"failure joins owned process: "+scenario)
    }
    try option(["static":true]);let idleLife=DispatchGroup(),idle=AndroidJPEGSession(adb:adb.path,serial:"emulator-5554",fps:60,maxSize:640,network:network,lifecycle:idleLife,installation:{jar.path})
    idle.start();try wait("idle initial image"){idle.state.ready}
    _ = try idle.h264(quality:1,fps:60,forceKeyframe:false,dataSaver:false)
    try option(["heartbeat":true]);try wait("idle heartbeat"){(idle.diagnostics["source_heartbeats"] as? UInt64 ?? 0)>0}
    // Decode the last pre-heartbeat image before measuring cache-only cadence.
    _ = try idle.h264(quality:1,fps:60,forceKeyframe:false,dataSaver:false)
    let idleFrames=idle.diagnostics["source_frames"] as! UInt64
    Thread.sleep(forTimeInterval:8.3)
    check(idle.state.ready && idle.state.error==nil && !idle.state.finished,"heartbeats keep an idle mirror connected beyond eight-second frame timeout")
    check(idle.diagnostics["source_frames"] as? UInt64==idleFrames && !idle.hasFrame,"heartbeats never count as fresh frames")
    check((idle.diagnostics["last_frame_age_ms"] as? Double ?? 0)>8000,"heartbeats do not refresh source frame age")
    let idleDecodes=idle.diagnostics["jpeg_decodes"] as! UInt64,idleEncoded=idle.diagnostics["h264_encodes"] as! UInt64
    check(idle.canEncode(dataSaver:false,forceKeyframe:false) && !idle.canEncode(dataSaver:true,forceKeyframe:false),"only Data saver may idle when decoded pixels and healthy heartbeats exist")
    let cachedIDR=try idle.h264(quality:1,fps:60,forceKeyframe:true,dataSaver:false)
    check(cachedIDR?.keyframe==true,"cached decoded image supplies a NEW IDR after long idle")
    var lastPTS=cachedIDR!.timestamp
    for _ in 0..<60 {
        let frame=try idle.h264(quality:1,fps:60,forceKeyframe:false,dataSaver:false)
        check(frame != nil && frame!.timestamp>lastPTS && frame!.width==320,"each cached image submission yields a new completed H264 access unit/PTS")
        lastPTS=frame!.timestamp
    }
    check(idle.diagnostics["jpeg_decodes"] as? UInt64==idleDecodes && idle.diagnostics["source_frames"] as? UInt64==idleFrames,"continuous cached encoding never invents JPEG captures/decodes")
    check(idle.diagnostics["h264_encodes"] as? UInt64==idleEncoded+61 && (idle.diagnostics["cached_image_encodes"] as? UInt64 ?? 0)>=61,"actual cached-image encodes counted separately")
    // Changing output pacing must retain decoded pixels, the native encoder
    // and its monotonic PTS, even while the producer supplies only heartbeats.
    let continuityEncoders=idle.diagnostics["encoder_creations"] as! UInt64
    for outputFPS in [48,38,30,32,34,36,38,40,42,44,46,48,50,52,54,56,58,60] {
        for _ in 0..<3 {
            let frame=try idle.h264(quality:1,fps:outputFPS,forceKeyframe:false,dataSaver:false)
            check(frame != nil && frame!.timestamp>lastPTS,"adaptive output pacing retains a monotonic native encoder timeline")
            lastPTS=frame!.timestamp
        }
    }
    check(idle.diagnostics["encoder_creations"] as? UInt64==continuityEncoders && continuityEncoders==1,"adaptive output FPS never recreates the native encoder")
    check(idle.diagnostics["jpeg_decodes"] as? UInt64==idleDecodes && idle.diagnostics["source_frames"] as? UInt64==idleFrames,"adaptive pacing retains the same decoded image without new JPEG work")
    check(try idle.h264(quality:1,fps:60,forceKeyframe:false,dataSaver:true)==nil,"Data saver ON immediately suppresses unchanged decoded image")
    check(try idle.h264(quality:95,fps:60,forceKeyframe:true,dataSaver:true)?.keyframe==true,"explicit recovery under Data saver can re-encode current image")
    check(try idle.h264(quality:95,fps:60,forceKeyframe:false,dataSaver:true)==nil,"Data saver sleeps again after explicit IDR")
    check(try idle.h264(quality:95,fps:30,forceKeyframe:false,dataSaver:false) != nil,"Data saver OFF resumes using cached image without a source update")
    try option(["rotation":true]);try wait("fresh producer wakes after idle"){idle.hasFrame}
    check(try idle.h264(quality:1,fps:60,forceKeyframe:true,dataSaver:false)?.width==640,"first fresh rotated image after idle encodes normally")
    try option(["heartbeat":true]);let idleStop=monotonic();idle.stop();check(idleLife.wait(timeout:.now()+6) == .success && monotonic()-idleStop<2,"idle teardown joins heartbeat reader promptly")
    let emptyLife=DispatchGroup(),empty=AndroidJPEGSession(adb:adb.path,serial:"emulator-5554",fps:60,maxSize:640,network:network,lifecycle:emptyLife,installation:{jar.path})
    empty.start();try wait("heartbeat before image"){(empty.diagnostics["source_heartbeats"] as? UInt64 ?? 0)>0}
    check(!empty.state.ready && !empty.hasFrame && !empty.canEncode(dataSaver:false,forceKeyframe:true),"heartbeat alone cannot mark capture ready or invent cached pixels")
    check(try empty.h264(quality:1,fps:60,forceKeyframe:true,dataSaver:false)==nil,"a replacement session cannot inherit an old session image")
    empty.stop();check(emptyLife.wait(timeout:.now()+6) == .success,"startup heartbeat-only source joins")
    try option(["static":true]);let corruptedLife=DispatchGroup(),corrupted=AndroidJPEGSession(adb:adb.path,serial:"emulator-5554",fps:60,maxSize:640,network:network,lifecycle:corruptedLife,installation:{jar.path})
    corrupted.start();try wait("corrupt-after-cache initial"){corrupted.hasFrame}
    _ = try corrupted.h264(quality:1,fps:60,forceKeyframe:false,dataSaver:false)
    let beforeCorrupt=corrupted.diagnostics["source_frames"] as! UInt64
    try option(["corrupt":true]);try wait("corrupt latest pending"){corrupted.hasFrame && (corrupted.diagnostics["source_frames"] as? UInt64 ?? 0)>=beforeCorrupt+3}
    reject("new corrupt JPEG after good cache"){_ = try corrupted.h264(quality:1,fps:60,forceKeyframe:false,dataSaver:false)}
    check(corrupted.state.error != nil && !corrupted.canEncode(dataSaver:false,forceKeyframe:true),"corrupt replacement latches error rather than repeating older image")
    corrupted.stop();check(corruptedLife.wait(timeout:.now()+6) == .success,"corrupt replacement cleanup joins")
    try option(["static":true]);let lostLife=DispatchGroup(),lost=AndroidJPEGSession(adb:adb.path,serial:"emulator-5554",fps:60,maxSize:640,network:network,lifecycle:lostLife,installation:{jar.path})
    lost.start();try wait("transport-loss initial"){lost.hasFrame};_ = try lost.h264(quality:1,fps:60,forceKeyframe:false,dataSaver:false)
    try option(["stall":true]);try wait("transport deadline invalidates cache"){lost.state.error != nil}
    let lostFrame=try lost.h264(quality:1,fps:60,forceKeyframe:true,dataSaver:false)
    check(!lost.canEncode(dataSaver:false,forceKeyframe:true) && lostFrame==nil,"no infinite cache streaming after lost helper liveness")
    lost.stop();check(lostLife.wait(timeout:.now()+6) == .success,"lost transport cleanup joins")
    try option(["stall":true]);let stalledLife=DispatchGroup(),stalled=AndroidJPEGSession(adb:adb.path,serial:"emulator-5554",fps:60,maxSize:640,network:network,lifecycle:stalledLife,installation:{jar.path})
    let stalls=events().filter{$0["kind"] as? String=="jpeg_process"}.count;stalled.start();try wait("stalled reader"){events().filter{$0["kind"] as? String=="jpeg_process"}.count>stalls}
    let stopAt=monotonic();stalled.stop();check(stalledLife.wait(timeout:.now()+6) == .success && monotonic()-stopAt<2,"cancellation interrupts a silent frame read without eight-second timeout")
    for scenario in ["serial","missing","mkdir","push"] {
        let l=DispatchGroup(),count=NSLock();var calls=0
        let s=AndroidJPEGSession(adb:adb.path,serial:scenario=="serial" ? "emulator-5554;bad":"emulator-5554",fps:60,maxSize:640,network:network,lifecycle:l,installation:{if scenario=="missing"{throw WispError("missing helper")};return jar.path},run:{_,args,_ in count.withLock{calls+=1};if scenario=="mkdir" || args.contains("push"){throw WispError("fixture tool refusal")};return CommandResult(status:0,output:Data(),error:Data())})
        s.start();try wait("tool failure "+scenario){s.state.error != nil};s.stop();check(l.wait(timeout:.now()+6) == .success,"startup failure cleanup "+scenario)
        if scenario=="serial" || scenario=="missing"{check(count.withLock{calls}==0,"no ADB calls before safe admission")}
    }
    try? fm.removeItem(at:root.appendingPathComponent("jpeg-mode.json"))
    try jsonData(["checks":checks,"real_device_actions":false,"real_capture":false,"real_input":false,"fixed_jpeg_quality":70,"hardware_encoder":true]).write(to:root.appendingPathComponent("jpeg-native-review.json"))
    print("Emulator JPEG native checks: \(checks) passed")
}
