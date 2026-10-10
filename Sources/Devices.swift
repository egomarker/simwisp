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
    var json: [String: Any] { ["id": id, "name": name, "platform": platform, "width": width, "height": height, "project_app": project_app] }
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
    let adb: String?
    let emulator: String?
    init(settings: Settings) {
        self.settings = settings
        let env = ProcessInfo.processInfo.environment
        let roots = [settings.androidSDK, env["ANDROID_HOME"] ?? "", env["ANDROID_SDK_ROOT"] ?? "", NSHomeDirectory() + "/Library/Android/sdk", NSHomeDirectory() + "/.androidsdk"]
        adb = roots.filter { !$0.isEmpty }.map { $0 + "/platform-tools/adb" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        emulator = roots.filter { !$0.isEmpty }.map { $0 + "/emulator/emulator" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        bundleID = Self.projectBundle(settings.projectDirectory)
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
            for device in androidCache {
                let port = device.id.replacingOccurrences(of: "emulator-", with: "")
                if let info = hostWindows.first(where: { ($0[kCGWindowOwnerName as String] as? String ?? "").lowercased().hasPrefix("qemu-system") && ($0[kCGWindowName as String] as? String ?? "").hasSuffix(":" + port) && Self.bounds($0).width > 100 }), let window = makeWindow(info, ios: false) { mapped[device.id] = window }
                devices.append(device)
            }
            let runningNames = Set(androidCache.map { $0.name.replacingOccurrences(of: " ", with: "_") })
            library += avds.filter { !runningNames.contains($0) }.map { ["id": $0, "name": $0.replacingOccurrences(of: "_", with: " "), "platform": "android"] }
            lock.lock(); running = devices; available = library; windows = mapped; lock.unlock()
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
        guard let adb, let result = try? command(adb, ["devices"], timeout: 3) else { return [] }
        return result.text.split(separator: "\n").compactMap { line in
            let columns = line.split(whereSeparator: { $0.isWhitespace })
            guard columns.count >= 2, columns[1] == "device", columns[0].hasPrefix("emulator-") else { return nil }
            let serial = String(columns[0])
            guard let dimensions = try? command(adb, ["-s", serial, "shell", "wm", "size"], timeout: 3), let range = dimensions.text.range(of: "[0-9]+x[0-9]+", options: .regularExpression) else { return nil }
            let numbers = dimensions.text[range].split(separator: "x").compactMap { Int($0) }
            guard numbers.count == 2 else { return nil }
            let title = (try? command(adb, ["-s", serial, "emu", "avd", "name"], timeout: 3).text.components(separatedBy: .newlines).first) ?? serial
            return Device(id: serial, name: title.replacingOccurrences(of: "_", with: " "), platform: "android", width: min(numbers[0], numbers[1]), height: max(numbers[0], numbers[1]))
        }
    }
    func boot(_ id: String) throws {
        guard let entry = library().first(where: { $0["id"] as? String == id }) else { throw WispError("Unknown or already running device") }
        if entry["platform"] as? String == "android" {
            guard let emulator else { throw WispError("Android Emulator not found") }
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/nohup"); p.arguments = [emulator, "-avd", id, "-no-snapshot-load"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice; try p.run()
        } else {
            let r = try command("/usr/bin/xcrun", ["simctl", "boot", id], timeout: 60)
            guard r.status == 0 else { throw WispError(String(decoding: r.error, as: UTF8.self)) }
            _ = try command("/usr/bin/open", ["-a", "Simulator", "--args", "-CurrentDeviceUDID", id])
        }
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
