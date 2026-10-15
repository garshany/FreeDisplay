// SPDX-License-Identifier: GPL-3.0-or-later
// Original clean-room implementation for FreeDisplay (CTA-861 and DisplayID extension blocks).
import Foundation

extension EDIDDecoder {
    // MARK: CTA-861

    /// IEEE OUIs of the vendor-specific blocks decoded here, as stored (little-endian) in the block.
    static let hdmiLicensingOUI = 0x000C03
    static let hdmiForumOUI = 0xC45DD8

    static func decodeCTA(_ d: [UInt8], block: Int, issues: inout [EDIDDecoded.Issue]) -> EDIDDecoded.CTA {
        var cta = EDIDDecoded.CTA(
            revision: Int(d[1]), underscan: nil, basicAudio: nil, ycbcr444: nil, ycbcr422: nil,
            nativeDetailedTimingCount: nil, videoFormats: [], ycbcr420OnlyFormats: [], audioFormats: [],
            speakerAllocation: nil, hdmi: nil, hdmiForum: nil, otherVendorOUIs: [], colorimetry: [],
            hdrStaticMetadata: nil, quantization: nil, otherDataBlocks: [], detailedTimings: [])
        if cta.revision >= 2 {
            cta.underscan = d[3] & 0x80 != 0
            cta.basicAudio = d[3] & 0x40 != 0
            cta.ycbcr444 = d[3] & 0x20 != 0
            cta.ycbcr422 = d[3] & 0x10 != 0
            cta.nativeDetailedTimingCount = Int(d[3] & 0x0F)
        }
        // Byte 2 is where the detailed timings start: 0 = no timings and no data blocks, 4 = no
        // data blocks. Anything inside the header or past the checksum is a broken layout.
        let dtdStart = Int(d[2])
        guard dtdStart == 0 || (4...127).contains(dtdStart) else {
            issues.append(.ctaLayoutInvalid(block: block))
            return cta
        }
        guard dtdStart > 0 else { return cta }

        // Data blocks exist from revision 3 (CTA-861-B); before that bytes 4… up to the
        // timings are reserved.
        var offset = cta.revision >= 3 ? 4 : dtdStart
        while offset < dtdStart {
            let tag = Int(d[offset] >> 5)
            let length = Int(d[offset] & 0x1F)
            guard offset + 1 + length <= dtdStart else {
                issues.append(.ctaDataBlockOverrun(block: block))
                break
            }
            let payload = Array(d[(offset + 1)..<(offset + 1 + length)])
            if !decodeCTADataBlock(tag: tag, payload: payload, into: &cta) {
                let extended = tag == 7 ? payload.first.map(Int.init) : nil
                issues.append(.ctaDataBlockMalformed(block: block, tag: tag, extendedTag: extended))
            }
            offset += 1 + length
        }

        var dtd = dtdStart
        while dtd + 18 <= 127 {
            let descriptor = Array(d[dtd..<(dtd + 18)])
            guard descriptor[0] != 0 || descriptor[1] != 0, let timing = detailedTiming(descriptor) else { break }
            cta.detailedTimings.append(timing)
            dtd += 18
        }
        return cta
    }

