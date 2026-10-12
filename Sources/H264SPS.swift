import Foundation

// VideoToolbox can omit the SPS VUI bitstream restrictions even when frame
// reordering is disabled. Some WebCodecs decoders then buffer several pictures.
// Keep the encoder's SPS intact except for the VUI buffering constraints.
enum H264SPS {
    enum ParseError: Error { case invalidBitstream }

    struct Restrictions {
        let referenceFrames: Int
        let reorderFrames: Int?
        let bufferFrames: Int?
    }

    private struct Bits {
        let bytes: [UInt8]
        var position = 0

        mutating func bit() throws -> Int {
            guard position < bytes.count * 8 else { throw ParseError.invalidBitstream }
            let value = Int((bytes[position / 8] >> (7 - position % 8)) & 1)
            position += 1
            return value
        }
        mutating func read(_ count: Int) throws -> Int {
            guard (0...32).contains(count) else { throw ParseError.invalidBitstream }
            var value = 0
            for _ in 0..<count { value = (value << 1) | (try bit()) }
            return value
        }
        mutating func ue() throws -> Int {
            var zeros = 0
            while try bit() == 0 {
                zeros += 1
                guard zeros <= 30 else { throw ParseError.invalidBitstream }
            }
            return ((1 << zeros) - 1) + (try read(zeros))
        }
        mutating func se() throws -> Int {
            let value = try ue()
            return value % 2 == 0 ? -(value / 2) : (value + 1) / 2
        }
        mutating func trailingBits() throws {
            guard try bit() == 1 else { throw ParseError.invalidBitstream }
            while position % 8 != 0 {
                guard try bit() == 0 else { throw ParseError.invalidBitstream }
            }
            guard position == bytes.count * 8 else { throw ParseError.invalidBitstream }
        }
        func at(_ index: Int) -> UInt8 {
            (bytes[index / 8] >> (7 - index % 8)) & 1
        }
    }

    private struct Writer {
        var bits: [UInt8] = []
        mutating func bit(_ b: Int) { bits.append(UInt8(b)) }
        mutating func ue(_ value: Int) {
            let binary = String(value + 1, radix: 2)
            bits.append(contentsOf: repeatElement(UInt8(0), count: binary.count - 1))
            bits.append(contentsOf: binary.utf8.map { $0 == 49 ? 1 : 0 })
        }
        mutating func prefix(_ source: Bits, to position: Int) {
            for index in 0..<position { bits.append(source.at(index)) }
        }
        func nal(header: UInt8) -> [UInt8] {
            var output = [header]
            var rbsp = bits + [1] // rbsp_stop_one_bit, followed by zero padding
            while rbsp.count % 8 != 0 { rbsp.append(0) }
            var zeros = 0
            for offset in stride(from: 0, to: rbsp.count, by: 8) {
                var byte: UInt8 = 0
                for i in 0..<8 { byte = (byte << 1) | rbsp[offset + i] }
                if zeros >= 2 && byte <= 3 {
                    output.append(3)
                    zeros = 0
                }
                output.append(byte)
                zeros = byte == 0 ? zeros + 1 : 0
            }
            return output
        }
    }

    private static func bits(for nal: [UInt8]) throws -> Bits {
        guard nal.count >= 5, nal[0] & 0x1f == 7, nal[0] & 0x80 == 0 else { throw ParseError.invalidBitstream }
        var rbsp: [UInt8] = []
        var zeros = 0, index = 1
        while index < nal.count {
            let byte = nal[index]
            if zeros >= 2 && byte == 3 {
                guard index + 1 < nal.count && nal[index + 1] <= 3 else { throw ParseError.invalidBitstream }
                zeros = 0
                index += 1
                continue
            }
            rbsp.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
            index += 1
        }
        return Bits(bytes: rbsp)
    }

    private static func skipScalingList(_ count: Int, _ reader: inout Bits) throws {
        var last = 8, next = 8
        for _ in 0..<count {
            if next != 0 {
                let delta = try reader.se()
                next = (last + delta + 256) % 256
            }
            if next != 0 { last = next }
        }
    }

