import XCTest
import DisplayDomain
@testable import TopologyCore

/// SD-02 / TR-09: serial collisions and tied scores never let two displays share one record, and
/// existing records keep their aliases through the change.
final class DisplayRegistryAmbiguityTests: XCTestCase {
    private func fingerprint(vendor: Int? = 1, product: Int? = 1, serial: String? = nil) -> DisplayFingerprint {
        DisplayFingerprint(vendorID: vendor, productID: product, serialNumber: serial)
    }

    private typealias Input = (fingerprint: DisplayFingerprint, cgUUID: String?, displayClass: DisplayClass)

    private func input(_ fingerprint: DisplayFingerprint, _ cgUUID: String?) -> Input {
        (fingerprint, cgUUID, .external)
    }

    func testTwoVendorsSharingASerialGetTwoRecords() async throws {
        let registry = await DisplayRegistry(store: InMemoryRegistryStore())
        let dell = await registry.resolve(fingerprint: fingerprint(vendor: 0x10AC, serial: "1"), cgUUID: "U1")
        try await registry.setAlias("Dell", for: dell.id)
        let samsung = await registry.resolve(fingerprint: fingerprint(vendor: 0x4C2D, serial: "1"), cgUUID: "U2")
        XCTAssertNotEqual(dell.id, samsung.id)
        XCTAssertNil(samsung.alias, "the other vendor's display must not inherit the alias")
        let count = await registry.allRecords().count
        XCTAssertEqual(count, 2)
    }

    /// Two new identical-serial units plugged in together: one record each, never one for both.
    func testTwoNewDisplaysWithTheSameSerialArriveAsTwoRecords() async {
        let registry = await DisplayRegistry(store: InMemoryRegistryStore())
        let same = fingerprint(serial: "16843009")
        let first = await registry.resolveAll([input(same, "U1"), input(same, "U2")])
        XCTAssertNotEqual(first[0].id, first[1].id)
        // …and they stay apart on every later refresh, each through its own CG UUID.
        let again = await registry.resolveAll([input(same, "U1"), input(same, "U2")])
        XCTAssertEqual(again.map(\.id), first.map(\.id))
        XCTAssertFalse(again.contains(where: \.isProvisional))
    }

    /// A registry written before this change, where two identical-serial monitors had been merged
    /// into one record (both CG UUIDs point at it). Present together, neither silently gets it.
    private func conflatedRegistry() async -> (DisplayRegistry, DisplayRecord) {
        let shared = DisplayRecord(id: DisplayRecordID(rawValue: "disp_shared"), alias: "Left",
                                   fingerprint: fingerprint(serial: "16843009"), displayClass: .external)
        let state = RegistryState(records: [shared], cgUUIDIndex: ["U1": shared.id, "U2": shared.id])
        return (await DisplayRegistry(store: InMemoryRegistryStore(state)), shared)
    }

    func testARecordTwoPresentDisplaysTieForIsGivenToNeither() async {
        let (registry, shared) = await conflatedRegistry()
        let same = fingerprint(serial: "16843009")
        let resolved = await registry.resolveAll([input(same, "U1"), input(same, "U2")])
        XCTAssertTrue(resolved.allSatisfy(\.isProvisional))
        XCTAssertTrue(resolved.allSatisfy { $0.alias == nil })
        XCTAssertEqual(resolved.map(\.unresolvedCandidates), [[shared.id], [shared.id]])
        XCTAssertNotEqual(resolved[0].id, resolved[1].id)
        // Nothing was persisted for them, and the remembered record kept its alias and its index.
        let records = await registry.allRecords()
        XCTAssertEqual(records.map(\.id), [shared.id])
        let byObservation = await registry.recordsByObservationID()
        XCTAssertEqual(byObservation[.forCGUUID("U1")]?.alias, "Left")
        XCTAssertEqual(byObservation[.forCGUUID("U2")]?.alias, "Left")
    }

    /// Migration keeps the common case intact: one of the merged pair on its own is still "Left".
    func testAMergedRecordStillServesEitherDisplayOnItsOwn() async {
        let (registry, shared) = await conflatedRegistry()
        let alone = await registry.resolveAll([input(fingerprint(serial: "16843009"), "U2")])
        XCTAssertEqual(alone.first?.id, shared.id)
        XCTAssertEqual(alone.first?.alias, "Left")
    }

