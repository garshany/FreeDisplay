import DisplayDomain
import XCTest
@testable import AutomationSchema

/// An in-memory surface: a few displays with brightness routes, modes and profiles, recording every
/// primitive call so tests can assert that refusals changed nothing.
private actor FakeEnvironment: AutomationEnvironment {
    nonisolated let surface: AutomationSurface
    nonisolated let unavailable: [AutomationCommandName: AutomationIssue]
    var candidates: [AutomationDisplayCandidate]
    var routes: [DisplayRecordID: BrightnessRouteAvailability] = [:]
    var levels: [DisplayRecordID: Double] = [:]
    /// What the route reads back after a write; nil echoes the written level.
    var readbackOverride: BrightnessReadback?
    var writeAccepted = true
    var modeState = AutomationModeState(current: nil, offered: [])
    var modeSettlement: AutomationModeSettlement = .awaitingConfirmation(secondsToKeep: 15)
    var mainAfter: DisplayRecordID?
    var mainAwaitsKeep = false
    var profiles: [AutomationProfileInfo] = []
    var profileState = AutomationColorProfileState(name: "Factory", customProfilePath: nil, isFactory: true, controllable: true)
    var profileLands = true
    var ready = true
    private(set) var calls: [String] = []

    init(surface: AutomationSurface = .http, candidates: [AutomationDisplayCandidate],
         unavailable: [AutomationCommandName: AutomationIssue] = [:]) {
        self.surface = surface
        self.candidates = candidates
        self.unavailable = unavailable
    }

    func configure(_ change: @Sendable (isolated FakeEnvironment) -> Void) {
        change(self)
    }

    nonisolated func unavailability(of command: AutomationCommandName) -> AutomationIssue? { unavailable[command] }

    func prepare() async throws(AutomationIssue) {
        guard ready else { throw AutomationIssue(.notReady, "not ready") }
    }

    func displaySet() async -> AutomationDisplaySet {
        AutomationDisplaySet(candidates: candidates, knownGroups: ["Work"], topologyGeneration: 42)
    }

    func brightnessRoutes(for display: AutomationDisplayCandidate) async -> BrightnessRouteAvailability {
        routes[display.id] ?? BrightnessRouteAvailability(current: .ddc, states: [.ddc: .available])
    }

    func readBrightness(of display: AutomationDisplayCandidate, via route: BrightnessRoute) async throws(AutomationIssue) -> BrightnessReadback {
        calls.append("read \(display.id.rawValue) \(route.rawValue)")
        guard let level = levels[display.id] else { return .none }
        return route == .software ? .applied(level) : .level(level)
    }

    func writeBrightness(_ level: AutomationLevel, to display: AutomationDisplayCandidate,
                         via route: BrightnessRoute) async throws(AutomationIssue) -> BrightnessWriteReport {
        calls.append("write \(display.id.rawValue) \(route.rawValue) \(level.wholePercent)")
        return finishWrite(level, display: display, route: route)
    }

    func adjustBrightness(by delta: AutomationLevelDelta, of display: AutomationDisplayCandidate,
                          via route: BrightnessRoute) async throws(AutomationIssue) -> BrightnessWriteReport {
        // Read-modify-write with no suspension in between: what the real primitives guarantee.
        let target = AutomationLevel(clamping: levels[display.id] ?? 0).offset(by: delta)
        calls.append("adjust \(display.id.rawValue) \(route.rawValue) \(target.wholePercent)")
        return finishWrite(target, display: display, route: route)
    }

    private func finishWrite(_ level: AutomationLevel, display: AutomationDisplayCandidate,
                             route: BrightnessRoute) -> BrightnessWriteReport {
        guard writeAccepted else {
            return BrightnessWriteReport(requested: level, accepted: false, readback: .none, failure: "DDC write failed")
        }
        levels[display.id] = level.normalized
        let readback = readbackOverride ?? (route == .software ? .applied(level.normalized) : .level(level.normalized))
        return BrightnessWriteReport(requested: level, accepted: true, readback: readback)
    }

    func modes(of display: AutomationDisplayCandidate) async throws(AutomationIssue) -> AutomationModeState { modeState }

    func applyMode(_ mode: DisplayMode, to display: AutomationDisplayCandidate,
                   keepWithoutConfirmation: Bool) async throws(AutomationIssue) -> AutomationModeSettlement {
        calls.append("mode \(display.id.rawValue) \(FavoriteResolutions.key(for: mode))\(keepWithoutConfirmation ? " keep" : "")")
        return keepWithoutConfirmation ? .applied : modeSettlement
    }

    func makeMain(_ display: AutomationDisplayCandidate) async throws(AutomationIssue) -> AutomationMainSettlement {
        calls.append("main \(display.id.rawValue)")
        return AutomationMainSettlement(observedMain: mainAfter, awaitingConfirmation: mainAwaitsKeep,
                                        secondsToKeep: mainAwaitsKeep ? 10 : nil)
    }

    func installedColorProfiles() async throws(AutomationIssue) -> [AutomationProfileInfo] { profiles }

    func colorProfile(of display: AutomationDisplayCandidate) async throws(AutomationIssue) -> AutomationColorProfileState {
        profileState
    }

    func applyColorProfile(_ profile: AutomationProfileInfo?, to display: AutomationDisplayCandidate) async throws(AutomationIssue) -> AutomationColorProfileState {
        calls.append("profile \(display.id.rawValue) \(profile?.name ?? "factory")")
        guard profileLands else { return profileState }
        profileState = AutomationColorProfileState(name: profile?.name ?? "Factory", customProfilePath: profile?.id,
                                                   isFactory: profile == nil, controllable: true)
        return profileState
    }

    func reconnectAll() async throws(AutomationIssue) -> ResultEnvelope {
        calls.append("reconnectAll")
        return ResultEnvelope.reconnectAll(results: [("cg:off", true)], actor: surface.actor,
                                           requestedAt: Date(timeIntervalSince1970: 0), topologyGeneration: 42)
    }
}

