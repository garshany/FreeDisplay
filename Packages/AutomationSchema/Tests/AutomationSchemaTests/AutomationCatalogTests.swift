import DisplayDomain
import XCTest
@testable import AutomationSchema

final class AutomationCatalogTests: XCTestCase {
    func testEveryCommandHasExactlyOneDescriptor() {
        for name in AutomationCommandName.allCases {
            XCTAssertEqual(AutomationCatalog.descriptors.filter { $0.name == name }.count, 1, name.rawValue)
        }
        XCTAssertEqual(AutomationCatalog.descriptors.count, AutomationCommandName.allCases.count)
    }

    /// Only `brightness`, `mode` and `profile` choose between commands by their parameters; any other
    /// alias must name one command, and no alias may shadow a canonical name.
    func testAliasesAreUnambiguous() {
        let multi: Set<String> = ["brightness", "contrast", "mode", "profile", "colorprofile"]
        var owners: [String: Set<AutomationCommandName>] = [:]
        for descriptor in AutomationCatalog.descriptors {
            for alias in descriptor.aliases {
                XCTAssertEqual(alias, AutomationCatalog.normalize(alias), "aliases are stored normalized")
                owners[alias, default: []].insert(descriptor.name)
            }
        }
        for (alias, names) in owners where names.count > 1 {
            XCTAssertTrue(multi.contains(alias), "'\(alias)' names \(names)")
        }
        let canonical = Set(AutomationCommandName.allCases.map { $0.rawValue.lowercased() })
        XCTAssertTrue(canonical.isDisjoint(with: owners.keys))
    }

    func testLinksCarryOnlyTheRecoveryAction() {
        XCTAssertEqual(AutomationCatalog.descriptors(for: .url).map(\.name), [.reconnectAll])
    }

    /// Arrangement changes run only where the app's keep-or-revert path is (owner: main and mode
    /// changes go through keep/revert everywhere), never from a separate CLI process or a link.
    func testArrangementChangesStayOnTheApp() {
        for descriptor in AutomationCatalog.descriptors where descriptor.effect == .arrangement {
            XCTAssertEqual(descriptor.surfaces, [.cli, .http, .appIntent, .console], descriptor.name.rawValue)
        }
        XCTAssertEqual(AutomationCatalog.descriptor(for: .disconnect).surfaces, [.cli])
    }

    func testEveryTargetedCommandDocumentsItsDisplayParameter() {
        for descriptor in AutomationCatalog.descriptors where descriptor.target != .none {
            XCTAssertTrue(descriptor.parameters.contains { $0.name == "display" && $0.kind == .selector },
                          descriptor.name.rawValue)
        }
    }

    // MARK: Outcome mapping

    private func result(_ status: ResultEnvelope.Status, issue: AutomationIssue? = nil,
                        outcomes: [OperationOutcome] = []) -> AutomationResult {
        let envelope = ResultEnvelope(
            transactionId: "t", status: status, actor: .cli, requestedAt: Date(timeIntervalSince1970: 0),
            topologyGeneration: 0,
            targets: [.init(displayId: "x", alias: nil, identityConfidence: 1,
                            operations: outcomes.map { .init(field: "f", verification: .notApplicable, outcome: $0) })])
        return AutomationResult(command: .setBrightness, envelope: envelope, issue: issue)
    }

    func testCLIExitCodes() {
        XCTAssertEqual(CLIExitCode(result(.committed)), .success)
        XCTAssertEqual(CLIExitCode(result(.noOp)), .success)
        XCTAssertEqual(CLIExitCode(result(.partial)), .partial)
        XCTAssertEqual(CLIExitCode(result(.failed, issue: AutomationIssue(.ambiguousSelector, "x"))), .failure)
        XCTAssertEqual(CLIExitCode(result(.failed, issue: AutomationIssue(.invalidValue, "x"))), .usage)
        XCTAssertEqual(CLIExitCode(result(.failed, issue: AutomationIssue(.unknownCommand, "x"))), .usage)
    }

