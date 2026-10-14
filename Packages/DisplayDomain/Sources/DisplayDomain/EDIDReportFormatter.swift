// SPDX-License-Identifier: GPL-3.0-or-later
// Original clean-room implementation for FreeDisplay.
import Foundation

/// Words a decoded EDID as report sections — the rows the EDID pane shows and copies. Every value
/// is what the bytes state; nothing here claims the display or macOS supports it.
public enum EDIDReportFormatter {
    public static func sections(_ edid: EDIDDecoded, _ l: ReportLocalizer = .english) -> [InfoReport.Section] {
        var sections = [structure(edid, l)]
        guard let base = edid.base else { return sections }
        sections.append(identification(base, l))
        sections.append(parameters(base, l))
        var timings = InfoReport.Section(title: l("Detailed timings"))
        for (index, timing) in base.detailedTimings.enumerated() {
            timings.rows.append(.init(timing.preferred ? l("Preferred timing") : l.fill("Detailed timing %1", "\(index + 1)"),
                                      timingText(timing, l)))
        }
        if let range = base.rangeLimits {
            timings.rows.append(.init(l("Vertical rate range"), l.fill("%1–%2 Hz", "\(range.minVerticalHz)", "\(range.maxVerticalHz)")))
            timings.rows.append(.init(l("Horizontal rate range"), l.fill("%1–%2 kHz", "\(range.minHorizontalKHz)", "\(range.maxHorizontalKHz)")))
            if let clock = range.maxPixelClockMHz {
                timings.rows.append(.init(l("Maximum pixel clock"), l.fill("%1 MHz", "\(clock)")))
            }
        }
        if !base.establishedTimings.isEmpty {
            timings.rows.append(.init(l("Established timings"), base.establishedTimings.map { listed($0, l) }.joined(separator: "\n")))
        }
        if !base.standardTimings.isEmpty {
            timings.rows.append(.init(l("Standard timings"), base.standardTimings.map { listed($0, l) }.joined(separator: "\n")))
        }
        if !base.otherDescriptorTags.isEmpty {
            timings.rows.append(.init(l("Other descriptors"), base.otherDescriptorTags.map(hexByte).joined(separator: ", ")))
        }
        sections.append(timings)
        for ext in edid.extensions { sections.append(extensionSection(ext, l)) }
        return sections.filter { !$0.isEmpty }
    }

    /// One sentence per structural problem.
    public static func issueText(_ issue: EDIDDecoded.Issue, _ l: ReportLocalizer = .english) -> String {
        switch issue {
        case .tooShort(let count):
            return l.fill("Too short (%1 B): an EDID needs at least 128 bytes.", "\(count)")
        case .invalidHeader:
            return l("The bytes don’t start with the EDID header.")
        case .invalidManufacturer:
            return l("The manufacturer code isn’t a valid three-letter ID.")
        case .baseChecksumInvalid:
            return l("The base block checksum is wrong.")
        case .extensionChecksumInvalid(let block):
            return l.fill("The checksum of block %1 is wrong.", "\(block)")
        case .missingExtensions(let declared, let present):
            return l.fill("Extension blocks declared by the base block: %1, present: %2. The EDID is incomplete.",
                          "\(declared)", "\(present)")
        case .undeclaredBlocks(let declared, let present):
            return l.fill("Extension blocks declared by the base block: %1, present: %2.", "\(declared)", "\(present)")
        case .partialTrailingBlock(let bytes):
            return l.fill("Bytes after the last complete block that don’t form a whole block: %1.", "\(bytes)")
        case .ctaLayoutInvalid(let block):
            return l.fill("Block %1 (CTA-861) has an invalid layout; its data blocks weren’t decoded.", "\(block)")
        case .ctaDataBlockOverrun(let block):
            return l.fill("A data block in block %1 (CTA-861) runs past its area; decoding stopped there.", "\(block)")
        case .displayIDSectionOverrun(let block):
            return l.fill("The DisplayID section in block %1 is longer than the block.", "\(block)")
        case .displayIDChecksumInvalid(let block):
            return l.fill("The DisplayID section checksum in block %1 is wrong.", "\(block)")
        case .displayIDDataBlockOverrun(let block, let tag):
            return l.fill("DisplayID data block %2 in block %1 runs past the section; decoding stopped there.",
                          "\(block)", hexByte(tag))
        case .ctaDataBlockMalformed(let block, let tag, let extended):
            return l.fill("The %2 data block in block %1 (CTA-861) is malformed for its type; only what could be read is shown.",
                          "\(block)", EDIDDecoder.ctaDataBlockName(.init(tag: tag, extendedTag: extended), l))
        case .displayIDDataBlockMalformed(let block, let tag):
            return l.fill("The %2 data block in block %1 (DisplayID) is malformed for its type; only what could be read is shown.",
                          "\(block)", EDIDDecoder.displayIDBlockName(tag, l))
        }
    }

