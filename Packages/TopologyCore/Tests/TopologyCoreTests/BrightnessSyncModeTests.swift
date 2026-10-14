import DisplayDomain
import XCTest
@testable import TopologyCore

/// TR-15/SO-05/AM-17/TB-14: explicit absolute and delta brightness sync beside the learned-offset
/// mode, the Default group, the outside-change switch and the one-operation Shift bypass.
final class BrightnessSyncModeTests: XCTestCase {
    private typealias Policy = GroupSyncPolicy

    private let epoch = Date(timeIntervalSinceReferenceDate: 0)
    private let builtIn = DisplayRecordID(rawValue: "cgid:1")
    private let desk = DisplayRecordID(rawValue: "cgid:2")
    private let side = DisplayRecordID(rawValue: "cgid:3")
    private let virtualScreen = DisplayRecordID(rawValue: "cgid:9")

    private func group(_ mode: BrightnessSyncMode, offsets: [DisplayRecordID: Float] = [:],
                       followsOutsideChanges: Bool = true,
                       members: [DisplayRecordID]? = nil) -> DisplayGroup {
        var made = DisplayGroup(name: "Desk", memberRecordIDs: members ?? [builtIn, desk, side],
                                brightnessMode: mode, followsOutsideChanges: followsOutsideChanges)
        for (member, offset) in offsets { made.setOffset(offset, for: member) }
        return made
    }

    private func world(levels: [DisplayRecordID: Float] = [:], present: [DisplayRecordID]? = nil,
                       governed: [DisplayRecordID] = []) -> Policy.World {
        Policy.World(present: Set(present ?? [builtIn, desk, side]), governed: Set(governed),
                     levels: levels)
    }

    private func write(_ value: Float, on display: DisplayRecordID, from previous: Float? = nil,
                       applied: Float? = nil, at now: Date? = nil, world: Policy.World? = nil,
                       via origin: Policy.ManualWrite.Origin = .slider, bypass: Bool = false,
                       token: Policy.SyncEcho.Token? = nil) -> Policy.ManualWrite {
        Policy.ManualWrite(value: value, display: display, token: token, now: now ?? epoch,
                           world: world ?? self.world(), origin: origin, appliedValue: applied,
                           previousValue: previous, bypass: bypass)
    }

    private func classify(_ write: Policy.ManualWrite, _ group: DisplayGroup,
                          state: Policy.GroupSyncState = .init(),
                          echo: Policy.SyncEcho = .init()) -> Policy.ManualWriteResult {
        Policy.classify(write, group: group, state: state, echo: echo)
    }

    private func fanOut(of result: Policy.ManualWriteResult,
                        file: StaticString = #filePath, line: UInt = #line) -> Policy.FanOut {
        guard case .leader(let fanOut) = result.outcome else {
            XCTFail("expected a leader event, got \(result.outcome)", file: file, line: line)
            return Policy.FanOut()
        }
        return fanOut
    }

    private func assertWrites(_ fanOut: Policy.FanOut, _ expected: [DisplayRecordID: Float],
                              file: StaticString = #filePath, line: UInt = #line) {
        let written = Dictionary(uniqueKeysWithValues: fanOut.writes.map { ($0.member, $0.value) })
        XCTAssertEqual(Set(written.keys), Set(expected.keys), file: file, line: line)
        for (member, value) in expected {
            XCTAssertEqual(written[member] ?? .nan, value, accuracy: 0.0001, file: file, line: line)
        }
    }

    // MARK: - Delta

    func testDeltaPreservesAStartingDifference() {
        // T23: +10% on the leader keeps a 20-point difference.
        let levels = world(levels: [builtIn: 0.20, desk: 0.40, side: 0.70])
        let result = classify(write(0.30, on: builtIn, from: 0.20, world: levels), group(.delta))
        assertWrites(fanOut(of: result), [desk: 0.50, side: 0.80])
    }

