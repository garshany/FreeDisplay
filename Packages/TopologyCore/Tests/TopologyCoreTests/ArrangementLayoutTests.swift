import XCTest
import DisplayDomain
@testable import TopologyCore

final class ArrangementLayoutTests: XCTestCase {
    private func id(_ raw: String) -> DisplayRecordID { DisplayRecordID(rawValue: raw) }

    private func tile(_ raw: String, _ x: Int, _ y: Int, _ w: Int, _ h: Int,
                      mirrors: [String] = []) -> ArrangementLayout.Tile {
        .init(id: id(raw), frame: ArrangementRect(x: x, y: y, width: w, height: h),
              mirrorTargets: mirrors.map(id))
    }

    private func layout(_ tiles: ArrangementLayout.Tile..., main: String = "A") -> ArrangementLayout {
        ArrangementLayout(tiles: tiles, mainID: id(main))
    }

    private func obs(_ raw: String, x: Int, y: Int, w: Int = 1920, h: Int = 1080, main: Bool = false,
                     mirror: String? = nil, rotation: Rotation = .degrees0) -> DisplayObservation {
        DisplayObservation(recordID: id(raw), cgDisplayID: 1, isActive: true,
                           origin: DisplayOrigin(x: x, y: y),
                           mode: DisplayMode(pixelWidth: w, pixelHeight: h, pointWidth: w, pointHeight: h,
                                             refreshHz: 60, isHiDPI: false),
                           rotation: rotation, isMain: main,
                           mirrorSourceID: mirror.map(id), generation: .initial)
    }

    // MARK: - Reading the topology

    func testARotatedDisplayTakesItsPortraitSizeOnTheDesktop() {
        let mode = DisplayMode(pixelWidth: 2560, pixelHeight: 1440, pointWidth: 2560, pointHeight: 1440,
                               refreshHz: 60, isHiDPI: false)
        XCTAssertTrue(ArrangementLayout.desktopSize(of: mode, rotation: .degrees90) == (1440, 2560))
        XCTAssertTrue(ArrangementLayout.desktopSize(of: mode, rotation: .degrees270) == (1440, 2560))
        XCTAssertTrue(ArrangementLayout.desktopSize(of: mode, rotation: .degrees180) == (2560, 1440))

        let rotated = ArrangementLayout(observations: [obs("A", x: 0, y: 0, main: true),
                                                       obs("B", x: 1920, y: 0, rotation: .degrees90)])
        XCTAssertEqual(rotated.frame(of: id("B")), ArrangementRect(x: 1920, y: 0, width: 1080, height: 1920))
    }

    func testAMirrorSetIsOneTileAndCarriesTheMenuBarWhenItsTargetIsMain() {
        let layout = ArrangementLayout(observations: [obs("A", x: 0, y: 0),
                                                      obs("B", x: 0, y: 0, main: true, mirror: "A"),
                                                      obs("C", x: 1920, y: 0)])
        XCTAssertEqual(layout.tiles.map(\.id), [id("A"), id("C")])
        XCTAssertEqual(layout.tiles[0].mirrorTargets, [id("B")])
        XCTAssertEqual(layout.mainID, id("A"))
    }

    /// The canvas draws from the app's sorted display list while the drop is checked against a fresh
    /// snapshot in Core Graphics' order; the same arrangement must compare equal either way.
    func testTheSameArrangementReadInAnyOrderIsEqual() {
        let observations = [obs("C", x: 0, y: 1080), obs("A", x: 0, y: 0, main: true), obs("B", x: 1920, y: 0)]
        let reference = ArrangementLayout(observations: observations)
        XCTAssertEqual(reference.tiles.map(\.id), [id("A"), id("B"), id("C")])
        XCTAssertEqual(ArrangementLayout(observations: observations.reversed()), reference)
        XCTAssertEqual(ArrangementLayout(observations: [observations[1], observations[0], observations[2]]), reference)
    }

