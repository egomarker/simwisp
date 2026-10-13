import Foundation
import AppKit
import ApplicationServices

// Only injected command/window effects are used. No simctl/ADB, window close,
// application quit, permission request, or host input occurs in these tests.
var checks = 0
func expect(_ condition: Bool, _ name: String) {
    guard condition else { fatalError("FAIL: " + name) }; checks += 1
}
let a = "00000000-0000-4000-8000-000000000001", b = "00000000-0000-4000-8000-000000000002"
func ref(_ id: UInt32 = 1, title: String = "iPhone 11 — iOS 26.0", pid: pid_t = 901) -> SimulatorWindowRef {
    SimulatorWindowRef(id: id, pid: pid, title: title, bounds: CGRect(x: 10, y: 10, width: 200, height: 400))
}
final class World {
    var entries: [[String: Any]] = [["udid": a, "name": "iPhone 11", "state": "Booted", "isAvailable": true]]
    var refs = [ref()], apps: [pid_t] = [901], reliable = true
    var commands: [[String]] = [], closeIDs: [UInt32] = [], quitAttempts = 0, quits = 0, snapshots = 0
    var failShutdown = false, failClose = false, failInventory = false, failSnapshot = false, invalidInventory = false, failADB = false
    var neverShutdown = false, neverRemoveADB = false, uncertainAfterClose = false, closeNeverCompletes = false, quitRefused = false
    var android = ["emulator-5554", "emulator-5556"]
    var time = 0.0, disappearAt: Double?, listDuration = 0.0
    var listOverride: String?, failList = false, listFailures = 0
    var listTimeouts: [Double] = [], androidState = "device"
    var onSnapshot: ((Int) -> Void)?, onQuit: (() -> Void)?, onInventory: ((Int) -> Void)?
    var inventories = 0, selectionReliable: Bool?
    let launches = DeviceLaunches()
    var control: DeviceControl!
    init(adb: String? = "/fixture/adb") {
        control = DeviceControl(adb: adb, launches: launches,
            windows: SimulatorWindowEffects(snapshot: { [unowned self] in
                snapshots += 1; onSnapshot?(snapshots)
                if failSnapshot { throw WispError("fixture window query failed") }
                return SimulatorWindowSnapshot(applications: apps, windows: refs, reliable: reliable, selectionReliable: selectionReliable)
            }, close: { [unowned self] window in
                if failClose { throw WispError("fixture close refused") }
                closeIDs.append(window.id)
                if !closeNeverCompletes { refs.removeAll { window.sameWindow($0) } }
                if uncertainAfterClose { reliable = false }
            }, quitIfEmpty: { [unowned self] pid in
                quitAttempts += 1; onQuit?()
                // The native effect makes this same fresh identity/window check.
                guard reliable, refs.isEmpty, apps == [pid], !quitRefused else { return false }
                quits += 1; return true
            }), run: { [unowned self] path, args, timeout in
                commands.append([path] + args)
                if args == ["simctl", "list", "devices", "--json"] {
                    inventories += 1; onInventory?(inventories)
                    if failInventory { return result(status: 1, error: "fixture inventory failed") }
                    if invalidInventory { return result(output: "not valid JSON") }
                    return result(data: try JSONSerialization.data(withJSONObject: ["devices": ["fixture-runtime": entries]]))
                }
                if args.first == "simctl", args.count == 3, args[1] == "shutdown" {
                    if failShutdown { return result(status: 1, error: "fixture shutdown refused") }
                    if !neverShutdown, let index = entries.firstIndex(where: { $0["udid"] as? String == args[2] }) { entries[index]["state"] = "Shutdown" }
                    return result()
                }
                if args.count == 4, args[0] == "-s", args[2] == "emu", args[3] == "kill" {
                    if failADB { return result(status: 1, error: "fixture ADB refused") }
                    if !neverRemoveADB { android.removeAll { $0 == args[1] } }
                    return result()
                }
                if args == ["devices"] {
                    listTimeouts.append(timeout); time += min(timeout, listDuration)
                    if failList || listFailures > 0 { listFailures = max(0, listFailures - 1); return result(status: 1, error: "fixture inventory failed") }
                    if let listOverride { return result(output: listOverride) }
                    if let disappearAt, time >= disappearAt { android.removeAll { $0 == "emulator-5554" } }
                    return result(output: "List of devices attached\n" + android.map { $0 + "\t" + androidState + "\n" }.joined())
                }
                fatalError("Unexpected command path/args: \(path) \(args)")
            }, wait: { [unowned self] seconds in time += seconds }, clock: { [unowned self] in time })
    }
}
func result(status: Int32 = 0, output: String = "", error: String = "", data: Data? = nil) -> CommandResult {
    CommandResult(status: status, output: data ?? Data(output.utf8), error: Data(error.utf8))
}
func device(_ id: String = a, platform: String = "ios") -> Device { Device(id: id, name: "iPhone 11", platform: platform, width: 200, height: 400) }
func fails(_ world: World, _ value: Device = device(), _ name: String) {
    do { _ = try world.control.stop(value); fatalError("FAIL: " + name) } catch { checks += 1 }
}
for id in ["booted", "all", "", "../../", a + "/extra", "-x", "ios-fixture"] {
    let world = World(); fails(world, device(id), "invalid iOS selector rejected")
    expect(world.commands.isEmpty && world.closeIDs.isEmpty && world.quits == 0, "invalid selector has no effects")
}
for id in ["emulator-0", "emulator-65536", "emulator-05554", "emulator-5554;kill", "emulator-5554/", "physical-device", "5554"] {
    let world = World(); fails(world, device(id, platform: "android"), "invalid ADB serial rejected")
    expect(world.commands.isEmpty, "invalid serial sends no command")
}
do {
    let world = World(); let output = try world.control.stop(device())
    expect(output["ok"] as? Bool == true && output["window_closed"] as? Bool == true && output["simulator_quit_requested"] as? Bool == true, "last device/window stops then normal quit requested")
    expect(world.commands.filter { $0.contains("shutdown") } == [["/usr/bin/xcrun", "simctl", "shutdown", a]], "exact selected UDID shutdown, never all/booted")
    expect(world.closeIDs == [1] && world.quits == 1, "only selected native window closed")
    expect(!world.commands.contains { $0.contains("killall") || $0.contains("osascript") || $0.contains("open") }, "no force-kill/AppleScript/app launch")
}
for state in ["Booted", "Booting", "ShuttingDown", "Creating", "Unknown"] {
    let world = World(); world.entries.append(["udid": b, "name": "iPhone SE", "state": state, "isAvailable": true])
    let output = try world.control.stop(device())
    expect(output["ok"] as? Bool == true && world.quits == 0, "headless/transitional \(state) device blocks shared-app quit")
    expect(world.entries.last?["state"] as? String == state && world.closeIDs == [1], "other device remains unchanged")
}
for title in ["iPhone SE — iOS 26", "Minimized device", "Hidden device", "Device on another Space", "Simulator Settings"] {
    let world = World(); world.refs.append(ref(2, title: title))
    _ = try world.control.stop(device())
    expect(world.quits == 0 && world.refs.map(\.id) == [2], "remaining \(title) window blocks shared quit")
    expect(world.closeIDs == [1], "never closes remaining window")
}
do {
    let world = World(); world.refs = [ref(2, title: "iPhone 11 Pro — iOS 26")]
    _ = try world.control.stop(device())
    expect(world.closeIDs.isEmpty && world.quits == 0 && world.refs.count == 1, "partial name cannot close Pro window")
}
do {
    let world = World(); world.entries.append(["udid": b, "name": "iPhone 11", "state": "Booted", "isAvailable": true])
    let output = try world.control.stop(device())
    expect(world.closeIDs.isEmpty && world.quits == 0 && output["warning"] is String, "ambiguous same-name devices only shut down exact UDID")
}
do {
    let world = World(); world.refs.append(ref(2))
    let output = try world.control.stop(device())
    expect(world.closeIDs.isEmpty && world.quits == 0 && output["warning"] is String, "ambiguous matching windows are not guessed")
}
do {
    let world = World(); world.apps = [901, 902]
    _ = try world.control.stop(device())
    expect(world.quits == 0, "multiple Simulator instances are not globally quit")
}
do {
    let world = World(); world.reliable = false
    let output = try world.control.stop(device())
    expect(world.closeIDs.isEmpty && world.quits == 0 && output["warning"] is String, "incomplete initial window data cannot close or quit")
}
for failure in ["snapshot", "close", "uncertain", "closePending"] {
    let world = World()
    if failure == "snapshot" { world.failSnapshot = true }
    if failure == "close" { world.failClose = true }
    if failure == "uncertain" { world.uncertainAfterClose = true }
    if failure == "closePending" { world.closeNeverCompletes = true }
    let output = try world.control.stop(device())
    expect(output["ok"] as? Bool == true && output["warning"] is String && world.quits == 0, "\(failure) degrades safely after verified shutdown")
}
for failure in ["inventory", "invalidInventory", "shutdown", "neverShutdown"] {
    let world = World()
    if failure == "inventory" { world.failInventory = true }
    if failure == "invalidInventory" { world.invalidInventory = true }
    if failure == "shutdown" { world.failShutdown = true }
    if failure == "neverShutdown" { world.neverShutdown = true }
    fails(world, device(), "\(failure) is propagated")
    expect(world.closeIDs.isEmpty && world.quits == 0, "\(failure) cannot close/quit app")
}
do {
    let world = World(); world.launches.begin()
    _ = try world.control.stop(device())
    expect(world.quitAttempts == 0, "pending launch blocks quit before native request")
    world.launches.end(); expect(world.launches.ifIdle { true }, "launch tracking ends without timers")
}
do {
    let world = World()
    world.onSnapshot = { n in if n == 3 { world.refs.append(ref(3, title: "New simulator window")) } }
    _ = try world.control.stop(device())
    expect(world.quits == 0 && world.refs.count == 1, "window opened during stop prevents quit")
}
do {
    let world = World(); world.onQuit = { world.refs.append(ref(3, title: "Last-moment window")) }
    let output = try world.control.stop(device())
    expect(world.quitAttempts == 1 && world.quits == 0 && output["simulator_quit_requested"] as? Bool == false, "final native recheck protects last-moment window")
}
do {
    let world = World(); world.onQuit = { world.apps = [902] }
    _ = try world.control.stop(device())
    expect(world.quits == 0, "final native recheck protects replaced app identity")
}
do {
    let world = World(); world.quitRefused = true
    let output = try world.control.stop(device())
    expect(output["simulator_quit_requested"] as? Bool == false && world.quits == 0, "normal quit refusal never escalates to force quit")
}
do {
    let world = World(); world.refs = []
    let output = try world.control.stop(device())
    expect(output["window_closed"] as? Bool == false && world.quits == 1, "headless selected device can leave app truly idle")
}
do {
    let world = World(); world.apps = []; world.refs = []
    _ = try world.control.stop(device())
    expect(world.quitAttempts == 0, "already-absent app is not launched/quit")
}
do {
    let world = World(); world.entries[0]["state"] = "Shutdown"
    _ = try world.control.stop(device())
    expect(world.commands.filter { $0.contains("shutdown") }.isEmpty && world.closeIDs == [1], "already-shutdown selected device closes only its lingering window")
}
do {
    let world = World(); world.entries[0]["isAvailable"] = false
    fails(world, device(), "unavailable device rejected")
    expect(world.closeIDs.isEmpty && world.commands.count == 1, "unavailable device sends no shutdown")
}
do {
    let world = World(); let output = try world.control.stop(device("emulator-5554", platform: "android"))
    expect(world.commands.first == ["/fixture/adb", "-s", "emulator-5554", "emu", "kill"], "ADB kill is explicitly serial-scoped")
    expect(world.android == ["emulator-5556"] && world.snapshots == 0 && world.closeIDs.isEmpty && world.quits == 0, "Android stop never touches iOS GUI/other emulator")
    expect(output["ok"] as? Bool == true && output["simulator_quit_requested"] as? Bool == false, "Android success after disappearance")
}
for failure in ["missingADB", "ADBError"] {
    let world = World(adb: failure == "missingADB" ? nil : "/fixture/adb")
    world.failADB = failure == "ADBError"
    fails(world, device("emulator-5554", platform: "android"), "\(failure) reported")
    expect(world.snapshots == 0 && world.quits == 0, "\(failure) never falls back to iOS/global kill")
    expect(world.commands.count <= 1, "failed kill never enters confirmation")
}
// The owner observed successful real shutdown after the old quick grace ended.
for seconds in [2.0, 4.0, 7.75] {
    let world = World(); world.neverRemoveADB = true; world.disappearAt = seconds
    let output = try world.control.stop(device("emulator-5554", platform: "android"))
    expect(output["state"] as? String == "stopped" && output["window_closed"] as? Bool == true && world.time >= seconds, "delayed removal within grace is confirmed success")
    expect(world.commands.filter { $0.contains("kill") }.count == 1 && world.android == ["emulator-5556"], "delayed stop never resends kill or removes second serial")
}
for state in ["device", "offline", "unauthorized", "recovery", "no permissions"] {
    let world = World(); world.neverRemoveADB = true; world.androidState = state
    let output = try world.control.stop(device("emulator-5554", platform: "android"))
    expect(output["ok"] as? Bool == true && output["state"] as? String == "pending" && output["window_closed"] as? Bool == false, "accepted kill with remaining serial is neutral pending, even offline")
    expect(world.time == 8 && world.commands.filter { $0.contains("kill") }.count == 1 && world.listTimeouts.count == 32, "confirmation bounded to eight monotonic seconds, one selected kill")
    let fresh = try world.control.androidStopStatus("emulator-5554")
    expect(fresh["state"] as? String == "pending" && world.commands.last == ["/fixture/adb", "devices"], "refresh checks all-state serial presence without kill")
    world.android.removeAll { $0 == "emulator-5554" }
    expect((try world.control.androidStopStatus("emulator-5554"))["state"] as? String == "stopped", "fresh confirmed absence resolves pending stop")
    expect(world.quits == 0 && world.snapshots == 0 && world.commands.filter { $0.contains("kill") }.count == 1, "status reconciliation never touches GUI/other devices or repeats kill")
}
for invalid in ["", "adb output error", "List of devices attached\nemulator-5554", "List of devices attached\nemulator-5554 device\nemulator-5554 offline", "List of devices attached\ngarbage unexpected"] {
    let world = World(); world.listOverride = invalid
    let output = try world.control.stop(device("emulator-5554", platform: "android"))
    expect(output["state"] as? String == "pending", "unreadable inventory after accepted kill is not a failed shutdown or false success")
    do { _ = try world.control.androidStopStatus("emulator-5554"); fatalError("FAIL: malformed inventory cannot confirm absence") } catch { checks += 1 }
}
do {
    let world = World(); world.failList = true
    expect((try world.control.stop(device("emulator-5554", platform: "android")))["state"] as? String == "pending", "inventory failure preserves accepted pending outcome")
    do { _ = try world.control.androidStopStatus("emulator-5554"); fatalError("FAIL: failed list cannot confirm shutdown") } catch { checks += 1 }
    expect(world.commands.filter { $0.contains("kill") }.count == 1, "list failures never resend accepted kill")
}
do {
    let world = World(); world.listFailures = 3
    expect((try world.control.stop(device("emulator-5554", platform: "android")))["state"] as? String == "stopped", "transient inventory failures recover within grace")
}
do {
    let world = World(); world.neverRemoveADB = true; world.listDuration = 2
    expect((try world.control.stop(device("emulator-5554", platform: "android")))["state"] as? String == "pending", "slow tools return pending at the same elapsed deadline")
    expect(world.time == 8 && world.listTimeouts.count == 4 && world.listTimeouts.last! <= 1.25, "tool time counts toward deadline; last command budget fits remaining time")
}
do {
    let world = World(); world.listOverride = "List of devices attached\r\nemulator-55540\tdevice\r\nphysical-123\tunauthorized\r\n"
    expect((try world.control.androidStopStatus("emulator-5554"))["state"] as? String == "stopped", "CRLF/other and prefix serials never count as selected serial")
    expect(world.commands == [["/fixture/adb", "devices"]], "fresh absence check is one inventory only")
}
for id in [a, "all", "emulator-05554", "emulator-5554/extra", "physical-device"] {
    let world = World()
    do { _ = try world.control.androidStopStatus(id); fatalError("FAIL: invalid status selector accepted") } catch { checks += 1 }
    expect(world.commands.isEmpty, "invalid confirmation selector sends no command")
}
do {
    let world = World(); world.entries.append(["udid": b, "name": "iPhone 11", "state": "Shutdown", "isAvailable": true])
    let output = try world.control.stop(device())
    expect(world.closeIDs.isEmpty && world.quits == 0 && output["warning"] is String, "shutdown same-name sibling still makes its lingering window ambiguous")
}
do {
    let world = World(); world.entries.append(["udid": b, "name": "iPhone 11 — Custom", "state": "Booted", "isAvailable": true])
    world.refs = [ref(2, title: "iPhone 11 — Custom — iOS 26")]
    _ = try world.control.stop(device())
    expect(world.closeIDs.isEmpty && world.quits == 0, "delimiter in another device name cannot select its window")
}
do {
    let world = World(); world.onSnapshot = { n in if n == 2 { world.refs = [] } }
    let output = try world.control.stop(device())
    expect(output["window_closed"] as? Bool == true && output["warning"] == nil && world.closeIDs.isEmpty && world.quits == 1, "selected window already closed by shutdown is benign and can leave shared app idle")
}
expect(ref().stillIdentifies(ref()), "unchanged native window identity retained")
expect(!ref().stillIdentifies(ref(title: "iPhone SE — iOS 26")), "reused window with another device title rejected")
expect(!ref().stillIdentifies(ref(pid: 902)), "replaced app identity rejected")
expect(!ref().stillIdentifies(ref(2)), "different native window rejected")
// Exercise the actual production metadata adapter, not supplied snapshots.
let adapterStart = checks
let windowBounds = CGRect(x: 1420, y: 115, width: 443, height: 924)
let menuBounds = CGRect(x: 0, y: 0, width: 1920, height: 24)
let auxiliaryBounds = CGRect(x: 1440, y: 131, width: 52, height: 20)
func ax(_ bounds: CGRect = windowBounds, role: String? = kAXWindowRole, title: String? = "iPhone 11 — iOS 18.6") -> SimulatorWindowAdapter.AXRecord {
    SimulatorWindowAdapter.AXRecord(role: role, title: title, bounds: bounds)
}
func cg(_ id: UInt32, bounds: CGRect = windowBounds, layer: Int = 8, title: String? = nil, pid: pid_t = 901, onscreen: Bool? = true) -> [String: Any] {
    var info: [String: Any] = [kCGWindowOwnerPID as String: NSNumber(value: pid), kCGWindowNumber as String: NSNumber(value: id), kCGWindowLayer as String: layer, kCGWindowBounds as String: bounds.dictionaryRepresentation]
    if let title { info[kCGWindowName as String] = title }
    if let onscreen { info[kCGWindowIsOnscreen as String] = onscreen }
    return info
}
let helpers = (10...13).map { cg(UInt32($0), bounds: menuBounds, layer: 0, onscreen: nil) }
let menu = ax(menuBounds, role: kAXMenuBarRole, title: "")
let button = ax(auxiliaryBounds, role: kAXButtonRole, title: "")
let actualLayout = [cg(1), cg(2, bounds: auxiliaryBounds)] + helpers
func assemble(_ windows: [SimulatorWindowAdapter.AXRecord] = [ax()], _ surfaces: [[String: Any]] = actualLayout, _ auxiliary: [SimulatorWindowAdapter.AXRecord] = [menu, button]) -> SimulatorWindowAdapter.Result {
    SimulatorWindowAdapter.assemble(pid: 901, windows: windows, surfaces: surfaces, auxiliary: auxiliary)
}
do {
    let result = assemble()
    expect(result.reliable && result.selectionReliable && result.windows.map(\.id) == [1], "floating layer8 window plus positively read AX menu/button helper surfaces are reliable")
    expect(result.indices == [1: 0], "real adapter retains exactly selected AX index, not a menu/helper ID")
    let unknown = assemble([ax()], actualLayout, [])
    expect(!unknown.reliable && unknown.selectionReliable && unknown.windows.count == 1, "without semantic helper evidence, selected window identifiable but quit remains blocked")
    expect(!assemble([ax()], actualLayout, [ax(menuBounds, role: kAXWindowRole, title: ""), button]).reliable, "a window role cannot masquerade as a menu bar")
    expect(!assemble([ax()], actualLayout, [ax(menuBounds, role: nil, title: ""), button]).reliable, "unreadable helper role cannot establish emptiness")
    expect(!assemble([ax()], actualLayout, [ax(menuBounds, role: "AXUnknown", title: ""), button]).reliable, "unrecognized helper role is not ignored")
}
for layer in [-1, 0, 1, 3, 8, 20, 100] {
    for onscreen in [true, false] {
        let result = assemble([ax()], [cg(1, layer: layer, onscreen: onscreen)], [])
        expect(result.reliable && result.windows.map(\.id) == [1], "device window layer/visibility never filters actual AX windows")
    }
}
for role in [kAXMenuBarRole, kAXMenuRole, kAXToolbarRole, kAXGroupRole, kAXButtonRole, kAXMenuButtonRole, kAXPopUpButtonRole, kAXStaticTextRole, kAXImageRole] {
    let item = ax(auxiliaryBounds, role: role, title: "")
    expect(assemble([ax()], [cg(1), cg(2, bounds: auxiliaryBounds)], [item]).reliable, "known AX non-window role can corroborate its own compositor surface")
}
for title in ["Hidden device", "Minimized device", "Another Space", "Simulator Settings", ""] {
    let bounds = CGRect(x: -500, y: -100, width: 250, height: 450)
    let result = assemble([ax(), ax(bounds, title: title)], [cg(1), cg(2, bounds: bounds, layer: 8, title: title, onscreen: false)], [])
    expect(result.reliable && result.windows.count == 2, "hidden/minimized/other-Space/untitled actual windows remain in full inventory")
    let world = World(); world.refs = result.windows
    _ = try world.control.stop(device())
    expect(world.closeIDs == [1] && world.quits == 0 && world.refs.count == 1, "adapter output preserves every independent remaining window during selected Stop")
}
for bounds in [CGRect(x: 0, y: 0, width: 1, height: 1), menuBounds, auxiliaryBounds] {
    let result = assemble([ax()], [cg(1), cg(2, bounds: bounds, layer: 0, onscreen: false)], [])
    expect(!result.reliable, "generic tiny/menu-sized/hidden unmatched surfaces cannot be ignored")
}
do {
    let tiny = ax(menuBounds, title: "Simulator Settings")
    let result = assemble([ax(), tiny], [cg(1), cg(10, bounds: menuBounds, layer: 0)], [menu])
    expect(result.reliable && result.windows.count == 2, "AXWindow takes precedence over overlapping AXMenuBar geometry")
    expect(!assemble([ax(), tiny], [cg(1)] + helpers, [menu]).reliable, "duplicate compositor bounds for an actual AXWindow remain ambiguous, not discarded as menu helpers")
    expect(!assemble([ax()], [cg(1), cg(2)], []).selectionReliable, "duplicate device-sized CG candidates cannot select a first match")
    expect(!assemble([ax(), ax()], [cg(1)], []).selectionReliable, "two AX windows cannot reuse a single compositor identity")
    expect(!assemble([ax()], [cg(1), cg(2, bounds: auxiliaryBounds, title: "Another device")], [button]).reliable, "named independent surface cannot hide behind an empty-titled AX button")
    expect(!assemble([ax()], [cg(1), cg(2, bounds: auxiliaryBounds, title: "Another device")], [button]).selectionReliable, "unmatched named app window also blocks selected-window action")
    expect(assemble([], helpers, [menu]).reliable && assemble([], helpers, [menu]).windows.isEmpty, "real menu-bar-only app can be empty without requiring CG list to be empty")
    expect(!assemble([], helpers, []).reliable, "menu-sized shapes alone do not prove an empty app")
    expect(assemble([], [], []).reliable, "empty complete AX and CG inventories remain reliable")
    expect(!assemble([ax()], [cg(1), cg(2, bounds: auxiliaryBounds)], [ax(auxiliaryBounds, role: kAXButtonRole, title: nil)]).windows.isEmpty, "auxiliary title query failure cannot erase an actual device window")
}
for bad in [ax(role: nil), ax(role: kAXGroupRole), ax(title: nil), ax(CGRect.zero), ax(CGRect(x: 0, y: 0, width: CGFloat.nan, height: 20))] {
    expect(!assemble([bad], [cg(1)], []).selectionReliable, "malformed AX window metadata cannot authorize a close")
}
do {
    let tooMany = Array(repeating: ax(), count: 65)
    expect(!assemble(tooMany, [cg(1)], []).reliable, "AX window limit never truncates to successful emptiness")
    for key in [kCGWindowOwnerPID, kCGWindowNumber, kCGWindowBounds] {
        var broken = cg(1); broken.removeValue(forKey: key as String)
        expect(!assemble([ax()], [broken], []).reliable, "missing CG owner/id/bounds fails safely")
    }
    for number in [NSNumber(value: 0), NSNumber(value: -1), NSNumber(value: 1.5), NSNumber(value: UInt64(UInt32.max) + 1)] {
        var broken = cg(1); broken[kCGWindowNumber as String] = number
        expect(!assemble([ax()], [broken], []).selectionReliable, "invalid compositor window number cannot be truncated into identity")
    }
    var badTitle = cg(1); badTitle[kCGWindowName as String] = 3
    expect(!assemble([ax()], [badTitle], []).reliable, "malformed optional CG title is not guessed")
    expect(!assemble([ax()], [cg(1), cg(1)], []).selectionReliable, "duplicate CG IDs are incomplete data")
    expect(assemble([ax()], [cg(1), cg(2, pid: 902)], []).reliable, "another application's compositor surfaces are not selected or counted as this app's")
}
// Opaque native identities: create unqueried synthetic proxies, never AX actions.
do {
    let first = AXUIElementCreateApplication(99998), other = AXUIElementCreateApplication(99999)
    let original = SimulatorWindowRef(id: 1, pid: 901, title: "iPhone 11", bounds: windowBounds, element: first)
    let unchanged = SimulatorWindowRef(id: 1, pid: 901, title: "iPhone 11", bounds: windowBounds, element: first)
    let replacement = SimulatorWindowRef(id: 1, pid: 901, title: "iPhone 11", bounds: windowBounds, element: other)
    expect(original.stillIdentifies(unchanged), "same opaque AX identity is retained")
    expect(!original.sameWindow(replacement), "reused CG ID and title with different AX identity rejected")
    expect(!original.sameWindow(ref()), "native identity cannot be replaced with missing AX identity")
    let world = World(); world.refs = [original]
    world.onSnapshot = { n in if n == 2 { world.refs = [replacement] } }
    _ = try world.control.stop(device())
    expect(world.closeIDs.isEmpty && world.quits == 0 && world.refs.count == 1, "reused native identity after shutdown never closes replacement window")
}
do {
    expect(!assemble([], [cg(2, bounds: auxiliaryBounds)], [button, ax(auxiliaryBounds, role: kAXWindowRole, title: "Child window")]).reliable, "child AXWindow evidence overrides coincident auxiliary bounds")
    let proxy = AXUIElementCreateApplication(99998)
    let original = SimulatorWindowRef(id: 1, pid: 901, title: "iPhone 11", bounds: windowBounds, element: proxy)
    let renumbered = SimulatorWindowRef(id: 2, pid: 901, title: "iPhone 11", bounds: windowBounds, element: proxy)
    expect(original.sameWindow(renumbered), "opaque AX identity survives CG number replacement")
    let world = World(); world.refs = [original]
    world.onSnapshot = { n in if n == 2 { world.refs = [renumbered] } }
    let output = try world.control.stop(device())
    expect(world.closeIDs == [1] && output["window_closed"] as? Bool == true, "renumbered existing window is actually closed, never falsely declared absent")
}
do {
    let before = actualLayout
    expect(SimulatorWindowAdapter.stable(before: before, after: before.reversed(), pids: [901]), "CG enumeration order alone cannot invalidate a snapshot")
    expect(!SimulatorWindowAdapter.stable(before: before, after: before + [cg(50, bounds: auxiliaryBounds, onscreen: false)], pids: [901]), "late hidden/other-Space surface invalidates empty-window reasoning")
    expect(!SimulatorWindowAdapter.stable(before: before, after: Array(before.dropFirst()), pids: [901]), "surface removal during AX/CG scan forces another fresh read")
    for field in [kCGWindowName, kCGWindowBounds, kCGWindowLayer, kCGWindowIsOnscreen, kCGWindowNumber] {
        var changed = before
        if field == kCGWindowName { changed[0][field as String] = "iPhone SE" }
        if field == kCGWindowBounds { changed[0][field as String] = menuBounds.dictionaryRepresentation }
        if field == kCGWindowLayer { changed[0][field as String] = 0 }
        if field == kCGWindowIsOnscreen { changed[0][field as String] = false }
        if field == kCGWindowNumber { changed[0][field as String] = 99 }
        expect(!SimulatorWindowAdapter.stable(before: before, after: changed, pids: [901]), "changed native metadata invalidates the read")
    }
    expect(SimulatorWindowAdapter.stable(before: before, after: before + [cg(51, pid: 902)], pids: [901]), "unrelated app's new surface does not authorize or obstruct this app's scan")
    expect(!SimulatorWindowAdapter.stable(before: before, after: before + [cg(1)], pids: [901]), "duplicate identities never produce stable native data")
    expect(!SimulatorWindowAdapter.stable(before: before, after: [[:]], pids: [901]), "failed CG owner metadata cannot establish a stable inventory")
}
let adapterChecks = checks - adapterStart
let raceStart = checks
for initial in ["ambiguous", "queryError", "duplicateTitle"] {
    let world = World()
    if initial == "duplicateTitle" { world.refs.append(ref(2)) }
    world.onSnapshot = { n in
        if n == 1 { world.reliable = initial != "ambiguous"; world.failSnapshot = initial == "queryError" }
        else { world.reliable = true; world.failSnapshot = false; world.refs = [] }
    }
    let output = try world.control.stop(device())
    expect(output["warning"] == nil && output["simulator_quit_requested"] as? Bool == true && world.quits == 1, "fresh complete emptiness resolves initial ambiguity/query error/duplicate title after auto-close")
    expect(world.closeIDs.isEmpty && world.commands.filter { $0.contains("shutdown") }.count == 1, "recovery uses no guessed close or repeated shutdown")
}
for blocker in ["otherBooted", "otherBooting", "unknownDevice", "pendingLaunch", "multipleApps", "uncertain", "remainingWindow", "quitRefused", "inventoryError"] {
    let world = World()
    world.onSnapshot = { n in
        if n == 1 { world.reliable = false }
        else {
            world.refs = []; world.reliable = blocker != "uncertain"
            if blocker == "remainingWindow" { world.refs = [ref(2, title: "Hidden other device")] }
            if blocker == "multipleApps" { world.apps = [901, 902] }
            if n == 2 {
                if ["otherBooted", "otherBooting", "unknownDevice"].contains(blocker) { world.entries.append(["udid": b, "name": "iPhone SE", "state": blocker == "otherBooted" ? "Booted" : blocker == "otherBooting" ? "Booting" : "Unknown", "isAvailable": true]) }
                if blocker == "pendingLaunch" { world.launches.begin() }
                if blocker == "inventoryError" { world.failInventory = true }
            }
        }
    }
    world.quitRefused = blocker == "quitRefused"
    let output = try world.control.stop(device())
    expect(world.quits == 0 && output["simulator_quit_requested"] as? Bool == false && world.closeIDs.isEmpty, "fresh-idle recovery retains every device/launch/window/identity/error blocker")
}
do {
    let world = World(); world.reliable = false; world.selectionReliable = true
    let output = try world.control.stop(device())
    expect(world.closeIDs == [1] && output["window_closed"] as? Bool == true && world.quits == 0 && output["warning"] is String, "known selected AX window can close while unrelated unknown surfaces still forbid shared quit")
}
do {
    let world = World(); world.onSnapshot = { n in if n == 2 { world.refs = [ref(title: "iPhone SE — iOS 26")] } }
    let output = try world.control.stop(device())
    expect(world.closeIDs.isEmpty && world.quits == 0 && output["warning"] is String, "same native number with changed title is revalidated before any close")
}
do {
    let world = World(); world.failClose = true
    world.onSnapshot = { n in if n == 3 { world.refs = [] } }
    let output = try world.control.stop(device())
    expect(world.quits == 0 && output["warning"] is String, "fresh emptiness never overrides an actual close failure")
}
for change in ["reboot", "inventoryError", "invalidInventory"] {
    let world = World()
    world.onInventory = { n in if n == 3 {
        if change == "reboot" { world.entries[0]["state"] = "Booted" }
        if change == "inventoryError" { world.failInventory = true }
        if change == "invalidInventory" { world.invalidInventory = true }
    } }
    let output = try world.control.stop(device())
    expect(world.closeIDs.isEmpty && world.quits == 0 && output["warning"] is String, "fresh pre-close selected-state query prevents reboot/inventory races")
}
for change in ["otherBooted", "selectedBooted", "inventoryError", "invalidInventory"] {
    let world = World(); world.refs = []
    world.onInventory = { n in if n == 4 {
        if change == "otherBooted" { world.entries.append(["udid": b, "name": "iPhone SE", "state": "Booted", "isAvailable": true]) }
        if change == "selectedBooted" { world.entries[0]["state"] = "Booted" }
        if change == "inventoryError" { world.failInventory = true }
        if change == "invalidInventory" { world.invalidInventory = true }
    } }
    _ = try world.control.stop(device())
    expect(world.quitAttempts == 0 && world.quits == 0, "last device recheck inside launch lock prevents late boot/unreadable inventory before quit")
}
let raceChecks = checks - raceStart

let report: [String: Any] = ["passed": true, "checks": checks, "adapterChecks": adapterChecks, "newRaceChecks": raceChecks, "realDeviceActions": false, "realWindowActions": false, "realAppQuit": false]
if let output = ProcessInfo.processInfo.environment["TEST_OUTPUT"], !output.isEmpty {
    let root = URL(fileURLWithPath: output, isDirectory: true); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: root.appendingPathComponent("device-control-review.json"))
}
print("\(checks) inert device-stop/window/quit policy checks passed")
