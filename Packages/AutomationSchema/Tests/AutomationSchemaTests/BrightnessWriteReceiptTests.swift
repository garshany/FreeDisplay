import DisplayDomain
import XCTest
@testable import AutomationSchema

@MainActor final class BrightnessWriteReceiptTests: XCTestCase {
    func testFailedRequestCannotBorrowLaterSuccessfulReceipt() async throws {
        let slots = CoalescedBrightnessReceipts<String>()
        let a = BrightnessWriteReceipt(.init(normalized: 0.2)!)
        slots.enqueue(a, for: "brightness")
        let dispatchedA = try XCTUnwrap(slots.take("brightness"))
        let b = BrightnessWriteReceipt(.init(normalized: 0.8)!)
        slots.enqueue(b, for: "brightness")
        dispatchedA.complete(accepted: false, readback: .none)
        let dispatchedB = try XCTUnwrap(slots.take("brightness"))
        dispatchedB.complete(accepted: true, readback: .ddc(current: 80, max: 100))
        // A late coalescing/readback completion cannot overwrite the transport failure.
        dispatchedA.complete(accepted: true, readback: .ddc(current: 80, max: 100))
        let resultA = await a.report(), resultB = await b.report()
        XCTAssertFalse(resultA.accepted); XCTAssertEqual(resultA.readback, .none)
        XCTAssertEqual(BrightnessSettlement.settle(resultA).outcome, .failed)
        XCTAssertEqual(BrightnessSettlement.settle(resultB).outcome, .verified)
    }
    func testPendingAndReadbackSupersessionAreExplicitForBothControls() async throws {
        for key in ["brightness", "contrast"] {
            let slots = CoalescedBrightnessReceipts<String>()
            let a = BrightnessWriteReceipt(.minimum), b = BrightnessWriteReceipt(.maximum)
            slots.enqueue(a, for: key); slots.enqueue(b, for: key)
            let first = await a.report()
            XCTAssertFalse(first.accepted); XCTAssertTrue(first.failure?.contains("superseded") == true)
            let dispatched = try XCTUnwrap(slots.take(key))
            dispatched.reject()
            dispatched.complete(accepted: true, readback: .none)
            let second = await b.report()
            XCTAssertFalse(second.accepted); XCTAssertTrue(second.failure?.contains("superseded") == true)
        }
    }
    func testCallerCancellationVetoesTransportQueuedOnAnotherTask() async {
        let receipt = BrightnessWriteReceipt(.maximum)
        let caller = Task { await receipt.report() }
        caller.cancel()
        // Let the cancelled caller install its handler; transport belongs to a separate writer.
        await Task.yield()
        let writer = Task { receipt.admitDispatch() }
        let admitted = await writer.value
        XCTAssertFalse(admitted)
        if admitted { receipt.complete(accepted: true, readback: .none) }
        let report = await caller.value
        XCTAssertFalse(report.accepted); XCTAssertTrue(report.failure?.contains("cancelled") == true)
    }
    func testWaitingRequestsReceiveTheirOwnReadback() async {
        let a = BrightnessWriteReceipt(.minimum), b = BrightnessWriteReceipt(.maximum)
        let waiterA = Task { await a.report() }, waiterB = Task { await b.report() }
        await Task.yield()
        b.complete(accepted: true, readback: .ddc(current: 100, max: 100))
        a.complete(accepted: true, readback: .ddc(current: 0, max: 100))
        let first = await waiterA.value, second = await waiterB.value
        XCTAssertEqual(first.readback, .ddc(current: 0, max: 100))
        XCTAssertEqual(second.readback, .ddc(current: 100, max: 100))
    }
    func testInvalidatedGenerationVetoesQueuedTransport() async {
        let generation = AutomationExecutionGeneration(), token = generation.current
        let receipt = BrightnessWriteReceipt(.maximum, beforeDispatch: { generation.issue(for: token) })
        generation.invalidate()
        XCTAssertFalse(receipt.admitDispatch())
        let result = await receipt.report()
        XCTAssertFalse(result.accepted)
        XCTAssertTrue(result.failure?.contains("configuration changed") == true)
    }
}
