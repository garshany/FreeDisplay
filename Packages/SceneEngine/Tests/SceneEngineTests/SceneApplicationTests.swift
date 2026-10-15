import XCTest
import DisplayDomain
@testable import SceneEngine

final class SceneApplicationTests: XCTestCase {
    private let desk = DisplayRecordID(rawValue: "cg:desk")
    private let laptop = DisplayRecordID(rawValue: "cg:laptop")
    private let wide = DisplayMode(pixelWidth: 2560, pixelHeight: 1440, pointWidth: 2560, pointHeight: 1440,
                                   refreshHz: 60, isHiDPI: false)
    private let small = DisplayMode(pixelWidth: 1920, pixelHeight: 1080, pointWidth: 1920, pointHeight: 1080,
                                    refreshHz: 60, isHiDPI: false)

    private func observation(_ id: DisplayRecordID, origin: DisplayOrigin = .zero, mode: DisplayMode? = nil,
                             main: Bool = false, active: Bool = true,
                             rotation: Rotation = .degrees0) -> DisplayObservation {
        DisplayObservation(recordID: id, isActive: active, origin: origin, mode: mode, rotation: rotation,
                           isMain: main, generation: .initial)
    }

    private func snapshot(_ observations: DisplayObservation...) -> TopologySnapshot {
        TopologySnapshot(generation: .initial, observations: observations)
    }

    private func outcome(_ report: SceneApplyReport, _ field: SceneApplyReport.Field,
                         _ id: DisplayRecordID) -> SceneApplyReport.Outcome? {
        report.entries.first { $0.field == field && $0.target == id }?.outcome
    }

    func testWritesOnlyTheFieldsThatDiffer() {
        let before = snapshot(observation(desk, origin: .zero, mode: small, main: true),
                              observation(laptop, origin: DisplayOrigin(x: -1512, y: 0), mode: small))
        let scene = Scene(id: "s", name: "Desk", members: [
            .init(selector: "id:cg:desk", required: false,
                  desired: DesiredState(position: .zero, mode: wide)),
            .init(selector: "id:cg:laptop", required: false,
                  desired: DesiredState(position: DisplayOrigin(x: -1512, y: 0), mode: small)),
        ])
        let prep = SceneApplication.prepare(scene: scene, resolution: ["id:cg:desk": desk, "id:cg:laptop": laptop],
                                            before: before)
        XCTAssertEqual(prep.writes, [.init(target: desk, origin: nil, mode: wide)])
        XCTAssertFalse(prep.isBlocked)
    }

    func testVerifiedAgainstTheTopologyAfterTheWrite() {
        let before = snapshot(observation(desk, origin: .zero, mode: small, main: true))
        let after = snapshot(observation(desk, origin: .zero, mode: wide, main: true))
        let scene = Scene(id: "s", name: "Desk", members: [
            .init(selector: "id:cg:desk", required: false, desired: DesiredState(main: true, position: .zero, mode: wide)),
        ])
        let resolution: ScenePlanner.Resolution = ["id:cg:desk": desk]
        let prep = SceneApplication.prepare(scene: scene, resolution: resolution, before: before)
        let report = SceneApplication.report(scene: scene, preparation: prep, resolution: resolution,
                                             before: before, after: after, providerWarnings: [])
        XCTAssertEqual(outcome(report, .mode, desk), .applied)
        XCTAssertEqual(outcome(report, .position, desk), .alreadySatisfied)
        XCTAssertEqual(outcome(report, .main, desk), .alreadySatisfied)
        XCTAssertEqual(report.status, .applied)
    }

