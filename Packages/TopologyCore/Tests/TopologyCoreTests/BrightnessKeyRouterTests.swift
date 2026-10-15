import XCTest
@testable import DisplayDomain
@testable import TopologyCore

/// SO-27 / FA-19 / T27: which displays a brightness key changes — pointer, focused window, all,
/// main, built-in and external modes; modifier scopes; mirror sets; keyboard exclusions; group
/// deduplication; and no fallback to an unrelated screen.
final class BrightnessKeyRouterTests: XCTestCase {
    private func obs(
        _ id: String, active: Bool = true, main: Bool = false, builtIn: Bool = false,
        x: Int = 0, y: Int = 0, w: Int = 1920, h: Int = 1080, mirrors: String? = nil,
        presence: PhysicalPresence? = nil
    ) -> DisplayObservation {
        DisplayObservation(
            recordID: DisplayRecordID(rawValue: id),
            isActive: active,
            origin: DisplayOrigin(x: x, y: y),
            mode: DisplayMode(pixelWidth: w, pixelHeight: h, pointWidth: w, pointHeight: h,
                              refreshHz: 60, isHiDPI: false),
            isMain: main,
            mirrorSourceID: mirrors.map(DisplayRecordID.init(rawValue:)),
            displayClass: builtIn ? .builtIn : .external,
            physicalPresence: presence,
            generation: .initial
        )
    }

    private func candidate(_ observation: DisplayObservation, keyboard: Bool = true, controllable: Bool = true,
                           macOS: Bool = false, group: UUID? = nil) -> BrightnessKeyRouter.Candidate {
        .init(observation: observation, keyboardEnabled: keyboard, controllable: controllable,
              macOSControllable: macOS, syncGroup: group)
    }

    private func decide(_ candidates: [BrightnessKeyRouter.Candidate], mode: MediaKeyTargetMode,
                        intent: NativeKeyIntent = .plain, pointer: DisplayOrigin? = nil,
                        focused: String? = nil,
                        takeover: BrightnessKeyTakeover = .anyControllableDisplay) -> BrightnessKeyRouter.Decision {
        BrightnessKeyRouter.decide(intent: intent, candidates: candidates,
                                   context: .init(mode: mode, takeover: takeover, pointer: pointer,
                                                  focusedDisplay: focused.map(DisplayRecordID.init(rawValue:))))
    }

    private func ids(_ decision: BrightnessKeyRouter.Decision) -> [String] {
        decision.targets.map(\.display.rawValue)
    }

    // MARK: - Pointer

    func testUnderCursorPicksDisplayContainingPoint() {
        let decision = decide([candidate(obs("builtin", main: true, builtIn: true)), candidate(obs("ext", x: 1920))],
                              mode: .underCursor, pointer: DisplayOrigin(x: 2000, y: 100))
        XCTAssertEqual(ids(decision), ["ext"])
        XCTAssertEqual(decision.targets.first?.bypassesSync, false)
    }

    func testPointerOutsideEveryDisplayChangesNothingInsteadOfFallingBackToMain() {
        let decision = decide([candidate(obs("builtin", main: true, builtIn: true)), candidate(obs("ext", x: 1920))],
                              mode: .underCursor, pointer: DisplayOrigin(x: 99999, y: 99999))
        XCTAssertEqual(decision, .passThrough(.noTarget))
    }

    func testPointerOnTheFarEdgeStillBelongsToThatDisplay() {
        // NSEvent's flipped bottom row lands exactly on the height — outside the half-open bounds.
        let decision = decide([candidate(obs("only", main: true))], mode: .underCursor,
                              pointer: DisplayOrigin(x: 100, y: 1080))
        XCTAssertEqual(ids(decision), ["only"])
    }

    func testPointerOnAKeyboardExcludedDisplayChangesNothing() {
        let decision = decide([candidate(obs("builtin", main: true, builtIn: true)),
                               candidate(obs("ext", x: 1920), keyboard: false)],
                              mode: .underCursor, pointer: DisplayOrigin(x: 2000, y: 100))
        XCTAssertEqual(decision, .passThrough(.noTarget))
    }

