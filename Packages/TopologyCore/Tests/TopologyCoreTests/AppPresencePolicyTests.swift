import XCTest
import DisplayDomain
@testable import TopologyCore

/// Dock policy (SO-13/FB-15), safe startup (FA-09), the notice filter (SO-12/FA-16) and the
/// settings fields behind them.
final class AppPresencePolicyTests: XCTestCase {
    // MARK: - Dock icon policy

    func testDockPolicies() {
        let cases: [(DockIconPolicy, settings: Bool, any: Bool, shows: Bool)] = [
            (.never, true, true, false),
            (.whileSettingsOpen, false, false, false),
            (.whileSettingsOpen, false, true, false),  // a PiP or About window alone doesn't count
            (.whileSettingsOpen, true, true, true),
            (.whileAnyWindowOpen, false, false, false),
            (.whileAnyWindowOpen, false, true, true),
            (.whileAnyWindowOpen, true, false, true),  // Settings is a window too
            (.always, false, false, true),
        ]
        for (policy, settingsOpen, anyOpen, shows) in cases {
            XCTAssertEqual(policy.showsDockIcon(settingsWindowOpen: settingsOpen, anyWindowOpen: anyOpen), shows,
                           "\(policy) settings:\(settingsOpen) any:\(anyOpen)")
        }
    }

    func testDockPolicyDefaultsToWhileSettingsIsOpen() {
        XCTAssertEqual(OpenDisplaySettings.default.dockIconPolicy, .whileSettingsOpen)
    }

    // MARK: - Safe startup

    func testSafeStartupNamesDefaultGroupDayRestorationPowerAndSleepPolicies() {
        var settings = OpenDisplaySettings.default
        settings.defaultDisplayGroup.syncBrightness = true
        settings.adaptiveDayPresetByDisplay = ["cg:A": 5]
        settings.xdrBrightnessEnabled = true
        settings.xdrDisableOnBattery = true
        settings.preventDisplaySleepWithExternal = true
        let before = settings
        XCTAssertEqual(SafeStartup.activeSuspensions(settings: settings, turnedOffDisplays: false),
                       [.displayGroupSync, .launchRestores, .xdrPowerAutomation, .displaySleepPrevention])
        XCTAssertEqual(settings, before, "safe-session reporting retains every stored setting")
    }

    func testSafeStartupIsShiftOrTheLaunchArgument() {
        XCTAssertFalse(SafeStartup.isRequested(arguments: ["/Applications/FreeDisplay.app"], shiftHeld: false))
        XCTAssertTrue(SafeStartup.isRequested(arguments: [], shiftHeld: true))
        XCTAssertTrue(SafeStartup.isRequested(arguments: ["app", "--safe-mode"], shiftHeld: false))
    }

    func testNothingConfiguredMeansNothingHeldBack() {
        XCTAssertTrue(SafeStartup.activeSuspensions(settings: .default, turnedOffDisplays: false).isEmpty)
    }

    func testActiveSuspensionsNameWhatWouldHaveActed() {
        var settings = OpenDisplaySettings.default
        settings.layoutProtectionEnabled = true  // on, but nothing protected yet: nothing to hold back
        settings.autoDisconnectBuiltInOnExternal = true
        settings.clockScheduleEnabled = true
        settings.appPresetsEnabled = true  // no presets configured
        settings.faceLightPriorStateByDisplay = ["cg:A": FaceLightPolicy.PriorState(brightness: 0.3)]
        XCTAssertEqual(SafeStartup.activeSuspensions(settings: settings, turnedOffDisplays: true),
                       [.turnedOffDisplays, .autoDisconnectBuiltIn, .adaptiveDisplay, .launchRestores])
    }

