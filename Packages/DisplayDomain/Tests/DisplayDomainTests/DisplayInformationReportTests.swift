import XCTest
@testable import DisplayDomain

final class DisplayInformationReportTests: XCTestCase {
    private func mode(_ width: Int, _ height: Int, scale: Int = 1, hz: Double = 60) -> DisplayMode {
        DisplayMode(pixelWidth: width * scale, pixelHeight: height * scale, pointWidth: width, pointHeight: height,
                    refreshHz: hz, isHiDPI: scale > 1)
    }

    private func connectedFacts() -> DisplayReportFacts {
        var facts = DisplayReportFacts(appName: "FreeDisplay", appVersion: "1.2 (34)", generatedAt: "2026-10-15 10:00",
                                       presence: .connected, name: "Studio", displayClass: .external,
                                       recordID: "cg:ABCD")
        facts.systemName = "U2723QE"
        facts.physicalPresence = .physical
        facts.cgDisplayID = 3
        facts.uuid = "ABCD-1234"
        facts.vendorNumber = 0x10AC
        facts.modelNumber = 0x1234
        facts.serialNumber = 0
        facts.isActive = true
        facts.isAsleep = false
        facts.isMain = false
        facts.origin = DisplayOrigin(x: -2560, y: 0)
        facts.rotationDegrees = 0
        facts.currentMode = mode(2560, 1440, scale: 2)
        facts.backingScaleFactor = 2
        facts.listedModes = [
            DisplayModeOption(mode: mode(3840, 2160), isNative: true, isDefault: false, ioFlags: 0x3),
            DisplayModeOption(mode: mode(2560, 1440, scale: 2), isNative: false, isDefault: true, ioFlags: 0x3),
            DisplayModeOption(mode: mode(2560, 1440, scale: 2), isNative: false, isDefault: true, ioFlags: 0x3),
            DisplayModeOption(mode: mode(1280, 720), isNative: false, isDefault: false, isUsableForDesktop: false, ioFlags: 0x3),
        ]
        facts.physicalSize = DisplayPhysicalSize(widthMM: 597, heightMM: 336)
        facts.brightness = .ddc
        facts.ddc = .init(availability: .available, advertisedCodes: [0x10, 0x12], answeredCodes: [0x10])
        facts.colorProfileName = "U2723QE"
        facts.edrHeadroom = 1
        facts.potentialEDRHeadroom = 1
        return facts
    }

    func testModeNoteUsesFreeDisplayInTheReportAndLocalizationKey() {
        let note = "macOS lists only the modes the display, connection and GPU offer now; FreeDisplay can’t add modes."
        let report = DisplayInformationReport.build(connectedFacts())
        XCTAssertTrue(report.plainText().contains(note))
        let localized = DisplayInformationReport.build(connectedFacts(), ReportLocalizer(
            text: { $0 == note ? "Translated mode note" : $0 }, decimal: ReportLocalizer.posixDecimal))
        XCTAssertTrue(localized.plainText().contains("Translated mode note"))
    }

    // MARK: Plain text

    func testPlainTextKeepsEverySectionRowNoteAndTheFooter() {
        let report = InfoReport(title: "Title", header: ["Line"], sections: [
            .init(title: "One", rows: [.init("A", "1"), .init("B", "first\nsecond")], notes: ["Careful"]),
            .init(title: "Empty"),
        ], footer: ["Privacy"])
        XCTAssertEqual(report.plainText(), """
        Title
        Line

        == One ==
        A: 1
        B:
            first
            second
        * Careful

        Privacy

        """)
    }

    func testLocalizerFillsPositionalArgumentsInAnyOrder() {
        let reordering = ReportLocalizer(text: { $0 == "%1 of %2" ? "%2 → %1" : $0 }, decimal: ReportLocalizer.posixDecimal)
        XCTAssertEqual(reordering.fill("%1 of %2", "a", "b"), "b → a")
        XCTAssertEqual(ReportLocalizer.english.fill("%1/%10", "x"), "x/x0", "only supplied markers are replaced")
        XCTAssertEqual(ReportLocalizer.posixDecimal(59.940, 2), "59.94")
        XCTAssertEqual(ReportLocalizer.posixDecimal(60, 2), "60")
        XCTAssertEqual(ReportLocalizer.posixDecimal(-0.0001, 2), "0")
    }

    // MARK: Connected report

    func testConnectedReportHasEverySectionAndThePrivacyNotice() {
        let report = DisplayInformationReport.build(connectedFacts())
        XCTAssertEqual(report.title, "Display report: Studio")
        XCTAssertEqual(report.header, ["FreeDisplay 1.2 (34)", "Generated 2026-10-15 10:00"])
        XCTAssertEqual(report.sections.map(\.title),
                       ["Identity", "State", "Current mode", "Physical size", "Display modes", "Capabilities",
                        "Connection", "EDID"])
        XCTAssertTrue(report.footer.first?.contains("serial numbers, UUIDs and registry paths") ?? false)
        XCTAssertTrue(report.plainText().hasSuffix("Review it before sharing.\n"))
    }