    /// Decodes one data block into `cta`; false when the block is malformed for its type (what
    /// could be read is still kept).
    static func decodeCTADataBlock(tag: Int, payload p: [UInt8], into cta: inout EDIDDecoded.CTA) -> Bool {
        switch tag {
        case 1:
            for index in stride(from: 0, to: p.count - 2, by: 3) {
                let rates = [32_000, 44_100, 48_000, 88_200, 96_000, 176_400, 192_000]
                    .enumerated().filter { p[index + 1] & (1 << $0.offset) != 0 }.map(\.element)
                cta.audioFormats.append(EDIDDecoded.ShortAudio(
                    formatCode: Int((p[index] >> 3) & 0x0F), channels: Int(p[index] & 0x07) + 1,
                    sampleRates: rates))
            }
            // Short Audio Descriptors are 3 bytes each.
            return !p.isEmpty && p.count % 3 == 0
        case 2:
            cta.videoFormats.append(contentsOf: p.compactMap(shortVideo))
        case 3:
            guard p.count >= 3 else {
                cta.otherDataBlocks.append(.init(tag: tag, extendedTag: nil))
                return false
            }
            let oui = Int(p[0]) | (Int(p[1]) << 8) | (Int(p[2]) << 16)
            if (oui == hdmiLicensingOUI || oui == hdmiForumOUI) && p.count < 5 {
                cta.otherVendorOUIs.append(oui)
                return false
            }
            if oui == hdmiLicensingOUI {
                cta.hdmi = EDIDDecoded.HDMIVendorBlock(
                    physicalAddress: "\(p[3] >> 4).\(p[3] & 0x0F).\(p[4] >> 4).\(p[4] & 0x0F)",
                    deepColor30: p.count > 5 && p[5] & 0x10 != 0,
                    deepColor36: p.count > 5 && p[5] & 0x20 != 0,
                    deepColor48: p.count > 5 && p[5] & 0x40 != 0,
                    deepColorYCbCr444: p.count > 5 && p[5] & 0x08 != 0,
                    maxTMDSClockMHz: p.count > 6 && p[6] > 0 ? Int(p[6]) * 5 : nil)
            } else if oui == hdmiForumOUI {
                cta.hdmiForum = EDIDDecoded.HDMIForumBlock(
                    version: Int(p[3]),
                    maxTMDSCharacterRateMHz: p[4] > 0 ? Int(p[4]) * 5 : nil,
                    maxFRLRateCode: p.count > 6 ? Int(p[6] >> 4) : nil)
            } else {
                cta.otherVendorOUIs.append(oui)
            }
        case 4:
            cta.speakerAllocation = p
        case 7:
            guard let extended = p.first else {
                cta.otherDataBlocks.append(.init(tag: tag, extendedTag: nil))
                return false
            }
            let body = Array(p.dropFirst())
            switch extended {
            case 0:
                guard !body.isEmpty else { return false }
                cta.quantization = .init(rgbSelectable: body[0] & 0x40 != 0, yccSelectable: body[0] & 0x80 != 0)
            case 5:
                guard !body.isEmpty else { return false }
                let bits = EDIDDecoded.Colorimetry.allCases.filter { $0 != .dciP3 }
                cta.colorimetry = bits.enumerated().filter { body[0] & (1 << $0.offset) != 0 }.map(\.element)
                if body.count > 1, body[1] & 0x80 != 0 { cta.colorimetry.append(.dciP3) }
            case 6:
                guard body.count >= 2 else { return false }
                func luminance(_ code: UInt8) -> Double { 50 * pow(2, Double(code) / 32) }
                let maxLuminance = body.count > 2 && body[2] > 0 ? luminance(body[2]) : nil
                let minLuminance: Double? = body.count > 4
                    ? maxLuminance.map { $0 * pow(Double(body[4]) / 255, 2) / 100 } : nil
                cta.hdrStaticMetadata = EDIDDecoded.HDRStaticMetadata(
                    traditionalSDR: body[0] & 0x01 != 0, traditionalHDR: body[0] & 0x02 != 0,
                    pq: body[0] & 0x04 != 0, hlg: body[0] & 0x08 != 0,
                    maxLuminance: maxLuminance,
                    maxFrameAverageLuminance: body.count > 3 && body[3] > 0 ? luminance(body[3]) : nil,
                    minLuminance: minLuminance)
            case 14:
                cta.ycbcr420OnlyFormats.append(contentsOf: body.compactMap(shortVideo))
            default:
                cta.otherDataBlocks.append(.init(tag: tag, extendedTag: Int(extended)))
            }
        default:
            cta.otherDataBlocks.append(.init(tag: tag, extendedTag: nil))
        }
        return true
    }

