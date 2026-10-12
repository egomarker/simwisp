import Foundation
import AppKit
import Darwin
import CoreImage

let root = CommandLine.arguments[1]
let source = FileManager.default.currentDirectoryPath
let fakeADB = root + "/fake-adb.sh"
let env = ProcessInfo.processInfo.environment
let realADB = [env["ANDROID_HOME"] ?? "", env["ANDROID_SDK_ROOT"] ?? "", NSHomeDirectory()+"/Library/Android/sdk", NSHomeDirectory()+"/.androidsdk"].filter { !$0.isEmpty }.map { $0+"/platform-tools/adb" }.first { FileManager.default.isExecutableFile(atPath:$0) }
let server = HTTPServer(), lifecycle = DispatchGroup()
var useRealADB = false, terminalEnabled = false
// Synthetic protocol only: no host shell or PTY is created by this fixture.
var terminalClients: [UUID: ClientConnection] = [:]
var terminalStarts = 0, terminalACKs = 0
var registry: [String: FixtureStream] = [:]
let sampleID = "eventId=type:EVENT_TYPE_ACCESSIBILITY subtype:TYPE_VIEW_ACCESSIBILITY_FOCUSED displayId:0 time:123"
let sampleFocus = "10-11 11:11:00.123 V/talkback: \(sampleID) interpretation=AccessibilityFocused{ eventSourceNode=contentDescription: ADHD. Attention-Deficit/Hyperactivity Disorder; text: null; tooltipText: Opens this decision support tool; packageName: guidelines.childrensmercy.com.iguidelines; className: android.widget.Button; boundsInScreen: Rect(37, 451 - 1043, 819); selected: false; checked: false; checkable: false; enabled: true; clickable: true; longClickable: false; focusable: true; focused: false; scrollable: false; visible: true; importantForAccessibility: true; password: false; [ACTION_FOCUS, ACTION_SELECT, ACTION_CLEAR_SELECTION, ACTION_CLICK, ACTION_CLEAR_ACCESSIBILITY_FOCUS, ACTION_NEXT_AT_MOVEMENT_GRANULARITY, ACTION_PREVIOUS_AT_MOVEMENT_GRANULARITY, ACTION_SET_SELECTION, ACTION_SHOW_ON_SCREEN]"
let sampleRole = "V/talkback: TreeNodesDescription \(sampleID) role=ROLE_BUTTON"
let sampleSpeech = "V/talkback: Pipeline( \(sampleID) action=SPEAK text=\"ADHD. Attention-Deficit/Hyperactivity Disorder, Button, Opens this decision support tool\""
func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of:"'",with:"'\\''") + "'" }
try Data(("#!/bin/sh\nprintf '%s\\n' \(quote(sampleFocus)) \(quote(sampleRole)) \(quote(sampleSpeech))\nexec /bin/sleep 300\n").utf8).write(to:URL(fileURLWithPath:fakeADB))
try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:fakeADB)
let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:405,pixelsHigh:900,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep)
NSColor.white.setFill(); NSRect(x:0,y:0,width:405,height:900).fill()
func text(_ s: String,_ x: CGFloat,_ y: CGFloat,_ size: CGFloat, _ color: NSColor = .darkGray) { (s as NSString).draw(at:NSPoint(x:x,y:y),withAttributes:[.font:NSFont.systemFont(ofSize:size),.foregroundColor:color]) }
text("11:45                   SAMPLE ANDROID",18,869,11)
text("CHILDREN’S MERCY",25,818,12,NSColor.systemBlue)
text("PedsGuide",25,765,36)
text("Clinical decision support",25,731,14)
NSColor(white:0.95,alpha:1).setFill(); NSBezierPath(roundedRect:NSRect(x:22,y:655,width:361,height:47),xRadius:8,yRadius:8).fill()
text("Find a tool",35,670,14,.gray); text("DECISION SUPPORT TOOLS",25,620,12,.gray)
NSColor.systemBlue.setStroke(); let outline = NSBezierPath(roundedRect:NSRect(x:18,y:430,width:369,height:165),xRadius:8,yRadius:8);outline.lineWidth=3;outline.stroke()
text("ADHD",35,542,24);text("Attention-Deficit/",35,503,17);text("Hyperactivity Disorder",35,478,17);text("Opens this decision support tool",35,450,12,.gray)
text("Asthma",35,340,24);text("Assessment and management",35,303,15,.gray)
text("Dehydration",35,215,24);text("Evaluation and treatment",35,178,15,.gray)
text("HOME          FAVORITES          ABOUT",45,67,12,.gray);text("◁               ◯               □",107,20,18,.gray)
NSGraphicsContext.restoreGraphicsState()

