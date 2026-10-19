import Foundation
import AppKit
import ApplicationServices

// NEW focused suite: real production Stop/AX-CG adapter; every command, AX
// close, quit and wait is inert. No process/device lookup, host permission,
// application launch, live capture, input or clock sleep is performed.
let selectedID = "00000000-0000-4000-8000-000000000091"
let otherID = "00000000-0000-4000-8000-000000000092"
let frame = CGRect(x: 20, y: 30, width: 443, height: 924)
func window(_ id: UInt32 = 91, title: String = "Inert iPhone", bounds: CGRect = frame) -> SimulatorWindowRef {
    SimulatorWindowRef(id: id, pid: 901, title: title, bounds: bounds)
}
var checks: [[String: Any]] = []
func check(_ name: String, _ value: Bool) { checks.append(["name": name, "passed": value]); if !value { print("FAIL: " + name) } }

final class World {
    var state = "Booted", extraState: String?, extraName = "Another device"
    var refs = [window()], apps: [pid_t] = [901]
    var now = 0.0, closedAt: Double?, settleDelay = 0.2
    var autoClose = false, closePending = false, failClose = false, quitRefused = false, neverShutdown = false
    var snapshotFailsAfterClose = false, failInventoryAt: Int?
    var commands: [[String]] = [], waits: [Double] = [], closes = 0, quits = 0, inventories = 0, snapshots = 0
    var quitTimes: [Double] = [], onWait: ((World) -> Void)?, onClose: ((World) -> Void)?
    var onInventory: ((World, Int) -> Void)?, onSnapshot: ((World, Int) -> Void)?, onQuit: ((World) -> Void)?
    let launches = DeviceLaunches()
    var control: DeviceControl!
    init() {
        control = DeviceControl(adb: nil, launches: launches,
            windows: SimulatorWindowEffects(snapshot: { [unowned self] in try snapshot() },
                close: { [unowned self] target in
                    closes += 1; onClose?(self)
                    if failClose { throw WispError("inert close refusal") }
                    guard refs.contains(where: { target.stillIdentifies($0) }) else { throw WispError("inert identity changed") }
                    if !closePending { refs.removeAll { target.sameWindow($0) }; closedAt = now }
                }, quitIfEmpty: { [unowned self] pid in
                    quits += 1; quitTimes.append(now); onQuit?(self)
                    let fresh = try snapshot()
                    return !quitRefused && fresh.reliable && fresh.windows.isEmpty && fresh.applications == [pid]
                }),
            run: { [unowned self] path, args, _ in
                commands.append([path] + args)
                guard path == "/usr/bin/xcrun" else { throw WispError("Unexpected non-fixture command") }
                if args == ["simctl", "list", "devices", "--json"] {
                    inventories += 1; onInventory?(self, inventories)
                    if failInventoryAt == inventories { throw WispError("inert inventory failure") }
                    var devices: [[String: Any]] = [["udid": selectedID, "name": "Inert iPhone", "state": state, "isAvailable": true]]
                    if let extraState { devices.append(["udid": otherID, "name": extraName, "state": extraState, "isAvailable": true]) }
                    return CommandResult(status: 0, output: try JSONSerialization.data(withJSONObject: ["devices": ["inert": devices]]), error: Data())
                }
                guard args == ["simctl", "shutdown", selectedID] else { throw WispError("Unexpected non-fixture action") }
                if !neverShutdown { state = "Shutdown" }
                if autoClose { refs.removeAll { $0.id == 91 }; closedAt = now }
                return CommandResult(status: 0, output: Data(), error: Data())
            }, launch: { _, _ in throw WispError("Launch forbidden in quit tests") },
            wait: { [unowned self] seconds in waits.append(seconds); now += seconds; onWait?(self) }, clock: { [unowned self] in now })
    }
    func snapshot() throws -> SimulatorWindowSnapshot {
        snapshots += 1; onSnapshot?(self, snapshots)
        if snapshotFailsAfterClose && closedAt != nil { throw WispError("inert native metadata failure") }
        func cg(_ id: UInt32, _ bounds: CGRect, title: String? = nil, onscreen: Bool = false) -> [String: Any] {
            var row: [String: Any] = [kCGWindowOwnerPID as String: NSNumber(value: 901), kCGWindowNumber as String: NSNumber(value: id), kCGWindowBounds as String: bounds.dictionaryRepresentation, kCGWindowLayer as String: 8, kCGWindowIsOnscreen as String: onscreen]
            if let title { row[kCGWindowName as String] = title }; return row
        }
        var surfaces = refs.map { cg($0.id, $0.bounds, title: $0.title) }
        if let closedAt, now - closedAt + 0.0000001 < settleDelay { surfaces.append(cg(800, frame)) }
        let menuFrame = CGRect(x: 0, y: 0, width: 1920, height: 24)
        let auxiliary = apps.isEmpty ? [] : [SimulatorWindowAdapter.AXRecord(role: kAXMenuBarRole, title: "", bounds: menuFrame)]
        if !apps.isEmpty { surfaces += (810...813).map { cg(UInt32($0), menuFrame) } }
        let result = SimulatorWindowAdapter.assemble(pid: 901,
            windows: refs.map { SimulatorWindowAdapter.AXRecord(role: kAXWindowRole, title: $0.title, bounds: $0.bounds) }, surfaces: surfaces, auxiliary: auxiliary)
        return SimulatorWindowSnapshot(applications: apps, windows: result.windows, reliable: result.reliable, selectionReliable: result.selectionReliable)
    }
    func stop(_ label: String) throws -> [String: Any] {
        let result = try control.stop(Device(id: selectedID, name: "Inert iPhone", platform: "ios", width: 443, height: 924))
        check(label + ": shutdown sent at most once and exact UUID only", commands.filter { $0.contains("shutdown") }.count <= 1 && commands.allSatisfy { $0 == ["/usr/bin/xcrun", "simctl", "shutdown", selectedID] || $0 == ["/usr/bin/xcrun", "simctl", "list", "devices", "--json"] })
        check(label + ": original four-wait budget only; close/quit never resent", waits.count <= 4 && waits.allSatisfy { $0 == 0.1 } && closes <= 1 && quits <= 1)
        check(label + ": structured bounded quit reason returned", (result["simulator_quit_reason"] as? String).map { !$0.isEmpty && $0 != "not_checked" } == true)
        return result
    }
}
func reason(_ result: [String: Any], _ name: String) -> Bool { result["simulator_quit_reason"] as? String == name }
func requested(_ result: [String: Any]) -> Bool { result["simulator_quit_requested"] as? Bool == true }

