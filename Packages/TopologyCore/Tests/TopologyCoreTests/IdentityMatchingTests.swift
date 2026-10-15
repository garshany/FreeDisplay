import XCTest
import DisplayDomain
@testable import TopologyCore

/// SD-10 / FA-11 / TB-09: the explanation of how a display was matched is the very value the
/// registry decided from, stage by stage, with every record's own verdict.
final class IdentityMatchingTests: XCTestCase {
    private typealias Input = (fingerprint: DisplayFingerprint, cgUUID: String?, displayClass: DisplayClass)

    private func fingerprint(vendor: Int? = 1, product: Int? = 1, serial: String? = nil,
                             model: String? = nil, width: Int? = nil, height: Int? = nil) -> DisplayFingerprint {
        DisplayFingerprint(vendorID: vendor, productID: product, serialNumber: serial, modelName: model,
                           physicalWidthMM: width, physicalHeightMM: height)
    }

    private func input(_ fingerprint: DisplayFingerprint, _ cgUUID: String?) -> Input {
        (fingerprint, cgUUID, .external)
    }

    private func record(_ id: String, _ fingerprint: DisplayFingerprint, alias: String? = nil,
                        paired: Bool = false) -> DisplayRecord {
        DisplayRecord(id: DisplayRecordID(rawValue: id), alias: alias, fingerprint: fingerprint,
                      displayClass: .external, lastSeen: Date(timeIntervalSince1970: 0), pairingConfirmed: paired)
    }

    private func registry(_ records: [DisplayRecord], index: [String: String] = [:]) async -> DisplayRegistry {
        let state = RegistryState(records: records,
                                  cgUUIDIndex: index.mapValues { DisplayRecordID(rawValue: $0) })
        return await DisplayRegistry(store: InMemoryRegistryStore(state))
    }

    func testStrategyRestrictionsCannotManufactureSerialUniqueness() async {
        var a = record("disp_a", fingerprint(serial: "SHARED"))
        a.identityStrategy = .systemUUID
        let b = record("disp_b", fingerprint(serial: "SHARED"))
        let registry = await registry([a, b], index: ["UUID-A": "disp_a"])
        let result = await registry.resolveAllExplained([input(fingerprint(serial: "SHARED"), "UUID-A")])
        XCTAssertEqual(result[0].record.id, a.id)
        let state = await registry.currentState()
        XCTAssertEqual(state.cgUUIDIndex["UUID-A"], a.id)
        let unknown = await registry.resolveAllExplained([input(fingerprint(serial: "SHARED"), "NEW")])
        XCTAssertTrue(unknown[0].record.isProvisional)
    }

    func testUnsupportedNewRecordStrategyStaysUnresolvedWithoutRegistryGrowth() async {
        let registry = await registry([])
        for _ in 0..<3 {
            let result = await registry.resolveAllExplained([input(fingerprint(), "UUID")],
                                                          newRecordStrategy: .qualifiedSerial)
            XCTAssertTrue(result[0].record.isProvisional)
            let state = await registry.currentState()
            XCTAssertTrue(state.records.isEmpty)
            XCTAssertTrue(state.cgUUIDIndex.isEmpty)
        }
        let result = await registry.resolveAllExplained([input(fingerprint(), nil)], newRecordStrategy: .systemUUID)
        XCTAssertTrue(result[0].record.isProvisional)
    }

    func testUnsupportedStrategyAfterCollisionRetryNeverMintsOrReindexes() async {
        let known = record("disp_a", fingerprint(), paired: true)
        let registry = await registry([known], index: ["UUID-A": "disp_a"])
        for _ in 0..<3 {
            let result = await registry.resolveAllExplained(
                [input(fingerprint(), "UUID-A"), input(fingerprint(), "UUID-B")],
                newRecordStrategy: .qualifiedSerial)
            XCTAssertEqual(result[0].record.id, known.id)
            XCTAssertTrue(result[1].record.isProvisional)
            let state = await registry.currentState()
            XCTAssertEqual(state.records.map(\.id), [known.id])
            XCTAssertEqual(state.cgUUIDIndex, ["UUID-A": known.id])
        }
    }

    func testSystemUUIDStrategyRejectsSerialFallbackButStillRejectsConflicts() async {
        var known = record("disp_a", fingerprint(serial: "A"))
        known.identityStrategy = .systemUUID
        let registry = await registry([known], index: ["U1": "disp_a"])
        let unchanged = await registry.resolveAllExplained([input(fingerprint(serial: "A"), "U1")])
        XCTAssertEqual(unchanged[0].record.id, known.id)
        let changed = await registry.resolveAllExplained([input(fingerprint(serial: "A"), "U-new")])
        XCTAssertNotEqual(changed[0].record.id, known.id)
        let conflict = await registry.resolveAllExplained([input(fingerprint(serial: "B"), "U1")])
        XCTAssertNotEqual(conflict[0].record.id, known.id)
    }

