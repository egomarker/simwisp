import Foundation
import VideoToolbox
import CoreImage
import CryptoKit
import ScreenCaptureKit

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    guard condition() else { fatalError("FAIL: " + name) }; checks += 1
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let encoder = try H264Encoder(width: 405, height: 901)
let color = CIImage(color: CIColor(red: 0.15, green: 0.70, blue: 0.25)).cropped(to: CGRect(x: 0, y: 0, width: 405, height: 901))
var frames: [H264Frame] = []
for n in 0..<90 {
    let frame = try encoder.encode(color, quality: n < 30 ? 20 : (n < 60 ? 95 : 1), fps: n < 60 ? 60 : 30, forceKeyframe: n == 0 || n == 30 || n == 60)
    expect(!frame.payload.isEmpty, "access unit \(n)")
    expect(frame.description.first == 1 && frame.description.count >= 7, "AVCC \(n)")
    expect(frame.codec.hasPrefix("avc1.42"), "baseline profile \(n)")
    expect(frame.timestamp > (frames.last?.timestamp ?? 0), "strict PTS \(n)")
    frames.append(frame)
}
expect(frames[0].keyframe && frames[30].keyframe && frames[60].keyframe, "requested recovery IDRs")
expect(frames.dropFirst().contains { !$0.keyframe }, "real inter-frame H.264, not all-intra")
let frame = frames[0]
expect(frame.width == 405 && frame.height == 901 && frame.codedWidth == 406 && frame.codedHeight == 902, "odd sizes padded, visible size retained")
let config = frame.configuration(epoch: 7)
expect(config["type"] as? String == "video_config" && config["epoch"] as? UInt32 == 7, "configuration identity")
expect(Data(base64Encoded: config["description"] as! String) == frame.description, "configuration roundtrip")
let packet = frame.packet(epoch: 0x12345678, id: 0x9abcdef0)
expect(Array(packet.prefix(8)) == [0x53,0x57,0x56,0x31,1,0,0,0], "wire magic/key/reserved")
expect(Array(packet[8..<16]) == [0x12,0x34,0x56,0x78,0x9a,0xbc,0xde,0xf0], "wire epoch/id endian")
expect(packet[16..<24].reduce(UInt64(0)) { $0 << 8 | UInt64($1) } == frame.timestamp, "wire timestamp")
expect(Data(packet.dropFirst(24)) == frame.payload, "wire AVCC payload")

