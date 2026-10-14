import XCTest
@testable import DisplayDomain

final class DisplayModeFilterTests: XCTestCase {
    private func mode(_ width: Int, _ height: Int, scale: Int = 1, hz: Double = 60, depth: Int? = nil) -> DisplayMode {
        DisplayMode(pixelWidth: width * scale, pixelHeight: height * scale, pointWidth: width, pointHeight: height,
                    refreshHz: hz, isHiDPI: scale > 1, bitDepth: depth)
    }

    /// Valid + safe, the flags an ordinary mode carries.
    private let ordinaryFlags: UInt32 = 0x3

    private func option(_ mode: DisplayMode, native: Bool = false, isDefault: Bool = false,
                        usable: Bool = true, flags: UInt32? = 0x3) -> DisplayModeOption {
        DisplayModeOption(mode: mode, isNative: native, isDefault: isDefault, isUsableForDesktop: usable, ioFlags: flags)
    }

    /// A 4K panel: native LoDPI, a HiDPI family at 60 and 59.94 Hz, a 16:10 size, a mode macOS
    /// marks not for desktop use and one flagged unsafe.
    private var panel: [DisplayModeOption] {
        [option(mode(3840, 2160), native: true),
         option(mode(3840, 2160, hz: 59.94), native: true),
         option(mode(2560, 1440, scale: 2), isDefault: true),
         option(mode(2560, 1440, scale: 2, hz: 59.94)),
         option(mode(1920, 1080, scale: 2)),
         option(mode(1920, 1080)),
         option(mode(1920, 1200, scale: 2)),
         option(mode(1280, 720), usable: false),
         option(mode(720, 480), flags: 0x1)]
    }

    // MARK: Tags

    func testTagsRestateWhatTheModeReports() {
        let options = panel
        func tags(_ index: Int, current: DisplayMode? = nil) -> [DisplayModeTag] {
            DisplayModeCatalog.tags(for: options[index], among: options, current: current)
        }
        XCTAssertEqual(tags(0), [.native, .loDPI])
        XCTAssertEqual(tags(2, current: mode(2560, 1440, scale: 2)), [.current, .defaultMode, .hiDPI, .scaled])
        // 1920 × 1080 HiDPI renders 3840 × 2160 — the native framebuffer — so it isn't "scaled".
        XCTAssertEqual(tags(4), [.hiDPI])
        XCTAssertEqual(tags(5), [.loDPI, .scaled])
        XCTAssertEqual(tags(7), [.loDPI, .scaled, .notForDesktop])
        XCTAssertEqual(tags(8), [.loDPI, .scaled, .unsafe])
    }

    func testNothingIsCalledScaledWithoutANativeMode() {
        let options = [option(mode(1920, 1080)), option(mode(1280, 720))]
        XCTAssertFalse(DisplayModeCatalog.tags(for: options[1], among: options, current: nil).contains(.scaled))
        XCTAssertNil(DisplayModeCatalog.nativeFramebuffer(options))
    }

    func testFlagBitsAreInterpretedOnlyWhenRead() {
        let unknown = option(mode(1920, 1080), flags: nil)
        XCTAssertNil(unknown.isReportedValid); XCTAssertNil(unknown.isReportedSafe)
        XCTAssertTrue(unknown.isOrdinary, "missing flags are not evidence against a mode")
        XCTAssertTrue(option(mode(640, 480), flags: 0x0).isOrdinary, "flags tag a mode; only desktop usability hides it")
        XCTAssertFalse(option(mode(640, 480), usable: false).isOrdinary)
        let interlaced = option(mode(1920, 1080), flags: 0x3 | 0x40)
        XCTAssertEqual(DisplayModeCatalog.tags(for: interlaced, among: [interlaced], current: nil), [.loDPI, .interlaced])
        XCTAssertEqual(option(mode(640, 480), flags: 0x2).isReportedValid, false)
    }

    func testBitDepthIsTaggedOnlyWhenKnown() {
        let known = option(mode(1920, 1080, depth: 10))
        XCTAssertTrue(DisplayModeCatalog.tags(for: known, among: [known], current: nil).contains(.bitDepth(10)))
        XCTAssertTrue(DisplayModeCatalog.facets(panel).bitDepths.isEmpty)
    }

    // MARK: Filtering

    func testDefaultFilterListsOrdinaryModesAndCountsTheRest() {
        let result = DisplayModeCatalog.filter(panel, with: .any, current: mode(2560, 1440, scale: 2))
        // The unsafe-flagged mode is usable for a desktop, so it's listed (tagged), not hidden.
        XCTAssertEqual(result.visible.count, 8)
        XCTAssertEqual(result.hiddenNonOrdinary, 1)
        XCTAssertEqual(result.hiddenByFilters, 0)
        XCTAssertFalse(result.currentKeptOutsideFilter)
    }

    func testIncludingNonOrdinaryModesListsEverythingMacOSOffers() {
        var filter = DisplayModeFilter.any
        filter.includeNonOrdinary = true
        let result = DisplayModeCatalog.filter(panel, with: filter, current: nil)
        XCTAssertEqual(result.visible, panel)
        XCTAssertEqual(result.hiddenNonOrdinary, 0)
    }

