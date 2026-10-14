import XCTest
@testable import DisplayDomain

final class FavoriteResolutionsTests: XCTestCase {
    private func mode(_ pw: Int, _ ph: Int, hz: Double = 60, hiDPI: Bool = false) -> DisplayMode {
        DisplayMode(pixelWidth: pw, pixelHeight: ph, pointWidth: pw, pointHeight: ph,
                    refreshHz: hz, isHiDPI: hiDPI)
    }
    /// A HiDPI ("looks like") mode: framebuffer twice the logical size, as Core Graphics reports it.
    private func scaled(_ pw: Int, _ ph: Int, hz: Double = 60) -> DisplayMode {
        DisplayMode(pixelWidth: pw * 2, pixelHeight: ph * 2, pointWidth: pw, pointHeight: ph,
                    refreshHz: hz, isHiDPI: true)
    }
    private let dispA = DisplayRecordID(rawValue: "disp_A")
    private let dispB = DisplayRecordID(rawValue: "disp_B")

    func testLegacyKeyEncodesSizeRoundedRefreshAndHiDPI() {
        XCTAssertEqual(FavoriteResolutions.legacyKey(for: mode(1920, 1080, hz: 60)), "1920x1080@60")
        XCTAssertEqual(FavoriteResolutions.legacyKey(for: mode(1920, 1080, hz: 120)), "1920x1080@120")
        XCTAssertEqual(FavoriteResolutions.legacyKey(for: mode(1512, 982, hz: 60, hiDPI: true)), "1512x982@60@2x")
    }

    func testExactKeyEncodesFramebufferUnroundedRefreshDensityAndDepth() {
        XCTAssertEqual(FavoriteResolutions.key(for: scaled(1920, 1080, hz: 59.94)), "1920x1080/3840x2160@59.940@2x")
        XCTAssertEqual(FavoriteResolutions.key(for: mode(1920, 1080, hz: 60)), "1920x1080/1920x1080@60.000")
        var deep = mode(2560, 1440)
        deep.bitDepth = 10
        XCTAssertEqual(FavoriteResolutions.key(for: deep), "2560x1440/2560x1440@60.000#10")
    }

    func testExactKeysRoundTripThroughParsing() {
        var deep = scaled(1512, 982, hz: 120)
        deep.bitDepth = 8
        for candidate in [mode(1920, 1080), scaled(1920, 1080, hz: 59.94), deep] {
            XCTAssertEqual(FavoriteResolutions.exactMode(from: FavoriteResolutions.key(for: candidate)), candidate)
        }
        XCTAssertNil(FavoriteResolutions.exactMode(from: "1920x1080@60@2x"), "a legacy key is not exact")
    }

    // MARK: - Fractional refresh rates (AM-10)

    func testFractionalAndIntegerRatesAreSeparateFavorites() {
        var fav = FavoriteResolutions()
        fav.add(scaled(1920, 1080, hz: 59.94), for: dispA)
        XCTAssertTrue(fav.isFavorite(scaled(1920, 1080, hz: 59.94), for: dispA))
        XCTAssertFalse(fav.isFavorite(scaled(1920, 1080, hz: 60), for: dispA))
        fav.add(scaled(1920, 1080, hz: 60), for: dispA)
        fav.toggle(scaled(1920, 1080, hz: 59.94), for: dispA)
        XCTAssertFalse(fav.isFavorite(scaled(1920, 1080, hz: 59.94), for: dispA))
        XCTAssertTrue(fav.isFavorite(scaled(1920, 1080, hz: 60), for: dispA))
    }

    func testFramebufferAndDensityVariantsAreSeparateFavorites() {
        var fav = FavoriteResolutions()
        fav.add(scaled(1920, 1080), for: dispA)
        XCTAssertFalse(fav.isFavorite(mode(1920, 1080), for: dispA))
    }

    func testFloatingPointNoiseInTheReportedRateStillMatches() {
        var fav = FavoriteResolutions()
        fav.add(scaled(1920, 1080, hz: 59.94005994005994), for: dispA)
        XCTAssertTrue(fav.isFavorite(scaled(1920, 1080, hz: 59.94), for: dispA))
    }

    // MARK: - Legacy rounded keys

    private func legacy(_ keys: [String], for display: DisplayRecordID) -> FavoriteResolutions {
        FavoriteResolutions(byDisplay: [display.rawValue: keys])
    }

    func testALegacyKeyStillMatchesEveryModeItUsedTo() {
        let fav = legacy(["1920x1080@60@2x"], for: dispA)
        XCTAssertTrue(fav.isFavorite(scaled(1920, 1080, hz: 60), for: dispA))
        XCTAssertTrue(fav.isFavorite(scaled(1920, 1080, hz: 59.94), for: dispA))
        XCTAssertFalse(fav.isFavorite(mode(1920, 1080, hz: 60), for: dispA), "density was always part of it")
    }

    func testMigrationExpandsALegacyKeyIntoEveryExactModeItCovered() {
        var fav = legacy(["2560x1440@60", "1920x1080@60@2x"], for: dispA)
        let offered = [scaled(1920, 1080, hz: 60), scaled(1920, 1080, hz: 59.94), mode(1920, 1080), mode(1280, 720)]
        XCTAssertTrue(fav.migrateLegacyKeys(among: offered, for: dispA))
        XCTAssertEqual(fav.favoriteKeys(for: dispA), [
            "2560x1440@60",  // nothing offered matches it: kept as-is, still resolvable later
            "1920x1080/3840x2160@60.000@2x",
            "1920x1080/3840x2160@59.940@2x",
        ])
        XCTAssertFalse(fav.migrateLegacyKeys(among: offered, for: dispA), "a second pass changes nothing")
    }