// Reconstruct the exact browser decoder description, then decode actual IDR +
// dependent P access units using VideoToolbox. No ScreenCaptureKit/host input.
let avcc = [UInt8](frame.description)
var offset = 6, sets: [[UInt8]] = []
func readSet() { let count = Int(avcc[offset]) << 8 | Int(avcc[offset+1]); offset += 2; sets.append(Array(avcc[offset..<offset+count])); offset += count }
for _ in 0..<Int(avcc[5] & 31) { readSet() }
let ppsCount = Int(avcc[offset]); offset += 1
for _ in 0..<ppsCount { readSet() }
expect(sets.count == 2 && avcc[4] & 3 == 3, "SPS/PPS and 4-byte NAL lengths")
var format: CMFormatDescription?
let formatStatus = sets[0].withUnsafeBufferPointer { sps in sets[1].withUnsafeBufferPointer { pps in
    let pointers = [sps.baseAddress!, pps.baseAddress!], sizes = [sps.count, pps.count]
    return pointers.withUnsafeBufferPointer { p in sizes.withUnsafeBufferPointer { z in
        CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: p.baseAddress!, parameterSetSizes: z.baseAddress!, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
    } }
} }
expect(formatStatus == noErr && format != nil, "AVCC creates decoder format")
final class Sink {
    let lock = NSLock()
    var image: CVPixelBuffer?
    var count = 0
    var error: OSStatus = noErr
}
let sink = Sink()
var decoder: VTDecompressionSession?
var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { pointer, _, status, _, image, _, _ in
    let sink = Unmanaged<Sink>.fromOpaque(pointer!).takeUnretainedValue()
    sink.lock.withLock { sink.error = status; sink.image = image; sink.count += 1 }
}, decompressionOutputRefCon: Unmanaged.passUnretained(sink).toOpaque())
expect(VTDecompressionSessionCreate(allocator: nil, formatDescription: format!, decoderSpecification: nil, imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary, outputCallback: &callback, decompressionSessionOut: &decoder) == noErr, "native decoder creation")
for value in frames.prefix(30) {
    var block: CMBlockBuffer?
    expect(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: value.payload.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: value.payload.count, flags: 0, blockBufferOut: &block) == noErr, "decode buffer")
    expect(value.payload.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: value.payload.count) } == noErr, "decode copy")
    var sample: CMSampleBuffer?, size = value.payload.count
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(value.timestamp), timescale: 1_000_000), decodeTimeStamp: .invalid)
    expect(CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, "decode sample")
    expect(VTDecompressionSessionDecodeFrame(decoder!, sampleBuffer: sample!, flags: [], frameRefcon: nil, infoFlagsOut: nil) == noErr, "decode dependent H.264 frame")
}
expect(VTDecompressionSessionWaitForAsynchronousFrames(decoder!) == noErr, "drain native decode")
expect(sink.count == 30 && sink.error == noErr && sink.image != nil, "all dependent frames decoded")
let decoded = sink.image!
expect(CVPixelBufferGetWidth(decoded) == 406 && CVPixelBufferGetHeight(decoded) == 902, "decoded padded dimensions")
CVPixelBufferLockBaseAddress(decoded, .readOnly)
let base = CVPixelBufferGetBaseAddress(decoded)!.assumingMemoryBound(to: UInt8.self)
let pixel = base.advanced(by: 100 * CVPixelBufferGetBytesPerRow(decoded) + 100 * 4)
expect(abs(Int(pixel[0]) - 64) < 15 && abs(Int(pixel[1]) - 179) < 15 && abs(Int(pixel[2]) - 38) < 15, "decoded synthetic colors within lossy tolerance")
CVPixelBufferUnlockBaseAddress(decoded, .readOnly)
VTDecompressionSessionInvalidate(decoder!); encoder.close()
do { _ = try encoder.encode(color, quality: 20, fps: 60, forceKeyframe: true); fatalError("closed encoder accepted work") } catch { checks += 1 }

// Feed the production ScreenCaptureKit sample handler with synthetic buffers.
// This does not start SCStream or request permissions/discovery/ADB.
let target = DeviceWindow(id: 123, pid: 0, title: "fixture", bounds: CGRect(x: 0, y: 0, width: 200, height: 120), crop: CGRect(x: 20, y: 10, width: 101, height: 81))
let capture = WindowCapture(target: target)
var sourcePixel: CVPixelBuffer?
expect(CVPixelBufferCreate(nil, 200, 120, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &sourcePixel) == noErr, "synthetic capture pixel")
CIContext(options: [.cacheIntermediates: false]).render(CIImage(color: .white), to: sourcePixel!)
var sourceFormat: CMFormatDescription?
expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: sourcePixel!, formatDescriptionOut: &sourceFormat) == noErr, "synthetic capture format")
func sample(_ status: SCFrameStatus) -> CMSampleBuffer {
    var sample: CMSampleBuffer?
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: sourcePixel!, formatDescription: sourceFormat!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, "synthetic SCK sample")
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sample!, createIfNecessary: true)!
    let dict = Unmanaged<NSMutableDictionary>.fromOpaque(CFArrayGetValueAtIndex(attachments, 0)).takeUnretainedValue()
    dict[SCStreamFrameInfo.status.rawValue] = status.rawValue
    return sample!
}
expect(!capture.hasFrame, "capture starts without frame")
capture.receive(sample(.complete), type: .screen)
expect(capture.hasFrame, "complete synthetic sample retained")
let cropped = try capture.h264(quality: 20, fps: 60, forceKeyframe: true, dataSaver: true)!
expect(cropped.width == 101 && cropped.height == 81 && cropped.codedWidth == 102 && cropped.codedHeight == 82, "production host-point crop and even padding")
let skipped = try capture.h264(quality: 20, fps: 60, forceKeyframe: false, dataSaver: true)
expect(skipped == nil && capture.hasFrame, "idle Data saver skips encoding without losing live state")
let recovered = try capture.h264(quality: 20, fps: 60, forceKeyframe: true, dataSaver: true)
expect(recovered?.keyframe == true, "forced recovery bypasses Data saver")
let repeated = try capture.h264(quality: 20, fps: 60, forceKeyframe: false, dataSaver: false)
expect(repeated != nil && repeated!.timestamp > recovered!.timestamp, "non-saver repeat is freshly encoded with new PTS")
expect(capture.counters["h264_encodes"] as? UInt64 == 3, "no encoded-frame cache/replay")
capture.receive(sample(.idle), type: .screen)
expect(capture.hasFrame && capture.counters["fresh_capture_frames"] as? UInt64 == 1, "idle SCK callback keeps latest without version increment")
capture.receive(sample(.blank), type: .screen)
expect(!capture.hasFrame, "blank capture invalidates readiness")
let blank = try capture.h264(quality: 20, fps: 60, forceKeyframe: false, dataSaver: false)
expect(blank == nil, "blank capture cannot encode stale image")
capture.receive(sample(.complete), type: .screen)
expect(capture.hasFrame && capture.counters["fresh_capture_frames"] as? UInt64 == 2, "fresh sample recovers capture")
capture.receive(sample(.suspended), type: .screen)
expect(!capture.hasFrame, "suspended capture clears latest")
expect(CaptureHealth.shared.snapshot["active"] as? Int == 0, "no actual capture stream started")