    func testValuesInACategoryAreAlternativesAndCategoriesCombine() {
        var filter = DisplayModeFilter.any
        filter.toggle(DisplayRefreshRate(60))
        filter.toggle(DisplayRefreshRate(59.94))
        filter.toggle(DisplayModeDensity.hiDPI)
        let visible = DisplayModeCatalog.filter(panel, with: filter, current: nil).visible.map(\.mode)
        XCTAssertEqual(visible, [mode(2560, 1440, scale: 2), mode(2560, 1440, scale: 2, hz: 59.94),
                                 mode(1920, 1080, scale: 2), mode(1920, 1200, scale: 2)])
        filter.toggle(DisplayAspectRatio(width: 16, height: 9)!)
        let sixteenByNine = DisplayModeCatalog.filter(panel, with: filter, current: nil).visible.map(\.mode)
        XCTAssertFalse(sixteenByNine.contains(mode(1920, 1200, scale: 2)))
        XCTAssertEqual(sixteenByNine.count, 3)
    }

    func testFractionalAndIntegerRatesStayDistinct() {
        var filter = DisplayModeFilter.any
        filter.toggle(DisplayRefreshRate(59.94))
        let visible = DisplayModeCatalog.filter(panel, with: filter, current: nil).visible.map(\.mode.refreshHz)
        XCTAssertEqual(visible, [59.94, 59.94])
        XCTAssertNotEqual(DisplayRefreshRate(59.94), DisplayRefreshRate(60))
    }

    func testTheCurrentModeStaysVisibleOutsideTheFilters() {
        var filter = DisplayModeFilter.any
        filter.toggle(DisplayModeDensity.loDPI)
        let current = mode(2560, 1440, scale: 2)
        let result = DisplayModeCatalog.filter(panel, with: filter, current: current)
        XCTAssertTrue(result.visible.contains { $0.mode == current })
        XCTAssertTrue(result.currentFailsFilters)
        XCTAssertFalse(result.currentIsNotOrdinary)
        // Even a current mode macOS considers non-ordinary stays listed, for that reason.
        let odd = DisplayModeCatalog.filter(panel, with: .any, current: mode(1280, 720))
        XCTAssertTrue(odd.visible.contains { $0.mode == mode(1280, 720) })
        XCTAssertTrue(odd.currentIsNotOrdinary)
        XCTAssertFalse(odd.currentFailsFilters)
        XCTAssertTrue(odd.currentKeptOutsideFilter)
    }

    func testAnUnenumeratedCurrentModeIsListedWithoutClaimedMarkers() {
        let current = mode(3008, 1692, scale: 2)
        let result = DisplayModeCatalog.filter(panel, with: .any, current: current)
        XCTAssertEqual(result.visible.first?.mode, current)
        XCTAssertEqual(result.visible.first?.isNative, false)
        XCTAssertTrue(result.currentNotEnumerated)
        XCTAssertFalse(result.currentFailsFilters)
    }

    func testDeselectingEveryValueMatchesNothingButTheCurrentMode() {
        var filter = DisplayModeFilter.any
        filter.toggle(DisplayModeDensity.hiDPI)
        filter.toggle(DisplayModeDensity.hiDPI)
        XCTAssertEqual(filter.densities, [])
        let current = mode(3840, 2160)
        let result = DisplayModeCatalog.filter(panel, with: filter, current: current)
        XCTAssertEqual(result.visible.map(\.mode), [current])
        // The not-for-desktop mode is counted as such, not as filtered: clearing the filters
        // alone wouldn't bring it back.
        XCTAssertEqual(result.hiddenByFilters, 7)
        XCTAssertEqual(result.hiddenNonOrdinary, 1)
    }

    func testMatchingCurrentSelectsItsAspectRateAndDensity() {
        let filter = DisplayModeFilter.matching(mode(2560, 1440, scale: 2, hz: 59.94))
        XCTAssertEqual(filter.aspects, [DisplayAspectRatio(width: 16, height: 9)!])
        XCTAssertEqual(filter.refreshRates, [DisplayRefreshRate(59.94)])
        XCTAssertEqual(filter.densities, [.hiDPI])
        XCTAssertNil(filter.bitDepths, "an unknown depth isn't turned into a depth filter")
        XCTAssertEqual(filter.restrictedCategories, [.aspect, .refresh, .density])
    }

    func testFacetsListEveryValueOnce() {
        let facets = DisplayModeCatalog.facets(panel)
        XCTAssertEqual(facets.refreshRates.map(\.hertz), [60, 59.94])
        XCTAssertEqual(facets.densities, [.hiDPI, .loDPI])
        XCTAssertEqual(facets.aspects.map { $0.label() }, ["16:9", "16:10", "3:2"])
    }

