import XCTest
import DisplayDomain
import ProviderInterfaces
import SimulatorProvider
@testable import TopologyCore

private actor LastCheckpointStore: CheckpointStoring {
    private var last: Checkpoint?
    func writeAtomic(_ checkpoint: Checkpoint) async throws { last = checkpoint }
    func restore(_ id: CheckpointID) async throws -> Checkpoint? { last?.id == id ? last : nil }
    func latest() async -> Checkpoint? { last }
}

/// Black Out reaches the lifecycle safeguards (R1 P0): a blacked-out screen is no safe surface for a
/// disconnect, and no screen for the always-one-active net.
final class BlackOutSafetyTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let a = DisplayRecordID(rawValue: "a")
    private let b = DisplayRecordID(rawValue: "b")

    private func obs(_ id: DisplayRecordID, main: Bool = false,
                     klass: DisplayClass = .external) -> DisplayObservation {
        DisplayObservation(recordID: id, isActive: true, isMain: main, displayClass: klass,
                           physicalPresence: .physical, generation: .initial)
    }

    private func coordinator(_ observer: any TopologyObserving,
                             _ system: SimulatedDisplaySystem) -> TopologyCoordinator {
        TopologyCoordinator(observer: observer, lifecycleProvider: system,
                            checkpoints: LastCheckpointStore(), confirm: { _, _ in true })
    }

    func testDisconnectingTheOtherScreenIsBlockedWhileTheRemainingOneIsBlackedOut() async throws {
        let system = SimulatedDisplaySystem(observations: [obs(a, main: true), obs(b)])
        let observer = BlackOutAwareObserver(base: system)
        observer.setBlackedOut([a])
        let result = try await coordinator(observer, system).disconnect(
            b, options: .init(actor: .ui, identityConfidence: 1.0))
        XCTAssertEqual(result, .blocked([.noSafeSurface]))
        let snapshot = await system.currentSnapshot()
        XCTAssertEqual(snapshot.observation(for: b)?.isActive, true, "nothing was written")
    }

    func testTheSameDisconnectProceedsOnceTheBlackOutIsLifted() async throws {
        let system = SimulatedDisplaySystem(observations: [obs(a, main: true), obs(b)])
        let observer = BlackOutAwareObserver(base: system)
        observer.setBlackedOut([a])
        observer.setBlackedOut([])
        let result = try await coordinator(observer, system).disconnect(
            b, options: .init(actor: .ui, identityConfidence: 1.0))
        guard case .committed = result else { return XCTFail("expected committed, got \(result)") }
    }

    func testTheWrapperStampsEverySnapshotItHandsOut() async {
        let system = SimulatedDisplaySystem(observations: [obs(a), obs(b)])
        let observer = BlackOutAwareObserver(base: system)
        observer.setBlackedOut([b])
        let current = await observer.currentSnapshot()
        XCTAssertEqual(current.observation(for: a)?.overlay, .visible)
        XCTAssertEqual(current.observation(for: b)?.overlay, .blackedOut)
        let stable = await observer.awaitStableGeneration(after: .initial)
        XCTAssertEqual(stable.observation(for: b)?.overlay, .blackedOut)
    }

    func testABlackedOutScreenDoesNotSatisfyTheNet() {
        let observations = BlackOutPolicy.stamping([a], into: [obs(a)])
        XCTAssertTrue(WakeConvergencePolicy.recoverySurfaces(in: observations).isEmpty)
        let context = WakeConvergencePolicy.Context(now: epoch, observations: observations)
        XCTAssertNotEqual(WakeConvergencePolicy.surfaceDecision(context), .satisfied)
        XCTAssertEqual(WakeConvergencePolicy.recoverySurfaces(in: [obs(a)]).map(\.recordID), [a],
                       "unstamped, the same screen still counts")
    }

    func testABlackedOutScreenDoesNotCoverAnOwedOff() {
        let builtIn = DisplayRecordID(rawValue: "builtin")
        let offline = ManagedOfflineDisplay(recordID: builtIn, cgID: 1, name: "Built-in", displayClass: .builtIn)
        let lit = [obs(builtIn, klass: .builtIn), obs(a)]
        func intent(_ observations: [DisplayObservation]) -> WakeConvergencePolicy.OfflineIntent {
            WakeConvergencePolicy.offlineIntent(.init(now: epoch, observations: observations,
                                                      managedOffline: [offline], lastWakeAt: epoch))
        }
        XCTAssertEqual(intent(lit).reassert.map(\.recordID), [builtIn], "a lit external covers it")
        XCTAssertTrue(intent(BlackOutPolicy.stamping([a], into: lit)).reassert.isEmpty,
                      "a blacked-out external doesn't")
    }

    private func netContext(_ observations: [DisplayObservation], blackedOut: Set<DisplayRecordID>,
                            darkForSeconds: TimeInterval, offline: [ManagedOfflineDisplay] = [],
                            wokeSecondsAgo: TimeInterval? = nil) -> WakeConvergencePolicy.Context {
        WakeConvergencePolicy.Context(now: epoch, observations: BlackOutPolicy.stamping(blackedOut, into: observations),
                                      managedOffline: offline,
                                      lastWakeAt: wokeSecondsAgo.map { epoch.addingTimeInterval(-$0) },
                                      darkSince: epoch.addingTimeInterval(-darkForSeconds))
    }

    func testTheNetLiftsBlackOutWhenTheOtherScreenIsGone() {
        // b was unplugged (or turned off from another process), outside any wake: lift at once.
        XCTAssertEqual(WakeConvergencePolicy.blackOutRescue(
            netContext([obs(a)], blackedOut: [a], darkForSeconds: 0), blackedOut: [a]), .lift([a]))
        // A turned-off built-in in the ledger changes nothing: the blackout is the cheaper rescue.
        let builtIn = ManagedOfflineDisplay(recordID: DisplayRecordID(rawValue: "builtin"), cgID: 1,
                                            name: "Built-in", displayClass: .builtIn)
        XCTAssertEqual(WakeConvergencePolicy.blackOutRescue(
            netContext([obs(a)], blackedOut: [a], darkForSeconds: 0, offline: [builtIn]), blackedOut: [a]),
                       .lift([a]))
    }

    func testTheNetWaitsForAScreenOnItsWayBackWithinTheDeadline() {
        let deadline = WakeConvergencePolicy.defaultRecoveryDeadline
        let step = WakeConvergencePolicy.defaultRecheckStep
        // b is still enumerated but dark (renegotiating its link): wait, as for anything else.
        let renegotiating = DisplayObservation(recordID: b, isActive: false, displayClass: .external,
                                               physicalPresence: .physical, generation: .initial)
        XCTAssertEqual(WakeConvergencePolicy.blackOutRescue(
            netContext([obs(a), renegotiating], blackedOut: [a], darkForSeconds: 0), blackedOut: [a]),
                       .wait(step))
        // Just woke, b not back yet: the wake gets the benefit of the doubt.
        XCTAssertEqual(WakeConvergencePolicy.blackOutRescue(
            netContext([obs(a)], blackedOut: [a], darkForSeconds: 1, wokeSecondsAgo: 1), blackedOut: [a]),
                       .wait(step), "a wake doesn't end the blackout while the external trains its link")
        // The deadline is the net's own: past it, lift.
        XCTAssertEqual(WakeConvergencePolicy.blackOutRescue(
            netContext([obs(a), renegotiating], blackedOut: [a], darkForSeconds: deadline + 1), blackedOut: [a]),
                       .lift([a]))
    }

    func testTheNetLeavesBlackOutAloneWhileAnotherScreenIsLit() {
        XCTAssertEqual(WakeConvergencePolicy.blackOutRescue(
            netContext([obs(a), obs(b)], blackedOut: [a], darkForSeconds: 60), blackedOut: [a]), .none)
        XCTAssertEqual(WakeConvergencePolicy.blackOutRescue(
            netContext([obs(a)], blackedOut: [], darkForSeconds: 60), blackedOut: []), .none)
    }

    func testAMirrorOfABlackedOutScreenIsNoScreenEither() {
        let mirror = DisplayObservation(recordID: b, isActive: true, mirrorSourceID: a, displayClass: .external,
                                        physicalPresence: .physical, generation: .initial)
        XCTAssertEqual(WakeConvergencePolicy.blackOutRescue(
            netContext([obs(a), mirror], blackedOut: [a], darkForSeconds: 0), blackedOut: [a]), .lift([a]))
    }

    func testTheNetsLiftIsAudited() {
        let entry = WakeConvergencePolicy.netLiftBlackOutAudit(of: [b, a], at: epoch)
        XCTAssertEqual(entry.command, WakeConvergencePolicy.netLiftBlackOutAuditCommand)
        XCTAssertEqual(entry.targets, ["a", "b"])
        XCTAssertEqual(entry.status, "committed")
    }
}
