import XCTest
import DisplayDomain
@testable import TopologyCore

final class ArrangementTilesTests: XCTestCase {
    private let mode = DisplayMode(pixelWidth: 1920, pixelHeight: 1080, pointWidth: 1920, pointHeight: 1080,
                                   refreshHz: 60, isHiDPI: false)

    private func obs(_ id: String, active: Bool = true, mirror: String? = nil, hasMode: Bool = true,
                     cgID: UInt32? = 1) -> DisplayObservation {
        DisplayObservation(recordID: .init(rawValue: id), cgDisplayID: cgID, isActive: active,
                           mode: hasMode ? mode : nil, mirrorSourceID: mirror.map { .init(rawValue: $0) },
                           generation: .initial)
    }

    func testAMirrorSetHasOneTileTheSourceCarryingItsTargets() {
        let tiles = ArrangementTiles.tiles(for: [obs("A"), obs("B", mirror: "A"), obs("C", mirror: "A"), obs("D")])
        XCTAssertEqual(tiles.map(\.display.recordID.rawValue), ["A", "D"])
        XCTAssertEqual(tiles[0].mirrorTargets.map(\.rawValue), ["B", "C"])
        XCTAssertEqual(tiles[1].mirrorTargets, [])
    }

    func testInactiveAndModelessDisplaysGetNoTile() {
        let tiles = ArrangementTiles.tiles(for: [obs("A"), obs("B", active: false), obs("C", hasMode: false)])
        XCTAssertEqual(tiles.map(\.display.recordID.rawValue), ["A"])
    }

    func testADropIsRefusedForADisplayThatBecameAMirrorTargetOrLeft() {
        let snapshot = TopologySnapshot(generation: .initial,
                                        observations: [obs("A"), obs("B", mirror: "A"), obs("C", active: false),
                                                       obs("E", cgID: nil)])
        XCTAssertTrue(ArrangementTiles.canMove(.init(rawValue: "A"), in: snapshot))
        XCTAssertFalse(ArrangementTiles.canMove(.init(rawValue: "B"), in: snapshot))
        XCTAssertFalse(ArrangementTiles.canMove(.init(rawValue: "C"), in: snapshot))
        XCTAssertFalse(ArrangementTiles.canMove(.init(rawValue: "D"), in: snapshot))
        XCTAssertFalse(ArrangementTiles.canMove(.init(rawValue: "E"), in: snapshot))
    }
}
