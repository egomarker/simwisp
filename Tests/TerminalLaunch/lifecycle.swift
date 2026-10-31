import Foundation
import Darwin

func runLifecycle(_ root: URL, _ helper: URL) throws {
    let queue = DispatchQueue(label: "terminal.launch.lifecycle"), id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    var launches = 0
    let bridge = TerminalLaunchBridge(queue: queue, helper: helper) { _, _ in launches += 1; return id }
    let app = try queue.sync { try bridge.register(id) }
    defer { queue.sync { bridge.stop() } }
    let config = dictionary(try Data(contentsOf: app.appendingPathComponent("Contents/Resources/bridge.json")))
    let script = root.appendingPathComponent("launchPackager.command")
    try Data("printf 'SCRIPT_FINISHED\\n'\nexit 7\n".utf8).write(to: script)
    try Data("export PROJECT_ROOT=fixture\nexport REACT_NATIVE_PATH=fixture\nexport RCT_METRO_PORT=18089\n".utf8).write(to: root.appendingPathComponent(".packager.env"))
    func connectPeer() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { throw WispError("Fixture socket failed") }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array((config["socket"] as! String).utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { out in bytes.withUnsafeBytes { out.copyBytes(from: $0) } }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { Darwin.close(fd); throw WispError("Fixture connect failed") }
        var timeout = timeval(tv_sec: 5, tv_usec: 0), one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        return fd
    }
    func send(_ fd: Int32, _ data: Data) { _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } }
    func receive(_ fd: Int32) -> Data { var buffer = [UInt8](repeating: 0, count: 4096); let n = Darwin.read(fd, &buffer, buffer.count); return n > 0 ? Data(buffer.prefix(n)) : Data() }
    if ProcessInfo.processInfo.environment["TERMINAL_LAUNCH_RESUME"] != "pty" {
    let fragmented = try connectPeer(), request = jsonData(["capability": config["capability"]!, "script": script.path])
    let half = request.count / 2
    send(fragmented, request.prefix(half)); Thread.sleep(forTimeInterval: 0.05)
    check("partial request does not launch before completion", queue.sync { launches == 0 })
    var remaining = Data(request.dropFirst(half)); remaining.append(10); send(fragmented, remaining)
    let accepted = dictionary(receive(fragmented)); Darwin.close(fragmented)
    check("fragmented authenticated request is acknowledged once", accepted["ok"] as? Bool == true && queue.sync { launches == 1 })
    let malformed = try connectPeer(); send(malformed, Data("not-json\n".utf8))
    check("malformed framed request is refused", dictionary(receive(malformed))["ok"] as? Bool == false); Darwin.close(malformed)
    let slow = try connectPeer(), begin = monotonic(); send(slow, Data("{".utf8))
    check("incomplete request expires and closes its socket", receive(slow).isEmpty && monotonic() - begin < 4.5); Darwin.close(slow)
    check("invalid and expired requests never spawn", queue.sync { launches == 1 })
    let again = try command(helper.path, ["--request", app.appendingPathComponent("Contents/Resources/bridge.json").path, script.path], timeout: 6)
    check("bridge remains usable after incomplete request timeout", again.status == 0 && queue.sync { launches == 2 })
    }
    // Real TerminalHost, a private HOME and a login profile, but no user shell
    // setup, project/dependency, device, service, or real packager is involved.
    try Data("export PROFILE_OK=owned\n".utf8).write(to: root.appendingPathComponent(".bash_profile"))
    var master: Int32 = -1, slave: Int32 = -1
    guard openpty(&master, &slave, nil, nil, nil) == 0 else { throw WispError("Fixture PTY failed") }
    defer { Darwin.close(master) }
    var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
    defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
    for fd in [Int32(0), 1, 2] { posix_spawn_file_actions_adddup2(&actions, slave, fd) }
    posix_spawn_file_actions_addclose(&actions, master); posix_spawn_file_actions_addclose(&actions, slave)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
    let host = root.appendingPathComponent("shell-host").path
    var argv: [UnsafeMutablePointer<CChar>?] = [host, root.path, "/bin/bash", script.path].map { value in value.withCString { strdup($0) } } + [nil]
    var envp: [UnsafeMutablePointer<CChar>?] = ["HOME=" + root.path, "SHELL=/bin/bash", "PATH=/usr/bin:/bin", "TERM=xterm-256color"].map { value in value.withCString { strdup($0) } } + [nil]
    defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
    var pid: pid_t = 0
    let spawned = argv.withUnsafeMutableBufferPointer { a in envp.withUnsafeMutableBufferPointer { e in posix_spawn(&pid, host, &actions, &attributes, a.baseAddress!, e.baseAddress!) } }
    Darwin.close(slave); guard spawned == 0 else { throw WispError("Fixture spawn failed") }
    _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
    var status: Int32 = 0, ended = false, output = Data()
    func drain() { var bytes = [UInt8](repeating: 0, count: 4096); let count = Darwin.read(master, &bytes, bytes.count); if count > 0 && output.count < 16384 { output.append(contentsOf: bytes.prefix(count)) } }
    let deadline = monotonic() + 4
    while monotonic() < deadline { drain(); if waitpid(pid, &status, WNOHANG) == pid { ended = true; break }; Thread.sleep(forTimeInterval: 0.01) }
    if !ended {
        _ = kill(pid, SIGTERM)
        let cleanup = monotonic() + 2
        while monotonic() < cleanup { drain(); if waitpid(pid, &status, WNOHANG) == pid { ended = true; break }; Thread.sleep(forTimeInterval: 0.01) }
    }
    try jsonData(["ended": ended, "status": status, "output": String(decoding: output, as: UTF8.self)]).write(to: root.appendingPathComponent("lifecycle-pty.json"))
    check("finished script ends launch PTY without extra shell or user input", ended)
    check("script exit status reaches terminal host unchanged", (status & 0x7f) == 0 && ((status >> 8) & 0xff) == 7)
    queue.sync { bridge.stop() }
    check("stopped bridge removes session launch application", !FileManager.default.fileExists(atPath: app.path))
    try jsonData(["passed": true, "checks": checks, "selfContained": true, "realMetro": false, "productService": false]).write(to: root.appendingPathComponent("lifecycle.json"))
    print("Terminal launch lifecycle: \(checks.count) checks PASS")
}
