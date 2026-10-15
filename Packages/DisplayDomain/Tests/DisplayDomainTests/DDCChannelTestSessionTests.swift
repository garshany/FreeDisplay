import XCTest
@testable import DisplayDomain

final class DDCChannelTestSessionTests: XCTestCase {
    @MainActor
    func testQuitCancelsHoldAndWaitsForOriginalBrightnessWrite() async {
        let session = DDCChannelTestSession()
        let holding = expectation(description: "temporary brightness is active")
        let restored = expectation(description: "restore completed before quit")
        var writes: [Int] = []
        var holdWasCancelled = false
        let task = Task { @MainActor in
            await session.run {
                await DDCChannelTest.run(parameters: .init(levelPercent: 0, durationSeconds: 30)!,
                    read: { (current: 73, max: 100) },
                    write: { value in
                        writes.append(value)
                        if value == 73 { restored.fulfill() }
                        return true
                    },
                    hold: {
                        holding.fulfill()
                        try? await Task.sleep(for: .seconds(30))
                        holdWasCancelled = Task.isCancelled
                    })
            }
        }
        await fulfillment(of: [holding])
        XCTAssertTrue(session.isRunning)
        await session.cancelAndRestore()
        XCTAssertEqual(writes, [0, 73])
        XCTAssertTrue(holdWasCancelled)
        await fulfillment(of: [restored])
        let outcome = await task.value
        XCTAssertEqual(outcome, .flashed(original: 73, flashLevel: 0, restored: true))
        XCTAssertFalse(session.isRunning)
    }
}
