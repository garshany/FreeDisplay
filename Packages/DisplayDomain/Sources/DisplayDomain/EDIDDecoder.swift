// SPDX-License-Identifier: GPL-3.0-or-later
// Original clean-room implementation for FreeDisplay, written from the public VESA EDID 1.4,
// CTA-861 and DisplayID structure descriptions; no third-party decoder source was used.
import Foundation

/// A complete, read-only decoding of an EDID blob: the base block, every extension block that is
/// actually present, and every structural problem found on the way.
///
/// It never rejects input it can partly read: acquired bytes stay inspectable even when they are
/// invalid, and each problem is reported as an `Issue` instead of being silently skipped — a valid
/// base block can travel with missing or corrupt extensions, and "the bytes were read" is not
/// "the bytes are valid". `EDID.parse` stays the small identity parser the rest of the app uses;
/// `EDIDDocument` (TopologyCore) stays the strict gate for exporting an override.
public struct EDIDDecoded: Hashable, Sendable {
    public var byteCount: Int
    /// Nil when the bytes are too short or don't start with the EDID header.
    public var base: Base?
    /// Every complete 128-byte block after the base, in file order.
    public var extensions: [Extension]
    public var issues: [Issue]

    /// No structural problem at all: header, every checksum, block count and every decoded
    /// structure agree. Says nothing about whether the panel behaves as described.
    public var isStructurallyValid: Bool { base != nil && issues.isEmpty }

    public enum Issue: Hashable, Sendable {
        case tooShort(byteCount: Int)
        case invalidHeader
        case invalidManufacturer
        case baseChecksumInvalid
        /// `block` is the block's position in the file, base = 0.
        case extensionChecksumInvalid(block: Int)
        /// The base block promises more extension blocks than the bytes contain.
        case missingExtensions(declared: Int, present: Int)
        /// More complete blocks follow than the base block declares (an HDMI Forum EEODB can
        /// legitimately do this; it is reported, not discarded).
        case undeclaredBlocks(declared: Int, present: Int)
        /// Bytes after the last complete block that don't make a whole 128-byte block.
        case partialTrailingBlock(bytes: Int)
        case ctaLayoutInvalid(block: Int)
        case ctaDataBlockOverrun(block: Int)
        case displayIDSectionOverrun(block: Int)
        case displayIDChecksumInvalid(block: Int)
        case displayIDDataBlockOverrun(block: Int, tag: Int)
        /// A CTA data block too short for its type, or with a length its type can't have; what
        /// couldn't be read is left out rather than guessed.
        case ctaDataBlockMalformed(block: Int, tag: Int, extendedTag: Int?)
        case displayIDDataBlockMalformed(block: Int, tag: Int)
    }

    // MARK: Base block

    public struct Base: Hashable, Sendable {
        public var manufacturerID: String
        /// The raw big-endian manufacturer word (bytes 8–9), as Core Graphics reports the vendor.
        public var manufacturerCode: Int
        public var productCode: Int
        public var serialNumber: UInt32
        public var manufacture: Manufacture
        public var version: Int
        public var revision: Int
        public var videoInput: VideoInput
        public var screenSize: ScreenSize
        /// Nil when byte 23 says the gamma is given elsewhere (0xFF).
        public var gamma: Double?
        public var features: Features
        public var chromaticity: Chromaticity
        public var establishedTimings: [ListedTiming]
        public var standardTimings: [ListedTiming]
        /// Detailed timings from the four 18-byte descriptors, in order. The first one is the
        /// preferred timing.
        public var detailedTimings: [DetailedTiming]
        public var monitorName: String?
        public var serialText: String?
        public var otherText: [String]
        public var rangeLimits: RangeLimits?
        /// Tags of display descriptors not decoded further (0xFB colour point, 0xF7 …, 0x10 dummy).
        public var otherDescriptorTags: [Int]
        public var declaredExtensionCount: Int
        public var checksumValid: Bool
    }

