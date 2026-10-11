import Foundation
import Darwin

// Nonblocking BSD sockets with dispatch readiness sources. All callbacks and
// writes are confined to one network queue; no thread or blocking read per peer.
final class SocketTransport {
    private struct Write {
        let data: Data
        var offset: Int = 0
        let completion: (Error?) -> Void
    }
    let fd: Int32
    let peer: String
    let sourceAddress: String
    private let queue: DispatchQueue
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var writes: [Write] = []
    private var bufferedBytes = 0
    private var closed = false
    private var finishing = false
    private var finishCompletion: ((Error?) -> Void)?
    var onData: ((Data) -> Void)?
    var onEnd: (() -> Void)?
    init(fd: Int32, peer: String, sourceAddress: String, queue: DispatchQueue) {
        self.fd = fd; self.peer = peer; self.sourceAddress = sourceAddress; self.queue = queue
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }
    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readReady() }
        let descriptor = fd
        source.setCancelHandler { Darwin.close(descriptor) }
        reader = source; source.resume()
    }
    private func readReady() {
        guard !closed else { return }
        var bytes = [UInt8](repeating: 0, count: 65_536)
        // Yield after a bounded batch so a flooding peer cannot starve ACKs.
        for _ in 0..<8 {
            let n = Darwin.read(fd, &bytes, bytes.count)
            if n > 0 { onData?(Data(bytes.prefix(n))); if closed { return } }
            else if n == 0 { cancel(); return }
            else if errno == EAGAIN || errno == EWOULDBLOCK { return }
            else if errno != EINTR { cancel(); return }
        }
    }
    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        if data.isEmpty { completion(nil); return }
        guard !closed, !finishing, bufferedBytes + data.count <= 16_777_216 else { completion(WispError("Socket closed or send buffer full")); cancel(); return }
        writes.append(Write(data: data, completion: completion)); bufferedBytes += data.count
        flush()
    }
    func finish(completion: @escaping (Error?) -> Void) {
        guard !closed else { completion(WispError("Socket closed")); return }
        finishing = true; finishCompletion = completion; flush()
    }
    private func flush() {
        guard !closed else { return }
        var budget = 1_048_576
        while !writes.isEmpty && budget > 0 {
            let n = writes[0].data.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return 0 }
                return Darwin.write(fd, base.advanced(by: writes[0].offset), writes[0].data.count - writes[0].offset)
            }
            if n > 0 {
                writes[0].offset += n; bufferedBytes -= n; budget -= n
                if writes[0].offset == writes[0].data.count {
                    let completion = writes.removeFirst().completion; completion(nil)
                    if closed { return }
                }
            } else if n < 0 && errno == EINTR { continue }
            else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { waitWritable(); return }
            else { cancel(); return }
        }
        if !writes.isEmpty { waitWritable(); return }
        writer?.cancel(); writer = nil
        if finishing, let completion = finishCompletion {
            finishCompletion = nil
            if shutdown(fd, SHUT_WR) == 0 { completion(nil) } else { completion(WispError("Socket shutdown failed")); cancel() }
        }
    }
    private func waitWritable() {
        guard writer == nil, !closed else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.flush() }
        writer = source; source.resume()
    }
    func cancel() {
        guard !closed else { return }; closed = true
        writer?.cancel(); writer = nil; reader?.cancel(); reader = nil
        let pending = writes; writes.removeAll(); bufferedBytes = 0
        let final = finishCompletion; finishCompletion = nil
        onEnd?(); onData = nil; onEnd = nil
        for write in pending { write.completion(WispError("Connection closed")) }
        final?(WispError("Connection closed"))
    }
}

final class SocketListener {
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var closed = false
    private let fd: Int32
    var onAccept: ((SocketTransport) -> Void)?
    init(port: Int, lan: Bool, queue: DispatchQueue) throws {
        self.queue = queue
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw WispError("Cannot create listening socket") }
        fd = descriptor
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian; address.sin_addr = in_addr(s_addr: lan ? INADDR_ANY : inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0, listen(descriptor, 64) == 0 else { let message = String(cString: strerror(errno)); Darwin.close(descriptor); throw WispError("Cannot listen on port \(port): \(message)") }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    }
    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptReady() }
        let descriptor = fd; source.setCancelHandler { Darwin.close(descriptor) }
        self.source = source; source.resume()
    }
    private func acceptReady() {
        guard !closed else { return }
        for _ in 0..<16 {
            var address = sockaddr_storage(), length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let descriptor = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &length) } }
            if descriptor < 0 { if errno == EINTR { continue }; return }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST)), port = [CChar](repeating: 0, count: Int(NI_MAXSERV))
            _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getnameinfo($0, length, &host, socklen_t(host.count), &port, socklen_t(port.count), NI_NUMERICHOST | NI_NUMERICSERV) } }
            let addressString = String(cString: host)
            let transport = SocketTransport(fd: descriptor, peer: addressString + ":" + String(cString: port), sourceAddress: addressString, queue: queue)
            if let onAccept { onAccept(transport) } else { transport.start(); transport.cancel() }
        }
    }
    func cancel() { guard !closed else { return }; closed = true; source?.cancel(); source = nil }
}
