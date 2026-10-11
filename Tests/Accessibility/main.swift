import Foundation
import Darwin

var checks: [[String: Any]] = []
func check(_ name: String, _ pass: @autoclosure () -> Bool) {
    let ok = pass(); checks.append(["name": name, "passed": ok]); if !ok { fputs("FAIL: \(name)\n", stderr) }
}
let id = "eventId=type:EVENT_TYPE_ACCESSIBILITY subtype:TYPE_VIEW_ACCESSIBILITY_FOCUSED displayId:0 time:123"
let otherID = id.replacingOccurrences(of: "time:123", with: "time:124")
let speech = "ADHD. Attention-Deficit/Hyperactivity Disorder, Button, Opens this decision support tool"
let focus = "10-11 11:11:00.123 V/talkback: \(id) interpretation=AccessibilityFocused{ eventSourceNode=contentDescription: ADHD. Attention-Deficit/Hyperactivity Disorder; text: null; tooltipText: Opens this decision support tool; packageName: guidelines.childrensmercy.com.iguidelines; className: android.widget.Button; boundsInScreen: Rect(37, 451 - 1043, 819); selected: false; checked: false; checkable: false; enabled: true; clickable: true; longClickable: false; focusable: true; focused: false; scrollable: false; visible: true; importantForAccessibility: true; password: false; [ACTION_FOCUS, ACTION_SELECT, ACTION_CLEAR_SELECTION, ACTION_CLICK, ACTION_CLEAR_ACCESSIBILITY_FOCUS, ACTION_NEXT_AT_MOVEMENT_GRANULARITY, ACTION_PREVIOUS_AT_MOVEMENT_GRANULARITY, ACTION_SET_SELECTION, ACTION_SHOW_ON_SCREEN]"
let speak = "10-11 11:11:00.140 V/talkback: Pipeline( \(id) action=SPEAK text=\"\(speech)\""
var time = 1.0
let parser = TalkBackParser(clock: { time })
let first = parser.consume(focus)!
check("Focus label and tooltip", first["label"] as? String == "ADHD. Attention-Deficit/Hyperactivity Disorder" && first["tooltip"] as? String == "Opens this decision support tool")
check("Package/class", first["package"] as? String == "guidelines.childrensmercy.com.iguidelines" && first["class"] as? String == "android.widget.Button")
check("No Center field anywhere in bounds", (first["bounds"] as? [String: Int]) == ["left":37,"top":451,"right":1043,"bottom":819,"width":1006,"height":368])
check("12 properties", (first["properties"] as? [String:String])?.count == 12)
check("Nine actions", (first["actions"] as? [String])?.count == 9)
check("Initial speech absent, never substitute label", first["speech"] is NSNull && first["speech_source"] as? String == "none")
check("Wrong event speech ignored", parser.consume(speak.replacingOccurrences(of:id,with:otherID)) == nil)
let spoken = parser.consume(speak)!
check("Exact action=SPEAK preferred", spoken["speech"] as? String == speech && spoken["speech_source"] as? String == "speak")
check("Unchanged speech not resent", parser.consume(speak) == nil)
let role = parser.consume("V/talkback: TreeNodesDescription \(id) role=ROLE_BUTTON")
check("Correlated role", role?["role"] as? String == "ROLE_BUTTON")
check("Uncorrelated role ignored", parser.consume("V/talkback: TreeNodesDescription \(otherID) role=ROLE_CHECKBOX") == nil)
let tts = "V/talkback: TalkBackFeedbackProvider \(id) ttsOutput=ADHD composed queueMode=1"
check("Fallback cannot overwrite exact speech", parser.consume(tts) == nil)
_ = parser.consume(focus)
check("Fallback labeled", parser.consume(tts)?["speech_source"] as? String == "composed")
check("Exact replaces fallback", parser.consume(speak)?["speech_source"] as? String == "speak")
_ = parser.consume(focus); time = 5
check("Stale event does not attach speech", parser.consume(speak) == nil)
time = 1
_ = parser.consume(focus)
check("Unrelated tag ignored", parser.consume(speak.replacingOccurrences(of:"V/talkback:",with:"V/other:")) == nil)
check("No partial malformed focus", parser.consume("V/talkback: interpretation=AccessibilityFocused{ eventSourceNode=null") == nil && parser.consume(speak) == nil)
check("No missing event speech association", parser.consume(focus.replacingOccurrences(of:id,with:"")) != nil && parser.consume(speak) == nil)
_ = parser.consume(focus.replacingOccurrences(of:"password: false",with:"password: true"))
let hidden = parser.consume("V/talkback: TreeNodesDescription \(id) role=ROLE_EDIT_TEXT")!
check("Password text fields redacted", hidden["text"] is NSNull && hidden["tooltip"] is NSNull && hidden["content_description"] is NSNull && hidden["label"] as? String == "[Password content hidden]")
check("Password speech/fallback ignored", parser.consume(speak) == nil && parser.consume(tts) == nil)
check("Oversized log line discarded", parser.consume(String(repeating:"x",count:TalkBackParser.lineLimit+1)) == nil)
check("Bounds validation", TalkBackParser.bounds("Rect(1, 2 - 0, 1)") == nil && TalkBackParser.bounds("Rect(1, 2 - 99999999999999999999, 4)") == nil)
check("Negative bounds supported", TalkBackParser.bounds("Rect(-37, -451 - 1043, 819)")?["width"] == 1080)
_ = parser.consume(focus); parser.reset()
check("Reset drops all correlation state", parser.consume(speak) == nil)
let unicodeSpeech = speak.replacingOccurrences(of:speech,with:#"Hello \"world\" \\ ADHD ё"#)
_ = parser.consume(focus)
check("Escaped speech/unicode", parser.consume(unicodeSpeech)?["speech"] as? String == "Hello \"world\" \\ ADHD ё")

let root = FileManager.default.temporaryDirectory.appendingPathComponent("simwisp-a11y-unit-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories:true, attributes:[.posixPermissions:0o700])
defer { try? FileManager.default.removeItem(at:root) }
let fixture = root.appendingPathComponent("fake-adb.sh")
func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of:"'",with:"'\\''") + "'" }
try Data(("#!/bin/sh\nprintf '%s\\n' \(quote(focus)) \(quote(speak))\nexec /bin/sleep 30\n").utf8).write(to:fixture)
try FileManager.default.setAttributes([.posixPermissions:0o700], ofItemAtPath:fixture.path)
let delivery = DispatchQueue(label:"tests.a11y.delivery"), lifecycle = DispatchGroup(), logLock = NSLock()
var delivered: [[String: Any]] = []
let reader = AccessibilityReader(executable:fixture.path,serial:"fixture",lifecycle:lifecycle,callbackQueue:delivery) { token,state,node in
    logLock.withLock { delivered.append(["token": token, "state":state,"node":node as Any? ?? NSNull()]) }
}
func wait(_ condition: () -> Bool, timeout: Double = 2) -> Bool { let end = monotonic()+timeout; while !condition() && monotonic()<end { Thread.sleep(forTimeInterval:0.005) }; return condition() }
check("Closed reader never starts", reader.diagnostics["starts"] as? Int == 0 && reader.diagnostics["running"] as? Bool == false)
reader.start()
check("Demand creates one child", wait { reader.diagnostics["running"] as? Bool == true })
check("Native readiness reader emits exact speech", wait { logLock.withLock { delivered.contains { ($0["node"] as? [String:Any])?["speech"] as? String == speech } } })
reader.start()
check("Repeated open cannot duplicate child", reader.diagnostics["starts"] as? Int == 1)
let oldToken = logLock.withLock { delivered.last?["token"] as? UInt64 ?? 0 }
reader.stop()
check("Stop immediately invalidates generation", !reader.isCurrent(oldToken) && !reader.isGeneration(oldToken))
check("Child terminates and is reaped", lifecycle.wait(timeout:.now()+2) == .success && reader.diagnostics["running"] as? Bool == false)
let stoppedLines = reader.diagnostics["lines"] as? UInt64
let stoppedBytes = reader.diagnostics["bytes"] as? UInt64
Thread.sleep(forTimeInterval:0.08)
check("Closed reader parse/read counters never advance", stoppedLines == reader.diagnostics["lines"] as? UInt64 && stoppedBytes == reader.diagnostics["bytes"] as? UInt64)
check("Closed buffers released", reader.diagnostics["buffer_bytes"] as? Int == 0)
reader.start(); check("Reopen starts fresh", wait { reader.diagnostics["starts"] as? Int == 2 })
reader.stop(); reader.start()
check("Immediate stop/reopen reconciles child lifetime", wait { reader.diagnostics["starts"] as? Int == 3 })
reader.stop(); check("Fast reopen child cleanup", lifecycle.wait(timeout:.now()+2) == .success)
for _ in 0..<8 { reader.start(); _ = wait { reader.diagnostics["running"] as? Bool == true }; reader.stop(); _ = lifecycle.wait(timeout:.now()+2) }
check("Repeated lifecycle ends with no child", reader.diagnostics["running"] as? Bool == false)
let gatedQueue = DispatchQueue(label:"tests.a11y.gated"); gatedQueue.suspend()
var stale = 0
let gated = AccessibilityReader(executable:fixture.path,serial:"gated",lifecycle:lifecycle,callbackQueue:gatedQueue) { _,_,_ in logLock.withLock { stale += 1 } }
gated.start(); _ = wait { gated.diagnostics["lines"] as? UInt64 ?? 0 >= 2 }
gated.stop(); gatedQueue.resume(); _ = lifecycle.wait(timeout:.now()+2); gatedQueue.sync {}
check("Queued events are discarded on close before delivery", logLock.withLock { stale == 0 })
var errorSeen = false
let failed = AccessibilityReader(executable:"/not-present/adb",serial:"missing",lifecycle:lifecycle,callbackQueue:delivery) { _,state,_ in logLock.withLock { errorSeen = state == "error" } }
failed.start(); check("Launch failure safely reported", wait { logLock.withLock { errorSeen } })
check("Launch failure leaks no lifecycle group/child", lifecycle.wait(timeout:.now()+1) == .success && failed.diagnostics["running"] as? Bool == false)
failed.stop()

