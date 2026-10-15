import XCTest
@testable import DisplayDomain

/// Fixtures are assembled byte by byte from the EDID 1.4, CTA-861 and DisplayID layouts, so each
/// expected value below is the one deliberately written into the bytes.
final class EDIDDecoderTests: XCTestCase {
    // MARK: Fixtures

    private func withChecksum(_ block: [UInt8]) -> [UInt8] {
        var block = block
        let sum = block[0..<127].reduce(0) { $0 + Int($1) }
        block[127] = UInt8((256 - sum % 256) % 256)
        return block
    }

    /// 3840 × 2160, 533.25 MHz, totals 4000 × 2222 → 59.997 Hz, image 597 × 336 mm.
    private let uhdTiming: [UInt8] = [0x4D, 0xD0, 0x00, 0xA0, 0xF0, 0x70, 0x3E, 0x80,
                                      0x30, 0x20, 0x35, 0x00, 0x55, 0x50, 0x21, 0x00, 0x00, 0x1A]

    private func textDescriptor(_ tag: UInt8, _ text: String) -> [UInt8] {
        var d: [UInt8] = [0, 0, 0, tag, 0] + Array(text.utf8.prefix(13))
        if d.count < 18 { d.append(0x0A) }
        while d.count < 18 { d.append(0x20) }
        return d
    }