    public enum Manufacture: Hashable, Sendable {
        case week(Int, year: Int)
        /// A year without a week (week byte 0).
        case year(Int)
        /// The week byte is 0xFF: the year is a model year, not a manufacture date.
        case modelYear(Int)
        case unspecified
    }

    public enum VideoInput: Hashable, Sendable {
        /// `bitsPerColor`/`interface` are only defined from EDID 1.4; nil means undefined there.
        case digital(bitsPerColor: Int?, interface: DigitalInterface?)
        case analog
    }

    public enum DigitalInterface: String, Hashable, Sendable {
        case dvi = "DVI", hdmiA = "HDMI-a", hdmiB = "HDMI-b", mddi = "MDDI", displayPort = "DisplayPort"
    }

    public enum ScreenSize: Hashable, Sendable {
        case centimeters(width: Int, height: Int)
        /// EDID 1.4 may give only an aspect ratio (for projectors and variable-size screens).
        case landscapeAspect(Double)
        case portraitAspect(Double)
        case undefined
    }

    public struct Features: Hashable, Sendable {
        public var standby: Bool
        public var suspend: Bool
        public var activeOff: Bool
        /// Bits 4–3 of byte 24; meaning depends on digital/analog input.
        public var colorType: Int
        public var sRGBDefault: Bool
        /// EDID 1.4: the preferred timing carries the native pixel format and refresh rate.
        public var preferredTimingIsNative: Bool
        /// EDID 1.4: continuous frequency. EDID 1.3 and older: GTF supported.
        public var continuousFrequency: Bool
    }

    public struct Chromaticity: Hashable, Sendable {
        public var red: Point, green: Point, blue: Point, white: Point
        public struct Point: Hashable, Sendable {
            public var x: Double
            public var y: Double
        }
    }

    /// An established or standard timing: a size and a nominal rate, nothing more.
    public struct ListedTiming: Hashable, Sendable {
        public var width: Int
        public var height: Int
        public var refreshHz: Double
        public var interlaced: Bool
    }

    public struct DetailedTiming: Hashable, Sendable {
        public var pixelClockKHz: Int
        public var horizontalActive: Int
        public var horizontalBlanking: Int
        public var horizontalFrontPorch: Int
        public var horizontalSyncWidth: Int
        public var verticalActive: Int
        public var verticalBlanking: Int
        public var verticalFrontPorch: Int
        public var verticalSyncWidth: Int
        public var imageWidthMM: Int?
        public var imageHeightMM: Int?
        public var interlaced: Bool
        /// DisplayID marks a preferred timing itself; for EDID descriptors it is the first one.
        public var preferred: Bool
        /// EDID detailed timings count an interlaced mode's vertical lines per field; DisplayID
        /// descriptors count the frame.
        public var verticalCountsPerField: Bool = false

        /// Visible lines of the whole frame (1080 for 1080i).
        public var frameHeight: Int {
            interlaced && verticalCountsPerField ? verticalActive * 2 : verticalActive
        }

        /// Frame rate, or for interlaced timings the field rate; nil when a total is 0. A per-field
        /// interlaced timing has half a line more per field (1125-line 1080i = 2 × 562.5).
        public var refreshHz: Double? {
            let horizontal = Double(horizontalActive + horizontalBlanking)
            var vertical = Double(verticalActive + verticalBlanking)
            if interlaced && verticalCountsPerField { vertical += 0.5 }
            guard horizontal > 0, vertical > 0, pixelClockKHz > 0 else { return nil }
            return Double(pixelClockKHz) * 1000 / (horizontal * vertical)
        }
    }

    public struct RangeLimits: Hashable, Sendable {
        public var minVerticalHz: Int
        public var maxVerticalHz: Int
        public var minHorizontalKHz: Int
        public var maxHorizontalKHz: Int
        /// Nil when the byte is 0 (not given).
        public var maxPixelClockMHz: Int?
    }

    // MARK: Extensions