    func testConfiguredProtectionPresetsAndGroupsAreHeldBack() {
        let a = DisplayRecordID(rawValue: "cg:A"), b = DisplayRecordID(rawValue: "cg:B")
        var settings = OpenDisplaySettings.default
        settings.layoutProtectionEnabled = true
        settings.protectedLayouts = ["set": ProtectedConfig(
            snapshot: TopologySnapshot(generation: .init(1), observations: []), capturedAt: Date())]
        settings.appPresetsEnabled = true
        settings.appPresets = [AppPresetPolicy.AppPreset(bundleIdentifier: "com.example", applicationName: "Example",
                                                         brightness: 0.5)]
        settings.displayGroups = [DisplayGroup(name: "Desk", memberRecordIDs: [a, b])]
        // The app-preset ledger alone is a restore owed at launch.
        settings.appPresetPriorStateByDisplay = [a.rawValue: AppPresetPolicy.PriorState(brightness: 0.7)]
        XCTAssertEqual(SafeStartup.activeSuspensions(settings: settings, turnedOffDisplays: false),
                       [.layoutProtection, .appPresets, .displayGroupSync, .launchRestores])
    }

    func testAGroupThatSyncsNothingOrHasOneMemberHoldsNothingBack() {
        var settings = OpenDisplaySettings.default
        settings.displayGroups = [
            DisplayGroup(name: "Solo", memberRecordIDs: [DisplayRecordID(rawValue: "cg:A")]),
            DisplayGroup(name: "Off", memberRecordIDs: [DisplayRecordID(rawValue: "cg:B"), DisplayRecordID(rawValue: "cg:C")],
                         syncBrightness: false, syncContrast: false),
        ]
        XCTAssertTrue(SafeStartup.activeSuspensions(settings: settings, turnedOffDisplays: false).isEmpty)
    }

    // MARK: - Notice filter

    func testMutingRoutineProtectionKeepsFailuresAndEvents() {
        var settings = OpenDisplaySettings.default
        settings.displayNotificationsEnabled = true
        settings.routineProtectionNoticesEnabled = false
        XCTAssertFalse(NotificationPolicy.shouldDeliver(.routineProtection, settings: settings))
        XCTAssertTrue(NotificationPolicy.shouldDeliver(.failure, settings: settings))
        XCTAssertTrue(NotificationPolicy.shouldDeliver(.event, settings: settings))
    }

    func testNoticesOffSilencesEveryKind() {
        var settings = OpenDisplaySettings.default
        settings.displayNotificationsEnabled = false
        for kind in [NotificationPolicy.NoticeKind.event, .routineProtection, .failure] {
            XCTAssertFalse(NotificationPolicy.shouldDeliver(kind, settings: settings))
        }
    }

    func testRoutineProtectionNoticesDefaultOn() {
        var settings = OpenDisplaySettings.default
        settings.displayNotificationsEnabled = true
        XCTAssertTrue(NotificationPolicy.shouldDeliver(.routineProtection, settings: settings))
        XCTAssertEqual(settings.notificationStyle, .notificationCenter)
    }

    // MARK: - Persistence of the new fields

    func testNewFieldsDefaultWhenAbsentAndDegradeAlone() throws {
        let older = try JSONDecoder().decode(OpenDisplaySettings.self,
                                             from: Data(#"{"displayNotificationsEnabled": true}"#.utf8))
        XCTAssertEqual(older.notificationStyle, .notificationCenter)
        XCTAssertTrue(older.routineProtectionNoticesEnabled)
        XCTAssertEqual(older.dockIconPolicy, .whileSettingsOpen)

        let odd = try JSONDecoder().decode(OpenDisplaySettings.self, from: Data(
            #"{"dockIconPolicy": "sometimes", "notificationStyle": "appWindow", "routineProtectionNoticesEnabled": false}"#.utf8))
        XCTAssertEqual(odd.dockIconPolicy, .whileSettingsOpen)
        XCTAssertEqual(odd.notificationStyle, .appWindow)
        XCTAssertFalse(odd.routineProtectionNoticesEnabled)
    }
}