    /// A Short Video Descriptor: codes 129–192 are the native-flagged VICs 1–64; 0, 128, 254 and
    /// 255 are reserved.
    static func shortVideo(_ code: UInt8) -> EDIDDecoded.ShortVideo? {
        switch code {
        case 129...192: return EDIDDecoded.ShortVideo(vic: Int(code & 0x7F), native: true)
        case 1...127, 193...253: return EDIDDecoded.ShortVideo(vic: Int(code), native: false)
        default: return nil
        }
    }

    /// Names of the CTA data block tags (and extended tags) that are listed but not decoded.
    public static func ctaDataBlockName(_ tag: EDIDDecoded.DataBlockTag, _ l: ReportLocalizer = .english) -> String {
        if let extended = tag.extendedTag {
            switch extended {
            case 0: return l("Video Capability")
            case 1: return l("Vendor-Specific Video")
            case 2: return l("VESA Display Device")
            case 5: return l("Colorimetry")
            case 6: return l("HDR Static Metadata")
            case 7: return l("HDR Dynamic Metadata")
            case 13: return l("Video Format Preference")
            case 14: return l("YCbCr 4:2:0 Video")
            case 15: return l("YCbCr 4:2:0 Capability Map")
            case 17: return l("Vendor-Specific Audio")
            case 18: return l("HDMI Audio")
            case 19: return l("Room Configuration")
            case 20: return l("Speaker Location")
            case 32: return "InfoFrame"
            case 34: return l("DisplayID Type VII Timing")
            case 35: return l("DisplayID Type VIII Timing")
            case 42: return l("DisplayID Type X Timing")
            case 120: return l("HDMI Forum EDID Extension Override")
            case 121: return l("HDMI Forum Sink Capability")
            default: return l.fill("Extended tag %1", "\(extended)")
            }
        }
        switch tag.tag {
        case 1: return l("Audio")
        case 2: return l("Video")
        case 3: return l("Vendor-Specific")
        case 4: return l("Speaker Allocation")
        case 5: return l("VESA Display Transfer Characteristic")
        case 6: return l("Video Format")
        default: return l.fill("Tag %1", "\(tag.tag)")
        }
    }

    /// Short names of the CTA audio format codes.
    public static func audioFormatName(_ code: Int, _ l: ReportLocalizer = .english) -> String {
        switch code {
        case 1: return "LPCM"
        case 2: return "AC-3"
        case 3: return "MPEG-1"
        case 4: return "MP3"
        case 5: return "MPEG-2"
        case 6: return "AAC LC"
        case 7: return "DTS"
        case 8: return "ATRAC"
        case 9: return "DSD"
        case 10: return "E-AC-3"
        case 11: return "DTS-HD"
        case 12: return "MAT (Dolby TrueHD)"
        case 13: return "DST"
        case 14: return "WMA Pro"
        default: return l.fill("Format %1", "\(code)")
        }
    }

    // MARK: DisplayID

