import XCTest
import DisplayDomain
@testable import TopologyCore

/// AM-11 / SO-23 / FA-12 / FA-13 / FA-14 / SD-11: tray contents, per-display presentation, ordering
/// and expansion policies.
final class MenuLayoutTests: XCTestCase {
    private let desk = DisplayRecordID.forCGUUID("DESK")
    private let laptop = DisplayRecordID.forCGUUID("LAPTOP")

    // MARK: - Contents registry

    /// The defaults are the tray as it was before it could be customized.
    func testDefaultsMatchTheFixedLayout() {
        let layout = MenuLayoutSettings()
        for family in MenuItemFamily.families(in: .slider) { XCTAssertEqual(layout.placement(of: family), .visible) }
        for family in MenuItemFamily.families(in: .displayFeature) { XCTAssertEqual(layout.placement(of: family), .expanded) }
        for family in MenuItemFamily.families(in: .tool) { XCTAssertEqual(layout.placement(of: family), .visible) }
        XCTAssertTrue(layout.hasDefaultContents)
        XCTAssertEqual(MenuItemFamily.displayMode.trayID, "mode")
        XCTAssertEqual(MenuItemFamily.monitorColorPreset.trayID, "colorMode")
    }

    func testEveryFamilyIsStoredIndependentlyAndDefaultsDropTheOverride() {
        var layout = MenuLayoutSettings()
        layout.setPlacement(.hidden, for: .resolution)
        layout.setPlacement(.visible, for: .rotation)
        XCTAssertEqual(layout.placement(of: .resolution), .hidden)
        XCTAssertEqual(layout.placement(of: .displayMode), .expanded, "hiding Resolution leaves Display mode alone")
        XCTAssertEqual(layout.placement(of: .rotation), .visible)
        layout.setPlacement(.expanded, for: .rotation)
        XCTAssertNil(layout.placements[MenuItemFamily.rotation.rawValue])
        XCTAssertFalse(layout.hasDefaultContents)
    }

    /// A tool has no «More» level; asking for it (or finding it in a file) falls back to the default.
    func testToolsAcceptOnlyVisibleOrHidden() {
        var layout = MenuLayoutSettings()
        layout.setPlacement(.expanded, for: .scenes)
        XCTAssertEqual(layout.placement(of: .scenes), .visible)
        layout.placements[MenuItemFamily.scenes.rawValue] = .expanded
        XCTAssertEqual(layout.placement(of: .scenes), .visible)
        layout.setPlacement(.hidden, for: .scenes)
        XCTAssertEqual(layout.placement(of: .scenes), .hidden)
    }

    /// Reset Menu Layout restores contents only: names, icons, visibility, order and the behaviour
    /// switches are other choices.
    func testResetMenuContentsKeepsEverythingElse() {
        var layout = MenuLayoutSettings(rememberExpandedSections: true, mainDisplayFirst: true, animateMenu: false)
        layout.setPlacement(.hidden, for: .brightness)
        layout.setPlacement(.hidden, for: .updates)
        layout.setHidden(true, for: [desk])
        layout.setIconSymbol("tv", for: [laptop])
        layout.displayOrder = [laptop.rawValue, desk.rawValue]

        let reset = layout.resettingMenuContents()
        XCTAssertTrue(reset.hasDefaultContents)
        XCTAssertTrue(reset.isHidden(desk))
        XCTAssertEqual(reset.iconSymbol(for: laptop), "tv")
        XCTAssertEqual(reset.displayOrder, layout.displayOrder)
        XCTAssertTrue(reset.rememberExpandedSections)
        XCTAssertTrue(reset.mainDisplayFirst)
        XCTAssertFalse(reset.animateMenu)
    }

    // MARK: - Per-display presentation

    func testIconSymbolIsTrimmedAndBlankClearsIt() {
        var layout = MenuLayoutSettings()
        layout.setIconSymbol("  tv  ", for: [desk])
        XCTAssertEqual(layout.iconSymbol(for: desk), "tv")
        layout.setIconSymbol("   ", for: [desk])
        XCTAssertNil(layout.iconSymbol(for: desk))
        XCTAssertNil(layout.displays[desk.rawValue], "a default entry isn't stored")
    }

