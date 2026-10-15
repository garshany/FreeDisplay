import DisplayDomain
import Foundation
import XCTest
@testable import AutomationSchema

private actor StandaloneFake: AutomationEnvironment {
    nonisolated let surface: AutomationSurface = .cli
    var recoveries = 0
    var writes = 0
    let screen = AutomationDisplayCandidate(id: .init(rawValue: "screen"), name: "Screen", availability: .active)
    nonisolated func unavailability(of command: AutomationCommandName) -> AutomationIssue? {
        CLIExecutionPolicy.standaloneUnavailability(of: command)
    }
    func displaySet() async -> AutomationDisplaySet { .init(candidates: [screen]) }
    func reconnectAll() async throws(AutomationIssue) -> ResultEnvelope {
        recoveries += 1
        return .init(transactionId: "ledger", status: .committed, actor: .cli, requestedAt: Date(),
                     topologyGeneration: 0, targets: [])
    }
    func brightnessRoutes(for display: AutomationDisplayCandidate) async -> BrightnessRouteAvailability {
        .init(current: .ddc, states: [.ddc: .available, .software: .unavailable(.notInThisProcess)])
    }
    func readBrightness(of display: AutomationDisplayCandidate, via route: BrightnessRoute) async throws(AutomationIssue) -> BrightnessReadback {
        .ddc(current: 40, max: 100)
    }
    func writeBrightness(_ level: AutomationLevel, to display: AutomationDisplayCandidate,
                         via route: BrightnessRoute) async throws(AutomationIssue) -> BrightnessWriteReport {
        writes += 1
        return .init(requested: level, accepted: true, readback: .ddc(current: level.raw(maximum: 100), max: 100))
    }
}

final class CLIExecutionPolicyTests: XCTestCase, @unchecked Sendable {
    private enum Fault: Error { case transport, timedOut, invalidReply, denied, cancelled }

    private func recover(appRunning: Bool, endpoint: () async throws -> String?, fake: StandaloneFake) async throws -> String {
        if let app = try await CLIExecutionPolicy.appResponse(exchangeIfAvailable: endpoint,
                                                             appIsRunning: { appRunning }) { return app }
        let result = await AutomationEngine(environment: fake).run(.init(.reconnectAll))
        XCTAssertTrue(result.succeeded)
        return "standalone"
    }

    func testRunningAppUsesIPCWithoutStandaloneRecovery() async throws {
        let fake = StandaloneFake()
        let path = try await recover(appRunning: true, endpoint: { "app" }, fake: fake)
        XCTAssertEqual(path, "app")
        let recoveries = await fake.recoveries
        XCTAssertEqual(recoveries, 0)
    }

    func testAbsentAppAndUnavailableEndpointUseStandaloneLedgerEngine() async throws {
        let fake = StandaloneFake()
        let path = try await recover(appRunning: false, endpoint: { nil }, fake: fake)
        XCTAssertEqual(path, "standalone")
        let recoveries = await fake.recoveries
        XCTAssertEqual(recoveries, 1)
    }

    func testReachableEndpointWinsEvenIfAppSnapshotSaysAbsent() async throws {
        let fake = StandaloneFake()
        let path = try await recover(appRunning: false, endpoint: { "app" }, fake: fake)
        XCTAssertEqual(path, "app")
        let recoveries = await fake.recoveries
        XCTAssertEqual(recoveries, 0)
    }

    func testUnreachableEndpointWhileAppRunsFailsClosed() async {
        let fake = StandaloneFake()
        do {
            _ = try await recover(appRunning: true, endpoint: { nil }, fake: fake)
            XCTFail("a running app owns the ledger even if IPC is not listening")
        } catch let issue as AutomationIssue { XCTAssertEqual(issue.code, .notReady) }
        catch { XCTFail("unexpected error: \(error)") }
        let recoveries = await fake.recoveries
        XCTAssertEqual(recoveries, 0)
    }

    func testFailureAfterSendNeverFallsBackEvenIfAppHasQuit() async {
        let fake = StandaloneFake(), app = StandaloneFake()
        do {
            _ = try await recover(appRunning: false, endpoint: {
                _ = await AutomationEngine(environment: app).run(.init(.reconnectAll))
                throw Fault.transport
            }, fake: fake)
            XCTFail("a lost response may mean recovery was already accepted")
        } catch { }
        let accepted = await app.recoveries
        let recoveries = await fake.recoveries
        XCTAssertEqual(accepted, 1)
        XCTAssertEqual(recoveries, 0)
    }

    func testTimeoutInvalidReplyPermissionsAndCancellationNeverFallBack() async {
        let fake = StandaloneFake()
        for fault in [Fault.timedOut, .invalidReply, .denied, .cancelled] {
            do {
                _ = try await recover(appRunning: false, endpoint: { throw fault }, fake: fake)
                XCTFail("only a pre-send unavailable endpoint permits standalone")
            } catch { }
        }
        let recoveries = await fake.recoveries
        XCTAssertEqual(recoveries, 0)
    }