    /// A DisplayID section carried in an EDID extension block: byte 1 version, 2 payload length,
    /// 3 product type / use case, 4 extension count, data blocks from byte 5, then the section's
    /// own checksum byte (the block's checksum is byte 127 as for every extension).
    static func decodeDisplayIDBlock(_ d: [UInt8], block: Int,
                                     issues: inout [EDIDDecoded.Issue]) -> EDIDDecoded.Extension.Content {
        let payloadLength = Int(d[2])
        let sectionEnd = 5 + payloadLength           // index of the section checksum byte
        guard sectionEnd < 127 else {
            issues.append(.displayIDSectionOverrun(block: block))
            return .undecoded
        }
        let sectionValid = checksumOK(Array(d[1...sectionEnd]))
        if !sectionValid { issues.append(.displayIDChecksumInvalid(block: block)) }
        let version = Int(d[1])
        var section = EDIDDecoded.DisplayID(
            version: version >> 4, revision: version & 0x0F, productType: Int(d[3]),
            sectionChecksumValid: sectionValid, product: nil, parameters: nil, timings: [], tiles: [],
            otherBlockTags: [])
        let isV2 = version >= 0x20

        func malformed(_ tag: Int) {
            section.otherBlockTags.append(tag)
            issues.append(.displayIDDataBlockMalformed(block: block, tag: tag))
        }
        var offset = 5
        while offset + 3 <= sectionEnd {
            let tag = Int(d[offset]), blockRevision = d[offset + 1], length = Int(d[offset + 2])
            // Zero padding fills the rest of the section; a real block always has a payload.
            if tag == 0 && length == 0 && blockRevision == 0 { break }
            guard offset + 3 + length <= sectionEnd else {
                issues.append(.displayIDDataBlockOverrun(block: block, tag: tag))
                break
            }
            let payload = Array(d[(offset + 3)..<(offset + 3 + length)])
            switch tag {
            case 0x00, 0x20:
                if let product = displayIDProduct(payload, oui: tag == 0x20) {
                    section.product = product
                    // The name runs past the block: the product is kept, the name isn't guessed.
                    if payload.count < 12 + Int(payload[11]) {
                        issues.append(.displayIDDataBlockMalformed(block: block, tag: tag))
                    }
                } else {
                    malformed(tag)
                }
            case 0x01, 0x21:
                // DisplayID 2.x states the unit in the block revision byte: bit 7 = 1 mm, else 0.1 mm.
                let unit = tag == 0x21 && blockRevision & 0x80 != 0 ? 1.0 : 0.1
                if var parameters = displayIDParameters(payload, unitMM: unit) {
                    if tag == 0x21 { displayIDLuminance(payload, into: &parameters) }
                    section.parameters = parameters
                    // Keep readable prefixes, but a partial parameter block isn't a valid one.
                    let requiredLength = tag == 0x21 ? 29 : 12
                    if payload.count != requiredLength {
                        issues.append(.displayIDDataBlockMalformed(block: block, tag: tag))
                    }
                } else {
                    malformed(tag)
                }
            case 0x03, 0x22:
                // Type I timings count the pixel clock in 10 kHz, Type VII in 1 kHz. A Type VII
                // block's revision bits 6–4 add bytes to each 20-byte descriptor (DisplayID 2.1);
                // they are 0 in 2.0, so the descriptor stays 20 bytes there.
                let unit = tag == 0x03 ? 10 : 1
                let size = tag == 0x22 ? 20 + Int((blockRevision >> 4) & 0x07) : 20
                for start in stride(from: 0, through: payload.count - size, by: size) {
                    section.timings.append(displayIDTiming(Array(payload[start..<(start + 20)]), clockUnitKHz: unit))
                }
                if payload.isEmpty || payload.count % size != 0 { malformed(tag) }
            case 0x12, 0x28:
                if let tile = displayIDTile(payload, oui: tag == 0x28 || isV2) {
                    section.tiles.append(tile)
                    // 22 bytes carry the topology ID; a shorter block keeps the layout only.
                    if payload.count != 22 || tile.column >= tile.horizontalTiles || tile.row >= tile.verticalTiles {
                        issues.append(.displayIDDataBlockMalformed(block: block, tag: tag))
                    }
                } else {
                    malformed(tag)
                }
            default:
                section.otherBlockTags.append(tag)
            }
            offset += 3 + length
        }
        return .displayID(section)
    }