    func testARejectedModeIsNotReportedAsApplied() {
        // The provider warned and the mode never changed: the old code printed "applied" anyway.
        let before = snapshot(observation(desk, mode: small, main: true))
        let scene = Scene(id: "s", name: "Desk", members: [
            .init(selector: "id:cg:desk", required: false, desired: DesiredState(position: .zero, mode: wide)),
        ])
        let resolution: ScenePlanner.Resolution = ["id:cg:desk": desk]
        let prep = SceneApplication.prepare(scene: scene, resolution: resolution, before: before)
        let report = SceneApplication.report(scene: scene, preparation: prep, resolution: resolution,
                                             before: before, after: before,
                                             providerWarnings: ["no matching mode for 1 (2560x1440@60)"])
        XCTAssertEqual(outcome(report, .mode, desk), .notApplied)
        XCTAssertEqual(report.entries.first { $0.field == .mode }?.observed, "1920x1080@60")
        XCTAssertEqual(report.providerWarnings, ["no matching mode for 1 (2560x1440@60)"])
        XCTAssertEqual(report.status, .partial)  // the position was already right
    }

    func testFieldsSceneApplyDoesNotExecuteAreSkippedUnlessAlreadyTrue() {
        let before = snapshot(observation(desk, main: true, rotation: .degrees0),
                              observation(laptop, active: true, rotation: .degrees90))
        let scene = Scene(id: "s", name: "Mixed", members: [
            .init(selector: "id:cg:desk", required: false,
                  desired: DesiredState(connected: true, rotation: .degrees0, brightness: 0.5, hdr: true)),
            .init(selector: "id:cg:laptop", required: false,
                  desired: DesiredState(connected: false, rotation: .degrees0, colorProfile: "Display P3")),
        ])
        let resolution: ScenePlanner.Resolution = ["id:cg:desk": desk, "id:cg:laptop": laptop]
        let prep = SceneApplication.prepare(scene: scene, resolution: resolution, before: before)
        XCTAssertTrue(prep.writes.isEmpty)
        let report = SceneApplication.report(scene: scene, preparation: prep, resolution: resolution,
                                             before: before, after: before, providerWarnings: [])
        XCTAssertEqual(outcome(report, .connected, desk), .alreadySatisfied)
        XCTAssertEqual(outcome(report, .rotation, desk), .alreadySatisfied)
        XCTAssertEqual(outcome(report, .brightness, desk), .skipped)
        XCTAssertEqual(outcome(report, .hdr, desk), .skipped)
        XCTAssertEqual(outcome(report, .connected, laptop), .skipped)   // disconnect isn't run by scenes
        XCTAssertEqual(outcome(report, .rotation, laptop), .skipped)
        XCTAssertEqual(outcome(report, .colorProfile, laptop), .skipped)
        XCTAssertEqual(report.status, .partial)
        XCTAssertEqual(report.problems.count, 5)
    }

    func testMainWithoutAPositionCanOnlyBeSkipped() {
        let before = snapshot(observation(desk, main: false), observation(laptop, main: true))
        let scene = Scene(id: "s", name: "Main", members: [
            .init(selector: "id:cg:desk", required: false, desired: DesiredState(main: true)),
        ])
        let resolution: ScenePlanner.Resolution = ["id:cg:desk": desk]
        let prep = SceneApplication.prepare(scene: scene, resolution: resolution, before: before)
        let report = SceneApplication.report(scene: scene, preparation: prep, resolution: resolution,
                                             before: before, after: before, providerWarnings: [])
        XCTAssertEqual(outcome(report, .main, desk), .skipped)
        XCTAssertEqual(report.status, .failed)
    }

    func testMissingRequiredMemberBlocksWithoutWriting() {
        let before = snapshot(observation(desk, mode: small))
        let scene = Scene(id: "s", name: "Two", members: [
            .init(selector: "id:cg:desk", required: false, desired: DesiredState(mode: wide)),
            .init(selector: "alias:Gone", required: true, desired: DesiredState(position: .zero)),
        ])
        let resolution: ScenePlanner.Resolution = ["id:cg:desk": desk]
        let prep = SceneApplication.prepare(scene: scene, resolution: resolution, before: before)
        XCTAssertTrue(prep.isBlocked)
        XCTAssertEqual(prep.missingRequired, ["alias:Gone"])
        let report = SceneApplication.report(scene: scene, preparation: prep, resolution: resolution,
                                             before: before, after: before, providerWarnings: [])
        XCTAssertEqual(report.status, .blocked)
        XCTAssertTrue(report.entries.isEmpty)
    }

