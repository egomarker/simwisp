import Foundation
import AppKit
import ApplicationServices

enum DeviceLaunchMode: String {
    case windowed, headless
    static func parse(_ body: Data) throws -> Self {
        if body.isEmpty { return .windowed } // Existing empty POST remains windowed.
        guard let value = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw WispError("Expected a launch object") }
        guard let raw = value["mode"] else { return .windowed }
        guard let name = raw as? String, let mode = Self(rawValue: name) else { throw WispError("Launch mode must be windowed or headless") }
        return mode
    }
}

// Only explicit device actions use this tracker. No discovery/idle timer.
final class DeviceLaunches {
    private let lock = NSLock()
    private var pending = 0
    func begin() { lock.withLock { pending += 1 } }
    func end() { lock.withLock { pending = max(0, pending - 1) } }
    func ifIdle(_ action: () throws -> Bool) rethrows -> Bool {
        try lock.withLock { guard pending == 0 else { return false }; return try action() }
    }
}
struct SimulatorEntry: Decodable {
    let udid: String, name: String, state: String
    let isAvailable: Bool?
}
struct SimulatorInventory: Decodable {
    let devices: [String: [SimulatorEntry]]
    var all: [SimulatorEntry] { devices.values.flatMap { $0 } }
    var idle: Bool { all.allSatisfy { $0.state == "Shutdown" } }
}
struct SimulatorWindowRef: Equatable {
    let id: CGWindowID, pid: pid_t
    let title: String
    let bounds: CGRect
    // Keep the actual AX identity through shutdown. A reused CG number/title
    // must never authorize closing a newly created window.
    let element: AXUIElement?
    init(id: CGWindowID, pid: pid_t, title: String, bounds: CGRect, element: AXUIElement? = nil) {
        self.id = id; self.pid = pid; self.title = title; self.bounds = bounds; self.element = element
    }
    func sameWindow(_ current: SimulatorWindowRef) -> Bool {
        guard pid == current.pid else { return false }
        switch (element, current.element) {
        case let (a?, b?): return CFEqual(a, b)
        case (nil, nil): return id == current.id // inert policy fixtures only
        default: return false
        }
    }
    func stillIdentifies(_ current: SimulatorWindowRef) -> Bool { sameWindow(current) && title == current.title }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.stillIdentifies(rhs) && lhs.bounds == rhs.bounds }
}
struct SimulatorWindowSnapshot {
    let applications: [pid_t]
    let windows: [SimulatorWindowRef]
    let reliable: Bool
    // A complete AX list can identify one window even if an unrelated CG
    // surface is unknown. Such a surface still blocks shared-app quitting.
    let selectionReliable: Bool
    init(applications: [pid_t], windows: [SimulatorWindowRef], reliable: Bool, selectionReliable: Bool? = nil) {
        self.applications = applications; self.windows = windows; self.reliable = reliable
        self.selectionReliable = selectionReliable ?? reliable
    }
}
struct SimulatorWindowEffects {
    let snapshot: () throws -> SimulatorWindowSnapshot
    let close: (SimulatorWindowRef) throws -> Void
    let quitIfEmpty: (pid_t) throws -> Bool
    static var live: Self {
        Self(snapshot: { try NativeSimulatorWindows.snapshot() }, close: { try NativeSimulatorWindows.close($0) }, quitIfEmpty: { try NativeSimulatorWindows.quitIfEmpty($0) })
    }
}

