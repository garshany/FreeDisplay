import XCTest
@testable import TopologyCore

/// SO-10 / SD-08: application timing preferences (blank, zero and unusable values each mean
/// something different), the shared reaction schedule, motion, and where Settings opens.
final class ApplicationPreferencesTests: XCTestCase {
    private typealias Timing = ApplicationTiming

    // MARK: - Parsing a timing field

    func testBlankFieldIsAutomaticNotZero() {
        XCTAssertEqual(Timing.parse(""), .accepted(.automatic))
        XCTAssertEqual(Timing.parse("   "), .accepted(.automatic))
        XCTAssertEqual(Timing.parse("0"), .accepted(.seconds(0)))
        XCTAssertNotEqual(Timing.parse(""), Timing.parse("0"))
    }

    func testAcceptsDecimalsWithAPointOrAComma() {
        XCTAssertEqual(Timing.parse("1.5"), .accepted(.seconds(1.5)))
        XCTAssertEqual(Timing.parse("1,5"), .accepted(.seconds(1.5)))
        XCTAssertEqual(Timing.parse(" 0.25 "), .accepted(.seconds(0.25)))
    }

    func testNegativeZeroIsZero() {
        XCTAssertEqual(Timing.parse("-0"), .accepted(.seconds(0)))
    }

    func testRejectsWhatIsNotANumber() {
        for text in ["abc", "nan", "NaN", "inf", "-inf", "infinity", "1.2.3", "0x10", "1s"] {
            XCTAssertEqual(Timing.parse(text), .rejected(.notANumber), text)
        }
    }

    func testRejectsNegativeValues() {
        XCTAssertEqual(Timing.parse("-1"), .rejected(.negative))
        XCTAssertEqual(Timing.parse("-0.5"), .rejected(.negative))
    }

    /// Nothing caps the value unless the caller asks: a large but schedulable value is accepted.
    func testNoMaximumUnlessOneIsGiven() {
        XCTAssertEqual(Timing.parse("3600"), .accepted(.seconds(3600)))
        XCTAssertEqual(Timing.parse("11", maximum: 10), .rejected(.aboveMaximum(10)))
        XCTAssertEqual(Timing.parse("10", maximum: 10), .accepted(.seconds(10)))
    }

    /// A value whose nanoseconds overflow what the scheduler takes would trap where it's used.
    func testRejectsValuesTooLargeToSchedule() {
        XCTAssertEqual(Timing.parse("1e11"), .rejected(.tooLargeToSchedule))
        XCTAssertEqual(Timing.parse("1e9"), .accepted(.seconds(1e9)))
    }

    func testFieldTextRoundTrips() {
        XCTAssertEqual(TimingValue.automatic.fieldText, "")
        XCTAssertEqual(TimingValue.seconds(0).fieldText, "0")
        XCTAssertEqual(TimingValue.seconds(2).fieldText, "2")
        XCTAssertEqual(TimingValue.seconds(1.25).fieldText, "1.25")
        XCTAssertEqual(Timing.parse(TimingValue.seconds(1.25).fieldText), .accepted(.seconds(1.25)))
    }

    // MARK: - Effective values

    func testAutomaticUsesTheAppsOwnValue() {
        XCTAssertEqual(Timing.seconds(.automatic, automatic: 0.24), 0.24)
        XCTAssertEqual(Timing.seconds(.seconds(0), automatic: 0.24), 0)
        XCTAssertEqual(Timing.seconds(.seconds(1.5), automatic: 0.24), 1.5)
    }

    /// A value that slipped past validation (a hand-edited file) is never applied as is.
    func testUnusableStoredValueFallsBackToAutomatic() {
        XCTAssertEqual(Timing.seconds(.seconds(-3), automatic: 0.24), 0.24)
        XCTAssertEqual(Timing.seconds(.seconds(.nan), automatic: 0.24), 0.24)
        XCTAssertEqual(Timing.seconds(.seconds(.infinity), automatic: 0.24), 0.24)
    }

    func testZeroDurationMeansNoTransition() {
        XCTAssertNil(Timing.transitionDuration(.seconds(0), automatic: 0.24, animationsEnabled: true, reduceMotion: false))
    }

    func testReduceMotionAlwaysMeansNoTransition() {
        XCTAssertNil(Timing.transitionDuration(.automatic, automatic: 0.24, animationsEnabled: true, reduceMotion: true))
        XCTAssertNil(Timing.transitionDuration(.seconds(1), automatic: 0.24, animationsEnabled: true, reduceMotion: true))
    }

    func testAnimationSwitchOffMeansNoTransition() {
        XCTAssertNil(Timing.transitionDuration(.seconds(1), automatic: 0.24, animationsEnabled: false, reduceMotion: false))
    }

