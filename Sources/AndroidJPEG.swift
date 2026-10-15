import Foundation
import Darwin
import CoreImage
import ImageIO

// Independent JPEGs are safe to replace, unlike interdependent H.264 P-frames.
struct AndroidJPEGFrame {
    let bytes: Data, sequence: UInt64, capturedNS: UInt64
    let width: Int, height: Int
}
enum AndroidJPEGWire {
    static let maxBytes = 8_388_608, maxEdge = 4096, quality = 70
    struct Header { let length: Int; let sequence: UInt64, capturedNS: UInt64; let width: Int, height: Int }
    static func header(_ d: Data) throws -> Header {
        guard d.count == 32, d.prefix(4) == Data("SWJ1".utf8) else { throw WispError("Invalid emulator JPEG frame header") }
        let n=Int(d.scrcpyUInt(4,4)),s=d.scrcpyUInt(8,8),t=d.scrcpyUInt(16,8),w=Int(d.scrcpyUInt(24,4)),h=Int(d.scrcpyUInt(28,4))
        guard (4...maxBytes).contains(n),s>0,t>0,(8...maxEdge).contains(w),(8...maxEdge).contains(h) else { throw WispError("Emulator JPEG frame exceeds bounds") }
        return Header(length:n,sequence:s,capturedNS:t,width:w,height:h)
    }
    static func image(_ f: AndroidJPEGFrame) throws -> CIImage {
        let b=f.bytes
        guard (4...maxBytes).contains(b.count),b.prefix(2)==Data([255,216]),b.suffix(2)==Data([255,217]),
              let source=CGImageSourceCreateWithData(b as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.jpeg",CGImageSourceGetCount(source)==1,
              let p=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let w=p[kCGImagePropertyPixelWidth] as? Int,let h=p[kCGImagePropertyPixelHeight] as? Int,
              (8...maxEdge).contains(w),(8...maxEdge).contains(h),w==f.width,h==f.height,
              (p[kCGImagePropertyOrientation] as? Int ?? 1)==1,
              let cg=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source,0) == .statusComplete,cg.width==w,cg.height==h else { throw WispError("Invalid or mismatched emulator JPEG image") }
        return CIImage(cgImage:cg)
    }
}

