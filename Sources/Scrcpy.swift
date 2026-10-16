import Foundation
import Darwin

struct ScrcpyInstallation {
    let server: String
    let version: String
    static func find() throws -> ScrcpyInstallation {
        let fm = FileManager.default
        let roots = ["/opt/homebrew", "/usr/local"]
        let candidates = roots.map { $0 + "/bin/scrcpy" } + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/scrcpy" }
        guard let binary = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else { throw WispError("scrcpy is not installed on this Mac") }
        let r = try command(binary, ["--version"], timeout: 3)
        guard r.status == 0, r.text.components(separatedBy: .newlines).first?.split(separator: " ").dropFirst().first.map(String.init) == ScrcpyWire.version else { throw WispError("scrcpy \(ScrcpyWire.version) is required (private protocol version)") }
        let real = URL(fileURLWithPath: binary).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let paths = [real.appendingPathComponent("share/scrcpy/scrcpy-server").path] + roots.map { $0 + "/share/scrcpy/scrcpy-server" }
        guard let server = paths.first(where: { fm.isReadableFile(atPath: $0) }) else { throw WispError("Matching scrcpy-server JAR is missing") }
        return ScrcpyInstallation(server: server, version: ScrcpyWire.version)
    }
}

// Owned sockets. shutdown interrupts readers; close is serialized against input
// writes so a recycled descriptor can never receive an old callback's event.
final class ScrcpySocket {
    private let lock = NSLock()
    private var fd: Int32
    init(port: UInt16) throws {
        fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WispError("Cannot create scrcpy socket") }
        var yes: Int32 = 1, timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian; a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let flags = fcntl(fd, F_GETFL); _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let result = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var connected = result == 0
        if !connected && errno == EINPROGRESS {
            var p = pollfd(fd:fd,events:Int16(POLLOUT),revents:0)
            if Darwin.poll(&p,1,250)>0 {
                var error:Int32=0,length=socklen_t(MemoryLayout<Int32>.size)
                connected=getsockopt(fd,SOL_SOCKET,SO_ERROR,&error,&length)==0 && error==0
            }
        }
        guard connected else { close(); throw WispError("scrcpy server socket is not ready") }
        _ = fcntl(fd,F_SETFL,flags)
    }
    func interrupt() { lock.withLock { if fd >= 0 { _ = Darwin.shutdown(fd, SHUT_RDWR) } } }
    func close() { lock.withLock { if fd >= 0 { Darwin.close(fd); fd = -1 } } }
    func read(_ count: Int, cancelled: () -> Bool, deadline: Double? = nil) throws -> Data {
        guard count > 0, count <= ScrcpyWire.maxPacket else { throw WispError("Invalid scrcpy read size") }
        var d = Data(count: count), offset = 0
        while offset < count {
            guard !cancelled(), deadline.map({ monotonic() < $0 }) ?? true else { throw WispError("scrcpy connection cancelled or timed out") }
            let socket = lock.withLock { fd }; guard socket >= 0 else { throw WispError("scrcpy socket closed") }
            var p = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            let polled = Darwin.poll(&p, 1, 100); if polled == 0 { continue }; if polled < 0 && errno == EINTR { continue }
            guard polled > 0 else { throw WispError("scrcpy socket read failed") }
            let n = d.withUnsafeMutableBytes { Darwin.recv(socket, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
            if n < 0 && errno == EINTR { continue }; guard n > 0 else { throw WispError("scrcpy server disconnected") }; offset += n
        }
        return d
    }
    func send(_ d: Data) throws {
        try lock.withLock {
            guard fd >= 0 else { throw WispError("scrcpy input is disconnected") }; var offset = 0
            let deadline = monotonic() + 0.3
            while offset < d.count {
                guard monotonic() < deadline else { throw WispError("scrcpy input write timed out") }
                let n = d.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), d.count - offset, 0) }
                if n < 0 && errno == EINTR { continue }; guard n > 0 else { throw WispError("scrcpy input write failed") }; offset += n
            }
        }
    }
    deinit { close() }
}

