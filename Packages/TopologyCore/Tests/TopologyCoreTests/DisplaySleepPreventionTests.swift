import XCTest
import DisplayDomain
@testable import TopologyCore

/// Records creates and releases so a test can see exactly which assertion is held.
private final class RecordingAssertions: PowerAssertionControlling, @unchecked Sendable {
    private(set) var created: [String] = []
    private(set) var released: [UInt32] = []
    private(set) var live: Set<UInt32> = []
    var refuse = false
    private var next: UInt32 = 100

    func createPreventDisplaySleepAssertion(named name: String) -> UInt32? {
        created.append(name)
        guard !refuse else { return nil }
        next += 1
        live.insert(next)
        return next
    }

    func releaseAssertion(_ handle: UInt32) {
        released.append(handle)
        live.remove(handle)
    }
}

/// FB-12 / AM-42: who keeps the displays awake, and that only lit, real displays ever do.
final class DisplaySleepPreventionTests: XCTestCase {
    private let builtIn = DisplayRecordID(rawValue: "builtin")
    private let desk = DisplayRecordID(rawValue: "desk")
    private let tv = DisplayRecordID(rawValue: "tv")
    private let virtualScreen = DisplayRecordID(rawValue: "virtual")
    private let displayLink = DisplayRecordID(rawValue: "displaylink")

    private func candidate(_ id: DisplayRecordID, _ displayClass: DisplayClass, active: Bool = true,
                           presence: PhysicalPresence? = .physical) -> DisplaySleepPrevention.Candidate {
        DisplaySleepPrevention.Candidate(recordID: id, displayClass: displayClass, isActive: active,
                                         physicalPresence: presence)
    }

    private var laptopWithDesk: [DisplaySleepPrevention.Candidate] {
        [candidate(builtIn, .builtIn, presence: .physical), candidate(desk, .external, presence: .physical)]
    }

    // MARK: - Policy

    func testNothingAskedNothingHeld() {
        let decision = DisplaySleepPrevention.decide(anyExternal: false, perDisplay: [], candidates: laptopWithDesk)
        XCTAssertFalse(decision.shouldHold)
        XCTAssertEqual(decision.standings[desk], .notRequested)
    }

    func testAnyExternalIsOwnedByEachLitExternal() {
        let decision = DisplaySleepPrevention.decide(
            anyExternal: true, perDisplay: [],
            candidates: laptopWithDesk + [candidate(tv, .television, presence: .physical)])
        XCTAssertEqual(decision.owners, [desk, tv])
        XCTAssertEqual(decision.standings[desk], .owner(.anyExternal))
        XCTAssertEqual(decision.standings[builtIn], .notRequested, "the built-in isn't an external")
    }

    /// The bug FB-12 names: a display switched off (or soft-disconnected) is still listed, and must
    /// not keep the displays awake.
    func testASwitchedOffExternalOwnsNothing() {
        let decision = DisplaySleepPrevention.decide(
            anyExternal: true, perDisplay: [],
            candidates: [candidate(builtIn, .builtIn, presence: .physical), candidate(desk, .external, active: false)])
        XCTAssertFalse(decision.shouldHold)
        XCTAssertEqual(decision.standings[desk], .ineligible(.inactive, requestedBy: .anyExternal))
    }

    func testAVirtualScreenNeverOwnsIt() {
        let decision = DisplaySleepPrevention.decide(
            anyExternal: true, perDisplay: [virtualScreen.rawValue],
            candidates: [candidate(builtIn, .builtIn), candidate(virtualScreen, .virtual)])
        XCTAssertFalse(decision.shouldHold)
        XCTAssertEqual(decision.standings[virtualScreen],
                       .ineligible(.virtual, requestedBy: [.anyExternal, .thisDisplay]))
    }

