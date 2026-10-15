import Foundation
import CoreImage
import CoreText
import ImageIO
import VideoToolbox
import ScreenCaptureKit
import CryptoKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory:true)
// Opt-in fidelity regression: synthetic pixels only; never starts SCStream/ADB.
let width=411,height=914,moving=180,fps=60
let staticFrames=Int(ProcessInfo.processInfo.environment["VIDEO_QUALITY_STATIC_FRAMES"] ?? "900") ?? 900
let resumed=90,total=moving+staticFrames+resumed,forcedAt=450
let bounds=CGRect(x:0,y:0,width:width,height:height)
let space=CGColorSpace(name:CGColorSpace.sRGB)!
let context=CIContext(options:[.cacheIntermediates:false])
let font=CTFontCreateWithName("Menlo" as CFString,11,nil)
func checked(_ s:OSStatus,_ why:String)throws {if s != noErr{throw WispError("\(why): \(s)")}}
func synthetic(_ n:Int)throws->CGImage {
    guard let c=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{throw WispError("bitmap")}
    c.setFillColor(CGColor(gray:1,alpha:1));c.fill(bounds)
    c.saveGState();c.clip(to:CGRect(x:8,y:30,width:width-16,height:height-100))
    let offset=n*5
    for row in -5..<65 {
        let y=Double(height-95-row*20+offset%20),index=row+offset/20
        if index%4==0{c.setFillColor(CGColor(red:0.94,green:0.96,blue:0.99,alpha:1));c.fill(CGRect(x:12.0,y:y-3,width:Double(width-24),height:18.0))}
        let string=String(format:"%03d  State: ready | value %05d",index,abs(index*7919)%99991)
        let a=NSAttributedString(string:string,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:0.08,alpha:1)])
        c.textPosition=CGPoint(x:16,y:y);CTLineDraw(CTLineCreateWithAttributedString(a),c)
        if index%3==0{for x in stride(from:20,to:390,by:6){c.setFillColor(CGColor(red:Double((x+index)&7)/8,green:0.35,blue:0.75,alpha:1));c.fill(CGRect(x:x,y:Int(y)-7,width:3,height:2))}}
    }
    c.restoreGState();c.setFillColor(CGColor(red:0.12,green:0.32,blue:0.65,alpha:1));c.fill(CGRect(x:0,y:height-60,width:width,height:60))
    let title=NSAttributedString(string:"SYNTHETIC MOTION / STATIC",attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:1,alpha:1)])
    c.textPosition=CGPoint(x:20,y:height-35);CTLineDraw(CTLineCreateWithAttributedString(title),c)
    guard let image=c.makeImage() else{throw WispError("make image")};return image
}
func jpeg(_ image:CGImage)throws->Data {
    let data=NSMutableData();guard let dest=CGImageDestinationCreateWithData(data,"public.jpeg" as CFString,1,nil) else{throw WispError("jpeg destination")}
    CGImageDestinationAddImage(dest,image,[kCGImageDestinationLossyCompressionQuality:0.70] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else{throw WispError("jpeg write")};return data as Data
}
func jpegImage(_ data:Data)throws->CIImage {
    guard let src=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),let image=CGImageSourceCreateImageAtIndex(src,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else{throw WispError("jpeg decode")};return CIImage(cgImage:image)
}
func pixels(_ image:CIImage)->[UInt8] {
    var bytes=[UInt8](repeating:0,count:width*height*4)
    bytes.withUnsafeMutableBytes{context.render(image,toBitmap:$0.baseAddress!,rowBytes:width*4,bounds:bounds,format:.RGBA8,colorSpace:space)};return bytes
}
func macSource(_ image:CIImage,_ capture:WindowCapture)throws->CIImage {
    var pixel:CVPixelBuffer?
    try checked(CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&pixel),"synthetic Mac pixel")
    context.render(image,to:pixel!,bounds:bounds,colorSpace:space)
    CVBufferSetAttachment(pixel!,kCVImageBufferCGColorSpaceKey,space,.shouldPropagate)
    var format:CMFormatDescription?,sample:CMSampleBuffer?
    try checked(CMVideoFormatDescriptionCreateForImageBuffer(allocator:nil,imageBuffer:pixel!,formatDescriptionOut:&format),"Mac format")
    var timing=CMSampleTimingInfo(duration:.invalid,presentationTimeStamp:.zero,decodeTimeStamp:.invalid)
    try checked(CMSampleBufferCreateReadyWithImageBuffer(allocator:nil,imageBuffer:pixel!,formatDescription:format!,sampleTiming:&timing,sampleBufferOut:&sample),"Mac sample")
    let attachments=CMSampleBufferGetSampleAttachmentsArray(sample!,createIfNecessary:true)!
    let dict=Unmanaged<NSMutableDictionary>.fromOpaque(CFArrayGetValueAtIndex(attachments,0)).takeUnretainedValue()
    dict[SCStreamFrameInfo.status.rawValue]=SCFrameStatus.complete.rawValue
    capture.receive(sample!,type:.screen)
    return CIImage(cvPixelBuffer:pixel!)
}
func score(_ reference:[UInt8],_ output:[UInt8])->(Double,Double) {
    var error=0.0,edge=0.0,referenceEdge=0.0,count=0
    for y in stride(from:2,to:height-2,by:2){for x in stride(from:2,to:width-2,by:2){let p=(y*width+x)*4
        for k in 0..<3{let difference=Double(Int(reference[p+k])-Int(output[p+k]));error+=difference*difference;count+=1}
        edge+=Double(abs(Int(output[p])-Int(output[p-8]))+abs(Int(output[p])-Int(output[p-width*8])))
        referenceEdge+=Double(abs(Int(reference[p])-Int(reference[p-8]))+abs(Int(reference[p])-Int(reference[p-width*8])))
    }}
    let mse=error/Double(count);return(mse>0 ? 10*log10(255*255/mse):99,referenceEdge>0 ? edge/referenceEdge:0)
}
final class QualityDecoder {
    var session:VTDecompressionSession?,format:CMFormatDescription?,image:CVPixelBuffer?,count=0,error:OSStatus=noErr
    init(_ description:Data)throws {
        let avcc=[UInt8](description);var offset=6,sets=[[UInt8]]()
        func read()throws{guard offset+2<=avcc.count else{throw WispError("avcc length")};let n=Int(avcc[offset])*256+Int(avcc[offset+1]);offset+=2;guard offset+n<=avcc.count else{throw WispError("avcc set")};sets.append(Array(avcc[offset..<offset+n]));offset+=n}
        for _ in 0..<Int(avcc[5]&31){try read()};let n=Int(avcc[offset]);offset+=1;for _ in 0..<n{try read()};guard sets.count==2 else{throw WispError("sets")}
        try checked(sets[0].withUnsafeBufferPointer{sps in sets[1].withUnsafeBufferPointer{pps in let pointers=[sps.baseAddress!,pps.baseAddress!],sizes=[sps.count,pps.count];return pointers.withUnsafeBufferPointer{p in sizes.withUnsafeBufferPointer{z in CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator:nil,parameterSetCount:2,parameterSetPointers:p.baseAddress!,parameterSetSizes:z.baseAddress!,nalUnitHeaderLength:4,formatDescriptionOut:&format)}}}},"format")
        var cb=VTDecompressionOutputCallbackRecord(decompressionOutputCallback:{p,_,status,_,image,_,_ in let me=Unmanaged<QualityDecoder>.fromOpaque(p!).takeUnretainedValue();me.image=image;me.error=status;me.count+=1},decompressionOutputRefCon:Unmanaged.passUnretained(self).toOpaque())
        try checked(VTDecompressionSessionCreate(allocator:nil,formatDescription:format!,decoderSpecification:nil,imageBufferAttributes:[kCVPixelBufferPixelFormatTypeKey:kCVPixelFormatType_32BGRA] as CFDictionary,outputCallback:&cb,decompressionSessionOut:&session),"decoder")
    }
    func decode(_ frame:H264Frame)throws->CVPixelBuffer {
        var block:CMBlockBuffer?;try checked(CMBlockBufferCreateWithMemoryBlock(allocator:nil,memoryBlock:nil,blockLength:frame.payload.count,blockAllocator:nil,customBlockSource:nil,offsetToData:0,dataLength:frame.payload.count,flags:0,blockBufferOut:&block),"block")
        try checked(frame.payload.withUnsafeBytes{CMBlockBufferReplaceDataBytes(with:$0.baseAddress!,blockBuffer:block!,offsetIntoDestination:0,dataLength:frame.payload.count)},"copy")
        var sample:CMSampleBuffer?,size=frame.payload.count,timing=CMSampleTimingInfo(duration:.invalid,presentationTimeStamp:CMTime(value:Int64(frame.timestamp),timescale:1_000_000),decodeTimeStamp:.invalid)
        try checked(CMSampleBufferCreateReady(allocator:nil,dataBuffer:block,formatDescription:format,sampleCount:1,sampleTimingEntryCount:1,sampleTimingArray:&timing,sampleSizeEntryCount:1,sampleSizeArray:&size,sampleBufferOut:&sample),"sample")
        let previous=count;image=nil;try checked(VTDecompressionSessionDecodeFrame(session!,sampleBuffer:sample!,flags:[],frameRefcon:nil,infoFlagsOut:nil),"decode");try checked(VTDecompressionSessionWaitForAsynchronousFrames(session!),"wait");try checked(error,"output");guard count==previous+1,let image else{throw WispError("missing decoded output")};return image
    }
    deinit{if let session{VTDecompressionSessionInvalidate(session)}}
}