    func testPointerOnAMirrorSetChangesEveryMemberOnce() {
        let source = obs("source", main: true)
        let target = obs("target", mirrors: "source")
        let other = obs("other", x: 1920)
        let decision = decide([candidate(target), candidate(source), candidate(other)], mode: .underCursor,
                              pointer: DisplayOrigin(x: 10, y: 10))
        XCTAssertEqual(ids(decision), ["source", "target"])
    }

    func testAMirrorMemberWithoutAVisibleRouteIsLeftOut() {
        // An overlay-only software route draws nothing a mirror member shows.
        let decision = decide([candidate(obs("source", main: true)),
                               candidate(obs("target", mirrors: "source"), controllable: false)],
                              mode: .underCursor, pointer: DisplayOrigin(x: 10, y: 10))
        XCTAssertEqual(ids(decision), ["source"])
    }

    // MARK: - Focused window

    func testFocusedWindowModeUsesTheFocusedDisplayIgnoringThePointer() {
        let decision = decide([candidate(obs("builtin", main: true, builtIn: true)), candidate(obs("ext", x: 1920))],
                              mode: .focusedWindow, pointer: DisplayOrigin(x: 10, y: 10), focused: "ext")
        XCTAssertEqual(ids(decision), ["ext"])
    }

    func testFocusedWindowModeWithoutAFocusedDisplayChangesNothing() {
        let decision = decide([candidate(obs("builtin", main: true, builtIn: true))], mode: .focusedWindow,
                              pointer: DisplayOrigin(x: 10, y: 10), focused: nil)
        XCTAssertEqual(decision, .passThrough(.noTarget))
    }

    func testFocusedWindowScreenIsTheDisplayHoldingMostOfTheWindow() {
        let left = obs("left")
        let right = obs("right", x: 1920)
        let window = FocusedWindowScreen.Bounds(x: 1500, y: 100, width: 1000, height: 500)  // 420 left, 580 right
        XCTAssertEqual(FocusedWindowScreen.display(for: window, in: [left, right])?.rawValue, "right")
        let offscreen = FocusedWindowScreen.Bounds(x: -5000, y: -5000, width: 100, height: 100)
        XCTAssertNil(FocusedWindowScreen.display(for: offscreen, in: [left, right]))
    }

    // MARK: - All displays

    func testAllModeWritesEveryEligibleDisplayDirectly() {
        let group = UUID()
        let decision = decide([candidate(obs("a", main: true), group: group),
                               candidate(obs("b", x: 1920), group: group),
                               candidate(obs("c", x: 3840), keyboard: false)],
                              mode: .allDisplays, pointer: DisplayOrigin(x: 10, y: 10))
        XCTAssertEqual(ids(decision), ["a", "b"])
        XCTAssertTrue(decision.targets.allSatisfy(\.bypassesSync), "all-screen mode bypasses group sync")
    }

    func testShiftNarrowsAllModeToThePointerAndItsMirrors() {
        let decision = decide([candidate(obs("a", main: true)), candidate(obs("a2", mirrors: "a")),
                               candidate(obs("b", x: 1920))],
                              mode: .allDisplays, intent: NativeKeyIntent(bypassesSync: true),
                              pointer: DisplayOrigin(x: 2000, y: 10))
        XCTAssertEqual(ids(decision), ["b"])
        XCTAssertTrue(decision.targets.allSatisfy(\.bypassesSync))
    }

    func testAllModeOutranksTheBuiltInAndExternalChords() {
        let candidates = [candidate(obs("builtin", main: true, builtIn: true)), candidate(obs("ext", x: 1920))]
        XCTAssertEqual(ids(decide(candidates, mode: .allDisplays, intent: NativeKeyIntent(scope: .builtIn))),
                       ["builtin", "ext"])
    }

    // MARK: - Groups

    func testOneMemberPerSyncGroupWhenSyncIsNotBypassed() {
        let group = UUID()
        let decision = decide([candidate(obs("source", main: true), group: group),
                               candidate(obs("target", mirrors: "source"), group: group)],
                              mode: .underCursor, pointer: DisplayOrigin(x: 10, y: 10))
        XCTAssertEqual(ids(decision), ["source"], "the group carries the change to its other member")
    }

