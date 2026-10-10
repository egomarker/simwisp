import Foundation
import Darwin

// All PTY/session state belongs to this separate readiness-driven queue. The
// simulator network/capture queues never spawn shells, read PTYs, or poll them.
final class TerminalManager {
    private let queue = DispatchQueue(label: "Simwisp.terminal", qos: .userInitiated)
    private let network: DispatchQueue
    private let settings: Settings
    private var sessions: [String: TerminalSession] = [:]
    private var bindings: [UUID: TerminalSession] = [:]
    private var stopping = false
    private var stopCompletion: (() -> Void)?
    init(settings: Settings, network: DispatchQueue) { self.settings = settings; self.network = network }
    func attach(_ request: HTTPRequest, client: ClientConnection) {
        // Called on the network queue: install callbacks before queuing spawn,
        // so a disconnect during spawn cannot leave a falsely attached shell.
        let budget = TerminalInputBudget()
        client.startTerminalKeepalive()
        client.onBinary = { [weak self, weak client] data in
            guard let self, let client else { return }
            guard budget.bytes + data.count <= 65_536 else { client.close(); return }
            budget.bytes += data.count
            self.queue.async {
                let done = { self.network.async { budget.bytes -= data.count } }
                guard let session = self.bindings[client.id] else { done(); return }
                session.write(data, completion: done)
            }
        }
        client.onMessage = { [weak self, weak client] text in
            guard let self, let client else { return }
            let message = dictionary(Data(text.utf8))
            self.queue.async {
                guard let session = self.bindings[client.id] else { return }
                switch message["type"] as? String {
                case "resize":
                    if let cols = message["cols"] as? Int, let rows = message["rows"] as? Int { session.resize(cols: cols, rows: rows) }
                case "output_ack": session.acknowledge(client.id)
                case "close": session.terminate()
                default: break
                }
            }
        }
        client.onClose = { [weak self] in
            guard let self else { return }
            self.queue.async { self.bindings.removeValue(forKey: client.id)?.detach(client.id) }
        }
        queue.async {
            guard !self.stopping else { self.network.async { client.close() }; return }
            do {
                let requested = request.query["session"] ?? ""
                let session: TerminalSession
                if let existing = self.sessions[requested], !existing.closing {
                    session = existing
                } else {
                    guard self.sessions.count < 8 else { throw WispError("Terminal limit reached (8 sessions)") }
                    session = try TerminalSession(settings: self.settings, queue: self.queue, network: self.network)
                    self.sessions[session.id] = session
                    session.onExit = { [weak self, weak session] in
                        guard let self, let session else { return }
                        self.sessions.removeValue(forKey: session.id)
                        self.bindings = self.bindings.filter { $0.value !== session }
                        if self.stopping && self.sessions.isEmpty { let complete = self.stopCompletion; self.stopCompletion = nil; complete?() }
                    }
                }
                self.bindings[client.id] = session
                session.attach(client)
            } catch {
                self.network.async { client.sendJSON(["type": "terminal_error", "message": error.localizedDescription]); client.closeAfterSending() }
            }
        }
    }
    var diagnostics: [String: Any] {
        queue.sync {
            ["enabled": settings.terminalEnabled == true, "sessions": sessions.count,
             "attached": sessions.values.filter { $0.attached }.count,
             "read_events": sessions.values.reduce(UInt64(0)) { $0 + $1.readEvents },
             "write_events": sessions.values.reduce(UInt64(0)) { $0 + $1.writeEvents },
             "replay_bytes": sessions.values.reduce(0) { $0 + $1.replayBytes },
             "awaiting_output_ack": sessions.values.filter { $0.awaitingAck }.count]
        }
    }
    func snapshots(_ completion: @escaping ([[String: Any]]) -> Void) {
        queue.async { completion(self.sessions.values.map { ["id": $0.id, "pid": $0.pid, "attached": $0.attached, "closing": $0.closing] }) }
    }
    func stop(completion: @escaping () -> Void) {
        queue.async {
            self.stopping = true
            guard !self.sessions.isEmpty else { completion(); return }
            self.stopCompletion = completion
            for session in Array(self.sessions.values) { session.terminate() }
        }
    }
}
private final class TerminalInputBudget { var bytes = 0 } // network queue only