    // MARK: Sections

    static func structure(_ edid: EDIDDecoded, _ l: ReportLocalizer) -> InfoReport.Section {
        var section = InfoReport.Section(title: l("Structure"))
        section.rows.append(.init(l("Size"), l.fill("%1 B, complete 128-byte blocks: %2", "\(edid.byteCount)", "\(edid.byteCount / 128)")))
        if let base = edid.base {
            section.rows.append(.init(l("Extension blocks"), l.fill("%1 declared, %2 present",
                                                                    "\(base.declaredExtensionCount)", "\(edid.extensions.count)")))
            section.rows.append(.init(l("Base block checksum"), validText(base.checksumValid, l)))
        }
        section.rows.append(.init(l("Structure check"), edid.isStructurallyValid
            ? l("No problems found") : l.fill("Problems found: %1", "\(edid.issues.count)")))
        section.notes = edid.issues.map { issueText($0, l) }
        return section
    }

    static func identification(_ base: EDIDDecoded.Base, _ l: ReportLocalizer) -> InfoReport.Section {
        var rows: [InfoReport.Row] = [
            .init(l("Manufacturer"), "\(base.manufacturerID) (\(hexWord(base.manufacturerCode)))"),
            .init(l("Product code"), "\(base.productCode) (\(hexWord(base.productCode)))"),
            .init(l("Serial number"), base.serialNumber == 0 ? l("Not set") : "\(base.serialNumber)"),
        ]
        if let text = base.serialText { rows.append(.init(l("Serial number (text)"), text)) }
        if let name = base.monitorName { rows.append(.init(l("Monitor name"), name)) }
        if !base.otherText.isEmpty { rows.append(.init(l("Text"), base.otherText.joined(separator: "\n"))) }
        rows.append(.init(l("Manufactured"), manufactureText(base.manufacture, l)))
        rows.append(.init(l("EDID version"), "\(base.version).\(base.revision)"))
        return InfoReport.Section(title: l("Identification"), rows: rows)
    }