// A console port selects a local emulator; a PID alone or an AVD name does not.
// Capture start time before asking ADB to stop, then revalidate before each signal.
struct AndroidEmulatorProcess: Equatable {
    let pid: pid_t, uid: uid_t
    let startSeconds: UInt64, startMicroseconds: UInt64
    let executable: String, arguments: [String]
}
struct AndroidEmulatorProcessEffects {
    let resolve: (Device) throws -> AndroidEmulatorProcess?
    let isRunning: (AndroidEmulatorProcess) throws -> Bool
    let signal: (Device, AndroidEmulatorProcess, Int32) throws -> Bool
    // Injected controllers/fixtures never acquire live process authority implicitly.
    static let none = Self(resolve: { _ in nil }, isRunning: { _ in false }, signal: { _, _, _ in false })
    static func live(emulator: String?) -> Self {
        guard let emulator else { return .none }
        return Self(resolve: { try NativeAndroidEmulatorProcess.resolve($0, emulator: emulator) },
                    isRunning: { try NativeAndroidEmulatorProcess.read($0.pid) == $0 },
                    signal: { device, target, number in
            guard target.pid > 1, [SIGTERM, SIGKILL].contains(number),
                  try NativeAndroidEmulatorProcess.resolve(device, emulator: emulator) == target,
                  try NativeAndroidEmulatorProcess.read(target.pid) == target else { return false }
            // Positive, freshly checked PID only: never a process group, name,
            // ADB server, crash reporter, or another emulator on a reused port.
            if Darwin.kill(target.pid, number) == 0 { return true }
            if errno == ESRCH { return false }
            throw WispError("Could not terminate the selected emulator: \(String(cString: strerror(errno)))")
        })
    }
}
enum NativeAndroidEmulatorProcess {
    static func listeningPID(_ text: String, port: Int) throws -> pid_t? {
        guard text.utf8.count <= 65536 else { throw WispError("Emulator port inventory is too large") }
        var current: pid_t?, listeners = Set<pid_t>()
        for line in text.split(separator: "\n") {
            if line.first == "p" {
                guard let pid = pid_t(line.dropFirst()), pid > 1 else { throw WispError("Invalid emulator port owner") }
                current = pid
            } else if line.first == "n" {
                guard let pid = current, ["n127.0.0.1:\(port)", "n[::1]:\(port)"].contains(String(line)) else {
                    throw WispError("Uncertain emulator console listener")
                }
                listeners.insert(pid)
            } else if line.first != "f" { throw WispError("Unreadable emulator port inventory") }
        }
        guard listeners.count <= 1, text.isEmpty || !listeners.isEmpty else { throw WispError("Ambiguous emulator console owner") }
        return listeners.first
    }
    static func arguments(_ data: Data) throws -> [String] {
        guard data.count >= 5, data.count <= 1_048_576 else { throw WispError("Unreadable emulator arguments") }
        let count = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard (1...4096).contains(count) else { throw WispError("Invalid emulator argument count") }
        let bytes = [UInt8](data); var at = 4
        guard let end = bytes[at...].firstIndex(of: 0) else { throw WispError("Missing emulator executable") }
        at = end + 1
        while at < bytes.count && bytes[at] == 0 { at += 1 }
        var result = [String]()
        for _ in 0..<count {
            guard at < bytes.count, let end = bytes[at...].firstIndex(of: 0),
                  let value = String(bytes: bytes[at..<end], encoding: .utf8) else { throw WispError("Truncated emulator arguments") }
            result.append(value); at = end + 1
        }
        return result // Environment following argv is never inspected or retained.
    }
    static func read(_ pid: pid_t) throws -> AndroidEmulatorProcess? {
        guard pid > 1 else { throw WispError("Invalid emulator PID") }
        var info = proc_bsdinfo(); let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            if errno == ESRCH { return nil }; throw WispError("Cannot inspect emulator process identity")
        }
        if info.pbi_status == SZOMB { return nil }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { throw WispError("Cannot inspect emulator executable") }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid], bytes = [UInt8](repeating: 0, count: 1_048_576), length = bytes.count
        guard sysctl(&mib, u_int(mib.count), &bytes, &length, nil, 0) == 0 else { throw WispError("Cannot inspect emulator arguments") }
        let argv = try arguments(Data(bytes.prefix(length)))
        var after = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, size) == size,
              after.pbi_pid == info.pbi_pid, after.pbi_uid == info.pbi_uid,
              after.pbi_start_tvsec == info.pbi_start_tvsec, after.pbi_start_tvusec == info.pbi_start_tvusec else {
            throw WispError("Emulator identity changed during inspection")
        }
        return AndroidEmulatorProcess(pid: pid, uid: info.pbi_uid, startSeconds: info.pbi_start_tvsec,
                                      startMicroseconds: info.pbi_start_tvusec, executable: String(cString: path), arguments: argv)
    }
    static func matches(_ target: AndroidEmulatorProcess, device: Device, emulator: String) -> Bool {
        guard DeviceControl.validID(device.id, platform: device.platform), device.platform == "android",
              target.uid == geteuid(), let avd = device.avd, !avd.isEmpty else { return false }
        let directory = URL(fileURLWithPath: emulator).resolvingSymlinksInPath().deletingLastPathComponent()
        let executables = ["aarch64", "x86_64"].flatMap { arch in
            ["", "-headless"].map { directory.appendingPathComponent("qemu/darwin-\(arch)/qemu-system-\(arch)\($0)").path }
        }
        let avdFlags = target.arguments.indices.filter { target.arguments[$0] == "-avd" }
        guard executables.contains(URL(fileURLWithPath: target.executable).resolvingSymlinksInPath().path),
              avdFlags.count == 1, let index = avdFlags.first, index + 1 < target.arguments.count else { return false }
        return target.arguments[index + 1] == avd
    }
    static func resolve(_ device: Device, emulator: String) throws -> AndroidEmulatorProcess? {
        guard device.platform == "android", DeviceControl.validID(device.id, platform: "android"),
              let port = Int(device.id.dropFirst(9)), device.avd != nil else { return nil }
        let result = try command("/usr/sbin/lsof", ["-nP", "-a", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpn"], timeout: 1)
        if result.status == 1, result.output.isEmpty, result.error.isEmpty { return nil }
        guard result.status == 0, let pid = try listeningPID(result.text, port: port), let target = try read(pid) else {
            throw WispError("Cannot identify the selected emulator process")
        }
        return matches(target, device: device, emulator: emulator) ? target : nil
    }
}

final class DeviceControl {
    let launches: DeviceLaunches
    private let adb: String?
    private let run: (String, [String], Double) throws -> CommandResult
    private let windows: SimulatorWindowEffects
    private let emulatorProcesses: AndroidEmulatorProcessEffects
    private let androidStopLock = NSLock()
    private var androidStopTargets: [String: AndroidEmulatorProcess] = [:]
    private let launch: (String, [String]) throws -> Void
    private let wait: (Double) -> Void
    private let clock: () -> Double
    init(adb: String?, launches: DeviceLaunches = DeviceLaunches(), windows: SimulatorWindowEffects = .live,
         emulatorProcesses: AndroidEmulatorProcessEffects = .none,
         run: @escaping (String, [String], Double) throws -> CommandResult = { try command($0, $1, timeout: $2) },
         launch: @escaping (String, [String]) throws -> Void = { path, args in
             let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
             p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice; try p.run()
         }, wait: @escaping (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }, clock: @escaping () -> Double = monotonic) {
        self.adb = adb; self.launches = launches; self.windows = windows; self.emulatorProcesses = emulatorProcesses
        self.run = run; self.launch = launch; self.wait = wait; self.clock = clock
    }
    static func validID(_ id: String, platform: String) -> Bool {
        if platform == "ios" { return UUID(uuidString: id) != nil }
        guard platform == "android", id.hasPrefix("emulator-"),
              let port = Int(id.dropFirst(9)), (1...65535).contains(port) else { return false }
        return id == "emulator-\(port)"
    }
    // Opaque ADB selectors, never shell fragments. This does NOT grant Stop:
    // validID above deliberately remains emulator-only for destructive actions.
    static func validADBSerial(_ id: String) -> Bool {
        guard (1...255).contains(id.utf8.count) else { return false }
        if id.hasPrefix("emulator-") { return validID(id, platform: "android") }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-[]%")
        guard id.unicodeScalars.allSatisfy({ allowed.contains($0) }), let first = id.utf8.first,
              (48...57).contains(first) || (65...90).contains(first) || (97...122).contains(first) || first == 91 else { return false }
        return true
    }
    private func checked(_ path: String, _ args: [String], timeout: Double) throws -> CommandResult {
        let result = try run(path, args, timeout)
        guard result.status == 0 else {
            let message = String(decoding: result.error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw WispError(message.isEmpty ? "Device operation failed (exit \(result.status))" : message)
        }
        return result
    }
    // Launch by inventory identity, independently of capture/input or host windows.
    func boot(_ id: String, platform: String, mode: DeviceLaunchMode = .windowed, emulator: String? = nil) throws {
        if platform == "android" {
            guard let emulator else { throw WispError("Android Emulator not found") }
            let args = [emulator, "-avd", id] + (mode == .headless ? ["-no-window", "-no-boot-anim", "-gpu", "host"] : ["-no-snapshot-load"])
            try launch("/usr/bin/nohup", args)
        } else {
            guard platform == "ios", Self.validID(id, platform: platform) else { throw WispError("Invalid simulator identifier") }
            _ = try checked("/usr/bin/xcrun", ["simctl", "boot", id], timeout: 60)
            if mode == .windowed { _ = try checked("/usr/bin/open", ["-a", "Simulator", "--args", "-CurrentDeviceUDID", id], timeout: 8) }
        }
    }
    private func inventory() throws -> SimulatorInventory {
        let result = try checked("/usr/bin/xcrun", ["simctl", "list", "devices", "--json"], timeout: 8)
        return try JSONDecoder().decode(SimulatorInventory.self, from: result.output)
    }
    private func androidInventory(timeout: Double) throws -> [String: String] {
        guard let adb else { throw WispError("Android SDK adb unavailable") }
        let output = try checked(adb, ["devices"], timeout: timeout).text
        let lines = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard lines.first == "List of devices attached" else { throw WispError("ADB device inventory is incomplete or unreadable") }
        var inventory: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count >= 2, inventory[parts[0]] == nil,
                  ["device", "offline", "unauthorized", "bootloader", "recovery", "sideload", "rescue", "host", "connecting"].contains(parts[1]) || (parts[1] == "no" && parts.dropFirst(2).first == "permissions") else {
                throw WispError("ADB device inventory is incomplete or unreadable")
            }
            inventory[parts[0]] = parts[1]
        }
        return inventory
    }
    // One fresh, read-only all-state query on explicit refresh. An offline or
    // unauthorized serial still exists; filtered running-device absence is not
    // enough to claim shutdown. Errors/malformed output remain inconclusive.
    func androidStopStatus(_ id: String) throws -> [String: Any] {
        guard Self.validID(id, platform: "android") else { throw WispError("Invalid emulator identifier") }
        return try confirmedAndroidStatus(id, timeout: 2)
    }
    private func confirmedAndroidStatus(_ id: String, timeout: Double) throws -> [String: Any] {
        let inventory = try androidInventory(timeout: timeout)
        let target = androidStopLock.withLock { androidStopTargets[id] }
        if inventory[id] == nil, let target, try emulatorProcesses.isRunning(target) { return pendingAndroidStatus(id) }
        if inventory[id] == nil { androidStopLock.withLock { _ = androidStopTargets.removeValue(forKey: id) } }
        return androidStatus(id, inventory: inventory)
    }
    private func pendingAndroidStatus(_ id: String, warning: String? = nil) -> [String: Any] {
        var value: [String: Any] = ["ok": true, "id": id, "platform": "android", "state": "pending", "window_closed": false, "simulator_quit_requested": false]
        if let warning { value["warning"] = warning }
        return value
    }
    private func waitForAndroidStop(_ id: String, seconds: Double) -> [String: Any]? {
        let deadline = clock() + seconds
        while clock() < deadline {
            let remaining = deadline - clock()
            guard remaining > 0 else { break }
            if let value = try? confirmedAndroidStatus(id, timeout: min(2, remaining)), value["state"] as? String == "stopped" { return value }
            let budget = deadline - clock()
            if budget > 0 { wait(min(0.25, budget)) }
        }
        return nil
    }
    private func stopAndroid(_ device: Device, adb: String) throws -> [String: Any] {
        // Resolve before the first command, so a later port/PID replacement can
        // never become the fallback target for this request.
        let target = try? emulatorProcesses.resolve(device)
        androidStopLock.withLock { androidStopTargets[device.id] = target }
        do { _ = try checked(adb, ["-s", device.id, "emu", "kill"], timeout: 8) }
        catch { if target == nil { throw error } }
        if let stopped = waitForAndroidStop(device.id, seconds: 8) { return stopped }
        guard let target else {
            return pendingAndroidStatus(device.id, warning: "Normal shutdown is still pending; the local emulator process could not be identified safely.")
        }
        do {
            for (number, seconds) in [(SIGTERM, 2.0), (SIGKILL, 3.0)] {
                guard try emulatorProcesses.isRunning(target), try emulatorProcesses.signal(device, target, number) else {
                    return pendingAndroidStatus(device.id, warning: "Emulator process exited or changed; no further termination was attempted. Refresh devices to confirm.")
                }
                if var stopped = waitForAndroidStop(device.id, seconds: seconds) {
                    if number == SIGKILL { stopped["forced"] = true; stopped["warning"] = "Emulator force-stopped after normal shutdown stalled. Unsaved emulator state may be lost." }
                    return stopped
                }
            }
        } catch {
            return pendingAndroidStatus(device.id, warning: "Could not safely finish stopping the emulator: \(error.localizedDescription)")
        }
        return pendingAndroidStatus(device.id, warning: "Emulator termination was requested, but process/ADB exit is not yet confirmed.")
    }
    private func androidStatus(_ id: String, inventory: [String: String]) -> [String: Any] {
        let present = inventory[id]
        var value: [String: Any] = ["ok": true, "id": id, "platform": "android", "state": present == nil ? "stopped" : "pending", "window_closed": present == nil, "simulator_quit_requested": false]
        if let present { value["adb_state"] = present }
        return value
    }
    static func title(_ title: String, matches name: String) -> Bool {
        // Never let "iPhone 11" accidentally select an "iPhone 11 Pro" window.
        title == name || [" — ", " – ", " - ", " ("].contains { title.hasPrefix(name + $0) }
    }
    static func selectedWindow(device: SimulatorEntry, inventory: SimulatorInventory, snapshot: SimulatorWindowSnapshot) -> SimulatorWindowRef? {
        // A shut-down same-name device may still have a lingering window.
        // Treat every duplicate name/title interpretation as uncertain.
        guard snapshot.selectionReliable, inventory.all.filter({ $0.name == device.name }).count == 1 else { return nil }
        let matches = snapshot.windows.filter { window in
            let identities = inventory.all.filter { title(window.title, matches: $0.name) }
            return identities.count == 1 && identities[0].udid == device.udid
        }
        return matches.count == 1 ? matches[0] : nil
    }
    // Called on the serial tools/action queue, never the network/UI queue.
    func stop(_ device: Device) throws -> [String: Any] {
        guard Self.validID(device.id, platform: device.platform) else { throw WispError("Invalid simulator identifier") }
        if device.platform == "android" {
            guard let adb else { throw WispError("Android SDK adb unavailable") }
            return try stopAndroid(device, adb: adb)
        }
        let before = try inventory()
        guard let selected = before.all.first(where: { $0.udid == device.id }), selected.isAvailable != false else { throw WispError("Unknown or unavailable simulator") }
        var warning: String?
        var prepared: SimulatorWindowSnapshot?
        do { prepared = try windows.snapshot() }
        catch { warning = "Simulator stopped; its window could not be inspected safely. Check Accessibility and Screen Recording permissions." }
        let target = prepared.flatMap { Self.selectedWindow(device: selected, inventory: before, snapshot: $0) }
        if selected.state != "Shutdown" {
            _ = try checked("/usr/bin/xcrun", ["simctl", "shutdown", device.id], timeout: 30)
        }
        let after = try inventory()
        guard after.all.first(where: { $0.udid == device.id })?.state == "Shutdown" else {
            throw WispError("Shutdown requested, but the simulator is not confirmed shut down. Refresh devices to check its state.")
        }
        var closed = false, quit = false, closeFailed = false
        if let target {
            do {
                let current = try windows.snapshot()
                guard current.selectionReliable else { throw WispError("Selected Simulator window inventory is incomplete") }
                if !current.windows.contains(where: { target.sameWindow($0) }) {
                    closed = true // shutdown may already have closed the window
                } else {
                    guard current.windows.contains(where: { target.stillIdentifies($0) }) else { throw WispError("Selected Simulator window identity changed") }
                    let preClose = try inventory()
                    guard preClose.all.contains(where: { $0.udid == device.id && $0.state == "Shutdown" }) else { throw WispError("Selected simulator is no longer confirmed shut down") }
                    try windows.close(target)
                    for attempt in 0..<5 {
                        let fresh = try windows.snapshot()
                        if fresh.selectionReliable && !fresh.windows.contains(where: { target.sameWindow($0) }) { closed = true; break }
                        if attempt < 4 { wait(0.1) }
                    }
                }
                if !closed { closeFailed = true; warning = "Simulator stopped; its window did not finish closing. The Simulator app was left running." }
            } catch { closeFailed = true; warning = "Simulator stopped; its window could not be closed safely. The Simulator app was left running." }
        } else if prepared?.windows.contains(where: { Self.title($0.title, matches: selected.name) }) == true || prepared?.reliable == false {
            warning = "Simulator stopped; its window was left unchanged because it could not be identified unambiguously."
        }
        // Initial ambiguity can become obsolete when shutdown removes the
        // window itself. Always perform fresh checks; never override an actual
        // close failure, incomplete inventory, active device or pending launch.
        do {
            let fresh = try windows.snapshot()
            let finalDevices = try inventory()
            let confirmed = finalDevices.all.contains(where: { $0.udid == device.id && $0.state == "Shutdown" })
            if fresh.reliable, fresh.windows.isEmpty, confirmed, !closeFailed {
                if target != nil || prepared?.windows.contains(where: { Self.title($0.title, matches: selected.name) }) == true { closed = true }
                warning = nil // complete emptiness resolves the old inspection warning
                if fresh.applications.count == 1, finalDevices.idle {
                    quit = try launches.ifIdle {
                        let lastDevices = try inventory()
                        guard lastDevices.idle, lastDevices.all.contains(where: { $0.udid == device.id && $0.state == "Shutdown" }) else { return false }
                        return try windows.quitIfEmpty(fresh.applications[0])
                    }
                }
            } else if !fresh.reliable && warning == nil {
                warning = "Simulator stopped; the final window inspection was incomplete, so the Simulator app was left running."
            }
        } catch {
            if warning == nil { warning = "Simulator stopped; the final idle check was inconclusive, so the Simulator app was left running." }
        }
        var result: [String: Any] = ["ok": true, "id": device.id, "platform": "ios", "window_closed": closed, "simulator_quit_requested": quit]
        if let warning { result["warning"] = warning }
        return result
    }
}

// Metadata-only adapter, shared by the native reader and inert tests. CG lists
// compositor surfaces, not just app windows: never assume a device's layer is 0.
// Only an explicitly read AX non-window role can classify an auxiliary surface;
// generic small/hidden/untitled/unmatched CG entries remain uncertain.
enum SimulatorWindowAdapter {
    struct AXRecord {
        let role: String?, title: String?, bounds: CGRect?
    }
    struct Result {
        let windows: [SimulatorWindowRef]
        let indices: [CGWindowID: Int]
        let reliable: Bool, selectionReliable: Bool
    }
    static let auxiliaryRoles: Set<String> = [kAXMenuBarRole, kAXMenuRole, kAXToolbarRole, kAXGroupRole, kAXButtonRole, kAXMenuButtonRole, kAXPopUpButtonRole, kAXStaticTextRole, kAXImageRole]
    static func valid(_ bounds: CGRect) -> Bool {
        bounds.minX.isFinite && bounds.minY.isFinite && bounds.width.isFinite && bounds.height.isFinite && bounds.width > 0 && bounds.height > 0
    }
    static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }
    // Recheck CG as well as AX: a new/replaced/off-Space compositor surface
    // appearing during the read must not be absent from an "empty" snapshot.
    static func stable(before: [[String: Any]], after: [[String: Any]], pids: [pid_t]) -> Bool {
        let keys = Set([kCGWindowOwnerPID, kCGWindowNumber, kCGWindowName, kCGWindowBounds, kCGWindowLayer, kCGWindowIsOnscreen].map { $0 as String })
        func own(_ rows: [[String: Any]]) -> [String: Any]? {
            var value: [String: Any] = [:]
            for row in rows {
                guard let owner = row[kCGWindowOwnerPID as String] as? NSNumber else { return nil }
                guard pids.contains(where: { owner.doubleValue == Double($0) }) else { continue }
                guard let id = row[kCGWindowNumber as String] as? NSNumber, id.doubleValue > 0, id.doubleValue <= Double(UInt32.max), id.doubleValue == Double(id.uint32Value) else { return nil }
                let key = String(id.uint32Value)
                guard value[key] == nil else { return nil }
                value[key] = row.filter { keys.contains($0.key) }
            }
            return value
        }
        guard let a = own(before), let b = own(after) else { return false }
        return NSDictionary(dictionary: a).isEqual(NSDictionary(dictionary: b))
    }
    static func assemble(pid: pid_t, windows: [AXRecord], surfaces: [[String: Any]], auxiliary: [AXRecord]) -> Result {
        struct Surface { let id: CGWindowID, title: String?, bounds: CGRect }
        var cg: [Surface] = [], complete = pid > 0 && windows.count <= 64, identifiable = complete
        var ids = Set<CGWindowID>()
        for info in surfaces {
            guard let owner = info[kCGWindowOwnerPID as String] as? NSNumber else { complete = false; identifiable = false; continue }
            guard owner.doubleValue == Double(pid) else { continue }
            guard let number = info[kCGWindowNumber as String] as? NSNumber, number.doubleValue > 0, number.doubleValue <= Double(UInt32.max), number.doubleValue == Double(number.uint32Value),
                  let dictionary = info[kCGWindowBounds as String] as? [String: Any], let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary), valid(bounds),
                  ids.insert(number.uint32Value).inserted else { complete = false; identifiable = false; continue }
            let rawTitle = info[kCGWindowName as String]
            if rawTitle != nil && !(rawTitle is String) { complete = false; identifiable = false }
            cg.append(Surface(id: number.uint32Value, title: rawTitle as? String, bounds: bounds))
        }
        var refs: [SimulatorWindowRef] = [], indices: [CGWindowID: Int] = [:]
        for (index, window) in windows.prefix(64).enumerated() {
            guard window.role == kAXWindowRole, let title = window.title, let bounds = window.bounds, valid(bounds) else { complete = false; identifiable = false; continue }
            let matches = cg.filter { Self.matches($0.bounds, bounds) }
            guard matches.count == 1, let surface = matches.first, indices[surface.id] == nil else { complete = false; identifiable = false; continue }
            refs.append(SimulatorWindowRef(id: surface.id, pid: pid, title: title, bounds: bounds)); indices[surface.id] = index
        }
        for surface in cg where indices[surface.id] == nil {
            // AXWindow records always take precedence, even for a tiny window
            // placed over the menu bar. Do not erase a failed window match.
            let overlapsWindow = (windows + auxiliary.filter { $0.role == kAXWindowRole }).contains { $0.bounds.map { Self.matches($0, surface.bounds) } == true }
            let knownAuxiliary = !overlapsWindow && auxiliary.contains { item in
                guard let role = item.role, auxiliaryRoles.contains(role), let bounds = item.bounds, valid(bounds), Self.matches(bounds, surface.bounds) else { return false }
                return surface.title?.isEmpty != false || (item.title?.isEmpty == false && surface.title == item.title)
            }
            if !knownAuxiliary {
                complete = false
                if surface.title?.isEmpty == false { identifiable = false }
            }
        }
        return Result(windows: refs, indices: indices, reliable: complete && identifiable, selectionReliable: identifiable)
    }
}