    static func displayIDProduct(_ p: [UInt8], oui: Bool) -> EDIDDecoded.DisplayID.Product? {
        guard p.count >= 12 else { return nil }
        let vendor = oui
            ? String(format: "%02X-%02X-%02X", p[0], p[1], p[2])
            : String(p[0..<3].map { $0 >= 0x20 && $0 < 0x7F ? Character(UnicodeScalar($0)) : "?" })
        let nameLength = Int(p[11])
        let name: String? = nameLength > 0 && p.count >= 12 + nameLength
            ? String(decoding: p[12..<(12 + nameLength)], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            : nil
        return EDIDDecoded.DisplayID.Product(
            vendor: vendor, productCode: Int(p[3]) | (Int(p[4]) << 8),
            serialNumber: UInt32(p[5]) | (UInt32(p[6]) << 8) | (UInt32(p[7]) << 16) | (UInt32(p[8]) << 24),
            manufacture: manufactureDate(week: Int(p[9]), yearByte: Int(p[10]), yearBase: 2000),
            name: name)
    }

    static func displayIDParameters(_ p: [UInt8], unitMM: Double) -> EDIDDecoded.DisplayID.Parameters? {
        guard p.count >= 8 else { return nil }
        let width = Int(p[0]) | (Int(p[1]) << 8), height = Int(p[2]) | (Int(p[3]) << 8)
        let pixelsH = Int(p[4]) | (Int(p[5]) << 8), pixelsV = Int(p[6]) | (Int(p[7]) << 8)
        return EDIDDecoded.DisplayID.Parameters(
            imageWidthMM: width > 0 ? Double(width) * unitMM : nil,
            imageHeightMM: height > 0 ? Double(height) * unitMM : nil,
            nativeWidth: pixelsH > 0 ? pixelsH : nil, nativeHeight: pixelsV > 0 ? pixelsV : nil)
    }

    /// DisplayID 2.x Display Parameters carry the native luminance as IEEE 754 half-precision
    /// cd/m² values after the size, pixel count, feature flags and chromaticity: full-coverage
    /// maximum at payload bytes 21–22, 10%-window maximum at 23–24, minimum at 25–26.
    static func displayIDLuminance(_ p: [UInt8], into parameters: inout EDIDDecoded.DisplayID.Parameters) {
        guard p.count >= 27 else { return }
        func value(_ index: Int) -> Double? {
            let bits = UInt16(p[index]) | (UInt16(p[index + 1]) << 8)
            // DisplayID uses negative zero as "do not use", including for minimum black.
            guard bits != 0x8000 else { return nil }
            let decoded = halfFloat(bits)
            return decoded.isFinite && decoded >= 0 ? decoded : nil
        }
        parameters.maxLuminanceFullCoverage = value(21).flatMap { $0 > 0 ? $0 : nil }
        parameters.maxLuminanceTenPercent = value(23).flatMap { $0 > 0 ? $0 : nil }
        parameters.minLuminance = value(25)
    }

    /// An IEEE 754 binary16 value, decoded by hand so the package doesn't depend on `Float16`
    /// (absent on some platforms the core builds for).
    static func halfFloat(_ bits: UInt16) -> Double {
        let sign: Double = bits & 0x8000 != 0 ? -1 : 1
        let exponent = Int((bits >> 10) & 0x1F)
        let fraction = Double(bits & 0x03FF)
        switch exponent {
        case 0: return sign * fraction * pow(2, -24)                  // zero and subnormals
        case 0x1F: return fraction == 0 ? sign * .infinity : .nan
        default: return sign * (1 + fraction / 1024) * pow(2, Double(exponent - 15))
        }
    }

    /// Type I / Type VII detailed timing descriptor: every field is stored minus one.
    static func displayIDTiming(_ t: [UInt8], clockUnitKHz: Int) -> EDIDDecoded.DetailedTiming {
        func word(_ index: Int, mask: Int = 0xFFFF) -> Int { ((Int(t[index]) | (Int(t[index + 1]) << 8)) & mask) + 1 }
        return EDIDDecoded.DetailedTiming(
            pixelClockKHz: ((Int(t[0]) | (Int(t[1]) << 8) | (Int(t[2]) << 16)) + 1) * clockUnitKHz,
            horizontalActive: word(4), horizontalBlanking: word(6),
            horizontalFrontPorch: word(8, mask: 0x7FFF), horizontalSyncWidth: word(10),
            verticalActive: word(12), verticalBlanking: word(14),
            verticalFrontPorch: word(16, mask: 0x7FFF), verticalSyncWidth: word(18),
            imageWidthMM: nil, imageHeightMM: nil,
            interlaced: t[3] & 0x10 != 0, preferred: t[3] & 0x80 != 0)
    }

    /// Tiled Display Topology: capabilities, packed tile counts/location (low bits in bytes 1–2,
    /// high bits in byte 3), tile size minus one, then bezel data and the topology ID.
    static func displayIDTile(_ p: [UInt8], oui: Bool) -> EDIDDecoded.DisplayID.Tile? {
        guard p.count >= 8 else { return nil }
        let horizontalTiles = (Int(p[1] >> 4) | ((Int(p[3] >> 6) & 0x03) << 4)) + 1
        let verticalTiles = (Int(p[1] & 0x0F) | ((Int(p[3] >> 4) & 0x03) << 4)) + 1
        let column = Int(p[2] >> 4) | ((Int(p[3] >> 2) & 0x03) << 4)
        let row = Int(p[2] & 0x0F) | ((Int(p[3]) & 0x03) << 4)
        var tile = EDIDDecoded.DisplayID.Tile(
            horizontalTiles: horizontalTiles, verticalTiles: verticalTiles, column: column, row: row,
            tileWidth: (Int(p[4]) | (Int(p[5]) << 8)) + 1, tileHeight: (Int(p[6]) | (Int(p[7]) << 8)) + 1,
            singleEnclosure: p[0] & 0x80 != 0, vendor: nil, productCode: nil, serialNumber: nil)
        if p.count >= 22 {
            tile.vendor = oui
                ? String(format: "%02X-%02X-%02X", p[13], p[14], p[15])
                : String(p[13..<16].map { $0 >= 0x20 && $0 < 0x7F ? Character(UnicodeScalar($0)) : "?" })
            tile.productCode = Int(p[16]) | (Int(p[17]) << 8)
            tile.serialNumber = UInt32(p[18]) | (UInt32(p[19]) << 8) | (UInt32(p[20]) << 16) | (UInt32(p[21]) << 24)
        }
        return tile
    }

    /// Names of DisplayID data block tags (1.x and 2.x) listed but not decoded.
    public static func displayIDBlockName(_ tag: Int, _ l: ReportLocalizer = .english) -> String {
        switch tag {
        case 0x00: return l("Product Identification")
        case 0x01: return l("Display Parameters")
        case 0x02: return l("Color Characteristics")
        case 0x03: return l("Type I Timing")
        case 0x04: return l("Type II Timing")
        case 0x05: return l("Type III Timing")
        case 0x06: return l("Type IV Timing")
        case 0x07: return l("VESA Timing Standard")
        case 0x08: return l("CTA Timing Standard")
        case 0x09: return l("Video Timing Range")
        case 0x0A: return l("Product Serial Number")
        case 0x0B: return l("ASCII String")
        case 0x0C: return l("Display Device Data")
        case 0x0D: return l("Interface Power Sequencing")
        case 0x0E: return l("Transfer Characteristics")
        case 0x0F: return l("Display Interface")
        case 0x10: return l("Stereo Display Interface")
        case 0x11: return l("Type V Timing")
        case 0x12: return l("Tiled Display Topology")
        case 0x13: return l("Type VI Timing")
        case 0x20: return l("Product Identification")
        case 0x21: return l("Display Parameters")
        case 0x22: return l("Type VII Timing")
        case 0x23: return l("Type VIII Timing")
        case 0x24: return l("Type IX Timing")
        case 0x25: return l("Dynamic Video Timing Range Limits")
        case 0x26: return l("Display Interface Features")
        case 0x27: return l("Stereo Display Interface")
        case 0x28: return l("Tiled Display Topology")
        case 0x29: return "ContainerID"
        case 0x7E, 0x7F: return l("Vendor-Specific")
        case 0x81: return l("CTA DisplayID")
        default: return l.fill("Tag %1", String(format: "0x%02X", tag))
        }
    }
}
