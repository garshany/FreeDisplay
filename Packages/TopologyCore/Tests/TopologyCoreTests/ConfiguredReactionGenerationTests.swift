import XCTest
@testable import TopologyCore

final class ConfiguredReactionGenerationTests: XCTestCase {
    func testRearmWhileRefreshIsSuspendedRejectsOldRunBeforeMutation() async {
        var generation = ConfiguredReactionGeneration()
        let oldRun = generation.invalidate()
        XCTAssertTrue(generation.isCurrent(oldRun))
        // Deterministic fake refresh: a newer event arrives during its suspension point.
        let newerRun = await rearmDuringRefresh(&generation)
        var mutations = 0
        if generation.isCurrent(oldRun) { mutations += 1 }
        XCTAssertEqual(mutations, 0)
        XCTAssertTrue(generation.isCurrent(newerRun))
        if generation.isCurrent(newerRun) { mutations += 1 }
        XCTAssertEqual(mutations, 1)
        generation.invalidate() // sleep/quit cancellation also revokes already-started work
        XCTAssertFalse(generation.isCurrent(newerRun))
    }

    private func rearmDuringRefresh(_ generation: inout ConfiguredReactionGeneration) async -> UUID {
        generation.invalidate()
    }

    func testStaleRunCannotConsumeArrivalOwedToLatestRun() {
        var generation = ConfiguredReactionGeneration()
        var arrival = AutoDisconnectBuiltInPolicy()
        let oldRun = generation.invalidate()
        arrival.observe(enabled: true, externalPresent: true, suppressed: false)
        let newRun = generation.invalidate()
        if generation.isCurrent(oldRun) { _ = arrival.takePendingArrival() }
        XCTAssertTrue(generation.isCurrent(newRun))
        XCTAssertTrue(arrival.takePendingArrival())
    }
}
