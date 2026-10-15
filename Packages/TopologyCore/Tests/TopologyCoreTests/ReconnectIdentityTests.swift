import XCTest
import DisplayDomain
import ProviderInterfaces
@testable import TopologyCore

/// R4 P0: a reconnect by raw display number must reach — and be verified against — the display the
/// ledger recorded, not whichever display has been handed that number since.
final class ReconnectIdentityTests: XCTestCase {
    /// Display A, turned off while it was display number 7.
    private let entryA = ManagedOfflineDisplay(recordID: .forCGUUID("AAAA"), cgID: 7, name: "Desk",
                                               displayClass: .external)

    private func observation(_ uuid: String?, number: UInt32, active: Bool = true) -> DisplayObservation {
        DisplayObservation(recordID: uuid.map(DisplayRecordID.forCGUUID) ?? DisplayRecordID(rawValue: "cgid:\(number)"),
                           cgDisplayID: number, cgUUID: uuid, isActive: active, displayClass: .external,
                           generation: .initial)
    }

    // MARK: - Which observed display is the entry's

    func testAnotherDisplayUnderTheOldNumberIsNotTheEntryBack() {
        XCTAssertFalse(ReconnectVerification.isLit(entryA, in: [observation("BBBB", number: 7)]),
                       "B was handed A's number; B lit is not A lit")
        XCTAssertFalse(ReconnectVerification.isLit(entryA, in: [observation(nil, number: 7)]),
                       "a number with no persistent identity behind it proves nothing")
    }

    func testTheRecordedDisplayIsBackWhateverNumberItGotThisTime() {
        XCTAssertTrue(ReconnectVerification.isLit(entryA, in: [observation("AAAA", number: 9)]))
        XCTAssertTrue(ReconnectVerification.isLit(entryA, in: [observation("aaaa", number: 7)]),
                      "the UUID decides, however it is spelled")
    }

    func testAUUIDLessEntryIsMatchedOnItsRecordOnly() {
        let uuidLess = ManagedOfflineDisplay(recordID: DisplayRecordID(rawValue: "cgid:7"), cgID: 7,
                                             name: "Desk", displayClass: .external)
        XCTAssertTrue(ReconnectVerification.isLit(uuidLess, in: [observation(nil, number: 7)]))
        XCTAssertFalse(ReconnectVerification.isLit(uuidLess, in: [observation("BBBB", number: 7)]),
                       "a display with a persistent identity can't be shown to be the one that had none")
    }

    // MARK: - When the number may be used

    private func conflict(_ offline: ManagedOfflineDisplay? = nil, observations: [DisplayObservation],
                          ledger: [ManagedOfflineDisplay]? = nil,
                          uuid: @escaping (UInt32) -> String?) -> ReconnectIdentity.Conflict? {
        let offline = offline ?? entryA
        return ReconnectIdentity.conflict(for: offline, observations: observations, ledger: ledger ?? [offline],
                                          uuidForNumber: uuid)
    }

    private func target(observations: [DisplayObservation], ledger: [ManagedOfflineDisplay]? = nil,
                        uuid: @escaping (UInt32) -> String?) throws -> DisplayRecordID {
        try ReconnectIdentity.reconnectTarget(for: entryA, observations: observations, ledger: ledger ?? [entryA],
                                              uuidForNumber: uuid)
    }

    func testTheNumberIsRefusedWhileAnotherDisplayHoldsIt() {
        XCTAssertEqual(conflict(observations: [observation("BBBB", number: 7, active: false)], uuid: { _ in nil }),
                       .numberHeldByAnotherDisplay(number: 7, holder: .forCGUUID("BBBB")))
    }

    func testTheNumberIsRefusedWhenCoreGraphicsNamesAnotherDisplay() {
        XCTAssertEqual(conflict(observations: [], uuid: { _ in "BBBB" }),
                       .numberNamesAnotherDisplay(number: 7, uuid: "BBBB"))
    }

