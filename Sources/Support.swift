import Foundation
import AppKit
import ApplicationServices
import Security
import Darwin

struct WispError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func jsonData(_ value: Any) -> Data { (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8) }
func dictionary(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
func clamp(_ x: Double, _ low: Double = 0, _ high: Double = 1) -> Double { x.isFinite ? min(high, max(low, x)) : low }
func monotonic() -> Double { ProcessInfo.processInfo.systemUptime }
func log(_ message: String) { fputs("[Simwisp] \(message)\n", stderr) }

struct CommandResult {
    let status: Int32
    let output: Data
    let error: Data
    var text: String { String(decoding: output, as: UTF8.self) }
}

// Blocking tool calls are restricted to worker queues, never the UI/network queues.
// Read both pipes concurrently so a verbose tool cannot deadlock on stderr.
func command(_ path: String, _ arguments: [String], timeout: Double = 10) throws -> CommandResult {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = arguments
    let out = Pipe(), err = Pipe(); p.standardOutput = out; p.standardError = err
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
    p.environment = env
    try p.run()
    let group = DispatchGroup(), lock = NSLock()
    var stdout = Data(), stderr = Data()
    group.enter(); DispatchQueue.global().async { let data = out.fileHandleForReading.readDataToEndOfFile(); lock.lock(); stdout = data; lock.unlock(); group.leave() }
    group.enter(); DispatchQueue.global().async { let data = err.fileHandleForReading.readDataToEndOfFile(); lock.lock(); stderr = data; lock.unlock(); group.leave() }
    let deadline = monotonic() + timeout
    while p.isRunning && monotonic() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    if p.isRunning {
        p.terminate(); Thread.sleep(forTimeInterval: 0.1)
        if p.isRunning { Darwin.kill(p.processIdentifier, SIGKILL) }
    }
    p.waitUntilExit()
    guard group.wait(timeout: .now() + 3) == .success else { throw WispError("Tool output did not close") }
    return CommandResult(status: p.terminationStatus, output: stdout, error: stderr)
}

struct Settings: Codable {
    var port = 4141
    var shareLAN = false
    // Optional for backward-compatible decoding of pre-terminal saved settings.
    var terminalEnabled: Bool? = nil
    var fps = 60
    var quality = 20
    var projectDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    var androidSDK = ""
    var androidTitlebar = 28
    var pairingToken = ""
    var pairing = PairingSettings()
    // Transient startup error, deliberately excluded from saved settings.
    var loadingError: String? = nil
    init() {}
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case port, shareLAN, terminalEnabled, fps, quality, projectDirectory, androidSDK, androidTitlebar, pairingToken, pairing
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 4141
        shareLAN = try c.decodeIfPresent(Bool.self, forKey: .shareLAN) ?? false
        terminalEnabled = try c.decodeIfPresent(Bool.self, forKey: .terminalEnabled)
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? 60
        quality = try c.decodeIfPresent(Int.self, forKey: .quality) ?? 20
        projectDirectory = try c.decodeIfPresent(String.self, forKey: .projectDirectory) ?? FileManager.default.homeDirectoryForCurrentUser.path
        androidSDK = try c.decodeIfPresent(String.self, forKey: .androidSDK) ?? ""
        androidTitlebar = try c.decodeIfPresent(Int.self, forKey: .androidTitlebar) ?? 28
        pairingToken = try c.decodeIfPresent(String.self, forKey: .pairingToken) ?? ""
        pairing = try c.decodeIfPresent(PairingSettings.self, forKey: .pairing) ?? PairingSettings()
    }
    static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Simwisp/settings.json")
    }
    static func load(from file: URL = Settings.file) -> Settings {
        var s = Settings(), needsSave = false
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.deletingLastPathComponent().path)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                let data = try Data(contentsOf: file)
                s = try JSONDecoder().decode(Settings.self, from: data)
                needsSave = dictionary(data)["pairing"] == nil
            } catch {
                s.loadingError = "Cannot read settings.json. Repair its JSON/types on the Mac; existing credentials were not overwritten."
                return s
            }
        }
        if s.pairingToken.isEmpty {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { fatalError("Secure randomness unavailable") }
            s.pairingToken = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            needsSave = true
        }
        if needsSave && !s.save(to: file) {
            s.loadingError = "Cannot save settings.json securely. Check permissions on the Mac before starting the server."
        }
        return s
    }
    @discardableResult
    func save(to file: URL = Settings.file) -> Bool {
        // Native controls must not replace owner data after a failed load.
        guard loadingError == nil else { log("Refusing to save settings after a loading error."); return false }
        do {
            // Retain unknown top-level owner settings when adding the new group.
            var object: [String: Any] = [:]
            if FileManager.default.fileExists(atPath: file.path) {
                guard let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else { throw WispError("Invalid settings JSON") }
                object = saved
            }
            for key in CodingKeys.allCases { object.removeValue(forKey: key.rawValue) }
            object.merge(dictionary(try JSONEncoder().encode(self))) { _, new in new }
            let dir = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch { log("Cannot finish saving settings. Check their JSON and permissions on the Mac."); return false }
    }
}

func localAddress() -> String? {
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
    defer { freeifaddrs(pointer) }

    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    var candidates: [(String, String)] = []

    while let item = cursor {
        defer { cursor = item.pointee.ifa_next }

        guard let addr = item.pointee.ifa_addr,
              addr.pointee.sa_family == UInt8(AF_INET)
        else { continue }

        let name = String(cString: item.pointee.ifa_name)

        var host = [CChar](
            repeating: 0,
            count: Int(NI_MAXHOST)
        )

        if getnameinfo(
            addr,
            socklen_t(addr.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        ) == 0 {
            let ip = String(cString: host)

            if ip != "127.0.0.1" {
                candidates.append((name, ip))
            }
        }
    }

    return candidates.first(where: {
        $0.0.hasPrefix("en")
    })?.1 ?? candidates.first?.1
}

func localAddresses() -> Set<String> {
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0, let first = pointer else {
        return []
    }

    defer { freeifaddrs(pointer) }

    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    var addresses = Set<String>()

    while let item = cursor {
        defer { cursor = item.pointee.ifa_next }

        guard let addr = item.pointee.ifa_addr,
              addr.pointee.sa_family == UInt8(AF_INET)
        else { continue }

        var host = [CChar](
            repeating: 0,
            count: Int(NI_MAXHOST)
        )

        if getnameinfo(
            addr,
            socklen_t(addr.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        ) == 0 {
            addresses.insert(String(cString: host))
        }
    }

    return addresses
}

struct Usage {
    var cpu: Double = 0
    var memory: UInt64 = 0
    private var lastTime = monotonic()
    private var lastCPU: Double? = nil
    mutating func sample() {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let total = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        let now = monotonic()
        cpu = lastCPU.map { max(0, (total - $0) / max(0.01, now - lastTime) * 100) } ?? 0
        lastTime = now; lastCPU = total
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        if result == KERN_SUCCESS { memory = info.phys_footprint }
    }
}

func axAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let p = axAttribute(element, kAXPositionAttribute), let s = axAttribute(element, kAXSizeAttribute), CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}