    func testShiftWritesEachGroupMemberDirectly() {
        let group = UUID()
        let decision = decide([candidate(obs("source", main: true), group: group),
                               candidate(obs("target", mirrors: "source"), group: group)],
                              mode: .underCursor, intent: NativeKeyIntent(bypassesSync: true),
                              pointer: DisplayOrigin(x: 10, y: 10))
        XCTAssertEqual(ids(decision), ["source", "target"])
        XCTAssertTrue(decision.targets.allSatisfy(\.bypassesSync))
    }

    // MARK: - Main / built-in / external modes

    func testMainDisplayModeAlwaysPicksMain() {
        let decision = decide([candidate(obs("builtin", builtIn: true)), candidate(obs("ext", main: true, x: 1920))],
                              mode: .mainDisplay, pointer: DisplayOrigin(x: 100, y: 100))
        XCTAssertEqual(ids(decision), ["ext"])
    }

    func testBuiltInModeWithoutABuiltInChangesNothing() {
        // Clamshell: the built-in isn't active. No fallback to the (unrelated) main external.
        let decision = decide([candidate(obs("builtin", active: false, builtIn: true)),
                               candidate(obs("ext", main: true, x: 1920))], mode: .builtInAlways)
        XCTAssertEqual(decision, .passThrough(.noTarget))
        XCTAssertEqual(ids(decide([candidate(obs("builtin", builtIn: true)), candidate(obs("ext", main: true, x: 1920))],
                                  mode: .builtInAlways)), ["builtin"])
    }

    func testExternalOnlyNeverFallsBackToBuiltIn() {
        let builtIn = candidate(obs("builtin", main: true, builtIn: true))
        XCTAssertEqual(ids(decide([builtIn, candidate(obs("external", x: 1920))], mode: .externalOnly,
                                  pointer: DisplayOrigin(x: 100, y: 100))), ["external"])
        XCTAssertEqual(decide([builtIn], mode: .externalOnly), .passThrough(.noTarget))
    }

    func testInactiveAndEmptyChangeNothing() {
        XCTAssertEqual(decide([], mode: .mainDisplay), .passThrough(.noTarget))
        XCTAssertEqual(decide([candidate(obs("off", active: false, main: true))], mode: .mainDisplay),
                       .passThrough(.noTarget))
    }

    // MARK: - Modifier scopes

    func testControlSelectsTheBuiltIn() {
        let decision = decide([candidate(obs("builtin", builtIn: true)), candidate(obs("ext", main: true, x: 1920))],
                              mode: .underCursor, intent: NativeKeyIntent(scope: .builtIn),
                              pointer: DisplayOrigin(x: 2000, y: 10))
        XCTAssertEqual(ids(decision), ["builtin"])
    }

    func testControlCommandSelectsExternalsButNotOpenDisplaysVirtualScreens() {
        let decision = decide([candidate(obs("builtin", main: true, builtIn: true)),
                               candidate(obs("ext", x: 1920, presence: .physical)),
                               candidate(obs("virtual", x: 3840, presence: .virtual))],
                              mode: .underCursor, intent: NativeKeyIntent(scope: .externals))
        XCTAssertEqual(ids(decision), ["ext"])
    }

    func testShiftCommandSelectsOtherScreensIncludingKeyboardExcludedOnes() {
        let decision = decide([candidate(obs("a", main: true)), candidate(obs("a2", mirrors: "a")),
                               candidate(obs("b", x: 1920), keyboard: false), candidate(obs("c", x: 3840))],
                              mode: .underCursor, intent: NativeKeyIntent(scope: .otherScreens, bypassesSync: true),
                              pointer: DisplayOrigin(x: 10, y: 10))
        XCTAssertEqual(ids(decision), ["b", "c"])
    }

    // MARK: - Takeover

    func testOnlyWhenMacOSCannotLeavesAppleNativeDisplaysToMacOS() {
        let builtIn = candidate(obs("builtin", main: true, builtIn: true), macOS: true)
        let ext = candidate(obs("ext", x: 1920))
        XCTAssertEqual(decide([builtIn, ext], mode: .underCursor, pointer: DisplayOrigin(x: 10, y: 10),
                              takeover: .onlyWhenMacOSCannot), .passThrough(.macOSHandles))
        XCTAssertEqual(ids(decide([builtIn, ext], mode: .underCursor, pointer: DisplayOrigin(x: 2000, y: 10),
                                  takeover: .onlyWhenMacOSCannot)), ["ext"])
        XCTAssertEqual(ids(decide([builtIn, ext], mode: .underCursor, pointer: DisplayOrigin(x: 10, y: 10))),
                       ["builtin"], "the default takes over any controllable display")
    }