    /// A hidden display OpenDisplay switched off still shows its card: it's the way back on.
    func testHiddenDisplaysLeaveTheTrayExceptWhileTurnedOff() {
        var layout = MenuLayoutSettings()
        layout.setHidden(true, for: [desk])
        XCTAssertFalse(layout.showsInTray(desk, turnedOffByApp: false))
        XCTAssertTrue(layout.showsInTray(desk, turnedOffByApp: true))
        XCTAssertTrue(layout.showsInTray(laptop, turnedOffByApp: false))
    }

    func testRoundTripAndTolerantDecoding() throws {
        var layout = MenuLayoutSettings(oneFeatureAtATime: true, showSliderNames: true)
        layout.setPlacement(.hidden, for: .volume)
        layout.setHidden(true, for: [desk])
        layout.displayOrder = [desk.rawValue]
        let decoded = try JSONDecoder().decode(MenuLayoutSettings.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(decoded, layout)

        // An unknown placement, an unknown family and a reshaped key degrade alone.
        let json = """
        {"placements": {"slider.volume": "floating", "slider.brightness": "hidden", "tool.someday": "hidden"},
         "displayOrder": "not-a-list", "animateMenu": false,
         "displays": {"cg:DESK": {"hidden": true, "future": 1}}}
        """
        let tolerant = try JSONDecoder().decode(MenuLayoutSettings.self, from: Data(json.utf8))
        XCTAssertEqual(tolerant.placement(of: .volume), .visible)
        XCTAssertEqual(tolerant.placement(of: .brightness), .hidden)
        XCTAssertEqual(tolerant.displayOrder, [])
        XCTAssertFalse(tolerant.animateMenu)
        XCTAssertTrue(tolerant.showSliderValues)
        XCTAssertTrue(tolerant.isHidden(desk))
    }

    func testStoreRoundTripsAndDegradesToDefault() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MenuLayoutStore(directory: directory)
        XCTAssertEqual(store.load(), .default)
        var layout = MenuLayoutSettings(mainDisplayFirst: true)
        layout.setPlacement(.visible, for: .displayMode)
        try store.save(layout)
        XCTAssertEqual(store.load(), layout)
        try Data("garbage".utf8).write(to: directory.appendingPathComponent("menu-layout.json"))
        XCTAssertEqual(store.load(), .default)
    }

    // MARK: - Ordering

    private func candidate(_ id: String, _ name: String, main: Bool = false, builtIn: Bool = false,
                           keys: [String]? = nil) -> MenuDisplayOrder.Candidate {
        .init(id: id, orderKeys: keys, name: name, isMain: main, isBuiltIn: builtIn)
    }

    private func order(_ candidates: [MenuDisplayOrder.Candidate], manual: [String] = [],
                       mainFirst: Bool = false) -> [String] {
        MenuDisplayOrder.sorted(candidates, manualOrder: manual, mainFirst: mainFirst).map(\.id)
    }

    func testAutomaticOrderIsBuiltInThenNameThenID() {
        let displays = [candidate("c", "dell 2"), candidate("b", "Dell 10"), candidate("a", "Dell 2"),
                        candidate("z", "Zeta"), candidate("l", "Built-in", builtIn: true)]
        // Numbers compare numerically; equal names (case-insensitive) fall back to the id.
        XCTAssertEqual(order(displays), ["l", "a", "c", "b", "z"])
        XCTAssertEqual(order(displays.reversed()), ["l", "a", "c", "b", "z"], "input order never matters")
    }

    func testManualOrderComesFirstAndUnlistedDisplaysFollowAutomatically() {
        let displays = [candidate("a", "Alpha"), candidate("b", "Beta"), candidate("c", "Gamma"),
                        candidate("l", "Built-in", builtIn: true)]
        XCTAssertEqual(order(displays, manual: ["c", "a", "gone"]), ["c", "a", "l", "b"])
    }