let network = DispatchQueue(label:"tests.a11y.network")
var messages: [[String: Any]] = []
let session = AccessibilitySession(serial:"fixture",platform:"android",executable:fixture.path,queue:network,lifecycle:lifecycle) { value, done in messages.append(value); done() }
func snap() -> [String:Any] { network.sync { session.snapshot } }
func readerInfo() -> [String:Any] { snap()["reader"] as? [String:Any] ?? [:] }
network.sync { session.update(streamActive:true) }
Thread.sleep(forTimeInterval:0.03)
check("Video only: no logcat reader is ever allocated", readerInfo().isEmpty)
network.sync { session.update(paneOpen:true,streamActive:false,subscription:1) }
check("Open pane without active video: no logcat", readerInfo().isEmpty)
network.sync { session.update(streamActive:true) }
check("Open pane plus active video starts monitoring", wait { readerInfo()["running"] as? Bool == true })
check("Same production coordinator sends speech", wait { network.sync { messages.contains { ($0["node"] as? [String:Any])?["speech"] as? String == speech } } })
check("Subscription echoed and popup reflects actual sending", network.sync { messages.contains { $0["subscription"] as? Int == 1 && $0["type"] as? String == "accessibility_event" } && session.snapshot["sending"] as? Bool == true })
network.sync { session.update(paneOpen:false,subscription:2) }
check("Pane close leaves no child while video continues", lifecycle.wait(timeout:.now()+2) == .success && readerInfo()["running"] as? Bool == false)
let offInfo = readerInfo(); let offMessages = network.sync { messages.count }
Thread.sleep(forTimeInterval:0.08)
check("Closed pane does not read or parse or send", readerInfo()["bytes"] as? UInt64 == offInfo["bytes"] as? UInt64 && readerInfo()["lines"] as? UInt64 == offInfo["lines"] as? UInt64 && network.sync { messages.count == offMessages })
network.sync { session.update(paneOpen:true,streamActive:true,subscription:3) }
check("Pane reopen creates fresh child", wait { readerInfo()["starts"] as? Int == 2 })
network.sync { session.update(streamActive:false) }
check("Stream pause/window loss cancels monitoring even with pane open", lifecycle.wait(timeout:.now()+2) == .success && snap()["state"] as? String == "off" && snap()["requested"] as? Bool == true)
network.sync { session.update(streamActive:true) }
check("Active-stream resumption restores open-pane monitoring", wait { readerInfo()["starts"] as? Int == 3 })
network.sync { session.stop(); session.update(paneOpen:true,streamActive:true) }
check("Disconnect/replacement/shutdown cannot restart closed session", lifecycle.wait(timeout:.now()+2) == .success && readerInfo()["starts"] as? Int == 3 && readerInfo()["running"] as? Bool == false)
let ios = AccessibilitySession(serial:"ios-fixture",platform:"ios",executable:fixture.path,queue:network,lifecycle:lifecycle) { value, done in messages.append(value); done() }
network.sync { ios.update(paneOpen:true,streamActive:true) }
check("Native backend rejects iOS independently of UI", network.sync { (ios.snapshot["reader"] as? [String:Any])?.isEmpty == true && ios.snapshot["requested"] as? Bool == false })
let noADB = AccessibilitySession(serial:"missing",platform:"android",executable:nil,queue:network,lifecycle:lifecycle) { value, done in messages.append(value); done() }
network.sync { noADB.update(paneOpen:true,streamActive:true) }
check("Missing SDK produces error without spawning", network.sync { noADB.snapshot["state"] as? String == "error" && (noADB.snapshot["reader"] as? [String:Any])?.isEmpty == true })
network.sync { ios.stop(); noADB.stop() }


