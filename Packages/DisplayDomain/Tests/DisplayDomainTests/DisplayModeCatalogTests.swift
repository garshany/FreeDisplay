import XCTest
@testable import DisplayDomain

final class DisplayModeCatalogTests: XCTestCase {
    /// A mode as Core Graphics reports it: HiDPI whenever the framebuffer is larger than the
    /// logical size.
    private func mode(_ width: Int, _ height: Int, scale: Int = 1, hz: Double = 60,
                      depth: Int? = nil) -> DisplayMode {
        DisplayMode(pixelWidth: width * scale, pixelHeight: height * scale,
                    pointWidth: width, pointHeight: height,
                    refreshHz: hz, isHiDPI: scale > 1, bitDepth: depth)
    }

    private func option(_ mode: DisplayMode, native: Bool = false,
                        isDefault: Bool = false) -> DisplayModeOption {
        DisplayModeOption(mode: mode, isNative: native, isDefault: isDefault)
    }

    private func stop(of size: (Int, Int), in stops: [DisplayModeOption]) -> DisplayMode? {
        stops.first { $0.mode.pointWidth == size.0 && $0.mode.pointHeight == size.1 }?.mode
    }

    /// A 4K panel offering the usual 16:9 family, at both 60 and 59.94 Hz.
    private var fourK: [DisplayModeOption] {
        [option(mode(3840, 2160), native: true),
         option(mode(3840, 2160, hz: 59.94), native: true),
         option(mode(2560, 1440, scale: 2), isDefault: true),
         option(mode(2560, 1440, scale: 2, hz: 59.94)),
         option(mode(2560, 1440)),
         option(mode(1920, 1080, scale: 2)),
         option(mode(1920, 1080, scale: 2, hz: 59.94)),
         option(mode(1920, 1080)),
         option(mode(1920, 1080, hz: 59.94))]
    }

    // MARK: - Preserving the current format

    func testASizeOnlyMoveKeepsAFractionalRefreshRateOverNativeAndDefaultMarkers() {
        let current = mode(1920, 1080, scale: 2, hz: 59.94)
        let stops = DisplayModeCatalog.sliderStops(fourK, current: current)
        // The default-flagged 2560 variant runs at 60 Hz; the stop must keep 59.94 instead.
        XCTAssertEqual(stop(of: (2560, 1440), in: stops), mode(2560, 1440, scale: 2, hz: 59.94))
        XCTAssertEqual(stop(of: (3840, 2160), in: stops), mode(3840, 2160, hz: 59.94))
    }

    func testDensityIsKeptWhenTheRateCanBeKeptToo() {
        let current = mode(1920, 1080, scale: 2)
        let stops = DisplayModeCatalog.sliderStops(fourK, current: current)
        XCTAssertEqual(stop(of: (2560, 1440), in: stops), mode(2560, 1440, scale: 2))
    }

    func testTheRefreshRateOutranksDensityAndTheDifferenceIsReported() {
        let current = mode(1920, 1080, scale: 2)
        let options = [option(current),
                       option(mode(2560, 1440, scale: 2, hz: 30)),
                       option(mode(2560, 1440))]
        let stops = DisplayModeCatalog.sliderStops(options, current: current)
        let chosen = try! XCTUnwrap(stop(of: (2560, 1440), in: stops))
        XCTAssertEqual(chosen, mode(2560, 1440))
        XCTAssertEqual(DisplayModeCatalog.change(from: current, to: chosen),
                       .init(refreshRate: false, density: true, bitDepth: false))
    }

    func testWithoutTheCurrentRateTheClosestOneIsChosenAndDisclosed() {
        let current = mode(1920, 1080, hz: 59.94)
        let options = [option(current), option(mode(2560, 1440, hz: 50)), option(mode(2560, 1440, hz: 75))]
        let stops = DisplayModeCatalog.sliderStops(options, current: current)
        let chosen = try! XCTUnwrap(stop(of: (2560, 1440), in: stops))
        XCTAssertEqual(chosen.refreshHz, 50)
        XCTAssertTrue(DisplayModeCatalog.change(from: current, to: chosen).refreshRate)
    }

