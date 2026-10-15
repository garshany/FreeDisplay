import DisplayDomain
import XCTest
@testable import AutomationSchema

final class AutomationRequestParserTests: XCTestCase {
    private func parse(_ verb: String, _ parameters: [String: AutomationParameterValue] = [:]) throws -> AutomationRequest {
        try AutomationRequestParser.parse(verb: verb, parameters: parameters)
    }

    private func issue(_ verb: String, _ parameters: [String: AutomationParameterValue] = [:]) -> AutomationIssue? {
        do {
            _ = try parse(verb, parameters)
            return nil
        } catch {
            return error as? AutomationIssue
        }
    }

    private let half = AutomationLevel(normalized: 0.5)!

    // MARK: Verbs

    func testCanonicalNamesAndAliases() throws {
        XCTAssertEqual(try parse("listDisplays").command, .listDisplays)
        XCTAssertEqual(try parse("list").command, .listDisplays)
        XCTAssertEqual(try parse("reconnect-all").command, .reconnectAll)
        XCTAssertEqual(try parse("RECONNECT_ALL").command, .reconnectAll)
        XCTAssertEqual(try parse("modes", ["display": .string("main")]).command, .listModes)
        XCTAssertEqual(try parse("main", ["display": .string("main")]).command, .setMain)
        XCTAssertEqual(try parse("profiles").command, .listColorProfiles)
        XCTAssertEqual(issue("nuke-everything")?.code, .unknownCommand)
        XCTAssertEqual(issue("")?.code, .unknownCommand)
        // `reconnect` alone is a per-display CLI verb, never reconnect-all.
        XCTAssertEqual(issue("reconnect")?.code, .unknownCommand)
    }

    func testBrightnessPicksGetSetOrAdjustByItsParameters() throws {
        let display: [String: AutomationParameterValue] = ["display": .string("alias:Desk")]
        XCTAssertEqual(try parse("brightness", display).command, .getBrightness(method: .automatic))
        XCTAssertEqual(try parse("brightness", display.merging(["value": .string("50%")]) { $1 }).command,
                       .setBrightness(half, method: .automatic))
        XCTAssertEqual(try parse("brightness", display.merging(["offset": .string("-5%")]) { $1 }).command,
                       .adjustBrightness(AutomationLevelDelta(normalized: -0.05)!, method: .automatic))
        XCTAssertEqual(issue("brightness", display.merging(["value": .number(0.5), "offset": .number(0.1)]) { $1 })?.code,
                       .conflictingParameters)
    }

    func testModeAndProfileAliasesPickGetOrSet() throws {
        let display: [String: AutomationParameterValue] = ["display": .string("main")]
        XCTAssertEqual(try parse("mode", display).command, .getMode)
        XCTAssertEqual(try parse("mode", display.merging(["mode": .string("1920x1080@60")]) { $1 }).command,
                       .setMode(.logical(width: 1920, height: 1080, refreshHz: 60, hiDPI: nil)))
        XCTAssertEqual(try parse("profile", display).command, .getColorProfile)
        XCTAssertEqual(try parse("profile", display.merging(["profile": .string("Display P3")]) { $1 }).command,
                       .setColorProfile(.name("Display P3")))
    }

    // MARK: Values

    func testValuesUseTheSharedUnits() throws {
        let display: [String: AutomationParameterValue] = ["display": .string("main")]
        XCTAssertEqual(try parse("setBrightness", display.merging(["value": .number(0.5)]) { $1 }).command,
                       .setBrightness(half, method: .automatic))
        XCTAssertEqual(try parse("setBrightness", display.merging(["value": .string("0.5")]) { $1 }).command,
                       .setBrightness(half, method: .automatic))
        XCTAssertEqual(issue("setBrightness", display.merging(["value": .number(50)]) { $1 })?.code, .invalidValue)
        XCTAssertEqual(issue("setBrightness", display.merging(["value": .bool(true)]) { $1 })?.code, .invalidValue)
        XCTAssertEqual(issue("setBrightness", display)?.code, .missingParameter)
        XCTAssertEqual(try parse("setBrightness", display.merging(["value": .number(0.5), "method": .string("hardware")]) { $1 }).command,
                       .setBrightness(half, method: .hardware))
        XCTAssertEqual(issue("setBrightness", display.merging(["value": .number(0.5), "method": .number(1)]) { $1 })?.code,
                       .invalidValue)
    }