    func testUnknownsStayUnknownAndUnsetSerialIsSaidSo() {
        var facts = connectedFacts()
        facts.vendorNumber = nil
        facts.isAsleep = nil
        facts.colorProfileName = nil
        let text = DisplayInformationReport.build(facts).plainText()
        XCTAssertTrue(text.contains("Vendor number: Unknown"))
        XCTAssertTrue(text.contains("Serial number: Not reported"))
        XCTAssertTrue(text.contains("Asleep: Unknown"))
        XCTAssertTrue(text.contains("Colour profile: Unknown"))
        XCTAssertTrue(text.contains("HDR output: Not observed"), "an unobserved HDR state is not \"No\"")
        XCTAssertTrue(text.contains("Bit depth: Not reported by macOS"))
    }

    func testModesSectionListsEveryDistinctModeWithTags() {
        let section = DisplayInformationReport.build(connectedFacts()).sections.first { $0.title == "Display modes" }
        let rows = Dictionary(uniqueKeysWithValues: (section?.rows ?? []).map { ($0.label, $0.value) })
        XCTAssertEqual(rows["Listed by macOS"], "4")
        XCTAssertEqual(rows["Distinct modes"], "3")
        XCTAssertEqual(rows["Not for desktop use"], "1")
        XCTAssertEqual(rows["All modes"], """
        3840 × 2160 points, framebuffer 3840 × 2160 pixels, 60 Hz [native, LoDPI]
        2560 × 1440 points, framebuffer 5120 × 2880 pixels, 60 Hz [current, default, HiDPI, scaled]
        1280 × 720 points, framebuffer 1280 × 720 pixels, 60 Hz [LoDPI, scaled, not for desktop use]
        """)
        XCTAssertTrue(section?.notes.contains("Entries that repeat another mode’s size, framebuffer and rate exactly, shown once: 1.") ?? false)
    }

    func testPhysicalSizeGivesDiagonalAndDensityFromTheNativeMode() {
        let section = DisplayInformationReport.build(connectedFacts()).sections.first { $0.title == "Physical size" }
        let rows = Dictionary(uniqueKeysWithValues: (section?.rows ?? []).map { ($0.label, $0.value) })
        XCTAssertEqual(rows["Image size"], "597 × 336 mm")
        XCTAssertEqual(rows["Diagonal"], "27 inches")
        XCTAssertEqual(rows["Native-flagged framebuffer"], "3840 × 2160 pixels")
        XCTAssertEqual(rows["Pixel density"], "163.4 pixels per inch")
        XCTAssertEqual(rows["Interface density"], "108.9 points per inch at the current mode")
    }

    func testASizeIsNotStatedForAScreenWithoutDisplayHardware() {
        var facts = connectedFacts()
        facts.physicalPresence = .unverified
        let section = DisplayInformationReport.build(facts).sections.first { $0.title == "Physical size" }
        XCTAssertEqual(section?.rows.first?.value,
                       "Not stated: macOS may only estimate the size of a screen without display hardware")
        XCTAssertFalse(section?.rows.contains { $0.label == "Pixel density" || $0.label == "Diagonal" } ?? true)
    }

