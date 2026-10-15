import AutomationSchema
import DisplayDomain
import Foundation
import XCTest
@testable import TopologyCore

@MainActor
final class ClockModeTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    private func level(_ value: Double) -> AutomationLevel { AutomationLevel(normalized: value)! }
    private func recipe(id: String = "desk", method: BrightnessMethodRequest = .software,
                        entries: [ClockScheduleEntry]? = nil, ramp: Int = 30) -> ClockDisplaySchedule {
        ClockDisplaySchedule(displayID: .init(rawValue: id), entries: entries ?? [
            .init(anchor: .time, timeMinute: 8 * 60, brightness: 0.8, transition: .instant),
            .init(anchor: .time, timeMinute: 20 * 60, brightness: 0.3, transition: .instant)
        ], method: method, restoreLevel: level(0.6), rampMinutes: ramp)
    }
    private func sample(_ iso: String, _ schedule: ClockDisplaySchedule? = nil,
                        zone: TimeZone? = nil) throws -> ClockCalendarPolicy.Sample? {
        try ClockCalendarPolicy.sample(at: date(iso), schedule: schedule ?? recipe(), timeZone: zone ?? utc,
                                       coordinate: nil)
    }
    private func decide(_ session: ClockModeSession, _ value: ClockCalendarPolicy.Sample?,
                        enabled: Bool = true, safe: Bool = false, sleeping: Bool = false,
                        competing: Bool = false) -> ClockModeSession.Decision {
        session.decision(schedule: recipe(), sample: value, enabled: enabled, safeStartup: safe,
                         sleeping: sleeping, competingPolicy: competing)
    }

    func testFixedDayEveningAndMidnight() throws {
        XCTAssertEqual(try sample("2026-10-15T07:59:00Z")?.level.float, 0.3)
        XCTAssertEqual(try sample("2026-10-15T08:00:00Z")?.level.float, 0.8)
        XCTAssertEqual(try sample("2026-10-15T20:00:00Z")?.level.float, 0.3)
        XCTAssertEqual(try sample("2026-10-16T00:00:00Z")?.level.float, 0.3)
    }

    func testTimeZoneChangeReevaluatesCurrentInterval() throws {
        let instant = "2026-10-15T07:00:00Z"
        XCTAssertEqual(try sample(instant)?.level.float, 0.3)
        XCTAssertEqual(try sample(instant, zone: TimeZone(identifier: "Europe/Moscow"))?.level.float, 0.8)
    }

    func testNamedZoneDoesNotFollowMacZoneAndUnknownZoneRefuses() {
        var config = ClockModeConfiguration(timeZoneIdentifier: "Europe/Moscow", resumePolicy: .currentInterval,
                                            displays: [])
        XCTAssertEqual(config.timeZone(current: utc)?.identifier, "Europe/Moscow")
        config.timeZoneIdentifier = nil
        XCTAssertEqual(config.timeZone(current: utc), utc)
        config.timeZoneIdentifier = "not-a-time-zone"
        XCTAssertNil(config.timeZone(current: utc))
    }

    func testSpringGapStepsAtFirstValidTime() throws {
        let schedule = recipe(entries: [
            .init(anchor: .time, timeMinute: 150, brightness: 0.8, transition: .instant),
            .init(anchor: .time, timeMinute: 20 * 60, brightness: 0.3, transition: .instant)
        ])
        let zone = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(try sample("2026-03-08T06:59:00Z", schedule, zone: zone)?.level.float, 0.3)
        XCTAssertEqual(try sample("2026-03-08T07:00:00Z", schedule, zone: zone)?.level.float, 0.8)
    }

    func testAutumnRepeatedHourNeverRevertsOrFiresTwice() throws {
        let schedule = recipe(entries: [
            .init(anchor: .time, timeMinute: 90, brightness: 0.8, transition: .instant),
            .init(anchor: .time, timeMinute: 20 * 60, brightness: 0.3, transition: .instant)
        ])
        let zone = TimeZone(identifier: "America/New_York")!
        let first = try XCTUnwrap(sample("2026-11-01T05:30:00Z", schedule, zone: zone))
        let repeated = try XCTUnwrap(sample("2026-11-01T06:10:00Z", schedule, zone: zone))
        XCTAssertEqual(first.level.float, 0.8)
        XCTAssertEqual(repeated, first)
    }

    func testContinuousTransitionUsesActualElapsedTimeAcrossDST() throws {
        let schedule = recipe(entries: [
            .init(anchor: .time, timeMinute: 0, brightness: 0, transition: .instant),
            .init(anchor: .time, timeMinute: 4 * 60, brightness: 1, transition: .continuous)
        ])
        // Midnight to 04:00 spans three real hours on spring-forward day; 03:00 is two hours in.
        let result = try XCTUnwrap(sample("2026-03-08T07:00:00Z", schedule,
                                          zone: TimeZone(identifier: "America/New_York")))
        XCTAssertEqual(result.level.normalized, 2.0 / 3, accuracy: 0.0001)
    }

    func testCallerSuppliedRampAndZeroRamp() throws {
        var schedule = recipe(entries: [
            .init(anchor: .time, timeMinute: 8 * 60, brightness: 1, transition: .instant),
            .init(anchor: .time, timeMinute: 20 * 60, brightness: 0, transition: .ramp)
        ], ramp: 120)
        XCTAssertEqual(try sample("2026-10-15T19:00:00Z", schedule)?.level.normalized, 0.5)
        schedule.rampMinutes = 0
        XCTAssertEqual(try sample("2026-10-15T19:59:00Z", schedule)?.level.normalized, 1)
    }

    func testNoLocationOrMissingSolarEventDoesNotInventAnchor() throws {
        let schedule = recipe(entries: [.init(anchor: .sunset, brightness: 0.3)])
        XCTAssertNil(try sample("2026-10-15T12:00:00Z", schedule))
        let result = try ClockCalendarPolicy.sample(at: date("2026-06-21T12:00:00Z"), schedule: schedule,
                                                    timeZone: utc,
                                                    coordinate: GeoCoordinate(latitude: 89, longitude: 0))
        XCTAssertNil(result)
    }

    func testSolarOffsetAndFixedTimeCanCoexist() throws {
        let schedule = recipe(entries: [
            .init(anchor: .sunset, offsetMinutes: -30, brightness: 0.3, transition: .instant),
            .init(anchor: .time, timeMinute: 8 * 60, brightness: 0.8, transition: .instant)
        ])
        XCTAssertEqual(try sample("2026-10-15T19:00:00Z", schedule)?.level.float, 0.8)
        let solar = try ClockCalendarPolicy.sample(at: date("2026-10-15T23:00:00Z"), schedule: schedule,
                                                   timeZone: utc,
                                                   coordinate: GeoCoordinate(latitude: 51.5, longitude: 0))
        XCTAssertEqual(solar?.level.float, 0.3)
    }

    func testInvalidSolarCoordinatesRefuseWithoutNumericConversionTrap() {
        XCTAssertThrowsError(try ClockCalendarPolicy.sample(at: date("2026-10-15T12:00:00Z"), schedule: recipe(),
                                                            timeZone: utc,
                                                            coordinate: GeoCoordinate(latitude: .nan, longitude: 0)))
    }

    func testInvalidPointsAndCoincidentPointsRefuse() throws {
        var schedule = recipe()
        schedule.entries[0].brightness = .nan
        XCTAssertThrowsError(try sample("2026-10-15T12:00:00Z", schedule))
        schedule = recipe()
        schedule.entries[0].timeMinute = 1440
        XCTAssertThrowsError(try sample("2026-10-15T12:00:00Z", schedule))
        schedule = recipe()
        schedule.entries[0].offsetMinutes = Int.max
        XCTAssertThrowsError(try sample("2026-10-15T12:00:00Z", schedule))
        schedule = recipe()
        schedule.entries.append(schedule.entries[0])
        XCTAssertThrowsError(try sample("2026-10-15T12:00:00Z", schedule))
        schedule = recipe(ramp: -1)
        XCTAssertThrowsError(try sample("2026-10-15T12:00:00Z", schedule))
    }

    func testWakeCatchUpRequestsOnlyCurrentInterval() throws {
        var session = ClockModeSession()
        session.didWake(policy: .currentInterval)
        let current = try sample("2026-10-17T21:00:00Z")
        XCTAssertEqual(decide(session, current), .request(.byID(.setBrightness(level(Double(Float(0.3))), method: .software),
                                                             recipe().displayID)))
    }

    func testWakePauseIsExplicitlyResumed() throws {
        var session = ClockModeSession()
        session.didWake(policy: .pauseUntilResumed)
        let current = try sample("2026-10-15T12:00:00Z")
        XCTAssertEqual(decide(session, current), .hold(.resumePaused))
        session.resume()
        guard case .request = decide(session, current) else { return XCTFail("resume must permit current request") }
    }

    func testManualOverrideHoldsUntilNextPointIncludingWake() throws {
        var session = ClockModeSession()
        let current = try sample("2026-10-15T12:00:00Z")
        session.noteManualChange(to: recipe().displayID, sample: current)
        XCTAssertEqual(decide(session, current), .hold(.manualOverride))
        session.didWake(policy: .currentInterval)
        XCTAssertEqual(decide(session, current), .hold(.manualOverride))
        guard case .request = decide(session, try sample("2026-10-15T20:00:00Z")) else {
            return XCTFail("next interval must release manual hold")
        }
    }

    func testManualOverrideSurvivesDSTRepeatedHour() throws {
        let schedule = recipe(entries: [.init(anchor: .time, timeMinute: 90, brightness: 0.8, transition: .instant)])
        let zone = TimeZone(identifier: "America/New_York")!
        var session = ClockModeSession()
        let first = try sample("2026-11-01T05:40:00Z", schedule, zone: zone)
        session.noteManualChange(to: schedule.displayID, sample: first)
        let repeated = try sample("2026-11-01T06:10:00Z", schedule, zone: zone)
        XCTAssertEqual(session.decision(schedule: schedule, sample: repeated, enabled: true, safeStartup: false,
                                        sleeping: false, competingPolicy: false), .hold(.manualOverride))
    }

    func testDisabledSafeStartupSleepAndGroupsNeverProduceRequests() throws {
        let session = ClockModeSession()
        let current = try sample("2026-10-15T12:00:00Z")
        XCTAssertEqual(decide(session, current, enabled: false), .hold(.disabled))
        XCTAssertEqual(decide(session, current, safe: true), .hold(.safeStartup))
        XCTAssertEqual(decide(session, current, sleeping: true), .hold(.sleeping))
        XCTAssertEqual(decide(session, current, competing: true), .hold(.competingPolicy))
        XCTAssertEqual(decide(session, nil), .hold(.noAnchor))
    }

    func testRestoreIsAlwaysExplicitBrightnessOnlyAndSameController() {
        let schedule = recipe(method: .hardware)
        XCTAssertEqual(schedule.restoreRequest, .byID(.setBrightness(level(0.6), method: .hardware), schedule.displayID))
    }

    func testSettingsBackwardCompatibilityAndClockRoundTrip() throws {
        let old = try JSONDecoder().decode(OpenDisplaySettings.self,
            from: Data(#"{"clockScheduleEnabled":true,"clockScheduleEntries":[]}"#.utf8))
        XCTAssertTrue(old.clockScheduleEnabled)
        XCTAssertNil(old.clockMode)
        var settings = old
        settings.clockMode = ClockModeConfiguration(timeZoneIdentifier: "Europe/Moscow",
                                                   resumePolicy: .pauseUntilResumed, displays: [recipe()])
        let decoded = try JSONDecoder().decode(OpenDisplaySettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }

    func testMalformedExplicitSettingsNeverReactivateLegacySchedule() throws {
        let settings = try JSONDecoder().decode(OpenDisplaySettings.self,
            from: Data(#"{"clockScheduleEnabled":true,"clockMode":{"displays":"damaged"}}"#.utf8))
        XCTAssertTrue(settings.clockScheduleEnabled)
        XCTAssertNotNil(settings.clockMode)
        XCTAssertEqual(settings.clockMode?.displays, [])
        let legacy = try JSONDecoder().decode(OpenDisplaySettings.self,
            from: Data(#"{"clockScheduleEnabled":true,"clockMode":null}"#.utf8))
        XCTAssertNil(legacy.clockMode)
    }

    func testEmptyScheduleAndSingleFixedPoint() throws {
        XCTAssertNil(try sample("2026-10-15T12:00:00Z", recipe(entries: [])))
        let single = recipe(entries: [.init(anchor: .time, timeMinute: 8 * 60, brightness: 0.7, transition: .instant)])
        XCTAssertEqual(try sample("2026-10-15T01:00:00Z", single)?.level.float, 0.7)
    }

    func testTwoRecipesKeepIndependentEveningAndDDCRoute() async throws {
        let first = recipe(id: "one", method: .ddc)
        let second = recipe(id: "two", entries: [
            .init(anchor: .time, timeMinute: 8 * 60, brightness: 0.5, transition: .instant),
            .init(anchor: .time, timeMinute: 20 * 60, brightness: 0.2, transition: .instant)
        ])
        let environment = ClockFakeEnvironment(schedules: [first, second])
        let engine = AutomationEngine(environment: environment)
        for schedule in [first, second] {
            let value = try XCTUnwrap(sample("2026-10-15T21:00:00Z", schedule))
            let result = await engine.run(.byID(.setBrightness(value.level, method: schedule.method), schedule.displayID))
            XCTAssertTrue(result.succeeded)
        }
        let values = await environment.values
        XCTAssertEqual(values[first.displayID]?.float, 0.3)
        XCTAssertEqual(values[second.displayID]?.float, 0.2)
    }

    func testArchiveReportsDisconnectedRecipeIdentityWithoutRetargeting() throws {
        var settings = OpenDisplaySettings.default
        settings.clockMode = ClockModeConfiguration(timeZoneIdentifier: nil, resumePolicy: .currentInterval,
                                                   displays: [recipe(id: "remembered")])
        let archive = SettingsArchive(createdAt: date("2026-10-15T12:00:00Z"), appVersion: nil, settings: settings,
                                      favorites: .init(), registry: .init(), scenes: [], defaults: .init())
        XCTAssertTrue(archive.referencedDisplayIDs.contains(.init(rawValue: "remembered")))
        XCTAssertEqual(try SettingsArchive.decode(archive.encoded()).settings.clockMode, settings.clockMode)
    }

    func testTwoExplicitDisplaysRequestIndependentValuesAndRepeatIdempotently() async throws {
        let first = recipe(id: "one", method: .native)
        let second = recipe(id: "two", method: .software, entries: [
            .init(anchor: .time, timeMinute: 8 * 60, brightness: 0.5, transition: .instant),
            .init(anchor: .time, timeMinute: 20 * 60, brightness: 0.2, transition: .instant)
        ])
        let environment = ClockFakeEnvironment(schedules: [first, second])
        let engine = AutomationEngine(environment: environment)
        for _ in 0..<2 {
            for schedule in [first, second] {
                let sample = try ClockCalendarPolicy.sample(at: date("2026-10-15T12:00:00Z"), schedule: schedule,
                                                            timeZone: utc, coordinate: nil)
                let decision = ClockModeSession().decision(schedule: schedule, sample: sample, enabled: true,
                                                          safeStartup: false, sleeping: false, competingPolicy: false)
                guard case .request(let request) = decision else { return XCTFail("expected recipe") }
                let result = await engine.run(request)
                XCTAssertTrue(result.succeeded)
                XCTAssertEqual(result.brightness?.route, schedule.method == .native ? .native : .software)
            }
        }
        let values = await environment.values
        XCTAssertEqual(values[first.displayID]?.float, 0.8)
        XCTAssertEqual(values[second.displayID]?.float, 0.5)
        let result = await engine.run(first.restoreRequest)
        XCTAssertTrue(result.succeeded)
        let restored = await environment.values[first.displayID]
        XCTAssertEqual(restored, first.restoreLevel)
    }

    func testHardwareOnlyRefusesSoftwareAndMissingOrOfflineNeverWrite() async {
        let software = recipe()
        let environment = ClockFakeEnvironment(schedules: [software])
        let engine = AutomationEngine(environment: environment)
        let hardware = await engine.run(.byID(.setBrightness(level(0.5), method: .hardware), software.displayID))
        XCTAssertEqual(hardware.issue?.code, .methodUnavailable)
        let missing = await engine.run(.byID(.setBrightness(level(0.5), method: .automatic), .init(rawValue: "missing")))
        XCTAssertEqual(missing.issue?.code, .displayNotFound)
        await environment.disconnect()
        let offline = await engine.run(software.restoreRequest)
        XCTAssertEqual(offline.issue?.code, .displayNotConnected)
        let writes = await environment.values
        XCTAssertTrue(writes.isEmpty)
    }
}

private actor ClockFakeEnvironment: AutomationEnvironment {
    nonisolated let surface = AutomationSurface.console
    var candidates: [AutomationDisplayCandidate]
    let methods: [DisplayRecordID: BrightnessMethodRequest]
    var values: [DisplayRecordID: AutomationLevel] = [:]

    init(schedules: [ClockDisplaySchedule]) {
        candidates = schedules.map { .init(id: $0.displayID, name: $0.displayID.rawValue, availability: .active) }
        methods = Dictionary(uniqueKeysWithValues: schedules.map { ($0.displayID, $0.method) })
    }
    func disconnect() { candidates = candidates.map { var copy = $0; copy.availability = .disconnected; return copy } }
    func displaySet() async -> AutomationDisplaySet { .init(candidates: candidates) }
    func brightnessRoutes(for display: AutomationDisplayCandidate) async -> BrightnessRouteAvailability {
        let route: BrightnessRoute = methods[display.id] == .native ? .native
            : methods[display.id] == .ddc ? .ddc : .software
        return .init(current: route, states: [route: .available])
    }
    func writeBrightness(_ level: AutomationLevel, to display: AutomationDisplayCandidate,
                         via route: BrightnessRoute) async throws(AutomationIssue) -> BrightnessWriteReport {
        values[display.id] = level
        return .init(requested: level, accepted: true,
                     readback: route == .software ? .applied(level.normalized) : .level(level.normalized))
    }
}