    static func parameters(_ base: EDIDDecoded.Base, _ l: ReportLocalizer) -> InfoReport.Section {
        var rows: [InfoReport.Row] = []
        let is14 = base.version > 1 || (base.version == 1 && base.revision >= 4)
        switch base.videoInput {
        case .digital(let bits, let interface):
            var parts = [l("Digital")]
            if let bits { parts.append(l.fill("%1 bits per colour", "\(bits)")) }
            if let interface { parts.append(interface.rawValue) }
            rows.append(.init(l("Video input"), parts.joined(separator: ", ")))
            let encodings = ["RGB 4:4:4", "RGB 4:4:4, YCbCr 4:4:4", "RGB 4:4:4, YCbCr 4:2:2",
                             "RGB 4:4:4, YCbCr 4:4:4, YCbCr 4:2:2"]
            if is14 { rows.append(.init(l("Colour encodings"), encodings[base.features.colorType])) }
        case .analog:
            rows.append(.init(l("Video input"), l("Analog")))
            let types = [l("Monochrome or greyscale"), l("RGB colour"), l("Non-RGB colour"), l("Undefined")]
            rows.append(.init(l("Display type"), types[base.features.colorType]))
        }
        switch base.screenSize {
        case .centimeters(let width, let height):
            rows.append(.init(l("Screen size"), l.fill("%1 × %2 cm", "\(width)", "\(height)")))
        case .landscapeAspect(let ratio):
            rows.append(.init(l("Screen size"), l.fill("Aspect ratio %1:1, landscape (no size given)", l.decimal(ratio, 2))))
        case .portraitAspect(let ratio):
            rows.append(.init(l("Screen size"), l.fill("Aspect ratio %1:1, portrait (no size given)", l.decimal(ratio, 2))))
        case .undefined:
            rows.append(.init(l("Screen size"), l("Not specified")))
        }
        rows.append(.init(l("Gamma"), base.gamma.map { l.decimal($0, 2) } ?? l("Given in an extension block")))
        rows.append(.init(l("sRGB is the default colour space"), l.yesNo(base.features.sRGBDefault)))
        if is14 {
            rows.append(.init(l("Preferred timing is native"), l.yesNo(base.features.preferredTimingIsNative)))
            rows.append(.init(l("Continuous frequency"), l.yesNo(base.features.continuousFrequency)))
        } else {
            rows.append(.init(l("GTF supported"), l.yesNo(base.features.continuousFrequency)))
        }
        var power: [String] = []
        if base.features.standby { power.append(l("standby")) }
        if base.features.suspend { power.append(l("suspend")) }
        if base.features.activeOff { power.append(l("active off")) }
        rows.append(.init(l("Power states"), power.isEmpty ? l("None stated") : power.joined(separator: ", ")))
        let c = base.chromaticity
        func point(_ name: String, _ p: EDIDDecoded.Chromaticity.Point) -> String {
            "\(name) (\(l.decimal(p.x, 3)), \(l.decimal(p.y, 3)))"
        }
        rows.append(.init(l("Chromaticity (x, y)"),
                          [point("R", c.red), point("G", c.green), point("B", c.blue), point("W", c.white)]
                              .joined(separator: " · ")))
        return InfoReport.Section(title: l("Display parameters"), rows: rows)
    }

    static func extensionSection(_ ext: EDIDDecoded.Extension, _ l: ReportLocalizer) -> InfoReport.Section {
        switch ext.content {
        case .cta(let cta):
            var section = InfoReport.Section(title: l.fill("Block %1: CTA-861, revision %2", "\(ext.block)", "\(cta.revision)"))
            section.rows = [.init(l("Checksum"), validText(ext.checksumValid, l))] + ctaRows(cta, l)
            return section
        case .displayID(let id):
            var section = InfoReport.Section(title: l.fill("Block %1: DisplayID %2.%3", "\(ext.block)", "\(id.version)", "\(id.revision)"))
            section.rows = [.init(l("Checksum"), validText(ext.checksumValid, l)),
                            .init(l("Section checksum"), validText(id.sectionChecksumValid, l))]
                + displayIDRows(id, l)
            return section
        case .undecoded:
            return InfoReport.Section(
                title: l.fill("Block %1: %2", "\(ext.block)", EDIDDecoder.extensionName(tag: ext.tag, l)),
                rows: [.init(l("Checksum"), validText(ext.checksumValid, l)),
                       .init(l("Contents"), l("Not decoded; the bytes are in the byte view."))])
        }
    }