    func testAScreenWithVirtualPresenceNeverOwnsIt() {
        let decision = DisplaySleepPrevention.decide(
            anyExternal: true, perDisplay: [],
            candidates: [candidate(virtualScreen, .external, presence: .virtual)])
        XCTAssertFalse(decision.shouldHold)
    }

    /// Public APIs cannot separate generic virtual routes from DisplayLink/Sidecar reliably.
    func testAnUnverifiedExternalCannotKeepAPhysicalDisplayAssertion() {
        for presence: PhysicalPresence? in [nil, .unverified] {
            let decision = DisplaySleepPrevention.decide(
                anyExternal: true, perDisplay: [displayLink.rawValue],
                candidates: [candidate(displayLink, .external, presence: presence)])
            XCTAssertTrue(decision.owners.isEmpty)
            XCTAssertEqual(decision.standings[displayLink],
                           .ineligible(.unverified, requestedBy: [.anyExternal, .thisDisplay]))
        }
    }

    func testAHeadlessAdapterCannotKeepDisplaysAwake() {
        let decision = DisplaySleepPrevention.decide(
            anyExternal: true, perDisplay: [],
            candidates: [candidate(desk, .headlessAdapter, presence: .physical)])
        XCTAssertFalse(decision.shouldHold)
    }

    func testPerDisplayIntentHoldsOnlyWhileThatDisplayIsLit() {
        let lit = DisplaySleepPrevention.decide(anyExternal: false, perDisplay: [desk.rawValue], candidates: laptopWithDesk)
        XCTAssertEqual(lit.owners, [desk])
        XCTAssertEqual(lit.standings[desk], .owner(.thisDisplay))
        XCTAssertEqual(lit.standings[builtIn], .notRequested)

        let unplugged = DisplaySleepPrevention.decide(anyExternal: false, perDisplay: [desk.rawValue],
                                                      candidates: [candidate(builtIn, .builtIn)])
        XCTAssertFalse(unplugged.shouldHold, "an absent display owns nothing")
    }

    func testTheBuiltInCanAskForItself() {
        let decision = DisplaySleepPrevention.decide(anyExternal: false, perDisplay: [builtIn.rawValue],
                                                     candidates: laptopWithDesk)
        XCTAssertEqual(decision.owners, [builtIn])
    }

    /// Aggregation: the assertion stays while any eligible owner remains.
    func testHeldUntilTheLastOwnerGoes() {
        let both = DisplaySleepPrevention.decide(
            anyExternal: false, perDisplay: [desk.rawValue, tv.rawValue],
            candidates: laptopWithDesk + [candidate(tv, .television)])
        XCTAssertEqual(both.owners, [desk, tv])
        let oneLeft = DisplaySleepPrevention.decide(
            anyExternal: false, perDisplay: [desk.rawValue, tv.rawValue],
            candidates: [candidate(builtIn, .builtIn), candidate(tv, .television)])
        XCTAssertEqual(oneLeft.owners, [tv])
        XCTAssertTrue(oneLeft.shouldHold)
    }

    func testBothSettingsAreReported() {
        let decision = DisplaySleepPrevention.decide(anyExternal: true, perDisplay: [desk.rawValue],
                                                     candidates: laptopWithDesk)
        XCTAssertEqual(decision.standings[desk], .owner([.anyExternal, .thisDisplay]))
    }

    func testCandidateFromAnObservation() {
        let observation = DisplayObservation(recordID: desk, isActive: false, displayClass: .external,
                                             physicalPresence: .physical, generation: .initial)
        let made = DisplaySleepPrevention.Candidate(observation)
        XCTAssertEqual(made, candidate(desk, .external, active: false, presence: .physical))
    }

    // MARK: - Guard

