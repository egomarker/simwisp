import Foundation
import CoreMedia

// Private wire protocol, deliberately pinned to the installed/tested server tag.
// v5 adds session packets and moves CONFIG/KEY to bits 62/61 (not older scrcpy framing).
enum AndroidBackendMode: String, CaseIterable { case auto, scrcpy, current }
// JPEG is capture-only and deliberately excluded from Auto/input resolution.
enum AndroidCaptureMode: String, CaseIterable { case auto, scrcpy, current, jpeg }
struct AndroidBackendChoice: Equatable {
    var capture: AndroidCaptureMode = .auto
    var input: AndroidBackendMode = .auto
    init(capture: String? = nil, input: String? = nil) {
        self.capture = AndroidCaptureMode(rawValue: capture ?? "auto") ?? .auto
        self.input = AndroidBackendMode(rawValue: input ?? "auto") ?? .auto
    }
}
// A portrait-normalized pixel budget, not input/display coordinates. Rotation
// alone must not restart a source. scrcpy preserves its display aspect ratio and
// rounds the long-edge limit to the Android codec's supported size alignment.
struct ScrcpyVideoSize: Equatable {
    let width: Int, height: Int
    static let headless = ScrcpyVideoSize(width: 360, height: 800)!
    init?(width: Int, height: Int) {
        guard (8...8192).contains(width), (8...8192).contains(height) else { return nil }
        self.width=min(width,height);self.height=max(width,height)
    }
    var maxSize: Int { height }
    func bitRate(quality: Int) -> Int {
        // Owner-requested200kbps/maxQP44 experiment at the current quality1 setting.
        // Other qualities retain the shared Mac-window curve; Mac is unchanged.
        quality == 1 ? 200_000 : H264VideoPolicy.bitRate(width:width,height:height,quality:quality)
    }
}