    static func ctaRows(_ cta: EDIDDecoded.CTA, _ l: ReportLocalizer) -> [InfoReport.Row] {
        var rows: [InfoReport.Row] = []
        if let underscan = cta.underscan, let audio = cta.basicAudio, let y444 = cta.ycbcr444, let y422 = cta.ycbcr422 {
            var flags: [String] = []
            if underscan { flags.append(l("underscans IT formats by default")) }
            if audio { flags.append(l("basic audio")) }
            if y444 { flags.append("YCbCr 4:4:4") }
            if y422 { flags.append("YCbCr 4:2:2") }
            rows.append(.init(l("Supports"), flags.isEmpty ? l("None stated") : flags.joined(separator: ", ")))
        }
        if let native = cta.nativeDetailedTimingCount {
            rows.append(.init(l("Native detailed timings"), "\(native)"))
        }
        if !cta.videoFormats.isEmpty {
            rows.append(.init(l("Video formats"), cta.videoFormats.map { videoText($0, l) }.joined(separator: "\n")))
        }
        if !cta.ycbcr420OnlyFormats.isEmpty {
            rows.append(.init(l("Formats only in YCbCr 4:2:0"), cta.ycbcr420OnlyFormats.map { videoText($0, l) }.joined(separator: "\n")))
        }
        if !cta.audioFormats.isEmpty {
            rows.append(.init(l("Audio formats"), cta.audioFormats.map { audio in
                let rates = audio.sampleRates.map { l.decimal(Double($0) / 1000, 1) }.joined(separator: "/")
                return l.fill("%1, channels: %2, %3 kHz", EDIDDecoder.audioFormatName(audio.formatCode, l), "\(audio.channels)", rates)
            }.joined(separator: "\n")))
        }
        if let speakers = cta.speakerAllocation {
            rows.append(.init(l("Speaker allocation"), speakers.map { hexByte(Int($0)) }.joined(separator: " ")))
        }
        if let hdmi = cta.hdmi {
            var lines = [l.fill("Physical address %1", hdmi.physicalAddress)]
            if let clock = hdmi.maxTMDSClockMHz { lines.append(l.fill("Maximum TMDS clock %1 MHz", "\(clock)")) }
            let depths = [(hdmi.deepColor30, "30"), (hdmi.deepColor36, "36"), (hdmi.deepColor48, "48")].filter(\.0).map(\.1)
            if !depths.isEmpty { lines.append(l.fill("Deep colour: %1 bits per pixel", depths.joined(separator: ", "))) }
            if hdmi.deepColorYCbCr444 { lines.append(l("Deep colour also in YCbCr 4:4:4")) }
            rows.append(.init("HDMI", lines.joined(separator: "\n")))
        }
        if let forum = cta.hdmiForum {
            var lines = [l.fill("Version %1", "\(forum.version)")]
            if let rate = forum.maxTMDSCharacterRateMHz { lines.append(l.fill("Maximum TMDS character rate %1 MHz", "\(rate)")) }
            if let frl = forum.maxFRL {
                lines.append(l.fill("Maximum FRL: %1 lanes × %2 Gbit/s", "\(frl.lanes)", "\(frl.gbpsPerLane)"))
            } else if forum.maxFRLRateCode == 0 {
                lines.append(l("No FRL"))
            }
            rows.append(.init("HDMI Forum", lines.joined(separator: "\n")))
        }
        if !cta.otherVendorOUIs.isEmpty {
            rows.append(.init(l("Other vendor blocks"), cta.otherVendorOUIs.map(vendorText).joined(separator: "\n")))
        }
        if !cta.colorimetry.isEmpty {
            rows.append(.init(l("Colorimetry"), cta.colorimetry.map(\.rawValue).joined(separator: ", ")))
        }
        if let hdr = cta.hdrStaticMetadata {
            var curves: [String] = []
            if hdr.traditionalSDR { curves.append(l("SDR gamma")) }
            if hdr.traditionalHDR { curves.append(l("HDR gamma")) }
            if hdr.pq { curves.append("SMPTE ST 2084 (PQ)") }
            if hdr.hlg { curves.append("HLG") }
            var lines = [l.fill("Transfer functions: %1", curves.isEmpty ? l("None stated") : curves.joined(separator: ", "))]
            if let value = hdr.maxLuminance { lines.append(l.fill("Desired maximum luminance %1 cd/m²", l.decimal(value, 1))) }
            if let value = hdr.maxFrameAverageLuminance {
                lines.append(l.fill("Desired maximum frame-average luminance %1 cd/m²", l.decimal(value, 1)))
            }
            if let value = hdr.minLuminance { lines.append(l.fill("Desired minimum luminance %1 cd/m²", l.decimal(value, 4))) }
            rows.append(.init(l("HDR static metadata"), lines.joined(separator: "\n")))
        }
        if let quantization = cta.quantization {
            rows.append(.init(l("Quantization range selectable"),
                              l.fill("RGB: %1, YCC: %2", l.yesNo(quantization.rgbSelectable), l.yesNo(quantization.yccSelectable))))
        }
        if !cta.otherDataBlocks.isEmpty {
            rows.append(.init(l("Other data blocks"), cta.otherDataBlocks.map { EDIDDecoder.ctaDataBlockName($0, l) }.joined(separator: ", ")))
        }
        if !cta.detailedTimings.isEmpty {
            rows.append(.init(l("Detailed timings"), cta.detailedTimings.map { timingText($0, l) }.joined(separator: "\n")))
        }
        return rows
    }