var checks=0
func expect(_ condition:Bool,_ name:String)throws {
    guard condition else{throw WispError(name)};checks+=1
}
func runQuality(_ mode:String)throws {
    let capture:WindowCapture?=mode=="mac_window" ? WindowCapture(target:DeviceWindow(id:123,pid:0,title:"synthetic",bounds:bounds,crop:bounds)):nil
    let encoder:H264Encoder?=capture==nil ? try H264Encoder(width:width,height:height):nil
    defer{encoder?.close()}
    try expect(CaptureHealth.shared.snapshot["active"] as? Int == 0,"no real capture")
    var decoder:QualityDecoder?,cached:CIImage?,truth=[UInt8](),rows=[[String:Any]](),description:Data?,lastTimestamp:UInt64=0
    var referenceHash="",allDrops=[Double](),unrequestedDrops=[Double](),automaticKeys=[Int](),resumedFrames=0
    let start=monotonic()
    for n in 0..<total {
        let delay=start+Double(n)/Double(fps)-monotonic();if delay>0{Thread.sleep(forTimeInterval:delay)}
        try autoreleasepool {
            let isStatic=n>=moving && n<moving+staticFrames,force=n==0 || n==forcedAt
            if !isStatic {
                let image=try synthetic(n<moving ? n:n-staticFrames)
                if let capture {cached=try macSource(CIImage(cgImage:image),capture)}else{cached=try jpegImage(jpeg(image))}
                truth=pixels(cached!)
                if n==moving-1{referenceHash=SHA256.hash(data:Data(truth)).map{String(format:"%02x",$0)}.joined()}
            }
            let frame:H264Frame
            if let capture {guard let value=try capture.h264(quality:1,fps:fps,forceKeyframe:force,dataSaver:false) else{throw WispError("Mac missing frame")};frame=value}
            else {frame=try encoder!.encode(cached!,quality:1,fps:fps,forceKeyframe:force)}
            try expect(frame.timestamp>lastTimestamp,"strictly monotonic PTS");lastTimestamp=frame.timestamp
            try expect(frame.width==width && frame.height==height && frame.codedWidth==412 && frame.codedHeight==914,"visible size and odd padding")
            if description==nil {description=frame.description;decoder=try QualityDecoder(frame.description)}
            try expect(description==frame.description,"same avcC throughout motion/static/recovery")
            if force {try expect(frame.keyframe,"explicit keyframe is honored")}
            let output=try decoder!.decode(frame),metric=score(truth,pixels(CIImage(cvPixelBuffer:output)))
            if isStatic {
                if frame.keyframe && !force {automaticKeys.append(n)}
                if n>moving,let previous=rows.last?["psnr"] as? Double {
                    let delta=metric.0-previous;allDrops.append(delta)
                    // Explicit recovery may replace references. The regression
                    // is unrequested static-image degradation, not recovery.
                    if !force {unrequestedDrops.append(delta)}
                }
            }else if n>=moving+staticFrames {resumedFrames+=1}
            rows.append(["frame":n,"phase":isStatic ? "static":n<moving ? "motion":"resumed_motion","timestampUS":frame.timestamp,"wallSeconds":monotonic()-start,"keyframe":frame.keyframe,"forced":force,"bytes":frame.payload.count,"psnr":metric.0,"edgeRatio":metric.1])
        }
    }
    let largeDrops=unrequestedDrops.filter{$0 < -3}.count,worst=unrequestedDrops.min() ?? 0
    let earlyAutomatic=automaticKeys.filter{$0<forcedAt || $0-forcedAt<3500}
    let boundaries=automaticKeys.filter{$0>forcedAt && $0-forcedAt>=3500}
    let hardware=(capture?.counters["hardware_encoder"] as? Bool) ?? encoder!.hardware
    let result:[String:Any]=["mode":mode,"totalFrames":total,"staticFrames":staticFrames,"resumedFrames":resumedFrames,"hardware":hardware,"decoderOutputs":decoder!.count,"descriptionCount":1,"staticReferenceSHA256":referenceHash,"largeUnrequestedDrops":largeDrops,"worstUnrequestedPSNRStep":worst,"worstAllStaticPSNRStep":allDrops.min() ?? 0,"automaticKeyframes":automaticKeys,"forcedFrame":forcedAt,"durationSeconds":monotonic()-start,"realCapture":false,"passed":largeDrops==0 && earlyAutomatic.isEmpty,"rows":rows]
    try jsonData(result).write(to:directory.appendingPathComponent(mode+"-quality.json"))
    try expect(decoder!.count==total,"all access units decode, including recovery and resumed motion")
    try expect(resumedFrames==resumed,"motion resumes after static without replacing decoder")
    try expect(largeDrops==0,"\(mode): \(largeDrops) unrequested static fidelity collapses, worst \(worst)dB")
    try expect(earlyAutomatic.isEmpty,"no short periodic IDRs in static image")
    if staticFrames>=4200 {
        try expect(boundaries.count==1,"one bounded automatic refresh past3600frames")
        try expect((3598...3601).contains(boundaries[0]-forcedAt),"automatic keyframe frame-count bound")
    }
    try expect(CaptureHealth.shared.snapshot["active"] as? Int == 0,"still no real capture")
    print("\(mode): \(total)/\(decoder!.count) encoded/decoded, zero large drops, worst \(worst)dB, autoIDs \(automaticKeys), hardware \(hardware)")
}
do {
    try expect((900...12000).contains(staticFrames),"static duration must be900...12000 frames")
    for mode in ["jpeg","mac_window"]{try runQuality(mode)}
    try jsonData(["passed":true,"checks":checks,"staticFrames":staticFrames,"realCapture":false,"realInput":false]).write(to:directory.appendingPathComponent("video-quality-review.json"))
    print("\(checks) native motion/static fidelity checks passed")
}catch{
    try? jsonData(["passed":false,"checks":checks,"error":error.localizedDescription]).write(to:directory.appendingPathComponent("video-quality-review.json"))
    fputs("FAIL: \(error.localizedDescription)\n",stderr);exit(1)
}