    // MARK: - Mirror set helper

    func testMirrorSetListsTheSourceFirstFromAnyMember() {
        let displays = [obs("t1", mirrors: "s"), obs("s"), obs("t2", mirrors: "s"), obs("x", x: 1920)]
        XCTAssertEqual(DisplayRelationships.mirrorSet(of: DisplayRecordID(rawValue: "t2"), in: displays).map(\.rawValue),
                       ["s", "t1", "t2"])
        XCTAssertEqual(DisplayRelationships.mirrorSet(of: DisplayRecordID(rawValue: "x"), in: displays).map(\.rawValue),
                       ["x"])
    }
    func testGroupFanoutCannotReintroduceKeyboardExcludedOrUnavailableDisplays() {
        let source = obs("source", main: true)
        let excluded = obs("excluded", x: 1920)
        let invisible = obs("invisible", mirrors: "source")
        let allowed = obs("allowed", x: 3840)
        let candidates = [candidate(source), candidate(excluded, keyboard: false),
                          candidate(invisible, controllable: false), candidate(allowed)]
        let eligible = BrightnessKeyRouter.syncEligibleDisplays(candidates)
        XCTAssertEqual(eligible, [source.recordID, allowed.recordID])
        let group = DisplayGroup(name: "Desk", memberRecordIDs: candidates.map(\.id), brightnessMode: .absolute)
        let write = GroupSyncPolicy.ManualWrite(value: 0.4, display: source.recordID, now: Date(),
                                                world: .init(present: eligible))
        let result = GroupSyncPolicy.classify(write, group: group, state: .init(), echo: .init())
        guard case .leader(let fanout) = result.outcome else { return XCTFail("expected a group leader") }
        XCTAssertEqual(fanout.writes.map(\.member), [allowed.recordID])
    }

    func testExplicitStreamsExpandMirrorSetsAndTerminateCyclesWithoutDuplicates() {
        let source = obs("source", main: true)
        let mirror = obs("mirror", mirrors: "source")
        let target = obs("target", x: 1920)
        let off = obs("off", active: false)
        let edges: [DisplayRelationships.StreamTarget] = [
            .init(source: source.recordID, target: target.recordID),
            .init(source: mirror.recordID, target: target.recordID),
            .init(source: target.recordID, target: source.recordID),
            .init(source: target.recordID, target: off.recordID)]
        XCTAssertEqual(DisplayRelationships.controlSet(of: source.recordID, in: [source, mirror, target, off], streams: edges),
                       [source.recordID, mirror.recordID, target.recordID])
        let decision = BrightnessKeyRouter.decide(
            intent: .plain, candidates: [candidate(source), candidate(mirror), candidate(target), candidate(off)],
            context: .init(mode: .focusedWindow, focusedDisplay: source.recordID, streamTargets: edges))
        XCTAssertEqual(Set(decision.targets.map(\.display)), [source.recordID, mirror.recordID, target.recordID])
    }

    func testStreamSelectionRespectsEligibilityAndDirection() {
        let source = obs("source", main: true)
        let target = obs("target", x: 1920)
        let edge = DisplayRelationships.StreamTarget(source: source.recordID, target: target.recordID)
        XCTAssertEqual(DisplayRelationships.controlSet(of: target.recordID, in: [source, target], streams: [edge]),
                       [target.recordID], "a target does not silently reach back to its source")
        let decision = BrightnessKeyRouter.decide(
            intent: .plain, candidates: [candidate(source), candidate(target, keyboard: false)],
            context: .init(mode: .underCursor, pointer: .init(x: 10, y: 10), streamTargets: [edge]))
        XCTAssertEqual(ids(decision), ["source"])
    }

    func testOtherScreensChordWithoutAPointerCannotSelectEveryScreen() {
        XCTAssertEqual(decide([candidate(obs("a", main: true)), candidate(obs("b", x: 1920))],
                              mode: .underCursor, intent: .init(scope: .otherScreens, bypassesSync: true)),
                       .passThrough(.noTarget))
    }

}