    static func displayIDRows(_ id: EDIDDecoded.DisplayID, _ l: ReportLocalizer) -> [InfoReport.Row] {
        var rows: [InfoReport.Row] = [.init(l("Product type"), "\(id.productType)")]
        if let product = id.product {
            rows.append(.init(l("Vendor"), product.vendor))
            rows.append(.init(l("Product code"), "\(product.productCode) (\(hexWord(product.productCode)))"))
            rows.append(.init(l("Serial number"), product.serialNumber == 0 ? l("Not set") : "\(product.serialNumber)"))
            rows.append(.init(l("Manufactured"), manufactureText(product.manufacture, l)))
            if let name = product.name, !name.isEmpty { rows.append(.init(l("Product name"), name)) }
        }
        if let parameters = id.parameters {
            if let width = parameters.imageWidthMM, let height = parameters.imageHeightMM {
                rows.append(.init(l("Image size"), l.fill("%1 × %2 mm", l.decimal(width, 1), l.decimal(height, 1))))
            }
            if let width = parameters.nativeWidth, let height = parameters.nativeHeight {
                rows.append(.init(l("Native resolution"), l.fill("%1 × %2 pixels", "\(width)", "\(height)")))
            }
        }
        if !id.timings.isEmpty {
            rows.append(.init(l("Timings"), id.timings.map { timing in
                (timing.preferred ? l("Preferred:") + " " : "") + timingText(timing, l)
            }.joined(separator: "\n")))
        }
        for tile in id.tiles {
            var lines = [l.fill("%1 × %2 tiles; this tile is column %3, row %4",
                                "\(tile.horizontalTiles)", "\(tile.verticalTiles)", "\(tile.column + 1)", "\(tile.row + 1)"),
                         l.fill("Tile size %1 × %2 pixels", "\(tile.tileWidth)", "\(tile.tileHeight)"),
                         tile.singleEnclosure ? l("All tiles in one enclosure") : l("Tiles in separate enclosures")]
            if let vendor = tile.vendor, let product = tile.productCode, let serial = tile.serialNumber {
                lines.append(l.fill("Topology ID: vendor %1, product %2, serial %3", vendor, "\(product)", "\(serial)"))
            }
            rows.append(.init(l("Tiled display"), lines.joined(separator: "\n")))
        }
        if !id.otherBlockTags.isEmpty {
            rows.append(.init(l("Other data blocks"), id.otherBlockTags.map { "\(EDIDDecoder.displayIDBlockName($0, l)) (\(hexByte($0)))" }
                .joined(separator: ", ")))
        }
        return rows
    }

    // MARK: Values

    public static func timingText(_ t: EDIDDecoded.DetailedTiming, _ l: ReportLocalizer = .english) -> String {
        let size = "\(t.horizontalActive) × \(t.frameHeight)\(t.interlaced ? "i" : "")"
        var line = t.refreshHz.map { l.fill("%1 @ %2 Hz", size, l.decimal($0, 3)) } ?? size
        line += ", " + l.fill("pixel clock %1 MHz", l.decimal(Double(t.pixelClockKHz) / 1000, 3))
        if let width = t.imageWidthMM, let height = t.imageHeightMM {
            line += ", " + l.fill("image %1 × %2 mm", "\(width)", "\(height)")
        }
        let horizontal = l.fill("horizontal: front porch %1, sync %2, blanking %3",
                                "\(t.horizontalFrontPorch)", "\(t.horizontalSyncWidth)", "\(t.horizontalBlanking)")
        let vertical = l.fill("vertical: front porch %1, sync %2, blanking %3",
                              "\(t.verticalFrontPorch)", "\(t.verticalSyncWidth)", "\(t.verticalBlanking)")
        return line + "\n    " + horizontal + "; " + vertical
    }

