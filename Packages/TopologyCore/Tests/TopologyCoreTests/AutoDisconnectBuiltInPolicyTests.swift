import DisplayDomain
import XCTest
@testable import TopologyCore

final class AutoDisconnectBuiltInPolicyTests: XCTestCase {
    func testDebouncedUnplugReconnectRetainsArrivalUntilExecution() {
        var policy = AutoDisconnectBuiltInPolicy(externalPresent: true)
        policy.observe(enabled: true, externalPresent: false, suppressed: false)
        policy.observe(enabled: true, externalPresent: true, suppressed: false)
        policy.observe(enabled: true, externalPresent: true, suppressed: false)
        XCTAssertTrue(policy.takePendingArrival())
        XCTAssertFalse(policy.takePendingArrival())
    }

    func testPendingArrivalIsCancelledByAbsenceDisableOrSafeStartup() {
        for reason in 0..<3 {
            var policy = AutoDisconnectBuiltInPolicy()
            policy.observe(enabled: true, externalPresent: true, suppressed: false)
            policy.observe(enabled: reason != 0, externalPresent: reason != 1, suppressed: reason == 2)
            XCTAssertFalse(policy.takePendingArrival())
        }
        var policy = AutoDisconnectBuiltInPolicy()
        policy.observe(enabled: true, externalPresent: true, suppressed: true)
        policy.observe(enabled: true, externalPresent: true, suppressed: false)
        XCTAssertFalse(policy.takePendingArrival())
    }

    func testFiresOnFirstExternalArrivalWhenEnabled() {
        var policy = AutoDisconnectBuiltInPolicy()
        XCTAssertTrue(policy.onTopologyChange(enabled: true, externalPresent: true))
    }

    func testDoesNotFireWhenDisabled() {
        var policy = AutoDisconnectBuiltInPolicy()
        XCTAssertFalse(policy.onTopologyChange(enabled: false, externalPresent: true))
        // ...and after later enabling, a *steady* external (no new edge) still doesn't fire.
        XCTAssertFalse(policy.onTopologyChange(enabled: true, externalPresent: true))
    }

    func testSecondExternalDoesNotReTrigger() {
        var policy = AutoDisconnectBuiltInPolicy()
        XCTAssertTrue(policy.onTopologyChange(enabled: true, externalPresent: true))   // first arrives → fire
        // A second external: presence is still "some" → no new rising edge.
        XCTAssertFalse(policy.onTopologyChange(enabled: true, externalPresent: true))
    }

    func testDisconnectingBuiltInDoesNotReTrigger() {
        // After firing, turning the built-in off raises another topology change, but the external is
        // still present (presence stays true) so the policy must not fire again.
        var policy = AutoDisconnectBuiltInPolicy()
        XCTAssertTrue(policy.onTopologyChange(enabled: true, externalPresent: true))
        XCTAssertFalse(policy.onTopologyChange(enabled: true, externalPresent: true))
    }

    func testReArmsAfterAllExternalsLeave() {
        var policy = AutoDisconnectBuiltInPolicy()
        XCTAssertTrue(policy.onTopologyChange(enabled: true, externalPresent: true))    // arrive → fire
        XCTAssertFalse(policy.onTopologyChange(enabled: true, externalPresent: false))  // all leave
        XCTAssertTrue(policy.onTopologyChange(enabled: true, externalPresent: true))    // new arrival → fire again
    }

    func testSeedSuppressesPreexistingExternalAsArrival() {
        // Launch with an external already attached: seed so the first observed change isn't an "edge".
        var policy = AutoDisconnectBuiltInPolicy()
        policy.seed(externalPresent: true)
        XCTAssertFalse(policy.onTopologyChange(enabled: true, externalPresent: true))
        // A genuine unplug+replug still fires.
        XCTAssertFalse(policy.onTopologyChange(enabled: true, externalPresent: false))
        XCTAssertTrue(policy.onTopologyChange(enabled: true, externalPresent: true))
    }

    func testArrivalWhileDisabledIsTrackedSoLaterEnableDoesNotFireOnSteadyState() {
        var policy = AutoDisconnectBuiltInPolicy()
        // External arrives while the policy is off — tracked but not fired.
        XCTAssertFalse(policy.onTopologyChange(enabled: false, externalPresent: true))
        // Now enabled, but the external didn't *just* arrive → no fire.
        XCTAssertFalse(policy.onTopologyChange(enabled: true, externalPresent: true))
        // It leaves and comes back while enabled → fires.
        XCTAssertFalse(policy.onTopologyChange(enabled: true, externalPresent: false))
        XCTAssertTrue(policy.onTopologyChange(enabled: true, externalPresent: true))
    }

    func testNoExternalNeverFires() {
        var policy = AutoDisconnectBuiltInPolicy()
        XCTAssertFalse(policy.onTopologyChange(enabled: true, externalPresent: false))
        XCTAssertFalse(policy.onTopologyChange(enabled: true, externalPresent: false))
    }

    /// On a wake the external's re-arrival edge can fire this policy before the wake re-assert gets
    /// its turn — an unaudited firing there reads as the re-assert acting silently. So a firing is
    /// audited like every other automatic display write.
    func testAFiringIsAudited() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = AutoDisconnectBuiltInPolicy.auditEntry(
            builtIn: DisplayRecordID(rawValue: "builtin"), committed: true, at: now)
        XCTAssertEqual(entry.actor, .system)
        XCTAssertEqual(entry.command, "autoDisconnect")
        XCTAssertEqual(entry.transactionId, "txn_autoDisconnect")
        XCTAssertEqual(entry.status, "committed")
        XCTAssertEqual(entry.targets, ["builtin"])
        XCTAssertEqual(entry.timestamp, now)
        XCTAssertEqual(AutoDisconnectBuiltInPolicy.auditEntry(
            builtIn: DisplayRecordID(rawValue: "builtin"), committed: false, at: now).status,
                       "failed")
    }
}