    func testRenamingDoesNotMoveAManuallyPlacedDisplay() {
        let before = [candidate("a", "Alpha"), candidate("b", "Beta")]
        let after = [candidate("a", "Zulu"), candidate("b", "Beta")]
        XCTAssertEqual(order(before, manual: ["a", "b"]), ["a", "b"])
        XCTAssertEqual(order(after, manual: ["a", "b"]), ["a", "b"])
        XCTAssertEqual(order(after), ["b", "a"], "without a manual order the name decides")
    }

    func testMainDisplayFirstWinsOverTheManualOrder() {
        let displays = [candidate("a", "Alpha"), candidate("b", "Beta", main: true)]
        XCTAssertEqual(order(displays, manual: ["a", "b"]), ["a", "b"])
        XCTAssertEqual(order(displays, manual: ["a", "b"], mainFirst: true), ["b", "a"])
    }

    /// A display known under two UUIDs takes the best place any of them has.
    func testCandidateWithSeveralKeysUsesItsBestRank() {
        let displays = [candidate("x", "X"), candidate("desk", "Desk", keys: ["cg:1", "cg:2"])]
        XCTAssertEqual(order(displays, manual: ["cg:2", "x"]), ["desk", "x"])
    }

    func testMovingPinsTheWholeSequence() {
        let sequence = [candidate("a", "A"), candidate("b", "B", keys: ["b1", "b2"]), candidate("c", "C")]
        let moved = MenuDisplayOrder.moving(sequence, from: 2, to: 0)
        XCTAssertEqual(moved.map(\.id), ["c", "a", "b"])
        XCTAssertEqual(MenuDisplayOrder.manualOrder(pinning: moved), ["c", "a", "b1", "b2"])
        XCTAssertEqual(MenuDisplayOrder.moving(sequence, from: 0, to: 99).map(\.id), ["b", "c", "a"])
        XCTAssertEqual(MenuDisplayOrder.moving(sequence, from: 5, to: 0).map(\.id), ["a", "b", "c"])
        // The pinned order reproduces the moved sequence whatever the names say.
        XCTAssertEqual(order(sequence, manual: MenuDisplayOrder.manualOrder(pinning: moved)), ["c", "a", "b"])
    }

    // MARK: - Expansion

    func testMoreSectionsOneAtATimeClosesOnlyOtherMoreSections() {
        XCTAssertEqual(MenuExpansionPolicy.togglingMore(["a"], device: "b", oneAtATime: false), ["a", "b"])
        XCTAssertEqual(MenuExpansionPolicy.togglingMore(["a"], device: "b", oneAtATime: true), ["b"])
        XCTAssertEqual(MenuExpansionPolicy.togglingMore(["a", "b"], device: "b", oneAtATime: true), ["a"])
    }

    func testOneFeatureAtATimeIsPerDisplay() {
        let open: Set<String> = ["a|mode", "a|rotation", "b|mode"]
        XCTAssertEqual(MenuExpansionPolicy.togglingFeature(open, feature: "a|pip", oneAtATime: true),
                       ["a|pip", "b|mode"])
        XCTAssertEqual(MenuExpansionPolicy.togglingFeature(open, feature: "a|pip", oneAtATime: false),
                       ["a|mode", "a|rotation", "a|pip", "b|mode"])
        XCTAssertEqual(MenuExpansionPolicy.togglingFeature(open, feature: "a|mode", oneAtATime: true),
                       ["a|rotation", "b|mode"], "closing never opens anything")
    }

    func testForgettingDevicesDropsTheirSectionsAndFeatures() {
        let entries: Set<String> = ["cg:A", "cg:A|mode", "cg:B", "cg:B|pip"]
        XCTAssertEqual(MenuExpansionPolicy.forgetting(entries, devices: ["cg:A"]), ["cg:B", "cg:B|pip"])
    }
}
