import Foundation
import AppKit
let id = "00000000-0000-4000-8000-000000000081"
let other = "00000000-0000-4000-8000-000000000082"
let app = SimulatorApplicationRef(pid: 901, launchedAt: 12)
var checks: [[String: Any]] = []
func check(_ name: String, _ condition: Bool) { checks.append(["name": name, "passed": condition]); if !condition { print("FAIL: " + name) } }
final class World {
    var renderers = false, apps = [app], state = "Booted", otherHeadless = false, now = 0.0
    var reads = 0, appReads = 0, closes: [SimulatorApplicationRef] = [], waits: [Double] = [], commands: [[String]] = [], events: [String] = [], launches: [[String]] = []
    var refuse = false, failRead = false, rebootGUI = false
    var onRead: ((World) -> Void)?, onWait: ((World) -> Void)?
    let tracker = DeviceLaunches()
    var control: DeviceControl!
    init() {
        let gui = SimulatorGUIEffects(hasWindowed: { [unowned self] in
            reads += 1; events.append("renderer-read"); onRead?(self)
            if failRead { throw WispError("inert renderer inventory failure") }; return renderers
        }, applications: { [unowned self] in appReads += 1; return apps }, closeApplication: { [unowned self] target, timeout in
            precondition(timeout > 0 && timeout <= 8); closes.append(target); events.append("close-GUI")
            if refuse { return false }; apps.removeAll { $0 == target }; renderers = false; return true
        })
        let forbiddenAX = SimulatorWindowEffects(snapshot: { fatalError("AX snapshot forbidden in new process-policy tests") }, close: { _ in fatalError("Per-window AX close forbidden") }, quitIfEmpty: { _ in fatalError("Old AX quit gate forbidden") })
        control = DeviceControl(adb: nil, launches: tracker, windows: forbiddenAX, simulatorGUI: gui,
            run: { [unowned self] path, args, _ in
                commands.append([path] + args)
                if args == ["simctl", "list", "devices", "--json"] {
                    var entries: [[String: Any]] = [["udid": id, "name": "Inert iPhone", "state": state, "isAvailable": true]]
                    if otherHeadless { entries.append(["udid": other, "name": "Other headless device", "state": "Booted", "isAvailable": true]) }
                    return CommandResult(status: 0, output: try JSONSerialization.data(withJSONObject: ["devices": ["inert": entries]]), error: Data())
                }
                if args == ["simctl", "shutdown", id] { state = "Shutdown"; events.append("shutdown") }
                else if args == ["simctl", "boot", id] { events.append("boot"); if rebootGUI { apps = [SimulatorApplicationRef(pid: 902, launchedAt: 13)] } }
                else { precondition(path == "/usr/bin/open") }
                return CommandResult(status: 0, output: Data(), error: Data())
            }, launch: { [unowned self] path, args in launches.append([path] + args) },
            wait: { [unowned self] seconds in waits.append(seconds); now += seconds; events.append("pause"); onWait?(self) }, clock: { [unowned self] in now })
    }
    func stop() throws -> [String: Any] { try control.stop(Device(id: id, name: "Inert iPhone", platform: "ios", width: 400, height: 800)) }
    func boot(consent: Bool = false, platform: String = "ios", mode: DeviceLaunchMode = .headless, selector: String = id) throws { try control.boot(selector, platform: platform, mode: mode, emulator: "/fixture/emulator", quitSimulatorConfirmed: consent) }
}
func rejected(_ name: String, _ body: () throws -> Void) { do { try body(); check(name, false) } catch { check(name, true) } }
if !CommandLine.arguments.contains("--refresh-only") {
do {
    let w = World(); w.otherHeadless = true; let result = try w.stop()
    check("last windowed Stop pauses then checks renderer before GUI close", w.events == ["shutdown", "pause", "renderer-read", "renderer-read", "close-GUI"])
    check("last windowed Stop closes GUI even with other headless device booted", w.closes == [app] && result["simulator_quit_requested"] as? Bool == true)
    check("Stop uses one300ms pause, no background poll", w.waits == [0.3] && w.reads == 2)
    check("Stop reports process-policy quit reason", result["simulator_quit_reason"] as? String == "quit_requested")
}
do {
    let w = World(); w.renderers = true; let result = try w.stop()
    check("remaining windowed renderer keeps Simulator alive", w.closes.isEmpty && w.apps == [app] && result["simulator_quit_reason"] as? String == "windowed_simulators_remain")
}
do {
    let w = World(); w.renderers = true; w.onWait = { $0.renderers = false }; _ = try w.stop()
    check("renderer disappearance during pause enables last-window GUI cleanup", w.closes == [app])
}
do {
    let w = World(); w.onRead = { if $0.reads == 2 { $0.renderers = true } }; let result = try w.stop()
    check("renderer appearing at final check blocks automatic GUI close", w.closes.isEmpty && result["simulator_quit_reason"] as? String == "windowed_simulators_appeared")
}
do {
    let w = World(); w.tracker.begin(); let result = try w.stop(); w.tracker.end()
    check("pending launch still blocks automatic Stop-time GUI close", w.closes.isEmpty && result["simulator_quit_reason"] as? String == "launch_pending")
}
do {
    let w = World(); w.failRead = true; let result = try w.stop()
    check("failed process query warns without guessing zero windows", w.closes.isEmpty && result["warning"] is String && w.state == "Shutdown")
}
do {
    let w = World(); w.refuse = true; let result = try w.stop()
    check("Stop GUI refusal warns without force kill or repeat", w.closes == [app] && result["warning"] is String && result["simulator_quit_requested"] as? Bool == false)
}
do {
    let w = World(); w.renderers = true
    rejected("Headless with renderer and no consent has no destructive effects") { try w.boot() }
    check("missing consent never quits GUI or boots", w.closes.isEmpty && w.commands.isEmpty)
}
do {
    let w = World(); w.renderers = true; try w.boot(consent: true)
    check("confirmed Headless closes whole GUI before boot", w.events == ["renderer-read", "close-GUI", "boot"] && w.closes == [app])
    check("Headless never opens Simulator.app", !w.commands.contains { $0.first == "/usr/bin/open" })
}
do {
    let w = World(); try w.boot()
    check("empty leftover GUI closes without renderer consent", w.closes == [app] && w.events.last == "boot")
}
do {
    let w = World(); w.apps = []; try w.boot()
    check("no GUI and no renderer starts Headless without quit", w.closes.isEmpty && w.events == ["renderer-read", "boot"])
}
do {
    let w = World(); w.refuse = true
    rejected("Headless aborts if GUI exit not confirmed") { try w.boot(consent: true) }
    check("GUI refusal does not continue to simctl boot", w.closes == [app] && w.commands.isEmpty)
}
do {
    let w = World(); w.rebootGUI = true
    rejected("Headless detects GUI reopening during boot") { try w.boot(consent: true) }
    check("GUI reopening never causes repeated quit or boot", w.closes.count == 1 && w.commands.count == 1)
}
do {
    let w = World(); rejected("invalid UUID rejected before GUI effects") { try w.boot(consent: true, selector: "all") }
    check("invalid selector never queries or closes GUI", w.reads == 0 && w.closes.isEmpty)
}
do {
    let w = World(); w.renderers = true; try w.boot(platform: "android", selector: "Pixel_fixture")
    check("Android Headless never checks or closes iOS GUI", w.reads == 0 && w.closes.isEmpty && w.launches == [["/usr/bin/nohup", "/fixture/emulator", "-avd", "Pixel_fixture", "-no-window", "-no-boot-anim", "-gpu", "host"]])
}
do {
    let w = World(); w.renderers = true; try w.boot(mode: .windowed)
    check("ordinary iOS Run does not query renderers or quit GUI", w.reads == 0 && w.closes.isEmpty && w.commands.last?.first == "/usr/bin/open")
}
for raw in ["1", "0", "\"true\"", "null", "[]", "{}"] {
    rejected("consent rejects nonboolean " + raw) { _ = try DeviceLaunchMode.quitConsent(Data(("{\"close_simulator\":" + raw + "}").utf8)) }
}
check("consent accepts true only as a JSON boolean", try DeviceLaunchMode.quitConsent(Data("{\"close_simulator\":true}".utf8)))
check("absent or false consent remains false", try !DeviceLaunchMode.quitConsent(Data()) && !DeviceLaunchMode.quitConsent(Data("{\"close_simulator\":false}".utf8)))
}
// Explicit refresh must reconcile an old windowed intent after confirmed GUI exit.
do {
    var settings = Settings(); settings.projectDirectory = "/inert-no-project"; settings.androidSDK = "/inert-no-sdk"
    var discovered: [Device] = []
    let emptyWindows = SimulatorWindowEffects(snapshot: { SimulatorWindowSnapshot(applications: [], windows: [], reliable: true) }, close: { _ in fatalError() }, quitIfEmpty: { _ in fatalError() })
    let control = DeviceControl(adb: nil, windows: emptyWindows)
    let devices = Devices(settings: settings, control: control, discovery: { (discovered, discovered.isEmpty ? [["id": id, "name": "Inert iPhone", "platform": "ios"]] : [], [:]) }, boot: { _, _ in discovered = [Device(id: id, name: "Inert iPhone", platform: "ios", width: 400, height: 800)] })
    func refresh() { let done = DispatchSemaphore(value: 0); devices.requestRefresh { done.signal() }; precondition(done.wait(timeout: .now() + 3) == .success) }
    refresh(); try devices.boot(id, mode: .windowed); refresh()
    check("fresh explicit discovery replaces stale requested windowed flag after GUI exit", devices.device(id)?.headless == true)
    devices.stop()
}
let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
try JSONSerialization.data(withJSONObject: ["passed": passed, "checks": checks, "real_device_actions": false, "real_window_actions": false, "real_input": false, "app_restart": false, "processSignal": "SimRenderServer"], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("native.json"))
print("Process-policy native checks: \(checks.count), passed: \(passed)"); exit(passed ? 0 : 1)
