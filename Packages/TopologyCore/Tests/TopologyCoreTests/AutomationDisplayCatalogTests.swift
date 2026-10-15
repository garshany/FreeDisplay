import AutomationSchema
import DisplayDomain
import XCTest
@testable import TopologyCore

final class AutomationDisplayCatalogTests: XCTestCase {
    private func obs(_ id: String, active: Bool = true, main: Bool = false, builtIn: Bool = false,
                     mode: DisplayMode? = nil) -> DisplayObservation {
        DisplayObservation(recordID: DisplayRecordID(rawValue: id), isActive: active, mode: mode, isMain: main,
                           displayClass: builtIn ? .builtIn : .external, generation: .initial)
    }

    private let names = ["builtin": "Built-in Retina Display", "desk": "Dell U2720Q", "tv": "LG TV",
                         "mirror": "Projector", "side": "Acer"]
    private func name(_ observation: DisplayObservation) -> String { names[observation.recordID.rawValue] ?? "?" }

    private func mode(_ w: Int, _ h: Int, hz: Double = 60, hiDPI: Bool = false) -> DisplayMode {
        DisplayMode(pixelWidth: hiDPI ? w * 2 : w, pixelHeight: hiDPI ? h * 2 : h,
                    pointWidth: w, pointHeight: h, refreshHz: hz, isHiDPI: hiDPI)
    }

    // MARK: - Entity listing

    func testListsMainFirstThenActiveThenInactiveThenTurnedOff() {
        let displays = [obs("side"), obs("mirror", active: false), obs("builtin", builtIn: true),
                        obs("desk", main: true)]
        let offline = [ManagedOfflineDisplay(recordID: DisplayRecordID(rawValue: "tv"), cgID: 9, name: "LG TV",
                                             displayClass: .television)]
        let entries = AutomationDisplayCatalog.entries(displays: displays, offline: offline, name: name)
        XCTAssertEqual(entries.map(\.id.rawValue), ["desk", "side", "builtin", "mirror", "tv"])
        XCTAssertEqual(entries.map(\.availability), [.active, .active, .active, .inactive, .disconnected])
        XCTAssertEqual(entries.first?.isMain, true)
        XCTAssertEqual(entries.first { $0.id.rawValue == "builtin" }?.isBuiltIn, true)
        XCTAssertEqual(entries.last?.name, "LG TV")
    }

