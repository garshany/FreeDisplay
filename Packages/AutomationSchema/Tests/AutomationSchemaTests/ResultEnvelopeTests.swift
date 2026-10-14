import XCTest
import DisplayDomain
@testable import AutomationSchema

final class ResultEnvelopeTests: XCTestCase {
    func testRoundTripPreservesAllFields() throws {
        let envelope = ResultEnvelope(
            transactionId: "txn_1",
            status: .committed,
            actor: .cli,
            requestedAt: Date(timeIntervalSince1970: 1_700_000_000),
            topologyGeneration: 419,
            targets: [
                .init(displayId: "disp_1", alias: "DeskLeft", identityConfidence: 0.98, operations: [
                    .init(field: "lifecycle.connected",
                          requested: .bool(false),
                          observed: .bool(false),
                          verification: .verified,
                          provider: "experimentalLifecycle.v1")
                ])
            ],
            recovery: .init(checkpointId: "cp_1", available: true)
        )

        let data = try ResultEnvelope.makeEncoder().encode(envelope)
        let decoded = try ResultEnvelope.makeDecoder().decode(ResultEnvelope.self, from: data)
        XCTAssertEqual(decoded, envelope)
    }

    func testUnknownFieldsAreIgnored() throws {
        // Forward compatibility (AUT-012): a client on schema 1.0 must ignore unknown fields.
        let json = """
        {
          "schemaVersion": "1.1",
          "transactionId": "txn_9",
          "status": "noOp",
          "actor": "ui",
          "requestedAt": "2026-06-22T00:00:00Z",
          "topologyGeneration": 1,
          "targets": [],
          "errors": [],
          "futureOnlyField": { "nested": true }
        }
        """
        let data = Data(json.utf8)
        let decoded = try ResultEnvelope.makeDecoder().decode(ResultEnvelope.self, from: data)
        XCTAssertEqual(decoded.status, .noOp)
        XCTAssertEqual(decoded.transactionId, "txn_9")
    }

    func testAnyCodableValueVariants() throws {
        let values: [AnyCodableValue] = [.bool(true), .int(42), .double(3.5), .string("hi")]
        for value in values {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: data)
            XCTAssertEqual(decoded, value)
        }
    }

    func testCurrentSchemaVersionDefault() {
        let envelope = ResultEnvelope(transactionId: "t", status: .failed, actor: .ui,
                                      requestedAt: Date(), topologyGeneration: 0)
        XCTAssertEqual(envelope.schemaVersion, "1.0")
    }

    // MARK: Outcomes (IN-02)

    func testOperationWithoutOutcomeStillDecodes() throws {
        // Envelopes written before `outcome` existed must keep decoding.
        let json = #"{"field":"reconnect","verification":"verified","warnings":[]}"#
        let decoded = try JSONDecoder().decode(ResultEnvelope.OperationResult.self, from: Data(json.utf8))
        XCTAssertNil(decoded.outcome)
        XCTAssertEqual(decoded.verification, .verified)
    }

    func testOutcomeRoundTrips() throws {
        let operation = ResultEnvelope.OperationResult(
            field: "brightness", requested: .double(0.6), observed: .double(0.55),
            verification: .readBackUnavailable, provider: "ddc", warnings: ["read back 55%"],
            outcome: .sent)
        let data = try JSONEncoder().encode(operation)
        XCTAssertEqual(try JSONDecoder().decode(ResultEnvelope.OperationResult.self, from: data), operation)
    }

    func testAggregateNeverRoundsAProblemUpToCommitted() {
        XCTAssertEqual(ResultEnvelope.Status.aggregate([]), .noOp)
        XCTAssertEqual(ResultEnvelope.Status.aggregate([.alreadySatisfied, .alreadySatisfied]), .noOp)
        XCTAssertEqual(ResultEnvelope.Status.aggregate([.verified, .sent, .alreadySatisfied]), .committed)
        XCTAssertEqual(ResultEnvelope.Status.aggregate([.verified, .failed]), .partial)
        XCTAssertEqual(ResultEnvelope.Status.aggregate([.alreadySatisfied, .skipped]), .partial)
        XCTAssertEqual(ResultEnvelope.Status.aggregate([.sent, .unsupported]), .partial)
        XCTAssertEqual(ResultEnvelope.Status.aggregate([.failed]), .failed)
        XCTAssertEqual(ResultEnvelope.Status.aggregate([.unsupported, .skipped]), .failed)
    }

    func testReconnectAllEnvelopeReportsEachDisplay() {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let none = ResultEnvelope.reconnectAll(results: [], actor: .httpAPI, requestedAt: at,
                                               topologyGeneration: 3)
        XCTAssertEqual(none.status, .noOp)
        XCTAssertTrue(none.targets.isEmpty)
        XCTAssertEqual(none.actor, .httpAPI)

        let mixed = ResultEnvelope.reconnectAll(
            results: [("cg:a", true), ("cg:b", false)], actor: .url, requestedAt: at, topologyGeneration: 3)
        XCTAssertEqual(mixed.status, .partial)
        XCTAssertEqual(mixed.targets.map(\.displayId), ["cg:a", "cg:b"])
        XCTAssertEqual(mixed.targets[0].operations.first?.verification, .verified)
        XCTAssertEqual(mixed.targets[1].operations.first?.outcome, .failed)
        XCTAssertEqual(mixed.errors.map(\.code), ["notReconnected"])

        let allFailed = ResultEnvelope.reconnectAll(
            results: [("cg:b", false)], actor: .appIntent, requestedAt: at, topologyGeneration: 3)
        XCTAssertEqual(allFailed.status, .failed)
    }
}