    func testMissingOptionalMemberIsListedAndTheRestStillApplies() {
        let before = snapshot(observation(desk, mode: small))
        let after = snapshot(observation(desk, mode: wide))
        let scene = Scene(id: "s", name: "Two", members: [
            .init(selector: "id:cg:desk", required: false, desired: DesiredState(mode: wide)),
            .init(selector: "id:cg:laptop", required: false, desired: DesiredState(position: .zero)),
        ])
        // Resolved to a record the topology no longer has (unplugged): absent, not present.
        let resolution: ScenePlanner.Resolution = ["id:cg:desk": desk, "id:cg:laptop": laptop]
        let prep = SceneApplication.prepare(scene: scene, resolution: resolution, before: before)
        let report = SceneApplication.report(scene: scene, preparation: prep, resolution: resolution,
                                             before: before, after: after, providerWarnings: [])
        XCTAssertEqual(report.missingOptional, ["id:cg:laptop"])
        XCTAssertEqual(report.status, .applied)
    }

    func testEveryMemberAbsentIsAFailureNotNoChange() {
        let scene = Scene(id: "s", name: "Away", members: [
            .init(selector: "id:cg:desk", required: false, desired: DesiredState(position: .zero)),
        ])
        let empty = snapshot()
        let prep = SceneApplication.prepare(scene: scene, resolution: [:], before: empty)
        let report = SceneApplication.report(scene: scene, preparation: prep, resolution: [:],
                                             before: empty, after: empty, providerWarnings: [])
        XCTAssertEqual(report.status, .failed)
    }

    func testAlreadySatisfiedSceneIsNoChange() {
        let before = snapshot(observation(desk, origin: .zero, mode: small, main: true))
        let scene = SceneRecorder.capture(from: before, name: "Now", id: "now")
        let resolution = SceneRecorder.resolution(for: scene, in: before)
        let prep = SceneApplication.prepare(scene: scene, resolution: resolution, before: before)
        XCTAssertTrue(prep.writes.isEmpty)
        let report = SceneApplication.report(scene: scene, preparation: prep, resolution: resolution,
                                             before: before, after: before, providerWarnings: [])
        XCTAssertEqual(report.status, .noChange)
    }

    func testDisplayThatVanishesMidApplyIsNotApplied() {
        let before = snapshot(observation(desk, origin: DisplayOrigin(x: 100, y: 0)))
        let scene = Scene(id: "s", name: "Move", members: [
            .init(selector: "id:cg:desk", required: false, desired: DesiredState(position: .zero)),
        ])
        let resolution: ScenePlanner.Resolution = ["id:cg:desk": desk]
        let prep = SceneApplication.prepare(scene: scene, resolution: resolution, before: before)
        let report = SceneApplication.report(scene: scene, preparation: prep, resolution: resolution,
                                             before: before, after: snapshot(), providerWarnings: [])
        XCTAssertEqual(outcome(report, .position, desk), .notApplied)
        XCTAssertEqual(report.entries.first?.observed, "display disappeared")
        XCTAssertEqual(report.status, .failed)
    }

    // MARK: - Hostile numbers (a hand-edited scenes.json or settings archive)