    func testControlCharactersAreRefused() {
        XCTAssertEqual(issue("getBrightness", ["display": .string("alias:De\u{0}sk")])?.code, .invalidValue)
        XCTAssertEqual(issue("getBrightness", ["display": .string("alias:De\nsk")])?.code, .invalidValue)
    }

    // MARK: Parameters

    func testUnknownParametersAreErrorsNotIgnored() {
        XCTAssertEqual(issue("reconnectAll", ["display": .string("main")])?.code, .unknownParameter)
        XCTAssertEqual(issue("getBrightness", ["display": .string("main"), "extra": .number(0)])?.code, .unknownParameter)
        XCTAssertEqual(issue("setMain", ["display": .string("main"), "value": .number(1)])?.code, .unknownParameter)
    }

    func testParameterNamesAreCaseAndSeparatorInsensitiveButNotDuplicated() throws {
        XCTAssertEqual(try parse("getBrightness", ["DISPLAY": .string("main")]).target, .display(.role(.main)))
        XCTAssertEqual(try parse("getBrightness", ["display_id": .string("cg:1")]).target,
                       .display(.id(DisplayRecordID(rawValue: "cg:1"))))
        XCTAssertEqual(issue("getBrightness", ["display": .string("main"), "Display": .string("builtin")])?.code,
                       .conflictingParameters)
    }

    func testTargetsTakeEitherASelectorOrAnID() throws {
        let byID = try parse("getBrightness", ["displayId": .string("cg:ABC")])
        XCTAssertEqual(byID.target, .display(.id(DisplayRecordID(rawValue: "cg:ABC"))))
        XCTAssertEqual(byID.targetText, "id:cg:ABC")
        let bySelector = try parse("getBrightness", ["display": .string("Studio Display")])
        XCTAssertEqual(bySelector.target, .display(.name("Studio Display")))
        XCTAssertEqual(issue("getBrightness", ["display": .string("main"), "displayId": .string("x")])?.code,
                       .conflictingParameters)
        XCTAssertEqual(issue("getBrightness")?.code, .missingParameter)
        XCTAssertEqual(issue("getBrightness", ["display": .string("  ")])?.code, .missingParameter)
        XCTAssertEqual(issue("getBrightness", ["display": .string("bogus:x")])?.code, .invalidSelector)
    }

    func testDryRunIsCommonToEveryCommand() throws {
        XCTAssertTrue(try parse("reconnectAll", ["dryRun": .bool(true)]).dryRun)
        XCTAssertTrue(try parse("setMain", ["display": .string("main"), "dry-run": .string("yes")]).dryRun)
        XCTAssertFalse(try parse("reconnectAll").dryRun)
        XCTAssertEqual(issue("reconnectAll", ["dryRun": .string("maybe")])?.code, .invalidValue)
    }

    // MARK: Modes and profiles