// No activate(), shortcuts, AppleScript, force quit, or permission prompts.
// AXWindows and CG optionAll are both used, without on-screen/layer filtering.
private enum NativeSimulatorWindows {
    private static let bundleID = "com.apple.iphonesimulator"
    private struct Scan {
        let snapshot: SimulatorWindowSnapshot
        let elements: [CGWindowID: AXUIElement]
    }
    private static func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
    private static func record(_ element: AXUIElement) -> SimulatorWindowAdapter.AXRecord {
        SimulatorWindowAdapter.AXRecord(role: axAttribute(element, kAXRoleAttribute) as? String, title: axAttribute(element, kAXTitleAttribute) as? String, bounds: axFrame(element))
    }
    private static func scan() throws -> Scan {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
        if apps.isEmpty { return Scan(snapshot: SimulatorWindowSnapshot(applications: [], windows: [], reliable: true), elements: [:]) }
        guard apps.count <= 8, AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else { throw WispError("Cannot reliably inspect Simulator windows without existing permissions") }
        guard let raw = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { throw WispError("Cannot inspect all Simulator windows") }
        var refs: [SimulatorWindowRef] = [], elements: [CGWindowID: AXUIElement] = [:], reliable = true, identifiable = true
        let deadline = monotonic() + 2
        for app in apps {
            let pid = app.processIdentifier
            guard pid > 0, app.isFinishedLaunching, monotonic() < deadline else { reliable = false; identifiable = false; continue }
            let root = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(root, 0.2)
            var value: CFTypeRef?, count: CFIndex = 0
            guard AXUIElementGetAttributeValueCount(root, kAXWindowsAttribute as CFString, &count) == .success, (0...64).contains(count),
                  AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement], windows.count == count else { reliable = false; identifiable = false; continue }
            var records: [SimulatorWindowAdapter.AXRecord] = [], auxiliary: [SimulatorWindowAdapter.AXRecord] = []
            for window in windows {
                guard monotonic() < deadline else { reliable = false; identifiable = false; break }
                AXUIElementSetMessagingTimeout(window, 0.2); records.append(record(window))
            }
            guard records.count == windows.count else { continue }
            // Read actual semantic AX elements, not a hard-coded menu-bar size
            // or assumed CG layer. Unknown/unreadable auxiliary data is optional:
            // an unmatched CG surface then keeps reliable=false and blocks quit.
            var pending: [(AXUIElement, Int)] = windows.map { ($0, 0) }
            for name in [kAXMenuBarAttribute, kAXExtrasMenuBarAttribute] {
                if let element = axAttribute(root, name), CFGetTypeID(element) == AXUIElementGetTypeID() { pending.append((element as! AXUIElement, 0)) }
            }
            var visited: [AXUIElement] = []
            while let (element, depth) = pending.popLast(), visited.count < 64, monotonic() < deadline {
                if visited.contains(where: { CFEqual($0, element) }) { continue }
                visited.append(element); AXUIElementSetMessagingTimeout(element, 0.2)
                let item = record(element)
                auxiliary.append(item) // retain child AXWindow roles too; they must never be ignored
                if depth < 3, let children = axAttribute(element, kAXChildrenAttribute) as? [AXUIElement] { pending.append(contentsOf: children.prefix(64).map { ($0, depth + 1) }) }
            }
            var finalCount: CFIndex = -1
            guard AXUIElementGetAttributeValueCount(root, kAXWindowsAttribute as CFString, &finalCount) == .success, finalCount == count,
                  let freshWindows = axAttribute(root, kAXWindowsAttribute) as? [AXUIElement], freshWindows.count == windows.count,
                  zip(windows, freshWindows).allSatisfy({ CFEqual($0.0, $0.1) }), monotonic() < deadline else { reliable = false; identifiable = false; continue }
            let result = SimulatorWindowAdapter.assemble(pid: pid, windows: records, surfaces: raw, auxiliary: auxiliary)
            reliable = reliable && result.reliable; identifiable = identifiable && result.selectionReliable
            for window in result.windows {
                guard let index = result.indices[window.id], elements[window.id] == nil else { reliable = false; identifiable = false; continue }
                let element = windows[index]
                refs.append(SimulatorWindowRef(id: window.id, pid: pid, title: window.title, bounds: window.bounds, element: element)); elements[window.id] = element
            }
        }
        if let freshCG = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] {
            if !SimulatorWindowAdapter.stable(before: raw, after: freshCG, pids: apps.map(\.processIdentifier)) { reliable = false; identifiable = false }
        } else { reliable = false; identifiable = false }
        if monotonic() >= deadline { reliable = false; identifiable = false }
        let currentApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
        if currentApps.map(\.processIdentifier).sorted() != apps.map(\.processIdentifier).sorted() || currentApps.contains(where: { !$0.isFinishedLaunching }) { reliable = false; identifiable = false }
        return Scan(snapshot: SimulatorWindowSnapshot(applications: apps.map(\.processIdentifier), windows: refs, reliable: reliable, selectionReliable: identifiable), elements: elements)
    }
    static func snapshot() throws -> SimulatorWindowSnapshot { try onMain { try scan().snapshot } }
    static func close(_ target: SimulatorWindowRef) throws {
        try onMain {
            let current = try scan()
            let matches = current.snapshot.windows.filter { target.stillIdentifies($0) }
            guard current.snapshot.selectionReliable, matches.count == 1, let fresh = matches.first,
                  let original = target.element, let window = current.elements[fresh.id], CFEqual(original, window),
                  axAttribute(window, kAXRoleAttribute) as? String == kAXWindowRole,
                  axAttribute(window, kAXTitleAttribute) as? String == target.title,
                  let button = axAttribute(window, kAXCloseButtonAttribute) else { throw WispError("Selected Simulator window is no longer identifiable") }
            guard CFGetTypeID(button) == AXUIElementGetTypeID(),
                  AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success else { throw WispError("Selected Simulator window could not be closed") }
        }
    }
    static func quitIfEmpty(_ pid: pid_t) throws -> Bool {
        try onMain {
            let fresh = try scan().snapshot
            guard fresh.reliable, fresh.windows.isEmpty, fresh.applications == [pid],
                  let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == bundleID, !app.isTerminated, app.isFinishedLaunching else { return false }
            return app.terminate() // normal request; never forceTerminate()
        }
    }
}