final class AutomationEngineTests: XCTestCase {
    private static func candidate(_ id: String, name: String, availability: AutomationDisplayCandidate.Availability = .active,
                                  main: Bool = false, tags: Set<String> = []) -> AutomationDisplayCandidate {
        AutomationDisplayCandidate(id: DisplayRecordID(rawValue: id), name: name, tags: tags, availability: availability,
                                   isMain: main)
    }

    private let displays = [
        candidate("cg:desk", name: "Desk", main: true, tags: ["pair"]),
        candidate("cg:side", name: "Side", tags: ["pair"]),
        candidate("cg:mirror", name: "Mirror", availability: .inactive),
        candidate("cg:off", name: "Off", availability: .disconnected),
    ]

    private func engine(_ environment: FakeEnvironment) -> AutomationEngine<FakeEnvironment> {
        AutomationEngine(environment: environment, now: { Date(timeIntervalSince1970: 1000) })
    }

    private func request(_ verb: String, _ parameters: [String: AutomationParameterValue]) throws -> AutomationRequest {
        try AutomationRequestParser.parse(verb: verb, parameters: parameters)
    }

    private let half = AutomationLevel(normalized: 0.5)!

    func testConsoleLexedRequestUsesSharedSettlementWithoutExternalTransport() async throws {
        let environment = FakeEnvironment(surface: .console, candidates: displays)
        await environment.configure { $0.levels[DisplayRecordID(rawValue: "cg:desk")] = 0.5 }
        guard case .command(let request) = try ConsoleGrammar.parse("brightness display='name:Desk' value=40% method=ddc") else { return XCTFail() }
        let result = await engine(environment).run(request)
        XCTAssertNil(result.issue)
        XCTAssertEqual(result.brightness?.level?.normalized, 0.4)
        XCTAssertEqual(result.brightness?.outcome, .verified)
    }

