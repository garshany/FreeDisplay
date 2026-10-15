import DisplayDomain
import XCTest
@testable import AutomationSchema

final class AutomationSelectorTests: XCTestCase {
    private func candidate(_ id: String, name: String, registry: String? = nil, cg: UInt32? = nil,
                           alias: String? = nil, tags: Set<String> = [], groups: Set<String> = [],
                           availability: AutomationDisplayCandidate.Availability = .active,
                           reachability: Reachability? = nil, main: Bool = false, builtIn: Bool = false,
                           vendor: Int? = nil, product: Int? = nil, serial: String? = nil,
                           pointer: Bool? = nil) -> AutomationDisplayCandidate {
        AutomationDisplayCandidate(id: DisplayRecordID(rawValue: id),
                                   registryID: registry.map(DisplayRecordID.init(rawValue:)), cgDisplayID: cg,
                                   name: name, alias: alias, tags: tags, groups: groups, availability: availability,
                                   reachability: reachability, isMain: main, isBuiltIn: builtIn, vendorID: vendor,
                                   productID: product, serial: serial, containsPointer: pointer)
    }

    private lazy var set = AutomationDisplaySet(candidates: [
        candidate("cg:A", name: "Built-in Retina Display", registry: "disp_a", cg: 1, builtIn: true, pointer: false),
        candidate("cg:B", name: "Dell U2720Q", registry: "disp_b", cg: 2, alias: "Desk", tags: ["studio"],
                  groups: ["Work"], main: true, vendor: 4268, product: 41_234, serial: "XYZ", pointer: true),
        candidate("cg:C", name: "Dell U2720Q", cg: 3, tags: ["studio"], groups: ["Work"], pointer: false),
        candidate("cg:D", name: "Écran Projecteur", cg: 4, availability: .inactive, pointer: false),
        candidate("cg:E", name: "LG TV", cg: 9, availability: .disconnected, reachability: .managedOffline),
    ], knownGroups: ["Work", "Empty"], topologyGeneration: 7)

    private func ids(_ text: String) throws -> [String] {
        try AutomationSelectorResolver.resolve(AutomationSelector.parse(text), text: text, in: set).map(\.id.rawValue)
    }

    private func issue(_ text: String) -> AutomationIssue? {
        do {
            _ = try AutomationSelectorResolver.resolveOne(AutomationSelector.parse(text), text: text, in: set)
            return nil
        } catch {
            return error
        }
    }

    // MARK: Parsing

    func testParsesEveryForm() throws {
        XCTAssertEqual(try AutomationSelector.parse("7"), .cgDisplayID(7))
        XCTAssertEqual(try AutomationSelector.parse("cgid:7"), .cgDisplayID(7))
        XCTAssertEqual(try AutomationSelector.parse("group:Work"), .group("Work"))
        XCTAssertEqual(try AutomationSelector.parse("GROUP:\"My Desk\""), .group("My Desk"))
        XCTAssertEqual(try AutomationSelector.parse("nameLike:dell"), .nameContains("dell"))
        XCTAssertEqual(try AutomationSelector.parse("alias:Desk"), .display(.alias("Desk")))
        XCTAssertEqual(try AutomationSelector.parse("name:\"Studio Display\""), .display(.name("Studio Display")))
        XCTAssertEqual(try AutomationSelector.parse("main"), .display(.role(.main)))
        XCTAssertEqual(try AutomationSelector.parse("built-in"), .display(.role(.builtin)))
        XCTAssertEqual(try AutomationSelector.parse("state:managedOffline"), .display(.state(.managedOffline)))
        XCTAssertEqual(try AutomationSelector.parse("id:disp_b"), .display(.id(DisplayRecordID(rawValue: "disp_b"))))
        // Bare text is a display's exact name — the form links and people write.
        XCTAssertEqual(try AutomationSelector.parse("Studio Display"), .display(.name("Studio Display")))
        XCTAssertEqual(try AutomationSelector.parse("\"Studio Display\""), .display(.name("Studio Display")))
    }

    func testMalformedSelectorsAreUsageErrors() {
        for text in ["", "  ", "cgid:x", "cgid:-1", "99999999999", "group:", "nameLike:", "id:", "bogus:thing",
                     "state:nowhere"] {
            XCTAssertThrowsError(try AutomationSelector.parse(text), "'\(text)'") { error in
                XCTAssertEqual((error as? AutomationIssue)?.code, .invalidSelector, "'\(text)'")
                XCTAssertEqual((error as? AutomationIssue)?.category, .usage)
            }
        }
    }

    func testSetSelectorsAreFlagged() throws {
        XCTAssertTrue(try AutomationSelector.parse("tag:x").isSetSelector)
        XCTAssertTrue(try AutomationSelector.parse("group:x").isSetSelector)
        XCTAssertTrue(try AutomationSelector.parse("nameLike:x").isSetSelector)
        XCTAssertFalse(try AutomationSelector.parse("alias:x").isSetSelector)
        XCTAssertFalse(try AutomationSelector.parse("3").isSetSelector)
    }

    // MARK: Matching rules

