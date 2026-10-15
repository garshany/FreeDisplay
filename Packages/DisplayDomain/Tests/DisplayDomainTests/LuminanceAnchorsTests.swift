import XCTest
@testable import DisplayDomain

final class LuminanceAnchorsTests: XCTestCase {
    // MARK: Fixtures

    private func withChecksum(_ block: [UInt8]) -> [UInt8] {
        var block = block
        let sum = block[0..<127].reduce(0) { $0 + Int($1) }
        block[127] = UInt8((256 - sum % 256) % 256)
        return block
    }

    private func base(extensions: UInt8) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 128)
        b.replaceSubrange(0..<8, with: [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
        b[8] = 0x10; b[9] = 0xAC; b[18] = 1; b[19] = 4
        b[126] = extensions
        return withChecksum(b)
    }

    /// A CTA-861 block holding one HDR Static Metadata block: SDR + PQ, maximum code 128
    /// (50 · 2^4 = 800 cd/m²), frame-average code 96 (400 cd/m²), minimum code 51.
    private func ctaHDR(eotf: UInt8 = 0x05, maxCode: UInt8 = 128, averageCode: UInt8 = 96) -> [UInt8] {
        var b: [UInt8] = [0x02, 0x03, 0, 0x00]
        b += [0xE6, 0x06, eotf, 0x01, maxCode, averageCode, 51]
        b[2] = UInt8(b.count)
        b += [UInt8](repeating: 0, count: 128 - b.count)
        return withChecksum(b)
    }

    /// A DisplayID 2.0 block with Display Parameters stating 400 / 1000 / 0.5 cd/m².
    private func displayIDLuminance() -> [UInt8] {
        let payload: [UInt8] = [0x21, 0x00, 29, 0x3A, 0x1B, 0x50, 0x0F, 0x00, 0x0F, 0x70, 0x08, 0x00]
            + [UInt8](repeating: 0, count: 12) + [0x40, 0x5E, 0xD0, 0x63, 0x00, 0x38, 0x00, 0x00]
        var section: [UInt8] = [0x20, UInt8(payload.count), 0, 0] + payload
        let sum = section.reduce(0) { $0 + Int($1) }
        section.append(UInt8((256 - sum % 256) % 256))
        var b: [UInt8] = [0x70] + section
        b += [UInt8](repeating: 0, count: 128 - b.count)
        return withChecksum(b)
    }

    private func entered(_ values: [LuminanceAnchor: Double], enabled: Bool = true) throws -> LuminanceAnchorSettings {
        var settings = LuminanceAnchorSettings(manualValuesEnabled: enabled)
        for anchor in LuminanceAnchor.allCases {
            guard let value = values[anchor] else { continue }
            settings = try settings.setting(anchor, nits: value).settings
        }
        return settings
    }

    // MARK: Entering values

    func testStartsOnWithNothingEntered() {
        let settings = LuminanceAnchorSettings()
        XCTAssertTrue(settings.manualValuesEnabled)
        XCTAssertTrue(settings.overrides.isEmpty)
        XCTAssertTrue(settings.isDefault)
    }

    func testZeroNegativeAndNonFiniteEntriesAreHandledOneWay() throws {
        let zero = try LuminanceAnchorSettings().setting(.sdrMinimum, nits: 0)
        XCTAssertEqual(zero.storedNits, 0)
        XCTAssertFalse(zero.raisedToZero)
        let negative = try LuminanceAnchorSettings().setting(.sdrMinimum, nits: -5)
        XCTAssertEqual(negative.settings.overrides[.sdrMinimum]?.nits, 0)
        XCTAssertTrue(negative.raisedToZero, "the raise is reported, not silent")
        let start = try entered([.sdrMaximum: 300])
        for bad in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try start.setting(.sdrMaximum, nits: bad)) {
                XCTAssertEqual($0 as? LuminanceAnchorSettings.EntryError, .notFinite)
            }
        }
        XCTAssertEqual(start.overrides[.sdrMaximum]?.nits, 300, "a refused entry changes nothing")
    }

    func testCrossingAnEnteredPartnerMovesItToEquality() throws {
        let settings = try entered([.sdrMinimum: 10, .sdrMaximum: 300])
        let raised = try settings.setting(.sdrMinimum, nits: 350)
        XCTAssertEqual(raised.settings.overrides[.sdrMaximum]?.nits, 350)
        XCTAssertEqual(raised.movedPartners, [.sdrMaximum: 350])
        let lowered = try settings.setting(.sdrMaximum, nits: 4)
        XCTAssertEqual(lowered.settings.overrides[.sdrMinimum]?.nits, 4)
        XCTAssertEqual(lowered.movedPartners, [.sdrMinimum: 4])
        let inside = try settings.setting(.sdrMaximum, nits: 200)
        XCTAssertTrue(inside.movedPartners.isEmpty)
    }

    func testThePeakKeepsBothHDRPartnersBelowIt() throws {
        let settings = try entered([.hdrReferenceWhite: 200, .hdrSustained: 600, .hdrPeak: 1000])
        let edit = try settings.setting(.hdrPeak, nits: 150)
        XCTAssertEqual(edit.movedPartners, [.hdrReferenceWhite: 150, .hdrSustained: 150])
        XCTAssertEqual(edit.settings.overrides[.hdrPeak]?.nits, 150)
    }

    func testAPartnerThatIsntEnteredIsNeverTouched() throws {
        let edit = try LuminanceAnchorSettings().setting(.sdrMinimum, nits: 500)
        XCTAssertNil(edit.settings.overrides[.sdrMaximum])
        XCTAssertTrue(edit.movedPartners.isEmpty)
    }

    func testBasisIsKeptOnReentryAndCanChangeAlone() throws {
        let measured = try LuminanceAnchorSettings().setting(.sdrMaximum, nits: 320, basis: .userMeasurement).settings
        let reentered = try measured.setting(.sdrMaximum, nits: 330).settings
        XCTAssertEqual(reentered.overrides[.sdrMaximum], ManualLuminance(nits: 330, basis: .userMeasurement))
        XCTAssertEqual(reentered.settingBasis(.specification, for: .sdrMaximum).overrides[.sdrMaximum]?.basis, .specification)
        XCTAssertEqual(reentered.settingBasis(.specification, for: .sdrMinimum), reentered, "nothing to relabel")
    }

    // MARK: Disable, clear, round trip

    func testDisablingKeepsValuesAndReenablingRestoresThemUnchanged() throws {
        var settings = try entered([.sdrMinimum: 8, .sdrMaximum: 320])
        settings.manualValuesEnabled = false
        let off = LuminanceAnchorResolver.resolve(settings, reported: ReportedLuminance(), anchor: .sdrMaximum)
        XCTAssertNil(off.resolved, "ignored while off")
        XCTAssertEqual(off.ignoredManual?.nits, 320, "but kept")
        settings.manualValuesEnabled = true
        let on = LuminanceAnchorResolver.resolve(settings, reported: ReportedLuminance(), anchor: .sdrMaximum)
        XCTAssertEqual(on.resolved?.nits, 320)
        XCTAssertEqual(on.resolved?.provenance, .manual(.unspecified))
    }

    func testClearingReturnsToTheReportedValueOrUnknown() throws {
        let reported = ReportedLuminance.from(EDIDDecoder.decode(base(extensions: 1) + ctaHDR()))
        let settings = try entered([.hdrPeak: 1200, .sdrMaximum: 300])
        let manual = LuminanceAnchorResolver.resolve(settings, reported: reported, anchor: .hdrPeak)
        XCTAssertEqual(manual.resolved?.nits, 1200)
        XCTAssertEqual(manual.resolved?.replacedReport?.nits ?? 0, 800, accuracy: 1e-9, "the replaced report stays visible")
        let cleared = settings.clearing(.hdrPeak).clearing(.sdrMaximum)
        XCTAssertEqual(LuminanceAnchorResolver.resolve(cleared, reported: reported, anchor: .hdrPeak).resolved?.provenance,
                       .reported(.ctaHDRStaticMetadata(block: 1)))
        XCTAssertNil(LuminanceAnchorResolver.resolve(cleared, reported: reported, anchor: .sdrMaximum).resolved)
    }

    func testBlankDisabledAndEnteredSettingsRoundTrip() throws {
        var disabled = try entered([.sdrMinimum: 0, .hdrPeak: 900])
        disabled.manualValuesEnabled = false
        let measured = try LuminanceAnchorSettings().setting(.sdrMaximum, nits: 412.5, basis: .userMeasurement).settings
        for settings in [LuminanceAnchorSettings(), disabled, measured] {
            let data = try JSONEncoder().encode(settings)
            XCTAssertEqual(try JSONDecoder().decode(LuminanceAnchorSettings.self, from: data), settings)
        }
    }

    func testDecodingSkipsWhatThisBuildCantRead() throws {
        let json = """
        {"manualValuesEnabled": false,
         "overrides": {"sdrMaximum": {"nits": 300, "basis": "colorimeterCertified"},
                       "hdrFuture": {"nits": 5},
                       "sdrMinimum": {"nits": "lots"}}}
        """
        let settings = try JSONDecoder().decode(LuminanceAnchorSettings.self, from: Data(json.utf8))
        XCTAssertFalse(settings.manualValuesEnabled)
        XCTAssertEqual(settings.overrides, [.sdrMaximum: ManualLuminance(nits: 300, basis: .unspecified)])
    }

    func testAnUnusableStoredValueIsNamedAndNeverUsed() throws {
        let json = #"{"overrides": {"sdrMaximum": {"nits": -3}}}"#
        let settings = try JSONDecoder().decode(LuminanceAnchorSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.unusableAnchor, .sdrMaximum)
        XCTAssertNil(LuminanceAnchorResolver.resolve(settings, reported: ReportedLuminance(), anchor: .sdrMaximum).resolved)
        XCTAssertNil(try entered([.sdrMaximum: 300]).unusableAnchor)
    }

    // MARK: Reported values

    func testEDIDHDRMetadataFillsOnlyHDRAnchorsWithItsSource() throws {
        let reported = ReportedLuminance.from(EDIDDecoder.decode(base(extensions: 1) + ctaHDR()))
        XCTAssertTrue(reported.statesHDRTransfer)
        XCTAssertEqual(try XCTUnwrap(reported.values[.hdrPeak]).nits, 800, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(reported.values[.hdrSustained]).nits, 400, accuracy: 1e-9)
        XCTAssertEqual(reported.values[.hdrPeak]?.source, .ctaHDRStaticMetadata(block: 1))
        XCTAssertNil(reported.values[.sdrMaximum], "no EDID field states SDR desktop luminance")
        XCTAssertNil(reported.values[.sdrMinimum])
        XCTAssertEqual(try XCTUnwrap(reported.minimum).nits, 800 * pow(51.0 / 255, 2) / 100, accuracy: 1e-9)
    }

    func testDisplayIDFillsWhatCTALeavesAndCTAComesFirst() throws {
        let both = ReportedLuminance.from(EDIDDecoder.decode(base(extensions: 2) + ctaHDR(averageCode: 0) + displayIDLuminance()))
        XCTAssertEqual(both.values[.hdrPeak]?.source, .ctaHDRStaticMetadata(block: 1))
        XCTAssertEqual(both.values[.hdrSustained]?.nits, 400)
        XCTAssertEqual(both.values[.hdrSustained]?.source, .displayIDParameters(block: 2), "the CTA block left it unstated")
        let displayIDOnly = ReportedLuminance.from(EDIDDecoder.decode(base(extensions: 1) + displayIDLuminance()))
        XCTAssertEqual(displayIDOnly.values[.hdrPeak]?.nits, 1000)
        XCTAssertEqual(displayIDOnly.minimum?.nits, 0.5)
        XCTAssertFalse(displayIDOnly.statesHDRTransfer)
    }

    func testHDRAnchorsShowOnlyWithSignsOfHDROrStoredValues() throws {
        let none = ReportedLuminance()
        XCTAssertFalse(LuminanceAnchorResolver.showsHDRAnchors(reported: none, potentialEDRHeadroom: 1, settings: nil))
        XCTAssertFalse(LuminanceAnchorResolver.showsHDRAnchors(reported: none, potentialEDRHeadroom: .nan, settings: nil))
        XCTAssertTrue(LuminanceAnchorResolver.showsHDRAnchors(reported: none, potentialEDRHeadroom: 2.5, settings: nil))
        let sdrOnly = ReportedLuminance.from(EDIDDecoder.decode(base(extensions: 1) + ctaHDR(eotf: 0x01, maxCode: 0, averageCode: 0)))
        XCTAssertFalse(LuminanceAnchorResolver.showsHDRAnchors(reported: sdrOnly, potentialEDRHeadroom: nil, settings: nil))
        XCTAssertTrue(LuminanceAnchorResolver.showsHDRAnchors(reported: none, potentialEDRHeadroom: nil,
                                                              settings: try entered([.hdrPeak: 600])),
                      "an entered HDR value stays reachable so it can be cleared")
    }

    // MARK: Estimates

    func testEstimatesAreLinearBetweenTheSDRAnchors() throws {
        let anchors = LuminanceAnchorResolver.resolveAll(try entered([.sdrMinimum: 20, .sdrMaximum: 420]), reported: ReportedLuminance())
        let middle = try LuminanceAnchorResolver.estimateNits(atPosition: 0.5, anchors: anchors).get()
        XCTAssertEqual(middle.nits, 220)
        XCTAssertFalse(middle.positionClamped)
        let beyond = try LuminanceAnchorResolver.estimateNits(atPosition: 1.2, anchors: anchors).get()
        XCTAssertEqual(beyond.nits, 420)
        XCTAssertTrue(beyond.positionClamped, "a position outside the range is held, and says so")
        XCTAssertEqual(try LuminanceAnchorResolver.estimatePosition(forNits: 120, anchors: anchors).get(),
                       .init(position: 0.25, saturation: .none))
        XCTAssertEqual(try LuminanceAnchorResolver.estimatePosition(forNits: 5, anchors: anchors).get(),
                       .init(position: 0, saturation: .belowMinimum))
        XCTAssertEqual(try LuminanceAnchorResolver.estimatePosition(forNits: 900, anchors: anchors).get(),
                       .init(position: 1, saturation: .aboveMaximum))
    }

    func testNoEstimateWithoutBothOrderedAnchors() throws {
        let onlyMax = LuminanceAnchorResolver.resolveAll(try entered([.sdrMaximum: 300]), reported: ReportedLuminance())
        XCTAssertEqual(LuminanceAnchorResolver.estimateNits(atPosition: 0.5, anchors: onlyMax), .failure(.missingAnchors([.sdrMinimum])))
        XCTAssertEqual(LuminanceAnchorResolver.estimateNits(atPosition: .nan, anchors: onlyMax), .failure(.positionNotFinite))
        // Only a hand-edited file can hold an inverted pair: entry keeps pairs ordered.
        let inverted = try JSONDecoder().decode(LuminanceAnchorSettings.self, from: Data(
            #"{"overrides": {"sdrMinimum": {"nits": 500}, "sdrMaximum": {"nits": 100}}}"#.utf8))
        let anchors = LuminanceAnchorResolver.resolveAll(inverted, reported: ReportedLuminance())
        XCTAssertEqual(LuminanceAnchorResolver.estimateNits(atPosition: 0.5, anchors: anchors), .failure(.anchorsOutOfOrder))
        let equal = LuminanceAnchorResolver.resolveAll(try entered([.sdrMinimum: 100, .sdrMaximum: 100]), reported: ReportedLuminance())
        XCTAssertEqual(try LuminanceAnchorResolver.estimatePosition(forNits: 100, anchors: equal).get().position, 0)
    }

    // MARK: Wording

    func testReportLabelsProvenanceAndNeverClaimsMeasurement() throws {
        let reported = ReportedLuminance.from(EDIDDecoder.decode(base(extensions: 1) + ctaHDR()))
        let settings = try LuminanceAnchorSettings().setting(.sdrMinimum, nits: 10, basis: .specification).settings
            .setting(.sdrMaximum, nits: 410).settings
        let section = LuminanceReport.section(settings: settings, reported: reported, includeHDR: true, brightnessPosition: 0.5)
        let rows = Dictionary(uniqueKeysWithValues: section.rows.map { ($0.label, $0.value) })
        XCTAssertEqual(rows["SDR minimum (lowest brightness)"], "10 nits — entered by you, from the display’s specification")
        XCTAssertEqual(rows["SDR maximum (highest brightness)"], "410 nits — entered by you")
        XCTAssertEqual(rows["HDR peak (highlights)"], "800 nits — stated by the EDID (HDR static metadata, block 1)")
        XCTAssertEqual(rows["HDR reference white (SDR content in HDR)"], "Unknown")
        XCTAssertEqual(rows["At the current brightness (50%)"], "about 210 nits (estimated, not measured)")
        XCTAssertTrue(section.notes.first?.hasPrefix("FreeDisplay doesn’t measure light.") ?? false)
        XCTAssertFalse(section.rows.contains { $0.value.lowercased().contains("measured") && !$0.value.contains("not measured")
            && !$0.value.contains("your own measurement") })
    }

    func testSDROnlyReportHidesHDRRowsAndExplainsAMissingEstimate() {
        let section = LuminanceReport.section(settings: nil, reported: ReportedLuminance(), includeHDR: false,
                                              brightnessPosition: nil, estimateNote: "No estimate: reason")
        XCTAssertEqual(section.rows.map(\.label), ["Entered values", "SDR minimum (lowest brightness)",
                                                   "SDR maximum (highest brightness)", "At the current brightness"])
        XCTAssertEqual(section.rows.last?.value, "No estimate: reason")
        var off = LuminanceAnchorSettings(manualValuesEnabled: false)
        off = (try? off.setting(.sdrMaximum, nits: 250).settings) ?? off
        let offSection = LuminanceReport.section(settings: off, reported: ReportedLuminance(), includeHDR: false, brightnessPosition: 0.2)
        let rows = Dictionary(uniqueKeysWithValues: offSection.rows.map { ($0.label, $0.value) })
        XCTAssertEqual(rows["Entered values"], "Off (kept, not used)")
        XCTAssertEqual(rows["SDR maximum (highest brightness)"],
                       "Unknown; your 250 nits is kept but not used while entered values are off")
        XCTAssertEqual(rows["At the current brightness (20%)"],
                       "No estimate: SDR minimum (lowest brightness), SDR maximum (highest brightness) unknown")
    }
}
