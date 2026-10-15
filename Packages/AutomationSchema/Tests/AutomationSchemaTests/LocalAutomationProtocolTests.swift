import DisplayDomain
import Foundation
import XCTest
@testable import AutomationSchema

private actor IPCFake: AutomationEnvironment {
    nonisolated let surface: AutomationSurface = .cli
    var writes = 0
    var level = 0.4
    var accepts = true
    var readback: BrightnessReadback?
    let display = AutomationDisplayCandidate(id: .init(rawValue: "screen"), name: "Screen", groups: ["Desk"], availability: .active)
    func displaySet() async -> AutomationDisplaySet { .init(candidates: [display], knownGroups: ["Desk"]) }
    func brightnessRoutes(for display: AutomationDisplayCandidate) async -> BrightnessRouteAvailability {
        .init(current: .software, states: [.software: .available])
    }
    func adjustBrightness(by delta: AutomationLevelDelta, of display: AutomationDisplayCandidate,
                          via route: BrightnessRoute) async throws(AutomationIssue) -> BrightnessWriteReport {
        let target = AutomationLevel(clamping: level).offset(by: delta)
        level = target.normalized; writes += 1
        return .init(requested: target, accepted: true, readback: .applied(level))
    }
    func writeGroupBrightness(_ level: AutomationLevel, group: String, dryRun: Bool) async throws(AutomationIssue) -> ResultEnvelope {
        if !dryRun { writes += 1; self.level = level.normalized }
        return .init(transactionId: "group", status: .committed, actor: .cli, requestedAt: Date(), topologyGeneration: 0, targets: [])
    }
    func readContrast(of display: AutomationDisplayCandidate) async throws(AutomationIssue) -> BrightnessReadback {
        readback ?? .ddc(current: Int((level * 100).rounded()), max: 100)
    }
    func writeContrast(_ value: AutomationLevel, to display: AutomationDisplayCandidate) async throws(AutomationIssue) -> BrightnessWriteReport {
        writes += 1
        if accepts { level = value.normalized }
        return .init(requested: value, accepted: accepts,
                     readback: readback ?? .ddc(current: Int((level * 100).rounded()), max: 100))
    }
    func configure(accepts: Bool = true, readback: BrightnessReadback? = nil) {
        self.accepts = accepts; self.readback = readback
    }
}

