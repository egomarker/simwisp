import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

// Real VideoToolbox avcC that produced seven buffered frames on Safari.
let original = Data(base64Encoded: "AUIAHv/hAA8nQgAeq0DAM/NJNQENAQIBAAQozjyA")!
let reference = [UInt8](original)
let firstSPS = Array(reference[8..<(8 + (Int(reference[6]) << 8 | Int(reference[7])))] )
let before = try H264SPS.restrictions(in: firstSPS)
check(before.referenceFrames == 1 && before.reorderFrames == nil && before.bufferFrames == nil,
      "fixture must lack VUI buffering restrictions")

let rewritten = try H264SPS.lowLatencyAVCC(original)
let bytes = [UInt8](rewritten)
let length = Int(bytes[6]) << 8 | Int(bytes[7])
let sps = Array(bytes[8..<(8 + length)])
let after = try H264SPS.restrictions(in: sps)
check(after.referenceFrames == 1 && after.reorderFrames == 0 && after.bufferFrames == 1,
      "rewritten SPS must explicitly signal low-latency decoding")
check(bytes[0..<6].elementsEqual(reference[0..<6]), "avcC header unchanged")
check(bytes[(8 + length)...].elementsEqual(reference[(8 + firstSPS.count)...]), "PPS unchanged")
let twice = try H264SPS.lowLatencyAVCC(rewritten)
check(twice == rewritten, "rewrite is idempotent")

// The hand-rewritten SPS that was verified to remove Safari's 105ms delay.
let proven = Data(base64Encoded: "AUIAHv/hABMnQgAeq0DAM/NJNQENAQbQRCNQAQAEKM48gA==")!
let provenAgain = try H264SPS.lowLatencyAVCC(proven)
check(provenAgain == proven, "known-good SPS preserved")
check(rewritten == proven, "exact Safari-verified avcC bytes are produced")

for malformed in [Data(), Data([1, 0x42, 0, 30, 0xff, 0xe1, 0xff, 0xff]),
                  Data([1, 0x42, 0, 30, 0, 0, 0])] {
    do {
        _ = try H264SPS.lowLatencyAVCC(malformed)
        fatalError("invalid avcC accepted")
    } catch H264SPS.ParseError.invalidBitstream { }
}
print("H.264 low-latency SPS rewrite tests passed")