    public struct Extension: Hashable, Sendable {
        /// Position in the file, base = 0.
        public var block: Int
        public var tag: Int
        public var checksumValid: Bool
        public var content: Content

        public enum Content: Hashable, Sendable {
            case cta(CTA)
            case displayID(DisplayID)
            /// Known or unknown extension types not decoded here; their bytes are still shown.
            case undecoded
        }
    }

    public struct CTA: Hashable, Sendable {
        public var revision: Int
        /// Byte 3 flags, defined from revision 2.
        public var underscan: Bool?
        public var basicAudio: Bool?
        public var ycbcr444: Bool?
        public var ycbcr422: Bool?
        public var nativeDetailedTimingCount: Int?
        public var videoFormats: [ShortVideo]
        /// Formats offered only with YCbCr 4:2:0 sampling.
        public var ycbcr420OnlyFormats: [ShortVideo]
        public var audioFormats: [ShortAudio]
        public var speakerAllocation: [UInt8]?
        public var hdmi: HDMIVendorBlock?
        public var hdmiForum: HDMIForumBlock?
        /// Vendor-specific blocks by IEEE OUI that aren't decoded further (FreeSync, Dolby, …).
        public var otherVendorOUIs: [Int]
        public var colorimetry: [Colorimetry]
        public var hdrStaticMetadata: HDRStaticMetadata?
        /// From the Video Capability block: whether RGB / YCC quantization range is selectable.
        public var quantization: Quantization?
        /// Data blocks present but not decoded: tag, and the extended tag for tag 7.
        public var otherDataBlocks: [DataBlockTag]
        public var detailedTimings: [DetailedTiming]

        public struct Quantization: Hashable, Sendable {
            public var rgbSelectable: Bool
            public var yccSelectable: Bool
        }
    }

    public struct DataBlockTag: Hashable, Sendable {
        public var tag: Int
        public var extendedTag: Int?
    }

    public struct ShortVideo: Hashable, Sendable {
        public var vic: Int
        public var native: Bool
        public var format: CTAVideoFormats.Format? { CTAVideoFormats.format(vic: vic) }
    }

    public struct ShortAudio: Hashable, Sendable {
        public var formatCode: Int
        public var channels: Int
        /// Sample rates in Hz.
        public var sampleRates: [Int]
    }

    public struct HDMIVendorBlock: Hashable, Sendable {
        /// CEC physical address a.b.c.d.
        public var physicalAddress: String
        public var deepColor30: Bool
        public var deepColor36: Bool
        public var deepColor48: Bool
        public var deepColorYCbCr444: Bool
        public var maxTMDSClockMHz: Int?
    }

    public struct HDMIForumBlock: Hashable, Sendable {
        public var version: Int
        /// Nil when 0 (the HDMI 1.4 block's limit applies).
        public var maxTMDSCharacterRateMHz: Int?
        /// 0 = no FRL; otherwise the CTA/HDMI 2.1 Max_FRL_Rate code.
        public var maxFRLRateCode: Int?

        /// Lanes and per-lane rate for a Max_FRL_Rate code, nil for 0 or reserved codes.
        public var maxFRL: (lanes: Int, gbpsPerLane: Int)? {
            switch maxFRLRateCode {
            case 1: return (3, 3)
            case 2: return (3, 6)
            case 3: return (4, 6)
            case 4: return (4, 8)
            case 5: return (4, 10)
            case 6: return (4, 12)
            default: return nil
            }
        }
    }

    public enum Colorimetry: String, Hashable, Sendable, CaseIterable {
        case xvYCC601, xvYCC709, sYCC601, opYCC601, opRGB, bt2020cYCC = "BT2020cYCC"
        case bt2020YCC = "BT2020YCC", bt2020RGB = "BT2020RGB"
        /// Bit 7 of the block's second flags byte.
        case dciP3 = "DCI-P3"
    }