    func testConsoleCannotBypassBuildRefusalOrConfirmation() async throws {
        let refusal = AutomationIssue(.capabilityUnavailable, "not in public build")
        let environment = FakeEnvironment(surface: .console, candidates: displays, unavailable: [.setBrightness: refusal])
        guard case .command(let request) = try ConsoleGrammar.parse("brightness display='name:Desk' value=40%") else { return XCTFail() }
        let result = await engine(environment).run(request)
        XCTAssertEqual(result.issue, refusal)
        let disconnect = await engine(environment).run(.byID(.disconnect, DisplayRecordID(rawValue: "cg:desk")))
        XCTAssertEqual(disconnect.issue?.code, .refusedFromSurface)
        let calls = await environment.calls
        XCTAssertTrue(calls.isEmpty)
    }

    // MARK: Admission

    func testALinkMayOnlyRunRecovery() async throws {
        let environment = FakeEnvironment(surface: .url, candidates: displays)
        let brightness = await engine(environment).run(try request("brightness", ["display": .string("Desk"), "value": .number(0.5)]))
        XCTAssertEqual(brightness.issue?.code, .refusedFromSurface)
        let disconnect = await engine(environment).run(.byID(.disconnect, DisplayRecordID(rawValue: "cg:desk")))
        XCTAssertEqual(disconnect.issue?.code, .confirmationRequired)
        let calls = await environment.calls
        XCTAssertEqual(calls, [], "nothing ran for a refused link")
        let recovery = await engine(environment).run(AutomationRequest(.reconnectAll))
        XCTAssertNil(recovery.issue)
        XCTAssertEqual(recovery.status, .committed)
    }

