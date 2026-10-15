import XCTest
@testable import AutomationSchema
import DisplayDomain

final class IntegrationFeedParserTests: XCTestCase {
    func testFeedSharesAuthenticatedHTTPCommandRoute() throws {
        let control = UUID()
        let body = try JSONSerialization.data(withJSONObject: ["command": "feed", "displayId": "desk", "control": control.uuidString, "response": "ON\n"])
        func wire(_ token: String) -> Data {
            var data = Data("POST /v1/command HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nAuthorization: Bearer \(token)\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
            data.append(body); return data
        }
        guard case .command(let request, _) = LocalHTTPControl.parse(wire("secret"), token: "secret") else { return XCTFail("Authorized feed must parse") }
        XCTAssertEqual(request.command, .feedIntegration(control: control, response: "ON\n"))
        XCTAssertEqual(LocalHTTPControl.parse(wire("wrong"), token: "secret"), .rejected(401))
    }
    func testFeedUsesSharedSelectorsAndPreservesExactResponse() throws {
        let control = UUID()
        let request = try AutomationRequestParser.parse(verb: "feed", parameters: ["display": .string("id:desk"), "control": .string(control.uuidString), "response": .string("ON\n")])
        XCTAssertEqual(request, AutomationRequest(.feedIntegration(control: control, response: "ON\n"), target: .display(.id(.init(rawValue: "desk"))), targetText: "id:desk"))
        XCTAssertEqual(try JSONDecoder().decode(AutomationRequest.self, from: JSONEncoder().encode(request)), request)
        XCTAssertThrowsError(try AutomationRequestParser.parse(verb: "feed", parameters: ["display": .string("id:desk"), "control": .string("invalid"), "response": .string("ON")]))
        XCTAssertThrowsError(try AutomationRequestParser.parse(verb: "feed", parameters: ["control": .string(control.uuidString), "response": .string("ON")]))
    }
}

@MainActor final class IntegrationFeedEngineTests: XCTestCase {
    func testFeedUpdatesSampleWithNoSetterAndUsesSharedOutcomeMapping() async throws {
        let environment = FeedEnvironment(), control = UUID()
        let request = AutomationRequest.byID(.feedIntegration(control: control, response: "ON\n"), environment.id)
        let result = await AutomationEngine(environment: environment).run(request)
        XCTAssertTrue(result.succeeded); XCTAssertEqual(result.integrationSample?.source, .feed)
        XCTAssertEqual(result.integrationSample?.value, .boolean(true)); XCTAssertEqual(environment.setterCalls, 0)
        XCTAssertEqual(environment.feeds, 1)
        XCTAssertEqual(try JSONDecoder().decode(AutomationResult.self, from: JSONEncoder().encode(result)), result)
    }
    func testFeedDryRunAndForbiddenSurfaceNeverInvokeParserOrSetter() async {
        let environment = FeedEnvironment(), control = UUID()
        let dryRun = AutomationRequest.byID(.feedIntegration(control: control, response: "ON\n"), environment.id, dryRun: true)
        _ = await AutomationEngine(environment: environment).run(dryRun)
        XCTAssertEqual(environment.feeds, 0)
        let forbidden = FeedEnvironment(surface: .url)
        let result = await AutomationEngine(environment: forbidden).run(.byID(.feedIntegration(control: control, response: "ON\n"), environment.id))
        XCTAssertFalse(result.succeeded); XCTAssertEqual(forbidden.feeds, 0)
    }
    func testMalformedReadbackFailsWithoutSetterAndAmbiguityDoesNotBroaden() async {
        let environment = FeedEnvironment(), control = UUID()
        let bad = await AutomationEngine(environment: environment).run(.byID(.feedIntegration(control: control, response: "ON"), environment.id))
        XCTAssertFalse(bad.succeeded); XCTAssertEqual(environment.setterCalls, 0)
        let ambiguous = await AutomationEngine(environment: environment).run(.init(.feedIntegration(control: control, response: "ON\n"), target: .nameContains("Desk")))
        XCTAssertEqual(ambiguous.issue?.code, .ambiguousSelector)
    }
}

@MainActor private final class FeedEnvironment: AutomationEnvironment {
    nonisolated let surface: AutomationSurface
    let id = DisplayRecordID(rawValue: "desk")
    var feeds = 0, setterCalls = 0
    init(surface: AutomationSurface = .http) { self.surface = surface }
    func displaySet() async -> AutomationDisplaySet {
        .init(candidates: [.init(id: id, name: "Desk", availability: .active), .init(id: .init(rawValue: "desk2"), name: "Desk 2", availability: .active)])
    }
    func feedIntegration(control: UUID, response: String, display: AutomationDisplayCandidate) async throws(AutomationIssue) -> IntegrationSample {
        do {
            let value = try IntegrationReadback.boolean(on: "ON\n", off: "OFF\n", regex: false).parse(response)
            feeds += 1; return .init(value: value, at: Date(timeIntervalSince1970: 0), source: .feed)
        } catch { throw .init(.invalidValue, "Readback did not match") }
    }
    func writeBrightness(_ level: AutomationLevel, to display: AutomationDisplayCandidate, via route: BrightnessRoute) async throws(AutomationIssue) -> BrightnessWriteReport {
        setterCalls += 1; throw .init(.executionFailed, "Setter must not run")
    }
}