    func testTransitionUsesTheOverrideOrTheDefault() {
        XCTAssertEqual(Timing.transitionDuration(.automatic, automatic: 0.24, animationsEnabled: true, reduceMotion: false), 0.24)
        XCTAssertEqual(Timing.transitionDuration(.seconds(0.6), automatic: 0.24, animationsEnabled: true, reduceMotion: false), 0.6)
    }

    // MARK: - Shared reaction schedule

    private let now = Date(timeIntervalSince1970: 10_000)

    /// Blank fields keep the behaviour from before the preferences existed: react at once.
    func testAutomaticDelaysReactImmediately() {
        let timing = ApplicationTimingPreferences()
        XCTAssertEqual(ConfiguredReactionSchedule.delay(for: .topologyChange, now: now, lastWakeAt: nil, timing: timing), 0)
        XCTAssertEqual(ConfiguredReactionSchedule.delay(for: .wake, now: now, lastWakeAt: now, timing: timing), 0)
    }

    func testConfigurationDelayAppliesToConfigurationChanges() {
        let timing = ApplicationTimingPreferences(configurationDelay: .seconds(0.5))
        XCTAssertEqual(ConfiguredReactionSchedule.delay(for: .topologyChange, now: now, lastWakeAt: nil, timing: timing), 0.5)
    }

    func testWakeDelayAppliesToTheWake() {
        let timing = ApplicationTimingPreferences(configurationDelay: .seconds(0.5), wakeDelay: .seconds(3))
        XCTAssertEqual(ConfiguredReactionSchedule.delay(for: .wake, now: now, lastWakeAt: now, timing: timing), 3)
    }

    /// Displays settling after a wake must not cut the wake delay short.
    func testAChangeInsideTheWakeDelayWaitsForItsEnd() {
        let timing = ApplicationTimingPreferences(configurationDelay: .seconds(0.5), wakeDelay: .seconds(3))
        let wokeAt = now.addingTimeInterval(-1)
        XCTAssertEqual(ConfiguredReactionSchedule.delay(for: .topologyChange, now: now, lastWakeAt: wokeAt, timing: timing),
                       2, accuracy: 1e-9)
    }

    func testAChangeAfterTheWakeDelayUsesTheConfigurationDelay() {
        let timing = ApplicationTimingPreferences(configurationDelay: .seconds(0.5), wakeDelay: .seconds(3))
        let wokeAt = now.addingTimeInterval(-60)
        XCTAssertEqual(ConfiguredReactionSchedule.delay(for: .topologyChange, now: now, lastWakeAt: wokeAt, timing: timing), 0.5)
    }

    func testAPendingWakeOutranksLaterChanges() {
        XCTAssertEqual(ConfiguredReactionSchedule.merged(.wake, with: .topologyChange), .wake)
        XCTAssertEqual(ConfiguredReactionSchedule.merged(nil, with: .topologyChange), .topologyChange)
        XCTAssertEqual(ConfiguredReactionSchedule.merged(.topologyChange, with: .wake), .wake)
    }

    // MARK: - Persistence and import

    func testTimingRoundTripsThroughTheSettingsFile() throws {
        var settings = OpenDisplaySettings()
        settings.applicationTiming = ApplicationTimingPreferences(
            configurationDelay: .seconds(0.2), wakeDelay: .automatic, animationDuration: .seconds(0))
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(OpenDisplaySettings.self, from: data)
        XCTAssertEqual(decoded.applicationTiming, settings.applicationTiming)
    }

