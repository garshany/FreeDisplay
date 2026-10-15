import DisplayDomain
import XCTest
@testable import TopologyCore

final class MirroringChangePlanTests: XCTestCase {
    private func display(_ uuid: String?, number: UInt32, mirrors: String? = nil, main: Bool = false) -> DisplayObservation {
        .init(recordID: .init(rawValue: "cg-\(number)"), cgDisplayID: number, cgUUID: uuid,
              isActive: true, isMain: main, mirrorSourceID: mirrors.map(DisplayRecordID.init(rawValue:)),
              displayClass: .external, generation: .initial)
    }

    func testMultiDisplayUnmirroringRequiresOneConfirmationAndKeepsOriginalRollbackSnapshot() throws {
        let main = display("main", number: 1, main: true)
        let before = [main, display("a", number: 2, mirrors: "cg-1"), display("b", number: 3, mirrors: "cg-1")]
        let plan = try XCTUnwrap(MirroringChangePlan(targets: Array(before.dropFirst()), source: nil))
        var current = before
        let applied = plan.apply(read: { current }, write: { number, source in
            XCTAssertNil(source)
            let index = current.firstIndex { $0.cgDisplayID == number }!
            current[index].mirrorSourceID = nil
            return true
        })
        XCTAssertEqual(plan.outcome(accepted: applied, current: current), .awaitingConfirmation)
        var gate = TimedRevertGate(before: before, deadline: Date(timeIntervalSince1970: 10))
        XCTAssertTrue(gate.isPending)
        XCTAssertEqual(gate.tick(now: Date(timeIntervalSince1970: 10)), before)
        XCTAssertEqual(plan.outcome(accepted: true, current: before), .restorePrevious)
        XCTAssertEqual(plan.outcome(accepted: false, current: current), .restorePrevious)
    }

    func testNextWriteRejectsReplacementReusingNumericID() throws {
        let a = display("a", number: 2, mirrors: "cg-1")
        let b = display("b", number: 3, mirrors: "cg-1")
        let plan = try XCTUnwrap(MirroringChangePlan(targets: [a, b], source: nil))
        var current = [a, b]
        var writes: [UInt32] = []
        XCTAssertFalse(plan.apply(read: { current }, write: { number, _ in
            writes.append(number)
            current[1] = self.display("replacement", number: 3)
            return true
        }))
        XCTAssertEqual(writes, [2])
        XCTAssertEqual(plan.outcome(accepted: true, current: current), .restorePrevious)
    }

    func testUUIDResolvesNewNumberAndRejectsMissingOrAmbiguousIdentityAndSource() throws {
        let old = display("target", number: 2)
        let source = display("source", number: 1, main: true)
        let plan = try XCTUnwrap(MirroringChangePlan(targets: [old], source: source))
        var writes: [UInt32] = []
        XCTAssertTrue(plan.apply(read: { [self.display("target", number: 9), source] }, write: { number, main in
            writes.append(number)
            XCTAssertEqual(main, 1)
            return true
        }))
        XCTAssertEqual(writes, [9])
        for current in [[old], [old, source, display("target", number: 3)],
                        [old, source, display("source", number: 4)],
                        [old, source, display("replacement", number: 2)]] {
            XCTAssertFalse(plan.apply(read: { current }, write: { _, _ in XCTFail("Ambiguous or missing identity"); return true }))
        }
        XCTAssertNil(MirroringChangePlan(targets: [display(nil, number: 2)], source: nil))
    }
}