extension Data {
    mutating func scrcpyAppend<T: FixedWidthInteger>(_ value: T) { var v = value.bigEndian; Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) } }
    func scrcpyUInt(_ offset: Int, _ count: Int) -> UInt64 { self[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) } }
}
enum ScrcpyWire {
    static let version = "5.0.1"
    static let maxPacket = 8_388_608
    enum Header { case session(Int, Int), packet(Int, UInt64, Bool, Bool) }
    static func header(_ data: Data) throws -> Header {
        guard data.count == 12 else { throw WispError("Invalid scrcpy header") }
        let flags = data.scrcpyUInt(0, 8)
        if flags & (1 << 63) != 0 {
            let w = Int(data.scrcpyUInt(4, 4)), h = Int(data.scrcpyUInt(8, 4))
            guard (1...8192).contains(w), (1...8192).contains(h) else { throw WispError("Invalid scrcpy session dimensions") }
            return .session(w, h)
        }
        let size = Int(data.scrcpyUInt(8, 4))
        guard (1...maxPacket).contains(size) else { throw WispError("Invalid scrcpy packet size") }
        return .packet(size, flags & ((1 << 61) - 1), flags & (1 << 62) != 0, flags & (1 << 61) != 0)
    }
    static func nals(_ data: Data) throws -> [Data] {
        let b = [UInt8](data)
        guard !b.isEmpty, b.count <= maxPacket else { throw WispError("Invalid H.264 packet") }
        var starts: [(Int, Int)] = [], i = 0
        while i + 2 < b.count {
            if b[i] == 0 && b[i+1] == 0 {
                if b[i+2] == 1 { starts.append((i, 3)); i += 3; continue }
                if i + 3 < b.count && b[i+2] == 0 && b[i+3] == 1 { starts.append((i, 4)); i += 4; continue }
            }
            i += 1
        }
        guard starts.first?.0 == 0, starts.count <= 256 else { throw WispError("scrcpy must send Annex-B H.264") }
        var result: [Data] = []
        for n in starts.indices {
            let lo = starts[n].0 + starts[n].1, hi = n + 1 < starts.count ? starts[n+1].0 : b.count
            guard hi > lo else { throw WispError("Empty H.264 NAL") }
            result.append(Data(b[lo..<hi]))
        }
        return result
    }
    static func avcc(_ nals: [Data]) -> Data {
        var data = Data(); for nal in nals { data.scrcpyAppend(UInt32(nal.count)); data.append(nal) }; return data
    }
    static func configuration(_ sps: Data, _ pps: Data) throws -> Data {
        guard sps.count >= 4, sps.count <= 65535, pps.count > 1, pps.count <= 65535, sps.first.map({ $0 & 31 }) == 7, pps.first.map({ $0 & 31 }) == 8,
              sps[1] == 66 else { throw WispError("scrcpy requires Baseline H.264 without B-frames") }
        var avcc = Data([1, sps[1], sps[2], sps[3], 255, 225]); avcc.scrcpyAppend(UInt16(sps.count)); avcc.append(sps); avcc.append(1); avcc.scrcpyAppend(UInt16(pps.count)); avcc.append(pps)
        return try H264SPS.lowLatencyAVCC(avcc)
    }
    static func touch(action: UInt8, pointer: UInt64 = UInt64.max - 1, x: Double, y: Double, width: Int, height: Int) throws -> Data {
        guard (1...8192).contains(width), (1...8192).contains(height), [0,1,2].contains(action), x.isFinite, y.isFinite else { throw WispError("Invalid scrcpy touch geometry") }
        var d = Data([2, action]); d.scrcpyAppend(pointer)
        d.scrcpyAppend(UInt32(min(width - 1, Int(clamp(x) * Double(width))))); d.scrcpyAppend(UInt32(min(height - 1, Int(clamp(y) * Double(height)))))
        d.scrcpyAppend(UInt16(width)); d.scrcpyAppend(UInt16(height)); d.scrcpyAppend(UInt16(action == 1 ? 0 : 65535)); d.scrcpyAppend(UInt32(0)); d.scrcpyAppend(UInt32(0)); return d
    }
    static func key(_ code: UInt32, down: Bool) -> Data { var d = Data([0, down ? 0 : 1]); d.scrcpyAppend(code); d.scrcpyAppend(UInt32(0)); d.scrcpyAppend(UInt32(0)); return d }
    static func text(_ text: String) throws -> Data {
        let bytes = Data(text.utf8); guard bytes.count <= 300 else { throw WispError("scrcpy text packet too long") }
        var d = Data([1]); d.scrcpyAppend(UInt32(bytes.count)); d.append(bytes); return d
    }
    // Control-only mode needs physical display coordinates; do not guess headless orientation.
    static func displaySize(_ text: String) throws -> (Int, Int) {
        let lines = text.components(separatedBy: .newlines).filter { $0.contains("DisplayInfo{") && ($0.contains("displayId 0") || $0.contains("displayId=0")) }
        // Base/native orientation can differ from the currently rotated override.
        let ordered = lines.sorted { ($0.contains("mOverrideDisplayInfo") ? 0 : 1) < ($1.contains("mOverrideDisplayInfo") ? 0 : 1) }
        for line in ordered {
            if let range = line.range(of: "real [0-9]+ x [0-9]+", options: .regularExpression) {
                let parts = line[range].split(separator: " "); if let w = Int(parts[1]), let h = Int(parts[3]), (1...8192).contains(w), (1...8192).contains(h) { return (w,h) }
            }
        }
        throw WispError("Cannot verify Android display coordinates for scrcpy input")
    }
}

// Four bounded access units, not a latest P-frame slot: dropping any dependency
// invalidates the whole chain. Resume only at an IDR after requesting RESET_VIDEO.
struct ScrcpyFrames {
    private var frames: [H264Frame] = []
    private var bytes = 0
    private(set) var needsKey = true
    private(set) var generation: UInt64 = 0
    var count: Int { frames.count }
    private(set) var dropped = 0
    mutating func reset() { frames.removeAll(); bytes = 0; needsKey = true; generation &+= 1 }
    mutating func append(_ frame: H264Frame) -> Bool {
        if frames.count >= 4 || bytes + frame.payload.count > ScrcpyWire.maxPacket { dropped += frames.count; reset() }
        if needsKey && !frame.keyframe { dropped += 1; return false }
        needsKey = false; frames.append(frame); bytes += frame.payload.count; return true
    }
    mutating func take() -> H264Frame? { guard !frames.isEmpty else { return nil }; let f = frames.removeFirst(); bytes -= f.payload.count; return f }
}
