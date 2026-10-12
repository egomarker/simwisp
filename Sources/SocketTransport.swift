import Foundation
import Network

// Network.framework performs TLS and readiness I/O; no blocking peer threads.
// Application bytes, completions and lifecycle remain on HTTPServer.queue.
final class SocketTransport {
    let peer: String
    let sourceAddress: String
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var bufferedBytes = 0
    private var sequence: UInt64 = 0
    private var writes: [UInt64: (Int, (Error?) -> Void)] = [:]
    private var closed = false
    private var finishing = false
    private var finishCompletion: ((Error?) -> Void)?
    var onData: ((Data) -> Void)?
    var onEnd: (() -> Void)?
    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection; self.queue = queue
        if case .hostPort(let host, let port) = connection.endpoint {
            sourceAddress = String(describing: host); peer = sourceAddress + ":" + String(port.rawValue)
        } else { sourceAddress = "unknown"; peer = "unknown" }
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready: self.receive()
            case .failed, .cancelled: self.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
    }
    private func receive() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty { self.onData?(data) }
            guard !self.closed else { return }
            if complete || error != nil { self.cancel() } else { self.receive() }
        }
    }
    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        if data.isEmpty { completion(nil); return }
        guard !closed, !finishing, writes.count < 1024, bufferedBytes + data.count <= 16_777_216 else { completion(WispError("Socket closed or send buffer full")); cancel(); return }
        sequence &+= 1; let id = sequence
        writes[id] = (data.count, completion); bufferedBytes += data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, let write = self.writes.removeValue(forKey: id) else { return }
            self.bufferedBytes -= write.0; write.1(error)
            if error != nil { self.cancel() }
        })
    }
    func finish(completion: @escaping (Error?) -> Void) {
        guard !closed, !finishing else { completion(WispError("Socket closed")); return }
        finishing = true; finishCompletion = completion
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
            guard let self, let done = self.finishCompletion else { return }
            self.finishCompletion = nil; done(error)
            if error != nil { self.cancel() }
        })
    }
    func cancel() {
        guard !closed else { return }; closed = true
        connection.stateUpdateHandler = nil; connection.cancel()
        let pending = Array(writes.values); writes.removeAll(); bufferedBytes = 0
        let final = finishCompletion; finishCompletion = nil
        let ended = onEnd; onData = nil; onEnd = nil; ended?()
        for write in pending { write.1(WispError("Connection closed")) }
        final?(WispError("Connection closed"))
    }
}

final class SocketListener {
    private let queue: DispatchQueue
    private let listener: NWListener
    private var closed = false
    var onAccept: ((SocketTransport) -> Void)?
    var onState: ((String) -> Void)?
    init(port: Int, lan: Bool, queue: DispatchQueue, tls: TLSIdentity) throws {
        self.queue = queue
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let parameters = NWParameters(tls: tls.options(), tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: lan ? "0.0.0.0" : "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!)
        listener = try NWListener(using: parameters)
    }
    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready: self.onState?("Running")
            case .failed(let error): self.onState?("HTTPS listener failed: \(error.localizedDescription)"); self.cancel()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, !self.closed else { connection.cancel(); return }
            let transport = SocketTransport(connection: connection, queue: self.queue)
            if let onAccept = self.onAccept { onAccept(transport) } else { transport.cancel() }
        }
        listener.start(queue: queue)
    }
    func cancel() {
        guard !closed else { return }; closed = true
        listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil; listener.cancel()
    }
}