    /// Naming one provisional display resolves it: it becomes its own record, and the other display
    /// keeps the old record — and its alias — from then on.
    func testNamingAProvisionalDisplaySplitsItOff() async throws {
        let (registry, shared) = await conflatedRegistry()
        let same = fingerprint(serial: "16843009")
        let provisional = await registry.resolveAll([input(same, "U1"), input(same, "U2")])
        try await registry.setAlias("Right", for: provisional[0].id)

        let after = await registry.resolveAll([input(same, "U1"), input(same, "U2")])
        XCTAssertEqual(after[0].alias, "Right")
        XCTAssertNotEqual(after[0].id, shared.id)
        XCTAssertEqual(after[1].id, shared.id)
        XCTAssertEqual(after[1].alias, "Left")
        XCTAssertFalse(after.contains(where: \.isProvisional))
    }

    /// A record claimed through this Mac's CG UUID index outranks a claim on the serial alone — and
    /// the outranked display, known not to be that record, becomes a display of its own.
    func testTheStrongerClaimKeepsTheRecord() async throws {
        let registry = await DisplayRegistry(store: InMemoryRegistryStore())
        let same = fingerprint(serial: "S1")
        let known = await registry.resolve(fingerprint: same, cgUUID: "U1")
        try await registry.setAlias("Desk", for: known.id)
        let resolved = await registry.resolveAll([input(same, "U9"), input(same, "U1")])
        XCTAssertEqual(resolved[1].id, known.id)
        XCTAssertEqual(resolved[1].alias, "Desk")
        XCTAssertNotEqual(resolved[0].id, known.id)
        XCTAssertFalse(resolved[0].isProvisional)
        XCTAssertNil(resolved[0].alias)
        let again = await registry.resolveAll([input(same, "U9"), input(same, "U1")])
        XCTAssertEqual(again.map(\.id), resolved.map(\.id), "both stay put on the next refresh")
    }

    /// The CG UUID index is a routing hint: a record whose serial says it is another display is not
    /// followed (and not overwritten with this display's identity).
    func testACGUUIDPointingAtAContradictingRecordIsNotFollowed() async throws {
        let registry = await DisplayRegistry(store: InMemoryRegistryStore())
        let original = await registry.resolve(fingerprint: fingerprint(serial: "A"), cgUUID: "U1")
        try await registry.setAlias("Original", for: original.id)
        let other = await registry.resolve(fingerprint: fingerprint(serial: "B"), cgUUID: "U1")
        XCTAssertNotEqual(other.id, original.id)
        XCTAssertNil(other.alias)
        let kept = await registry.record(for: original.id)
        XCTAssertEqual(kept?.fingerprint.serialNumber, "A")
        XCTAssertEqual(kept?.alias, "Original")
    }

    /// R1 P1: a paired record of the same model must not be *scored* onto a display whose serial says
    /// it is another unit — pairing plus model alone clear the recognition threshold. Checked both
    /// under the CG UUID the record is indexed by (where the index lookup already refuses it) and
    /// under a UUID this Mac never saw.
    func testAPairedRecordIsNotScoredOntoTheSameModelWithAnotherSerial() async throws {
        for cgUUID in ["U1", "U2"] {
            let registry = await DisplayRegistry(store: InMemoryRegistryStore())
            let original = await registry.resolve(fingerprint: fingerprint(serial: "A"), cgUUID: "U1")
            try await registry.setAlias("Left", for: original.id)
            await registry.addTag("desk", to: original.id)
            await registry.confirmPairing(for: original.id)

            let other = await registry.resolve(fingerprint: fingerprint(serial: "B"), cgUUID: cgUUID)
            XCTAssertNotEqual(other.id, original.id, cgUUID)
            XCTAssertNil(other.alias, cgUUID)
            XCTAssertTrue(other.tags.isEmpty, cgUUID)
            XCTAssertFalse(other.pairingConfirmed, cgUUID)
            let kept = await registry.record(for: original.id)
            XCTAssertEqual(kept?.fingerprint.serialNumber, "A", "the record's identity is not overwritten (\(cgUUID))")
            XCTAssertEqual(kept?.alias, "Left", cgUUID)
        }
    }