    func testHTTPStatusesDistinguishEveryKindOfRefusal() {
        let expected: [AutomationIssue.Code: Int] = [
            .unknownCommand: 404, .unknownParameter: 400, .missingParameter: 400, .conflictingParameters: 400,
            .invalidValue: 400, .invalidSelector: 400, .displayNotFound: 404, .ambiguousSelector: 409,
            .unknownGroup: 404, .unsupportedSelector: 422, .displayNotConnected: 409, .displayInactive: 409,
            .methodUnavailable: 422, .capabilityUnavailable: 422, .modeNotOffered: 422, .ambiguousMode: 409,
            .profileNotFound: 404, .ambiguousProfile: 409, .busy: 409, .confirmationRequired: 409,
            .refusedFromSurface: 403, .notReady: 503, .executionFailed: 502, .notConfirmed: 502,
        ]
        XCTAssertEqual(Set(expected.keys), Set(AutomationIssue.Code.allCases), "every code has a status")
        for (code, status) in expected {
            XCTAssertEqual(AutomationHTTPStatus.code(for: AutomationIssue(code, "x")), status, code.rawValue)
        }
        XCTAssertEqual(AutomationHTTPStatus.code(for: result(.committed)), 200)
        XCTAssertEqual(AutomationHTTPStatus.code(for: result(.noOp)), 200)
        XCTAssertEqual(AutomationHTTPStatus.code(for: result(.partial)), 207)
    }

    func testIntentOutcomeWords() {
        XCTAssertEqual(AutomationOutcomeKind(result(.committed, outcomes: [.verified])), .done)
        XCTAssertEqual(AutomationOutcomeKind(result(.committed, outcomes: [.sent])), .requested)
        XCTAssertEqual(AutomationOutcomeKind(result(.noOp, outcomes: [.alreadySatisfied])), .alreadyInEffect)
        XCTAssertEqual(AutomationOutcomeKind(result(.noOp)), .done)
        XCTAssertEqual(AutomationOutcomeKind(result(.partial, outcomes: [.verified, .failed])), .partial)
        XCTAssertEqual(AutomationOutcomeKind(result(.failed, issue: AutomationIssue(.busy, "x"))), .failed)
    }

    func testIssueCategories() {
        XCTAssertEqual(AutomationIssue(.invalidValue, "x").category, .usage)
        XCTAssertEqual(AutomationIssue(.displayNotConnected, "x").category, .target)
        XCTAssertEqual(AutomationIssue(.methodUnavailable, "x").category, .unsupported)
        XCTAssertEqual(AutomationIssue(.busy, "x").category, .conflict)
        XCTAssertEqual(AutomationIssue(.refusedFromSurface, "x").category, .forbidden)
        XCTAssertEqual(AutomationIssue(.notReady, "x").category, .unavailable)
        XCTAssertEqual(AutomationIssue(.notConfirmed, "x").category, .execution)
    }

    func testResultsRoundTripThroughJSON() throws {
        var original = result(.committed, outcomes: [.verified])
        original.brightness = AutomationBrightnessReport(
            displayId: "x", displayName: "X", route: .ddc, requested: AutomationLevel(normalized: 0.4),
            level: AutomationLevel(normalized: 0.4), outcome: .verified, reportedByDisplay: true, raw: 28,
            rawMaximum: 70, note: nil)
        original.issue = AutomationIssue(.busy, "busy", subject: "x", candidates: ["a"])
        let decoded = try ResultEnvelope.makeDecoder().decode(AutomationResult.self, from: original.jsonData())
        XCTAssertEqual(decoded, original)
        let json = String(decoding: original.jsonData(), as: UTF8.self)
        XCTAssertTrue(json.contains("\"schemaVersion\" : \"1.0\""))
        XCTAssertTrue(json.contains("\"route\" : \"ddc\""))
    }
}
