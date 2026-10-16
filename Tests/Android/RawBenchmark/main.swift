import Foundation
import CoreImage
import Darwin

// Process CPU only; no emulator, curl, window capture, network or device input.
// Compile both versions first, then run serial ABBA trials with identical work.
let mode=CommandLine.arguments[1],destination=URL(fileURLWithPath:CommandLine.arguments[2])
let width=411,height=914,fps=60
#if RAW_OPTIMIZED
let implementation="optimized"
#else
let implementation="baseline"
#endif
func cpu()->Double {var r=rusage();getrusage(RUSAGE_SELF,&r);return Double(r.ru_utime.tv_sec+r.ru_stime.tv_sec)+Double(r.ru_utime.tv_usec+r.ru_stime.tv_usec)/1_000_000}
func field(_ n:Int,_ data:Data)->Data {let size=EmulatorRawWire.uint(n,UInt64(data.count));return Data([UInt8(n*8+2)])+size.dropFirst()+data}
func rgba(_ n:Int)->Data {
    var d=Data(count:width*height*4)
    d.withUnsafeMutableBytes { raw in let p=raw.bindMemory(to:UInt8.self);for y in 0..<height{for x in 0..<width{let i=(y*width+x)*4;p[i]=UInt8((x+n*3)%256);p[i+1]=UInt8((y+n*7)%256);p[i+2]=UInt8((x+y+n*11)%256);p[i+3]=255}} }
    return d
}
var report:[String:Any]=["implementation":implementation,"mode":mode,"width":width,"height":height,"real_capture":false,"real_input":false,"scope":"this process only, excludes codec services/emulator/curl/browser; not real-device CPU savings"]
if mode=="parser" {
    let pixels=rgba(1),format=EmulatorRawWire.uint(1,1)+EmulatorRawWire.uint(3,UInt64(width))+EmulatorRawWire.uint(4,UInt64(height))
    let proto=field(1,format)+field(4,pixels)+EmulatorRawWire.uint(6,1)
    var packet=Data([0]);packet.scrcpyAppend(UInt32(proto.count));packet.append(proto)
    let chunks=stride(from:0,to:packet.count,by:65536).map{packet.subdata(in:$0..<min($0+65536,packet.count))}
    var parser=EmulatorRawWire.Messages(),latest:EmulatorRawWire.Frame?,checksum=0,frames=0
    func parse()throws {for chunk in chunks{try parser.append(chunk){latest=try EmulatorRawWire.image($0,maxSize:height);frames+=1}};checksum+=Int(latest!.bytes[0])}
    for _ in 0..<120 {try autoreleasepool{try parse()}}
    frames=0;checksum=0;let before=cpu(),start=monotonic(),count=1800
    for _ in 0..<count {try autoreleasepool{try parse()}}
    let elapsed=monotonic()-start,used=cpu()-before
    guard frames==count,checksum==count*3 else{throw WispError("parser output mismatch")}
    report.merge(["frames":frames,"source_frames":frames,"h264_frames":0,"cpu_seconds":used,"wall_seconds":elapsed,"cpu_ms_per_frame":used*1000/Double(count),"checksum":checksum]){_,n in n}
    #if RAW_OPTIMIZED
    guard parser.storageCounters.0<=4 else{throw WispError("unbounded parser")}
    report["slab_allocations"]=parser.storageCounters.0;report["slab_reuses"]=parser.storageCounters.1
    #endif
} else {
    guard mode=="static" || mode=="fresh" else{throw WispError("unknown mode")}
    let space=CGColorSpace(name:CGColorSpace.sRGB)!
    let images=(0..<16).map{CIImage(bitmapData:rgba($0),bytesPerRow:width*4,size:CGSize(width:width,height:height),format:.RGBA8,colorSpace:space)}
    let e=try H264Encoder(width:width,height:height);defer{e.close()}
    var last:UInt64=0,encoded=0,bytes=0,preparedCount=0,keys=0
    #if RAW_OPTIMIZED
    var prepared:H264Encoder.PreparedFrame?
    #endif
    func encode(_ n:Int)throws {
        let image=images[mode=="static" ? 0:n%images.count]
        let frame:H264Frame
        #if RAW_OPTIMIZED
        if prepared==nil || mode=="fresh" {prepared=try e.prepare(image);preparedCount+=1}
        frame=try e.encode(prepared!,quality:1,fps:fps,forceKeyframe:n==0)
        #else
        frame=try e.encode(image,quality:1,fps:fps,forceKeyframe:n==0);preparedCount+=1
        #endif
        guard frame.timestamp>last,frame.width==width,frame.height==height else{throw WispError("encode metadata")}
        last=frame.timestamp;encoded+=1;bytes+=frame.payload.count;if frame.keyframe{keys+=1}
    }
    for n in 0..<120 {try autoreleasepool{try encode(n)}}
    let pre=preparedCount;encoded=0;bytes=0;keys=0
    let before=cpu(),start=monotonic(),count=mode=="static" ? 1200:600
    for n in 0..<count {
        let delay=start+Double(n)/Double(fps)-monotonic();if delay>0{Thread.sleep(forTimeInterval:delay)}
        try autoreleasepool{try encode(n+120)}
    }
    let elapsed=monotonic()-start,used=cpu()-before
    guard e.hardware,encoded==count else{throw WispError("hardware encode count")}
    report.merge(["frames":encoded,"h264_frames":encoded,"prepared_buffers_during_measurement":preparedCount-pre,"source_versions_during_measurement":mode=="static" ? 0:count,"unique_visual_patterns":mode=="static" ? 1:16,"hardware":e.hardware,"cpu_seconds":used,"wall_seconds":elapsed,"cpu_percent_one_core":100*used/elapsed,"cpu_ms_per_frame":1000*used/Double(encoded),"requested_fps":fps,"encoded_fps":Double(encoded-1)/elapsed,"keyframes":keys,"encoded_bytes":bytes]){_,n in n}
}
try jsonData(report).write(to:destination)
print(String(data:jsonData(report),encoding:.utf8)!)