    func testRemovingOneOfAConflatedPairKeepsTheOther() {
        var fav = legacy(["1920x1080@60@2x"], for: dispA)
        let offered = [scaled(1920, 1080, hz: 60), scaled(1920, 1080, hz: 59.94)]
        fav.toggle(scaled(1920, 1080, hz: 60), among: offered, for: dispA)
        XCTAssertFalse(fav.isFavorite(scaled(1920, 1080, hz: 60), for: dispA))
        XCTAssertTrue(fav.isFavorite(scaled(1920, 1080, hz: 59.94), for: dispA))
        XCTAssertEqual(fav.favoriteKeys(for: dispA), ["1920x1080/3840x2160@59.940@2x"])
    }

    func testFavoriteModesResolvesNewestFirstAndKeepsUnavailableOnesStored() {
        var fav = FavoriteResolutions()
        fav.add(mode(3840, 2160), for: dispA)   // not offered right now
        fav.add(scaled(1920, 1080, hz: 59.94), for: dispA)
        let offered = [scaled(1920, 1080, hz: 59.94), scaled(1920, 1080, hz: 60), mode(1280, 720)]
        XCTAssertEqual(fav.favoriteModes(among: offered, for: dispA), [scaled(1920, 1080, hz: 59.94)])
        XCTAssertEqual(fav.favoriteKeys(for: dispA).count, 2, "the unavailable favourite is retained")
    }

    func testToggleAddsAndRemoves() {
        var fav = FavoriteResolutions()
        XCTAssertFalse(fav.isFavorite(mode(1920, 1080), for: dispA))
        fav.toggle(mode(1920, 1080), for: dispA)
        XCTAssertTrue(fav.isFavorite(mode(1920, 1080), for: dispA))
        fav.toggle(mode(1920, 1080), for: dispA)
        XCTAssertFalse(fav.isFavorite(mode(1920, 1080), for: dispA))
    }

    func testNewestFirstOrdering() {
        var fav = FavoriteResolutions()
        fav.add(mode(1280, 720), for: dispA)
        fav.add(mode(1920, 1080), for: dispA)
        fav.add(mode(2560, 1440), for: dispA)
        XCTAssertEqual(fav.favoriteKeys(for: dispA), ["2560x1440/2560x1440@60.000",
                                                     "1920x1080/1920x1080@60.000",
                                                     "1280x720/1280x720@60.000"])
    }

    func testPerDisplayIsolation() {
        var fav = FavoriteResolutions()
        fav.add(mode(1920, 1080), for: dispA)
        XCTAssertTrue(fav.isFavorite(mode(1920, 1080), for: dispA))
        XCTAssertFalse(fav.isFavorite(mode(1920, 1080), for: dispB))
    }

    func testAddRemoveAreIdempotent() {
        var fav = FavoriteResolutions()
        fav.add(mode(1920, 1080), for: dispA)
        fav.add(mode(1920, 1080), for: dispA)   // no-op
        XCTAssertEqual(fav.favoriteKeys(for: dispA).count, 1)
        fav.remove(mode(1280, 720), for: dispA) // not present — no-op
        XCTAssertEqual(fav.favoriteKeys(for: dispA).count, 1)
    }

    func testMergedPutsFavoritesFirstThenStopsDeduped() {
        let stops = [mode(1280, 720), mode(1920, 1080), mode(2560, 1440), mode(3440, 1440)]
        var fav = FavoriteResolutions()
        fav.add(mode(2560, 1440), for: dispA)
        fav.add(mode(1280, 720), for: dispA)   // newest first → 1280 before 2560
        let merged = fav.merged(stops: stops, for: dispA)
        XCTAssertEqual(merged.map { "\($0.pointWidth)" },
                       ["1280", "2560", "1920", "3440"])   // favorites (newest first), then the rest
        // no duplicates
        XCTAssertEqual(merged.count, 4)
    }

    func testMergedDropsStaleFavoritesNotInStops() {
        var fav = FavoriteResolutions()
        fav.add(mode(3840, 2160), for: dispA)   // favorite no longer offered
        fav.add(mode(1920, 1080), for: dispA)
        let stops = [mode(1280, 720), mode(1920, 1080)]
        let merged = fav.merged(stops: stops, for: dispA)
        XCTAssertEqual(merged.map { "\($0.pointWidth)" }, ["1920", "1280"])  // 3840 dropped
    }

    func testMergedWithNoFavoritesEqualsStops() {
        let stops = [mode(1280, 720), mode(1920, 1080)]
        XCTAssertEqual(FavoriteResolutions().merged(stops: stops, for: dispA), stops)
    }

    func testCodableRoundTrips() throws {
        var fav = FavoriteResolutions()
        fav.add(mode(1920, 1080), for: dispA)
        fav.add(mode(2560, 1440, hiDPI: true), for: dispB)
        let data = try JSONEncoder().encode(fav)
        XCTAssertEqual(try JSONDecoder().decode(FavoriteResolutions.self, from: data), fav)
    }
}