    func testBlankIsStoredAsNull() throws {
        let data = try JSONEncoder().encode(ApplicationTimingPreferences(wakeDelay: .seconds(1.5)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(object["configurationDelay"] is NSNull)
        XCTAssertEqual(object["wakeDelay"] as? Double, 1.5)
    }

    func testAnOlderSettingsFileGetsAutomaticTimings() throws {
        let decoded = try JSONDecoder().decode(OpenDisplaySettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.applicationTiming, .default)
        XCTAssertTrue(decoded.preventDisplaySleepDisplayIDs.isEmpty)
    }

    func testOneMalformedFieldCostsOnlyThatField() throws {
        let json = #"{"applicationTiming": {"configurationDelay": "soon", "wakeDelay": 2}}"#
        let decoded = try JSONDecoder().decode(OpenDisplaySettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.applicationTiming.configurationDelay, .automatic)
        XCTAssertEqual(decoded.applicationTiming.wakeDelay, .seconds(2))
    }

    /// An import with an unusable timing is refused by key, like every other numeric setting.
    func testImportRefusesAnUnusableTiming() throws {
        let json = #"{"applicationTiming": {"wakeDelay": -4}}"#
        let decoded = try JSONDecoder().decode(OpenDisplaySettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.unusableValueKey, "applicationTiming.wakeDelay")
        XCTAssertNil(OpenDisplaySettings().unusableValueKey)
    }

    // MARK: - Settings window placement

    private let laptop = WindowFrame(x: 0, y: 0, width: 1440, height: 875)
    private let external = WindowFrame(x: 1440, y: 0, width: 2560, height: 1415)

    func testRestoresTheLastPositionOnAConnectedScreen() {
        let origin = SettingsWindowPlacementPolicy.origin(
            placement: .lastPosition, saved: WindowFrame(x: 1600, y: 200, width: 900, height: 660),
            width: 900, height: 660, screens: [laptop, external], pointerScreen: laptop)
        XCTAssertEqual(origin?.x, 1600)
        XCTAssertEqual(origin?.y, 200)
    }

    /// The display it was left on is gone: open where the user is looking instead.
    func testFallsBackToThePointerScreenWhenTheSpotIsOffScreen() {
        let origin = SettingsWindowPlacementPolicy.origin(
            placement: .lastPosition, saved: WindowFrame(x: 5000, y: 200, width: 900, height: 660),
            width: 900, height: 660, screens: [laptop], pointerScreen: laptop)
        XCTAssertEqual(origin?.x, 270)
        XCTAssertEqual(origin?.y, 107.5)
    }

    /// Partly off the edge (the screen shrank or moved): pulled back fully onto that screen.
    func testPullsAPartlyOffScreenWindowBackOn() {
        let origin = SettingsWindowPlacementPolicy.origin(
            placement: .lastPosition, saved: WindowFrame(x: 1000, y: 500, width: 900, height: 660),
            width: 900, height: 660, screens: [laptop], pointerScreen: laptop)
        XCTAssertEqual(origin?.x, 540)
        XCTAssertEqual(origin?.y, 215)
    }

    /// Larger than the screen: the title bar stays reachable at the top-left.
    func testAWindowLargerThanTheScreenKeepsItsTitleBarVisible() {
        let small = WindowFrame(x: 0, y: 0, width: 800, height: 600)
        let origin = SettingsWindowPlacementPolicy.origin(
            placement: .lastPosition, saved: WindowFrame(x: 100, y: 100, width: 900, height: 660),
            width: 900, height: 660, screens: [small], pointerScreen: small)
        XCTAssertEqual(origin?.x, 0)
        XCTAssertEqual(origin?.y, -60)
    }

    func testAnOversizedWindowOnFallbackKeepsTheTitleBarReachable() {
        let small = WindowFrame(x: 0, y: 0, width: 800, height: 600)
        let origin = SettingsWindowPlacementPolicy.origin(
            placement: .lastPosition, saved: nil, width: 900, height: 660,
            screens: [small], pointerScreen: small)
        XCTAssertEqual(origin?.x, 0)
        XCTAssertEqual(origin?.y, -60)
    }

    func testPointerScreenPlacementIgnoresTheSavedSpot() {
        let origin = SettingsWindowPlacementPolicy.origin(
            placement: .pointerScreen, saved: WindowFrame(x: 1600, y: 200, width: 900, height: 660),
            width: 900, height: 660, screens: [laptop, external], pointerScreen: external)
        XCTAssertEqual(origin?.x, 1440 + (2560 - 900) / 2)
        XCTAssertEqual(origin?.y, (1415 - 660) / 2)
    }

    func testRestoredSizeUsesTheSavedScreensGeometryInsteadOfThePointersScreen() {
        XCTAssertEqual(SettingsWindowPlacementPolicy.destinationScreen(
            placement: .lastPosition, saved: WindowFrame(x: 1600, y: 200, width: 900, height: 660),
            screens: [laptop, external], pointerScreen: laptop), external)
    }

    func testNoScreensLeavesTheWindowAlone() {
        XCTAssertNil(SettingsWindowPlacementPolicy.origin(
            placement: .lastPosition, saved: nil, width: 900, height: 660, screens: [], pointerScreen: nil))
    }

    func testPicksTheScreenTheWindowMostlyCovers() {
        // Straddles the two screens, mostly on the external one.
        let origin = SettingsWindowPlacementPolicy.origin(
            placement: .lastPosition, saved: WindowFrame(x: 1300, y: 100, width: 900, height: 660),
            width: 900, height: 660, screens: [laptop, external], pointerScreen: laptop)
        XCTAssertEqual(origin?.x, 1440)
        XCTAssertEqual(origin?.y, 100)
    }
}