    func testAnOffDisplayThatCameBackIsListedOnceAsCurrent() {
        let offline = [ManagedOfflineDisplay(recordID: DisplayRecordID(rawValue: "desk"), cgID: 4, name: "Old name",
                                             displayClass: .external)]
        let entries = AutomationDisplayCatalog.entries(displays: [obs("desk", main: true)], offline: offline, name: name)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].availability, .active)
        XCTAssertEqual(entries[0].name, "Dell U2720Q")
    }

    func testAnInactiveMainIsNotReportedAsMain() {
        let entries = AutomationDisplayCatalog.entries(displays: [obs("desk", active: false, main: true)], offline: [], name: name)
        XCTAssertEqual(entries.first?.isMain, false)
    }

    func testNameSearchIgnoresCaseAndDiacritics() {
        let entries = AutomationDisplayCatalog.entries(
            displays: [obs("desk", main: true), obs("builtin", builtIn: true)], offline: [], name: name)
        XCTAssertEqual(AutomationDisplayCatalog.entries(matching: "dell", in: entries).map(\.id.rawValue), ["desk"])
        XCTAssertEqual(AutomationDisplayCatalog.entries(matching: "RÉTINA", in: entries).map(\.id.rawValue), ["builtin"])
        XCTAssertEqual(AutomationDisplayCatalog.entries(matching: "  ", in: entries).count, 2)
    }

    func testSavedIdentifiersResolveInOrderAndAbsentOnesComeBackDisconnected() {
        let entries = AutomationDisplayCatalog.entries(displays: [obs("desk", main: true)], offline: [], name: name)
        let resolved = AutomationDisplayCatalog.resolve(["gone", "desk", "remembered"], in: entries) { id in
            id.rawValue == "remembered" ? "Studio Display" : nil
        }
        XCTAssertEqual(resolved.map(\.id.rawValue), ["gone", "desk", "remembered"])
        XCTAssertEqual(resolved.map(\.availability), [.disconnected, .active, .disconnected])
        XCTAssertEqual(resolved.last?.name, "Studio Display")
        // Never dropped, even when nothing is known about it: an empty parameter could fall back to
        // a default display, a disconnected one makes the action fail instead.
        XCTAssertEqual(resolved.first?.name, "gone")
        XCTAssertEqual(AutomationDisplayCatalog.target(resolved[0].id, in: [obs("desk", main: true)]), .missing)
    }

    // MARK: - Target resolution

    func testTargetNeverSubstitutesAnotherDisplay() {
        let displays = [obs("builtin", main: true, builtIn: true), obs("mirror", active: false)]
        XCTAssertEqual(AutomationDisplayCatalog.target(DisplayRecordID(rawValue: "desk"), in: displays), .missing)
        guard case .inactive(let inactive) = AutomationDisplayCatalog.target(DisplayRecordID(rawValue: "mirror"), in: displays)
        else { return XCTFail("a present but inactive display is reported as inactive") }
        XCTAssertEqual(inactive.recordID.rawValue, "mirror")
        guard case .active(let active) = AutomationDisplayCatalog.target(DisplayRecordID(rawValue: "builtin"), in: displays)
        else { return XCTFail("an active display is targetable") }
        XCTAssertEqual(active.recordID.rawValue, "builtin")
    }

    func testBuiltInDefaultIsOnlyAnActiveBuiltIn() {
        XCTAssertEqual(AutomationDisplayCatalog.activeBuiltIn(in: [obs("desk", main: true), obs("builtin", builtIn: true)])?
            .recordID.rawValue, "builtin")
        XCTAssertNil(AutomationDisplayCatalog.activeBuiltIn(in: [obs("desk", main: true)]))  // Mac mini: no fallback
        XCTAssertNil(AutomationDisplayCatalog.activeBuiltIn(in: [obs("desk", main: true),
                                                                 obs("builtin", active: false, builtIn: true)]))
    }

    // MARK: - Brightness

    func testPercentConversionsClampAndRound() {
        XCTAssertEqual(AutomationBrightness.percent(0.556), 56)
        XCTAssertEqual(AutomationBrightness.percent(1.4), 100)
        XCTAssertEqual(AutomationBrightness.percent(-1), 0)
        XCTAssertEqual(AutomationBrightness.percent(.nan), 0)
        XCTAssertEqual(AutomationBrightness.level(percent: 40), 0.4)
        XCTAssertEqual(AutomationBrightness.level(percent: 140), 1)
    }

    func testLevelReadbackMustLandOnTheRequestedPercent() {
        XCTAssertEqual(AutomationBrightness.outcome(requestedPercent: 50, readback: .level(0.5002)),
                       .init(resultingPercent: 50, verified: true))
        XCTAssertEqual(AutomationBrightness.outcome(requestedPercent: 5, readback: .level(0.15)),
                       .init(resultingPercent: 15, verified: false))  // e.g. a software floor
    }

    func testDDCReadbackIsJudgedInMonitorUnits() {
        // A 0–100 monitor answering one unit off is the app's normal rounding allowance.
        XCTAssertEqual(AutomationBrightness.outcome(requestedPercent: 50, readback: .ddc(current: 49, max: 100)),
                       .init(resultingPercent: 49, verified: true))
        // A coarse 0–10 scale: 33 % → raw 3 is what the app sent, reported as 30 %.
        XCTAssertEqual(AutomationBrightness.outcome(requestedPercent: 33, readback: .ddc(current: 3, max: 10)),
                       .init(resultingPercent: 30, verified: true))
        // A monitor that ignored the write.
        XCTAssertEqual(AutomationBrightness.outcome(requestedPercent: 80, readback: .ddc(current: 20, max: 100)),
                       .init(resultingPercent: 20, verified: false))
        XCTAssertEqual(AutomationBrightness.outcome(requestedPercent: 80, readback: .ddc(current: 20, max: 0)),
                       .init(resultingPercent: nil, verified: false))
    }

    func testNoReadbackIsNeverVerified() {
        XCTAssertEqual(AutomationBrightness.outcome(requestedPercent: 50, readback: .none),
                       .init(resultingPercent: nil, verified: false))
    }

    // MARK: - Modes

    func testModeOptionsKeepEveryExactModeLargestFirst() {
        let modes = [mode(1920, 1080), mode(1920, 1080, hz: 59.94), mode(1280, 720), mode(1920, 1080, hiDPI: true)]
        let options = AutomationModeOptions.options(from: modes, current: mode(1280, 720))
        XCTAssertEqual(options.count, 4)  // nothing collapsed: 59.94 and 60 Hz are separate choices
        XCTAssertEqual(options.first?.pointWidth, 1920)
        XCTAssertEqual(options.last, mode(1280, 720))
    }

    func testModeOptionsIncludeTheCurrentModeEvenIfUnlisted() {
        let current = mode(1600, 900)
        XCTAssertTrue(AutomationModeOptions.options(from: [mode(1920, 1080)], current: current).contains(current))
    }

    func testModeKeysRoundTripExactly() throws {
        let original = DisplayMode(pixelWidth: 3840, pixelHeight: 2160, pointWidth: 1920, pointHeight: 1080,
                                   refreshHz: 59.94, isHiDPI: true, bitDepth: 10)
        let key = AutomationModeOptions.key(for: original)
        let decoded = try XCTUnwrap(AutomationModeOptions.mode(forKey: key))
        XCTAssertTrue(DisplayModeChoices.matches(decoded, requested: original))
        XCTAssertNil(AutomationModeOptions.mode(forKey: "1920x1080@60@2x"))  // legacy rounded keys aren't modes
        XCTAssertNil(AutomationModeOptions.mode(forKey: "garbage"))
    }

    func testOfferedModeIsAnExactMatchNeverANearestOne() {
        let offered = [mode(1920, 1080, hz: 59.94), mode(1920, 1080, hiDPI: true)]
        XCTAssertNil(AutomationModeOptions.offered(mode(1920, 1080), among: offered))  // 60 Hz LoDPI isn't there
        XCTAssertEqual(AutomationModeOptions.offered(mode(1920, 1080, hiDPI: true), among: offered),
                       mode(1920, 1080, hiDPI: true))
    }

    func testModeOutcomeClassification() {
        let requested = mode(1920, 1080)
        XCTAssertEqual(AutomationModeOptions.outcome(error: nil, revertPending: true, actual: requested, requested: requested),
                       .awaitingConfirmation)
        XCTAssertEqual(AutomationModeOptions.outcome(error: nil, revertPending: false, actual: requested, requested: requested),
                       .alreadyInEffect)
        XCTAssertEqual(AutomationModeOptions.outcome(error: "restored", revertPending: false, actual: mode(1280, 720),
                                                     requested: requested), .failed("restored"))
        XCTAssertEqual(AutomationModeOptions.outcome(error: nil, revertPending: false, actual: mode(1280, 720),
                                                     requested: requested), .notConfirmed)
        XCTAssertEqual(AutomationModeOptions.outcome(error: nil, revertPending: false, actual: nil, requested: requested),
                       .notConfirmed)
    }

    // MARK: - Shared automation candidates (FD-066)

    func testDisplaySetCarriesRecordsGroupsPointerAndTurnedOffDisplays() throws {
        let deskRecord = DisplayRecord(id: DisplayRecordID(rawValue: "disp_desk"), alias: "Desk", tags: ["studio"],
                                       fingerprint: DisplayFingerprint(vendorID: 4268, productID: 41_234, serialNumber: "XYZ"))
        let tvRecord = DisplayRecord(id: DisplayRecordID(rawValue: "disp_tv"), alias: "Living room",
                                     fingerprint: DisplayFingerprint())
        let records = [DisplayRecordID(rawValue: "desk"): deskRecord, DisplayRecordID(rawValue: "tv"): tvRecord]
        let work = DisplayGroup(name: "Work", memberRecordIDs: [DisplayRecordID(rawValue: "disp_desk")])
        var desk = obs("desk", main: true)
        desk.cgDisplayID = 2
        var builtin = obs("builtin", builtIn: true)
        builtin.cgDisplayID = 1
        let offline = [ManagedOfflineDisplay(recordID: DisplayRecordID(rawValue: "tv"), cgID: 9, name: "LG TV",
                                             displayClass: .television)]
        let set = AutomationDisplayCatalog.displaySet(
            displays: [desk, builtin, obs("mirror", active: false)], offline: offline, name: name,
            record: { records[$0] }, groups: [work], pointerDisplayID: 2, generation: 5)

        XCTAssertEqual(set.topologyGeneration, 5)
        XCTAssertEqual(set.knownGroups, ["Work"])
        XCTAssertEqual(set.candidates.map(\.id.rawValue), ["desk", "builtin", "mirror", "tv"])
        let deskCandidate = set.candidates[0]
        XCTAssertEqual(deskCandidate.registryID?.rawValue, "disp_desk")
        XCTAssertEqual(deskCandidate.alias, "Desk")
        XCTAssertEqual(deskCandidate.groups, ["Work"], "membership by the registry id counts")
        XCTAssertEqual(deskCandidate.serial, "XYZ")
        XCTAssertEqual(deskCandidate.containsPointer, true)
        XCTAssertEqual(set.candidates[1].containsPointer, false)
        XCTAssertEqual(set.candidates[2].availability, .inactive)
        let tv = set.candidates[3]
        XCTAssertEqual(tv.availability, .disconnected)
        XCTAssertEqual(tv.reachability, .managedOffline)
        XCTAssertEqual(tv.cgDisplayID, 9)
        XCTAssertEqual(tv.name, "Living room", "a turned-off display keeps its alias")
        XCTAssertEqual(try AutomationSelectorResolver.resolveOne(.display(.alias("Living room")), in: set).id.rawValue, "tv")
    }

    /// The CLI keeps a turned-off display reachable as an inactive placeholder observation; it is
    /// still not connected.
    func testALedgerPlaceholderObservationIsDisconnected() {
        var placeholder = obs("tv", active: false)
        placeholder.cgDisplayID = 9
        let offline = [ManagedOfflineDisplay(recordID: DisplayRecordID(rawValue: "tv"), cgID: 9, name: "LG TV",
                                             displayClass: .television)]
        let set = AutomationDisplayCatalog.displaySet(displays: [placeholder], offline: offline, name: name,
                                                      record: { _ in nil }, groups: [], pointerDisplayID: nil,
                                                      generation: 0)
        XCTAssertEqual(set.candidates.count, 1)
        XCTAssertEqual(set.candidates[0].availability, .disconnected)
        XCTAssertNil(set.candidates[0].containsPointer)
    }
}