    func testAspectRatiosReduceAndLabelReadably() {
        XCTAssertEqual(DisplayAspectRatio(width: 3840, height: 2160), DisplayAspectRatio(width: 1920, height: 1080))
        XCTAssertEqual(DisplayAspectRatio(width: 3440, height: 1440)?.label(), "43:18")
        XCTAssertEqual(DisplayAspectRatio(width: 1710, height: 1107)?.label(), "1.545:1")
        XCTAssertNil(DisplayAspectRatio(width: 0, height: 1080))
        let comma = ReportLocalizer(text: { $0 }, decimal: { ReportLocalizer.posixDecimal($0, $1).replacingOccurrences(of: ".", with: ",") })
        XCTAssertEqual(DisplayAspectRatio(width: 1710, height: 1107)?.label(comma), "1,545:1")
    }

    func testNotchHeightSizesThatReadAsOneRatioAreOneFilterValue() {
        // MacBook Pro 14": 1512 × 982 and 1800 × 1169 both read 1.540:1; 3024 × 1964 is the panel.
        let notch = [option(mode(3024, 1964), native: true), option(mode(1512, 982, scale: 2)),
                     option(mode(1800, 1169, scale: 2)), option(mode(1440, 900, scale: 2))]
        let facets = DisplayModeCatalog.facets(notch)
        XCTAssertEqual(facets.aspects.map { $0.label() }, ["16:10", "1.54:1"])
        let like = DisplayModeFilter.matching(mode(1512, 982, scale: 2))
        let visible = DisplayModeCatalog.filter(notch, with: like, current: mode(1512, 982, scale: 2)).visible.map(\.mode)
        XCTAssertEqual(visible, [mode(1512, 982, scale: 2), mode(1800, 1169, scale: 2)])
    }

    // MARK: Distinct modes and summary

    func testExactDuplicatesCollapseKeepingTheOrdinaryTwin() {
        let raw = [option(mode(1920, 1080), usable: false), option(mode(1920, 1080)), option(mode(1280, 720))]
        let distinct = DisplayModeCatalog.distinct(raw)
        XCTAssertEqual(distinct.count, 2)
        XCTAssertTrue(distinct[0].isUsableForDesktop)
        let summary = DisplayModeCatalog.summary(listed: raw)
        XCTAssertEqual(summary.listed, 3); XCTAssertEqual(summary.distinct, 2); XCTAssertEqual(summary.duplicates, 1)
        XCTAssertEqual(summary.notForDesktop, 0)
    }

    func testSummaryCountsEachKindOfMode() {
        let summary = DisplayModeCatalog.summary(listed: panel)
        XCTAssertEqual(summary.listed, 9); XCTAssertEqual(summary.ordinary, 8)
        XCTAssertEqual(summary.notForDesktop, 1); XCTAssertEqual(summary.flaggedUnsafe, 1)
        XCTAssertEqual(summary.flaggedInvalid, 0)
        XCTAssertEqual(summary.hiDPI, 4); XCTAssertEqual(summary.loDPI, 5)
    }

    // MARK: Why a mode is missing

    func testAvailabilityExplainsFilteredAndNonOrdinaryModes() {
        var filter = DisplayModeFilter.any
        filter.toggle(DisplayModeDensity.loDPI)
        XCTAssertEqual(DisplayModeCatalog.availability(of: mode(2560, 1440, scale: 2), in: panel, filter: filter),
                       .hiddenByFilters([.density]))
        XCTAssertEqual(DisplayModeCatalog.availability(of: mode(1280, 720), in: panel, filter: .any),
                       .hiddenNotOrdinary([.notForDesktop]))
        XCTAssertEqual(DisplayModeCatalog.availability(of: mode(3840, 2160), in: panel, filter: .any), .listed)
    }

    func testAvailabilityNamesWhatIsOfferedInsteadOfAMissingMode() {
        guard case .notOffered(let near) = DisplayModeCatalog.availability(of: mode(2560, 1440, scale: 2, hz: 120),
                                                                            in: panel, filter: .any) else {
            return XCTFail("a 120 Hz mode isn't offered")
        }
        XCTAssertEqual(near.otherRefreshRates, [60, 59.94])
        XCTAssertFalse(near.otherDensityOffered)
        XCTAssertFalse(near.sizeNotOffered)
        guard case .notOffered(let none) = DisplayModeCatalog.availability(of: mode(3008, 1692, scale: 2),
                                                                            in: panel, filter: .any) else {
            return XCTFail("not offered")
        }
        XCTAssertTrue(none.sizeNotOffered)
        guard case .notOffered(let density) = DisplayModeCatalog.availability(of: mode(1920, 1200),
                                                                               in: panel, filter: .any) else {
            return XCTFail("not offered")
        }
        XCTAssertTrue(density.otherDensityOffered)
    }

    func testTagLabelsGoThroughTheLocalizer() {
        let marked = ReportLocalizer(text: { "‹\($0)›" }, decimal: ReportLocalizer.posixDecimal)
        XCTAssertEqual(DisplayModeCatalog.tagLabel(.notForDesktop, marked), "‹not for desktop use›")
        XCTAssertEqual(DisplayModeCatalog.tagLabel(.bitDepth(10), marked), "‹10-bit›")
        XCTAssertEqual(DisplayModeCatalog.tagLabel(.hiDPI, marked), "HiDPI")
    }
}