    func testDeltaClampsAtTheRailAndTheDifferenceShrinksWithoutLooping() {
        let first = classify(write(0.85, on: builtIn, from: 0.75,
                                   world: world(levels: [builtIn: 0.75, desk: 0.95])),
                             group(.delta, members: [builtIn, desk]))
        assertWrites(fanOut(of: first), [desk: 1.0])
        // Coming back down, desk starts from the rail it stopped at: the gap is now 15 points.
        let back = classify(write(0.75, on: builtIn, from: 0.85,
                                  world: world(levels: [builtIn: 0.85, desk: 1.0])),
                            group(.delta, members: [builtIn, desk]), state: first.state)
        assertWrites(fanOut(of: back), [desk: 0.90])
    }

    func testDeltaDoesNotRewriteAFollowerAlreadyOnTheRail() {
        let result = classify(write(0.6, on: builtIn, from: 0.5,
                                    world: world(levels: [desk: 1.0, side: 0.3])), group(.delta))
        assertWrites(fanOut(of: result), [side: 0.4])
    }

    func testDeltaSkipsAFollowerWhoseLevelIsUnknownInsteadOfGuessing() {
        let result = classify(write(0.6, on: builtIn, from: 0.5, world: world(levels: [desk: 0.4])),
                              group(.delta))
        let fan = fanOut(of: result)
        assertWrites(fan, [desk: 0.5])
        XCTAssertEqual(fan.unknownLevel, [side])
    }

    func testDeltaSendsNothingWithoutAKnownStartingLevelOrAChange() {
        let levels = world(levels: [desk: 0.4, side: 0.3])
        XCTAssertTrue(fanOut(of: classify(write(0.6, on: builtIn, from: nil, world: levels), group(.delta))).isEmpty)
        XCTAssertTrue(fanOut(of: classify(write(0.6, on: builtIn, from: 0.6, world: levels), group(.delta))).isEmpty)
    }

    func testDeltaMeasuresTheAppliedLevelSoASoftwareFloorDoesNotDragFollowers() {
        // A software leader asked for 5% but sits on its 15% floor, as it already did: no change.
        let levels = world(levels: [builtIn: 0.15, desk: 0.40, side: 0.40])
        let result = classify(write(0.05, on: builtIn, from: 0.15, applied: 0.15, world: levels), group(.delta))
        XCTAssertTrue(fanOut(of: result).isEmpty)
    }

    func testDeltaStillSkipsAbsentAndGovernedFollowers() {
        let levels = world(levels: [desk: 0.4, side: 0.4], present: [builtIn, desk], governed: [desk])
        let fan = fanOut(of: classify(write(0.6, on: builtIn, from: 0.5, world: levels), group(.delta)))
        XCTAssertTrue(fan.writes.isEmpty)
        XCTAssertEqual(fan.absent, [side])
        XCTAssertEqual(fan.governed, [desk])
    }

    // MARK: - Absolute

    func testAbsoluteCopiesTheLeadersLevelOverUnequalStartingLevels() {
        // The same starting point as the delta test ends somewhere else: that is the difference.
        let levels = world(levels: [builtIn: 0.20, desk: 0.40, side: 0.70])
        let result = classify(write(0.30, on: builtIn, from: 0.20, world: levels), group(.absolute))
        assertWrites(fanOut(of: result), [desk: 0.30, side: 0.30])
    }

    func testAbsoluteIgnoresButKeepsLearnedOffsets() {
        let offsets = group(.absolute, offsets: [desk: 0.2])
        let result = classify(write(0.5, on: builtIn), offsets)
        assertWrites(fanOut(of: result), [desk: 0.5, side: 0.5])
        XCTAssertEqual(result.group.offset(for: desk), 0.2, accuracy: 0.0001, "kept for the offsets mode")
    }

    func testAbsoluteFollowsWhatTheLeaderShows() {
        let result = classify(write(0.05, on: builtIn, applied: 0.15), group(.absolute))
        assertWrites(fanOut(of: result), [desk: 0.15, side: 0.15])
    }

    func testTheOffsetsModeStillReadsTheRequestedValue() {
        // Backward compatibility: an existing group behaves exactly as before.
        let result = classify(write(0.05, on: builtIn, applied: 0.15), group(.offsets, offsets: [desk: 0.1]))
        assertWrites(fanOut(of: result), [desk: 0.15, side: 0.05])
    }

