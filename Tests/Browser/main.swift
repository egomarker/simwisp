import Foundation
import AppKit
import Darwin

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
let jpeg = rep.representation(using:.jpeg,properties:[.compressionFactor:0.7])!
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
let iosJPEG = iosRep.representation(using:.jpeg,properties:[.compressionFactor:0.7])!
final class FixtureStream {
    let id: String, client: ClientConnection, monitor: AccessibilitySession
    var timer: DispatchSourceTimer?, frames = 0, inputs = 0, paused = false, pendingFrame = false
    var lastInputs: [[String:Any]] = []
    init(id: String, client: ClientConnection) {
        self.id=id;self.client=client
        monitor=AccessibilitySession(serial:id,platform:id.hasPrefix("emulator-") ? "android" : "ios",executable:useRealADB ? realADB : fakeADB,queue:server.queue,lifecycle:lifecycle) { [weak client] value, done in client?.sendJSON(value,completion:done) }
        client.onMessage={ [weak self] value in self?.message(dictionary(Data(value.utf8))) }
        client.onClose={ [weak self] in self?.stop() }
        client.sendJSON(["type":"input_capabilities","live_touch":true]);client.sendJSON(["type":"rotated","landscape":false])
        let t=DispatchSource.makeTimerSource(queue:server.queue);t.schedule(deadline:.now(),repeating:1.0/60);t.setEventHandler { [weak self] in
            guard let self,!self.paused,!self.pendingFrame else{return};self.pendingFrame=true;self.frames+=1;self.client.sendBinary(self.id.hasPrefix("emulator-") ? jpeg : iosJPEG)
        };t.resume();timer=t
    }
    func message(_ m: [String:Any]) {
        if m["type"] as? String == "frame_ack" { pendingFrame=false }
        else if m["type"] as? String == "settings" {
            if let p=m["stream_paused"] as? Bool {paused=p}
            monitor.update(paneOpen:m["accessibility_enabled"] as? Bool,streamActive:!paused,subscription:m["accessibility_subscription"] as? Int)
        } else {inputs+=1;lastInputs.append(m);if lastInputs.count>16 {lastInputs.removeFirst()}}
    }
    func stop() {monitor.stop();timer?.cancel();timer=nil;if registry[id] === self {registry.removeValue(forKey:id)}}
    var snapshot: [String:Any] {["id":id,"frames":frames,"inputs":inputs,"last_inputs":lastInputs,"paused":paused,"accessibility":monitor.snapshot]}
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
    let id=String(request.path.dropFirst(4));if let old=registry[id] {old.stop();old.client.close()};registry[id]=FixtureStream(id:id,client:client)
}
server.route={ request, complete in
    if request.path == "/api/pair" {var r=HTTPResponse.json(["ok":true]);r.headers["Set-Cookie"]="fixture=paired; Path=/; HttpOnly; SameSite=Strict";complete(r);return}
    if request.path == "/api/pair/options" {complete(.json(["totp":false]));return}
    if request.path == "/api/info" {complete(.json(["app":"Simwisp","version":"fixture","has_adb":true,"mode":"fast2 (Native test fixture)","permissions":["screen_recording":true,"accessibility":true],"features":["terminal":terminalEnabled]]));return}
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
try server.start(port:45151,lan:false)
let signal=DispatchSource.makeSignalSource(signal:SIGTERM,queue:.main);Darwin.signal(SIGTERM,SIG_IGN);signal.setEventHandler{server.stop {lifecycle.notify(queue:.main){exit(0)}}};signal.resume()
print("Isolated accessibility fixture ready on 127.0.0.1:45151");fflush(stdout)
dispatchMain()