    func testGuardHoldsOneAssertionAcrossAHandOver() {
        let backend = RecordingAssertions()
        let guardian = DisplaySleepGuard(backend: backend)
        guardian.apply(DisplaySleepPrevention.Decision(owners: [desk], standings: [:]))
        XCTAssertEqual(backend.created.count, 1)
        // The desk leaves as the TV arrives: same assertion, new owner, no gap.
        guardian.apply(DisplaySleepPrevention.Decision(owners: [tv], standings: [:]))
        XCTAssertEqual(backend.created.count, 1)
        XCTAssertTrue(backend.released.isEmpty)
        XCTAssertEqual(guardian.owners, [tv])
        guardian.apply(.none)
        XCTAssertTrue(backend.live.isEmpty)
        XCTAssertEqual(guardian.status, .released)
        XCTAssertEqual(guardian.owners, [])
    }

    func testStatusNamesTheHeldAssertion() {
        let backend = RecordingAssertions()
        let guardian = DisplaySleepGuard(backend: backend)
        XCTAssertEqual(guardian.status, .released)
        guardian.apply(DisplaySleepPrevention.Decision(owners: [desk], standings: [:]))
        guard case .held(let id) = guardian.status else { return XCTFail("expected a held assertion") }
        XCTAssertTrue(backend.live.contains(id))
    }

    func testStatusReportsARefusal() {
        let backend = RecordingAssertions()
        backend.refuse = true
        let guardian = DisplaySleepGuard(backend: backend)
        guardian.apply(DisplaySleepPrevention.Decision(owners: [desk], standings: [:]))
        XCTAssertEqual(guardian.status, .refused)
        XCTAssertFalse(guardian.isHoldingAssertion)
    }

    /// The name `pmset -g assertions` shows says whose it is and what it covers.
    func testDefaultNameIdentifiesTheAppAndTheScope() {
        let backend = RecordingAssertions()
        let guardian = DisplaySleepGuard(backend: backend)
        guardian.apply(DisplaySleepPrevention.Decision(owners: [desk], standings: [:]))
        let name = try? XCTUnwrap(backend.created.first)
        XCTAssertTrue(name?.contains("FreeDisplay") == true)
        XCTAssertTrue(name?.contains("idle display sleep only") == true)
    }

    func testReleaseAllDropsOwners() {
        let backend = RecordingAssertions()
        let guardian = DisplaySleepGuard(backend: backend)
        guardian.apply(DisplaySleepPrevention.Decision(owners: [desk], standings: [:]))
        guardian.releaseAll()
        XCTAssertEqual(guardian.owners, [])
        XCTAssertEqual(guardian.status, .released)
        XCTAssertTrue(backend.live.isEmpty)
    }

    // MARK: - Settings and cleanup

    func testPerDisplayIntentRoundTrips() throws {
        var settings = OpenDisplaySettings()
        settings.preventDisplaySleepDisplayIDs = [desk.rawValue]
        let decoded = try JSONDecoder().decode(OpenDisplaySettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.preventDisplaySleepDisplayIDs, [desk.rawValue])
    }

    func testForgettingADisplayDropsItsIntent() throws {
        var settings = OpenDisplaySettings()
        settings.preventDisplaySleepDisplayIDs = [desk.rawValue, tv.rawValue]
        let record = DisplayRecord(id: .init(rawValue: "disp_desk"), alias: "Desk", tags: [],
                                   fingerprint: DisplayFingerprint(vendorID: 1, productID: 1, modelName: nil),
                                   displayClass: .external)
        let entry = RememberedDisplay(id: "disp_desk", record: record, isRegistered: true,
                                      observationIDs: [desk], status: .notConnected, offline: nil)
        let plan = try RememberedDisplayCleanup.plan(
            for: entry, mode: .forget, settings: settings, favorites: FavoriteResolutions(),
            menuLayout: MenuLayoutSettings(), ledger: [])
        XCTAssertTrue(plan.keepsDisplaysAwake)
        XCTAssertFalse(plan.removesOnlyRecord)
        let cleaned = RememberedDisplayCleanup.applying(plan, to: settings)
        XCTAssertEqual(cleaned.preventDisplaySleepDisplayIDs, [tv.rawValue])
    }
}