    public struct HDRStaticMetadata: Hashable, Sendable {
        public var traditionalSDR: Bool
        public var traditionalHDR: Bool
        public var pq: Bool
        public var hlg: Bool
        /// Desired content luminance the sink states, in cd/m², when given.
        public var maxLuminance: Double?
        public var maxFrameAverageLuminance: Double?
        public var minLuminance: Double?
    }

    public struct DisplayID: Hashable, Sendable {
        public var version: Int
        public var revision: Int
        public var productType: Int
        public var sectionChecksumValid: Bool
        public var product: Product?
        public var parameters: Parameters?
        public var timings: [DetailedTiming]
        public var tiles: [Tile]
        public var otherBlockTags: [Int]

        public struct Product: Hashable, Sendable {
            /// PnP letters (DisplayID 1.x) or an IEEE OUI as hex (2.x).
            public var vendor: String
            public var productCode: Int
            public var serialNumber: UInt32
            public var manufacture: Manufacture
            public var name: String?
        }

        public struct Parameters: Hashable, Sendable {
            public var imageWidthMM: Double?
            public var imageHeightMM: Double?
            public var nativeWidth: Int?
            public var nativeHeight: Int?
            /// DisplayID 2.x only: the panel's native maximum luminance with the whole screen lit,
            /// with a 10% window lit, and its native minimum, in cd/m². Nil when the block is too
            /// short to carry them, and a maximum of 0 means not stated.
            public var maxLuminanceFullCoverage: Double? = nil
            public var maxLuminanceTenPercent: Double? = nil
            public var minLuminance: Double? = nil
        }

        public struct Tile: Hashable, Sendable {
            public var horizontalTiles: Int
            public var verticalTiles: Int
            /// Zero-based position of this tile.
            public var column: Int
            public var row: Int
            public var tileWidth: Int
            public var tileHeight: Int
            public var singleEnclosure: Bool
            public var vendor: String?
            public var productCode: Int?
            public var serialNumber: UInt32?
        }
    }
}

// MARK: - Decoding

public enum EDIDDecoder {
    public static func decode(_ bytes: [UInt8]) -> EDIDDecoded {
        var issues: [EDIDDecoded.Issue] = []
        guard bytes.count >= 128 else {
            return EDIDDecoded(byteCount: bytes.count, base: nil, extensions: [],
                               issues: [.tooShort(byteCount: bytes.count)])
        }
        guard Array(bytes[0..<8]) == [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00] else {
            return EDIDDecoded(byteCount: bytes.count, base: nil, extensions: [], issues: [.invalidHeader])
        }
        let base = decodeBase(Array(bytes[0..<128]))
        if !base.checksumValid { issues.append(.baseChecksumInvalid) }
        let word = (Int(bytes[8]) << 8) | Int(bytes[9])
        let letters = [(word >> 10) & 0x1F, (word >> 5) & 0x1F, word & 0x1F]
        if word & 0x8000 != 0 || !letters.allSatisfy({ (1...26).contains($0) }) {
            issues.append(.invalidManufacturer)
        }

        let completeBlocks = bytes.count / 128
        let present = completeBlocks - 1
        if base.declaredExtensionCount > present {
            issues.append(.missingExtensions(declared: base.declaredExtensionCount, present: present))
        } else if base.declaredExtensionCount < present {
            issues.append(.undeclaredBlocks(declared: base.declaredExtensionCount, present: present))
        }
        if bytes.count % 128 != 0 { issues.append(.partialTrailingBlock(bytes: bytes.count % 128)) }

        var extensions: [EDIDDecoded.Extension] = []
        if present > 0 {
            for block in 1...present {
                let data = Array(bytes[(block * 128)..<(block * 128 + 128)])
                let valid = checksumOK(data)
                if !valid { issues.append(.extensionChecksumInvalid(block: block)) }
                let content: EDIDDecoded.Extension.Content
                switch data[0] {
                case 0x02: content = .cta(decodeCTA(data, block: block, issues: &issues))
                case 0x70: content = decodeDisplayIDBlock(data, block: block, issues: &issues)
                default: content = .undecoded
                }
                extensions.append(EDIDDecoded.Extension(block: block, tag: Int(data[0]),
                                                        checksumValid: valid, content: content))
            }
        }
        return EDIDDecoded(byteCount: bytes.count, base: base, extensions: extensions, issues: issues)
    }