    func testStandaloneHardwareBrightnessStillRunsThroughSharedEngine() async throws {
        let fake = StandaloneFake()
        let request = try CLIAppRequest.request(.init(command: "brightness", positional: ["id:screen", "60%"],
                                                    values: ["--method": "hardware"]))
        let result = await AutomationEngine(environment: fake).run(try XCTUnwrap(request))
        XCTAssertEqual(result.brightness?.outcome, .verified)
        let writes = await fake.writes
        XCTAssertEqual(writes, 1)
    }

    func testStandaloneAppOwnedOperationsAndSoftwareRouteStillRefuse() async throws {
        let fake = StandaloneFake()
        for name in [AutomationCommandName.adjustBrightness, .setMode, .setMain, .listColorProfiles,
                     .getColorProfile, .setColorProfile, .resetColorProfile] {
            XCTAssertNotNil(CLIExecutionPolicy.standaloneUnavailability(of: name))
        }
        for name in [AutomationCommandName.listDisplays, .reconnectAll, .disconnect, .getCapabilities,
                     .getBrightness, .setBrightness, .getContrast, .setContrast, .listModes, .getMode] {
            XCTAssertNil(CLIExecutionPolicy.standaloneUnavailability(of: name))
        }
        for arguments in [CLIInvocation(command: "brightness", positional: ["id:screen"], values: ["--offset": "+5%"]),
                          .init(command: "mode", positional: ["id:screen", "1920x1080@60"]),
                          .init(command: "main", positional: ["id:screen"]),
                          .init(command: "profiles"),
                          .init(command: "profile", positional: ["id:screen"]),
                          .init(command: "brightness", positional: ["id:screen", "60%"], values: ["--method": "software"])] {
            let request = try XCTUnwrap(CLIAppRequest.request(arguments))
            let result = await AutomationEngine(environment: fake).run(request)
            XCTAssertNotNil(result.issue, "\(arguments)")
        }
        let writes = await fake.writes
        XCTAssertEqual(writes, 0)
    }

    func testLegacyReadAndMutationTable() {
        let reads = [CLIInvocation(command: "diagnose"), .init(command: "diagnose", flags: ["--bundle"]),
                     .init(command: "lux"), .init(command: "lid"), .init(command: "listen"),
                     .init(command: "edid", positional: ["id:screen"]),
                     .init(command: "scene"), .init(command: "scene", positional: ["list"]),
                     .init(command: "scene", positional: ["show", "Desk"]),
                     .init(command: "scene", positional: ["plan", "Desk"]),
                     .init(command: "group"), .init(command: "group", positional: ["list"]),
                     .init(command: "layout"), .init(command: "layout", positional: ["status"]),
                     .init(command: "favorite", positional: ["list", "id:screen"]),
                     .init(command: "favourite", positional: ["LIST", "id:screen"]),
                     .init(command: "ddc", positional: ["id:screen", "brightness"]),
                     .init(command: "ddc", positional: ["id:screen", "contrast"]),
                     .init(command: "ddc", positional: ["id:screen", "caps"]),
                     .init(command: "ddc", positional: ["id:screen", "vcp", "0x10"])]
        let mutations = [CLIInvocation(command: "alias"), .init(command: "tag"), .init(command: "reconnect"),
                         .init(command: "scene", positional: ["save", "Desk"]),
                         .init(command: "scene", positional: ["apply", "Desk"]),
                         .init(command: "scene", positional: ["delete", "Desk"]),
                         .init(command: "group", positional: ["create", "Desk"]),
                         .init(command: "group", positional: ["delete", "Desk"]),
                         .init(command: "group", positional: ["add", "Desk", "id:screen"]),
                         .init(command: "group", positional: ["remove", "Desk", "id:screen"]),
                         .init(command: "layout", positional: ["protect"]),
                         .init(command: "layout", positional: ["unprotect"]),
                         .init(command: "favorite", positional: ["set", "id:screen", "1920x1080"]),
                         .init(command: "favorite", positional: ["unset", "id:screen", "1920x1080"]),
                         .init(command: "ddc", positional: ["id:screen", "brightness", "50"]),
                         .init(command: "ddc", positional: ["id:screen", "vcp", "0x10", "50"]),
                         .init(command: "ddc", positional: ["id:screen", "reset"]),
                         .init(command: "ddc", positional: ["id:screen", "power", "off"]),
                         .init(command: "_rotate-exp"), .init(command: "unknown")]
        for invocation in reads { XCTAssertTrue(CLIExecutionPolicy.legacyMayRunWithApp(invocation), "\(invocation)") }
        for invocation in mutations { XCTAssertFalse(CLIExecutionPolicy.legacyMayRunWithApp(invocation), "\(invocation)") }
    }

    func testProvenanceIsAdditiveAndOldResultsStillDecode() async throws {
        let result = await AutomationEngine(environment: StandaloneFake(), now: { Date(timeIntervalSince1970: 1_000) }).run(.init(.listDisplays))
        let encoder = ResultEnvelope.makeEncoder()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for path in [CLIExecutionPath.app, .standalone] {
            let data = try path.annotating(encoder.encode(result))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["servedBy"] as? String, path.rawValue)
            XCTAssertEqual(try decoder.decode(AutomationResult.self, from: data), result)
            let envelope = try path.annotating(encoder.encode(result.envelope))
            XCTAssertEqual(try decoder.decode(ResultEnvelope.self, from: envelope), result.envelope)
        }
    }
}