// A separate, explicitly synthetic iOS preview keeps toolbar screenshots honest.
let iosRep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:414,pixelsHigh:896,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:iosRep)
NSColor(white:0.97,alpha:1).setFill(); NSRect(x:0,y:0,width:414,height:896).fill()
text("11:45                       SYNTHETIC iOS",24,855,11)
text("iPhone 11",28,785,32); text("Simulator controls preview",28,751,15,.gray)
for (index,label) in ["Shake simulator", "Rotate screen", "Change appearance"].enumerated() {
    let y = CGFloat(590-index*100)
    NSColor.white.setFill(); NSBezierPath(roundedRect:NSRect(x:24,y:y,width:366,height:78),xRadius:12,yRadius:12).fill()
    text(label,44,y+32,19)
}
text("Home · Shake · App switcher below",28,224,17)
text("Test image — not a live device capture",28,194,12,.gray)
NSColor.darkGray.setFill(); NSBezierPath(roundedRect:NSRect(x:142,y:14,width:130,height:5),xRadius:2.5,yRadius:2.5).fill()
NSGraphicsContext.restoreGraphicsState()

func vectors(_ rep: NSBitmapImageRep) throws -> [H264Frame] {
    let encoder = try H264Encoder(width: rep.pixelsWide, height: rep.pixelsHigh)
    defer { encoder.close() }
    let image = CIImage(cgImage: rep.cgImage!)
    return try (0..<60).map { try encoder.encode(image, quality: 70, fps: 60, forceKeyframe: $0 == 0) }
}
let androidVideo = try vectors(rep), iosVideo = try vectors(iosRep)
final class FixtureStream {
    let id: String, client: ClientConnection, monitor: AccessibilitySession
    var timer: DispatchSourceTimer?, frames = 0, inputs = 0, paused = false, sending = false, ready = false, closed = false
    var flow = StreamFlow(fps: 60, quality: 70), feedbacks = 0
    var epoch: UInt32 = 1, cursor = 0
    var lastInputs: [[String:Any]] = []
    init(id: String, client: ClientConnection) {
        self.id=id;self.client=client
        monitor=AccessibilitySession(serial:id,platform:id.hasPrefix("emulator-") ? "android" : "ios",executable:useRealADB ? realADB : fakeADB,queue:server.queue,lifecycle:lifecycle) { [weak client] value, done in client?.sendJSON(value,completion:done) }
        client.onMessage={ [weak self] value in self?.message(dictionary(Data(value.utf8))) }
        client.onClose={ [weak self] in self?.stop() }
        client.sendJSON(["type":"input_capabilities","live_touch":true,"video_flow":"paced-v1"]);client.sendJSON(["type":"rotated","landscape":false])
        let t=DispatchSource.makeTimerSource(queue:server.queue);t.schedule(deadline:.now());t.setEventHandler { [weak self] in
            guard let self,!self.closed else{return}
            defer {self.reschedule()}
            if self.ready && !self.paused && self.flow.unresponsive(now:monotonic()) {self.client.close();return}
            guard self.ready,!self.paused,!self.sending,self.flow.beginFrame(now:monotonic()) else{return}
            let values = self.id.hasPrefix("emulator-") ? androidVideo : iosVideo
            let source = values[self.cursor]
            let frame = H264Frame(payload: source.payload, description: source.description, codec: source.codec, keyframe: source.keyframe, timestamp: UInt64(self.frames+1)*16667, width: source.width, height: source.height, codedWidth: source.codedWidth, codedHeight: source.codedHeight)
            guard self.flow.canSend(bytes:frame.payload.count+24) else {self.flow.deferSend(bytes:frame.payload.count+24,now:monotonic());self.resetVideo();return}
            self.cursor = (self.cursor+1)%values.count
            self.sending=true;self.frames+=1
            _ = self.flow.recordSend(epoch:self.epoch,id:UInt32(self.frames),bytes:frame.payload.count+24,now:monotonic())
            if frame.keyframe {self.client.sendJSON(frame.configuration(epoch:self.epoch))}
            self.client.sendBinary(frame.packet(epoch:self.epoch,id:UInt32(self.frames))) { [weak self] in
                guard let self,!self.closed else{return};self.sending=false;self.reschedule()
            }
        };t.resume();timer=t
    }
    func reschedule() {
        guard !closed else{return}
        let now=monotonic(),deadline=ready && !paused && !sending && flow.hasCapacity ? min(now+0.25,max(now,flow.nextFrame)) : now+0.25
        timer?.schedule(deadline:.now()+max(0.0001,deadline-now),leeway:.microseconds(100))
    }
    func resetVideo() {epoch &+= 1;cursor=0}
    func message(_ m: [String:Any]) {
        guard !closed else{return};defer {reschedule()}
        let type=m["type"] as? String
        if type == "video_ready" {ready=m["flow"] as? String == "paced-v1"}
        else if type == "video_keyframe" {
            if let e=m["epoch"] as? NSNumber,e.doubleValue != Double(epoch) {return}
            if m["overloaded"] as? Bool == true {flow.congested(now:monotonic())}
            resetVideo()
        } else if type == "video_feedback" {
            if let feedback=StreamFeedback(m),flow.feedback(feedback,currentEpoch:epoch,now:monotonic()) {feedbacks+=1}
        } else if type == "settings" {
            if let p=m["stream_paused"] as? Bool,p != paused {paused=p;resetVideo()}
            monitor.update(paneOpen:m["accessibility_enabled"] as? Bool,streamActive:!paused,subscription:m["accessibility_subscription"] as? Int)
        } else {inputs+=1;lastInputs.append(m);if lastInputs.count>16 {lastInputs.removeFirst()}}
    }
    func stop() {guard !closed else{return};closed=true;monitor.stop();timer?.cancel();timer=nil;if registry[id] === self {registry.removeValue(forKey:id)}}
    var snapshot: [String:Any] {["id":id,"frames":frames,"inputs":inputs,"last_inputs":lastInputs,"paused":paused,"codec":"h264","epoch":epoch,"feedbacks":feedbacks,"unreceived_frames":flow.count,"unreceived_bytes":flow.bytes,"accessibility":monitor.snapshot]}
}
let sims:[[String:Any]] = [["id":"emulator-5554","name":"Pixel 6 API 36","platform":"android","width":405,"height":900], ["id":"ios-fixture","name":"iPhone 11","platform":"ios","width":414,"height":896], ["id":"emulator-5556","name":"Pixel second emulator","platform":"android","width":405,"height":900]]
server.authorize={ request in request.headers["cookie"]?.contains("fixture=paired") == true }
server.upgrade={ request, client in
    if request.path == "/ws/pty" {
        guard terminalEnabled else {client.sendJSON(["type":"terminal_error","message":"Fixture terminals disabled"]);client.closeAfterSending();return}
        let id=client.id;terminalClients[id]=client;terminalStarts+=1
        client.onClose={terminalClients.removeValue(forKey:id)}
        client.onMessage={ [weak client] value in
            let m=dictionary(Data(value.utf8))
            if m["type"] as? String == "close" {client?.close()}
            else if m["type"] as? String == "output_ack" {terminalACKs+=1}
        }
        client.sendJSON(["type":"session","id":"fixture-terminal-\(terminalStarts)"])
        client.sendBinary(Data("Fixture terminal output\r\n".utf8));return
    }
    let id=String(request.path.dropFirst(4))
    // Match production post-upgrade asynchronous discovery/binding.
    server.queue.asyncAfter(deadline:.now()+0.15) {
        guard !client.isClosed else{return}
        if let old=registry[id] {old.stop();old.client.close()}
        registry[id]=FixtureStream(id:id,client:client)
    }
}
server.route={ request, complete in
    if request.path == "/api/pair" {var r=HTTPResponse.json(["ok":true]);r.headers["Set-Cookie"]="fixture=paired; Path=/; Secure; HttpOnly; SameSite=Strict";complete(r);return}
    if request.path == "/api/pair/options" {complete(.json(["totp":false]));return}
    if request.path == "/api/info" {complete(.json(["app":"Simwisp","version":"fixture","has_adb":true,"mode":"fast2 (Native H.264 test fixture)","video_codec":"h264","permissions":["screen_recording":true,"accessibility":true],"features":["terminal":terminalEnabled]]));return}
    if request.path == "/api/sims" {complete(.json(sims));return}
    if request.path == "/api/devices" {complete(.json([]));return}
    if request.path == "/fixture/status" {complete(.json(["sessions":registry.values.map(\.snapshot),"real_adb":useRealADB,"terminal":["active":terminalClients.count,"starts":terminalStarts,"output_acks":terminalACKs]]));return}
    if request.path == "/fixture/mode", request.method == "POST" {
        guard registry.isEmpty, terminalClients.isEmpty else {complete(.json(["error":"Close fixture streams first"],status:409));return}
        let mode=dictionary(request.body)
        if let real=mode["real"] as? Bool {useRealADB=real}
        if let terminal=mode["terminal"] as? Bool {terminalEnabled=terminal}
        complete(.json(["ok":true]));return
    }
    if request.path == "/" || request.path.hasPrefix("/css/") || request.path.hasPrefix("/js/") {
        let file=request.path == "/" ? "index.html" : String(request.path.dropFirst())
        guard !file.contains(".."),let data=try? Data(contentsOf:URL(fileURLWithPath:source+"/Resources/Web/"+file))else{complete(.json(["error":"Not found"],status:404));return}
        complete(HTTPResponse(body:data,type:file.hasSuffix("html") ? "text/html" : file.hasSuffix("css") ? "text/css" : "text/javascript"));return
    }
    complete(.json(["error":"No fixture route"],status:404))
}
let tls = try TLSIdentity(directory: URL(fileURLWithPath: root + "/tls"), addresses: [], hostname: "localhost")
server.stateChanged = { state in
    if state == "Running" { print("Isolated accessibility fixture ready on https://127.0.0.1:45151"); fflush(stdout) }
    else { log(state); exit(1) }
}
try server.start(port:45151,lan:false,tls:tls)
let signal=DispatchSource.makeSignalSource(signal:SIGTERM,queue:.main);Darwin.signal(SIGTERM,SIG_IGN);signal.setEventHandler{server.stop {lifecycle.notify(queue:.main){exit(0)}}};signal.resume()
dispatchMain()