    static func listed(_ t: EDIDDecoded.ListedTiming, _ l: ReportLocalizer) -> String {
        l.fill("%1 @ %2 Hz", "\(t.width) × \(t.height)\(t.interlaced ? "i" : "")", l.decimal(t.refreshHz, 2))
    }

    static func videoText(_ video: EDIDDecoded.ShortVideo, _ l: ReportLocalizer) -> String {
        let format = video.format.map {
            l.fill("%1 @ %2 Hz", "\($0.width) × \($0.height)\($0.interlaced ? "i" : "")", vicRateText($0.refreshHz, l))
                + " (\($0.aspect))"
        } ?? l("format not in the CTA table")
        return "VIC \(video.vic): \(format)" + (video.native ? " — " + l("native") : "")
    }

    /// A CTA rate of 24, 30, 48, 60, 120 or 240 Hz also covers its ×1000/1001 variant (59.94 for
    /// 60), so both are named; 25/50/100/200 Hz have none.
    static func vicRateText(_ hz: Double, _ l: ReportLocalizer) -> String {
        let integral = Int(hz)
        guard Double(integral) == hz, [24, 30, 48, 60, 120, 240].contains(integral) else { return l.decimal(hz, 2) }
        return l.decimal(hz * 1000 / 1001, 3) + "/" + l.decimal(hz, 2)
    }

    static func manufactureText(_ manufacture: EDIDDecoded.Manufacture, _ l: ReportLocalizer) -> String {
        switch manufacture {
        case .week(let week, let year): return l.fill("Week %1 of %2", "\(week)", "\(year)")
        case .year(let year): return "\(year)"
        case .modelYear(let year): return l.fill("Model year %1", "\(year)")
        case .unspecified: return l("Not specified")
        }
    }

    static func vendorText(_ oui: Int) -> String {
        let name: String?
        switch oui {
        case 0x00001A: name = "AMD"
        case 0x00044B: name = "NVIDIA"
        case 0x00D046: name = "Dolby"
        case 0x90848B: name = "HDR10+"
        case 0xCA125C: name = "Microsoft"
        default: name = nil
        }
        let hex = String(format: "%06X", oui)
        return name.map { "\($0) (\(hex))" } ?? hex
    }

    static func validText(_ valid: Bool, _ l: ReportLocalizer) -> String { valid ? l("Valid") : l("Invalid") }
    static func hexByte(_ value: Int) -> String { String(format: "0x%02X", value) }
    static func hexWord(_ value: Int) -> String { String(format: "0x%04X", value) }
}

/// Text renderings of raw EDID bytes for viewing and copying. All of them are exact: nothing is
/// elided, and Base64/hex round-trip to the same bytes.
public enum EDIDByteFormat: String, CaseIterable, Sendable, Identifiable {
    /// Offset, 16 bytes per line, a blank line between 128-byte blocks.
    case hexDump
    /// Every byte as two uppercase hex digits, no separators.
    case hex
    case base64
    /// A C array initializer.
    case cArray

    public var id: String { rawValue }

    public func render(_ bytes: [UInt8]) -> String {
        switch self {
        case .hexDump:
            var lines: [String] = []
            for start in stride(from: 0, to: bytes.count, by: 16) {
                if start > 0, start % 128 == 0 { lines.append("") }
                let row = bytes[start..<min(start + 16, bytes.count)]
                let groups = stride(from: 0, to: row.count, by: 8).map { offset in
                    row.dropFirst(offset).prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
                }
                lines.append(String(format: "%04X  ", start) + groups.joined(separator: "  "))
            }
            return lines.joined(separator: "\n")
        case .hex:
            return bytes.map { String(format: "%02X", $0) }.joined()
        case .base64:
            return Data(bytes).base64EncodedString()
        case .cArray:
            let body = stride(from: 0, to: bytes.count, by: 12).map { start in
                "    " + bytes[start..<min(start + 12, bytes.count)].map { String(format: "0x%02X", $0) }.joined(separator: ", ")
            }.joined(separator: ",\n")
            return "const unsigned char edid[\(bytes.count)] = {\n\(body)\n};"
        }
    }
}
