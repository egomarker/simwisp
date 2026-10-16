import Foundation
import Darwin
import CoreImage

// A single existing system HTTP/2 client per stream, not a process per frame.
// libcurl handles HTTP/2 flow control/HPACK; no Node/gRPC package is installed.
// Credentials enter curl via a private stdin pipe, NEVER argv, files or logs.
final class AndroidRawSession: @unchecked Sendable {
    typealias Discovery=(String)throws->EmulatorRawEndpoint
    let maxSize:Int
    private let serial:String,discover:Discovery,network:DispatchQueue,lifecycle:DispatchGroup
    private let worker=DispatchQueue(label:"Simwisp.raw-source",qos:.userInitiated)
    private let lock=NSLock(),encodeLock=NSLock(),work=DispatchGroup(),wake=Pipe()
    private var started=false,cancelled=false,finished=false,ready=false,noticePending=false
    private var failure:String?,latest:EmulatorRawWire.Frame?,available=false
    private var cached:CIImage?,cachedVersion:UInt64=0,encodedVersion:UInt64=0,version:UInt64=0
    private var encoder:H264Encoder?,received:UInt64=0,receivedBytes:UInt64=0,dropped:UInt64=0,encoded:UInt64=0,cachedEncodes:UInt64=0,encoderCreations:UInt64=0,bufferPeak=0
    private var dimensions=(0,0),hardware=false,lastAt:Double?,sourceTimestamp:UInt64=0
    var onChange:(()->Void)?
    init(serial:String,maxSize:Int,network:DispatchQueue,lifecycle:DispatchGroup,discovery:@escaping Discovery=EmulatorRawEndpoint.discover){
        self.serial=serial;self.maxSize=min(EmulatorRawWire.maxEdge,max(8,maxSize));self.network=network;self.lifecycle=lifecycle;discover=discovery
    }
    var state:(ready:Bool,error:String?,finished:Bool){lock.withLock{(ready && !cancelled,failure,finished)}}
    private var aliveLocked:Bool{!cancelled && !finished && failure==nil && ready && available}
    func canEncode(dataSaver:Bool,forceKeyframe:Bool)->Bool{lock.withLock{aliveLocked && (latest != nil || (!dataSaver || forceKeyframe))}}
    var diagnostics:[String:Any]{lock.withLock{[
        "source_mode":"emulator_host_rgba_stream","source_format":"RGBA8888","source_frames":received,"source_raw_bytes":receivedBytes,"video_width":dimensions.0,"video_height":dimensions.1,"max_size":maxSize,"queued_frames":latest == nil ? 0:1,"dropped_frames":dropped,"h264_encodes":encoded,"cached_image_encodes":cachedEncodes,"encoder_creations":encoderCreations,"hardware_encoder":hardware,"cached_image_available":aliveLocked,"last_frame_age_ms":lastAt.map{max(0,(monotonic()-$0)*1000)} as Any? ?? NSNull(),"source_timestamp_us":sourceTimestamp,"receive_buffer_peak_bytes":bufferPeak,"jpeg_encodes":0,"jpeg_decodes":0
    ]}}
    private func notify(){let send=lock.withLock{()->Bool in if cancelled || noticePending{return false};noticePending=true;return true};if send{network.async{[weak self] in guard let self else{return};self.lock.withLock{self.noticePending=false};if !self.lock.withLock({self.cancelled}){self.onChange?()}}}}
    private var stopped:Bool{lock.withLock{cancelled}}
    func start(){
        let begin=lock.withLock{()->Bool in guard !started,!cancelled else{return false};started=true;work.enter();lifecycle.enter();return true};guard begin else{return}
        worker.async{[self] in
            var process:Process?,directory:URL?,out:Pipe?,err:Pipe?,input:Pipe?
            defer{
                if let p=process {if p.isRunning{p.terminate();let end=monotonic()+0.5;while p.isRunning && monotonic()<end{Thread.sleep(forTimeInterval:0.01)};if p.isRunning{Darwin.kill(p.processIdentifier,SIGKILL)}};p.waitUntilExit()}
                for pipe in [out,err,input]{try? pipe?.fileHandleForReading.close();try? pipe?.fileHandleForWriting.close()}
                if let directory{try? FileManager.default.removeItem(at:directory)}
                lock.withLock{ready=false;available=false;latest=nil;finished=true;try? wake.fileHandleForReading.close();try? wake.fileHandleForWriting.close()}
                encodeLock.withLock{cached=nil;encoder?.close();encoder=nil};notify();work.leave();lifecycle.leave()
            }
            do{
                let endpoint=try discover(serial);guard !stopped else{return}
                let dir=FileManager.default.temporaryDirectory.appendingPathComponent("simwisp-raw-"+UUID().uuidString)
                try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);directory=dir
                let request=dir.appendingPathComponent("request.bin");try EmulatorRawWire.request(maxSize:maxSize).write(to:request,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:request.path)
                let p=Process(),stdout=Pipe(),stderr=Pipe(),stdin=Pipe();out=stdout;err=stderr;input=stdin
                p.executableURL=URL(fileURLWithPath:"/usr/bin/curl")
                p.arguments=["-q","--http2-prior-knowledge","--no-buffer","--silent","--show-error","--connect-timeout","5","--proto","=http","--max-redirs","0","--noproxy","*","--proxy","","--request","POST","--header","content-type: application/grpc","--header","te: trailers","--dump-header","/dev/stderr","--config","-","--data-binary","@"+request.path,"--url","http://127.0.0.1:\(endpoint.port)/android.emulation.control.EmulatorController/streamScreenshot"]
                p.standardInput=stdin;p.standardOutput=stdout;p.standardError=stderr
                let escaped=endpoint.token.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")
                _ = fcntl(stdin.fileHandleForWriting.fileDescriptor,F_SETFL,O_NONBLOCK)
                try stdin.fileHandleForWriting.write(contentsOf:Data("header = \"authorization: Bearer \(escaped)\"\n".utf8));try stdin.fileHandleForWriting.close()
                guard !stopped else{return};try p.run();process=p
                try stdout.fileHandleForWriting.close();try stderr.fileHandleForWriting.close();try stdin.fileHandleForReading.close()
                let outputFD=stdout.fileHandleForReading.fileDescriptor,errorFD=stderr.fileHandleForReading.fileDescriptor,cancelFD=wake.fileHandleForReading.fileDescriptor
                var headers=EmulatorRawWire.Headers(),messages=EmulatorRawWire.Messages(),firstPacket=false,lastSequence:UInt64?,pending:Data?
                let initialDeadline=monotonic()+8
                func accept(_ data:Data)throws{
                    let frame=try EmulatorRawWire.image(data,maxSize:maxSize);firstPacket=true
                    if frame.active {if let previous=lastSequence,frame.sequence<=previous{throw WispError("Stale emulator raw image sequence")};lastSequence=frame.sequence}
                    lock.withLock{
                        guard !cancelled else{return}
                        if !frame.active{latest=nil;available=false;ready=false;return}
                        if latest != nil{dropped &+= 1};latest=frame;version &+= 1;received &+= 1;receivedBytes &+= UInt64(frame.bytes.count);dimensions=(frame.width,frame.height);lastAt=monotonic();sourceTimestamp=frame.timestampUS;available=true;ready=true
                    };notify()
                }
                while !stopped {
                    if let value=pending,headers.ready{pending=nil;try accept(value)}
                    if !firstPacket && monotonic()>=initialDeadline{throw WispError("Emulator raw API produced no initial image")}
                    var fds=[pollfd(fd:errorFD,events:Int16(POLLIN),revents:0),pollfd(fd:pending==nil ? outputFD:-1,events:Int16(POLLIN),revents:0),pollfd(fd:cancelFD,events:Int16(POLLIN),revents:0)]
                    let timeout:Int32=firstPacket ? -1:Int32(max(1,min(8000,(initialDeadline-monotonic())*1000)))
                    let count=Darwin.poll(&fds,3,timeout);if count<0 && errno==EINTR{continue};guard count>=0 else{throw WispError("Emulator raw transport failed")};if count==0{continue}
                    if fds[2].revents != 0 || stopped{break}
                    for i in 0...1 where fds[i].revents != 0 {
                        var bytes=Data(count:65536);let n=bytes.withUnsafeMutableBytes{Darwin.read(fds[i].fd,$0.baseAddress!,65536)}
                        if n<0 && errno==EINTR{continue};guard n>0 else{throw WispError("Emulator raw stream disconnected")};bytes.count=n
                        if i==0 {try headers.append(bytes)}else{
                            try messages.append(bytes){value in if headers.ready{try accept(value)}else{guard pending==nil else{throw WispError("Raw image before validated HTTP/2 headers")};pending=value}}
                            lock.withLock{bufferPeak=messages.peakBytes}
                        }
                    }
                }
            }catch{if !stopped{lock.withLock{failure="Emulator raw capture failed: "+((error as? WispError)?.message ?? "transport unavailable");ready=false;available=false;latest=nil};notify()}}
        }
    }
    func h264(quality:Int,fps:Int,forceKeyframe:Bool,dataSaver:Bool)throws->H264Frame?{
        try encodeLock.withLock{try autoreleasepool{
            let state=lock.withLock{()->(EmulatorRawWire.Frame?,UInt64)? in guard aliveLocked else{return nil};let f=latest;latest=nil;return(f,version)}
            guard let(frame,current)=state else{return nil}
            do{
                if let frame {
                    // streamScreenshot supplies an already display-oriented
                    // bitmap. The legacy proto's "bottom up" comment must not
                    // become a SECOND Mac-side vertical flip. No emulator change.
                    cached=CIImage(bitmapData:frame.bytes,bytesPerRow:frame.width*4,size:CGSize(width:frame.width,height:frame.height),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!);cachedVersion=current
                }
                guard let cached,(!dataSaver || encodedVersion != cachedVersion || forceKeyframe),lock.withLock({aliveLocked}) else{return nil}
                let resized=encoder?.width != Int(cached.extent.width) || encoder?.height != Int(cached.extent.height)
                if resized{encoder?.close();encoder=try H264Encoder(width:Int(cached.extent.width),height:Int(cached.extent.height));lock.withLock{encoderCreations &+= 1}}
                let result=try encoder!.encode(cached,quality:quality,fps:fps,forceKeyframe:forceKeyframe || resized)
                let accepted=lock.withLock{()->Bool in guard aliveLocked else{return false};encoded &+= 1;if frame==nil{cachedEncodes &+= 1};hardware=encoder!.hardware;return true}
                guard accepted else{return nil};encodedVersion=cachedVersion;return result
            }catch{lock.withLock{if !cancelled{failure="Emulator raw H.264 encoding failed"};ready=false;available=false;latest=nil};cached=nil;encoder?.close();encoder=nil;notify();throw error}
        }}
    }
    func stop(completion:@escaping()->Void={}){
        lock.withLock{let first = !cancelled;cancelled=true;ready=false;available=false;latest=nil;if first && started && !finished{try? wake.fileHandleForWriting.write(contentsOf:Data([1]))}}
        work.notify(queue:network,execute:completion)
    }
}