    func testTheEDIDsOwnSizeIsShownBesideMacOSs() {
        var bytes = [UInt8](repeating: 0, count: 128)
        bytes.replaceSubrange(0..<8, with: [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
        bytes[18] = 1; bytes[19] = 4; bytes[21] = 60; bytes[22] = 34
        bytes[127] = UInt8((256 - bytes.reduce(0) { $0 + Int($1) } % 256) % 256)
        var facts = connectedFacts()
        facts.edid = .matched(bytes)
        let section = DisplayInformationReport.build(facts).sections.first { $0.title == "Physical size" }
        XCTAssertEqual(section?.rows.first { $0.label == "Size in the EDID" }?.value, "60 × 34 cm")
    }

    func testPlaceholderIdentityIsUnknownAndGammaClaimsNoMoreThanItKnows() {
        var facts = connectedFacts()
        facts.vendorNumber = 0x756E_6B6E
        facts.modelNumber = 0x0717
        let text = DisplayInformationReport.build(facts).plainText()
        XCTAssertTrue(text.contains("Vendor number: Unknown (macOS reports its placeholder value)"))
        XCTAssertTrue(text.contains("Model number: Unknown (macOS reports its placeholder value)"))
        XCTAssertTrue(text.contains("Software gamma: No rejected write recorded"))
    }

    func testMissingPhysicalSizeDisablesDensity() {
        var facts = connectedFacts()
        facts.physicalSize = DisplayPhysicalSize(widthMM: 0, heightMM: 0)
        XCTAssertNil(facts.physicalSize)
        let section = DisplayInformationReport.build(facts).sections.first { $0.title == "Physical size" }
        XCTAssertEqual(section?.rows.first, .init("Size", "Not reported by macOS"))
        XCTAssertFalse(section?.rows.contains { $0.label == "Pixel density" } ?? true)
    }

    func testDDCAdvertisedIsNotPresentedAsVerified() {
        let section = DisplayInformationReport.build(connectedFacts()).sections.first { $0.title == "Capabilities" }
        let rows = Dictionary(uniqueKeysWithValues: (section?.rows ?? []).map { ($0.label, $0.value) })
        XCTAssertEqual(rows["Brightness control"], "Monitor hardware over DDC")
        XCTAssertEqual(rows["DDC capability list"], "10 12")
        XCTAssertEqual(rows["DDC answered reads for"], "10")
        XCTAssertTrue(section?.notes.first?.contains("advertised, not verified") ?? false)
        var publicBuild = connectedFacts()
        publicBuild.ddc = .init(availability: .notInThisBuild)
        let text = DisplayInformationReport.build(publicBuild).plainText()
        XCTAssertTrue(text.contains("DDC: Not available in this build"))
        XCTAssertFalse(text.contains("DDC capability list"))
    }

    func testAnExternalWithoutHardwareEvidenceIsNotCalledExternal() {
        let l = ReportLocalizer.english
        XCTAssertEqual(DisplayInformationReport.classLabel(.external, presence: .unverified, l),
                       "External or virtual (not confirmed as display hardware)")
        XCTAssertEqual(DisplayInformationReport.classLabel(.external, presence: .virtual, l), "Virtual")
        XCTAssertEqual(DisplayInformationReport.classLabel(.sidecar, presence: nil, l), "Sidecar")
        XCTAssertEqual(DisplayInformationReport.classLabel(.unknown, presence: nil, l), "Unknown")
        XCTAssertEqual(DisplayInformationReport.classLabel(.external, presence: .physical, l), "External")
    }

    // MARK: Saved-only report

    func testASavedOnlyReportSaysSoAndOmitsLiveSections() {
        var facts = DisplayReportFacts(appName: "FreeDisplay", appVersion: "1.2", generatedAt: "now",
                                       presence: .savedOnly, name: "Old monitor", displayClass: .external,
                                       recordID: "cg:OLD")
        facts.lastSeen = "yesterday"
        let report = DisplayInformationReport.build(facts)
        XCTAssertTrue(report.header.contains("This display isn’t connected: only saved information is shown."))
        XCTAssertEqual(report.sections.map(\.title), ["Identity", "Connection", "EDID"])
        let text = report.plainText()
        XCTAssertTrue(text.contains("Display ID (this session): Not connected"))
        XCTAssertTrue(text.contains("Last seen: yesterday"))
    }

    // MARK: EDID

    func testAmbiguousEDIDIsReportedAsAmbiguous() {
        var facts = connectedFacts()
        facts.edid = .ambiguous(candidates: 2)
        let text = DisplayInformationReport.build(facts).plainText()
        XCTAssertTrue(text.contains("Source: Ambiguous: 2 different EDIDs carry this display’s vendor, product code and serial"))
    }

    func testMatchedEDIDIncludesTheBytesAndTheDecodedSections() {
        var bytes = [UInt8](repeating: 0, count: 128)
        bytes.replaceSubrange(0..<8, with: [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
        bytes[8] = 0x10; bytes[9] = 0xAC; bytes[18] = 1; bytes[19] = 4
        bytes[127] = UInt8((256 - bytes.reduce(0) { $0 + Int($1) } % 256) % 256)
        var facts = connectedFacts()
        facts.edid = .matched(bytes)
        let report = DisplayInformationReport.build(facts)
        let titles = report.sections.map(\.title)
        XCTAssertTrue(titles.contains("EDID — Identification"))
        let edid = report.sections.first { $0.title == "EDID" }
        XCTAssertEqual(edid?.rows.last?.value, Data(bytes).base64EncodedString())
    }

    // MARK: Helpers

    func testSuggestedFileNameReplacesUnsafeCharacters() {
        XCTAssertEqual(DisplayInformationReport.suggestedFileName(displayName: "LG 27\" / Left"), "LG 27- - Left_report.txt")
        XCTAssertEqual(DisplayInformationReport.suggestedFileName(displayName: "  "), "Display_report.txt")
    }

    func testPhysicalDensityIsRotationIndependent() throws {
        let size = try XCTUnwrap(DisplayPhysicalSize(widthMM: 597, heightMM: 336))
        XCTAssertEqual(size.density(width: 3840, height: 2160), size.density(width: 2160, height: 3840))
        XCTAssertNil(size.density(width: 0, height: 2160))
        XCTAssertNil(DisplayPhysicalSize(widthMM: .nan, heightMM: 300))
    }
}
