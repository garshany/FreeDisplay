import XCTest
import DisplayDomain
@testable import TopologyCore

/// AM-02 / SD-07: virtual and unverified screens never stand in for a physical one — not in
/// lifecycle preflight, not in the always-one-active net, not as the screen that covers an "off".
final class RecoverySafeguardTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func obs(_ id: String, active: Bool = true, main: Bool = false,
                     klass: DisplayClass = .external, presence: PhysicalPresence?) -> DisplayObservation {
        DisplayObservation(recordID: DisplayRecordID(rawValue: id), cgDisplayID: 1, isActive: active,
                           isMain: main, displayClass: klass, physicalPresence: presence, generation: .initial)
    }

    private var builtIn: DisplayObservation { obs("builtin", main: true, klass: .builtIn, presence: .physical) }
    /// One of OpenDisplay's own endpoints — a HiDPI one, which the single-mode test never caught. The
    /// provider keeps its `.external` class; only its presence says what it is.
    private var ourVirtual: DisplayObservation { obs("ours", presence: .virtual) }
    /// BetterDisplay / DisplayLink / Sidecar: looks like a monitor, no hardware behind it.
    private var thirdParty: DisplayObservation { obs("displaylink", presence: .unverified) }

    private func offline(_ id: String, klass: DisplayClass = .builtIn) -> ManagedOfflineDisplay {
        ManagedOfflineDisplay(recordID: DisplayRecordID(rawValue: id), cgID: 9, name: id, displayClass: klass)
    }

    // MARK: - Lifecycle preflight

    func testTheBuiltInCantBeDisconnectedWhenOnlyVirtualScreensWouldRemain() {
        for other in [ourVirtual, thirdParty] {
            let snapshot = TopologySnapshot(generation: .initial, observations: [builtIn, other])
            let decision = SafetyEngine().preflightDisconnect(
                target: builtIn.recordID, snapshot: snapshot, identityConfidence: 1,
                recoveryServiceHealthy: true, isFirstUseForRoute: false)
            XCTAssertEqual(decision, .blocked(reasons: [.noSafeSurface]), "\(other.recordID)")
        }
    }

    func testAPhysicalExternalStillCountsBesideAVirtualScreen() {
        let monitor = obs("monitor", presence: .physical)
        let snapshot = TopologySnapshot(generation: .initial, observations: [builtIn, ourVirtual, monitor])
        XCTAssertEqual(SafetyEngine().safeSurface(in: snapshot, excluding: [builtIn.recordID]), monitor.recordID)
    }

    // MARK: - The always-one-active net

    private func context(_ observations: [DisplayObservation], offline: [ManagedOfflineDisplay] = [],
                         wokeSecondsAgo: TimeInterval? = nil,
                         darkForSeconds: TimeInterval? = nil) -> WakeConvergencePolicy.Context {
        WakeConvergencePolicy.Context(now: epoch, observations: observations, managedOffline: offline,
                                      lastWakeAt: wokeSecondsAgo.map { epoch.addingTimeInterval(-$0) },
                                      darkSince: darkForSeconds.map { epoch.addingTimeInterval(-$0) })
    }

    /// The built-in is off and the last physical external went away; only our own virtual screen is
    /// left lit. It used to satisfy the net, which then never lit anything.
    func testOurLitVirtualScreenDoesNotSatisfyTheNet() {
        XCTAssertEqual(WakeConvergencePolicy.surfaceDecision(context([ourVirtual], offline: [offline("builtin")])),
                       .restore(offline("builtin")), "a known-virtual screen gets no benefit of the doubt")
    }

    /// An unverified screen may be a monitor whose hardware node isn't readable yet, so the net waits —
    /// but never past its deadline, after which the built-in comes back whatever the list claims.
    func testAnUnverifiedScreenGetsOnlyTheBoundedWait() {
        XCTAssertEqual(WakeConvergencePolicy.surfaceDecision(
            context([thirdParty], offline: [offline("builtin")], darkForSeconds: 1)),
            .waitForWakingDisplay(WakeConvergencePolicy.defaultRecheckStep))
        XCTAssertEqual(WakeConvergencePolicy.surfaceDecision(
            context([thirdParty], offline: [offline("builtin")],
                    darkForSeconds: WakeConvergencePolicy.defaultRecoveryDeadline)),
            .restore(offline("builtin")))
    }

    func testAPhysicalScreenSatisfiesTheNetBesideVirtualOnes() {
        XCTAssertEqual(WakeConvergencePolicy.surfaceDecision(
            context([ourVirtual, thirdParty, obs("monitor", presence: .physical)], offline: [offline("builtin")])),
            .satisfied)
    }

    func testAVirtualScreenCannotCoverTheBuiltInGoingBackOff() {
        let relitBuiltIn = obs("builtin", klass: .builtIn, presence: .physical)
        let intent = WakeConvergencePolicy.offlineIntent(
            context([relitBuiltIn, thirdParty], offline: [offline("builtin")], wokeSecondsAgo: 2))
        XCTAssertTrue(intent.reassert.isEmpty)
        XCTAssertNotNil(intent.recheckAfter)
    }
}