    private static func skipHRD(_ reader: inout Bits) throws {
        let cpbCount = try reader.ue() + 1
        guard cpbCount <= 32 else { throw ParseError.invalidBitstream }
        _ = try reader.read(8) // bit_rate_scale + cpb_size_scale
        for _ in 0..<cpbCount {
            _ = try reader.ue() // bit_rate_value_minus1
            _ = try reader.ue() // cpb_size_value_minus1
            _ = try reader.bit() // cbr_flag
        }
        _ = try reader.read(20) // delay lengths and time_offset_length
    }

    private struct Parsed {
        let bits: Bits
        let insertionPoint: Int
        let insertVUI: Bool
        let insertRestrictionFlag: Bool
        let referenceFrames: Int
        let oldReorderFrames: Int?
        let oldBufferFrames: Int?
    }

    private static func parse(_ nal: [UInt8]) throws -> Parsed {
        let original = try bits(for: nal)
        var r = original
        let profile = try r.read(8)
        _ = try r.read(16) // constraint flags and level_idc
        _ = try r.ue() // seq_parameter_set_id
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            let chromaFormat = try r.ue()
            guard chromaFormat <= 3 else { throw ParseError.invalidBitstream }
            if chromaFormat == 3 { _ = try r.bit() }
            _ = try r.ue() // bit_depth_luma_minus8
            _ = try r.ue() // bit_depth_chroma_minus8
            _ = try r.bit() // qpprime_y_zero_transform_bypass_flag
            if try r.bit() == 1 {
                for i in 0..<(chromaFormat == 3 ? 12 : 8) {
                    if try r.bit() == 1 { try skipScalingList(i < 6 ? 16 : 64, &r) }
                }
            }
        } else {
            guard [66, 77, 88].contains(profile) else { throw ParseError.invalidBitstream }
        }
        _ = try r.ue() // log2_max_frame_num_minus4
        let pocType = try r.ue()
        switch pocType {
        case 0: _ = try r.ue() // log2_max_pic_order_cnt_lsb_minus4
        case 1:
            _ = try r.bit() // delta_pic_order_always_zero_flag
            _ = try r.se(); _ = try r.se()
            let cycles = try r.ue()
            guard cycles <= 255 else { throw ParseError.invalidBitstream }
            for _ in 0..<cycles { _ = try r.se() }
        case 2: break
        default: throw ParseError.invalidBitstream
        }
        let references = try r.ue()
        guard references <= 16 else { throw ParseError.invalidBitstream }
        _ = try r.bit() // gaps_in_frame_num_value_allowed_flag
        _ = try r.ue() // pic_width_in_mbs_minus1
        _ = try r.ue() // pic_height_in_map_units_minus1
        let frameOnly = try r.bit()
        if frameOnly == 0 { _ = try r.bit() }
        _ = try r.bit() // direct_8x8_inference_flag
        if try r.bit() == 1 { for _ in 0..<4 { _ = try r.ue() } }