    func testNeitherPlainModeTeachesAnOffset() {
        for mode in [BrightnessSyncMode.absolute, .delta] {
            let synced = group(mode)
            let levels = world(levels: [builtIn: 0.5, desk: 0.6, side: 0.6])
            let led = classify(write(0.6, on: builtIn, from: 0.5, world: levels), synced)
            // A slider move on the follower four seconds later leads instead of re-learning.
            let nudge = classify(write(0.8, on: desk, from: 0.6, at: epoch.addingTimeInterval(4), world: levels),
                                 led.group, state: led.state)
            guard case .leader = nudge.outcome else { return XCTFail("\(mode): \(nudge.outcome)") }
            XCTAssertEqual(nudge.group.offsetByMember, [:], "\(mode)")
            XCTAssertEqual(nudge.state.leaderRecordID, desk)
        }
    }

    func testAGroupTargetSetsEveryMemberToTheLevelInThePlainModes() {
        for mode in [BrightnessSyncMode.absolute, .delta] {
            let fan = Policy.groupWrites(0.4, group: group(mode, offsets: [desk: 0.2]), world: world())
            assertWrites(fan, [builtIn: 0.4, desk: 0.4, side: 0.4])
        }
        let offsets = Policy.groupWrites(0.4, group: group(.offsets, offsets: [desk: 0.2]), world: world())
        assertWrites(offsets, [builtIn: 0.4, desk: 0.6, side: 0.4])
    }

    // MARK: - Shift bypass

    func testABypassedAdjustmentChangesOnlyItsOwnDisplay() {
        for mode in BrightnessSyncMode.allCases {
            let synced = group(mode, offsets: [desk: 0.1])
            let result = classify(write(0.3, on: builtIn, from: 0.5, world: world(levels: [desk: 0.6, side: 0.5]),
                                        bypass: true), synced)
            XCTAssertEqual(result.outcome, .bypassed, "\(mode)")
            XCTAssertEqual(result.group, synced, "the group's policy and offsets are unchanged")
        }
    }

    func testABypassClosesTheCorrectionWindowSoTheNextNudgeLeadsInsteadOfTeaching() {
        let synced = group(.offsets)
        let led = classify(write(0.6, on: builtIn), synced)
        let bypassed = classify(write(0.3, on: builtIn, at: epoch.addingTimeInterval(2), bypass: true),
                                led.group, state: led.state)
        XCTAssertEqual(bypassed.outcome, .bypassed)
        let nudge = classify(write(0.8, on: desk, at: epoch.addingTimeInterval(4)), bypassed.group,
                             state: bypassed.state)
        guard case .leader = nudge.outcome else { return XCTFail("expected a leader, got \(nudge.outcome)") }
        XCTAssertEqual(nudge.group.offset(for: desk), 0, "no offset learned against a level nobody is at")
    }

    func testOurOwnEchoIsStillAnEchoEvenWhenMarkedBypass() {
        var echo = Policy.SyncEcho()
        let token = echo.begin(leader: builtIn, followers: [desk])
        let result = classify(write(0.5, on: desk, bypass: true, token: token), group(.delta), echo: echo)
        XCTAssertEqual(result.outcome, .echo)
    }

    // MARK: - Outside changes

    func testAGroupThatIgnoresOutsideChangesDoesNotFollowAnObservedChange() {
        let ignoring = group(.delta, followsOutsideChanges: false)
        let levels = world(levels: [builtIn: 0.5, desk: 0.5, side: 0.5])
        let observed = classify(write(0.7, on: builtIn, from: 0.5, world: levels, via: .observed), ignoring)
        XCTAssertEqual(observed.outcome, .outsideChangeIgnored)
        // The app's own slider and keys still lead it.
        for origin in [Policy.ManualWrite.Origin.slider, .keys] {
            let led = classify(write(0.7, on: builtIn, from: 0.5, world: levels, via: origin), ignoring)
            assertWrites(fanOut(of: led), [desk: 0.7, side: 0.7])
        }
    }

    func testAGroupThatFollowsOutsideChangesLetsAnObservedChangeLead() {
        let levels = world(levels: [builtIn: 0.5, desk: 0.5, side: 0.5])
        let observed = classify(write(0.7, on: builtIn, from: 0.5, world: levels, via: .observed), group(.delta))
        assertWrites(fanOut(of: observed), [desk: 0.7, side: 0.7])
    }