    /// Name of an extension tag (the VESA-assigned block types).
    public static func extensionName(tag: Int, _ l: ReportLocalizer = .english) -> String {
        switch tag {
        case 0x02: return "CTA-861"
        case 0x10: return l("Video Timing Block")
        case 0x20: return "EDID 2.0"
        case 0x40: return l("Display Information")
        case 0x50: return l("Localized String")
        case 0x60: return l("Digital Packet Video Link")
        case 0x70: return "DisplayID"
        case 0xF0: return l("Block Map")
        case 0xFF: return l("Manufacturer-specific")
        default: return l.fill("Type %1", String(format: "0x%02X", tag))
        }
    }

    static func checksumOK(_ block: [UInt8]) -> Bool {
        block.reduce(0) { $0 + Int($1) } % 256 == 0
    }

    // MARK: Base block

    static func decodeBase(_ b: [UInt8]) -> EDIDDecoded.Base {
        let word = (Int(b[8]) << 8) | Int(b[9])
        let codes: [Int] = [(word >> 10) & 0x1F, (word >> 5) & 0x1F, word & 0x1F]
        let letters: [Character] = codes.map { code in
            (1...26).contains(code) ? Character(UnicodeScalar(UInt8(code + 64))) : "?"
        }
        let manufacturerID = String(letters)
        let product = Int(b[10]) | (Int(b[11]) << 8)
        let serialLow = UInt32(b[12]) | (UInt32(b[13]) << 8)
        let serial = serialLow | (UInt32(b[14]) << 16) | (UInt32(b[15]) << 24)
        let version = Int(b[18]), revision = Int(b[19])
        let is14 = version > 1 || (version == 1 && revision >= 4)

        let manufacture = manufactureDate(week: Int(b[16]), yearByte: Int(b[17]), yearBase: 1990)

        let videoInput: EDIDDecoded.VideoInput
        if b[20] & 0x80 != 0 {
            if is14 {
                let depthCode = Int((b[20] >> 4) & 0x07)
                let depth: Int? = (1...6).contains(depthCode) ? 4 + depthCode * 2 : nil
                let interface: EDIDDecoded.DigitalInterface?
                switch b[20] & 0x0F {
                case 1: interface = .dvi
                case 2: interface = .hdmiA
                case 3: interface = .hdmiB
                case 4: interface = .mddi
                case 5: interface = .displayPort
                default: interface = nil
                }
                videoInput = .digital(bitsPerColor: depth, interface: interface)
            } else {
                videoInput = .digital(bitsPerColor: nil, interface: nil)
            }
        } else {
            videoInput = .analog
        }

        let screenSize: EDIDDecoded.ScreenSize
        switch (b[21], b[22]) {
        case (0, 0): screenSize = .undefined
        case let (w, h) where w > 0 && h > 0: screenSize = .centimeters(width: Int(w), height: Int(h))
        case let (w, 0) where is14: screenSize = .landscapeAspect((Double(w) + 99) / 100)
        case let (0, h) where is14: screenSize = .portraitAspect(100 / (Double(h) + 99))
        default: screenSize = .undefined
        }

        let features = EDIDDecoded.Features(
            standby: b[24] & 0x80 != 0, suspend: b[24] & 0x40 != 0, activeOff: b[24] & 0x20 != 0,
            colorType: Int((b[24] >> 3) & 0x03), sRGBDefault: b[24] & 0x04 != 0,
            preferredTimingIsNative: b[24] & 0x02 != 0, continuousFrequency: b[24] & 0x01 != 0)

        func chroma(_ high: UInt8, _ low: Int) -> Double { Double((Int(high) << 2) | low) / 1024 }
        let chromaticity = EDIDDecoded.Chromaticity(
            red: .init(x: chroma(b[27], Int(b[25] >> 6) & 3), y: chroma(b[28], Int(b[25] >> 4) & 3)),
            green: .init(x: chroma(b[29], Int(b[25] >> 2) & 3), y: chroma(b[30], Int(b[25]) & 3)),
            blue: .init(x: chroma(b[31], Int(b[26] >> 6) & 3), y: chroma(b[32], Int(b[26] >> 4) & 3)),
            white: .init(x: chroma(b[33], Int(b[26] >> 2) & 3), y: chroma(b[34], Int(b[26]) & 3)))

        var detailed: [EDIDDecoded.DetailedTiming] = []
        var monitorName: String?, serialText: String?
        var otherText: [String] = []
        var rangeLimits: EDIDDecoded.RangeLimits?
        var otherTags: [Int] = []
        for offset in [54, 72, 90, 108] {
            let d = Array(b[offset..<offset + 18])
            if d[0] != 0 || d[1] != 0 {
                if var timing = detailedTiming(d) {
                    timing.preferred = detailed.isEmpty && offset == 54
                    detailed.append(timing)
                }
                continue
            }
            switch d[3] {
            case 0xFC: monitorName = descriptorText(d)
            case 0xFF: serialText = descriptorText(d)
            case 0xFE: otherText.append(descriptorText(d))
            case 0xFD: rangeLimits = decodeRangeLimits(d, is14: is14)
            default: otherTags.append(Int(d[3]))
            }
        }

        return EDIDDecoded.Base(
            manufacturerID: manufacturerID, manufacturerCode: word, productCode: product,
            serialNumber: serial, manufacture: manufacture, version: version, revision: revision,
            videoInput: videoInput, screenSize: screenSize,
            gamma: b[23] == 0xFF ? nil : (Double(b[23]) + 100) / 100,
            features: features, chromaticity: chromaticity,
            establishedTimings: establishedTimings(b[35], b[36], b[37]),
            standardTimings: standardTimings(Array(b[38..<54]), version: version, revision: revision),
            detailedTimings: detailed, monitorName: monitorName, serialText: serialText,
            otherText: otherText, rangeLimits: rangeLimits, otherDescriptorTags: otherTags,
            declaredExtensionCount: Int(b[126]), checksumValid: checksumOK(b))
    }