    /// A went dark as #7 and was unplugged; #7 went to B, which was then turned off too. Neither is
    /// online and Core Graphics may not resolve a disabled number — only the ledger tells them apart.
    func testANumberRecordedLaterForAnotherDarkDisplayBelongsToThatOne() {
        let entryB = ManagedOfflineDisplay(recordID: .forCGUUID("BBBB"), cgID: 7, name: "Side",
                                           displayClass: .external)
        XCTAssertEqual(conflict(observations: [], ledger: [entryA, entryB], uuid: { _ in nil }),
                       .numberRecordedLaterForAnotherDisplay(number: 7, by: .forCGUUID("BBBB")))
        XCTAssertNil(conflict(entryB, observations: [], ledger: [entryA, entryB], uuid: { _ in nil }),
                     "the later record owns the number")
        var elsewhere = entryB
        elsewhere.cgID = 8
        XCTAssertNil(conflict(observations: [], ledger: [entryA, elsewhere], uuid: { _ in nil }))
        XCTAssertNil(conflict(observations: [], ledger: [entryB, entryA], uuid: { _ in nil }),
                     "an older record of the number doesn't take it from a newer one")
    }

    func testTheNumberIsUsedWhenNothingContradictsIt() {
        XCTAssertNil(conflict(observations: [], uuid: { _ in nil }),
                     "a disabled display may not resolve; no answer contradicts nothing")
        XCTAssertNil(conflict(observations: [observation("BBBB", number: 3)], uuid: { $0 == 7 ? "AAAA" : "BBBB" }))
        // The public provider's "off" is a mirror: A stays online under its own number.
        XCTAssertNil(conflict(observations: [observation("AAAA", number: 7, active: false)], uuid: { _ in "AAAA" }))
        let byRecord = ManagedOfflineDisplay(recordID: .forCGUUID("AAAA"), cgID: 0, name: "Desk",
                                             displayClass: .external)
        XCTAssertNil(conflict(byRecord, observations: [observation("BBBB", number: 0)], uuid: { _ in "BBBB" }),
                     "without a number the provider resolves the recorded UUID itself")
    }

    func testAnOnlineDisplayIsReachedAtTheNumberItsIdentityHasNow() throws {
        // A is still enumerated (the public provider's "off" is a mirror) but now as #9; B has #7.
        let observations = [observation("BBBB", number: 7), observation("AAAA", number: 9, active: false)]
        XCTAssertEqual(try target(observations: observations, uuid: { $0 == 7 ? "BBBB" : "AAAA" }),
                       DisplayRecordID(rawValue: "cgid:9"))
        XCTAssertEqual(try target(observations: [], uuid: { _ in nil }),
                       DisplayRecordID(rawValue: "cgid:7"), "offline: the recorded number, uncontradicted")
        XCTAssertThrowsError(try target(observations: [observation("BBBB", number: 7)], uuid: { _ in "BBBB" }))
    }

    // MARK: - The no-model Reconnect All, end to end

    /// The finding: B now goes by A's number 7. The provider would act on B, B lit would pass for A
    /// lit, and A's ledger entry — its only record — would be deleted.
    func testANumberReusedByAnotherDisplayIsNeitherWrittenNorTakenForTheEntry() async {
        for heldBy in [observation("BBBB", number: 7, active: false), observation("BBBB", number: 7)] {
            let system = NumberAddressedDisplays(online: [heldBy], dark: [7: observation("AAAA", number: 7)])
            let saved = SavedLedgers()
            let ledger = [entryA]
            let results = await ManagedOfflineRecovery.reconnectAll(
                ledger: ledger,
                attempt: { offline in
                    await ManagedOfflineRecovery.verifiedAttempt(
                        offline, lifecycle: system, observer: system, ledger: ledger,
                        uuidForDisplayNumber: { _ in "BBBB" },
                        deadline: .distantFuture, escalate: {})
                },
                save: { saved.append($0) })
            let requests = await system.reconnectRequests
            XCTAssertEqual(requests, [], "nothing is sent to the display that holds the number now")
            XCTAssertEqual(results.map(\.reconnected), [false])
            XCTAssertEqual(saved.all, [[entryA]], "A's entry survives untouched")
        }
    }