// Bound native startup diagnostics in memory; never retain video or an output file.
final class ScrcpyServerOutput {
    private let lock=NSLock()
    private var tail=Data()
    static let capacity=8192
    func append(_ bytes:Data){lock.withLock{if bytes.count>=Self.capacity{tail=Data(bytes.suffix(Self.capacity))}else{let excess=max(0,tail.count+bytes.count-Self.capacity);if excess>0{tail.removeFirst(excess)};tail.append(bytes)}}}
    var count:Int{lock.withLock{tail.count}}
    func summary(serial:String)->String {
        let bytes=lock.withLock{tail}
        let text=String(String.UnicodeScalarView(String(decoding:bytes,as:UTF8.self).unicodeScalars.filter{$0.value>=32 || $0.value==10}))
            .replacingOccurrences(of:serial,with:"<device>")
            .replacingOccurrences(of:"/data/local/tmp/[^\\s]+",with:"<scrcpy helper>",options:.regularExpression)
        let lines=text.components(separatedBy:.newlines).map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty}
        return String(lines.suffix(4).joined(separator:"; ").suffix(1000))
    }
}

// One process/tunnel per selected device. Never launches the scrcpy desktop app,
// installs dependencies, changes clipboard/power, or uses an unscoped ADB call.
final class ScrcpySession: @unchecked Sendable {
    typealias Installation = () throws -> ScrcpyInstallation
    private let lock = NSLock(), inputLock = NSLock()
    private let worker = DispatchQueue(label: "Simwisp.scrcpy", qos: .userInitiated)
    private let geometryWorker = DispatchQueue(label: "Simwisp.scrcpy-geometry", qos: .userInitiated)
    private let network: DispatchQueue
    private let lifecycle: DispatchGroup
    private let run: (String, [String], Double) throws -> CommandResult
    private let installation: Installation
    private let adb: String, serial: String
    let video: Bool, controls: Bool
    let videoSize: ScrcpyVideoSize
    private let fps: Int, quality: Int
    private var physicalAndroid: Bool { !serial.hasPrefix("emulator-") }
    private var cancelled = false, stopping = false, ready = false, finished = false, everReady = false, installed = false
    private let work = DispatchGroup()
    private var failure: String?, buffer = ScrcpyFrames(), sockets: [ScrcpySocket] = []
    private var control: ScrcpySocket?, size = (0,0)
    private var physicalRevision: UInt64 = 0, physicalRefreshing = false
    private var physicalRefreshes = 0, physicalError: String?
    private var pressed: (Double, Double)?, gestureSize = (0,0), secondFinger = false
    private var noticePending = false, lastReset = -Double.infinity
    private var receivedFrames = 0, resetRequests = 0
    private var receivedBytes: UInt64 = 0, keyframeBytes: UInt64 = 0
    private var lastFrameAt: Double?
    var onChange: (() -> Void)?
    init(adb: String, serial: String, video: Bool, controls: Bool, fps: Int, quality: Int, videoSize: ScrcpyVideoSize = .headless, network: DispatchQueue, lifecycle: DispatchGroup, installation: @escaping Installation = ScrcpyInstallation.find, run: @escaping (String,[String],Double) throws -> CommandResult = { try command($0,$1,timeout:$2) }) {
        self.adb=adb;self.serial=serial;self.video=video;self.controls=controls;self.fps=fps;self.quality=quality;self.videoSize=videoSize;self.network=network;self.lifecycle=lifecycle;self.installation=installation;self.run=run
    }
    var state: (ready: Bool, error: String?, size: (Int,Int), finished: Bool, connected: Bool, installed: Bool) { lock.withLock { (ready && !stopping, finished ? failure : nil, size, finished, everReady, installed) } }
    var hasFrame: Bool { lock.withLock { buffer.count > 0 } }
    var diagnostics: [String: Any] { lock.withLock { ["source_frames": receivedFrames, "source_video_bytes": receivedBytes, "source_keyframe_bytes": keyframeBytes, "video_width": size.0, "video_height": size.1, "target_width": videoSize.width, "target_height": videoSize.height, "max_size": videoSize.maxSize, "target_bitrate_bps": videoSize.bitRate(quality: quality), "requested_qp_max": NSNull(), "requested_bitrate_mode": NSNull(), "format_shaping_disabled": NSNull(), "queued_frames": buffer.count, "dropped_frames": buffer.dropped, "reset_requests": resetRequests, "generation": buffer.generation, "last_frame_age_ms": lastFrameAt.map { max(0, (monotonic() - $0) * 1000) } as Any? ?? NSNull()] } }
    var inputDiagnostics: [String: Any] { lock.withLock {
        ["width": size.0, "height": size.1, "geometry_refreshes": physicalRefreshes,
         "geometry_refresh_pending": physicalRefreshing, "geometry_refresh_error": physicalError as Any? ?? NSNull()]
    } }
    private func notify() {
        let emit = lock.withLock { () -> Bool in if noticePending || cancelled { return false };noticePending=true;return true }
        if emit { network.async { [weak self] in guard let self else{return};self.lock.withLock{self.noticePending=false};if !self.lock.withLock({self.cancelled || self.stopping}){self.onChange?()} } }
    }
    private var isCancelled: Bool { lock.withLock { cancelled } }
    private func tool(_ args: [String], timeout: Double = 4) throws -> CommandResult {
        guard !lock.withLock({cancelled || stopping}), DeviceControl.validADBSerial(serial) else { throw WispError("Invalid or cancelled scrcpy session") }
        let r = try run(adb,["-s",serial]+args,timeout);guard r.status==0 else{throw WispError("scrcpy ADB operation failed")};return r
    }
    static func arguments(version: String, scid: String, jar: String, video: Bool, controls: Bool, fps: Int, quality: Int, videoSize: ScrcpyVideoSize = .headless, physical: Bool = false) -> [String] {
        let rate=videoSize.bitRate(quality:quality)
        if physical && video {
            // Samsung codec code can overflow on app_process argv >=255 bytes.
            // Pinned5.0.1 defaults retain video/control/H264/cleanup and all wire
            // metadata. Baseline excludes B-frames; never request stock High profile.
            // Retain explicit power/clipboard/audio protections. Native recovery
            // remains immediate; automatic GOP uses the pinned server default.
            return ["shell","CLASSPATH="+jar,"app_process","/","com.genymobile.scrcpy.Server",version,"scid="+scid,"tunnel_forward=true","audio=false","send_device_meta=false","clipboard_autosync=false","power_on=false","max_size=\(videoSize.maxSize)","max_fps=\(min(60,max(1,fps)))","video_bit_rate=\(rate)","log_level=warn","video_codec_options=profile=1"]
        }
        // Video uses the same Baseline/default-GOP/QP/rate-control policy as phones.
        // Preserve unused video options in existing control-only launches; no encoder runs.
        let codecOptions=video ? "profile=1" : "profile=1,max-bframes=0,i-frame-interval=1"
        // Keep control enabled internally for RESET_VIDEO even with Current input.
        return ["shell","CLASSPATH="+jar,"app_process","/","com.genymobile.scrcpy.Server",version,"scid="+scid,"tunnel_forward=true","audio=false","video=\(video)","control=true","send_device_meta=false","send_dummy_byte=true","send_stream_meta=true","send_frame_meta=true","clipboard_autosync=false","power_on=false","cleanup=true","video_codec=h264","video_codec_options="+codecOptions,"max_size=\(videoSize.maxSize)","max_fps=\(min(60,max(1,fps)))","video_bit_rate=\(rate)","log_level=warn"]
    }
    func start() {
        lifecycle.enter(); work.enter()
        worker.async { [self] in
            var forward: String?, jar: String?, process: Process?, pipe: Pipe?
            let drain=DispatchGroup(), outputDrain=DispatchGroup(), serverOutput=ScrcpyServerOutput()
            defer {
                let owned = lock.withLock { () -> [ScrcpySocket] in ready=false;return sockets }
                owned.forEach{$0.interrupt()};drain.wait();owned.forEach{$0.close()}
                if let process, process.isRunning { process.terminate(); let end=monotonic()+0.5;while process.isRunning && monotonic()<end{Thread.sleep(forTimeInterval:0.02)};if process.isRunning{Darwin.kill(process.processIdentifier,SIGKILL)};process.waitUntilExit() }
                try? pipe?.fileHandleForWriting.close()
                outputDrain.wait()
                try? pipe?.fileHandleForReading.close()
                let detail=serverOutput.summary(serial:serial)
                lock.withLock { if let error=failure,!detail.isEmpty{failure=error+": "+detail};finished=true }
                // Only this session's port/file; never remove-all or kill-server.
                if let forward { _ = try? run(adb,["-s",serial,"forward","--remove",forward],2) }
                if let jar { _ = try? run(adb,["-s",serial,"shell","rm","-f",jar],2) }
                notify();lifecycle.leave();work.leave()
            }
            do {
                guard DeviceControl.validADBSerial(serial) else{throw WispError("Invalid Android serial")}
                guard video || controls else{throw WispError("No scrcpy demand")}
                let install=try installation();guard install.version==ScrcpyWire.version else{throw WispError("Unsupported scrcpy protocol")};lock.withLock{installed=true}
                // Do not read/write device-wide codec shaping properties. An older
                // build's override is not silently reset; restoring it is owner-controlled.
                let scid=String(format:"%08x",UInt32.random(in:1...0x7fff_ffff)),remote="/data/local/tmp/simwisp-scrcpy-"+scid+".jar"
                let options=Self.arguments(version:install.version,scid:scid,jar:remote,video:video,controls:controls,fps:fps,quality:quality,videoSize:videoSize,physical:physicalAndroid)
                if physicalAndroid && video && options.dropFirst(2).joined(separator:" ").utf8.count>=255 { throw WispError("Phone scrcpy launch exceeds Samsung command-length safety budget") }
                jar=remote;_ = try tool(["push",install.server,remote],timeout:8)
                let f=try tool(["forward","tcp:0","localabstract:scrcpy_"+scid]).text.trimmingCharacters(in:.whitespacesAndNewlines)
                guard let port=UInt16(f),port>0 else{throw WispError("Invalid scrcpy forward port")};forward="tcp:"+f
                if !video { try refreshPhysicalSize() }
                let p=Process(),output=Pipe();p.executableURL=URL(fileURLWithPath:adb);p.arguments=["-s",serial]+options;p.standardInput=FileHandle.nullDevice;p.standardOutput=output;p.standardError=output
                pipe=output;process=p;try p.run()
                try? output.fileHandleForWriting.close()
                outputDrain.enter()
                DispatchQueue.global(qos:.utility).async {
                    defer{outputDrain.leave()}
                    while true{let bytes=output.fileHandleForReading.availableData;if bytes.isEmpty{break};serverOutput.append(bytes)}
                }
                let deadline=monotonic()+8
                func connect(first: Bool) throws -> ScrcpySocket {
                    while !isCancelled && monotonic()<deadline && p.isRunning {
                        if let s=try? ScrcpySocket(port:port) {
                            lock.withLock{sockets.append(s)}
                            do { if first { let b=try s.read(1,cancelled:{self.isCancelled},deadline:deadline);guard b==Data([0]) else{throw WispError("Invalid scrcpy handshake")} };return s } catch { s.close() }
                        }
                        Thread.sleep(forTimeInterval:0.05)
                    }
                    throw WispError("scrcpy server did not become ready")
                }
                let v = video ? try connect(first:true) : nil
                let c = try connect(first:!video);lock.withLock{control=c;ready=true;everReady=true};notify()
                // No unsolicited clipboard traffic; disconnects still terminate the session.
                drain.enter();work.enter();lifecycle.enter();DispatchQueue.global(qos:.utility).async{[self] in defer{drain.leave();work.leave();lifecycle.leave()};do{while !isCancelled{_ = try c.read(1,cancelled:{self.isCancelled})}}catch{if !isCancelled{lock.withLock{if failure==nil{failure="scrcpy control disconnected"}};lock.withLock{sockets}.forEach{$0.interrupt()}}}}
                if let v {
                    let codec=try v.read(4,cancelled:{self.isCancelled},deadline:deadline);guard codec==Data("h264".utf8) else{throw WispError("scrcpy did not provide H.264")}
                    try readVideo(v)
                } else { while !isCancelled && p.isRunning && lock.withLock({failure==nil}){Thread.sleep(forTimeInterval:0.05)} }
                c.interrupt();_ = drain.wait(timeout:.now()+1)
                if !isCancelled { throw WispError("scrcpy server stopped unexpectedly") }
            }catch{if !isCancelled{lock.withLock{failure=error.localizedDescription}}}
        }
    }
    private func readVideo(_ socket: ScrcpySocket) throws {
        var config=Data(),sps=Data(),pps=Data(),timestamp:UInt64=0
        while !isCancelled {
            let h=try ScrcpyWire.header(socket.read(12,cancelled:{self.isCancelled}))
            switch h {
            case .session(let w,let h):
                // Release with the NEW coordinate space; old-sized events are rejected by Android after rotation.
                inputLock.withLock { gestureSize=(w,h);releasePointers(width:w,height:h) }
                lock.withLock{size=(w,h);buffer.reset()};config=Data();sps=Data();pps=Data();notify()
            case .packet(let length,let pts,let isConfig,let isKey):
                let raw=try socket.read(length,cancelled:{self.isCancelled},deadline:monotonic()+3),nals=try ScrcpyWire.nals(raw)
                var changed = false
                for n in nals { if n[0]&31==7 && n != sps { sps=n;changed=true };if n[0]&31==8 && n != pps { pps=n;changed=true } }
                if changed && !sps.isEmpty && !pps.isEmpty {
                    let next = try ScrcpyWire.configuration(sps,pps)
                    if !config.isEmpty && config != next { lock.withLock { buffer.reset() } }
                    config=next
                }
                if isConfig{continue}
                let dimensions=lock.withLock{size};guard !config.isEmpty,dimensions.0>0 else{throw WispError("scrcpy video configuration is incomplete")}
                timestamp=max(timestamp+1,pts)
                let key=isKey || nals.contains{$0[0]&31==5}
                let media=nals.filter{($0[0]&31) != 7 && ($0[0]&31) != 8}
                guard media.contains(where:{(1...5).contains($0[0]&31)}) else{continue}
                // Keep in-band original SPS from overriding the zero-reorder avcC.
                let f=H264Frame(payload:ScrcpyWire.avcc(media),description:config,codec:"avc1."+config[1...3].map{String(format:"%02X",$0)}.joined(),keyframe:key,timestamp:timestamp,width:dimensions.0,height:dimensions.1,codedWidth:(dimensions.0+1) & ~1,codedHeight:(dimensions.1+1) & ~1)
                let accepted=lock.withLock{receivedFrames += 1;receivedBytes += UInt64(f.payload.count);if key { keyframeBytes += UInt64(f.payload.count) };lastFrameAt=monotonic();return buffer.append(f)};if !accepted{requestKeyframe()};notify()
            }
        }
    }
    func takeVideoFrame() -> (frame: H264Frame, generation: UInt64)? { lock.withLock { guard let frame=buffer.take() else { return nil };return (frame,buffer.generation) } }
    func takeFrame() -> H264Frame? { takeVideoFrame()?.frame }
    func requestKeyframe() {
        let c=lock.withLock{() -> ScrcpySocket? in guard video,!cancelled,monotonic()-lastReset>0.5 else{return nil};lastReset=monotonic();buffer.reset();resetRequests += 1;return control}
        if let c { try? c.send(Data([17])) }
    }
    private func readPhysicalSize() throws -> (Int, Int) {
        lock.withLock { physicalRefreshes += 1 }
        return try ScrcpyWire.displaySize(tool(["shell","dumpsys","display"]).text)
    }
    // Initial lookup is on the startup worker, before input becomes ready.
    private func refreshPhysicalSize() throws {
        let dimensions = try readPhysicalSize()
        lock.withLock { size = dimensions; physicalError = nil }
    }
    // No TTL and no gesture-time tool calls. Debounce/coalesce explicit changes
    // on a separate worker; never hold inputLock while querying or publishing.
    func invalidatePhysicalSize() {
        let begin = lock.withLock { () -> Bool in
            guard !video, controls, ready, !cancelled, !stopping, !finished else { return false }
            physicalRevision &+= 1
            guard !physicalRefreshing else { return false }
            physicalRefreshing = true; work.enter(); lifecycle.enter(); return true
        }
        if begin { geometryWorker.asyncAfter(deadline: .now() + 0.15) { [self] in
            defer { lifecycle.leave(); work.leave() }
            while true {
                let revision = lock.withLock { () -> UInt64? in
                    guard !cancelled, !stopping, !finished else { physicalRefreshing = false; return nil }
                    return physicalRevision
                }
                guard let revision else { return }
                let result = Result { try readPhysicalSize() }
                let again = lock.withLock { () -> Bool in
                    guard !cancelled, !stopping, !finished else { physicalRefreshing = false; return false }
                    // A newer rotation/resolution notification supersedes this result.
                    guard revision == physicalRevision else { return true }
                    switch result {
                    case .success(let dimensions): size = dimensions; physicalError = nil
                    case .failure(let error): physicalError = error.localizedDescription
                    }
                    physicalRefreshing = false; return false
                }
                if !again { notify(); return }
                Thread.sleep(forTimeInterval: 0.15)
            }
        } }
    }
    func perform(_ m:[String:Any]) throws -> Bool {
        try inputLock.withLock {
            guard controls else{throw WispError("scrcpy input is not selected")}
            guard let type=m["type"] as? String else{return true}
            // Appearance retains its existing serial-scoped command. Everything
            // else in this allowlist uses only the persistent control socket.
            guard ["touch_down","touch_move","touch_up","tap","drag","accessibility_swipe","key","text","home","back","menu","app_switcher","rotate"].contains(type) else{return false}
            guard type != "rotate" || DeviceControl.validID(serial,platform:"android") else{throw WispError("Rotate the physical device itself")}
            guard let c=lock.withLock({!cancelled && !stopping && ready && failure==nil ? control:nil}) else{throw WispError("scrcpy input is not ready")}
            func n(_ key:String)->Double{clamp((m[key] as? NSNumber)?.doubleValue ?? 0)}
            func touch(_ action:UInt8,_ x:Double,_ y:Double,_ second:Bool=false)throws {
                let otherX = x <= 0.94 ? x+0.05 : x-0.05
                try c.send(ScrcpyWire.touch(action:action,pointer:second ? UInt64.max-2:UInt64.max-1,x:second ? otherX:x,y:y,width:gestureSize.0,height:gestureSize.1))
            }
            func up()throws {
                if let p=pressed {defer{pressed=nil;secondFinger=false};if secondFinger{try touch(1,p.0,p.1,true)};try touch(1,p.0,p.1)}
            }
            switch type {
            case "touch_down","tap","drag","accessibility_swipe":
                // One validated snapshot for DOWN, every MOVE, both fingers, and UP.
                try up();gestureSize=lock.withLock{size}
                let x=n(type=="touch_down" || type=="tap" ? "x":"x1"),y=n(type=="touch_down" || type=="tap" ? "y":"y1");try touch(0,x,y);pressed=(x,y)
                if type=="accessibility_swipe"{secondFinger=true;do{try touch(0,x,y,true)}catch{try? up();throw error}}
                if type=="tap"{try up()}
                else if type != "touch_down" {
                    do{let end=(n("x2"),n("y2"));for i in 1...12{guard !lock.withLock({cancelled || stopping}) else{throw WispError("Gesture cancelled")};let t=Double(i)/12,p=(x+(end.0-x)*t,y+(end.1-y)*t);try touch(2,p.0,p.1);if secondFinger{try touch(2,p.0,p.1,true)};pressed=p;Thread.sleep(forTimeInterval:0.025)};try up()}catch{try? up();throw error}
                }
            case "touch_move":if pressed != nil{try touch(2,n("x"),n("y"));pressed=(n("x"),n("y"))}
            case "touch_up":if pressed != nil{pressed=(n("x"),n("y"));try up()}
            case "rotate":try up();try c.send(Data([11]));invalidatePhysicalSize()
            case "text":
                let text=m["text"] as? String ?? "";guard text.utf8.count<=16_384 else{throw WispError("Text is too long")};var part=""
                for ch in text { if part.utf8.count+String(ch).utf8.count>300{try c.send(ScrcpyWire.text(part));part=""};guard String(ch).utf8.count<=300 else{throw WispError("Text grapheme is too long")};part.append(ch) };if !part.isEmpty{try c.send(ScrcpyWire.text(part))}
            default:
                let map:[String:UInt32]=["home":3,"back":4,"menu":82,"app_switcher":187,"return":66,"enter":66,"delete":67,"backspace":67,"escape":111,"space":62,"tab":61,"arrowleft":21,"arrowright":22,"arrowup":19,"arrowdown":20]
                let name=type=="key" ? (m["key"] as? String ?? "").lowercased():type
                if let key=map[name]{try c.send(ScrcpyWire.key(key,down:true));try c.send(ScrcpyWire.key(key,down:false))}
            }
            return true
        }
    }
    func cancelGesture() { inputLock.withLock { releasePointers(width:gestureSize.0,height:gestureSize.1) } }
    // Caller holds inputLock. Always release both IDs, including rotation/close.
    private func releasePointers(width:Int,height:Int) {
        if let p=pressed,let c=lock.withLock({control}) {
            if secondFinger{try? c.send(ScrcpyWire.touch(action:1,pointer:UInt64.max-2,x:p.0 <= 0.94 ? p.0+0.05:p.0-0.05,y:p.1,width:width,height:height))}
            try? c.send(ScrcpyWire.touch(action:1,x:p.0,y:p.1,width:width,height:height))
        }
        pressed=nil;secondFinger=false
    }
    func stop(completion: @escaping () -> Void = {}) {
        let begin=lock.withLock{() -> Bool in if stopping{return false};stopping=true;return true}
        if begin {
            // Never wait for input/tool calls on the network queue. Release the
            // gesture before interrupting readers, then join both owned workers.
            DispatchQueue.global(qos:.userInitiated).async { [self] in
                cancelGesture();lock.withLock{cancelled=true};lock.withLock{sockets}.forEach{$0.interrupt()}
            }
        }
        work.notify(queue:network,execute:completion)
    }
}