    static func manufactureDate(week: Int, yearByte: Int, yearBase: Int) -> EDIDDecoded.Manufacture {
        if week == 0xFF { return .modelYear(yearBase + yearByte) }
        guard yearByte > 0 || yearBase == 2000 else { return .unspecified }
        let year = yearBase + yearByte
        if (1...54).contains(week) { return .week(week, year: year) }
        return .year(year)
    }

    static func detailedTiming(_ d: [UInt8]) -> EDIDDecoded.DetailedTiming? {
        let clock = (Int(d[0]) | (Int(d[1]) << 8)) * 10
        guard clock > 0 else { return nil }
        let width = Int(d[12]) | ((Int(d[14]) >> 4) << 8)
        let height = Int(d[13]) | ((Int(d[14]) & 0x0F) << 8)
        return EDIDDecoded.DetailedTiming(
            pixelClockKHz: clock,
            horizontalActive: Int(d[2]) | ((Int(d[4]) >> 4) << 8),
            horizontalBlanking: Int(d[3]) | ((Int(d[4]) & 0x0F) << 8),
            horizontalFrontPorch: Int(d[8]) | (((Int(d[11]) >> 6) & 0x03) << 8),
            horizontalSyncWidth: Int(d[9]) | (((Int(d[11]) >> 4) & 0x03) << 8),
            verticalActive: Int(d[5]) | ((Int(d[7]) >> 4) << 8),
            verticalBlanking: Int(d[6]) | ((Int(d[7]) & 0x0F) << 8),
            verticalFrontPorch: (Int(d[10]) >> 4) | (((Int(d[11]) >> 2) & 0x03) << 4),
            verticalSyncWidth: (Int(d[10]) & 0x0F) | ((Int(d[11]) & 0x03) << 4),
            imageWidthMM: width > 0 ? width : nil, imageHeightMM: height > 0 ? height : nil,
            interlaced: d[17] & 0x80 != 0, preferred: false, verticalCountsPerField: true)
    }

