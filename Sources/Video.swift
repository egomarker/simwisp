import Foundation
import VideoToolbox
import CoreImage

struct H264Frame {
    let payload: Data
    let description: Data
    let codec: String
    let keyframe: Bool
    let timestamp: UInt64
    let width: Int
    let height: Int
    let codedWidth: Int
    let codedHeight: Int
    func configuration(epoch: UInt32) -> [String: Any] {
        ["type": "video_config", "epoch": epoch, "codec": codec, "description": description.base64EncodedString(), "width": width, "height": height, "coded_width": codedWidth, "coded_height": codedHeight]
    }
    // SWV1, key flag + 3 reserved bytes, epoch, frame id, timestamp (microseconds), AVCC access unit.
    func packet(epoch: UInt32, id: UInt32) -> Data {
        var data = Data([0x53, 0x57, 0x56, 0x31, keyframe ? 1 : 0, 0, 0, 0])
        var e = epoch.bigEndian, i = id.bigEndian, t = timestamp.bigEndian
        withUnsafeBytes(of: &e) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &i) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &t) { data.append(contentsOf: $0) }
        data.append(payload); return data
    }
}

// One pull at a time. CompleteFrames drains each submission before returning,
// so neither VideoToolbox nor the socket builds a multi-frame latency queue.
final class H264Encoder {
    let width: Int, height: Int, codedWidth: Int, codedHeight: Int
    private var session: VTCompressionSession?
    private var pool: CVPixelBufferPool?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let outputLock = NSLock()
    private var output: H264Frame?
    private var outputError: OSStatus = noErr
    private var timestamp: UInt64 = 0
    private let started = monotonic()
    private var previousQuality = -1, previousFPS = -1
    private(set) var hardware = false
    init(width: Int, height: Int) throws {
        guard (1...8192).contains(width), (1...8192).contains(height) else { throw WispError("Invalid H.264 dimensions") }
        self.width = width; self.height = height
        codedWidth = (width + 1) & ~1; codedHeight = (height + 1) & ~1
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey: codedWidth, kCVPixelBufferHeightKey: codedHeight, kCVPixelBufferIOSurfacePropertiesKey: [:]]
        var newPool: CVPixelBufferPool?
        try check(CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 2] as CFDictionary, attributes as CFDictionary, &newPool), "pixel pool")
        pool = newPool
        var newSession: VTCompressionSession?
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(codedWidth), height: Int32(codedHeight), codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary, imageBufferAttributes: attributes as CFDictionary, compressedDataAllocator: nil, outputCallback: { refcon, _, status, _, sample in
            guard let refcon else { return }
            Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue().receive(status, sample)
        }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &newSession)
        try check(status, "creation"); session = newSession
        do {
            try property(kVTCompressionPropertyKey_RealTime, true as CFBoolean)
            try property(kVTCompressionPropertyKey_AllowFrameReordering, false as CFBoolean)
            try property(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel)
            try property(kVTCompressionPropertyKey_MaxKeyFrameInterval, 60 as CFNumber)
            try property(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 1 as CFNumber)
            try property(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
            try property(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_sRGB)
            try property(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
            try check(VTCompressionSessionPrepareToEncodeFrames(newSession!), "preparation")
            var usingHardware: Unmanaged<CFTypeRef>?
            if VTSessionCopyProperty(newSession!, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: &usingHardware) == noErr { hardware = (usingHardware?.takeRetainedValue() as? Bool) == true }
        } catch { close(); throw error }
    }
    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw WispError("H.264 \(operation) failed (\(status))") }
    }
    private func property(_ key: CFString, _ value: CFTypeRef) throws { try check(VTSessionSetProperty(session!, key: key, value: value), String(key)) }
    func encode(_ image: CIImage, quality: Int, fps: Int, forceKeyframe: Bool) throws -> H264Frame {
        guard let session, let pool else { throw WispError("H.264 encoder closed") }
        if quality != previousQuality || fps != previousFPS {
            // Preserve the existing 1–95 control; it now selects a resolution-
            // scaled bitrate, not JPEG compression. A 1080p portrait at q20 is ~6 Mbps.
            let area = Double(codedWidth * codedHeight) / (1080 * 1920)
            let rate = Int(max(500_000, min(40_000_000, (2_000_000 + Double(quality) / 95 * 18_000_000) * area)))
            try property(kVTCompressionPropertyKey_AverageBitRate, rate as CFNumber)
            try property(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
            previousQuality = quality; previousFPS = fps
        }
        var pixel: CVPixelBuffer?
        try check(CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, [kCVPixelBufferPoolAllocationThresholdKey: 3] as CFDictionary, &pixel), "bounded pixel allocation")
        let bounds = CGRect(x: 0, y: 0, width: codedWidth, height: codedHeight)
        let background = CIImage(color: .black).cropped(to: bounds)
        context.render(image.composited(over: background), to: pixel!, bounds: bounds, colorSpace: colorSpace)
        timestamp = max(timestamp + 1, UInt64(max(0, (monotonic() - started) * 1_000_000)))
        let pts = CMTime(value: Int64(timestamp), timescale: 1_000_000)
        outputLock.withLock { output = nil; outputError = noErr }
        let properties: CFDictionary? = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        try check(VTCompressionSessionEncodeFrame(session, imageBuffer: pixel!, presentationTimeStamp: pts, duration: .invalid, frameProperties: properties, sourceFrameRefcon: nil, infoFlagsOut: nil), "encode")
        try check(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid), "drain")
        return try outputLock.withLock {
            try check(outputError, "output")
            guard let frame = output else { throw WispError("H.264 encoder produced no access unit") }
            output = nil; return frame
        }
    }
    private func receive(_ status: OSStatus, _ sample: CMSampleBuffer?) {
        autoreleasepool {
            guard status == noErr, let sample, CMSampleBufferDataIsReady(sample), let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { outputLock.withLock { outputError = status == noErr ? -1 : status }; return }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0, length < 16_000_000,
                  let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
                  let description = atoms["avcC"] as? Data, description.count >= 7 else { outputLock.withLock { outputError = -2 }; return }
            var data = Data(count: length)
            let copied = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard copied == noErr else { outputLock.withLock { outputError = copied }; return }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            let key = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
            let codec = "avc1." + description[1...3].map { String(format: "%02X", $0) }.joined()
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let time = UInt64(max(0, CMTimeConvertScale(pts, timescale: 1_000_000, method: .default).value))
            let frame = H264Frame(payload: data, description: description, codec: codec, keyframe: key, timestamp: time, width: width, height: height, codedWidth: codedWidth, codedHeight: codedHeight)
            outputLock.withLock { output = frame }
        }
    }
    func close() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil; pool = nil; outputLock.withLock { output = nil }; context.clearCaches()
    }
    deinit { close() }
}