    private func base(extensions: UInt8 = 0, week: UInt8 = 12, year: UInt8 = 33,
                      revision: UInt8 = 4) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 128)
        b.replaceSubrange(0..<8, with: [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
        b[8] = 0x10; b[9] = 0xAC                          // "DEL"
        b[10] = 0x34; b[11] = 0x12                        // product 0x1234
        b[12] = 0x78; b[13] = 0x56; b[14] = 0x34; b[15] = 0x12
        b[16] = week; b[17] = year; b[18] = 1; b[19] = revision
        b[20] = 0xB5                                      // digital, 10 bits, DisplayPort
        b[21] = 60; b[22] = 34; b[23] = 120               // 60 × 34 cm, gamma 2.2
        b[24] = 0x2E                                      // active-off, RGB+4:4:4, sRGB, native, no CF
        b[35] = 0x21                                      // 640×480@60, 800×600@60
        b[36] = 0x08                                      // 1024×768@60
        b[38] = 0xD1; b[39] = 0xC0                        // 1920×1080 @ 60 (16:9)
        b[40] = 0x81; b[41] = 0x00                        // 1280×800 @ 60 (16:10)
        for index in stride(from: 42, to: 54, by: 2) { b[index] = 0x01; b[index + 1] = 0x01 }
        b.replaceSubrange(54..<72, with: uhdTiming)
        b.replaceSubrange(72..<90, with: [0, 0, 0, 0xFD, 0, 48, 144, 30, 222, 60, 0x01, 0x0A,
                                          0x20, 0x20, 0x20, 0x20, 0x20, 0x20])
        b.replaceSubrange(90..<108, with: textDescriptor(0xFC, "Test Panel"))
        b.replaceSubrange(108..<126, with: textDescriptor(0xFF, "ABC123"))
        b[126] = extensions
        return withChecksum(b)
    }

    private func cta(dataBlocks: [[UInt8]], dtds: [[UInt8]] = [], flags: UInt8 = 0xF1) -> [UInt8] {
        var b: [UInt8] = [0x02, 0x03, 0, flags]
        for block in dataBlocks { b += block }
        b[2] = UInt8(b.count)
        for dtd in dtds { b += dtd }
        b += [UInt8](repeating: 0, count: 128 - b.count)
        return withChecksum(b)
    }

    private func displayID(version: UInt8, productType: UInt8 = 0, blocks: [[UInt8]],
                           corruptSection: Bool = false) -> [UInt8] {
        let payload = blocks.flatMap { $0 }
        var section: [UInt8] = [version, UInt8(payload.count), productType, 0] + payload
        let sum = section.reduce(0) { $0 + Int($1) }
        section.append(UInt8((256 - sum % 256) % 256) &+ (corruptSection ? 1 : 0))
        var b: [UInt8] = [0x70] + section
        b += [UInt8](repeating: 0, count: 128 - b.count)
        return withChecksum(b)
    }

    /// DisplayID Type I / VII descriptor, values stored minus one.
    private func displayIDTiming(clock: Int, preferred: Bool, h: (Int, Int, Int, Int), v: (Int, Int, Int, Int)) -> [UInt8] {
        func le16(_ value: Int) -> [UInt8] { [UInt8((value - 1) & 0xFF), UInt8(((value - 1) >> 8) & 0xFF)] }
        let c = clock - 1
        return [UInt8(c & 0xFF), UInt8((c >> 8) & 0xFF), UInt8((c >> 16) & 0xFF), preferred ? 0x80 : 0x00]
            + le16(h.0) + le16(h.1) + le16(h.2) + le16(h.3) + le16(v.0) + le16(v.1) + le16(v.2) + le16(v.3)
    }

    // MARK: Base block

    func testDecodesEveryBaseBlockField() throws {
        let decoded = EDIDDecoder.decode(base())
        XCTAssertTrue(decoded.isStructurallyValid, "\(decoded.issues)")
        let b = try XCTUnwrap(decoded.base)
        XCTAssertEqual(b.manufacturerID, "DEL")
        XCTAssertEqual(b.manufacturerCode, 0x10AC)
        XCTAssertEqual(b.productCode, 0x1234)
        XCTAssertEqual(b.serialNumber, 0x1234_5678)
        XCTAssertEqual(b.manufacture, .week(12, year: 2023))
        XCTAssertEqual(b.version, 1); XCTAssertEqual(b.revision, 4)
        XCTAssertEqual(b.videoInput, .digital(bitsPerColor: 10, interface: .displayPort))
        XCTAssertEqual(b.screenSize, .centimeters(width: 60, height: 34))
        XCTAssertEqual(b.gamma ?? 0, 2.2, accuracy: 0.0001)
        XCTAssertTrue(b.features.activeOff); XCTAssertFalse(b.features.standby)
        XCTAssertTrue(b.features.sRGBDefault); XCTAssertTrue(b.features.preferredTimingIsNative)
        XCTAssertEqual(b.features.colorType, 1)
        XCTAssertEqual(b.monitorName, "Test Panel")
        XCTAssertEqual(b.serialText, "ABC123")
        XCTAssertEqual(b.rangeLimits, .init(minVerticalHz: 48, maxVerticalHz: 144, minHorizontalKHz: 30,
                                           maxHorizontalKHz: 222, maxPixelClockMHz: 600))
        XCTAssertEqual(b.establishedTimings.map { "\($0.width)x\($0.height)@\(Int($0.refreshHz))" },
                       ["640x480@60", "800x600@60", "1024x768@60"])
        XCTAssertEqual(b.standardTimings.map { "\($0.width)x\($0.height)@\(Int($0.refreshHz))" },
                       ["1920x1080@60", "1280x800@60"])
    }

    func testDecodesThePreferredDetailedTimingCompletely() throws {
        let timing = try XCTUnwrap(EDIDDecoder.decode(base()).base?.detailedTimings.first)
        XCTAssertTrue(timing.preferred)
        XCTAssertEqual(timing.pixelClockKHz, 533_250)
        XCTAssertEqual(timing.horizontalActive, 3840); XCTAssertEqual(timing.horizontalBlanking, 160)
        XCTAssertEqual(timing.horizontalFrontPorch, 48); XCTAssertEqual(timing.horizontalSyncWidth, 32)
        XCTAssertEqual(timing.verticalActive, 2160); XCTAssertEqual(timing.verticalBlanking, 62)
        XCTAssertEqual(timing.verticalFrontPorch, 3); XCTAssertEqual(timing.verticalSyncWidth, 5)
        XCTAssertEqual(timing.imageWidthMM, 597); XCTAssertEqual(timing.imageHeightMM, 336)
        XCTAssertFalse(timing.interlaced)
        XCTAssertEqual(timing.refreshHz ?? 0, 59.997, accuracy: 0.001)
    }

    func testAModelYearIsNotAManufactureDate() {
        XCTAssertEqual(EDIDDecoder.decode(base(week: 0xFF, year: 34)).base?.manufacture, .modelYear(2024))
        XCTAssertEqual(EDIDDecoder.decode(base(week: 0, year: 34)).base?.manufacture, .year(2024))
        XCTAssertEqual(EDIDDecoder.decode(base(week: 0, year: 0)).base?.manufacture, .unspecified)
    }

    func testOlderVersionsLeaveDepthAndInterfaceUndefined() {
        let decoded = EDIDDecoder.decode(base(revision: 3))
        XCTAssertEqual(decoded.base?.videoInput, .digital(bitsPerColor: nil, interface: nil))
    }

    func testAgreesWithTheIdentityParser() throws {
        let bytes = base()
        let identity = try XCTUnwrap(EDID.parse(bytes))
        let decoded = try XCTUnwrap(EDIDDecoder.decode(bytes).base)
        XCTAssertEqual(identity.manufacturerID, decoded.manufacturerID)
        XCTAssertEqual(identity.productCode, decoded.productCode)
        XCTAssertEqual(identity.serialNumber, decoded.serialNumber)
        XCTAssertEqual(identity.monitorName, decoded.monitorName)
    }

    // MARK: CTA-861

    private var richCTA: [UInt8] {
        cta(dataBlocks: [
            [0x44, 0x90, 0x61, 0x04, 0x84],                                   // video: VIC 16 native, 97, 4, 4 native
            [0x23, 0x09, 0x07, 0x07],                                         // audio: LPCM 2ch 32/44.1/48 kHz
            [0x67, 0x03, 0x0C, 0x00, 0x10, 0x00, 0x38, 0x3C],                 // HDMI 1.0.0.0, DC 30/36, 300 MHz
            [0x67, 0xD8, 0x5D, 0xC4, 0x01, 0x78, 0x00, 0x30],                 // HF-VSDB v1, 600 MHz, FRL code 3
            [0x63, 0x1A, 0x00, 0x00],                                         // AMD vendor block
            [0xE3, 0x05, 0xE0, 0x00],                                         // colorimetry BT2020 ×3
            [0xE6, 0x06, 0x0D, 0x01, 0x70, 0x60, 0x10],                       // HDR static metadata
            [0xE2, 0x00, 0xC0],                                               // video capability QY+QS
            [0xE2, 0x0E, 0x61],                                               // 4:2:0-only VIC 97
            [0xE2, 0x0F, 0x01],                                               // 4:2:0 capability map (listed)
        ], dtds: [uhdTiming])
    }

    func testDecodesCTADataBlocks() throws {
        let decoded = EDIDDecoder.decode(base(extensions: 1) + richCTA)
        XCTAssertTrue(decoded.isStructurallyValid, "\(decoded.issues)")
        guard case .cta(let c) = try XCTUnwrap(decoded.extensions.first).content else { return XCTFail("not CTA") }
        XCTAssertEqual(c.revision, 3)
        XCTAssertEqual(c.underscan, true); XCTAssertEqual(c.basicAudio, true)
        XCTAssertEqual(c.ycbcr444, true); XCTAssertEqual(c.ycbcr422, true)
        XCTAssertEqual(c.nativeDetailedTimingCount, 1)
        XCTAssertEqual(c.videoFormats.map(\.vic), [16, 97, 4, 4])
        XCTAssertEqual(c.videoFormats.map(\.native), [true, false, false, true])
        XCTAssertEqual(c.videoFormats[1].format, CTAVideoFormats.Format(width: 3840, height: 2160, refreshHz: 60,
                                                                        interlaced: false, aspect: "16:9"))
        XCTAssertEqual(c.audioFormats, [.init(formatCode: 1, channels: 2, sampleRates: [32_000, 44_100, 48_000])])
        XCTAssertEqual(c.hdmi?.physicalAddress, "1.0.0.0")
        XCTAssertEqual(c.hdmi?.maxTMDSClockMHz, 300)
        XCTAssertEqual(c.hdmi?.deepColor30, true); XCTAssertEqual(c.hdmi?.deepColor36, true)
        XCTAssertEqual(c.hdmi?.deepColor48, false); XCTAssertEqual(c.hdmi?.deepColorYCbCr444, true)
        XCTAssertEqual(c.hdmiForum?.version, 1)
        XCTAssertEqual(c.hdmiForum?.maxTMDSCharacterRateMHz, 600)
        XCTAssertEqual(c.hdmiForum?.maxFRL?.lanes, 4); XCTAssertEqual(c.hdmiForum?.maxFRL?.gbpsPerLane, 6)
        XCTAssertEqual(c.otherVendorOUIs, [0x00001A])
        XCTAssertEqual(c.colorimetry, [.bt2020cYCC, .bt2020YCC, .bt2020RGB])
        let hdr = try XCTUnwrap(c.hdrStaticMetadata)
        XCTAssertTrue(hdr.traditionalSDR); XCTAssertFalse(hdr.traditionalHDR); XCTAssertTrue(hdr.pq); XCTAssertTrue(hdr.hlg)
        XCTAssertEqual(hdr.maxLuminance ?? 0, 50 * pow(2, 3.5), accuracy: 0.01)
        XCTAssertEqual(hdr.maxFrameAverageLuminance ?? 0, 400, accuracy: 0.01)
        XCTAssertEqual(hdr.minLuminance ?? 0, 50 * pow(2, 3.5) * pow(16.0 / 255, 2) / 100, accuracy: 0.0001)
        XCTAssertEqual(c.quantization, .init(rgbSelectable: true, yccSelectable: true))
        XCTAssertEqual(c.ycbcr420OnlyFormats.map(\.vic), [97])
        XCTAssertEqual(c.otherDataBlocks, [.init(tag: 7, extendedTag: 15)])
        XCTAssertEqual(c.detailedTimings.first?.horizontalActive, 3840)
    }

    func testACTADataBlockRunningPastItsAreaIsReportedAndDecodingStops() {
        var block = cta(dataBlocks: [[0x42, 0x10, 0x04]])
        block[4] = 0x5F                                  // video block claiming 31 bytes
        block = withChecksum(block)
        let decoded = EDIDDecoder.decode(base(extensions: 1) + block)
        XCTAssertTrue(decoded.issues.contains(.ctaDataBlockOverrun(block: 1)))
        XCTAssertFalse(decoded.isStructurallyValid)
    }

    func testReservedShortVideoCodesAreSkipped() {
        XCTAssertNil(EDIDDecoder.shortVideo(0)); XCTAssertNil(EDIDDecoder.shortVideo(128))
        XCTAssertNil(EDIDDecoder.shortVideo(254)); XCTAssertNil(EDIDDecoder.shortVideo(255))
        XCTAssertEqual(EDIDDecoder.shortVideo(193), .init(vic: 193, native: false))
        XCTAssertEqual(EDIDDecoder.shortVideo(129), .init(vic: 1, native: true))
    }

    func testMalformedCTADataBlocksAreIssuesNotSilence() {
        let block = cta(dataBlocks: [
            [0x24, 0x09, 0x07, 0x07, 0x01],                  // audio: 4 bytes, not a multiple of 3
            [0x64, 0x03, 0x0C, 0x00, 0x10],                  // HDMI VSDB without its physical address
            [0xE2, 0x06, 0x0D],                              // HDR static metadata, 1 byte of body
        ])
        let decoded = EDIDDecoder.decode(base(extensions: 1) + block)
        XCTAssertEqual(decoded.issues, [.ctaDataBlockMalformed(block: 1, tag: 1, extendedTag: nil),
                                        .ctaDataBlockMalformed(block: 1, tag: 3, extendedTag: nil),
                                        .ctaDataBlockMalformed(block: 1, tag: 7, extendedTag: 6)])
        guard case .cta(let c)? = decoded.extensions.first?.content else { return XCTFail("not CTA") }
        XCTAssertEqual(c.audioFormats.count, 1, "the complete descriptor is still shown")
        XCTAssertNil(c.hdmi)
        XCTAssertNil(c.hdrStaticMetadata)
        let notes = EDIDReportFormatter.sections(decoded).first?.notes ?? []
        XCTAssertTrue(notes.contains("The HDR Static Metadata data block in block 1 (CTA-861) is malformed for its type; only what could be read is shown."))
    }

    func testDCIP3IsReadFromTheSecondColorimetryByte() {
        let decoded = EDIDDecoder.decode(base(extensions: 1) + cta(dataBlocks: [[0xE3, 0x05, 0x01, 0x80]]))
        guard case .cta(let c)? = decoded.extensions.first?.content else { return XCTFail("not CTA") }
        XCTAssertEqual(c.colorimetry, [.xvYCC601, .dciP3])
    }

    func testRevisionTwoCTAHasNoDataBlocks() {
        var block = cta(dataBlocks: [[0x42, 0x10, 0x04]])
        block[1] = 2
        let decoded = EDIDDecoder.decode(base(extensions: 1) + withChecksum(block))
        guard case .cta(let c)? = decoded.extensions.first?.content else { return XCTFail("not CTA") }
        XCTAssertTrue(c.videoFormats.isEmpty, "bytes before the timings are reserved before revision 3")
        XCTAssertTrue(decoded.isStructurallyValid)
    }

    func testInterlacedDetailedTimingsShowTheFrameAndFieldRate() throws {
        // 1920 × 1080i: 74.25 MHz, 2200 total pixels, 540 + 22 lines per field.
        let interlaced: [UInt8] = [0x01, 0x1D, 0x80, 0x18, 0x71, 0x1C, 0x16, 0x20,
                                   0x58, 0x2C, 0x25, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x9E]
        let block = cta(dataBlocks: [], dtds: [interlaced])
        let decoded = EDIDDecoder.decode(base(extensions: 1) + block)
        guard case .cta(let c)? = decoded.extensions.first?.content else { return XCTFail("not CTA") }
        let timing = try XCTUnwrap(c.detailedTimings.first)
        XCTAssertTrue(timing.interlaced)
        XCTAssertEqual(timing.verticalActive, 540)
        XCTAssertEqual(timing.frameHeight, 1080)
        XCTAssertEqual(timing.refreshHz ?? 0, 60, accuracy: 0.0001)
        XCTAssertTrue(EDIDReportFormatter.timingText(timing).hasPrefix("1920 × 1080i @ 60 Hz"))
    }

    // MARK: DisplayID

    func testDecodesDisplayID13TimingsAndTiles() throws {
        let timing = displayIDTiming(clock: 26_400, preferred: true, h: (2560, 160, 48, 32), v: (2880, 60, 3, 5))
        // Tile block: 2 × 1 tiles, this one at column 2 (index 1), 2560 × 2880 per tile, one enclosure.
        let tile: [UInt8] = [0x12, 0x00, 22, 0x80, 0x10, 0x10, 0x00, 0xFF, 0x09, 0x3F, 0x0B,
                             0x00, 0, 0, 0, 0, 0x44, 0x45, 0x4C, 0x34, 0x12, 0x01, 0x00, 0x00, 0x00]
        let product: [UInt8] = [0x00, 0x00, 15, 0x44, 0x45, 0x4C, 0x34, 0x12, 0x01, 0, 0, 0, 10, 23, 3, 0x41, 0x42, 0x43]
        let ext = displayID(version: 0x13, productType: 3,
                            blocks: [product, [0x03, 0x00, 20] + timing, tile])
        let decoded = EDIDDecoder.decode(base(extensions: 1) + ext)
        XCTAssertTrue(decoded.isStructurallyValid, "\(decoded.issues)")
        guard case .displayID(let id) = try XCTUnwrap(decoded.extensions.first).content else { return XCTFail("not DisplayID") }
        XCTAssertEqual(id.version, 1); XCTAssertEqual(id.revision, 3); XCTAssertEqual(id.productType, 3)
        XCTAssertTrue(id.sectionChecksumValid)
        XCTAssertEqual(id.product?.vendor, "DEL")
        XCTAssertEqual(id.product?.productCode, 0x1234)
        XCTAssertEqual(id.product?.serialNumber, 1)
        XCTAssertEqual(id.product?.manufacture, .week(10, year: 2023))
        XCTAssertEqual(id.product?.name, "ABC")
        let t = try XCTUnwrap(id.timings.first)
        XCTAssertTrue(t.preferred)
        XCTAssertEqual(t.pixelClockKHz, 264_000)
        XCTAssertEqual(t.horizontalActive, 2560); XCTAssertEqual(t.verticalActive, 2880)
        XCTAssertEqual(t.horizontalBlanking, 160); XCTAssertEqual(t.verticalBlanking, 60)
        XCTAssertEqual(t.refreshHz ?? 0, 264_000_000 / Double(2720 * 2940), accuracy: 0.001)
        let tiled = try XCTUnwrap(id.tiles.first)
        XCTAssertEqual(tiled.horizontalTiles, 2); XCTAssertEqual(tiled.verticalTiles, 1)
        XCTAssertEqual(tiled.column, 1); XCTAssertEqual(tiled.row, 0)
        XCTAssertEqual(tiled.tileWidth, 2560); XCTAssertEqual(tiled.tileHeight, 2880)
        XCTAssertTrue(tiled.singleEnclosure)
        XCTAssertEqual(tiled.vendor, "DEL"); XCTAssertEqual(tiled.productCode, 0x1234); XCTAssertEqual(tiled.serialNumber, 1)
        // The topology ID carries a serial number, so it is its own, identifying row.
        let rows = EDIDReportFormatter.sections(decoded).flatMap(\.rows)
        let topology = try XCTUnwrap(rows.first { $0.label == "Tile topology ID" })
        XCTAssertEqual(topology.value, "vendor DEL, product 4660, serial 1")
        XCTAssertTrue(topology.identifying)
        XCTAssertFalse(rows.first { $0.label == "Tiled display" }?.value.contains("serial") ?? true)
    }

    func testDecodesDisplayID20TypeVIIAndParameters() throws {
        let timing = displayIDTiming(clock: 594_000, preferred: true, h: (3840, 560, 176, 88), v: (2160, 90, 8, 10))
        // Display parameters in 0.1 mm: 6970 × 3920 → 697.0 × 392.0 mm; native 3840 × 2160.
        let parameters: [UInt8] = [0x21, 0x00, 29, 0x3A, 0x1B, 0x50, 0x0F, 0x00, 0x0F, 0x70, 0x08]
            + [UInt8](repeating: 0, count: 21)
        let product: [UInt8] = [0x20, 0x00, 12, 0x00, 0x1A, 0x2B, 0x01, 0x00, 0, 0, 0, 0, 0xFF, 24, 0]
        let ext = displayID(version: 0x20, productType: 4, blocks: [product, parameters, [0x22, 0x00, 20] + timing, [0x26, 0x00, 0]])
        let decoded = EDIDDecoder.decode(base(extensions: 1) + ext)
        XCTAssertTrue(decoded.isStructurallyValid, "\(decoded.issues)")
        guard case .displayID(let id) = try XCTUnwrap(decoded.extensions.first).content else { return XCTFail("not DisplayID") }
        XCTAssertEqual(id.version, 2); XCTAssertEqual(id.revision, 0)
        XCTAssertEqual(id.product?.vendor, "00-1A-2B")
        XCTAssertEqual(id.product?.manufacture, .modelYear(2024))
        XCTAssertEqual(id.parameters?.imageWidthMM ?? 0, 697.0, accuracy: 0.01)
        XCTAssertEqual(id.parameters?.imageHeightMM ?? 0, 392.0, accuracy: 0.01)
        XCTAssertEqual(id.parameters?.nativeWidth, 3840); XCTAssertEqual(id.parameters?.nativeHeight, 2160)
        // Type VII counts the pixel clock in kHz, not 10 kHz.
        XCTAssertEqual(id.timings.first?.pixelClockKHz, 594_000)
        XCTAssertEqual(id.timings.first?.refreshHz ?? 0, 60, accuracy: 0.001)
        XCTAssertEqual(id.otherBlockTags, [0x26])
    }

    func testDisplayID21TypeVIIDescriptorsCanBeLonger() throws {
        // Revision bits 6–4 = 1: each descriptor carries one byte more than 20.
        let first = displayIDTiming(clock: 594_000, preferred: true, h: (3840, 560, 176, 88), v: (2160, 90, 8, 10)) + [0]
        let second = displayIDTiming(clock: 297_000, preferred: false, h: (3840, 560, 176, 88), v: (2160, 90, 8, 10)) + [0]
        let ext = displayID(version: 0x21, blocks: [[0x22, 0x10, 42] + first + second])
        let decoded = EDIDDecoder.decode(base(extensions: 1) + ext)
        XCTAssertTrue(decoded.isStructurallyValid, "\(decoded.issues)")
        guard case .displayID(let id)? = decoded.extensions.first?.content else { return XCTFail("not DisplayID") }
        XCTAssertEqual(id.timings.map(\.pixelClockKHz), [594_000, 297_000])
        XCTAssertEqual(id.timings.map(\.preferred), [true, false])
    }

    func testShortDisplayIDBlocksAreReportedAsMalformed() {
        let tile: [UInt8] = [0x12, 0x00, 8, 0x80, 0x10, 0x10, 0x00, 0xFF, 0x09, 0x3F, 0x0B]
        let timing: [UInt8] = [0x03, 0x00, 10] + [UInt8](repeating: 0, count: 10)
        let ext = displayID(version: 0x13, blocks: [tile, timing])
        let decoded = EDIDDecoder.decode(base(extensions: 1) + ext)
        XCTAssertEqual(decoded.issues, [.displayIDDataBlockMalformed(block: 1, tag: 0x12),
                                        .displayIDDataBlockMalformed(block: 1, tag: 0x03)])
        guard case .displayID(let id)? = decoded.extensions.first?.content else { return XCTFail("not DisplayID") }
        XCTAssertEqual(id.tiles.first?.horizontalTiles, 2, "the layout part is still decoded")
        XCTAssertNil(id.tiles.first?.vendor)
        XCTAssertTrue(id.timings.isEmpty)
    }

    func testDisplayIDParameterPrefixesAreInspectableAndMarkedIncomplete() {
        for (version, tag, length) in [(UInt8(0x13), UInt8(0x01), 12), (0x20, 0x21, 29)] {
            let prefix: [UInt8] = [tag, 0, 8, 0x3A, 0x1B, 0x50, 0x0F, 0x00, 0x0F, 0x70, 0x08]
            let decoded = EDIDDecoder.decode(base(extensions: 1) + displayID(version: version, blocks: [prefix]))
            XCTAssertTrue(decoded.issues.contains(.displayIDDataBlockMalformed(block: 1, tag: Int(tag))), "expected \(length) bytes")
            guard case .displayID(let id)? = decoded.extensions.first?.content else { return XCTFail("not DisplayID") }
            XCTAssertEqual(id.parameters?.nativeWidth, 3840)
        }
    }

    func testDisplayIDNegativeZeroLuminanceMeansDoNotUse() {
        var payload = [UInt8](repeating: 0, count: 29)
        for offset in [21, 23, 25] { payload[offset + 1] = 0x80 }
        let decoded = EDIDDecoder.decode(base(extensions: 1) + displayID(version: 0x20, blocks: [[0x21, 0, 29] + payload]))
        guard case .displayID(let id)? = decoded.extensions.first?.content else { return XCTFail("not DisplayID") }
        XCTAssertNil(id.parameters?.maxLuminanceFullCoverage)
        XCTAssertNil(id.parameters?.maxLuminanceTenPercent)
        XCTAssertNil(id.parameters?.minLuminance)
    }

    func testDisplayIDTileHighBitsAndInvalidLocation() {
        // 18 columns, 35 rows; tile column 17, row 34. Topology byte packs counts and locations.
        let payload: [UInt8] = [0x80, 0x12, 0x12, 0x66, 0xFF, 0x09, 0x3F, 0x0B]
            + [UInt8](repeating: 0, count: 14)
        let decoded = EDIDDecoder.decode(base(extensions: 1) + displayID(version: 0x20, blocks: [[0x28, 0, 22] + payload]))
        guard case .displayID(let id)? = decoded.extensions.first?.content else { return XCTFail("not DisplayID") }
        XCTAssertEqual(id.tiles.first?.horizontalTiles, 18)
        XCTAssertEqual(id.tiles.first?.verticalTiles, 35)
        XCTAssertEqual(id.tiles.first?.column, 17)
        XCTAssertEqual(id.tiles.first?.row, 34)
        var invalid = payload
        invalid[2] = 0xF2
        let bad = EDIDDecoder.decode(base(extensions: 1) + displayID(version: 0x20, blocks: [[0x28, 0, 22] + invalid]))
        XCTAssertTrue(bad.issues.contains(.displayIDDataBlockMalformed(block: 1, tag: 0x28)))
    }

    func testABadDisplayIDSectionChecksumIsReportedWhileTheBlockStillDecodes() {
        let timing = displayIDTiming(clock: 26_400, preferred: true, h: (2560, 160, 48, 32), v: (2880, 60, 3, 5))
        let ext = displayID(version: 0x13, blocks: [[0x03, 0x00, 20] + timing], corruptSection: true)
        let decoded = EDIDDecoder.decode(base(extensions: 1) + ext)
        XCTAssertTrue(decoded.issues.contains(.displayIDChecksumInvalid(block: 1)))
        guard case .displayID(let id)? = decoded.extensions.first?.content else { return XCTFail("not DisplayID") }
        XCTAssertFalse(id.sectionChecksumValid)
        XCTAssertEqual(id.timings.count, 1)
    }

    func testADisplayIDDataBlockPastTheSectionIsReported() {
        var ext = displayID(version: 0x13, blocks: [[0x03, 0x00, 20] + [UInt8](repeating: 0, count: 20)])
        ext[7] = 40                                     // the timing block now claims 40 payload bytes
        ext = withChecksum(ext)
        let decoded = EDIDDecoder.decode(base(extensions: 1) + ext)
        XCTAssertTrue(decoded.issues.contains(.displayIDDataBlockOverrun(block: 1, tag: 0x03)))
    }

    // MARK: Structure

    func testMissingExtensionBlocksAreReportedAndThePresentOnesStillDecode() {
        let decoded = EDIDDecoder.decode(base(extensions: 2) + richCTA)
        XCTAssertEqual(decoded.issues, [.missingExtensions(declared: 2, present: 1)])
        XCTAssertNotNil(decoded.base)
        XCTAssertEqual(decoded.extensions.count, 1)
        XCTAssertFalse(decoded.isStructurallyValid)
    }

    func testUndeclaredBlocksAndPartialTailAreReported() {
        let decoded = EDIDDecoder.decode(base(extensions: 0) + richCTA + [0x01, 0x02, 0x03])
        XCTAssertTrue(decoded.issues.contains(.undeclaredBlocks(declared: 0, present: 1)))
        XCTAssertTrue(decoded.issues.contains(.partialTrailingBlock(bytes: 3)))
        XCTAssertEqual(decoded.extensions.count, 1, "an undeclared block is still decoded, not discarded")
    }

    func testChecksumProblemsAreReportedPerBlock() {
        var ext = richCTA
        ext[127] &+= 1
        var head = base(extensions: 1)
        head[127] &+= 1
        let decoded = EDIDDecoder.decode(head + ext)
        XCTAssertTrue(decoded.issues.contains(.baseChecksumInvalid))
        XCTAssertTrue(decoded.issues.contains(.extensionChecksumInvalid(block: 1)))
        XCTAssertEqual(decoded.base?.checksumValid, false)
        XCTAssertEqual(decoded.extensions.first?.checksumValid, false)
        XCTAssertEqual(decoded.base?.productCode, 0x1234, "invalid bytes stay inspectable")
    }

    func testUnreadableInputIsReportedNotDecoded() {
        XCTAssertEqual(EDIDDecoder.decode([0x00, 0xFF]).issues, [.tooShort(byteCount: 2)])
        XCTAssertNil(EDIDDecoder.decode([UInt8](repeating: 0, count: 128)).base)
        XCTAssertEqual(EDIDDecoder.decode([UInt8](repeating: 0, count: 128)).issues, [.invalidHeader])
    }

    func testUnknownExtensionsAreKeptUndecoded() {
        var block = [UInt8](repeating: 0, count: 128)
        block[0] = 0xF0
        let decoded = EDIDDecoder.decode(base(extensions: 1) + withChecksum(block))
        XCTAssertEqual(decoded.extensions.first?.content, .undecoded)
        XCTAssertEqual(decoded.extensions.first?.tag, 0xF0)
        XCTAssertTrue(decoded.isStructurallyValid)
    }

    /// Arbitrary bytes behind a valid header — random lengths, extension tags and data-block
    /// headers — must decode and format without trapping: registry and file input is untrusted.
    func testArbitraryBytesNeverTrap() {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt8 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 33)
        }
        for round in 0..<500 {
            var bytes = (0..<(128 + Int(next()) * 3)).map { _ in next() }
            bytes.replaceSubrange(0..<8, with: [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
            for block in stride(from: 128, to: bytes.count - 127, by: 128) {
                bytes[block] = [0x02, 0x70, 0xF0, next()][round % 4]
            }
            let decoded = EDIDDecoder.decode(bytes)
            XCTAssertNotNil(decoded.base)
            _ = InfoReport(title: "", sections: EDIDReportFormatter.sections(decoded)).plainText()
        }
    }

    // MARK: Formatting

    func testFormattedSectionsCoverBaseAndEveryExtension() {
        let timing = displayIDTiming(clock: 26_400, preferred: true, h: (2560, 160, 48, 32), v: (2880, 60, 3, 5))
        let bytes = base(extensions: 2) + richCTA + displayID(version: 0x13, blocks: [[0x03, 0x00, 20] + timing])
        let sections = EDIDReportFormatter.sections(EDIDDecoder.decode(bytes))
        XCTAssertEqual(sections.map(\.title), ["Structure", "Identification", "Display parameters", "Detailed timings",
                                               "Block 1: CTA-861, revision 3", "Block 2: DisplayID 1.3"])
        let text = InfoReport(title: "EDID", sections: sections).plainText()
        XCTAssertTrue(text.contains("Manufacturer: DEL (0x10AC)"))
        XCTAssertTrue(text.contains("Manufactured: Week 12 of 2023"))
        XCTAssertTrue(text.contains("Video input: Digital, 10 bits per colour, DisplayPort"))
        XCTAssertTrue(text.contains("3840 × 2160 @ 59.997 Hz, pixel clock 533.25 MHz, image 597 × 336 mm"))
        XCTAssertTrue(text.contains("VIC 16: 1920 × 1080 @ 59.94/60 Hz (16:9) — native"))
        XCTAssertTrue(text.contains("Colorimetry: BT2020cYCC, BT2020YCC, BT2020RGB"))
        XCTAssertTrue(text.contains("Maximum FRL: 4 lanes × 6 Gbit/s"))
        XCTAssertTrue(text.contains("Transfer functions: SDR gamma, SMPTE ST 2084 (PQ), HLG"))
        XCTAssertTrue(text.contains("Preferred: 2560 × 2880 @ 33.013 Hz"))
        XCTAssertTrue(text.contains("Structure check: No problems found"))
    }

    func testIssuesBecomeNotesOfTheStructureSection() {
        let sections = EDIDReportFormatter.sections(EDIDDecoder.decode(base(extensions: 3)))
        let structure = sections.first
        XCTAssertEqual(structure?.rows.last, .init("Structure check", "Problems found: 1"))
        XCTAssertEqual(structure?.notes, ["Extension blocks declared by the base block: 3, present: 0. The EDID is incomplete."])
    }

    func testEveryLabelGoesThroughTheLocalizer() {
        let marked = ReportLocalizer(text: { "‹\($0)›" }, decimal: ReportLocalizer.posixDecimal)
        let sections = EDIDReportFormatter.sections(EDIDDecoder.decode(base(extensions: 1) + richCTA), marked)
        let untranslated = sections.flatMap(\.rows).map(\.label).filter { !$0.hasPrefix("‹") }
        // Brand names stay as they are in every language.
        XCTAssertEqual(Set(untranslated), ["HDMI", "HDMI Forum"])
        XCTAssertTrue(sections.allSatisfy { $0.title.hasPrefix("‹") })
    }

    // MARK: Byte formats

    func testByteFormatsAreExactAndRoundTrip() {
        let bytes = base(extensions: 1) + richCTA
        let hex = EDIDByteFormat.hex.render(bytes)
        XCTAssertEqual(hex.count, bytes.count * 2)
        let parsed = stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
        XCTAssertEqual(parsed, bytes)
        XCTAssertEqual(Data(base64Encoded: EDIDByteFormat.base64.render(bytes)).map(Array.init), bytes)

        let dump = EDIDByteFormat.hexDump.render(bytes).split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(dump.first, "0000  00 FF FF FF FF FF FF 00  10 AC 34 12 78 56 34 12")
        XCTAssertEqual(dump.count, 16 + 1, "16 lines of 16 bytes and one blank line between the two blocks")
        XCTAssertEqual(dump[8], "")
        XCTAssertTrue(dump[9].hasPrefix("0080  02 03"))

        let array = EDIDByteFormat.cArray.render(bytes)
        XCTAssertTrue(array.hasPrefix("const unsigned char edid[256] = {\n    0x00, 0xFF"))
        XCTAssertTrue(array.hasSuffix("\n};"))
        XCTAssertEqual(array.components(separatedBy: "0x").count - 1, 256)
    }

    func testPastedBase64RoundTripsExactlyAndRefusesAnythingElse() throws {
        let bytes = base(extensions: 1) + richCTA
        let rendered = EDIDByteFormat.base64.render(bytes)
        XCTAssertEqual(try EDIDByteFormat.decodeBase64(rendered), bytes)
        // Line breaks and spaces anywhere, as a mail client or editor may add them, are ignored.
        let wrapped = stride(from: 0, to: rendered.count, by: 60).map { offset -> String in
            let start = rendered.index(rendered.startIndex, offsetBy: offset)
            return String(rendered[start..<rendered.index(start, offsetBy: min(60, rendered.count - offset))])
        }.joined(separator: "\r\n  ")
        XCTAssertEqual(try EDIDByteFormat.decodeBase64("  " + wrapped + "\n"), bytes)
        XCTAssertThrowsError(try EDIDByteFormat.decodeBase64(" \n\t")) { XCTAssertEqual($0 as? EDIDByteFormat.Base64Error, .empty) }
        XCTAssertThrowsError(try EDIDByteFormat.decodeBase64("AAA*")) { XCTAssertEqual($0 as? EDIDByteFormat.Base64Error, .invalid) }
        XCTAssertThrowsError(try EDIDByteFormat.decodeBase64("AA")) { XCTAssertEqual($0 as? EDIDByteFormat.Base64Error, .invalid) }
        // "AB==" decodes to the byte 0x00 with stray bits; the canonical form of that byte is "AA==".
        XCTAssertThrowsError(try EDIDByteFormat.decodeBase64("AB==")) { XCTAssertEqual($0 as? EDIDByteFormat.Base64Error, .nonCanonical) }
        XCTAssertEqual(try EDIDByteFormat.decodeBase64("AA=="), [0x00])
    }

    // MARK: DisplayID luminance

    func testHalfPrecisionValuesDecode() {
        XCTAssertEqual(EDIDDecoder.halfFloat(0x3C00), 1)
        XCTAssertEqual(EDIDDecoder.halfFloat(0x3800), 0.5)
        XCTAssertEqual(EDIDDecoder.halfFloat(0x63D0), 1000)
        XCTAssertEqual(EDIDDecoder.halfFloat(0x5E40), 400)
        XCTAssertEqual(EDIDDecoder.halfFloat(0x0001), pow(2, -24), "smallest subnormal")
        XCTAssertEqual(EDIDDecoder.halfFloat(0xC000), -2)
        XCTAssertEqual(EDIDDecoder.halfFloat(0x7C00), .infinity)
        XCTAssertTrue(EDIDDecoder.halfFloat(0x7E00).isNaN)
    }

    /// DisplayID 2.0 Display Parameters with the luminance fields: 400 cd/m² full screen, 1000 cd/m²
    /// in a 10% window, 0.5 cd/m² minimum.
    private let luminanceParameters: [UInt8] = [0x21, 0x00, 29,
                                                0x3A, 0x1B, 0x50, 0x0F, 0x00, 0x0F, 0x70, 0x08, 0x00]
        + [UInt8](repeating: 0, count: 12) + [0x40, 0x5E, 0xD0, 0x63, 0x00, 0x38, 0x00, 0x00]

    func testDisplayID20ParametersCarryNativeLuminance() throws {
        let decoded = EDIDDecoder.decode(base(extensions: 1) + displayID(version: 0x20, blocks: [luminanceParameters]))
        XCTAssertTrue(decoded.isStructurallyValid, "\(decoded.issues)")
        guard case .displayID(let id)? = decoded.extensions.first?.content else { return XCTFail("not DisplayID") }
        let parameters = try XCTUnwrap(id.parameters)
        XCTAssertEqual(parameters.maxLuminanceFullCoverage, 400)
        XCTAssertEqual(parameters.maxLuminanceTenPercent, 1000)
        XCTAssertEqual(parameters.minLuminance, 0.5)
        XCTAssertEqual(parameters.nativeWidth, 3840)
        let rows = EDIDReportFormatter.sections(decoded).flatMap(\.rows)
        XCTAssertTrue(rows.contains(.init("Native maximum luminance, full screen", "400 cd/m²")))
        XCTAssertTrue(rows.contains(.init("Native maximum luminance, 10% window", "1000 cd/m²")))
        XCTAssertTrue(rows.contains(.init("Native minimum luminance", "0.5 cd/m²")))
    }

    func testShortParametersAndDisplayID13StateNoLuminance() throws {
        let short: [UInt8] = [0x21, 0x00, 8, 0x3A, 0x1B, 0x50, 0x0F, 0x00, 0x0F, 0x70, 0x08]
        let decoded = EDIDDecoder.decode(base(extensions: 1) + displayID(version: 0x20, blocks: [short]))
        guard case .displayID(let id)? = decoded.extensions.first?.content else { return XCTFail("not DisplayID") }
        XCTAssertNil(id.parameters?.maxLuminanceFullCoverage)
        XCTAssertNil(id.parameters?.minLuminance)
        // The DisplayID section names what DisplayID is, apart from macOS's display IDs.
        let section = try XCTUnwrap(EDIDReportFormatter.sections(decoded).first { $0.title.contains("DisplayID") })
        XCTAssertTrue(section.notes.contains { $0.contains("unrelated to the display ID macOS assigns") })
    }
}