    /// Text descriptors carry up to 13 bytes (5…17), newline-terminated and space-padded.
    static func descriptorText(_ d: [UInt8]) -> String {
        var scalars: [Character] = []
        for byte in d[5..<18] {
            if byte == 0x0A || byte == 0 { break }
            scalars.append(byte >= 0x20 && byte < 0x7F ? Character(UnicodeScalar(byte)) : "?")
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    static func decodeRangeLimits(_ d: [UInt8], is14: Bool) -> EDIDDecoded.RangeLimits {
        let flags = is14 ? Int(d[4]) : 0
        return EDIDDecoded.RangeLimits(
            minVerticalHz: Int(d[5]) + (flags & 0x03 == 0x03 ? 255 : 0),
            maxVerticalHz: Int(d[6]) + (flags & 0x02 != 0 ? 255 : 0),
            minHorizontalKHz: Int(d[7]) + (flags & 0x0C == 0x0C ? 255 : 0),
            maxHorizontalKHz: Int(d[8]) + (flags & 0x08 != 0 ? 255 : 0),
            maxPixelClockMHz: d[9] > 0 ? Int(d[9]) * 10 : nil)
    }

    static func establishedTimings(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8) -> [EDIDDecoded.ListedTiming] {
        let table: [(UInt8, UInt8, Int, Int, Double, Bool)] = [
            (0, 0x80, 720, 400, 70, false), (0, 0x40, 720, 400, 88, false),
            (0, 0x20, 640, 480, 60, false), (0, 0x10, 640, 480, 67, false),
            (0, 0x08, 640, 480, 72, false), (0, 0x04, 640, 480, 75, false),
            (0, 0x02, 800, 600, 56, false), (0, 0x01, 800, 600, 60, false),
            (1, 0x80, 800, 600, 72, false), (1, 0x40, 800, 600, 75, false),
            (1, 0x20, 832, 624, 75, false), (1, 0x10, 1024, 768, 87, true),
            (1, 0x08, 1024, 768, 60, false), (1, 0x04, 1024, 768, 70, false),
            (1, 0x02, 1024, 768, 75, false), (1, 0x01, 1280, 1024, 75, false),
            (2, 0x80, 1152, 870, 75, false),
        ]
        let bytes = [b0, b1, b2]
        return table.filter { bytes[Int($0.0)] & $0.1 != 0 }.map {
            EDIDDecoded.ListedTiming(width: $0.2, height: $0.3, refreshHz: $0.4, interlaced: $0.5)
        }
    }

    static func standardTimings(_ bytes: [UInt8], version: Int, revision: Int) -> [EDIDDecoded.ListedTiming] {
        var result: [EDIDDecoded.ListedTiming] = []
        for index in stride(from: 0, to: bytes.count - 1, by: 2) {
            let first = bytes[index], second = bytes[index + 1]
            if (first == 0x01 && second == 0x01) || first == 0 { continue }
            let width = (Int(first) + 31) * 8
            let height: Int
            switch second >> 6 {
            case 0: height = (version == 1 && revision < 3) ? width : width * 10 / 16
            case 1: height = width * 3 / 4
            case 2: height = width * 4 / 5
            default: height = width * 9 / 16
            }
            result.append(EDIDDecoded.ListedTiming(width: width, height: height,
                                                   refreshHz: Double(Int(second & 0x3F) + 60),
                                                   interlaced: false))
        }
        return result
    }
}
