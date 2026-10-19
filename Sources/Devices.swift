import Foundation
import AppKit
import ApplicationServices

struct Device: Codable {
    let id: String
    let name: String
    let platform: String
    var width: Int
    var height: Int
    var project_app = false
    // Backend-only alias; keep the AVD name/serial and public inventory unchanged.
    var metroName: String? = nil
    var avd: String? = nil
    var headless: Bool? = nil // Known launch intent, not an inference from a hidden/minimized window.
    var physicalAndroid: Bool { platform == "android" && !id.hasPrefix("emulator-") }
    private enum CodingKeys: String, CodingKey { case id, name, platform, width, height, project_app, avd, headless }
    var json: [String: Any] { ["id": id, "name": name, "platform": platform, "width": width, "height": height, "project_app": project_app, "avd": avd as Any? ?? NSNull(), "physical": physicalAndroid, "headless": headless == true] }
}
// React Native's Android device label is Build.MODEL + release + SDK_INT,
// not the emulator's AVD name. Read once per existing tool-cache refresh on the
// discovery queue; failures create no alias and never retain a previous value.
enum AndroidMetroIdentity {
    static let properties = "getprop ro.product.model; getprop ro.build.version.release; getprop ro.build.version.sdk"
    static func name(_ output: Data) -> String? {
        guard output.count <= 1024, let text = String(data: output, encoding: .utf8) else { return nil }
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.count == 3 else { return nil }
        let values = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        guard values.allSatisfy({ !$0.isEmpty && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }),
              values[0].utf8.count <= 128, values[1].utf8.count <= 64, values[2].utf8.count <= 6,
              values[0].lowercased() != "unknown", values[1].lowercased() != "unknown",
              values[2].utf8.allSatisfy({ (48...57).contains($0) }), let sdk = Int(values[2]), (1...1000).contains(sdk) else { return nil }
        return values[0] + " - " + values[1] + " - API " + String(sdk)
    }
    static func read(adb: String, serial: String,
                     run: (String, [String], Double) throws -> CommandResult = { try command($0, $1, timeout: $2) }) -> String? {
        guard DeviceControl.validADBSerial(serial),
              let result = try? run(adb, ["-s", serial, "shell", properties], 3), result.status == 0 else { return nil }
        return name(result.output)
    }
}
// Inventory policy shared by live discovery and inert tests. Offline and
// unauthorized entries never become selectors. Duplicate/malformed inventories
// fail closed rather than choosing an ambiguous transport.
enum AndroidDeviceInventory {
    static func connected(_ data: Data) -> [String] {
        guard data.count <= 65536, let text = String(data: data, encoding: .utf8) else { return [] }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard lines.first == "List of devices attached", lines.count <= 257 else { return [] }
        var seen = Set<String>(), result = [String]()
        for line in lines.dropFirst() {
            let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard fields.count >= 2, seen.insert(fields[0]).inserted,
                  ["device", "offline", "unauthorized", "bootloader", "recovery", "sideload", "rescue", "host", "connecting"].contains(fields[1]) || (fields[1] == "no" && fields.dropFirst(2).first == "permissions") else { return [] }
            if fields[1] == "device", DeviceControl.validADBSerial(fields[0]) { result.append(fields[0]) }
        }
        return result
    }
    static func displaySize(_ data: Data) -> (Int, Int)? {
        guard data.count <= 1024, let text = String(data: data, encoding: .utf8) else { return nil }
        var size: (Int, Int)?
        for line in text.components(separatedBy: .newlines) {
            let p = line.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ": ")
            guard p.count == 2, ["Physical size", "Override size"].contains(p[0]) else { continue }
            let values = p[1].split(separator: "x", omittingEmptySubsequences: false)
            guard values.count == 2, values.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
                  let w = Int(values[0]), let h = Int(values[1]), (8...8192).contains(w), (8...8192).contains(h) else { return nil }
            size = (w, h)
        }
        return size
    }
    static func read(adb: String, run: (String, [String], Double) throws -> CommandResult = { try command($0, $1, timeout: $2) }) -> [Device] {
        guard let result = try? run(adb, ["devices"], 3), result.status == 0 else { return [] }
        return connected(result.output).map { serial in
            let metro = AndroidMetroIdentity.read(adb: adb, serial: serial, run: run)
            if DeviceControl.validID(serial, platform: "android") {
                let avd = (try? run(adb, ["-s", serial, "emu", "avd", "name"], 3)).flatMap { $0.status == 0 ? $0.text.components(separatedBy: .newlines).first : nil } ?? serial
                return Device(id: serial, name: avd.replacingOccurrences(of: "_", with: " "), platform: "android", width: 0, height: 0, metroName: metro, avd: avd)
            }
            let model = metro?.components(separatedBy: " - ").first ?? serial
            let display = (try? run(adb, ["-s", serial, "shell", "wm", "size"], 3)).flatMap { $0.status == 0 ? displaySize($0.output) : nil }
            return Device(id: serial, name: model, platform: "android", width: display?.0 ?? 0, height: display?.1 ?? 0, metroName: metro)
        }
    }
}
struct DeviceWindow: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let bounds: CGRect
    let crop: CGRect // top-left-relative host points; shared by capture and input
    var landscape: Bool { crop.width > crop.height }
    func point(_ nx: Double, _ ny: Double) -> CGPoint {
        CGPoint(x: bounds.minX + crop.minX + clamp(nx) * crop.width, y: bounds.minY + crop.minY + clamp(ny) * crop.height)
    }
}