    // MARK: - Persistence and migration

    /// A group as JSON with the mode keys rewritten: `nil` removes a key — the shape an older build
    /// saved — and a value replaces it.
    private func groupJSON(_ group: DisplayGroup, brightnessMode: Any?, followsOutsideChanges: Any?) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(group)) as? [String: Any])
        object["brightnessMode"] = brightnessMode
        object["followsOutsideChanges"] = followsOutsideChanges
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testAGroupSavedBeforeModesExistedKeepsItsOffsetsBehaviour() throws {
        let saved = group(.delta, offsets: [desk: 0.2], followsOutsideChanges: false)
        let legacy = try groupJSON(saved, brightnessMode: nil, followsOutsideChanges: nil)
        let decoded = try JSONDecoder().decode(DisplayGroup.self, from: legacy)
        XCTAssertEqual(decoded.brightnessMode, .offsets)
        XCTAssertTrue(decoded.followsOutsideChanges)
        XCTAssertEqual(decoded.memberRecordIDs, saved.memberRecordIDs)
        XCTAssertEqual(decoded.offset(for: desk), 0.2, accuracy: 0.0001)
    }

    func testAnUnknownModeFromANewerBuildFallsBackInsteadOfDroppingTheGroup() throws {
        let newer = try groupJSON(group(.delta), brightnessMode: "nits", followsOutsideChanges: "sometimes")
        let decoded = try JSONDecoder().decode(DisplayGroup.self, from: newer)
        XCTAssertEqual(decoded.brightnessMode, .offsets)
        XCTAssertTrue(decoded.followsOutsideChanges)
    }

    func testModeAndOutsideChangeSwitchRoundTrip() throws {
        let original = group(.delta, followsOutsideChanges: false)
        let decoded = try JSONDecoder().decode(DisplayGroup.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testANewNamedGroupStartsOnTheOriginalOffsetsMode() {
        let created = DisplayGroupStore.create(named: "Work", in: [])
        XCTAssertEqual(created?.first?.brightnessMode, .offsets)
    }

    // MARK: - Default group

    func testTheDefaultGroupStartsOffInDeltaMode() {
        let settings = OpenDisplaySettings()
        XCTAssertFalse(settings.defaultDisplayGroup.syncBrightness)
        XCTAssertEqual(settings.defaultDisplayGroup.brightnessMode, .delta)
        XCTAssertTrue(settings.defaultDisplayGroup.isDefaultGroup)
    }

    func testSettingsWithoutADefaultGroupDecodeToTheDefaultOne() throws {
        let decoded = try JSONDecoder().decode(OpenDisplaySettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.defaultDisplayGroup, .defaultGroup)
    }

    func testADecodedDefaultGroupKeepsItsFixedIdentityAndStoresNoMembers() throws {
        var tampered = DisplayGroup.defaultGroup
        tampered.id = UUID()
        tampered.memberRecordIDs = [desk]
        tampered.syncBrightness = true
        var settings = OpenDisplaySettings()
        settings.defaultDisplayGroup = tampered
        let decoded = try JSONDecoder().decode(OpenDisplaySettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.defaultDisplayGroup.id, DisplayGroup.defaultGroupID)
        XCTAssertEqual(decoded.defaultDisplayGroup.memberRecordIDs, [])
        XCTAssertTrue(decoded.defaultDisplayGroup.syncBrightness, "the user's switch survives")
    }

    func testTheDefaultGroupHoldsEveryEligibleDisplayNoNamedGroupClaims() {
        let work = DisplayGroup(name: "Work", memberRecordIDs: [desk])
        let resolved = DisplayGroupStore.resolvedDefaultGroup(.defaultGroup, eligible: [builtIn, desk, side],
                                                              groups: [work])
        XCTAssertEqual(resolved.memberRecordIDs, [builtIn, side])
    }

    func testANamedGroupOutranksTheDefaultGroupEvenWithItsSyncOff() {
        var defaultOn = DisplayGroup.defaultGroup
        defaultOn.syncBrightness = true
        let paused = DisplayGroup(name: "Work", memberRecordIDs: [desk], syncBrightness: false)
        let eligible = [builtIn, desk, side]
        XCTAssertEqual(DisplayGroupStore.syncGroup(containing: desk, in: [paused], defaultGroup: defaultOn,
                                                   eligible: eligible)?.id, paused.id)
        XCTAssertFalse(DisplayGroupStore.isGroupGoverned(desk, in: [paused], defaultGroup: defaultOn,
                                                         eligible: eligible))
        XCTAssertTrue(DisplayGroupStore.isGroupGoverned(side, in: [paused], defaultGroup: defaultOn,
                                                        eligible: eligible))
    }

    func testTheDefaultGroupGovernsNothingWhileOffOrForAnIneligibleDisplay() {
        let eligible = [builtIn, desk]
        XCTAssertFalse(DisplayGroupStore.isGroupGoverned(builtIn, in: [], defaultGroup: .defaultGroup,
                                                         eligible: eligible))
        var defaultOn = DisplayGroup.defaultGroup
        defaultOn.syncBrightness = true
        XCTAssertTrue(DisplayGroupStore.isGroupGoverned(builtIn, in: [], defaultGroup: defaultOn, eligible: eligible))
        XCTAssertNil(DisplayGroupStore.syncGroup(containing: virtualScreen, in: [], defaultGroup: defaultOn,
                                                 eligible: eligible))
    }

    func testADefaultGroupOfOneGovernsNothing() {
        // A lone external in clamshell, say: nothing to sync with, so Adaptive Display keeps it.
        var defaultOn = DisplayGroup.defaultGroup
        defaultOn.syncBrightness = true
        XCTAssertNil(DisplayGroupStore.syncGroup(containing: desk, in: [], defaultGroup: defaultOn, eligible: [desk]))
        XCTAssertFalse(DisplayGroupStore.isGroupGoverned(desk, in: [], defaultGroup: defaultOn, eligible: [desk]))
        // Nor when the only other eligible display belongs to a named group.
        let work = DisplayGroup(name: "Work", memberRecordIDs: [builtIn])
        XCTAssertFalse(DisplayGroupStore.isGroupGoverned(desk, in: [work], defaultGroup: defaultOn,
                                                         eligible: [builtIn, desk]))
    }

    func testADecodedDefaultGroupNeverEndsUpOnTheOffsetsModeItDoesNotOffer() throws {
        var settings = OpenDisplaySettings()
        settings.defaultDisplayGroup.brightnessMode = .offsets
        let decoded = try JSONDecoder().decode(OpenDisplaySettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.defaultDisplayGroup.brightnessMode, .delta)
        settings.defaultDisplayGroup.brightnessMode = .absolute
        let absolute = try JSONDecoder().decode(OpenDisplaySettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(absolute.defaultDisplayGroup.brightnessMode, .absolute)
    }

    func testTheMonitorBaselineIsWhatAnObservedDeltaIsMeasuredFrom() {
        var monitor = BrightnessMonitor()
        XCTAssertNil(monitor.baseline)
        XCTAssertFalse(monitor.observe(0.40, revision: monitor.revision), "the first read only seeds")
        XCTAssertEqual(monitor.baseline, 0.40)
        let previous = monitor.baseline
        XCTAssertTrue(monitor.observe(0.55, revision: monitor.revision))
        XCTAssertEqual(previous, 0.40, "read before observe: the level the change started from")
        XCTAssertEqual(monitor.baseline, 0.55)
        monitor.beginWrite()
        monitor.endWrite(value: 0.70)
        XCTAssertEqual(monitor.baseline, 0.70, "the app's own write moves the baseline with it")
    }

    func testTheDefaultGroupFansADeltaOutToItsLiveMembers() {
        var defaultOn = DisplayGroup.defaultGroup
        defaultOn.syncBrightness = true
        let resolved = DisplayGroupStore.resolvedDefaultGroup(defaultOn, eligible: [builtIn, desk, side],
                                                              groups: [DisplayGroup(name: "Work", memberRecordIDs: [side])])
        let levels = world(levels: [builtIn: 0.5, desk: 0.3, side: 0.9])
        let result = classify(write(0.6, on: builtIn, from: 0.5, world: levels), resolved)
        assertWrites(fanOut(of: result), [desk: 0.4])  // side belongs to Work, not the default group
    }
}