        let vuiPosition = r.position
        if try r.bit() == 0 {
            try r.trailingBits()
            return Parsed(bits: original, insertionPoint: vuiPosition, insertVUI: true,
                          insertRestrictionFlag: false, referenceFrames: references,
                          oldReorderFrames: nil, oldBufferFrames: nil)
        }
        if try r.bit() == 1 {
            let aspect = try r.read(8)
            if aspect == 255 { _ = try r.read(32) }
        }
        if try r.bit() == 1 { _ = try r.bit() } // overscan
        if try r.bit() == 1 {
            _ = try r.read(3) // video_format
            _ = try r.bit() // video_full_range_flag
            if try r.bit() == 1 { _ = try r.read(24) } // colour_description
        }
        if try r.bit() == 1 { _ = try r.ue(); _ = try r.ue() } // chroma_loc_info
        if try r.bit() == 1 { _ = try r.read(32); _ = try r.read(32); _ = try r.bit() } // timing_info
        let nalHRD = try r.bit() == 1
        if nalHRD { try skipHRD(&r) }
        let vclHRD = try r.bit() == 1
        if vclHRD { try skipHRD(&r) }
        if nalHRD || vclHRD { _ = try r.bit() }
        _ = try r.bit() // pic_struct_present_flag
        let restrictionFlagPosition = r.position
        if try r.bit() == 0 {
            try r.trailingBits()
            return Parsed(bits: original, insertionPoint: restrictionFlagPosition, insertVUI: false,
                          insertRestrictionFlag: true, referenceFrames: references,
                          oldReorderFrames: nil, oldBufferFrames: nil)
        }
        _ = try r.bit() // motion_vectors_over_pic_boundaries_flag
        for _ in 0..<4 { _ = try r.ue() }
        let reorderPosition = r.position
        let reorder = try r.ue()
        let buffering = try r.ue()
        try r.trailingBits()
        return Parsed(bits: original, insertionPoint: reorderPosition, insertVUI: false,
                      insertRestrictionFlag: false, referenceFrames: references,
                      oldReorderFrames: reorder, oldBufferFrames: buffering)
    }

    static func restrictions(in sps: [UInt8]) throws -> Restrictions {
        let parsed = try parse(sps)
        return Restrictions(referenceFrames: parsed.referenceFrames,
                            reorderFrames: parsed.oldReorderFrames,
                            bufferFrames: parsed.oldBufferFrames)
    }

    private static func rewriteSPS(_ nal: [UInt8]) throws -> [UInt8] {
        let parsed = try parse(nal)
        let buffers = max(1, parsed.referenceFrames)
        if parsed.oldReorderFrames == 0 && parsed.oldBufferFrames == buffers { return nal }
        var writer = Writer()
        writer.prefix(parsed.bits, to: parsed.insertionPoint)
        if parsed.insertVUI {
            writer.bit(1) // vui_parameters_present_flag
            for _ in 0..<8 { writer.bit(0) } // no optional VUI fields (including pic_struct)
        }
        if parsed.insertVUI || parsed.insertRestrictionFlag {
            writer.bit(1) // bitstream_restriction_flag
            writer.bit(1) // motion_vectors_over_pic_boundaries_flag
            writer.ue(2) // max_bytes_per_pic_denom
            writer.ue(1) // max_bits_per_mb_denom
            writer.ue(16) // log2_max_mv_length_horizontal
            writer.ue(16) // log2_max_mv_length_vertical
        }
        writer.ue(0) // max_num_reorder_frames
        writer.ue(buffers) // max_dec_frame_buffering
        let rewritten = writer.nal(header: nal[0])
        let verify = try parse(rewritten)
        guard verify.referenceFrames == parsed.referenceFrames,
              verify.oldReorderFrames == 0, verify.oldBufferFrames == buffers else { throw ParseError.invalidBitstream }
        return rewritten
    }

    // Preserve the AVCDecoderConfigurationRecord's header, PPS and extensions.
    // Only length-prefixed SPS NAL units are replaced; no access unit changes.
    static func lowLatencyAVCC(_ avcc: Data) throws -> Data {
        let bytes = [UInt8](avcc)
        guard bytes.count >= 7, bytes[0] == 1,
              bytes[4] & 0xfc == 0xfc, bytes[5] & 0xe0 == 0xe0,
              bytes[5] & 0x1f > 0 else { throw ParseError.invalidBitstream }
        var output = Array(bytes[0..<6]), position = 6
        for _ in 0..<Int(bytes[5] & 0x1f) {
            guard position + 2 <= bytes.count else { throw ParseError.invalidBitstream }
            let size = Int(bytes[position]) << 8 | Int(bytes[position + 1])
            position += 2
            guard size > 0, position + size <= bytes.count else { throw ParseError.invalidBitstream }
            let sps = try rewriteSPS(Array(bytes[position..<(position + size)]))
            guard sps.count <= 65535 else { throw ParseError.invalidBitstream }
            output.append(UInt8((sps.count >> 8) & 255)); output.append(UInt8(sps.count & 255))
            output.append(contentsOf: sps)
            position += size
        }
        guard position < bytes.count else { throw ParseError.invalidBitstream }
        output.append(contentsOf: bytes[position...]) // PPS NALs and optional avcC extensions
        return Data(output)
    }
}