    func testQualifiedSerialStrategyDoesNotFallBackToUUIDOrScore() async {
        var known = record("disp_a", fingerprint(serial: "A"))
        known.identityStrategy = .qualifiedSerial
        let registry = await registry([known], index: ["U1": "disp_a"])
        let changedUUID = await registry.resolveAllExplained([input(fingerprint(serial: "A"), "U-new")])
        XCTAssertEqual(changedUUID[0].record.id, known.id)
        let missing = await registry.resolveAllExplained([input(fingerprint(), "U1")])
        XCTAssertNotEqual(missing[0].record.id, known.id)
    }

    func testNewRecordStrategyOnlyAppliesToNewRecordsAndSurvivesCoding() async throws {
        let known = record("disp_a", fingerprint(serial: "A"))
        let registry = await registry([known], index: ["U1": "disp_a"])
        let resolved = await registry.resolveAllExplained(
            [input(fingerprint(serial: "A"), "U1"), input(fingerprint(serial: "B"), "U2")],
            newRecordStrategy: .systemUUID)
        XCTAssertNil(resolved[0].record.identityStrategy)
        XCTAssertEqual(resolved[1].record.identityStrategy, .systemUUID)
        let state = await registry.currentState()
        let decoded = try JSONDecoder().decode(RegistryState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
        var settings = OpenDisplaySettings()
        settings.newDisplayIdentityStrategy = .qualifiedSerial
        XCTAssertEqual(try JSONDecoder().decode(OpenDisplaySettings.self, from: JSONEncoder().encode(settings)), settings)
        XCTAssertEqual(try JSONDecoder().decode(OpenDisplaySettings.self, from: Data("{}".utf8)).newDisplayIdentityStrategy, .automatic)
    }

    func testArchiveReportsUnmatchedManualChannelIdentity() {
        let id = DisplayRecordID.forCGUUID("not-on-this-mac")
        var settings = OpenDisplaySettings()
        settings.ddcChannelMappings = [.init(displayID: id,
            displayIdentity: .init(vendorNumber: 1, productNumber: 2, serialNumber: 0),
            channelPath: "test-channel", channelAttributes: nil, confirmedAt: Date())]
        let archive = SettingsArchive(createdAt: Date(), appVersion: nil, settings: settings,
            favorites: FavoriteResolutions(), registry: RegistryState(), scenes: [], defaults: ArchivedDefaults())
        XCTAssertEqual(archive.unmatchedDisplays(known: []).map(\.id), [id])
    }

    // MARK: - Decision mirrors resolution

    func testANewDisplayIsExplainedAsANewRecord() async {
        let registry = await registry([])
        let result = await registry.resolveAllExplained([input(fingerprint(serial: "A"), "U1")])
        XCTAssertEqual(result[0].explanation.decision, .newRecord)
        XCTAssertTrue(result[0].explanation.assessments.isEmpty)
    }

    func testQualifiedSerialAndUUIDAreNamedAsTheEvidence() async {
        let known = record("disp_a", fingerprint(serial: "A"))
        let registry = await registry([known], index: ["U1": "disp_a"])
        let viaBoth = await registry.resolveAllExplained([input(fingerprint(serial: "A"), "U1")])
        XCTAssertEqual(viaBoth[0].record.id, known.id)
        XCTAssertEqual(viaBoth[0].explanation.decision, .record(known.id, .serialAndCGUUID))

        let viaSerial = await registry.resolveAllExplained([input(fingerprint(serial: "A"), "U-new")])
        XCTAssertEqual(viaSerial[0].explanation.decision, .record(known.id, .serial))
        XCTAssertEqual(viaSerial[0].explanation.assessment(for: known.id)?.serialMatches, true)
        XCTAssertEqual(viaSerial[0].explanation.assessment(for: known.id)?.indexedUnderThisUUID, false)
    }

    func testTheSameMacUUIDFastPathIsExplained() async {
        let known = record("disp_a", fingerprint(vendor: nil, product: nil))
        let registry = await registry([known], index: ["U1": "disp_a"])
        let result = await registry.resolveAllExplained([input(fingerprint(vendor: nil, product: nil), "U1")])
        XCTAssertEqual(result[0].record.id, known.id)
        XCTAssertEqual(result[0].explanation.decision, .record(known.id, .cgUUID))
    }

    func testAScoredMatchCarriesItsScore() async {
        let known = record("disp_a", fingerprint(), paired: true)
        let registry = await registry([known])
        let result = await registry.resolveAllExplained([input(fingerprint(), "U9")])
        XCTAssertEqual(result[0].record.id, known.id)
        XCTAssertEqual(result[0].explanation.decision, .record(known.id, .scored))
        let score = result[0].explanation.assessment(for: known.id)?.confidence.score ?? 0
        XCTAssertGreaterThanOrEqual(score, result[0].explanation.recognitionThreshold)
    }

    func testASharedSerialWithoutAUUIDIsAmbiguousForThatReason() async {
        let left = record("disp_l", fingerprint(serial: "S"))
        let right = record("disp_r", fingerprint(serial: "S"))
        let registry = await registry([left, right])
        let result = await registry.resolveAllExplained([input(fingerprint(serial: "S"), "U-new")])
        XCTAssertTrue(result[0].record.isProvisional)
        XCTAssertEqual(result[0].explanation.decision, .ambiguous([left.id, right.id], .sharedSerial))
    }

    func testATiedScoreIsAmbiguousForThatReason() async {
        let a = record("disp_a", fingerprint(), paired: true)
        let b = record("disp_b", fingerprint(), paired: true)
        let registry = await registry([a, b])
        let result = await registry.resolveAllExplained([input(fingerprint(), "U-new")])
        XCTAssertTrue(result[0].record.isProvisional)
        XCTAssertEqual(result[0].explanation.decision, .ambiguous([a.id, b.id], .tiedScore))
    }

    /// The fail-closed rule, explained: a record that names another serial or model takes part in no
    /// stage, even when this Mac's UUID index points at it.
    func testAConflictingRecordIsExplainedAndNeverFollowed() async {
        let other = record("disp_other", fingerprint(serial: "B"), alias: "Other", paired: true)
        let otherModel = record("disp_model", fingerprint(product: 2, serial: "A"))
        let registry = await registry([other, otherModel], index: ["U1": "disp_other"])
        let result = await registry.resolveAllExplained([input(fingerprint(serial: "A"), "U1")])
        XCTAssertEqual(result[0].explanation.decision, .newRecord)
        XCTAssertNotEqual(result[0].record.id, other.id)
        XCTAssertNil(result[0].record.alias)
        XCTAssertEqual(result[0].explanation.assessment(for: other.id)?.conflict, .differentSerial)
        XCTAssertEqual(result[0].explanation.assessment(for: other.id)?.indexedUnderThisUUID, true)
        XCTAssertEqual(result[0].explanation.assessment(for: otherModel.id)?.conflict, .differentVendorOrModel)
    }

    /// Two displays present together tie for one record: neither gets it, and both are told why.
    func testARecordTwoPresentDisplaysTieForIsExplainedAsClaimedByAnother() async {
        let shared = record("disp_shared", fingerprint(serial: "S"), alias: "Left")
        let registry = await registry([shared], index: ["U1": "disp_shared", "U2": "disp_shared"])
        let result = await registry.resolveAllExplained([input(fingerprint(serial: "S"), "U1"),
                                                         input(fingerprint(serial: "S"), "U2")])
        XCTAssertTrue(result.allSatisfy(\.record.isProvisional))
        for entry in result {
            XCTAssertEqual(entry.explanation.decision, .ambiguous([shared.id], .claimedByAnotherDisplay))
        }
    }

    /// The weaker claimant loses the record to the stronger one and resolves again without it; its
    /// explanation is the second round's, with the held record marked.
    func testAnOutrankedDisplayIsExplainedByItsRetry() async {
        let known = record("disp_a", fingerprint(serial: "A"))
        let registry = await registry([known], index: ["U2": "disp_a"])
        // U1 claims by serial, U2 only through the index (it reports no serial): serial wins.
        let result = await registry.resolveAllExplained([input(fingerprint(serial: "A"), "U1"),
                                                         input(fingerprint(), "U2")])
        XCTAssertEqual(result[0].record.id, known.id)
        XCTAssertEqual(result[0].explanation.decision, .record(known.id, .serial))
        XCTAssertNotEqual(result[1].record.id, known.id)
        XCTAssertEqual(result[1].explanation.assessment(for: known.id)?.heldByAnotherDisplay, true)
        if case .record(let id, _) = result[1].explanation.decision {
            XCTAssertEqual(id, result[1].record.id)
        } else if case .newRecord = result[1].explanation.decision {
            XCTAssertFalse(result[1].record.isProvisional)
        } else {
            XCTFail("unexpected decision \(result[1].explanation.decision)")
        }
    }

    /// The before/after view: compared against what the record remembered before this resolve.
    func testFieldComparisonIsAgainstTheRecordBeforeItWasMerged() async {
        let known = record("disp_a", fingerprint(model: "Old name", width: 600, height: 340))
        let registry = await registry([known], index: ["U1": "disp_a"])
        let result = await registry.resolveAllExplained([
            input(fingerprint(serial: "NEW", model: "New name", width: 600, height: 340), "U1")])
        let fields = Dictionary(uniqueKeysWithValues: (result[0].explanation.assessment(for: known.id)?.fields ?? [])
            .map { ($0.field, $0.agreement) })
        XCTAssertEqual(fields[.serial], .onlyCurrent)
        XCTAssertEqual(fields[.modelName], .different)
        XCTAssertEqual(fields[.physicalSize], .same)
        XCTAssertEqual(fields[.vendor], .same)
        XCTAssertEqual(fields[.edid], .neither)
    }

    func testExplainMatchAsksWithoutChangingAnything() async {
        let known = record("disp_a", fingerprint(serial: "A"))
        let registry = await registry([known])
        let explanation = await registry.explainMatch(fingerprint: fingerprint(serial: "A"), cgUUID: "U5")
        XCTAssertEqual(explanation.decision, .record(known.id, .serial))
        let state = await registry.currentState()
        XCTAssertTrue(state.cgUUIDIndex.isEmpty, "explaining is not resolving")
        XCTAssertEqual(state.records.first?.lastSeen, known.lastSeen)
    }

    // MARK: - Physical identity

    func testPhysicalIdentityNeverClaimsMoreThanTheEvidence() {
        XCTAssertEqual(FingerprintComparison.physicalIdentity(fingerprint(serial: "A"), fingerprint(serial: "A")),
                       .sameSerial)
        XCTAssertEqual(FingerprintComparison.physicalIdentity(fingerprint(serial: "A"), fingerprint(serial: "B")),
                       .differentDisplays)
        XCTAssertEqual(FingerprintComparison.physicalIdentity(fingerprint(product: 1), fingerprint(product: 2)),
                       .differentDisplays)
        XCTAssertEqual(FingerprintComparison.physicalIdentity(fingerprint(serial: "A"), fingerprint()),
                       .undetermined, "a missing serial is not a different display")
        XCTAssertEqual(FingerprintComparison.physicalIdentity(fingerprint(vendor: nil, serial: "A"),
                                                              fingerprint(vendor: nil, serial: "A")),
                       .undetermined, "a serial without vendor and model qualifies nothing")
    }

    // MARK: - Registry transfer

    func testTransferMovesNameAndTagsAndRemovesTheSourceWithoutMergingIdentities() async {
        var old = record("disp_old", fingerprint(serial: "OLD"), alias: "Desk")
        old.tags = ["studio"]
        var new = record("disp_new", fingerprint(serial: "NEW"), alias: "Fresh")
        new.tags = ["temp"]
        let registry = await registry([old, new], index: ["U-old": "disp_old", "U-old2": "disp_old", "U-new": "disp_new"])
        let provenance = DisplayRecordProvenance(kind: .transferredFrom, date: Date(timeIntervalSince1970: 5),
                                                 sourceName: "Desk", sourceRecordID: old.id,
                                                 sourceObservationIDs: [.forCGUUID("U-old")], categories: ["name"])
        let result = await registry.transferUserData(from: old.id, to: new.id, alias: true, tags: true,
                                                     provenance: provenance)
        XCTAssertEqual(result, new.id)
        let state = await registry.currentState()
        XCTAssertEqual(state.records.map(\.id), [new.id], "the source record is gone")
        XCTAssertEqual(state.cgUUIDIndex, ["U-new": new.id], "and every index entry pointing at it")
        let moved = state.records[0]
        XCTAssertEqual(moved.alias, "Desk")
        XCTAssertEqual(moved.tags, ["studio"], "replaced, not merged")
        XCTAssertEqual(moved.fingerprint.serialNumber, "NEW", "the destination keeps its own identity")
        XCTAssertEqual(moved.provenance, [provenance])
        // The old display, seen again, is a new display — not the destination.
        let returning = await registry.resolve(fingerprint: fingerprint(serial: "OLD"), cgUUID: "U-old")
        XCTAssertNotEqual(returning.id, new.id)
        XCTAssertNil(returning.alias)
    }

    func testTransferOnlyMovesTheSelectedParts() async {
        var old = record("disp_old", fingerprint(serial: "OLD"), alias: "Desk")
        old.tags = ["studio"]
        var new = record("disp_new", fingerprint(serial: "NEW"), alias: "Fresh")
        new.tags = ["temp"]
        let registry = await registry([old, new])
        let provenance = DisplayRecordProvenance(kind: .transferredFrom, date: Date(), sourceName: "Desk",
                                                 sourceObservationIDs: [], categories: ["tags"])
        await registry.transferUserData(from: old.id, to: new.id, alias: false, tags: true, provenance: provenance)
        let moved = await registry.record(for: new.id)
        XCTAssertEqual(moved?.alias, "Fresh")
        XCTAssertEqual(moved?.tags, ["studio"])
    }

    func testTransferOntoAProvisionalDisplayMakesItARecordOfItsOwn() async {
        let shared = record("disp_shared", fingerprint(serial: "S"), alias: "Left")
        let registry = await registry([shared], index: ["U1": "disp_shared", "U2": "disp_shared"])
        let provisional = await registry.resolveAll([input(fingerprint(serial: "S"), "U1"),
                                                     input(fingerprint(serial: "S"), "U2")])
        XCTAssertTrue(provisional[0].isProvisional)
        let provenance = DisplayRecordProvenance(kind: .transferredFrom, date: Date(), sourceName: "Left",
                                                 sourceRecordID: shared.id, sourceObservationIDs: [], categories: ["name"])
        let id = await registry.transferUserData(from: shared.id, to: provisional[0].id, alias: true, tags: false,
                                                 provenance: provenance)
        XCTAssertNotNil(id)
        XCTAssertNotEqual(id, provisional[0].id)
        let state = await registry.currentState()
        XCTAssertEqual(state.records.map(\.id), [id!])
        XCTAssertEqual(state.records.first?.alias, "Left")
        XCTAssertEqual(state.cgUUIDIndex, ["U1": id!])
    }

    func testTransferRefusesItselfAndUnknownDestinations() async {
        let only = record("disp_a", fingerprint(serial: "A"), alias: "A")
        let registry = await registry([only])
        let provenance = DisplayRecordProvenance(kind: .transferredFrom, date: Date(), sourceName: "",
                                                 sourceObservationIDs: [], categories: [])
        let same = await registry.transferUserData(from: only.id, to: only.id, alias: true, tags: true, provenance: provenance)
        XCTAssertNil(same)
        let unknown = await registry.transferUserData(from: only.id, to: DisplayRecordID(rawValue: "disp_none"),
                                                      alias: true, tags: true, provenance: provenance)
        XCTAssertNil(unknown)
        let records = await registry.allRecords()
        XCTAssertEqual(records, [only], "a refused transfer changes nothing")
    }

    func testResetClearsProvenanceAndMigrationAppendsIt() async {
        let known = record("disp_a", fingerprint(serial: "A"), alias: "A")
        let registry = await registry([known])
        let provenance = DisplayRecordProvenance(kind: .migratedFrom, date: Date(timeIntervalSince1970: 1),
                                                 sourceName: "A", sourceObservationIDs: [.forCGUUID("U-old")],
                                                 categories: ["favoriteModes"])
        await registry.appendProvenance(provenance, to: known.id)
        let appended = await registry.record(for: known.id)
        XCTAssertEqual(appended?.provenance, [provenance])
        await registry.clearUserData(for: known.id)
        let cleared = await registry.record(for: known.id)
        XCTAssertNil(cleared?.provenance)
        XCTAssertNil(cleared?.alias)
    }

    // MARK: - Persistence compatibility

    func testARecordWithoutProvenanceReadsAndWritesAsBefore() throws {
        let json = #"{"id":{"rawValue":"disp_1"},"tags":[],"fingerprint":{},"displayClass":"external","pairingConfirmed":false}"#
        let decoded = try JSONDecoder().decode(DisplayRecord.self, from: Data(json.utf8))
        XCTAssertNil(decoded.provenance)
        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        XCTAssertFalse(encoded.contains("provenance"))
    }

    func testMintedIDsCarryTheirFirstSeenMoment() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(DisplayRecordID.generate(now: now).mintedAt, now)
        XCTAssertNil(DisplayRecordID.forCGUUID("U1").mintedAt)
        XCTAssertNil(DisplayRecordID(rawValue: "disp_notanumber_X").mintedAt)
    }
}
