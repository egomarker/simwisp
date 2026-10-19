import Foundation
import Darwin

// This executable also acts as the ONLY fake emulator child used by this test.
// It never runs an installed SDK emulator, ADB, Simulator, or live device action.
if CommandLine.arguments.dropFirst().first == "-avd" {
    let env = ProcessInfo.processInfo.environment
    guard let output = env["SIMWISP_ENV_TEST_RECEIPT"], output.hasPrefix("/tmp/simwisp-android-env-tests.") else { exit(96) }
    do {
        let value: [String: Any] = ["reporting": env["ANDROID_EMU_ENABLE_CRASH_REPORTING"] ?? NSNull(),
            "sentinel": env["SIMWISP_ENV_TEST_SENTINEL"] ?? "", "argv": Array(CommandLine.arguments.dropFirst()), "fakeEmulatorOnly": true]
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: URL(fileURLWithPath: output), options: [.atomic])
        exit(0)
    } catch { exit(97) }
}

struct Failure: Error { let message: String }
let folder = CommandLine.arguments[1], red = CommandLine.arguments.contains("--red")
var checks = [[String: Any]](), unexpectedFailure = false
func expect(_ name: String, _ ok: Bool) throws {
    checks.append(["name": name, "passed": ok])
    if !ok { throw Failure(message: name) }
}
func successful() -> CommandResult { CommandResult(status: 0, output: Data(), error: Data()) }
let key = "ANDROID_EMU_ENABLE_CRASH_REPORTING", receiptKey = "SIMWISP_ENV_TEST_RECEIPT", sentinelKey = "SIMWISP_ENV_TEST_SENTINEL"
let names: [String] = [key, receiptKey, sentinelKey]
let original: [(String, String?)] = names.map { name in (name, getenv(name).map { String(cString: $0) }) }
func restore() { for (name, value) in original { if let value { setenv(name, value, 1) } else { unsetenv(name) } } }
let sentinel = "inherited value with spaces = retained"
setenv(sentinelKey, sentinel, 1)
let fake = folder + "/fake emulator"
try FileManager.default.copyItem(atPath: CommandLine.arguments[0], toPath: fake)
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake)

func child(_ mode: DeviceLaunchMode, inherited: String?, index: Int) throws -> [String: Any] {
    if let inherited { setenv(key, inherited, 1) } else { unsetenv(key) }
    let output = folder + "/child-\(index).json"
    setenv(receiptKey, output, 1)
    let control = DeviceControl(adb: nil, simulatorGUI: .none,
        run: { _, _, _ in throw Failure(message: "Unexpected device command") })
    try control.boot("Fixture AVD with spaces", platform: "android", mode: mode, emulator: fake)
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while !FileManager.default.fileExists(atPath: output) && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
    guard let data = FileManager.default.contents(atPath: output), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure(message: "Owned fake-emulator receipt missing") }
    return object
}

do {
    var index = 0
    outer: for inherited in ["1", nil] as [String?] {
        for mode in [DeviceLaunchMode.windowed, .headless] {
            index += 1
            let value = try child(mode, inherited: inherited, index: index)
            let suffix = "\(mode.rawValue), parent=\(inherited ?? "unset")"
            try expect("Child crash reporting is disabled: \(suffix)", value["reporting"] as? String == "0")
            if red { break outer }
            try expect("Unrelated inherited environment survives: \(suffix)", value["sentinel"] as? String == sentinel)
            let flags = mode == .headless ? ["-no-window", "-no-boot-anim", "-gpu", "host"] : ["-no-snapshot-load"]
            try expect("Exact emulator args and space-containing AVD retained: \(suffix)", value["argv"] as? [String] == ["-avd", "Fixture AVD with spaces"] + flags)
            try expect("Parent environment not modified by child launch: \(suffix)", getenv(key).map { String(cString: $0) } == inherited)
            try expect("Only owned local fake emulator executed: \(suffix)", value["fakeEmulatorOnly"] as? Bool == true)
        }
    }
    if !red {
        for mode in [DeviceLaunchMode.windowed, .headless] {
            var spawned = [[String]](), commands = [[String]]()
            let control = DeviceControl(adb: nil, simulatorGUI: .none,
                run: { path, args, _ in commands.append([path] + args); return successful() },
                launch: { path, args in spawned.append([path] + args) })
            try control.boot("Fixture_AVD", platform: "android", mode: mode, emulator: "/fixture SDK/emulator")
            let flags = mode == .headless ? ["-no-window", "-no-boot-anim", "-gpu", "host"] : ["-no-snapshot-load"]
            try expect("Explicit child-scoped env wrapper for \(mode.rawValue)", spawned == [["/usr/bin/env", key + "=0", "/usr/bin/nohup", "/fixture SDK/emulator", "-avd", "Fixture_AVD"] + flags])
            try expect("Android injection adds no device command for \(mode.rawValue)", commands.isEmpty)
            spawned = []
            let id = "00000000-0000-0000-0000-000000000001"
            try control.boot(id, platform: "ios", mode: mode)
            try expect("iOS has no env wrapper/Android child for \(mode.rawValue)", spawned.isEmpty && commands.first == ["/usr/bin/xcrun", "simctl", "boot", id] && commands.count == (mode == .windowed ? 2 : 1))
        }
        var spawned = [[String]]()
        let defaultControl = DeviceControl(adb: nil, simulatorGUI: .none, launch: { path, args in spawned.append([path] + args) })
        try defaultControl.boot("Fixture_AVD", platform: "android", emulator: "/fixture/emulator")
        try expect("Default windowed launch also injects reporting override", spawned == [["/usr/bin/env", key + "=0", "/usr/bin/nohup", "/fixture/emulator", "-avd", "Fixture_AVD", "-no-snapshot-load"]])
        spawned = []
        do { try defaultControl.boot("Fixture_AVD", platform: "android"); try expect("Missing SDK must throw", false) }
        catch { try expect("Missing SDK cannot launch anything", spawned.isEmpty) }
    }
} catch {
    unexpectedFailure = true
    print("FAIL: \((error as? Failure)?.message ?? String(describing: error))")
}
restore()
let passed = !unexpectedFailure && !checks.isEmpty && checks.allSatisfy { $0["passed"] as? Bool == true }
let report: [String: Any] = ["passed": passed, "checks": checks, "localFakeEmulatorOnly": true, "realEmulatorDeviceActions": false, "productBuildOrRestart": false, "environmentRestored": true]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: folder + "/android-crash-env.json"))
print("Android crash-env checks: \(checks.count), passed: \(passed)")
exit(passed ? 0 : 1)