private final class TerminalSession {
    private struct Input { let data: Data; var offset = 0; let completion: () -> Void }
    let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let pid: pid_t
    private let fd: Int32
    private let queue: DispatchQueue
    private let network: DispatchQueue
    private var reader: DispatchSourceRead!
    private var writer: DispatchSourceWrite?
    private var process: DispatchSourceProcess!
    private var readerPaused = false
    private var client: ClientConnection?
    private var input: [Input] = []
    private var inputBytes = 0
    private var replay = Data()
    private var expiry: DispatchSourceTimer?
    private var ackDeadline: DispatchSourceTimer?
    private var killDeadline: DispatchWorkItem?
    private var childExited = false
    private var eof = false
    private var finished = false
    private var exitStatus: Int32 = 0
    private(set) var closing = false
    private(set) var awaitingAck = false
    private(set) var readEvents: UInt64 = 0
    private(set) var writeEvents: UInt64 = 0
    var attached: Bool { client != nil }
    var replayBytes: Int { replay.count }
    var onExit: (() -> Void)?
    init(settings: Settings, queue: DispatchQueue, network: DispatchQueue) throws {
        self.queue = queue; self.network = network
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/SimwispShell").path
        guard FileManager.default.isExecutableFile(atPath: helper) else { throw WispError("Terminal helper is missing; rebuild Simwisp") }
        let env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        guard shell.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: shell) else { throw WispError("Login shell is unavailable") }
        var master: Int32 = -1, slave: Int32 = -1
        var size = winsize(ws_row: 30, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw WispError("Cannot allocate terminal") }
        var spawned = false
        defer { Darwin.close(slave); if !spawned { Darwin.close(master) } }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC); _ = fcntl(slave, F_SETFD, FD_CLOEXEC)
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        for descriptor in [Int32(0), 1, 2] { posix_spawn_file_actions_adddup2(&actions, slave, descriptor) }
        posix_spawn_file_actions_addclose(&actions, master); posix_spawn_file_actions_addclose(&actions, slave)
        var defaults = sigset_t(), mask = sigset_t()
        sigfillset(&defaults); sigdelset(&defaults, SIGKILL); sigdelset(&defaults, SIGSTOP); sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attributes, &defaults); posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
        // Inherit shell-useful values, not the app's entire environment (which
        // could contain service credentials). Login profiles run normally.
        let keys = ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "SSH_AUTH_SOCK", "ANDROID_HOME", "ANDROID_SDK_ROOT", "DEVELOPER_DIR"]
        var environment = env.filter { keys.contains($0.key) }
        environment["HOME"] = NSHomeDirectory(); environment["SHELL"] = shell
        environment["PATH"] = env["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["TERM"] = "xterm-256color"; environment["COLORTERM"] = "truecolor"
        var argv: [UnsafeMutablePointer<CChar>?] = [helper, settings.projectDirectory, shell].map { value in value.withCString { strdup($0) } }
        var envp: [UnsafeMutablePointer<CChar>?] = environment.sorted { $0.key < $1.key }.map { entry in "\(entry.key)=\(entry.value)".withCString { strdup($0) } }
        argv.append(nil); envp.append(nil)
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var child: pid_t = 0
        let result = argv.withUnsafeBufferPointer { args in envp.withUnsafeBufferPointer { vars in posix_spawn(&child, helper, &actions, &attributes, args.baseAddress!, vars.baseAddress!) } }
        guard result == 0 else { throw WispError("Cannot spawn terminal: \(String(cString: strerror(result)))") }
        spawned = true; fd = master; pid = child
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let descriptor = fd
        reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in self?.readReady() }
        reader.setCancelHandler { Darwin.close(descriptor) }
        reader.resume(); pauseRead()
        process = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        process.setEventHandler { [weak self] in self?.reap() }; process.resume()
    }
    func attach(_ next: ClientConnection) {
        expiry?.schedule(deadline: .distantFuture)
        ackDeadline?.cancel(); ackDeadline = nil; awaitingAck = false
        if let old = client, old !== next { network.async { old.close() } }
        client = next
        let sid = id
        network.async { guard !next.isClosed else { return }; next.sendJSON(["type": "session", "id": sid]) }
        if !replay.isEmpty { send(replay) } else { resumeRead() }
    }
    func detach(_ identifier: UUID) {
        guard client?.id == identifier else { return }
        client = nil; awaitingAck = false; ackDeadline?.cancel(); ackDeadline = nil
        pauseRead() // detached noisy commands backpressure in the kernel, not a busy discard loop
        if closing { return }
        if childExited { finish(); return }
        if expiry == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in if self?.client == nil { self?.terminate() } }
            expiry = timer; timer.schedule(deadline: .now() + 30 * 60); timer.resume()
        } else { expiry?.schedule(deadline: .now() + 30 * 60) }
    }
    private func pauseRead() { if !readerPaused { reader.suspend(); readerPaused = true } }
    private func resumeRead() { if readerPaused && !closing && !eof { reader.resume(); readerPaused = false } }
    private func readReady() {
        guard !closing, client != nil, !awaitingAck else { return }
        readEvents &+= 1
        var bytes = [UInt8](repeating: 0, count: 32_768)
        let count = Darwin.read(fd, &bytes, bytes.count)
        if count > 0 {
            let data = Data(bytes.prefix(count)); replay.append(data)
            if replay.count > 65_536 { replay.removeFirst(replay.count - 65_536) }
            send(data)
        } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            eof = true; pauseRead()
            if childExited { finish() }
        }
    }
    private func send(_ data: Data) {
        guard let client, !closing else { return }
        awaitingAck = true; pauseRead()
        network.async { guard !client.isClosed else { return }; client.sendBinary(data) }
        if ackDeadline == nil {
            let identifier = client.id
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in
                guard let self, self.awaitingAck, self.client?.id == identifier else { return }
                self.network.async { client.close() }
            }
            ackDeadline = timer; timer.schedule(deadline: .now() + 10); timer.resume()
        } else { ackDeadline?.schedule(deadline: .now() + 10) }
        // Reuse a single one-shot timer, rather than queueing canceled deadline
        // work items for every output chunk under sustained high throughput.
    }
    func acknowledge(_ identifier: UUID) {
        guard client?.id == identifier, awaitingAck else { return }
        awaitingAck = false; ackDeadline?.schedule(deadline: .distantFuture)
        if eof && childExited { finish() } else { resumeRead() }
    }
    func resize(cols: Int, rows: Int) {
        guard !closing, (1...500).contains(cols), (1...300).contains(rows) else { return }
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(fd, TIOCSWINSZ, &size) // kernel signals the foreground job's process group
    }
    func write(_ data: Data, completion: @escaping () -> Void) {
        guard !closing, !childExited, inputBytes + data.count <= 65_536 else { completion(); return }
        if data.isEmpty { completion(); return }
        input.append(Input(data: data, completion: completion)); inputBytes += data.count; flushInput()
    }
    private func flushInput() {
        guard !closing, !childExited else { return }
        writeEvents &+= 1
        var budget = 65_536
        while !input.isEmpty && budget > 0 {
            let count = input[0].data.withUnsafeBytes { bytes in Darwin.write(fd, bytes.baseAddress!.advanced(by: input[0].offset), input[0].data.count - input[0].offset) }
            if count > 0 {
                input[0].offset += count; inputBytes -= count; budget -= count
                if input[0].offset == input[0].data.count { input.removeFirst().completion() }
            } else if count < 0 && errno == EINTR { continue }
            else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { waitWritable(); return }
            else { terminate(); return }
        }
        if input.isEmpty { writer?.cancel(); writer = nil } else { waitWritable() }
    }
    private func waitWritable() {
        guard writer == nil, !closing else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.flushInput() }; writer = source; source.resume()
    }
    func terminate() {
        guard !closing else { return }; closing = true
        expiry?.cancel(); expiry = nil; ackDeadline?.cancel(); ackDeadline = nil
        let foreground = tcgetpgrp(fd)
        if foreground > 0 && foreground != pid && foreground != getpgrp() { _ = kill(-foreground, SIGHUP); _ = kill(-foreground, SIGTERM) }
        if !childExited { _ = kill(-pid, SIGHUP); _ = kill(-pid, SIGTERM); _ = kill(pid, SIGTERM) }
        closeIO()
        if let client { self.client = nil; network.async { client.sendJSON(["type": "exit", "status": 0]); client.closeAfterSending() } }
        if childExited { finish(); return }
        let child = pid
        let work = DispatchWorkItem { if kill(child, 0) == 0 { _ = kill(-child, SIGKILL); _ = kill(child, SIGKILL) } }
        killDeadline = work; queue.asyncAfter(deadline: .now() + 1, execute: work)
    }
    private func reap() {
        guard !childExited else { return }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        guard result == pid || (result < 0 && errno == ECHILD) else { return }
        childExited = true; exitStatus = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        process.cancel(); killDeadline?.cancel(); killDeadline = nil
        writer?.cancel(); writer = nil
        let pending = input; input.removeAll(); inputBytes = 0; pending.forEach { $0.completion() }
        if closing || client == nil || eof { finish() }
        // Otherwise drain final PTY output through the normal browser ACK path.
    }
    private func closeIO() {
        writer?.cancel(); writer = nil
        if readerPaused { reader.resume(); readerPaused = false }; reader.cancel()
        let pending = input; input.removeAll(); inputBytes = 0; pending.forEach { $0.completion() }
    }
    private func finish() {
        guard childExited, !finished else { return }; finished = true; closing = true
        expiry?.cancel(); expiry = nil; ackDeadline?.cancel(); ackDeadline = nil; killDeadline?.cancel(); killDeadline = nil
        closeIO(); process.cancel()
        if let client { self.client = nil; let status = exitStatus; network.async { client.sendJSON(["type": "exit", "status": status]); client.closeAfterSending() } }
        replay.removeAll(); let complete = onExit; onExit = nil; complete?()
    }
}
