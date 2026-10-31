import Foundation
import Darwin
import CryptoKit

// Private same-user IPC, scoped to live originating PTYs. No HTTP endpoint,
// terminal-output parsing, discovery timer, or project-file modification.
final class TerminalLaunchBridge {
    private let queue: DispatchQueue
    private let helper: URL
    private let onLaunch: (String, URL) throws -> String
    private let onError: (String) -> Void
    private var root: URL?
    private var listener: DispatchSourceRead?
    private var registrations: [String: (id: String, app: URL)] = [:]
    private var peers: [Int32: Peer] = [:]
    private var stopped = false
    private final class Peer {
        let fd: Int32
        let source: DispatchSourceRead
        var bytes = Data()
        var timeout: DispatchWorkItem?
        init(_ fd: Int32, queue: DispatchQueue) { self.fd = fd; source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue) }
    }
    init(queue: DispatchQueue, helper: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/SimwispTerminal"), onLaunch: @escaping (String, URL) throws -> String, onError: @escaping (String) -> Void = { _ in }) {
        self.queue = queue; self.helper = helper; self.onLaunch = onLaunch; self.onError = onError
    }
    func register(_ id: String) throws -> URL {
        guard !stopped, FileManager.default.isExecutableFile(atPath: helper.path) else { throw WispError("Terminal launcher is missing; rebuild Simwisp") }
        try start()
        let token = UUID().uuidString + UUID().uuidString
        let app = root!.appendingPathComponent(id + ".app"), contents = app.appendingPathComponent("Contents")
        do {
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.copyItem(at: helper, to: contents.appendingPathComponent("MacOS/SimwispTerminal"))
            let info: [String: Any] = ["CFBundleExecutable": "SimwispTerminal", "CFBundleIdentifier": "io.simwisp.terminal." + id, "CFBundleName": "Simwisp Metro", "CFBundlePackageType": "APPL", "LSUIElement": true, "CFBundleDocumentTypes": [["CFBundleTypeExtensions": ["command"], "CFBundleTypeRole": "Viewer", "LSHandlerRank": "None"]]]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
            try jsonData(["socket": root!.appendingPathComponent("bridge.sock").path, "capability": token]).write(to: contents.appendingPathComponent("Resources/bridge.json"), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: contents.appendingPathComponent("Resources/bridge.json").path)
            registrations[token] = (id, app); return app
        } catch { try? FileManager.default.removeItem(at: app); throw error }
    }
    func unregister(_ id: String) {
        for (token, value) in registrations.filter({ $0.value.id == id }) { registrations.removeValue(forKey: token); try? FileManager.default.removeItem(at: value.app) }
    }
    static func validate(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("\0") else { throw WispError("Invalid terminal launch path") }
        let input = URL(fileURLWithPath: path)
        guard input.lastPathComponent == "launchPackager.command" else { throw WispError("Only React Native packager launchers are accepted") }
        func ownedFile(_ url: URL, limit: Int64) throws {
            var stat = Darwin.stat()
            guard lstat(url.path, &stat) == 0, (stat.st_mode & S_IFMT) == S_IFREG, stat.st_uid == geteuid(), stat.st_size > 0, stat.st_size <= limit, stat.st_mode & 0o022 == 0 else { throw WispError("Packager launch files must be private to the current user and regular bounded files") }
        }
        try ownedFile(input, limit: 65536)
        let script = input.resolvingSymlinksInPath(), env = script.deletingLastPathComponent().appendingPathComponent(".packager.env")
        try ownedFile(env, limit: 8192)
        let text = String(decoding: try Data(contentsOf: env), as: UTF8.self)
        guard ["export PROJECT_ROOT=", "export REACT_NATIVE_PATH=", "export RCT_METRO_PORT="].allSatisfy(text.contains) else { throw WispError("Missing React Native packager environment") }
        return script
    }
    static func identity(_ script: URL) throws -> String {
        let data = try Data(contentsOf: script.deletingLastPathComponent().appendingPathComponent(".packager.env"))
        return script.path + ":" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func start() throws {
        if root != nil { return }
        var template = Array("/tmp/simwisp-term-XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else { throw WispError("Cannot create terminal launch directory") }
        let directory = URL(fileURLWithPath: String(cString: made)).resolvingSymlinksInPath()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { try? FileManager.default.removeItem(at: directory); throw WispError("Cannot create terminal launch socket") }
        var ready = false
        defer { if !ready { Darwin.close(fd); try? FileManager.default.removeItem(at: directory) } }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(directory.appendingPathComponent("bridge.sock").path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw WispError("Terminal socket path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { dest in bytes.withUnsafeBytes { dest.copyBytes(from: $0) } }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0, listen(fd, 4) == 0 else { throw WispError("Cannot listen for terminal launches") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC); _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptReady(fd) }; source.setCancelHandler { Darwin.close(fd) }
        listener = source; root = directory; ready = true; source.resume()
    }
    private func acceptReady(_ listenerFD: Int32) {
        for _ in 0..<8 {
            let fd = accept(listenerFD, nil, nil); if fd < 0 { return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard !stopped, peers.count < 4, getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { Darwin.close(fd); continue }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC); _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var one: Int32 = 1; _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
            let peer = Peer(fd, queue: queue); peers[fd] = peer
            peer.source.setEventHandler { [weak self, weak peer] in if let peer { self?.readReady(peer) } }
            peer.source.setCancelHandler { Darwin.close(fd) }; peer.source.resume()
            let deadline = DispatchWorkItem { [weak self, weak peer] in if let peer, self?.peers[fd] === peer { self?.close(peer) } }
            peer.timeout = deadline; queue.asyncAfter(deadline: .now() + 3, execute: deadline)
        }
    }
    private func readReady(_ peer: Peer) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(peer.fd, &buffer, buffer.count)
        if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { return }
        guard count > 0 else { close(peer); return }
        peer.bytes.append(contentsOf: buffer.prefix(count))
        guard peer.bytes.count <= 16384 else { close(peer); return }
        guard peer.bytes.contains(10) else { return }
        let message = dictionary(peer.bytes), capability = message["capability"] as? String ?? ""
        var result: [String: Any] = ["ok": false]
        if let registration = registrations[capability], let path = message["script"] as? String {
            do { let script = try Self.validate(path); result = ["ok": true, "id": try onLaunch(registration.id, script)] }
            catch { onError(registration.id); result["error"] = "Terminal request refused. Check the originating terminal and session limit." }
        }
        var reply = jsonData(result); reply.append(10)
        _ = reply.withUnsafeBytes { Darwin.write(peer.fd, $0.baseAddress, $0.count) }
        close(peer)
    }
    private func close(_ peer: Peer) { peers.removeValue(forKey: peer.fd); peer.timeout?.cancel(); peer.timeout = nil; peer.source.cancel() }
    func stop() {
        stopped = true; for peer in Array(peers.values) { close(peer) }
        listener?.cancel(); listener = nil; registrations.removeAll()
        if let root { try? FileManager.default.removeItem(at: root) }; root = nil
    }
}
