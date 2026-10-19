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
    var processTarget: AndroidEmulatorProcess?, processAlive = false, processReadFails = false, processSignalRefused = false
    var processSignals: [Int32] = [], signalledPIDs: [pid_t] = []
    var onProcessSignal: ((Int32) -> Void)?, onBeforeSignal: (() -> Void)?, onADBList: (() -> Void)?
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
            }), emulatorProcesses: AndroidEmulatorProcessEffects(resolve: { [unowned self] _ in processTarget },
                isRunning: { [unowned self] target in
                    if processReadFails { throw WispError("fixture process identity unreadable") }
                    return processAlive && processTarget == target
                }, signal: { [unowned self] _, target, number in
                    onBeforeSignal?()
                    guard !processSignalRefused, processAlive, processTarget == target else { return false }
                    processSignals.append(number); signalledPIDs.append(target.pid); onProcessSignal?(number); return true
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
                    onADBList?()
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
// iOS GUI cleanup now follows SimRenderServer policy; see Tests/IOSWindowProcesses.
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
}
do {
    expect(!assemble([], [cg(2, bounds: auxiliaryBounds)], [button, ax(auxiliaryBounds, role: kAXWindowRole, title: "Child window")]).reliable, "child AXWindow evidence overrides coincident auxiliary bounds")
    let proxy = AXUIElementCreateApplication(99998)
    let original = SimulatorWindowRef(id: 1, pid: 901, title: "iPhone 11", bounds: windowBounds, element: proxy)
    let renumbered = SimulatorWindowRef(id: 2, pid: 901, title: "iPhone 11", bounds: windowBounds, element: proxy)
    expect(original.sameWindow(renumbered), "opaque AX identity survives CG number replacement")
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
// Superseded AX-based Stop races are archived with the change evidence.
let raceChecks = 0 // Process-policy races live in Tests/IOSWindowProcesses.

let launchStart = checks
for (body, mode) in [("", DeviceLaunchMode.windowed), ("{}", .windowed), ("{\"mode\":\"windowed\"}", .windowed), ("{\"mode\":\"headless\"}", .headless)] {
    expect(try DeviceLaunchMode.parse(Data(body.utf8)) == mode, "closed launch-mode parser accepts backward-compatible object")
}
for body in ["[]", "null", "{", "{\"mode\":true}", "{\"mode\":1}", "{\"mode\":null}", "{\"mode\":\"HEADLESS\"}", "{\"mode\":\"bad\"}"] {
    do { _ = try DeviceLaunchMode.parse(Data(body.utf8)); expect(false, "invalid launch mode rejected") } catch { expect(true, "invalid launch object rejected before effect") }
}
for mode in [DeviceLaunchMode.windowed, .headless] {
    var commands: [[String]] = [], spawned: [[String]] = []
    let control = DeviceControl(adb: nil, run: { path, args, _ in commands.append([path] + args); return CommandResult(status: 0, output: Data(), error: Data()) }, launch: { path, args in spawned.append([path] + args) })
    try control.boot(a, platform: "ios", mode: mode)
    expect(commands.first == ["/usr/bin/xcrun", "simctl", "boot", a], "iOS boot always targets exact UUID")
    expect(commands.count == (mode == .headless ? 1 : 2), "headless iOS never opens Simulator")
    if mode == .windowed { expect(commands.last == ["/usr/bin/open", "-a", "Simulator", "--args", "-CurrentDeviceUDID", a], "windowed Run retains selected Simulator-window opening") }
    expect(spawned.isEmpty, "iOS never launches Android")
    commands = []
    try control.boot("Pixel_6_API_36", platform: "android", mode: mode, emulator: "/fixture/emulator")
    expect(commands.isEmpty, "Android launch issues no simctl or host input")
    expect(spawned == [["/usr/bin/env", "ANDROID_EMU_ENABLE_CRASH_REPORTING=0", "/usr/bin/nohup", "/fixture/emulator", "-avd", "Pixel_6_API_36"] + (mode == .headless ? ["-no-window", "-no-boot-anim", "-gpu", "host"] : ["-no-snapshot-load"])], "Android launch disables crash reporting in child and preserves mode-specific args")
}
do {
    var calls = 0
    let control = DeviceControl(adb: nil, run: { _, _, _ in calls += 1; return CommandResult(status: 1, output: Data(), error: Data("inert boot failure".utf8)) }, launch: { _, _ in expect(false, "no launch effect") })
    do { try control.boot(a, platform: "ios"); expect(false, "failed boot throws") } catch { expect(calls == 1, "failed boot never opens native window") }
    do { try control.boot("booted", platform: "ios", mode: .headless); expect(false, "invalid selector") } catch { expect(calls == 1, "unvalidated iOS selector never invokes command") }
    do { try control.boot("known-avd", platform: "android", mode: .headless); expect(false, "missing emulator") } catch { expect(calls == 1, "missing emulator fails without host actions") }
}
let launchChecks = checks - launchStart

// The real regression: ADB acknowledges "emu kill" but the host emulator
// remains alive. Every process/command/signal effect below is inert.
let fallbackStart = checks
let fallbackDevice = Device(id: "emulator-5554", name: "Pixel 6 API 36", platform: "android", width: 0, height: 0, avd: "Pixel_6_API_36")
let fixtureEmulator = "/fixture/sdk/emulator/emulator"
func emulatorProcess(pid: pid_t = 4242, start: UInt64 = 100, uid: uid_t = geteuid(), executable: String = "/fixture/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64-headless", args: [String] = ["emulator", "-avd", "Pixel_6_API_36", "-no-window"]) -> AndroidEmulatorProcess {
    AndroidEmulatorProcess(pid: pid, uid: uid, startSeconds: start, startMicroseconds: 42, executable: executable, arguments: args)
}
func hungEmulator() -> World {
    let world = World(); world.neverRemoveADB = true; world.processTarget = emulatorProcess(); world.processAlive = true; return world
}
for exitSignal in [SIGTERM, SIGKILL] {
    let world = hungEmulator()
    world.onProcessSignal = { signal in if signal == exitSignal { world.processAlive = false; world.android.removeAll { $0 == fallbackDevice.id } } }
    let output = try world.control.stop(fallbackDevice)
    expect(output["state"] as? String == "stopped", "hung emulator is confirmed stopped after fallback")
    expect(world.processSignals == (exitSignal == SIGTERM ? [SIGTERM] : [SIGTERM, SIGKILL]), "one TERM then at most one KILL; never kill after graceful exit")
    expect(world.signalledPIDs.allSatisfy { $0 == 4242 } && world.android == ["emulator-5556"], "signals/ADB affect only selected emulator, not second device or crashpad")
    expect(world.commands.filter { $0.contains("kill") }.count == 1, "fallback never resends adb emu kill")
    expect(world.time == (exitSignal == SIGTERM ? 8 : 10), "bounded grace before escalating")
    expect((output["forced"] as? Bool == true) == (exitSignal == SIGKILL), "forced shutdown explicitly reported")
    if exitSignal == SIGKILL { expect(output["warning"] is String, "force-stop warns about unsaved state") }
    expect(world.snapshots == 0 && world.quits == 0 && world.closeIDs.isEmpty, "Android process fallback never touches iOS GUI")
}
do {
    let world = hungEmulator(); world.neverRemoveADB = false; world.onADBList = { world.processAlive = false }
    expect((try world.control.stop(fallbackDevice))["state"] as? String == "stopped" && world.processSignals.isEmpty, "normal shutdown never sends host signals")
}
do {
    let world = hungEmulator(); world.neverRemoveADB = false
    world.onProcessSignal = { _ in world.processAlive = false }
    expect((try world.control.stop(fallbackDevice))["state"] as? String == "stopped" && world.processSignals == [SIGTERM], "ADB absence alone is not success while identified host process survives")
    expect(world.time == 8, "host process receives full normal shutdown grace even after ADB disconnect")
}
do {
    let world = hungEmulator(); let output = try world.control.stop(fallbackDevice)
    expect(output["state"] as? String == "pending" && output["window_closed"] as? Bool == false, "no false success if force-stop still unconfirmed")
    expect(world.processSignals == [SIGTERM, SIGKILL] && world.time == 13, "hung fallback has strict 8+2+3 second budget and two signals maximum")
    let calls = world.commands.count
    expect((try world.control.androidStopStatus(fallbackDevice.id))["state"] as? String == "pending", "GET confirmation remains read-only")
    expect(world.processSignals.count == 2 && world.commands.count == calls + 1, "refresh never repeats fallback signals")
    world.android.removeAll { $0 == fallbackDevice.id }
    expect((try world.control.androidStopStatus(fallbackDevice.id))["state"] as? String == "pending", "GET still waits for host process when ADB disappears")
    world.processAlive = false
    expect((try world.control.androidStopStatus(fallbackDevice.id))["state"] as? String == "stopped", "GET confirms only after ADB and process exit")
}
for problem in ["noIdentity", "identityUnreadable", "signalRefused", "reusedPID", "reusedPort"] {
    let world = hungEmulator()
    if problem == "noIdentity" { world.processTarget = nil }
    if problem == "identityUnreadable" { world.processReadFails = true }
    if problem == "signalRefused" { world.processSignalRefused = true }
    if problem == "reusedPID" { world.onBeforeSignal = { world.processTarget = emulatorProcess(start: 200) } }
    if problem == "reusedPort" { world.onBeforeSignal = { world.processTarget = emulatorProcess(pid: 4243) } }
    let output = try world.control.stop(fallbackDevice)
    expect(output["state"] as? String == "pending" && output["warning"] is String, "\(problem) fails closed with explanation")
    expect(world.processSignals.isEmpty && world.android == ["emulator-5554", "emulator-5556"], "\(problem) cannot signal any process")
}
do {
    let world = hungEmulator()
    world.onProcessSignal = { _ in world.processTarget = emulatorProcess(start: 200) }
    expect((try world.control.stop(fallbackDevice))["state"] as? String == "pending", "process replaced after TERM stays pending")
    expect(world.processSignals == [SIGTERM], "PID replacement between TERM and KILL cannot receive KILL")
}
do {
    let world = hungEmulator(); world.onProcessSignal = { _ in world.processAlive = false }
    expect((try world.control.stop(fallbackDevice))["state"] as? String == "pending", "process exit with lingering ADB transport is not success")
    expect(world.processSignals == [SIGTERM], "already exited process is not force-killed")
}
do {
    let world = hungEmulator(); world.failADB = true
    world.onProcessSignal = { _ in world.processAlive = false; world.android.removeAll { $0 == fallbackDevice.id } }
    expect((try world.control.stop(fallbackDevice))["state"] as? String == "stopped" && world.processSignals == [SIGTERM], "failed console command still permits safely identified local fallback")
}
// Test the production native adapter's parsing/allowlist without host signals.
expect(try NativeAndroidEmulatorProcess.listeningPID("p4242\nf39\nn127.0.0.1:5554\nf42\nn[::1]:5554\n", port: 5554) == 4242, "dual-stack console uniquely identifies one PID")
expect(try NativeAndroidEmulatorProcess.listeningPID("", port: 5554) == nil, "empty listener inventory has no owner")
for malformed in ["p4242\nn127.0.0.1:5554\np4243\nn[::1]:5554", "p4242\nn127.0.0.1:55540", "p4242\nn*:5554", "p0\nn127.0.0.1:5554", "p1\nn127.0.0.1:5554", "p-9\nn127.0.0.1:5554", "n127.0.0.1:5554", "p4242", "unexpected"] {
    do { _ = try NativeAndroidEmulatorProcess.listeningPID(malformed, port: 5554); expect(false, "ambiguous/malformed console owner") } catch { expect(true, "unsafe console owner refused") }
}
expect(NativeAndroidEmulatorProcess.matches(emulatorProcess(), device: fallbackDevice, emulator: fixtureEmulator), "exact configured-SDK qemu/AVD/user accepted")
for bad in [emulatorProcess(uid: geteuid() + 1), emulatorProcess(executable: "/other/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64-headless"), emulatorProcess(executable: "/fixture/sdk/emulator/crashpad_handler"), emulatorProcess(executable: "/fixture/sdk/platform-tools/adb"), emulatorProcess(args: ["qemu", "-avd", "Pixel_6_API_360"]), emulatorProcess(args: ["qemu", "-avd", "Pixel_6_API_36", "-avd", "Other"]), emulatorProcess(args: ["qemu", "-avd"])] {
    expect(!NativeAndroidEmulatorProcess.matches(bad, device: fallbackDevice, emulator: fixtureEmulator), "wrong SDK/user/AVD or non-qemu process rejected; crashpad never selected")
}
for bad in [device("physical-123", platform: "android"), device("emulator-5554", platform: "android"), device()] {
    expect(!NativeAndroidEmulatorProcess.matches(emulatorProcess(), device: bad, emulator: fixtureEmulator), "physical/iOS/unknown-AVD device cannot authorize process fallback")
}
for arch in ["aarch64", "x86_64"] { for suffix in ["", "-headless"] {
    let value = emulatorProcess(executable: "/fixture/sdk/emulator/qemu/darwin-\(arch)/qemu-system-\(arch)\(suffix)")
    expect(NativeAndroidEmulatorProcess.matches(value, device: fallbackDevice, emulator: fixtureEmulator), "windowed/headless known qemu binary accepted")
} }
func argvData(_ argv: [String], environment: String = "SECRET=not-an-argument") -> Data {
    var count = Int32(argv.count); var data = withUnsafeBytes(of: &count) { Data($0) }
    data.append(Data("/fixture/emulator\0\0\0".utf8)); data.append(Data((argv.joined(separator: "\0") + "\0" + environment + "\0").utf8)); return data
}
let argv = ["qemu", "-avd", "AVD name with spaces", "", "-no-window"]
expect(try NativeAndroidEmulatorProcess.arguments(argvData(argv)) == argv, "native argv parser handles spaces/empty args and excludes environment")
for malformed in [Data(), Data([0, 0, 0, 0, 0]), Data([2, 0, 0, 0, 65]), Data(argvData(["qemu", "-avd"]).prefix(10))] {
    do { _ = try NativeAndroidEmulatorProcess.arguments(malformed); expect(false, "invalid argv buffer") } catch { expect(true, "invalid argv buffer refused") }
}
if let own = try NativeAndroidEmulatorProcess.read(getpid()) {
    expect(own.pid == getpid() && own.uid == geteuid() && !own.arguments.isEmpty, "native adapter reads only this inert test process identity")
    expect(try NativeAndroidEmulatorProcess.read(getpid()) == own, "same PID start-time/path/argv identity stable")
    expect(!NativeAndroidEmulatorProcess.matches(own, device: fallbackDevice, emulator: fixtureEmulator), "test process can never masquerade as emulator")
} else { expect(false, "test process identity must be readable") }
let fallbackChecks = checks - fallbackStart

let report: [String: Any] = ["passed": true, "checks": checks, "adapterChecks": adapterChecks, "newRaceChecks": raceChecks, "launchChecks": launchChecks, "androidFallbackChecks": fallbackChecks, "realDeviceActions": false, "realWindowActions": false, "realAppQuit": false]
if let output = ProcessInfo.processInfo.environment["TEST_OUTPUT"], !output.isEmpty {
    let root = URL(fileURLWithPath: output, isDirectory: true); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: root.appendingPathComponent("device-control-review.json"))
}
print("\(checks) inert device-stop/window/quit policy checks passed")