    func testASurfaceThatCantRunACommandSaysSo() async {
        let issue = AutomationIssue(.capabilityUnavailable, "needs the app's keep-or-revert window")
        let environment = FakeEnvironment(surface: .cli, candidates: displays, unavailable: [.listModes: issue])
        let result = await engine(environment).run(.byID(.listModes, DisplayRecordID(rawValue: "cg:desk")))
        XCTAssertEqual(result.issue, issue)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.envelope.errors.map(\.code), ["capabilityUnavailable"])
    }

    func testDefaultPrimitivesRefuseInsteadOfPretending() async {
        struct Bare: AutomationEnvironment {
            let surface = AutomationSurface.console
            func displaySet() async -> AutomationDisplaySet {
                AutomationDisplaySet(candidates: [AutomationDisplayCandidate(id: DisplayRecordID(rawValue: "x"), name: "X",
                                                                             availability: .active)])
            }
        }
        let result = await AutomationEngine(environment: Bare()).run(.byID(.getMode, DisplayRecordID(rawValue: "x")))
        XCTAssertEqual(result.issue?.code, .capabilityUnavailable)
    }

    func testNotReadyIsReported() async {
        let environment = FakeEnvironment(candidates: displays)
        await environment.configure { $0.ready = false }
        let result = await engine(environment).run(AutomationRequest(.listDisplays))
        XCTAssertEqual(result.issue?.code, .notReady)
        XCTAssertEqual(AutomationHTTPStatus.code(for: result), 503)
    }

    // MARK: Targets

    func testTargetsMustBeExactlyOneUsableDisplay() async throws {
        let environment = FakeEnvironment(candidates: displays)
        let cases: [(String, AutomationIssue.Code)] = [
            ("alias:Nowhere", .displayNotFound), ("tag:pair", .ambiguousSelector),
            ("Mirror", .displayInactive), ("Off", .displayNotConnected), ("focus", .unsupportedSelector),
        ]
        for (selector, code) in cases {
            let result = await engine(environment).run(try request("setBrightness", ["display": .string(selector), "value": .number(0.5)]))
            XCTAssertEqual(result.issue?.code, code, selector)
            XCTAssertEqual(result.status, .failed, selector)
        }
        let calls = await environment.calls
        XCTAssertEqual(calls, [], "no refusal wrote anything")
    }

    // MARK: Brightness

    func testSetBrightnessVerifiedThroughTheChosenRoute() async throws {
        let environment = FakeEnvironment(candidates: displays)
        let result = await engine(environment).run(try request("brightness", ["display": .string("Desk"), "value": .string("50%")]))
        XCTAssertNil(result.issue)
        XCTAssertEqual(result.status, .committed)
        XCTAssertEqual(result.envelope.transactionId, "txn_brightness")
        XCTAssertEqual(result.envelope.actor, .httpAPI)
        XCTAssertEqual(result.envelope.topologyGeneration, 42)
        let operation = try XCTUnwrap(result.envelope.targets.first?.operations.first)
        XCTAssertEqual(operation.outcome, .verified)
        XCTAssertEqual(operation.provider, "ddc")
        XCTAssertEqual(operation.requested, .double(0.5))
        XCTAssertEqual(result.brightness?.route, .ddc)
        XCTAssertEqual(result.brightness?.reportedByDisplay, true)
        XCTAssertEqual(AutomationOutcomeKind(result), .done)
        let calls = await environment.calls
        XCTAssertEqual(calls, ["write cg:desk ddc 50"])
    }

    /// TB-36: hardware-only on a software-only display is refused, and nothing dims.
    func testHardwareOnlyRefusalWritesNothing() async throws {
        let environment = FakeEnvironment(candidates: displays)
        await environment.configure { $0.routes = [DisplayRecordID(rawValue: "cg:desk"): BrightnessRouteAvailability(
            current: .software, states: [.software: .available, .ddc: .unavailable(.refused)])] }
        let result = await engine(environment).run(try request("brightness", ["display": .string("Desk"), "value": .number(0.3),
                                                                              "method": .string("hardware")]))
        XCTAssertEqual(result.issue?.code, .methodUnavailable)
        XCTAssertEqual(AutomationHTTPStatus.code(for: result), 422)
        XCTAssertEqual(CLIExitCode(result), .failure)
        let calls = await environment.calls
        XCTAssertEqual(calls, [])
    }

    func testUnconfirmedAndFailedWritesAreReportedHonestly() async throws {
        let environment = FakeEnvironment(candidates: displays)
        await environment.configure { $0.readbackOverride = BrightnessReadback.none }
        let sent = await engine(environment).run(.byID(.setBrightness(half, method: .automatic), DisplayRecordID(rawValue: "cg:desk")))
        XCTAssertEqual(sent.status, .committed, "accepted but unconfirmed still counts as done")
        XCTAssertEqual(sent.envelope.targets.first?.operations.first?.outcome, .sent)
        XCTAssertEqual(sent.envelope.targets.first?.operations.first?.verification, .readBackUnavailable)
        XCTAssertEqual(AutomationOutcomeKind(sent), .requested)

        await environment.configure { $0.writeAccepted = false }
        let failed = await engine(environment).run(.byID(.setBrightness(half, method: .automatic), DisplayRecordID(rawValue: "cg:desk")))
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.issue?.code, .executionFailed)
        XCTAssertEqual(failed.envelope.errors.map(\.code), ["executionFailed"])
        XCTAssertEqual(AutomationHTTPStatus.code(for: failed), 502)
        XCTAssertEqual(CLIExitCode(failed), .failure)
    }

    func testSoftwareDimmingIsReportedButNotConfirmedByTheDisplay() async throws {
        let environment = FakeEnvironment(candidates: displays)
        await environment.configure { $0.routes = [DisplayRecordID(rawValue: "cg:desk"): BrightnessRouteAvailability(
            current: .software, states: [.software: .available])] }
        let result = await engine(environment).run(.byID(.setBrightness(half, method: .automatic), DisplayRecordID(rawValue: "cg:desk")))
        XCTAssertEqual(result.brightness?.route, .software)
        XCTAssertEqual(result.brightness?.reportedByDisplay, false)
        XCTAssertEqual(result.brightness?.outcome, .sent)
        XCTAssertEqual(result.envelope.targets.first?.operations.first?.provider, "software")
    }

    /// FA-44/T34: two rapid +5-point requests accumulate; the end of the span clamps.
    func testRelativeChangesAccumulateAndClamp() async throws {
        let environment = FakeEnvironment(candidates: displays)
        await environment.configure { $0.levels = [DisplayRecordID(rawValue: "cg:desk"): 0.5] }
        let plusFive = try request("brightness", ["display": .string("Desk"), "offset": .string("+5%")])
        let engine = engine(environment)
        async let first = engine.run(plusFive)
        async let second = engine.run(plusFive)
        let results = await [first, second]
        XCTAssertEqual(results.map(\.status), [.committed, .committed])
        let level = await environment.levels[DisplayRecordID(rawValue: "cg:desk")]
        XCTAssertEqual(level ?? 0, 0.6, accuracy: 1e-9)
        await environment.configure { $0.levels = [DisplayRecordID(rawValue: "cg:desk"): 0.98] }
        let clamped = await engine.run(plusFive)
        XCTAssertEqual(clamped.brightness?.requested?.normalized, 1)
    }

    func testReadingBrightness() async throws {
        let environment = FakeEnvironment(candidates: displays)
        await environment.configure { $0.levels = [DisplayRecordID(rawValue: "cg:desk"): 0.25] }
        let result = await engine(environment).run(try request("brightness", ["display": .string("main")]))
        XCTAssertEqual(result.status, .noOp)
        XCTAssertEqual(result.brightness?.level?.wholePercent, 25)
        XCTAssertNil(result.brightness?.outcome)
        XCTAssertEqual(AutomationOutcomeKind(result), .done)
        await environment.configure { $0.levels = [:] }
        let unreadable = await engine(environment).run(try request("brightness", ["display": .string("main")]))
        XCTAssertEqual(unreadable.issue?.code, .executionFailed)
    }

    func testDryRunResolvesAndChoosesButWritesNothing() async throws {
        let environment = FakeEnvironment(candidates: displays)
        let result = await engine(environment).run(try request("brightness", ["display": .string("Desk"), "value": .number(0.5),
                                                                              "dryRun": .bool(true)]))
        XCTAssertTrue(result.dryRun)
        XCTAssertEqual(result.status, .noOp)
        XCTAssertEqual(result.plan, "set the brightness of Desk to 50% via ddc")
        XCTAssertEqual(result.envelope.targets.first?.operations.first?.outcome, .skipped)
        let calls = await environment.calls
        XCTAssertEqual(calls, [])
    }

    // MARK: Modes

    private static func mode(_ w: Int, _ h: Int, hz: Double = 60, hiDPI: Bool = true) -> DisplayMode {
        DisplayMode(pixelWidth: hiDPI ? w * 2 : w, pixelHeight: hiDPI ? h * 2 : h, pointWidth: w, pointHeight: h,
                    refreshHz: hz, isHiDPI: hiDPI)
    }

    func testSetModeSettlesAndReportsTheKeepWindow() async throws {
        let environment = FakeEnvironment(candidates: displays)
        await environment.configure { $0.modeState = AutomationModeState(current: Self.mode(1920, 1080), offered: [Self.mode(1920, 1080), Self.mode(1600, 900)]) }
        let result = await engine(environment).run(try request("mode", ["display": .string("Desk"), "mode": .string("1600x900")]))
        XCTAssertEqual(result.status, .committed)
        XCTAssertEqual(result.mode?.settlement, .awaitingConfirmation)
        XCTAssertEqual(result.mode?.secondsToKeep, 15)
        XCTAssertTrue(result.envelope.targets.first?.operations.first?.warnings.first?.hasPrefix("keepPending") ?? false)

        let again = await engine(environment).run(try request("mode", ["display": .string("Desk"), "mode": .string("1920x1080")]))
        XCTAssertEqual(again.status, .noOp)
        XCTAssertEqual(again.mode?.settlement, .alreadyInEffect)
        XCTAssertEqual(AutomationOutcomeKind(again), .alreadyInEffect)
        let calls = await environment.calls
        XCTAssertEqual(calls.count, 1, "an already-current mode is not re-applied")
    }

    /// Owner decision #20: the Intent can keep a verified mode without the countdown; no parsed
    /// request can.
    func testKeepingAModeWithoutConfirmationIsOnlyAnExplicitCommandFlag() async throws {
        let environment = FakeEnvironment(surface: .appIntent, candidates: displays)
        await environment.configure { $0.modeState = AutomationModeState(current: Self.mode(1920, 1080), offered: [Self.mode(1920, 1080), Self.mode(1600, 900)]) }
        let kept = await engine(environment).run(.byID(.setMode(.logical(width: 1600, height: 900, refreshHz: nil, hiDPI: nil),
                                                                keepWithoutConfirmation: true),
                                                      DisplayRecordID(rawValue: "cg:desk")))
        XCTAssertEqual(kept.mode?.settlement, .applied)
        XCTAssertNil(kept.mode?.secondsToKeep)
        XCTAssertEqual(try request("mode", ["display": .string("Desk"), "mode": .string("1600x900")]).command,
                       .setMode(.logical(width: 1600, height: 900, refreshHz: nil, hiDPI: nil), keepWithoutConfirmation: false))
        XCTAssertThrowsError(try request("mode", ["display": .string("Desk"), "mode": .string("1600x900"),
                                                  "keepWithoutConfirmation": .bool(true)]))
    }

    func testDecodedConfirmationBypassIsRefusedOutsideIntentBeforeExecution() async throws {
        let environment = FakeEnvironment(surface: .http, candidates: displays)
        let request = AutomationRequest.byID(.setMode(.logical(width: 1600, height: 900, refreshHz: nil, hiDPI: nil),
                                                       keepWithoutConfirmation: true), .init(rawValue: "cg:desk"))
        let decoded = try JSONDecoder().decode(AutomationRequest.self, from: JSONEncoder().encode(request))
        let result = await engine(environment).run(decoded)
        XCTAssertEqual(result.issue?.code, .refusedFromSurface)
        let calls = await environment.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testEquivalentHardwareRequestsUseIdenticalSettlementAcrossExecutableSurfaces() async throws {
        let request = try request("brightness", ["display": .string("id:cg:desk"), "value": .string("40%"),
                                                  "method": .string("hardware")])
        for surface in [AutomationSurface.cli, .http, .appIntent, .console] {
            let environment = FakeEnvironment(surface: surface, candidates: displays)
            await environment.configure { $0.readbackOverride = .ddc(current: 41, max: 100) }
            let result = await engine(environment).run(request)
            XCTAssertEqual(result.brightness?.outcome, .verified, surface.rawValue)
            XCTAssertEqual(result.brightness?.level?.wholePercent, 41)
            XCTAssertEqual(result.brightness?.route, .ddc)
        }
    }

    func testCapabilitiesDistinguishAdmissionBuildRefusalAndOfflineState() async {
        let environment = FakeEnvironment(surface: .cli, candidates: displays,
                                            unavailable: [.adjustBrightness: .init(.capabilityUnavailable, "IPC required")])
        let active = await engine(environment).run(.byID(.getCapabilities, .init(rawValue: "cg:desk")))
        XCTAssertTrue(active.capabilities?.brightnessRoutes.isAvailable(.ddc) ?? false)
        XCTAssertNil(active.capabilities?.commands.first { $0.command == .setMode }?.issue)
        XCTAssertEqual(active.capabilities?.commands.first { $0.command == .adjustBrightness }?.issue?.code, .capabilityUnavailable)
        await environment.configure { $0.candidates = $0.candidates.map { candidate in
            var copy = candidate
            copy.availability = .disconnected
            return copy
        } }
        let offline = await engine(environment).run(.byID(.getCapabilities, .init(rawValue: "cg:desk")))
        XCTAssertEqual(offline.capabilities?.commands.first { $0.command == .setBrightness }?.issue?.code, .displayNotConnected)
        XCTAssertFalse(offline.capabilities?.brightnessRoutes.isAvailable(.ddc) ?? true)
    }

    func testModeDiscoveryListsCurrentFirst() async throws {
        let environment = FakeEnvironment(candidates: displays)
        await environment.configure { $0.modeState = AutomationModeState(current: Self.mode(1920, 1080), offered: [Self.mode(1600, 900), Self.mode(1920, 1080)]) }
        let result = await engine(environment).run(.byID(.listModes, DisplayRecordID(rawValue: "cg:desk")))
        XCTAssertEqual(result.modes?.available.map(\.isCurrent), [true, false])
        XCTAssertEqual(result.modes?.available.first?.mode, Self.mode(1920, 1080))
        await environment.configure { $0.modeState = AutomationModeState(current: nil, offered: []) }
        let unreadable = await engine(environment).run(.byID(.getMode, DisplayRecordID(rawValue: "cg:desk")))
        XCTAssertEqual(unreadable.issue?.code, .executionFailed)
    }

    // MARK: Main display

    func testSetMainJudgesByTheObservedMainDisplay() async throws {
        let environment = FakeEnvironment(candidates: displays)
        let already = await engine(environment).run(.byID(.setMain, DisplayRecordID(rawValue: "cg:desk")))
        XCTAssertEqual(already.status, .noOp)
        XCTAssertEqual(already.main?.changed, false)

        let notConfirmed = await engine(environment).run(.byID(.setMain, DisplayRecordID(rawValue: "cg:side")))
        XCTAssertEqual(notConfirmed.issue?.code, .notConfirmed)

        await environment.configure { $0.mainAfter = DisplayRecordID(rawValue: "cg:side") }
        let changed = await engine(environment).run(.byID(.setMain, DisplayRecordID(rawValue: "cg:side")))
        XCTAssertEqual(changed.status, .committed)
        XCTAssertEqual(changed.main?.changed, true)
        XCTAssertEqual(changed.main?.awaitingConfirmation, false)

        // When main changes go through a keep-or-revert window, the result says so.
        await environment.configure { $0.mainAwaitsKeep = true }
        let pending = await engine(environment).run(.byID(.setMain, DisplayRecordID(rawValue: "cg:side")))
        XCTAssertEqual(pending.main?.awaitingConfirmation, true)
        XCTAssertEqual(pending.main?.secondsToKeep, 10)
        XCTAssertTrue(pending.envelope.targets.first?.operations.first?.warnings.first?.hasPrefix("keepPending") ?? false)
    }

    // MARK: Colour profiles

    func testColorProfileChangesAreReadBack() async throws {
        let environment = FakeEnvironment(candidates: displays)
        let p3 = AutomationProfileInfo(id: "/Library/ColorSync/Profiles/P3.icc", name: "Display P3")
        await environment.configure { $0.profiles = [p3] }
        let set = await engine(environment).run(try request("profile", ["display": .string("Desk"), "profile": .string("display p3")]))
        XCTAssertEqual(set.status, .committed)
        XCTAssertEqual(set.colorProfile?.state.customProfilePath, p3.id)
        let again = await engine(environment).run(try request("profile", ["display": .string("Desk"), "profile": .string(p3.id)]))
        XCTAssertEqual(again.status, .noOp)

        await environment.configure { $0.profileLands = false }
        let reset = await engine(environment).run(.byID(.resetColorProfile, DisplayRecordID(rawValue: "cg:desk")))
        XCTAssertEqual(reset.issue?.code, .notConfirmed)

        await environment.configure { $0.profileState = AutomationColorProfileState(name: nil, customProfilePath: nil, isFactory: true,
                                                                           controllable: false) }
        let uncontrollable = await engine(environment).run(.byID(.setColorProfile(.name("Display P3")), DisplayRecordID(rawValue: "cg:desk")))
        XCTAssertEqual(uncontrollable.issue?.code, .capabilityUnavailable)
    }

    // MARK: Lists

    func testListDisplaysCarriesNoIdentityEvidence() async throws {
        let environment = FakeEnvironment(candidates: displays)
        let result = await engine(environment).run(AutomationRequest(.listDisplays))
        XCTAssertEqual(result.displays?.map(\.id), ["cg:desk", "cg:side", "cg:mirror", "cg:off"])
        let json = String(decoding: result.jsonData(), as: UTF8.self)
        XCTAssertFalse(json.contains("serial"))
        XCTAssertFalse(json.contains("vendor"))
    }
}
