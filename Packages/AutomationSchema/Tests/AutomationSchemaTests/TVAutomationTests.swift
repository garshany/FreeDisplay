import DisplayDomain
import Foundation
import XCTest
@testable import AutomationSchema

private actor FakeTVEnvironment: AutomationEnvironment {
    nonisolated let surface: AutomationSurface
    let candidates: [AutomationDisplayCandidate]
    let receipt: TVCommandReceipt
    let ready: Bool
    private(set) var writes: [String] = []
    init(surface: AutomationSurface = .console, candidates: [AutomationDisplayCandidate], ready: Bool = true,
         receipt: TVCommandReceipt = TVCommandReceipt(.sent)) {
        self.surface = surface; self.candidates = candidates; self.ready = ready; self.receipt = receipt
    }
    func displaySet() async -> AutomationDisplaySet { AutomationDisplaySet(candidates: candidates) }
    func tvCanPerform(_ action: TVAction, on display: AutomationDisplayCandidate) async -> Bool { ready }
    func tvControl(_ action: TVAction, on display: AutomationDisplayCandidate) async throws(AutomationIssue) -> TVCommandReceipt {
        writes.append(display.id.rawValue + ":" + action.name)
        return receipt
    }
}

final class TVAutomationTests: XCTestCase {
    private let id = DisplayRecordID(rawValue: "tv:chosen")
    private var candidate: AutomationDisplayCandidate {
        AutomationDisplayCandidate(id: id, name: "TV", availability: .active)
    }
    func testSharedParserSelectsExplicitTVActionsAndRejectsExtraParameters() throws {
        let request = try AutomationRequestParser.parse(verb: "tv-control", parameters: [
            "display": .string("id:tv:chosen"), "action": .string("switchInput"), "input": .string("HDMI_1")])
        XCTAssertEqual(request.command, .tvControl(.switchInput("HDMI_1")))
        XCTAssertEqual(request.target, .display(.id(id)))
        for parameters: [String: AutomationParameterValue] in [
            ["action": .string("volumeUp")],
            ["display": .string("TV"), "action": .string("setVolume"), "value": .number(0.2)],
            ["display": .string("TV"), "action": .string("volumeUp"), "input": .string("HDMI_1")],
            ["display": .string("TV"), "action": .string("switchInput")],
            ["display": .string("TV"), "action": .string("serviceMenu")]
        ] { XCTAssertThrowsError(try AutomationRequestParser.parse(verb: "tvControl", parameters: parameters)) }
    }

    func testRequestsAndResultsRoundTripWithoutCredentials() async throws {
        let request = AutomationRequest.byID(.tvControl(.switchInput("HDMI_1")), id)
        let encoded = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(AutomationRequest.self, from: encoded), request)
        let environment = FakeTVEnvironment(candidates: [candidate], receipt: TVCommandReceipt(.acknowledged))
        let result = await AutomationEngine(environment: environment).run(request)
        XCTAssertEqual(try JSONDecoder().decode(AutomationResult.self, from: JSONEncoder().encode(result)), result)
        XCTAssertEqual(result.tv?.delivery, .acknowledged)
        XCTAssertEqual(AutomationOutcomeKind(result), .requested)
        XCTAssertEqual(result.envelope.targets.first?.operations.first?.verification, .readBackUnavailable)
    }

    func testDeniedWriteUsesTheExistingFailureMappings() async {
        let environment = FakeTVEnvironment(candidates: [candidate], receipt: TVCommandReceipt(.failed))
        let result = await AutomationEngine(environment: environment).run(.byID(.tvControl(.powerOff), id))
        XCTAssertEqual(result.issue?.code, .executionFailed)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(CLIExitCode(result), .failure)
        XCTAssertEqual(AutomationHTTPStatus.code(for: result), 502)
        XCTAssertEqual(AutomationOutcomeKind(result), .failed)
    }

    func testMissingAmbiguousAndUnreadyTargetsDoNotWrite() async {
        let requests = [AutomationRequest(.tvControl(.volumeDown)),
                        AutomationRequest(.tvControl(.volumeDown), target: .display(.name("TV")))]
        let ambiguous = FakeTVEnvironment(candidates: [candidate, AutomationDisplayCandidate(id: .init(rawValue: "other"), name: "TV", availability: .active)])
        for request in requests {
            let result = await AutomationEngine(environment: ambiguous).run(request)
            XCTAssertNotNil(result.issue)
        }
        let ambiguousWrites = await ambiguous.writes
        XCTAssertTrue(ambiguousWrites.isEmpty)
        let unready = FakeTVEnvironment(candidates: [candidate], ready: false)
        let result = await AutomationEngine(environment: unready).run(.byID(.tvControl(.volumeDown), id))
        XCTAssertEqual(result.issue?.code, .capabilityUnavailable)
        let writes = await unready.writes
        XCTAssertTrue(writes.isEmpty)
    }

    func testOnlyWakeMayTargetRememberedOfflineTV() async {
        var offline = candidate; offline.availability = .disconnected
        let environment = FakeTVEnvironment(candidates: [offline])
        let normal = await AutomationEngine(environment: environment).run(.byID(.tvControl(.volumeDown), id))
        XCTAssertEqual(normal.issue?.code, .displayNotConnected)
        let wake = await AutomationEngine(environment: environment).run(.byID(.tvControl(.wake), id))
        XCTAssertNil(wake.issue)
        XCTAssertEqual(AutomationOutcomeKind(wake), .requested)
        let writes = await environment.writes
        XCTAssertEqual(writes, ["tv:chosen:wake"])
    }

    func testDryRunDoesNotSendAndOtherSurfacesRefusePairingSideEffects() async {
        let environment = FakeTVEnvironment(candidates: [candidate])
        let result = await AutomationEngine(environment: environment).run(.byID(.tvControl(.muteToggle), id, dryRun: true))
        XCTAssertTrue(result.dryRun)
        let writes = await environment.writes
        XCTAssertTrue(writes.isEmpty)
        for surface in [AutomationSurface.cli, .url, .http, .appIntent] {
            let refused = FakeTVEnvironment(surface: surface, candidates: [candidate])
            let result = await AutomationEngine(environment: refused).run(.byID(.tvControl(.powerOff), id))
            XCTAssertNotNil(result.issue)
            let writes = await refused.writes
            XCTAssertTrue(writes.isEmpty)
        }
    }
}