final class Devices {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "Simwisp.discovery", qos: .utility)
    private var timer: DispatchSourceTimer? // discovery queue owns timer lifetime
    private var stopped = false // lock protects demand/diagnostic state
    private var streamingDemand = false
    private var polling = false
    private var refreshCount: UInt64 = 0
    private var toolRefreshCount: UInt64 = 0
    private var running: [Device] = []
    private var available: [[String: Any]] = []
    private var windows: [String: DeviceWindow] = [:]
    private var iosJSON: [String: Any] = [:]
    private var lastTools: Double = 0
    private var androidCache: [Device] = []
    private var avds: [String] = []
    private var bundleID: String?
    private var cropCache: [CGWindowID: (bounds: CGRect, checked: Double, crop: CGRect?)] = [:]
    private var projectApps: [String: Bool] = [:]
    let settings: Settings
    let control: DeviceControl
    private let discoveryOverride: (() -> ([Device], [[String: Any]], [String: DeviceWindow]))?
    private let bootOverride: ((String, DeviceLaunchMode) throws -> Void)?
    private var launchModes: [String: DeviceLaunchMode] = [:]
    private var observedLaunches = Set<String>()
    let adb: String?
    let emulator: String?
    init(settings: Settings, control: DeviceControl? = nil, discovery: (() -> ([Device], [[String: Any]], [String: DeviceWindow]))? = nil, boot: ((String, DeviceLaunchMode) throws -> Void)? = nil) {
        self.settings = settings; discoveryOverride = discovery; bootOverride = boot
        let env = ProcessInfo.processInfo.environment
        let roots = [settings.androidSDK, env["ANDROID_HOME"] ?? "", env["ANDROID_SDK_ROOT"] ?? "", NSHomeDirectory() + "/Library/Android/sdk", NSHomeDirectory() + "/.androidsdk"]
        adb = roots.filter { !$0.isEmpty }.map { $0 + "/platform-tools/adb" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        emulator = roots.filter { !$0.isEmpty }.map { $0 + "/emulator/emulator" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        bundleID = Self.projectBundle(settings.projectDirectory)
        self.control = control ?? DeviceControl(adb: adb, emulatorProcesses: .live(emulator: emulator))
    }
    func setStreamingDemand(_ active: Bool) {
        lock.withLock { streamingDemand = active }
        queue.async { self.updatePolling() }
    }
    private func updatePolling() {
        let needed = lock.withLock { streamingDemand && !stopped }
        if needed && timer == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(50))
            t.setEventHandler { [weak self] in
                guard let self, self.lock.withLock({ self.streamingDemand && !self.stopped }) else { return }
                self.refresh()
            }
            timer = t; lock.withLock { polling = true }; t.resume()
        } else if !needed {
            timer?.cancel(); timer = nil; lock.withLock { polling = false }
        }
    }
    func stop() {
        lock.withLock { stopped = true; streamingDemand = false }
        queue.async { self.updatePolling() }
    }
    func requestRefresh(completion: @escaping () -> Void) {
        queue.async {
            if !self.lock.withLock({ self.stopped }) { self.refresh() }
            completion()
        }
    }
    func invalidate() {
        queue.async {
            guard !self.lock.withLock({ self.stopped }) else { return }
            self.lastTools = 0; self.refresh()
        }
    }
    var diagnostics: [String: Any] {
        lock.withLock { ["polling": polling, "streaming_demand": streamingDemand, "refreshes": refreshCount, "tool_refreshes": toolRefreshCount] }
    }
    func list() -> [Device] { lock.lock(); defer { lock.unlock() }; return running }
    func library() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return available }
    func window(_ id: String) -> DeviceWindow? { lock.lock(); defer { lock.unlock() }; return windows[id] }
    func device(_ id: String) -> Device? { list().first { $0.id == id } }
    var projectBundleID: String? { bundleID }

    private func refresh() {
        lock.withLock { refreshCount &+= 1 }
        if let discoveryOverride {
            let snapshot = discoveryOverride()
            let decorated = applyingLaunchModes(snapshot.0)
            lock.withLock { running = decorated; available = snapshot.1; windows = snapshot.2 }
            return
        }
        autoreleasepool {
            let refreshTools = monotonic() - lastTools > 8
            if refreshTools {
                lock.withLock { toolRefreshCount &+= 1 }
                if let result = try? command("/usr/bin/xcrun", ["simctl", "list", "devices", "--json"], timeout: 8), result.status == 0 {
                    iosJSON = dictionary(result.output)
                }
                androidCache = androidDevices()
                if let emulator, let result = try? command(emulator, ["-list-avds"], timeout: 4), result.status == 0 {
                    avds = result.text.split(separator: "\n").map(String.init)
                }
                lastTools = monotonic()
            }
            let hostWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            var devices: [Device] = [], library: [[String: Any]] = [], mapped: [String: DeviceWindow] = [:]
            for (runtime, entries) in (iosJSON["devices"] as? [String: [[String: Any]]] ?? [:]).sorted(by: { $0.key < $1.key }) {
                for entry in entries where entry["isAvailable"] as? Bool != false {
                    guard let id = entry["udid"] as? String, let name = entry["name"] as? String else { continue }
                    let size = Self.logicalSize(name)
                    if entry["state"] as? String == "Booted" {
                        var device = Device(id: id, name: name, platform: "ios", width: size.0, height: size.1)
                        if let win = hostWindows.first(where: { ($0[kCGWindowOwnerName as String] as? String) == "Simulator" && ($0[kCGWindowName as String] as? String ?? "").contains(name) && Self.bounds($0).width > 100 }), let window = makeWindow(win, ios: true) {
                            mapped[id] = window
                            device.width = Int(window.crop.width); device.height = Int(window.crop.height)
                        }
                        if let bundleID, refreshTools, let result = try? command("/usr/bin/xcrun", ["simctl", "get_app_container", id, bundleID, "app"], timeout: 3) { projectApps[id] = result.status == 0 }
                        device.project_app = projectApps[id] ?? false
                        devices.append(device)
                    } else if entry["state"] as? String == "Shutdown" {
                        library.append(["id": id, "name": name, "platform": "ios", "width": size.0, "height": size.1, "runtime": runtime.components(separatedBy: ".").last?.replacingOccurrences(of: "-", with: " ") ?? runtime])
                    }
                }
            }
            for var device in androidCache {
                let port = device.id.replacingOccurrences(of: "emulator-", with: "")
                if !device.physicalAndroid, let info = hostWindows.first(where: { ($0[kCGWindowOwnerName as String] as? String ?? "").lowercased().hasPrefix("qemu-system") && ($0[kCGWindowName as String] as? String ?? "").hasSuffix(":" + port) && Self.bounds($0).width > 100 }), let window = makeWindow(info, ios: false) {
                    mapped[device.id] = window
                    // Same Quartz crop geometry used for iOS, capture, and HID
                    // input; Android's internal ADB display size is unrelated.
                    device.width = Int(window.crop.width); device.height = Int(window.crop.height)
                }
                devices.append(device)
            }
            let runningNames = Set(androidCache.filter { !$0.physicalAndroid }.map { $0.avd ?? $0.name.replacingOccurrences(of: " ", with: "_") })
            library += avds.filter { !runningNames.contains($0) }.map { ["id": $0, "name": $0.replacingOccurrences(of: "_", with: " "), "platform": "android"] }
            let decorated = applyingLaunchModes(devices)
            lock.lock(); running = decorated; available = library; windows = mapped; lock.unlock()
        }
    }
    static func bounds(_ info: [String: Any]) -> CGRect {
        guard let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { return .zero }
        return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
    }
    private func makeWindow(_ info: [String: Any], ios: Bool) -> DeviceWindow? {
        guard let id = info[kCGWindowNumber as String] as? UInt32, let pid = info[kCGWindowOwnerPID as String] as? Int32 else { return nil }
        let bounds = Self.bounds(info), title = info[kCGWindowName as String] as? String ?? ""
        guard bounds.width > 100, bounds.height > 100 else { return nil }
        let full = CGRect(origin: .zero, size: bounds.size)
        let top = min(CGFloat(settings.androidTitlebar), bounds.height - 1)
        var iosCrop: CGRect?
        if ios {
            if let cached = cropCache[id], cached.bounds == bounds, monotonic() - cached.checked < 5 { iosCrop = cached.crop }
            else { iosCrop = Self.iosCrop(pid: pid, bounds: bounds); cropCache[id] = (bounds, monotonic(), iosCrop) }
        }
        let crop = ios ? iosCrop ?? full : CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
        return DeviceWindow(id: id, pid: pid, title: title, bounds: bounds, crop: crop)
    }
    static func iosCrop(pid: pid_t, bounds: CGRect) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app, 0.2)
        for window in axAttribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
            guard let frame = axFrame(window), abs(frame.minX - bounds.minX) < 5, abs(frame.minY - bounds.minY) < 5, abs(frame.width - bounds.width) < 5 else { continue }
            var queue: [(AXUIElement, Int)] = [(window, 0)], index = 0
            while index < queue.count && index < 200 {
                let (element, depth) = queue[index]; index += 1
                if axAttribute(element, kAXSubroleAttribute) as? String == "iOSContentGroup", let rect = axFrame(element) {
                    let crop = CGRect(x: (rect.minX - bounds.minX).rounded(), y: (rect.minY - bounds.minY).rounded(), width: rect.width.rounded(), height: rect.height.rounded())
                    if crop.minX >= 0, crop.minY >= 0, crop.width >= bounds.width * 0.4, crop.height >= bounds.height * 0.4, crop.maxX <= bounds.width + 2, crop.maxY <= bounds.height + 2 { return crop.intersection(CGRect(origin: .zero, size: bounds.size)) }
                }
                if depth < 12 { queue += (axAttribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).map { ($0, depth + 1) } }
            }
        }
        return nil
    }
    private func androidDevices() -> [Device] {
        guard let adb else { return [] }
        return AndroidDeviceInventory.read(adb: adb)
    }
    private func applyingLaunchModes(_ devices: [Device]) -> [Device] {
        lock.withLock {
            let key: (Device) -> String = { $0.platform == "android" ? "android:" + ($0.avd ?? $0.id) : "ios:" + $0.id }
            let present = Set(devices.map(key))
            // Stop is still device-ID based. Forget intent after observed retirement,
            // so a later external launch cannot inherit a stopped session's mode.
            for retired in observedLaunches.subtracting(present) { launchModes.removeValue(forKey: retired); observedLaunches.remove(retired) }
            return devices.map { device in
                var next = device
                if let mode = launchModes[key(device)] { next.headless = mode == .headless; observedLaunches.insert(key(device)) }
                return next
            }
        }
    }
    func boot(_ id: String, mode: DeviceLaunchMode = .windowed) throws {
        guard let entry = library().first(where: { $0["id"] as? String == id }), let platform = entry["platform"] as? String else { throw WispError("Unknown or already running device") }
        if let bootOverride { try bootOverride(id, mode) }
        else { try control.boot(id, platform: platform, mode: mode, emulator: emulator) }
        lock.withLock { let key = platform + ":" + id; launchModes[key] = mode; observedLaunches.remove(key) }
        invalidate()
    }
    static func projectBundle(_ directory: String) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
        for project in entries.filter({ $0.hasSuffix(".xcodeproj") }).sorted() {
            if let text = try? String(contentsOfFile: directory + "/" + project + "/project.pbxproj", encoding: .utf8), let regex = try? NSRegularExpression(pattern: "PRODUCT_BUNDLE_IDENTIFIER\\s*=\\s*([^;\"\\s]+)") {
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    if let range = Range(match.range(at: 1), in: text) {
                        let id = String(text[range]); if !id.hasPrefix("$("), !id.lowercased().contains("test"), !id.lowercased().contains("extension") { return id }
                    }
                }
            }
        }
        return nil
    }
    static func logicalSize(_ name: String) -> (Int, Int) {
        guard let url = Bundle.main.url(forResource: "device-sizes", withExtension: "json"), let data = try? Data(contentsOf: url), let sizes = dictionary(data) as? [String: [Int]] else { return (390, 844) }
        for key in sizes.keys.sorted(by: { $0.count > $1.count }) where name.lowercased().contains(key) {
            if let size = sizes[key], size.count == 2 { return (size[0], size[1]) }
        }
        return (390, 844)
    }
}