    /// The exclusion is for evidence that contradicts, not for evidence that is missing: the paired
    /// display reporting no serial this time is still recognized by pairing plus model.
    func testAPairedRecordStillServesItsDisplayWhenTheSerialGoesMissing() async throws {
        let registry = await DisplayRegistry(store: InMemoryRegistryStore())
        let original = await registry.resolve(fingerprint: fingerprint(serial: "A"), cgUUID: "U1")
        try await registry.setAlias("Left", for: original.id)
        await registry.confirmPairing(for: original.id)
        let again = await registry.resolve(fingerprint: fingerprint(serial: nil), cgUUID: "U2")
        XCTAssertEqual(again.id, original.id)
        XCTAssertEqual(again.alias, "Left")
        XCTAssertEqual(again.fingerprint.serialNumber, "A", "a missing serial keeps the one on record")
    }

    /// A third unit with the shared serial and an unknown CG UUID, once records were split: there is
    /// nothing to choose between them, so it gets none of their settings.
    func testSeveralRecordsSharingTheSerialAndNoIndexIsAmbiguous() async throws {
        let (registry, shared) = await conflatedRegistry()
        let same = fingerprint(serial: "16843009")
        let provisional = await registry.resolveAll([input(same, "U1"), input(same, "U2")])
        try await registry.setAlias("Right", for: provisional[0].id)
        let third = await registry.resolveAll([input(same, "U3")])
        XCTAssertTrue(third[0].isProvisional)
        XCTAssertEqual(third[0].unresolvedCandidates?.count, 2)
        XCTAssertTrue(third[0].unresolvedCandidates?.contains(shared.id) == true)
    }

    /// Two paired identical monitors seen under a CG UUID this Mac never indexed tie on score;
    /// the old code took whichever came first.
    func testATiedScoreIsNotResolvedByOrder() async {
        let a = DisplayRecord(id: DisplayRecordID(rawValue: "disp_a"), alias: "A",
                              fingerprint: fingerprint(), pairingConfirmed: true)
        let b = DisplayRecord(id: DisplayRecordID(rawValue: "disp_b"), alias: "B",
                              fingerprint: fingerprint(), pairingConfirmed: true)
        let registry = await DisplayRegistry(store: InMemoryRegistryStore(RegistryState(records: [a, b])))
        let resolved = await registry.resolve(fingerprint: fingerprint(), cgUUID: "NEW")
        XCTAssertTrue(resolved.isProvisional)
        XCTAssertNil(resolved.alias)
        XCTAssertEqual(resolved.unresolvedCandidates, [a.id, b.id])
        let count = await registry.allRecords().count
        XCTAssertEqual(count, 2, "an ambiguous answer persists nothing")
    }

    func testAProvisionalRecordIsFoundByItsIDUntilTheNextResolve() async {
        let (registry, _) = await conflatedRegistry()
        let same = fingerprint(serial: "16843009")
        let provisional = await registry.resolveAll([input(same, "U1"), input(same, "U2")])
        let lookedUp = await registry.record(for: provisional[0].id)
        XCTAssertEqual(lookedUp?.isProvisional, true)
    }

    /// Records written by earlier builds (no `unresolvedCandidates` key) load with their aliases.
    func testAnExistingRegistryFileStillLoads() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("od-registry-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = """
        {"cgUUIDIndex":{"U1":{"rawValue":"disp_1"}},"records":[{"alias":"Desk","displayClass":"external",
        "fingerprint":{"productID":1,"serialNumber":"S1","vendorID":1},"id":{"rawValue":"disp_1"},
        "pairingConfirmed":false,"tags":["studio"]}]}
        """
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("registry.json"))
        let registry = await DisplayRegistry(store: DiskRegistryStore(directory: directory))
        let resolved = await registry.resolve(fingerprint: fingerprint(serial: "S1"), cgUUID: "U1")
        XCTAssertEqual(resolved.id.rawValue, "disp_1")
        XCTAssertEqual(resolved.alias, "Desk")
        XCTAssertEqual(resolved.tags, ["studio"])
        XCTAssertFalse(resolved.isProvisional)
    }
}
