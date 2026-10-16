import Foundation
import CoreImage
import Darwin

func rawFixtureEndpoint(_ root:URL)throws->EmulatorRawEndpoint {
    let peer=dictionary(try Data(contentsOf:root.appendingPathComponent("raw-peer.json")))
    guard let port=peer["port"] as? Int else{throw WispError("No owned raw peer")}
    return try EmulatorRawEndpoint(port:port,token:"owned-raw-fixture-secret")
}
func runRawTests(root:URL)throws {
    var checks=0
    func check(_ b:Bool,_ name:String){precondition(b,name);checks+=1}
    func reject(_ name:String,_ body:()throws->Void){do{try body();preconditionFailure("Accepted "+name)}catch{checks+=1}}
    func wait(_ name:String,_ body:()->Bool)throws{let end=monotonic()+10;while monotonic()<end{if body(){return};Thread.sleep(forTimeInterval:0.01)};throw WispError("Raw timeout "+name)}
    func mode(_ value:[String:Any])throws{try jsonData(value).write(to:root.appendingPathComponent("raw-mode.json"),options:.atomic)}
    func events()->[[String:Any]]{((try? String(contentsOf:root.appendingPathComponent("raw-events.ndjson"),encoding:.utf8)) ?? "").split(separator:"\n").map{dictionary(Data($0.utf8))}}
    func length(_ f:Int,_ data:Data)->Data{let tag=EmulatorRawWire.uint(f,UInt64(data.count));var r=Data([UInt8(f*8+2)]);r.append(tag.dropFirst());r.append(data);return r}
    func packet(_ bytes:Data)->Data{var d=Data([0]);d.scrcpyAppend(UInt32(bytes.count));d.append(bytes);return d}
    let format=EmulatorRawWire.uint(1,1)+EmulatorRawWire.uint(3,8)+EmulatorRawWire.uint(4,8)
    let proto=length(1,format)+length(4,Data(repeating:255,count:256))+EmulatorRawWire.uint(6,1)
    let frame=try EmulatorRawWire.image(proto,maxSize:8);check(frame.width==8 && frame.height==8 && frame.bytes.count==256 && frame.sequence==0,"RGBA metadata/default first sequence")
    check(try !EmulatorRawWire.image(Data(),maxSize:8).active,"empty protobuf means inactive display, not corrupt image")
    for split in 0...packet(proto).count {
        var parser=EmulatorRawWire.Messages(),out=[Data]();let p=packet(proto)
        try parser.append(Data(p.prefix(split))){out.append($0)};try parser.append(Data(p.dropFirst(split))){out.append($0)}
        check(out==[proto],"gRPC fragmentation \(split)")
    }
    var parser=EmulatorRawWire.Messages(),count=0;try parser.append(packet(Data())+packet(proto)){_ in count+=1};check(count==2,"coalesced inactive + image")
    reject("compressed gRPC"){var p=EmulatorRawWire.Messages();try p.append(Data([1,0,0,0,1,0])){_ in}}
    reject("message allocation bound"){var p=EmulatorRawWire.Messages(),d=Data([0]);d.scrcpyAppend(UInt32(EmulatorRawWire.maxMessage+1));try p.append(d){_ in}}
    for data in [Data([10,255]),proto+EmulatorRawWire.uint(6,2),length(1,format)+length(4,Data([0])),Data([0]),Data([8,1]),Data([0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,2])] {
        reject("bad protobuf length/type/duplicate/bounds"){_ = try EmulatorRawWire.image(data,maxSize:8)}
    }
    for token in ["","a\nb","a\rb",String(repeating:"a",count:8193)]{reject("credential injection/bound"){_ = try EmulatorRawEndpoint(port:8554,token:token)}}
    for port in [-1,0,80,65536]{reject("loopback port bound"){_ = try EmulatorRawEndpoint(port:port,token:"secret")}}
    let endpoint=try EmulatorRawEndpoint(port:8554,token:"secret");check(!String(reflecting:endpoint).contains("secret"),"endpoint debug never reveals token")
    let ini=Data("port.serial=5554\ngrpc.port=8554\ngrpc.token=private-fixture\n".utf8)
    check(try EmulatorRawEndpoint.parse(ini,serial:"emulator-5554",pid:100,process:{$0==100})?.port==8554,"serial-scoped discovery record")
    check(try EmulatorRawEndpoint.parse(ini,serial:"emulator-5556",pid:100,process:{_ in true})==nil,"other emulator never selected")
    check(try EmulatorRawEndpoint.parse(ini,serial:"emulator-5554",pid:100,process:{_ in false})==nil,"stale dead-process discovery is ignored")
    reject("duplicate discovery credential"){_ = try EmulatorRawEndpoint.parse(ini+Data("grpc.token=other\n".utf8),serial:"emulator-5554",pid:100,process:{_ in true})}
    for serial in ["physical-device","emulator-5554;bad","emulator-05554","emulator-5555"]{reject("invalid emulator identity"){_ = try EmulatorRawEndpoint.parse(ini,serial:serial,pid:100,process:{_ in true})}}
    let record=root.appendingPathComponent("raw-private.ini");try ini.write(to:record);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:record.path)
    check(try EmulatorRawEndpoint.privateFile(record)==ini,"private discovery readable")
    try FileManager.default.setAttributes([.posixPermissions:0o666],ofItemAtPath:record.path);reject("writable discovery file"){_ = try EmulatorRawEndpoint.privateFile(record)}
    let link=root.appendingPathComponent("raw-link.ini");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:record);reject("symlink discovery"){_ = try EmulatorRawEndpoint.privateFile(link)}
    check(AndroidBackendChoice(capture:"raw",input:"raw").capture == .raw && AndroidBackendChoice(capture:"raw",input:"raw").input == .auto,"raw is capture-only")
    var headers=EmulatorRawWire.Headers();for b in Data("HTTP/2 200\r\ncontent-type: application/grpc\r\n\r\n".utf8){try headers.append(Data([b]))};check(headers.ready,"fragmented HTTP2 headers accepted")
    for text in ["HTTP/1.1 200 OK\r\n","HTTP/2 403\r\n","HTTP/2 200\r\ncontent-type: text/plain\r\n","grpc-status: 16\r\n",String(repeating:"x",count:8193)]{reject("headers/status/auth fail closed"){var h=EmulatorRawWire.Headers();try h.append(Data(text.utf8))}}
    let network=DispatchQueue(label:"fixture.raw-native"),life=DispatchGroup()
    try mode(["static":true]);let s=AndroidRawSession(serial:"emulator-5554",maxSize:64,network:network,lifecycle:life,discovery:{_ in try rawFixtureEndpoint(root)});s.start();s.start()
    try wait("first raw image"){s.state.ready || s.state.error != nil};check(s.state.error==nil,"system HTTP2 curl/gRPC receives real fragmented body: \(s.state.error ?? "")")
    let first=try s.h264(quality:1,fps:60,forceKeyframe:false,dataSaver:false)
    check(first?.keyframe==true && first?.width==32 && first?.height==64,"raw pixels enter existing H264 with real dimensions")
    check(s.diagnostics["hardware_encoder"] as? Bool==true && s.diagnostics["jpeg_decodes"] as? Int==0 && s.diagnostics["jpeg_encodes"] as? Int==0,"hardware H264 without either JPEG stage")
    let before=s.diagnostics["source_frames"] as! UInt64
    check(try s.h264(quality:1,fps:60,forceKeyframe:false,dataSaver:true)==nil,"Data saver skips no-new-frame source")
    var last=first!.timestamp
    for i in 0..<30 {let f=try s.h264(quality:1,fps:i%2==0 ? 60:30,forceKeyframe:false,dataSaver:false);check(f != nil && f!.timestamp>last,"cached pixels NEW encode and monotonic PTS");last=f!.timestamp}
    check(s.diagnostics["source_frames"] as? UInt64==before && s.diagnostics["encoder_creations"] as? UInt64==1,"pacing changes preserve source/cache/encoder")
    check(try s.h264(quality:1,fps:60,forceKeyframe:true,dataSaver:true)?.keyframe==true,"explicit recovery bypasses Data saver without fetching pixels")
    Thread.sleep(forTimeInterval:8.2);check(s.state.ready && s.state.error==nil && s.diagnostics["source_frames"] as? UInt64==before,"silent healthy raw stream survives idle beyond JPEG heartbeat timeout")
    try mode(["inactive":true]);try wait("inactive display"){!s.state.ready};check(!s.canEncode(dataSaver:false,forceKeyframe:true),"inactive display invalidates cached output")
    try mode(["rotation":true]);try wait("raw rotation wake"){s.state.ready && s.diagnostics["video_width"] as? Int==64};let rotated=try s.h264(quality:1,fps:60,forceKeyframe:false,dataSaver:false)
    check(rotated?.keyframe==true && rotated?.width==64 && rotated?.height==32 && s.diagnostics["encoder_creations"] as? UInt64==2,"actual geometry alone replaces encoder and forces keyframe")
    s.stop();check(life.wait(timeout:.now()+4) == .success,"cancel wakes idle poll, joins curl and encoder");check(s.state.finished && !s.state.ready,"stopped source cannot resurrect")
    let args=try command("/bin/ps",["-axo","args="],timeout:2);check(!args.text.contains("authorization: Bearer owned-raw-fixture-secret"),"credentials never enter process arguments")
    for scenario in ["corrupt","compressed","oversize","duplicate","png","secondary","badDimensions","grpcError","badContentType","eof","auth"] {
        try mode([scenario:true]);let l=DispatchGroup(),bad=AndroidRawSession(serial:"emulator-5554",maxSize:64,network:network,lifecycle:l,discovery:{_ in let e=try rawFixtureEndpoint(root);return scenario=="auth" ? try EmulatorRawEndpoint(port:e.port,token:"wrong-fixture-secret"):e})
        bad.start();try wait("malformed/error raw \(scenario)"){bad.state.error != nil};check(!bad.canEncode(dataSaver:false,forceKeyframe:true),"failed source cannot keep cached pixels: "+scenario);bad.stop();check(l.wait(timeout:.now()+4) == .success,"malformed source cleanup: "+scenario)
    }
    try mode(["noInitial":true]);let l=DispatchGroup(),cancel=AndroidRawSession(serial:"emulator-5554",maxSize:64,network:network,lifecycle:l,discovery:{_ in try rawFixtureEndpoint(root)});cancel.start();Thread.sleep(forTimeInterval:0.1);let start=monotonic();cancel.stop();check(l.wait(timeout:.now()+2) == .success && monotonic()-start<1,"stop cancels a startup/quiet connection promptly")
    for n in 0..<12 {
        let l=DispatchGroup(),early=AndroidRawSession(serial:"emulator-5554",maxSize:64,network:network,lifecycle:l,discovery:{_ in try rawFixtureEndpoint(root)})
        early.start();Thread.sleep(forTimeInterval:Double(n%4)*0.001);early.stop();early.stop();check(l.wait(timeout:.now()+2) == .success,"startup cancellation/idempotent stop race")
    }
    for size in [-1,0,7,4097] {reject("raw size argument bound"){_ = try EmulatorRawWire.image(proto,maxSize:size)}}
    reject("inactive MMAP metadata is not a normal display-off image"){_ = try EmulatorRawWire.image(length(1,format+length(6,Data([8,1]))),maxSize:8)}
    let requests=events().filter{$0["kind"] as? String=="raw-request"};check(requests.allSatisfy{$0["authValid"] as? Bool==true && $0["format"] as? Int==1},"only authenticated RGBA screenshot RPCs")
    try? FileManager.default.removeItem(at:root.appendingPathComponent("raw-mode.json"))
    try jsonData(["checks":checks,"passed":true,"real_capture":false,"real_input":false,"real_device_actions":false,"transport":"system curl HTTP2 + owned Node h2 peer"]).write(to:root.appendingPathComponent("raw-native-review.json"))
    print("Emulator raw native checks: \(checks) passed")
}
