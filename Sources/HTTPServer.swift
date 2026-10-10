import Foundation
import CryptoKit

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data
    var host: String { headers["host"] ?? "" }
    var sameOrigin: Bool { headers["origin"] == "http://" + host }
}
struct HTTPResponse {
    var status = 200
    var body = Data()
    var type = "application/json; charset=utf-8"
    var headers: [String: String] = [:]
    static func json(_ value: Any, status: Int = 200) -> HTTPResponse { HTTPResponse(status: status, body: jsonData(value)) }
}

// Dispatch-driven BSD sockets carry bounded HTTP/1.1 and RFC6455 messages.
// One HTTP request per connection, no permissive CORS.
final class HTTPServer {
    let queue = DispatchQueue(label: "Simwisp.network", qos: .userInitiated)
    private var listener: SocketListener?
    private var connections: [UUID: ClientConnection] = [:]
    private var activity: NSObjectProtocol?
    var route: ((HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void)?
    var upgrade: ((HTTPRequest, ClientConnection) -> Void)?
    var authorize: ((HTTPRequest) -> Bool)?
    var stateChanged: ((String) -> Void)?
    func start(port: Int, lan: Bool) throws {
        let listener = try SocketListener(port: port, lan: lan, queue: queue)
        listener.onAccept = { [weak self] connection in
            guard let self, self.connections.count < 64 else { connection.start(); connection.cancel(); return }
            if self.activity == nil {
                self.activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Serving simulator streams and browser requests")
            }
            let client = ClientConnection(connection: connection, server: self)
            self.connections[client.id] = client; client.start()
        }
        self.listener = listener; listener.start()
        queue.async { [weak self, weak listener] in
            if let self, self.listener === listener { self.stateChanged?("Running") }
        }
    }
    func stop(completion: @escaping () -> Void = {}) {
        queue.async {
            self.listener?.cancel(); self.listener = nil
            for client in Array(self.connections.values) { client.close() }
            self.connections.removeAll(); completion()
        }
    }
    func removed(_ id: UUID) {
        connections.removeValue(forKey: id)
        if connections.isEmpty, let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }
    func validHost(_ value: String) -> Bool {
        guard value.count < 256, let components = URLComponents(string: "http://" + value), let host = components.host,
              components.user == nil, components.password == nil, components.path.isEmpty else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == localAddress() || host == ProcessInfo.processInfo.hostName
    }
}

final class ClientConnection {
    let id = UUID()
    let connection: SocketTransport
    private weak var server: HTTPServer?
    private var buffer = Data()
    private var websocket = false
    private var closing = false
    private var handledHTTP = false
    private var responded = false
    private var queuedBytes = 0
    private var fragmented = Data()
    private var fragmentOpcode: UInt8 = 0
    private var timeout: DispatchWorkItem?
    var onMessage: ((String) -> Void)?
    var onClose: (() -> Void)?
    var peer: String { connection.peer }
    var isClosed: Bool { closing }
    init(connection: SocketTransport, server: HTTPServer) { self.connection = connection; self.server = server }
    func start() {
        connection.onEnd = { [weak self] in self?.close() }
        connection.onData = { [weak self] data in self?.receive(data) }
        connection.start(); armTimeout(15)
    }
    private func armTimeout(_ seconds: Double) {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close() }
        timeout = work; server?.queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    private func receive(_ data: Data) {
        guard !closing else { return }
        buffer.append(data)
        guard buffer.count <= 131_072 else { close(); return }
        if websocket { armTimeout(45); parseFrames() }
        else if !handledHTTP { parseHTTP() }
    }
    private func parseHTTP() {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { if buffer.count > 16_384 { respond(.json(["error": "Headers too large"], status: 431)) }; return }
        guard end.lowerBound < 16_384, let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { close(); return }
        let lines = head.components(separatedBy: "\r\n"), first = lines.first?.components(separatedBy: " ") ?? []
        guard first.count == 3, first[2] == "HTTP/1.1", first[1].hasPrefix("/"), let url = URLComponents(string: "http://local" + first[1]) else { respond(.json(["error": "Bad request"], status: 400)); return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { close(); return }
            let key = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard headers[key] == nil else { respond(.json(["error": "Duplicate header"], status: 400)); return }
            headers[key] = value
        }
        guard server?.validHost(headers["host"] ?? "") == true, headers["transfer-encoding"] == nil else { respond(.json(["error": "Invalid host or request framing"], status: 400)); return }
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0, length <= 65_536 else { respond(.json(["error": "Body too large"], status: 413)); return }
        let total = end.upperBound + length
        guard buffer.count >= total else { return }
        var query: [String: String] = [:]; for item in url.queryItems ?? [] { query[item.name] = item.value }
        let request = HTTPRequest(method: first[0], path: url.path, query: query, headers: headers, body: Data(buffer[end.upperBound..<total]))
        buffer = Data(buffer.dropFirst(total)); handledHTTP = true; timeout?.cancel()
        if headers["upgrade"]?.lowercased() == "websocket" {
            guard request.method == "GET", request.sameOrigin, server?.authorize?(request) == true,
                  headers["connection"]?.lowercased().split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains("upgrade") == true,
                  headers["sec-websocket-version"] == "13", let key = headers["sec-websocket-key"], Data(base64Encoded: key)?.count == 16,
                  request.path.hasPrefix("/ws/"), request.path != "/ws/pty" else { respond(.json(["error": "WebSocket denied"], status: 403)); return }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            sendRaw(Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8))
            websocket = true; armTimeout(45)
            server?.upgrade?(request, self); parseFrames()
        } else {
            guard let server, let route = server.route else { respond(.json(["error": "Unavailable"], status: 503)); return }
            armTimeout(70)
            route(request) { [weak self, weak server] response in server?.queue.async { self?.respond(response) } }
        }
    }
    func respond(_ response: HTTPResponse) {
        guard !closing, !responded else { return }
        responded = true; handledHTTP = true; timeout?.cancel()
        let descriptions = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 413: "Payload Too Large", 431: "Request Header Fields Too Large", 500: "Internal Server Error", 503: "Service Unavailable"]
        var headers = response.headers
        headers["Content-Type"] = response.type; headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"; headers["Cache-Control"] = "no-store"; headers["X-Content-Type-Options"] = "nosniff"
        headers["Referrer-Policy"] = "no-referrer"; headers["X-Frame-Options"] = "DENY"
        let head = "HTTP/1.1 \(response.status) \(descriptions[response.status] ?? "Error")\r\n" + headers.keys.sorted().map { "\($0): \(headers[$0]!)\r\n" }.joined() + "\r\n"
        var data = Data(head.utf8); data.append(response.body)
        sendRaw(data) { [weak self] in
            guard let self, !self.closing else { return }
            // Flush the body before half-closing; peer EOF (or the bounded
            // final timeout) releases the descriptor without truncating bytes.
            self.connection.finish { [weak self] error in
                if error != nil { self?.close() } else { self?.armTimeout(5) }
            }
        }
    }
    private func parseFrames() {
        while buffer.count >= 2 && !closing {
            let bytes = [UInt8](buffer.prefix(14))
            let fin = bytes[0] & 0x80 != 0, opcode = bytes[0] & 0x0f
            guard bytes[0] & 0x70 == 0, bytes[1] & 0x80 != 0 else { close(); return }
            var length = UInt64(bytes[1] & 0x7f), offset = 2
            if length == 126 {
                guard bytes.count >= 4 else { return }; length = UInt64(bytes[2]) << 8 | UInt64(bytes[3]); offset = 4
                guard length >= 126 else { close(); return }
            } else if length == 127 {
                guard bytes.count >= 10 else { return }; length = bytes[2..<10].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }; offset = 10
                guard length >= 65_536, bytes[2] & 0x80 == 0 else { close(); return }
            }
            guard length <= 65_536, opcode < 8 || (fin && length <= 125) else { close(); return }
            guard buffer.count >= offset + 4 + Int(length) else { return }
            let mask = Array(buffer[offset..<offset + 4]); offset += 4
            let payload = Data(buffer[offset..<offset + Int(length)].enumerated().map { $0.element ^ mask[$0.offset % 4] })
            buffer = Data(buffer.dropFirst(offset + Int(length)))
            switch opcode {
            case 8: sendFrame(payload, opcode: 8) { [weak self] in self?.close() }; return
            case 9: sendFrame(payload, opcode: 10)
            case 10: break
            case 1:
                guard fragmentOpcode == 0 else { close(); return }
                if fin { deliverText(payload) } else { fragmentOpcode = 1; fragmented = payload }
            case 0:
                guard fragmentOpcode == 1, fragmented.count + payload.count <= 65_536 else { close(); return }
                fragmented.append(payload)
                if fin { let message = fragmented; fragmented.removeAll(keepingCapacity: false); fragmentOpcode = 0; deliverText(message) }
            default: close(); return
            }
        }
    }
    private func deliverText(_ data: Data) { guard let text = String(data: data, encoding: .utf8) else { close(); return }; onMessage?(text) }
    func sendJSON(_ value: [String: Any]) { sendFrame(jsonData(value), opcode: 1) }
    func sendBinary(_ value: Data, completion: (() -> Void)? = nil) { sendFrame(value, opcode: 2, completion: completion) }
    func ping() { sendFrame(Data(), opcode: 9) }
    private func sendFrame(_ payload: Data, opcode: UInt8, completion: (() -> Void)? = nil) {
        guard websocket, !closing else { return }
        var frame = Data([0x80 | opcode])
        if payload.count < 126 { frame.append(UInt8(payload.count)) }
        else if payload.count <= 65_535 { frame.append(126); var size = UInt16(payload.count).bigEndian; withUnsafeBytes(of: &size) { frame.append(contentsOf: $0) } }
        else { frame.append(127); var size = UInt64(payload.count).bigEndian; withUnsafeBytes(of: &size) { frame.append(contentsOf: $0) } }
        frame.append(payload); sendRaw(frame, completion: completion)
    }
    private func sendRaw(_ data: Data, completion: (() -> Void)? = nil) {
        guard !closing, queuedBytes + data.count < 16_777_216 else { close(); return }
        queuedBytes += data.count
        connection.send(data) { [weak self] error in
            guard let self else { return }; self.queuedBytes -= data.count
            if error != nil { self.close() } else { completion?() }
        }
    }
    func close() {
        guard !closing else { return }; closing = true
        timeout?.cancel(); timeout = nil; onClose?(); onMessage = nil; onClose = nil
        connection.cancel(); server?.removed(id); buffer.removeAll(); fragmented.removeAll()
    }
}