final class AndroidJPEGSession: @unchecked Sendable {
    typealias Installation = () throws -> String
    static func bundledJar() throws -> String {
        guard let u=Bundle.main.url(forResource:"simwisp-jpeg",withExtension:"jar"),FileManager.default.isReadableFile(atPath:u.path) else { throw WispError("Emulator JPEG helper is not bundled. Rebuild with JDK and Android SDK platform34+ / build-tools.") }
        return u.path
    }
    let fps: Int, maxSize: Int
    private let lock=NSLock(),encodeLock=NSLock(),work=DispatchGroup()
    private let worker=DispatchQueue(label:"Simwisp.jpeg-source",qos:.userInitiated)
    private let network:DispatchQueue,lifecycle:DispatchGroup,adb:String,serial:String
    private let installation:Installation,run:(String,[String],Double)throws->CommandResult
    private var started=false,cancelled=false,finished=false,ready=false,noticePending=false
    private var failure:String?,latest:AndroidJPEGFrame?,previous:Data?,encoder:H264Encoder?
    private var received:UInt64=0,receivedBytes:UInt64=0,dropped:UInt64=0,encoded:UInt64=0
    private var dimensions=(0,0),lastAt:Double?,hardware=false
    var onChange:(()->Void)?
    init(adb:String,serial:String,fps:Int,maxSize:Int,network:DispatchQueue,lifecycle:DispatchGroup,installation:@escaping Installation=AndroidJPEGSession.bundledJar,run:@escaping(String,[String],Double)throws->CommandResult={try command($0,$1,timeout:$2)}) {
        self.adb=adb;self.serial=serial;self.fps=min(60,max(1,fps));self.maxSize=min(AndroidJPEGWire.maxEdge,max(8,maxSize));self.network=network;self.lifecycle=lifecycle;self.installation=installation;self.run=run
    }
    var state:(ready:Bool,error:String?,finished:Bool) { lock.withLock{(ready && !cancelled,failure,finished)} }
    var hasFrame:Bool { lock.withLock{!cancelled && failure==nil && latest != nil} }
    var diagnostics:[String:Any] { lock.withLock{["source_frames":received,"source_jpeg_bytes":receivedBytes,"jpeg_quality":AndroidJPEGWire.quality,"video_width":dimensions.0,"video_height":dimensions.1,"max_size":maxSize,"source_fps_limit":fps,"queued_frames":latest == nil ? 0:1,"dropped_frames":dropped,"h264_encodes":encoded,"hardware_encoder":hardware,"last_frame_age_ms":lastAt.map{max(0,(monotonic()-$0)*1000)} as Any? ?? NSNull()]} }
    private var isCancelled:Bool { lock.withLock{cancelled} }
    private func notify() {
        let emit=lock.withLock{()->Bool in if cancelled || noticePending{return false};noticePending=true;return true}
        if emit { network.async{[weak self] in guard let self else{return};self.lock.withLock{self.noticePending=false};if !self.isCancelled{self.onChange?()} } }
    }
    private func tool(_ args:[String],_ timeout:Double=4)throws->CommandResult {
        guard !isCancelled else{throw WispError("Emulator JPEG cancelled")}
        let r=try run(adb,["-s",serial]+args,timeout)
        guard r.status==0 else{throw WispError("Emulator JPEG ADB operation failed")};return r
    }
    // The PID file belongs to a unique private directory. Verify its exact argv0
    // before a signal, so a recycled PID can never kill another process.
    static func cleanup(directory:String,name:String)->String {
        "if [ -f '\(directory)/pid' ]; then p=$(cat '\(directory)/pid'); case \"$p\" in ''|*[!0-9]*) ;; *) c=$(tr '\\000' '\\n' < /proc/$p/cmdline 2>/dev/null | head -n 1); if [ \"$c\" = '\(name)' ]; then kill -TERM \"$p\" 2>/dev/null; fi ;; esac; fi; rm -rf '\(directory)'"
    }
    // ADB preserves the final sh -c argument as the command string. Wrapping
    // that string in another pair of quotes turns the whole command into argv0.
    static func arguments(directory:String,name:String,maxSize:Int,fps:Int)->[String] {
        let launch="CLASSPATH='\(directory)/helper.jar' exec app_process / --nice-name=\(name) io.simwisp.SimwispJpeg \(maxSize) \(fps) '\(directory)/pid'"
        return ["exec-out","sh","-c",launch]
    }
    func start() {
        let begin=lock.withLock{()->Bool in guard !started,!cancelled else{return false};started=true;work.enter();lifecycle.enter();return true}
        guard begin else{return}
        worker.async{[self] in
            var directory:String?,process:Process?,pipe:Pipe?
            let token=UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased(),name="simwisp-jpeg-"+token
            defer {
                lock.withLock{ready=false;latest=nil}
                if let directory { _ = try? run(adb,["-s",serial,"shell",Self.cleanup(directory:directory,name:name)],3) }
                if let p=process {
                    if p.isRunning {p.terminate();let end=monotonic()+0.5;while p.isRunning && monotonic()<end{Thread.sleep(forTimeInterval:0.02)};if p.isRunning{Darwin.kill(p.processIdentifier,SIGKILL)}}
                    p.waitUntilExit()
                }
                try? pipe?.fileHandleForReading.close();try? pipe?.fileHandleForWriting.close()
                encodeLock.withLock{encoder?.close();encoder=nil;previous=nil}
                lock.withLock{finished=true};notify();work.leave();lifecycle.leave()
            }
            do {
                guard DeviceControl.validID(serial,platform:"android") else{throw WispError("Invalid emulator JPEG serial")}
                let jar=try installation()
                guard FileManager.default.isReadableFile(atPath:jar) else{throw WispError("Emulator JPEG helper is unreadable")}
                let remote="/data/local/tmp/"+name
                _ = try tool(["shell","mkdir -m 700 '"+remote+"'"]);directory=remote
                _ = try tool(["push",jar,remote+"/helper.jar"],8)
                let p=Process(),out=Pipe();p.executableURL=URL(fileURLWithPath:adb)
                p.arguments=["-s",serial]+Self.arguments(directory:remote,name:name,maxSize:maxSize,fps:fps)
                p.standardInput=FileHandle.nullDevice;p.standardOutput=out;p.standardError=FileHandle.nullDevice
                pipe=out;guard !isCancelled else{throw WispError("Emulator JPEG cancelled")};try p.run();process=p;try out.fileHandleForWriting.close()
                let fd=out.fileHandleForReading.fileDescriptor
                func read(_ count:Int,deadline:Double)throws->Data {
                    guard (1...AndroidJPEGWire.maxBytes).contains(count) else{throw WispError("Invalid emulator JPEG read")}
                    var d=Data(count:count),offset=0
                    while offset<count {
                        guard !isCancelled,monotonic()<deadline else{throw WispError("Emulator JPEG stopped or frame timed out")}
                        var poller=pollfd(fd:fd,events:Int16(POLLIN),revents:0)
                        let polled=Darwin.poll(&poller,1,100)
                        if polled==0 || (polled<0 && errno==EINTR){continue}
                        guard polled>0 else{throw WispError("Emulator JPEG transport failed")}
                        let n=d.withUnsafeMutableBytes{Darwin.read(fd,$0.baseAddress!.advanced(by:offset),count-offset)}
                        if n<0 && errno==EINTR{continue};guard n>0 else{throw WispError("Emulator JPEG helper disconnected (Android14+ capture support required)")};offset+=n
                    }
                    return d
                }
                var sequence:UInt64=0,timestamp:UInt64=0
                while !isCancelled {
                    let deadline=monotonic()+8,prefix=try read(8,deadline:deadline)
                    if prefix.prefix(4)==Data("SWE1".utf8) {
                        let n=Int(prefix.scrcpyUInt(4,4));guard (1...2048).contains(n) else{throw WispError("Invalid emulator JPEG error packet")}
                        let text=String(decoding:try read(n,deadline:deadline),as:UTF8.self).unicodeScalars.filter{!CharacterSet.controlCharacters.contains($0)}
                        throw WispError(String(String.UnicodeScalarView(text)))
                    }
                    let h=try AndroidJPEGWire.header(prefix+read(24,deadline:deadline))
                    guard h.sequence>sequence,h.capturedNS>timestamp,h.width<=maxSize,h.height<=maxSize else{throw WispError("Stale or oversized emulator JPEG frame")}
                    let bytes=try read(h.length,deadline:deadline)
                    guard bytes.prefix(2)==Data([255,216]),bytes.suffix(2)==Data([255,217]) else{throw WispError("Invalid emulator JPEG markers")}
                    sequence=h.sequence;timestamp=h.capturedNS
                    let frame=AndroidJPEGFrame(bytes:bytes,sequence:sequence,capturedNS:timestamp,width:h.width,height:h.height)
                    lock.withLock{guard !cancelled else{return};if latest != nil{dropped &+= 1};latest=frame;received &+= 1;receivedBytes &+= UInt64(bytes.count);dimensions=(h.width,h.height);lastAt=monotonic();ready=true}
                    notify()
                }
            } catch { if !isCancelled{lock.withLock{failure=error.localizedDescription};notify()} }
        }
    }
    func h264(quality:Int,fps:Int,forceKeyframe:Bool,dataSaver:Bool)throws->H264Frame? {
        try encodeLock.withLock { try autoreleasepool {
            let frame=lock.withLock{()->AndroidJPEGFrame? in guard !cancelled,failure==nil,let f=latest else{return nil};latest=nil
                guard let at=lastAt,monotonic()-at<=max(0.5,2/Double(self.fps)) else{dropped &+= 1;return nil};return f}
            guard let frame else{return nil}
            if dataSaver && previous==frame.bytes && !forceKeyframe{return nil}
            let image=try AndroidJPEGWire.image(frame)
            let resized=encoder?.width != frame.width || encoder?.height != frame.height
            if resized {encoder?.close();encoder=try H264Encoder(width:frame.width,height:frame.height)}
            let result=try encoder!.encode(image,quality:quality,fps:fps,forceKeyframe:forceKeyframe || resized)
            previous=frame.bytes
            lock.withLock{encoded &+= 1;hardware=encoder!.hardware}
            return result
        } }
    }
    func stop(completion:@escaping()->Void={}) {
        lock.withLock{cancelled=true;latest=nil}
        work.notify(queue:network,execute:completion)
    }
}
