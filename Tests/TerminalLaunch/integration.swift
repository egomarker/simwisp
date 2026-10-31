import Foundation
import Darwin

func runIntegration(_ root: URL, _ helper: URL) throws {
    let q = DispatchQueue(label: "terminal.launch.integration")
    var delivered: [(String, String)] = []
    let bridge = TerminalLaunchBridge(queue: q, helper: helper) { id, script in delivered.append((id, script.path)); return String(repeating: "a", count: 32) }
    let app = try q.sync { try bridge.register(String(repeating: "b", count: 32)) }
    defer { q.sync { bridge.stop() } }
    func generated(_ name: String) throws -> URL {
        let directory = root.appendingPathComponent(name + "/node_modules/.generated")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("launchPackager.command")
        try Data("#!/bin/bash\nprintf 'synthetic-packager-only\\n'\n".utf8).write(to: script)
        try Data("export PROJECT_ROOT=fixture\nexport REACT_NATIVE_PATH=fixture\nexport RCT_METRO_PORT=18089\n".utf8).write(to: directory.appendingPathComponent(".packager.env"))
        return script
    }
    let a = try generated("Owned project A 'quoted;literal"), b = try generated("Owned project B")
    let opening = DispatchGroup()
    for file in [a, b] {
        opening.enter()
        DispatchQueue.global().async { _ = try? command("/usr/bin/open", ["-a", app.path, file.path], timeout: 6); opening.leave() }
    }
    check("concurrent macOS open requests finish within bounded time", opening.wait(timeout: .now() + 8) == .success)
    let deadlineForOpens = monotonic() + 8
    while q.sync(execute: { delivered.count < 2 }) && monotonic() < deadlineForOpens { Thread.sleep(forTimeInterval: 0.025) }
    check("concurrent documents both reach originating session bridge", q.sync { delivered.count == 2 && delivered.allSatisfy { $0.0 == String(repeating: "b", count: 32) } })
    check("concurrent launch paths preserve exact owned projects", q.sync { Set(delivered.map { $0.1 }) == Set([a.path, b.path]) })
    let otherID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let otherApp = try q.sync { try bridge.register(otherID) }
    let config = otherApp.appendingPathComponent("Contents/Resources/bridge.json")
    let sent = try command(helper.path, ["--request", config.path, a.path], timeout: 6)
    check("second originating session has independent launch identity", sent.status == 0 && q.sync { delivered.count == 3 && delivered.last?.0 == otherID })
    let directory = root.appendingPathComponent("PTY project 'quoted;literal")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("launchPackager.command")
    try Data("printf 'PROFILE=%s\\nDIR=%s\\nTERMINAL=%s\\nHOST_FINISHED\\n' \"$PROFILE_OK\" \"$PWD\" \"$REACT_TERMINAL\"\n".utf8).write(to: script)
    try Data("export PROFILE_OK=owned-profile\n".utf8).write(to: root.appendingPathComponent(".bash_profile"))
    var master: Int32 = -1, slave: Int32 = -1, size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw WispError("Fixture openpty failed") }
    defer { Darwin.close(master) }
    var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
    defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
    for fd in [Int32(0), 1, 2] { posix_spawn_file_actions_adddup2(&actions, slave, fd) }
    posix_spawn_file_actions_addclose(&actions, master); posix_spawn_file_actions_addclose(&actions, slave)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
    let host = root.appendingPathComponent("shell-host").path
    var argv: [UnsafeMutablePointer<CChar>?] = [host, directory.path, "/bin/bash", script.path].map { value in value.withCString { strdup($0) } } + [nil]
    var envp: [UnsafeMutablePointer<CChar>?] = ["HOME=" + root.path, "SHELL=/bin/bash", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "TERM=xterm-256color", "REACT_TERMINAL=" + app.path].map { value in value.withCString { strdup($0) } } + [nil]
    defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
    var pid: pid_t = 0
    let spawned = argv.withUnsafeMutableBufferPointer { a in envp.withUnsafeMutableBufferPointer { e in posix_spawn(&pid, host, &actions, &attributes, a.baseAddress!, e.baseAddress!) } }
    Darwin.close(slave); guard spawned == 0 else { throw WispError("Owned shell fixture spawn failed") }
    _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
    var output = Data(), status: Int32 = 0, ended = false, sentExit = false
    let deadline = monotonic() + 8
    while monotonic() < deadline {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(master, &buffer, buffer.count); if count > 0 { output.append(contentsOf: buffer.prefix(count)) }
        if !sentExit && String(decoding: output, as: UTF8.self).contains("HOST_FINISHED") { _ = "exit\n".withCString { Darwin.write(master, $0, 5) }; sentExit = true }
        if waitpid(pid, &status, WNOHANG) == pid { ended = true; break }
        Thread.sleep(forTimeInterval: 0.01)
    }
    if !ended { _ = kill(pid, SIGTERM); _ = waitpid(pid, &status, 0) }
    let text = String(decoding: output, as: UTF8.self)
    guard let physical = realpath(directory.path, nil) else { throw WispError("Fixture realpath failed") }
    defer { free(physical) }
    let physicalDirectory = String(cString: physical)
    try jsonData(["output": text, "expectedDirectory": directory.path, "canonicalDirectory": physicalDirectory, "ended": ended, "status": status]).write(to: root.appendingPathComponent("integration-debug.json"))
    check("owned terminal host exits cleanly after packager script", ended && status == 0)
    check("login initialization supplies shell profile configuration", text.contains("PROFILE=owned-profile"))
    check("PTY launch directory survives spaces quotes and semicolons", text.contains("DIR=" + physicalDirectory))
    check("PTY command inherits correct originating launcher capability", text.contains("TERMINAL=" + app.path))
    check("packager path is passed literally without command injection", text.contains("HOST_FINISHED") && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("literal").path))
    try jsonData(["passed": true, "checks": checks, "selfContained": true, "realMetro": false, "productService": false, "ownedPTY": true]).write(to: root.appendingPathComponent("integration.json"))
    print("Terminal launch integration: \(checks.count) checks PASS")
}