    func testAKnownBitDepthIsKept() {
        let current = mode(1920, 1080, scale: 2, depth: 10)
        let options = [option(current),
                       option(mode(2560, 1440, scale: 2, depth: 8), isDefault: true),
                       option(mode(2560, 1440, scale: 2, depth: 10))]
        let stops = DisplayModeCatalog.sliderStops(options, current: current)
        XCTAssertEqual(stop(of: (2560, 1440), in: stops)?.bitDepth, 10)
    }

    func testAnUnknownBitDepthIsNeverReportedAsAChange() {
        XCTAssertTrue(DisplayModeCatalog.change(from: mode(1920, 1080), to: mode(2560, 1440, depth: 8)).isEmpty)
        XCTAssertTrue(DisplayModeCatalog.change(from: mode(1920, 1080, depth: 10),
                                                to: mode(2560, 1440, depth: 8)).bitDepth)
    }

    func testNativeLoDPIWithoutAHiDPITwinMovesToHiDPIElsewhere() {
        let current = mode(3840, 2160)
        let stops = DisplayModeCatalog.sliderStops(fourK, current: current)
        XCTAssertEqual(stop(of: (1920, 1080), in: stops), mode(1920, 1080, scale: 2))
    }

    func testADeliberateLoDPIChoiceStaysLoDPI() {
        // 1920×1080 also exists as HiDPI, so LoDPI here is the user's choice — keep it.
        let current = mode(1920, 1080)
        let stops = DisplayModeCatalog.sliderStops(fourK, current: current)
        XCTAssertEqual(stop(of: (2560, 1440), in: stops), mode(2560, 1440))
    }

    // MARK: - The current mode is always a truthful stop

    func testTheCurrentSizeIsTheCurrentVariantNotADefaultSibling() {
        let current = mode(2560, 1440)
        let stops = DisplayModeCatalog.sliderStops(fourK, current: current)
        XCTAssertEqual(stop(of: (2560, 1440), in: stops), current)
        XCTAssertNotNil(DisplayModeCatalog.index(of: current, in: stops))
    }

    func testACurrentModeMissingFromTheListStillGetsItsOwnStop() {
        let current = mode(1680, 945, scale: 2)
        let stops = DisplayModeCatalog.sliderStops(fourK, current: current)
        let index = try! XCTUnwrap(DisplayModeCatalog.index(of: current, in: stops))
        XCTAssertEqual(stops[index].mode, current)
        // Nothing is known about an unlisted mode's markers, so it claims none.
        XCTAssertFalse(stops[index].isNative)
        XCTAssertFalse(stops[index].isDefault)
        // Ordered by size like every other stop.
        XCTAssertEqual(stops.map(\.mode.pointWidth), [1680, 1920, 2560, 3840])
    }

    func testACurrentModeOutsideTheNativeAspectIsKept() {
        let current = mode(1920, 1200)
        var options = fourK
        options.append(option(current))
        options.append(option(mode(1680, 1050)))
        let stops = DisplayModeCatalog.sliderStops(options, current: current)
        XCTAssertNotNil(DisplayModeCatalog.index(of: current, in: stops))
        XCTAssertNil(stop(of: (1680, 1050), in: stops), "other off-aspect sizes stay filtered out")
    }

    func testTheIndexMatchesTheExactModeNotJustItsSize() {
        let stops = DisplayModeCatalog.sliderStops(fourK, current: mode(1920, 1080, scale: 2))
        XCTAssertNil(DisplayModeCatalog.index(of: mode(1920, 1080, scale: 2, hz: 59.94), in: stops))
        XCTAssertNotNil(DisplayModeCatalog.index(of: mode(1920, 1080, scale: 2), in: stops))
    }

    func testOneStopPerSizeAscending() {
        let stops = DisplayModeCatalog.sliderStops(fourK, current: mode(2560, 1440, scale: 2))
        XCTAssertEqual(stops.map(\.mode.pointWidth), [1920, 2560, 3840])
    }

    func testIdentityKeepsFractionalRatesApart() {
        XCTAssertNotEqual(option(mode(1920, 1080, hz: 60)).id, option(mode(1920, 1080, hz: 59.94)).id)
        XCTAssertNotEqual(option(mode(1920, 1080, scale: 2)).id, option(mode(1920, 1080)).id)
    }
}