let tlsDir = root.appendingPathComponent("tls")
let first = try TLSIdentity(directory: tlsDir, addresses: ["192.0.2.1"], hostname: "fixture.local")
let cert = first.certificate, pem = try Data(contentsOf: tlsDir.appendingPathComponent("server.pem"))
let second = try TLSIdentity(directory: tlsDir, addresses: ["192.0.2.1"], hostname: "fixture.local")
let secondPEM = try Data(contentsOf: tlsDir.appendingPathComponent("server.pem"))
expect(cert == second.certificate && pem == secondPEM, "persistent CA and leaf across launches")
let updated = try TLSIdentity(directory: tlsDir, addresses: ["192.0.2.2"], hostname: "fixture.local")
let updatedPEM = try Data(contentsOf: tlsDir.appendingPathComponent("server.pem"))
expect(updated.certificate == cert && pem != updatedPEM, "SAN refresh preserves client CA trust")
for name in ["root.key", "server.key", "server.p12", "server.passphrase"] {
    let attributes = try FileManager.default.attributesOfItem(atPath: tlsDir.appendingPathComponent(name).path)
    expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "owner-only \(name)")
}
let attributes = try FileManager.default.attributesOfItem(atPath: tlsDir.path)
expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "owner-only TLS directory")
expect(first.fingerprint == SHA256.hash(data: cert).map { String(format: "%02X", $0) }.joined(separator: ":"), "public CA fingerprint")
let verify = try command("/usr/bin/openssl", ["verify", "-CAfile", tlsDir.appendingPathComponent("root.pem").path, tlsDir.appendingPathComponent("server.pem").path])
expect(verify.status == 0, "leaf chain verifies against public CA")
let rootSubject = try command("/usr/bin/openssl", ["x509", "-in", tlsDir.appendingPathComponent("root.pem").path, "-noout", "-subject"])
expect(rootSubject.text.contains("Simwisp Local CA"), "CA distinguished name differs from server leaf")
let bad = root.appendingPathComponent("bad-tls"); try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
try cert.write(to: bad.appendingPathComponent("root.pem"))
do { _ = try TLSIdentity(directory: bad); fatalError("incomplete CA replaced") } catch { checks += 1 }
let link = root.appendingPathComponent("tls-link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tlsDir)
do { _ = try TLSIdentity(directory: link); fatalError("symlink TLS directory accepted") } catch { checks += 1 }
let result: [String: Any] = ["checks": checks, "passed": true, "hardware_encoder": encoder.hardware, "encoded_frames": frames.count, "native_decoded_frames": sink.count, "real_capture": false, "real_input": false, "trust_installed": false]
try jsonData(result).write(to: root.appendingPathComponent("video-review.json"))
print("\(checks) native H.264/TLS checks passed; hardware encoder \(encoder.hardware)")