    func testIdentityMatches() throws {
        XCTAssertEqual(try ids("id:cg:B"), ["cg:B"])
        XCTAssertEqual(try ids("id:disp_b"), ["cg:B"], "the registry record id reaches the same display")
        XCTAssertEqual(try ids("alias:Desk"), ["cg:B"])
        XCTAssertEqual(try ids("2"), ["cg:B"])
        XCTAssertEqual(try ids("cgid:9"), ["cg:E"], "a turned-off display stays addressable by its number")
        XCTAssertEqual(try ids("vendor:4268 product:41234"), ["cg:B"])
        XCTAssertEqual(try ids("serial:XYZ"), ["cg:B"])
    }

    func testNamesMatchIgnoringCaseAndDiacritics() throws {
        XCTAssertEqual(try ids("name:\"ecran projecteur\""), ["cg:D"])
        XCTAssertEqual(try ids("ÉCRAN PROJECTEUR"), ["cg:D"])
        XCTAssertEqual(try ids("name:desk"), ["cg:B"], "an alias is a name too")
        XCTAssertEqual(try ids("nameLike:retina"), ["cg:A"])
        XCTAssertEqual(try ids("nameLike:dell"), ["cg:B", "cg:C"])
    }

    func testRolesStatesAndGroups() throws {
        XCTAssertEqual(try ids("main"), ["cg:B"])
        XCTAssertEqual(try ids("builtin"), ["cg:A"])
        XCTAssertEqual(try ids("pointer"), ["cg:B"])
        XCTAssertEqual(try ids("state:managedOffline"), ["cg:E"])
        XCTAssertEqual(try ids("state:discoveredInactive"), ["cg:D"])
        XCTAssertEqual(try ids("group:work"), ["cg:B", "cg:C"], "group names are case-insensitive")
        XCTAssertEqual(try ids("tag:studio"), ["cg:B", "cg:C"])
    }

    func testAnInactiveMainIsNotMain() throws {
        let set = AutomationDisplaySet(candidates: [candidate("x", name: "X", availability: .inactive, main: true)])
        XCTAssertFalse(set.candidates[0].isMain)
        XCTAssertThrowsError(try AutomationSelectorResolver.resolve(.display(.role(.main)), in: set))
    }

    // MARK: Errors name the selector, never a substitute display

    func testNoMatchIsNotFound() {
        let issue = issue("alias:Nowhere")
        XCTAssertEqual(issue?.code, .displayNotFound)
        XCTAssertEqual(issue?.message, "no display matches 'alias:Nowhere'")
        XCTAssertEqual(issue?.category, .target)
    }

    func testSeveralMatchesForOneDisplayIsAmbiguousAndListsThem() {
        let issue = issue("tag:studio")
        XCTAssertEqual(issue?.code, .ambiguousSelector)
        XCTAssertEqual(issue?.candidates, ["cg:B", "cg:C"])
        XCTAssertEqual(issue?.message, "'tag:studio' is ambiguous (2 displays): cg:B, cg:C")
        // Two displays with the same name are ambiguous too — never "the first one".
        XCTAssertEqual(self.issue("Dell U2720Q")?.code, .ambiguousSelector)
    }

    func testUnknownGroupIsNotAnEmptyMatch() {
        XCTAssertEqual(issue("group:Nope")?.code, .unknownGroup)
        // A group that exists but has no member here is "no display", not "no group".
        XCTAssertEqual(issue("group:Empty")?.code, .displayNotFound)
    }

    func testSelectorsASurfaceCantEvaluateAreRefused() {
        XCTAssertEqual(issue("focus")?.code, .unsupportedSelector)
        XCTAssertEqual(issue("leftOf:alias:Desk")?.code, .unsupportedSelector)
        let noPointer = AutomationDisplaySet(candidates: [candidate("x", name: "X")])
        XCTAssertThrowsError(try AutomationSelectorResolver.resolve(.display(.role(.pointer)), in: noPointer)) {
            XCTAssertEqual(($0 as? AutomationIssue)?.code, .unsupportedSelector)
        }
    }

    // MARK: Availability

    func testAvailabilityRequirements() throws {
        let inactive = try AutomationSelectorResolver.resolveOne(.cgDisplayID(4), in: set)
        let off = try AutomationSelectorResolver.resolveOne(.cgDisplayID(9), in: set)
        let active = try AutomationSelectorResolver.resolveOne(.cgDisplayID(2), in: set)
        XCTAssertNil(AutomationSelectorResolver.availabilityIssue(active, requirement: .activeDisplay))
        XCTAssertEqual(AutomationSelectorResolver.availabilityIssue(inactive, requirement: .activeDisplay)?.code, .displayInactive)
        XCTAssertNil(AutomationSelectorResolver.availabilityIssue(inactive, requirement: .connectedDisplay))
        XCTAssertEqual(AutomationSelectorResolver.availabilityIssue(off, requirement: .activeDisplay)?.code, .displayNotConnected)
        XCTAssertEqual(AutomationSelectorResolver.availabilityIssue(off, requirement: .connectedDisplay)?.code, .displayNotConnected)
        XCTAssertNil(AutomationSelectorResolver.availabilityIssue(off, requirement: .anyDisplay))
    }
}