    func testModeSpecGrammar() throws {
        XCTAssertEqual(try AutomationModeSpec.parse("2560x1440"), .logical(width: 2560, height: 1440, refreshHz: nil, hiDPI: nil))
        XCTAssertEqual(try AutomationModeSpec.parse("1512x982@120@2x"), .logical(width: 1512, height: 982, refreshHz: 120, hiDPI: true))
        XCTAssertEqual(try AutomationModeSpec.parse("1920X1080@1x"), .logical(width: 1920, height: 1080, refreshHz: nil, hiDPI: false))
        XCTAssertEqual(try AutomationModeSpec.parse("1920x1080@59.94"), .logical(width: 1920, height: 1080, refreshHz: 59.94, hiDPI: nil))
        let exact = DisplayMode(pixelWidth: 3840, pixelHeight: 2160, pointWidth: 1920, pointHeight: 1080,
                                refreshHz: 59.94, isHiDPI: true)
        XCTAssertEqual(try AutomationModeSpec.parse(FavoriteResolutions.key(for: exact)), .exact(exact))
        for text in ["", "1920", "1920x", "x1080", "0x1080", "1920x1080@", "1920x1080@fast", "1920x1080@60@3x", "a@b@c@d"] {
            XCTAssertThrowsError(try AutomationModeSpec.parse(text), "'\(text)'")
        }
    }

    func testModeResolutionNeverApproximates() throws {
        func mode(_ w: Int, _ h: Int, hz: Double, hiDPI: Bool, px: Int? = nil) -> DisplayMode {
            DisplayMode(pixelWidth: px ?? (hiDPI ? w * 2 : w), pixelHeight: hiDPI ? h * 2 : h,
                        pointWidth: w, pointHeight: h, refreshHz: hz, isHiDPI: hiDPI)
        }
        let offered = [mode(1920, 1080, hz: 60, hiDPI: true), mode(1920, 1080, hz: 59.94, hiDPI: true),
                       mode(1920, 1080, hz: 60, hiDPI: false), mode(2560, 1440, hz: 60, hiDPI: false)]
        XCTAssertEqual(try AutomationModeSpec.parse("2560x1440").resolve(among: offered, displayName: "Desk"), offered[3])
        XCTAssertEqual(try AutomationModeSpec.parse("1920x1080@60@2x").resolve(among: offered, displayName: "Desk"), offered[0])
        XCTAssertEqual(try AutomationModeSpec.parse("1920x1080@59.94").resolve(among: offered, displayName: "Desk"), offered[1])
        XCTAssertThrowsError(try AutomationModeSpec.parse("1920x1080@60").resolve(among: offered, displayName: "Desk")) {
            let issue = $0 as? AutomationIssue
            XCTAssertEqual(issue?.code, .ambiguousMode)
            XCTAssertEqual(issue?.candidates.count, 2, "both 60 Hz densities, never 59.94")
        }
        XCTAssertThrowsError(try AutomationModeSpec.parse("1280x720").resolve(among: offered, displayName: "Desk")) {
            XCTAssertEqual(($0 as? AutomationIssue)?.code, .modeNotOffered)
        }
    }

    func testProfileResolution() throws {
        let installed = [AutomationProfileInfo(id: "/Library/ColorSync/Profiles/P3.icc", name: "Display P3"),
                         AutomationProfileInfo(id: "/Users/me/Library/ColorSync/Profiles/P3.icc", name: "Display P3"),
                         AutomationProfileInfo(id: "/Library/ColorSync/Profiles/sRGB.icc", name: "sRGB IEC61966-2.1")]
        XCTAssertEqual(try AutomationProfileSpec.parse("srgb iec61966-2.1").resolve(among: installed), installed[2])
        XCTAssertEqual(try AutomationProfileSpec.parse("/Library/ColorSync/Profiles/../Profiles/P3.icc").resolve(among: installed),
                       installed[0])
        XCTAssertThrowsError(try AutomationProfileSpec.parse("Display P3").resolve(among: installed)) {
            XCTAssertEqual(($0 as? AutomationIssue)?.code, .ambiguousProfile)
            XCTAssertEqual(($0 as? AutomationIssue)?.candidates.count, 2)
        }
        XCTAssertThrowsError(try AutomationProfileSpec.parse("Nope").resolve(among: installed)) {
            XCTAssertEqual(($0 as? AutomationIssue)?.code, .profileNotFound)
        }
        XCTAssertThrowsError(try AutomationProfileSpec.parse(" "))
    }
}