final class LocalAutomationProtocolTests: XCTestCase, @unchecked Sendable {
    private typealias IPC = LocalAutomationProtocol
    private func exchange(_ request: IPC.Request, fake: IPCFake, state: IPC.State = .ready) async throws -> IPC.Response {
        let response = await IPC.respond(to: try JSONEncoder().encode(request), state: state) {
            await AutomationEngine(environment: fake).run($0)
        }
        return try JSONDecoder().decode(IPC.Response.self, from: JSONEncoder().encode(response))
    }
    func testConcurrentClientsCorrelateAndAccumulateOnOneEnvironment() async throws {
        let fake = IPCFake()
        let command = try AutomationRequestParser.parse(verb: "brightness", parameters: [
            "displayId": .string("screen"), "offset": .string("+5%")])
        let first = IPC.Request(command: command), second = IPC.Request(command: command)
        async let a = exchange(first, fake: fake)
        async let b = exchange(second, fake: fake)
        let (ra, rb) = try await (a, b)
        guard case .result = try ra.validated(for: first), case .result = try rb.validated(for: second) else {
            return XCTFail("each client needs a typed result")
        }
        XCTAssertThrowsError(try ra.validated(for: second))
        let level = await fake.level
        let writes = await fake.writes
        XCTAssertEqual(level, 0.5, accuracy: 0.00001)
        XCTAssertEqual(writes, 2)
    }
    func testMalformedAndUnknownVersionNeverDispatch() async throws {
        let fake = IPCFake()
        let malformed = await IPC.respond(to: Data("not json".utf8), state: .ready) {
            await AutomationEngine(environment: fake).run($0)
        }
        XCTAssertEqual(malformed.payload, .failure(.malformed))
        var request = IPC.Request(command: .byID(.setContrast(.init(normalized: 0.5)!), .init(rawValue: "screen")))
        request.version += 1
        let rejected = try await exchange(request, fake: fake)
        XCTAssertEqual(rejected.id, request.id)
        XCTAssertEqual(rejected.payload, .failure(.versionMismatch))
        let writes = await fake.writes
        XCTAssertEqual(writes, 0)
    }
    func testReadinessAndNotReadyDifferFromCommandFailure() async throws {
        let fake = IPCFake(), query = IPC.Request()
        for state in [IPC.State.starting, .ready, .stopping] {
            let response = try await exchange(query, fake: fake, state: state)
            XCTAssertEqual(response.payload, .readiness(state))
        }
        let command = IPC.Request(command: .byID(.getContrast, .init(rawValue: "screen")))
        let response = try await exchange(command, fake: fake, state: .starting)
        XCTAssertEqual(response.payload, .failure(.notReady))
        let unsupported = IPC.Request(command: .byID(.getMode, .init(rawValue: "screen")))
        guard case .result(let result) = try await exchange(unsupported, fake: fake).validated(for: unsupported) else {
            return XCTFail("unsupported is a command result, not transport failure")
        }
        XCTAssertEqual(result.issue?.code, .capabilityUnavailable)
        let displayRequest = IPC.Request(command: .init(.listDisplays))
        guard case .result(let list) = try await exchange(displayRequest, fake: fake).validated(for: displayRequest) else {
            return XCTFail("missing property result")
        }
        XCTAssertEqual(list.displays?.first?.isBuiltIn, false)
    }
    func testReadinessCannotBeSubstitutedForCommandResult() {
        let request = IPC.Request(command: .init(.listDisplays))
        XCTAssertThrowsError(try IPC.Response(id: request.id, payload: .readiness(.ready)).validated(for: request))
    }
    func testIPCDoesNotImpersonateAppIntentForConfirmationBypass() async throws {
        let fake = IPCFake()
        let request = IPC.Request(command: .byID(.setMode(.logical(width: 100, height: 100, refreshHz: nil, hiDPI: nil),
                                                                 keepWithoutConfirmation: true), .init(rawValue: "screen")))
        guard case .result(let result) = try await exchange(request, fake: fake).validated(for: request) else { return XCTFail() }
        XCTAssertEqual(result.issue?.code, .refusedFromSurface)
    }
    func testContrastUsesSharedUnitsAndTruthfulSettlement() async throws {
        let fake = IPCFake()
        let request = try AutomationRequestParser.parse(verb: "contrast", parameters: ["displayId": .string("screen"), "value": .string("40%")])
        XCTAssertEqual(request.command, .setContrast(.init(normalized: 0.4)!))
        let result = await AutomationEngine(environment: fake).run(request)
        XCTAssertEqual(result.contrast?.outcome, .verified)
        XCTAssertEqual(result.contrast?.raw, 40)
        XCTAssertEqual(result.envelope.targets.first?.operations.first?.field, "contrast")
        await fake.configure(accepts: false)
        let failed = await AutomationEngine(environment: fake).run(request)
        XCTAssertEqual(CLIExitCode(failed), .failure)
        XCTAssertEqual(AutomationHTTPStatus.code(for: failed), 502)
    }
    func testContrastRefusalsNeverWrite() async throws {
        let fake = IPCFake()
        await fake.configure(readback: BrightnessReadback.none)
        let unavailable = await AutomationEngine(environment: fake).run(.byID(.setContrast(.init(normalized: 0.5)!), .init(rawValue: "screen")))
        XCTAssertEqual(unavailable.issue?.code, .methodUnavailable)
        for value in ["25", "nan", "inf", "-1", "101%"] {
            XCTAssertThrowsError(try AutomationRequestParser.parse(verb: "contrast", parameters: ["displayId": .string("screen"), "value": .string(value)]))
        }
        let unknown = await AutomationEngine(environment: fake).run(.byID(.getContrast, .init(rawValue: "missing")))
        XCTAssertEqual(unknown.issue?.code, .displayNotFound)
        let writes = await fake.writes
        XCTAssertEqual(writes, 0)
    }
    func testCLIAdapterUsesSharedParserAndCallerTimeout() throws {
        guard case .run(let invocation) = try CLIGrammar.parse(["brightness", "name:Экран", "--offset", "-5%", "--timeout", "12.75"]) else { return XCTFail() }
        XCTAssertEqual(try CLIAppRequest.timeout(invocation), 12.75)
        XCTAssertEqual(try CLIAppRequest.request(invocation)?.command, .adjustBrightness(.init(normalized: -0.05)!, method: .automatic))
        XCTAssertNil(try CLIAppRequest.timeout(.init(command: "ready")))
        for timeout in ["0", "-1", "nan", "inf"] {
            XCTAssertThrowsError(try CLIAppRequest.timeout(.init(command: "ready", values: ["--timeout": timeout])))
        }
        let mode = try CLIAppRequest.request(.init(command: "mode", positional: ["id:screen", "1920x1080@60"]))
        XCTAssertEqual(mode?.command.name, .setMode)
        XCTAssertThrowsError(try CLIAppRequest.request(.init(command: "command", positional: ["brightness", "display=id:a", "display=id:b"])))
    }
    func testExplicitGroupBaseUsesOneAppPolicyOperationAndRejectsOffset() async throws {
        let fake = IPCFake()
        let request = try AutomationRequestParser.parse(verb: "brightness", parameters: ["display": .string("group:desk"), "value": .string("70%")])
        let result = await AutomationEngine(environment: fake).run(request)
        XCTAssertTrue(result.succeeded)
        let offset = try AutomationRequestParser.parse(verb: "brightness", parameters: ["display": .string("group:desk"), "offset": .string("+5%")])
        let refused = await AutomationEngine(environment: fake).run(offset)
        XCTAssertEqual(refused.issue?.code, .unsupportedSelector)
        let unknown = await AutomationEngine(environment: fake).run(.init(.setBrightness(.init(normalized: 0.5)!, method: .automatic), target: .group("Unknown")))
        XCTAssertEqual(unknown.issue?.code, .unknownGroup)
        let writes = await fake.writes
        XCTAssertEqual(writes, 1)
    }
    func testHTTPConfigurationIsOffLoopbackAndHasNoDefaultPortOrSecret() throws {
        let config = IntegrationHTTPConfiguration()
        XCTAssertFalse(config.enabled); XCTAssertFalse(config.remoteAccess)
        XCTAssertNil(config.port); XCTAssertEqual(config.host, "127.0.0.1")
        let saved = IntegrationHTTPConfiguration(enabled: true, port: 12345, remoteAccess: true)
        XCTAssertEqual(try JSONDecoder().decode(IntegrationHTTPConfiguration.self, from: JSONEncoder().encode(saved)), saved)
        XCTAssertEqual(saved.host, "0.0.0.0")
        XCTAssertNil(try IntegrationHTTPConfiguration.parsePort(""))
        XCTAssertEqual(try IntegrationHTTPConfiguration.parsePort("65535"), 65535)
        for port in ["0", "65536", "-1", "1.5", "abc"] { XCTAssertThrowsError(try IntegrationHTTPConfiguration.parsePort(port)) }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["enabled", "port", "remoteAccess"])
    }
}