    /// Reporting must never trap on a number from the file: these went through `Int(...)` and
    /// crashed the CLI after the arrangement had already been written.
    func testReportingHostileNumbersDoesNotTrap() {
        let huge = DisplayMode(pixelWidth: 2560, pixelHeight: 1440, pointWidth: 2560, pointHeight: 1440,
                               refreshHz: 1e30, isHiDPI: false)
        let before = snapshot(observation(desk, origin: .zero, mode: small, main: true))
        let scene = Scene(id: "s", name: "Hostile", members: [
            .init(selector: "id:cg:desk", required: false, desired: DesiredState(mode: huge, brightness: 1e30)),
        ])
        let resolution: ScenePlanner.Resolution = ["id:cg:desk": desk]
        let prep = SceneApplication.Preparation(writes: [], missingRequired: [], missingOptional: [])
        let report = SceneApplication.report(scene: scene, preparation: prep, resolution: resolution,
                                             before: before, after: before, providerWarnings: [])
        XCTAssertEqual(report.entries.first { $0.field == .mode }?.requested, "2560x1440@1000000000000000019884624838656.00")
        XCTAssertNotNil(report.entries.first { $0.field == .brightness })
        let plan = ScenePlanner().plan(scene: scene, snapshot: before, resolution: resolution)
        XCTAssertEqual(plan.operations.count, 2)
    }

    func testValuesThatCantBeUsedAreFound() {
        func member(_ selector: String, _ desired: DesiredState) -> Scene.Member {
            .init(selector: selector, required: false, desired: desired)
        }
        func mode(_ hz: Double) -> DisplayMode {
            DisplayMode(pixelWidth: 1920, pixelHeight: 1080, pointWidth: 1920, pointHeight: 1080,
                        refreshHz: hz, isHiDPI: false)
        }
        let hostile = Scene(id: "s", name: "Hostile", members: [
            member("a", DesiredState(brightness: 1e30)),
            member("b", DesiredState(brightness: .nan)),
            member("c", DesiredState(brightness: -0.01)),
            member("d", DesiredState(mode: mode(.infinity))),
            member("e", DesiredState(mode: mode(.nan))),
            member("f", DesiredState(mode: mode(-1))),
            member("g", DesiredState(position: DisplayOrigin(x: Int(Int32.max) + 1, y: 0))),
            member("h", DesiredState(position: DisplayOrigin(x: 0, y: Int.min))),
        ])
        XCTAssertEqual(hostile.invalidValues.map { "\($0.selector) \($0.field.rawValue)" },
                       ["a brightness", "b brightness", "c brightness", "d mode", "e mode", "f mode",
                        "g position", "h position"])
        let fine = Scene(id: "s", name: "Fine", members: [
            member("a", DesiredState(brightness: 0)),
            member("b", DesiredState(brightness: 1)),
            member("c", DesiredState(mode: mode(0))),
            member("d", DesiredState(mode: mode(1e300))),
            member("e", DesiredState(position: DisplayOrigin(x: Int(Int32.min), y: Int(Int32.max)))),
        ])
        XCTAssertEqual(fine.invalidValues, [])
    }

    /// A scene carrying a value that can't be used is refused whole, before any write — scene apply
    /// used to write the arrangement and only then trap while reporting.
    func testAValueThatCantBeUsedBlocksTheApplyBeforeAnyWrite() {
        let before = snapshot(observation(desk, origin: .zero, mode: small, main: true),
                              observation(laptop, origin: DisplayOrigin(x: -1512, y: 0), mode: small))
        let scene = Scene(id: "s", name: "Hostile", members: [
            .init(selector: "id:cg:desk", required: true, desired: DesiredState(mode: wide)),
            .init(selector: "id:cg:laptop", required: false, desired: DesiredState(brightness: 1e30)),
        ])
        let resolution: ScenePlanner.Resolution = ["id:cg:desk": desk, "id:cg:laptop": laptop]
        let prep = SceneApplication.prepare(scene: scene, resolution: resolution, before: before)
        XCTAssertTrue(prep.isBlocked)
        XCTAssertEqual(prep.writes, [])
        XCTAssertEqual(prep.invalidValues, [.init(selector: "id:cg:laptop", field: .brightness)])
        let report = SceneApplication.report(scene: scene, preparation: prep, resolution: resolution,
                                             before: before, after: before, providerWarnings: [])
        XCTAssertEqual(report.status, .blocked)
        XCTAssertEqual(report.entries, [])
        XCTAssertEqual(report.invalidValues, prep.invalidValues)
        XCTAssertEqual(report.missingRequired, [])
    }
}