    func testTheRecordedDisplayIsStillReconnectedAndForgottenOnceLit() async {
        let system = NumberAddressedDisplays(online: [observation("CCCC", number: 3)],
                                             dark: [7: observation("AAAA", number: 7)])
        let saved = SavedLedgers()
        let ledger = [entryA]
        let results = await ManagedOfflineRecovery.reconnectAll(
            ledger: ledger,
            attempt: { offline in
                await ManagedOfflineRecovery.verifiedAttempt(
                    offline, lifecycle: system, observer: system, ledger: ledger,
                    uuidForDisplayNumber: { $0 == 7 ? "AAAA" : "CCCC" }, deadline: .distantFuture, escalate: {})
            },
            save: { saved.append($0) })
        let requests = await system.reconnectRequests
        XCTAssertEqual(requests, [DisplayRecordID(rawValue: "cgid:7")])
        XCTAssertEqual(results.map(\.reconnected), [true])
        XCTAssertEqual(saved.all, [[]])
    }

    func testARenumberedDisplayIsReconnectedUnderItsNewNumberNotTheReusedOne() async {
        let system = NumberAddressedDisplays(
            online: [observation("BBBB", number: 7), observation("AAAA", number: 9, active: false)], dark: [:])
        let attempt = await ManagedOfflineRecovery.verifiedAttempt(
            entryA, lifecycle: system, observer: system, ledger: [entryA],
            uuidForDisplayNumber: { $0 == 7 ? "BBBB" : "AAAA" }, deadline: .distantFuture, escalate: {})
        let requests = await system.reconnectRequests
        XCTAssertEqual(requests, [DisplayRecordID(rawValue: "cgid:9")], "A, where it is now — never B's #7")
        XCTAssertEqual(attempt, .lit)
    }

    func testTheRequestItselfRefusesWithTheConflict() async {
        let system = NumberAddressedDisplays(online: [observation("BBBB", number: 7)], dark: [:])
        do {
            try await ManagedOfflineRecovery.requestReconnect(
                entryA, lifecycle: system, observations: await system.currentSnapshot().observations,
                ledger: [entryA], uuidForDisplayNumber: { _ in "BBBB" }, deadline: .distantFuture)
            XCTFail("a number held by another display must not be used")
        } catch let conflict as ReconnectIdentity.Conflict {
            XCTAssertEqual(conflict, .numberHeldByAnotherDisplay(number: 7, holder: .forCGUUID("BBBB")))
        } catch {
            XCTFail("unexpected \(error)")
        }
        let requests = await system.reconnectRequests
        XCTAssertEqual(requests, [])
    }
}

/// A topology addressed the way the real lifecycle providers address it: `cgid:<n>` acts on
/// whichever display has number n, online or dark.
private actor NumberAddressedDisplays: LifecycleProvider, TopologyObserving {
    nonisolated let providerID = "test.numberAddressed"
    nonisolated let isExperimental = false

    private var online: [DisplayObservation]
    private var dark: [UInt32: DisplayObservation]
    private(set) var reconnectRequests: [DisplayRecordID] = []

    init(online: [DisplayObservation], dark: [UInt32: DisplayObservation]) {
        self.online = online
        self.dark = dark
    }

    func currentSnapshot() -> TopologySnapshot {
        TopologySnapshot(generation: .initial, observations: online)
    }

    func awaitStableGeneration(after generation: TopologyGeneration) -> TopologySnapshot { currentSnapshot() }

    func probe(_ environment: ProviderEnvironment) -> ProviderProbe {
        ProviderProbe(providerID: providerID, status: .supported, risk: .normal)
    }

    func disconnect(_ target: DisplayRecordID, deadline: Date) async throws {}

    func reconnect(_ target: DisplayRecordID, deadline: Date) async throws {
        reconnectRequests.append(target)
        guard target.rawValue.hasPrefix("cgid:"), let number = UInt32(target.rawValue.dropFirst(5)) else {
            throw ProviderFailure.ambiguous(candidates: [])
        }
        if let index = online.firstIndex(where: { $0.cgDisplayID == number }) {
            online[index].isActive = true
        } else if var back = dark.removeValue(forKey: number) {
            back.isActive = true
            online.append(back)
        }
    }

    func recover(to checkpoint: Checkpoint) async throws {}
}

/// Collects every ledger a run saves, in order.
private final class SavedLedgers: @unchecked Sendable {
    private let lock = NSLock()
    private var ledgers: [[ManagedOfflineDisplay]] = []
    func append(_ ledger: [ManagedOfflineDisplay]) { lock.withLock { ledgers.append(ledger) } }
    var all: [[ManagedOfflineDisplay]] { lock.withLock { ledgers } }
}
