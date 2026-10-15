import XCTest
@testable import AutomationSchema

@MainActor final class CoalescedWriterOwnershipTests: XCTestCase {
    func testOldBindingCompletionCannotInvalidateReplacementReceiptForEitherControl() async throws {
        for control in ["brightness", "contrast"] {
            let writers = CoalescedWriterOwnership<String>()
            let receipts = CoalescedBrightnessReceipts<String>()
            let old = writers.begin(control)
            receipts.enqueue(BrightnessWriteReceipt(.minimum), for: control)
            // Pruning cancels the task while detached binding remains outstanding.
            writers.invalidate(control)
            receipts.invalidate(control)
            let replacement = writers.begin(control)
            let receipt = BrightnessWriteReceipt(.maximum)
            receipts.enqueue(receipt, for: control)
            var sharedWriterCleared = false
            // The old binding returns after the replacement queued its own binding/receipt.
            writers.finish(old, for: control) {
                receipts.invalidate(control)
                sharedWriterCleared = true
            }
            XCTAssertFalse(sharedWriterCleared)
            XCTAssertFalse(writers.isCurrent(old, for: control))
            XCTAssertTrue(writers.isCurrent(replacement, for: control))
            let pending = try XCTUnwrap(receipts.take(control))
            XCTAssertTrue(pending === receipt)
            XCTAssertTrue(pending.admitDispatch())
            pending.complete(accepted: true, readback: .ddc(current: 100, max: 100))
            let report = await receipt.report()
            XCTAssertTrue(report.accepted)
            writers.finish(replacement, for: control) { sharedWriterCleared = true }
            XCTAssertTrue(sharedWriterCleared)
        }
    }

    func testCurrentWriterFailureStillRejectsItsOwnPendingReceipt() async {
        let writers = CoalescedWriterOwnership<String>()
        let receipts = CoalescedBrightnessReceipts<String>()
        let writer = writers.begin("brightness")
        let receipt = BrightnessWriteReceipt(.maximum)
        receipts.enqueue(receipt, for: "brightness")
        writers.finish(writer, for: "brightness") { receipts.invalidate("brightness") }
        let report = await receipt.report()
        XCTAssertFalse(report.accepted)
        XCTAssertTrue(report.failure?.contains("cancelled") == true)
    }
}