    func testAMeasuredDesktopSizeWinsOverTheModeSize() {
        let layout = ArrangementLayout(observations: [obs("A", x: 0, y: 0, main: true), obs("B", x: 1920, y: 0)]) {
            $0.recordID == self.id("B") ? (1200, 1920) : nil
        }
        XCTAssertEqual(layout.frame(of: id("A")), ArrangementRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(layout.frame(of: id("B")), ArrangementRect(x: 1920, y: 0, width: 1200, height: 1920))
    }

    func testWithoutAMainFlagTheTileAtTheOriginIsMain() {
        let layout = ArrangementLayout(observations: [obs("A", x: -1920, y: 0), obs("B", x: 0, y: 0)])
        XCTAssertEqual(layout.mainID, id("B"))
    }

    // MARK: - Validity

    func testValidityNeedsContactWithoutOverlap() {
        XCTAssertTrue(layout(tile("A", 0, 0, 100, 50), tile("B", 100, 10, 80, 40)).isValid)
        // A shared corner is still contact.
        XCTAssertTrue(layout(tile("A", 0, 0, 100, 50), tile("B", 100, 50, 80, 40)).isValid)
        XCTAssertFalse(layout(tile("A", 0, 0, 100, 50), tile("B", 99, 0, 80, 40)).isValid, "overlap")
        XCTAssertFalse(layout(tile("A", 0, 0, 100, 50), tile("B", 101, 0, 80, 40)).isValid, "gap")
        XCTAssertFalse(layout(tile("A", 0, 0, 100, 50), tile("B", 100, 51, 80, 40)).isValid, "diagonal gap")
        XCTAssertTrue(layout(tile("A", 0, 0, 100, 50)).isValid)
    }

    // MARK: - Main display

    func testNormalisingPutsTheMainTileAtTheOriginAndKeepsTheRest() {
        let shifted = layout(tile("A", 50, 20, 100, 50), tile("B", 150, 20, 100, 50)).normalized()
        XCTAssertEqual(shifted.frame(of: id("A")), ArrangementRect(x: 0, y: 0, width: 100, height: 50))
        XCTAssertEqual(shifted.frame(of: id("B")), ArrangementRect(x: 100, y: 0, width: 100, height: 50))
    }

    func testMakingAnotherDisplayMainReanchorsEveryOriginOnIt() throws {
        let current = layout(tile("A", 0, 0, 1920, 1080), tile("B", 1920, 98, 1512, 982),
                             tile("C", 0, 1080, 1920, 1080))
        let made = try XCTUnwrap(current.makingMain(id("B")))
        XCTAssertEqual(made.mainID, id("B"))
        XCTAssertEqual(made.frame(of: id("B"))?.origin, DisplayOrigin(x: 0, y: 0))
        XCTAssertEqual(made.frame(of: id("A"))?.origin, DisplayOrigin(x: -1920, y: -98))
        XCTAssertEqual(made.frame(of: id("C"))?.origin, DisplayOrigin(x: -1920, y: 982))
        XCTAssertTrue(made.isValid)
        XCTAssertNil(current.makingMain(id("A")), "already main")
        XCTAssertNil(current.makingMain(id("Z")), "no such tile")
        XCTAssertEqual(Set(current.originChanges(to: made).keys), [id("A"), id("B"), id("C")])
    }

    // MARK: - Dropping

    private var pair: ArrangementLayout {
        layout(tile("A", 0, 0, 1920, 1080), tile("B", 1920, 0, 1512, 982))
    }

    func testASnappedDropBelowLandsOnTheNearestAlignmentStop() throws {
        let drop = try XCTUnwrap(pair.dropping(id("B"), at: DisplayOrigin(x: 300, y: 1100), snapping: true))
        // Stops along A's bottom edge: leading 0, centre 204, trailing 408 — 204 is nearest to 300.
        XCTAssertEqual(drop.result.frame(of: id("B")), ArrangementRect(x: 204, y: 1080, width: 1512, height: 982))
        XCTAssertEqual(drop.result.frame(of: id("A"))?.origin, .zero)
        XCTAssertEqual(drop.displaced, [])
        XCTAssertEqual(pair.originChanges(to: drop.result), [id("B"): DisplayOrigin(x: 204, y: 1080)])
    }

    func testShiftDropKeepsTheExactOffsetButStillTouches() throws {
        let free = try XCTUnwrap(pair.dropping(id("B"), at: DisplayOrigin(x: 300, y: 1100), snapping: false))
        XCTAssertEqual(free.result.frame(of: id("B"))?.origin, DisplayOrigin(x: 300, y: 1080))
        // Far past the corner: clamped to the last spot that still touches.
        let corner = try XCTUnwrap(pair.dropping(id("B"), at: DisplayOrigin(x: 2600, y: 1300), snapping: false))
        XCTAssertEqual(corner.result.frame(of: id("B"))?.origin, DisplayOrigin(x: 1920, y: 1080))
        XCTAssertTrue(corner.result.isValid)
    }

    func testADropOnTopOfAnotherDisplayMovesToTheNearestFreeEdge() throws {
        let drop = try XCTUnwrap(pair.dropping(id("B"), at: DisplayOrigin(x: 200, y: 50), snapping: true))
        XCTAssertEqual(drop.result.frame(of: id("B"))?.origin, DisplayOrigin(x: 204, y: 1080))
        XCTAssertTrue(drop.result.isValid)
    }

    func testADropBackOnItsOwnSpotChangesNothing() throws {
        let drop = try XCTUnwrap(pair.dropping(id("B"), at: DisplayOrigin(x: 1925, y: 10), snapping: true))
        XCTAssertEqual(pair.originChanges(to: drop.result), [:])
    }

    func testMovingTheMainDisplayKeepsItMainAtTheOrigin() throws {
        let drop = try XCTUnwrap(pair.dropping(id("A"), at: DisplayOrigin(x: 3432, y: 0), snapping: true))
        XCTAssertEqual(drop.result.mainID, id("A"))
        XCTAssertEqual(drop.result.frame(of: id("A"))?.origin, .zero)
        XCTAssertEqual(drop.result.frame(of: id("B"))?.origin, DisplayOrigin(x: -1512, y: 0))
        // The preview stays in the drawn coordinates: A lands right of B, B doesn't move.
        XCTAssertEqual(drop.preview.frame(of: id("A"))?.origin, DisplayOrigin(x: 3432, y: 0))
        XCTAssertEqual(drop.preview.frame(of: id("B"))?.origin, DisplayOrigin(x: 1920, y: 0))
    }

    func testDroppingOnASeamShiftsThePeersOnTheFarSideAside() throws {
        let row = layout(tile("A", 0, 0, 1000, 500), tile("B", 1000, 0, 1000, 500), tile("C", 0, 500, 1000, 500))
        let drop = try XCTUnwrap(row.dropping(id("C"), at: DisplayOrigin(x: 500, y: 0), snapping: true))
        XCTAssertEqual(drop.result.frame(of: id("A"))?.origin, .zero)
        XCTAssertEqual(drop.result.frame(of: id("C"))?.origin, DisplayOrigin(x: 1000, y: 0))
        XCTAssertEqual(drop.result.frame(of: id("B"))?.origin, DisplayOrigin(x: 2000, y: 0))
        XCTAssertEqual(drop.displaced, [id("B")])
        XCTAssertTrue(drop.result.isValid)
    }

    func testLiftingADisplayOutOfARowClosesTheGapItLeaves() throws {
        let row = layout(tile("A", 0, 0, 1000, 500), tile("D", 1000, 0, 1000, 500), tile("B", 2000, 0, 1000, 500))
        let drop = try XCTUnwrap(row.dropping(id("D"), at: DisplayOrigin(x: 2600, y: 0), snapping: true))
        XCTAssertEqual(drop.result.frame(of: id("B"))?.origin, DisplayOrigin(x: 1000, y: 0))
        XCTAssertEqual(drop.result.frame(of: id("D"))?.origin, DisplayOrigin(x: 2000, y: 0))
        XCTAssertEqual(drop.displaced, [id("B")])
    }

    func testAMirrorSetMovesAsOneTileAndKeepsItsTargets() throws {
        let current = ArrangementLayout(observations: [obs("A", x: 0, y: 0, main: true),
                                                       obs("B", x: 1920, y: 0), obs("T", x: 1920, y: 0, mirror: "B")])
        let drop = try XCTUnwrap(current.dropping(id("B"), at: DisplayOrigin(x: 0, y: 1200), snapping: true))
        XCTAssertEqual(drop.result.tiles.first { $0.id == id("B") }?.mirrorTargets, [id("T")])
        XCTAssertNil(drop.result.frame(of: id("T")), "a mirror target is never positioned on its own")
        XCTAssertEqual(Set(current.originChanges(to: drop.result).keys), [id("B")])
    }

    func testNoDropForALoneOrUnknownTile() {
        XCTAssertNil(layout(tile("A", 0, 0, 100, 50)).dropping(id("A"), at: DisplayOrigin(x: 10, y: 10), snapping: true))
        XCTAssertNil(pair.dropping(id("Z"), at: .zero, snapping: true))
    }

    /// Wherever a tile is dropped, with or without snapping, the result is a layout macOS takes as
    /// is, the main display stays at the origin and nobody changes size.
    func testEveryDropYieldsAValidNormalisedLayout() throws {
        let three = layout(tile("A", 0, 0, 1920, 1080), tile("B", 1920, -200, 1080, 1920),
                           tile("C", 0, 1080, 1512, 982))
        for dragged in ["A", "B", "C"] {
            for x in stride(from: -4000, through: 5000, by: 650) {
                for y in stride(from: -3000, through: 4000, by: 550) {
                    for snapping in [true, false] {
                        let drop = try XCTUnwrap(three.dropping(id(dragged), at: DisplayOrigin(x: x, y: y),
                                                                snapping: snapping), "\(dragged) at \(x),\(y)")
                        XCTAssertTrue(drop.result.isValid, "\(dragged) at \(x),\(y)")
                        XCTAssertEqual(drop.result.frame(of: id("A"))?.origin, .zero)
                        for tile in three.tiles {
                            XCTAssertEqual(drop.result.frame(of: tile.id)?.width, tile.frame.width)
                            XCTAssertEqual(drop.result.frame(of: tile.id)?.height, tile.frame.height)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Edge coordinates

    func testSnappingTriesOnlyTheStopsAndFreePlacementAlsoTheDroppedSpot() {
        let spans = [(start: 0, length: 1000)]
        // Range ends -400 and 1000; leading 0, trailing 600, centre 300; abutting -400 and 1000.
        XCTAssertEqual(ArrangementLayout.edgeCoordinates(140, in: -400...1000, length: 400, spans: spans, snapping: true),
                       [-400, 0, 300, 600, 1000])
        XCTAssertEqual(ArrangementLayout.edgeCoordinates(140, in: -400...1000, length: 400, spans: spans, snapping: false),
                       [-400, 0, 140, 300, 600, 1000])
        // A dropped spot beyond the range is clamped to its end; stops outside the range are dropped.
        XCTAssertEqual(ArrangementLayout.edgeCoordinates(5000, in: 0...700, length: 400, spans: spans, snapping: false),
                       [0, 300, 600, 700])
        // An odd difference centres by flooring, also below zero.
        XCTAssertTrue(ArrangementLayout.edgeCoordinates(0, in: -2000...1000, length: 1001, spans: spans, snapping: true)
            .contains(-1))
    }

    func testASnappedDropTakesTheNearestStopAndAFreeDropTheExactSpot() throws {
        // Right of A (1000 tall), B 400 tall: stops 0 (top), 300 (centre), 600 (bottom).
        let current = layout(tile("A", 0, 0, 1000, 1000), tile("B", 1000, 0, 400, 400))
        let snapped = try XCTUnwrap(current.dropping(id("B"), at: DisplayOrigin(x: 1010, y: 160), snapping: true))
        XCTAssertEqual(snapped.result.frame(of: id("B"))?.origin, DisplayOrigin(x: 1000, y: 300))
        let free = try XCTUnwrap(current.dropping(id("B"), at: DisplayOrigin(x: 1010, y: 160), snapping: false))
        XCTAssertEqual(free.result.frame(of: id("B"))?.origin, DisplayOrigin(x: 1000, y: 160))
    }

    func testAFreeDropBlockedByAnotherDisplayAbutsIt() throws {
        // C stands on E, clear of A; B dropped (Shift) where it would overlap C ends just above it.
        let current = layout(tile("A", 0, 0, 1000, 1000), tile("B", 1000, 0, 400, 400),
                             tile("E", 0, 1000, 1600, 400), tile("C", 1200, 600, 400, 400))
        XCTAssertTrue(current.isValid)
        let drop = try XCTUnwrap(current.dropping(id("B"), at: DisplayOrigin(x: 1000, y: 500), snapping: false))
        XCTAssertEqual(drop.result.frame(of: id("B"))?.origin, DisplayOrigin(x: 1000, y: 200))
        XCTAssertEqual(drop.displaced, [])
    }

    func testAFreeDropOnASeamInsertsRatherThanOverlaps() throws {
        // B dropped (Shift) over C, which shares A's right edge: it goes in between and C moves aside.
        let current = layout(tile("A", 0, 0, 1000, 1000), tile("B", 1000, 0, 400, 400),
                             tile("C", 1000, 600, 400, 400))
        let drop = try XCTUnwrap(current.dropping(id("B"), at: DisplayOrigin(x: 1000, y: 450), snapping: false))
        XCTAssertEqual(drop.result.frame(of: id("B"))?.origin, DisplayOrigin(x: 1000, y: 450))
        XCTAssertEqual(drop.result.frame(of: id("C"))?.origin, DisplayOrigin(x: 1400, y: 600))
        XCTAssertEqual(drop.displaced, [id("C")])
        XCTAssertTrue(drop.result.isValid)
    }

    // MARK: - Readback

    func testReadbackOutcomes() {
        let before = pair
        let planned = layout(tile("A", 0, 0, 1920, 1080), tile("B", 204, 1080, 1512, 982))
        XCTAssertEqual(ArrangementLayout.outcome(planned: planned, before: before, after: planned), .applied)
        XCTAssertEqual(ArrangementLayout.outcome(planned: planned, before: before, after: before), .nothingMoved)
        let adjusted = layout(tile("A", 0, 0, 1920, 1080), tile("B", 0, 1080, 1512, 982))
        XCTAssertEqual(ArrangementLayout.outcome(planned: planned, before: before, after: adjusted), .adjusted)
        let mainMoved = ArrangementLayout(tiles: planned.tiles, mainID: id("B"))
        XCTAssertEqual(ArrangementLayout.outcome(planned: planned, before: before, after: mainMoved), .mainChanged)
        let mirrored = layout(tile("A", 0, 0, 1920, 1080, mirrors: ["B"]))
        XCTAssertEqual(ArrangementLayout.outcome(planned: planned, before: before, after: mirrored), .desktopsChanged)
    }

    // MARK: - Canvas mapping

    func testTheCanvasMappingFitsCentresAndConvertsDrags() {
        let mapping = ArrangementCanvasMapping(layout: pair, canvasWidth: 480, canvasHeight: 210)
        // Fit: (3432 + 1920) × (1080 + 1080) → width-limited.
        XCTAssertEqual(mapping.scale, 480.0 / 5352.0, accuracy: 1e-12)
        let a = mapping.canvasRect(ArrangementRect(x: 0, y: 0, width: 1920, height: 1080))
        let b = mapping.canvasRect(ArrangementRect(x: 1920, y: 0, width: 1512, height: 982))
        XCTAssertEqual((a.x + b.x + b.width) / 2, 240, accuracy: 1e-9, "centred horizontally")
        XCTAssertEqual(a.y + a.height / 2, 105, accuracy: 1e-9, "centred vertically on the bounds")
        let back = mapping.desktopPoint(canvasX: a.x, canvasY: a.y)
        XCTAssertEqual(back.x, 0, accuracy: 1e-9)
        XCTAssertEqual(back.y, 0, accuracy: 1e-9)
        let delta = mapping.desktopDelta(canvasDX: 10, canvasDY: -3)
        XCTAssertEqual(delta.dx, Int((10 / mapping.scale).rounded()))
        XCTAssertEqual(delta.dy, Int((-3 / mapping.scale).rounded()))
        XCTAssertEqual(pair.tileID(atX: back.x + 1, y: back.y + 1), id("A"))
        XCTAssertNil(pair.tileID(atX: -1, y: -1))
    }
}