for (label, automatic, delay) in [("AX close before CG retirement", false, 0.2), ("shutdown auto-close before CG retirement", true, 0.3), ("retirement at existing budget boundary", false, 0.4)] {
    let w = World(); w.autoClose = automatic; w.settleDelay = delay; let out = try w.stop(label)
    check(label + ": strict complete emptiness eventually requests one normal quit", requested(out) && reason(out, "quit_requested") && out["window_closed"] as? Bool == true && out["warning"] == nil && w.quits == 1)
    check(label + ": no quit ahead of compositor retirement", w.quitTimes == [w.now] && w.now + 0.0000001 >= delay && w.now <= 0.4000001 && w.closes == (automatic ? 0 : 1))
}
do {
    let w = World(); w.autoClose = true; w.settleDelay = .infinity; let out = try w.stop("persistent unknown compositor")
    check("persistent unknown is never reclassified as harmless", !requested(out) && w.quits == 0 && reason(out, "window_inventory_incomplete") && out["warning"] is String)
    check("persistent unknown returns at old budget without retained retry", w.waits.count == 4 && abs(w.now - 0.4) < 0.000001 && out["window_closed"] as? Bool == true)
}
do {
    let w = World(); w.closePending = true; let out = try w.stop("AX close never completes")
    check("unconfirmed close blocks quit and explains why", reason(out, "window_close_unconfirmed") && !requested(out) && out["window_closed"] as? Bool == false && out["warning"] is String && w.refs.count == 1 && w.waits.count == 4)
}
do {
    let w = World(); w.failClose = true; w.onClose = { $0.refs = []; $0.closedAt = -1 }; let out = try w.stop("refused close then fresh empty")
    check("actual close failure remains terminal despite later reliable emptiness", reason(out, "window_close_failed") && !requested(out) && w.quits == 0 && out["warning"] is String && w.waits.isEmpty)
}
do {
    let w = World(); w.onWait = { world in if world.waits.count == 1 { world.launches.begin() } }; let out = try w.stop("launch admitted during settling")
    check("settling cannot bypass pending-launch lock", reason(out, "launch_pending") && !requested(out) && w.quits == 0)
    w.launches.end()
}
for state in ["Booted", "Booting", "ShuttingDown", "Unknown"] {
    let w = World(); w.extraState = state; let out = try w.stop("settling beside " + state)
    check("other " + state + " device blocks shared quit after settling", reason(out, "devices_active") && !requested(out) && w.quits == 0 && w.extraState == state)
}
for title in ["Minimized device", "Hidden device", "Other Space", "Simulator Settings"] {
    let w = World(); let other = window(92, title: title, bounds: CGRect(x: -2000, y: -900, width: 300, height: 600)); w.refs.append(other)
    let out = try w.stop("settling beside " + title)
    check(title + " remains in all-window inventory and untouched", reason(out, "windows_remain") && !requested(out) && w.quits == 0 && w.refs == [other])
}
do {
    let w = World(); w.onWait = { world in if world.waits.count == 1 { world.refs.append(window(93, title: "Late window", bounds: CGRect(x: -600, y: 20, width: 200, height: 400))) } }
    let out = try w.stop("window appears during settling")
    check("new window during settle blocks quit without closing it", reason(out, "windows_remain") && !requested(out) && w.quits == 0 && w.refs.map(\.id) == [93])
}
for selected in [false, true] {
    let w = World(); w.onInventory = { world, count in if count == 5 { if selected { world.state = "Booted" } else { world.extraState = "Booting" } } }
    let out = try w.stop(selected ? "selected reboots inside launch guard" : "other device boots inside launch guard")
    check("last inventory inside launch lock remains authoritative \(selected)", reason(out, "device_state_changed") && !requested(out) && w.quits == 0 && out["warning"] is String)
}
for lastChange in ["window", "application", "refusal"] {
    let w = World(); w.onQuit = { world in
        if lastChange == "window" { world.refs.append(window(94, title: "Native-last-moment window")) }
        if lastChange == "application" { world.apps = [902] }
        if lastChange == "refusal" { world.quitRefused = true }
    }
    let out = try w.stop("native recheck " + lastChange)
    check("native recheck/refusal never escalates or claims requested " + lastChange, reason(out, "native_recheck_or_quit_refused") && !requested(out) && w.quits == 1 && out["warning"] is String)
}
do {
    let w = World(); w.apps = [901, 902]; let out = try w.stop("multiple apps after settling")
    check("multiple Simulator identities still block quit", reason(out, "multiple_simulator_apps") && !requested(out) && w.quits == 0)
}
do {
    let w = World(); w.snapshotFailsAfterClose = true; let out = try w.stop("metadata fails after close")
    check("native read failure fails closed without later quit", reason(out, "window_inventory_incomplete") && !requested(out) && w.quits == 0 && out["warning"] is String)
}
do {
    let w = World(); w.failInventoryAt = 4; let out = try w.stop("device inventory fails after settling")
    check("inventory error after successful settling blocks quit", reason(out, "device_inventory_incomplete") && !requested(out) && w.quits == 0 && out["warning"] is String)
}
do {
    let w = World(); w.refs = []; let out = try w.stop("already windowless with corroborated menus")
    check("headless last-device Stop requests normal quit without AX action", requested(out) && reason(out, "quit_requested") && w.closes == 0 && w.waits.isEmpty && out["window_closed"] as? Bool == false)
}
do {
    let w = World(); w.refs = []; w.apps = []; let out = try w.stop("Simulator app already absent")
    check("absent GUI is never opened, quit or artificially waited", reason(out, "simulator_not_running") && !requested(out) && w.closes == 0 && w.quits == 0 && w.waits.isEmpty)
}
do {
    let w = World(); w.autoClose = true; w.extraState = "Shutdown"; w.extraName = "Inert iPhone"; let out = try w.stop("initial duplicate identity resolves by shutdown")
    check("complete empty settlement resolves initial ambiguity without guessing close", requested(out) && reason(out, "quit_requested") && w.closes == 0 && out["warning"] == nil)
}
do {
    let w = World(); w.neverShutdown = true
    do { _ = try w.stop("unconfirmed shutdown"); check("unconfirmed shutdown rejected", false) }
    catch { check("unconfirmed shutdown rejected before window effects", w.closes == 0 && w.quits == 0 && w.waits.isEmpty) }
}
let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
let report: [String: Any] = ["passed": passed, "checks": checks, "newFocusedSuite": true, "productionStopAndAdapter": true, "real_device_actions": false, "real_window_actions": false, "real_input": false, "new_timer": false, "background_polling": false, "app_build": false, "app_restart": false]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("simulator-quit.json"))
print("Simulator quit focused checks: \(checks.count), passed: \(passed)")
exit(passed ? 0 : 1)