// Bound oversized input and exercise chunked UTF8 + latest-only delivery.
let burstFile = root.appendingPathComponent("burst.txt")
var burst = String(repeating:"x",count:TalkBackParser.lineLimit+4000)+"\n"
for n in 0..<150 { burst += focus.replacingOccurrences(of:"time:123",with:"time:\(1000+n)")+"\n"; burst += speak.replacingOccurrences(of:"time:123",with:"time:\(1000+n)").replacingOccurrences(of:speech,with:"Latest ё event \(n)")+"\n" }
try Data(burst.utf8).write(to:burstFile)
let burstScript = root.appendingPathComponent("burst.sh")
try Data("#!/bin/sh\n/bin/cat \(quote(burstFile.path))\nexec /bin/sleep 30\n".utf8).write(to:burstScript)
try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:burstScript.path)
let heldQueue=DispatchQueue(label:"tests.a11y.held"), heldLock=NSLock();heldQueue.suspend()
var burstNodes: [[String:Any]]=[]
let noisy=AccessibilityReader(executable:burstScript.path,serial:"burst",lifecycle:lifecycle,callbackQueue:heldQueue) { _,state,node in if state == "event",let node {heldLock.withLock {burstNodes.append(node)}} }
noisy.start();check("Burst fully read while callback queue blocked",wait { noisy.diagnostics["lines"] as? UInt64 ?? 0 >= 300 })
check("Oversized/chunked input buffer stays bounded",noisy.diagnostics["buffer_bytes"] as? Int ?? -1 <= TalkBackParser.lineLimit)
heldQueue.resume();check("Latest-only slot delivers most recent focus/speech",wait {heldLock.withLock {burstNodes.last?["speech"] as? String == "Latest ё event 149"}})
check("Blocked network never accumulates per-event callbacks",heldLock.withLock {burstNodes.count <= 2})
noisy.stop();check("Noisy child cleanup",lifecycle.wait(timeout:.now()+2) == .success)
let exitQueue=DispatchQueue(label:"tests.a11y.exit"),exitLock=NSLock();var naturalError=false
let exited=AccessibilityReader(executable:"/usr/bin/true",serial:"exit",lifecycle:lifecycle,callbackQueue:exitQueue) { _,state,_ in exitLock.withLock {naturalError=state=="error"} }
exited.start();check("Unexpected child exit reports unavailable",wait {exitLock.withLock {naturalError}})
check("Natural exit reaps and releases lifecycle",lifecycle.wait(timeout:.now()+2) == .success && exited.diagnostics["running"] as? Bool == false)
exited.stop()
// A slow transport permits one event in flight and one newest pending slot.
let slowQueue=DispatchQueue(label:"tests.a11y.slow")
var completions:[()->Void]=[], slowMessages:[[String:Any]]=[]
let slow=AccessibilitySession(serial:"slow",platform:"android",executable:burstScript.path,queue:slowQueue,lifecycle:lifecycle) { value,done in
    if value["type"] as? String == "accessibility_event" {slowMessages.append(value);completions.append(done)} else {done()}
}
slowQueue.sync {slow.update(paneOpen:true,streamActive:true)}
check("Slow-send fixture starts",wait {slowQueue.sync {((slow.snapshot["reader"] as? [String:Any])?["lines"] as? UInt64 ?? 0) >= 300}})
check("At most one accessibility packet in flight",slowQueue.sync {slowMessages.count == 1 && completions.count == 1})
check("Popup never claims sending before transport completion",slowQueue.sync {slow.snapshot["sending"] as? Bool == false})
slowQueue.sync {slow.stop();completions.forEach {$0()}}
check("Close invalidates pending send and old completion",lifecycle.wait(timeout:.now()+2) == .success && slowQueue.sync {slowMessages.count == 1 && slow.snapshot["sending"] as? Bool == false})

let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
print(String(decoding:try JSONSerialization.data(withJSONObject:["passed":passed,"checks":checks],options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
try? FileManager.default.removeItem(at: root)
exit(passed ? 0 : 1)
