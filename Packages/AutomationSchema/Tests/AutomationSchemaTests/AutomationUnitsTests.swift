import XCTest
@testable import AutomationSchema

final class AutomationUnitsTests: XCTestCase {
    private func level(_ text: String) -> AutomationLevel? { try? AutomationValueParser.level(text) }
    private func delta(_ text: String) -> AutomationLevelDelta? { try? AutomationValueParser.delta(text) }
    private func raw(_ text: String) -> Int? { try? AutomationValueParser.rawValue(text) }

    // MARK: Levels: one canonical unit, explicit percent at the edge

    func testNormalizedAndPercentSpellingsMeanTheSameLevel() {
        XCTAssertEqual(level("0.4")?.normalized, 0.4)
        XCTAssertEqual(level("40%")?.normalized, 0.4)
        XCTAssertEqual(level(" 40 % ")?.normalized, 0.4)
        XCTAssertEqual(level("40.5%")?.normalized ?? 0, 0.405, accuracy: 1e-12)
        XCTAssertEqual(level("0")?.normalized, 0)
        XCTAssertEqual(level("1")?.normalized, 1)
        XCTAssertEqual(level("1.0")?.normalized, 1)
        XCTAssertEqual(level("100%")?.normalized, 1)
        XCTAssertEqual(level("0%")?.normalized, 0)
    }

    /// TA-47/T47: "25" is not 25 % — a bare number outside 0…1 is refused, never reinterpreted.
    func testBareNumberAboveOneIsRefusedNotReadAsPercent() {
        XCTAssertThrowsError(try AutomationValueParser.level("25")) { error in
            let issue = error as? AutomationIssue
            XCTAssertEqual(issue?.code, .invalidValue)
            XCTAssertTrue(issue?.message.contains("40%") ?? false, "the message shows how to write a percentage")
        }
    }

    func testMalformedAndOutOfRangeLevelsAreRefused() {
        for text in ["", "%", "101%", "-0.1", "-5%", "1.01", "abc", "nan", "inf", "1e-1", "0,5", ".", "0.5.1",
                     "+0.5", "٣٠%"] {
            XCTAssertNil(level(text), "'\(text)' should be refused")
        }
    }

    func testNumericLevelsAreValidatedNotClamped() {
        XCTAssertEqual(try AutomationValueParser.level(number: 0.25).normalized, 0.25)
        XCTAssertThrowsError(try AutomationValueParser.level(number: 1.0001))
        XCTAssertThrowsError(try AutomationValueParser.level(number: -0.0001))
        XCTAssertThrowsError(try AutomationValueParser.level(number: .nan))
        XCTAssertThrowsError(try AutomationValueParser.level(number: .infinity))
    }

    func testLevelConversions() throws {
        let level = try XCTUnwrap(AutomationLevel(normalized: 0.555))
        XCTAssertEqual(level.wholePercent, 56)
        XCTAssertEqual(level.raw(maximum: 100), 56)
        XCTAssertEqual(level.raw(maximum: 70), 39)  // 38.85 rounds to 39
        XCTAssertEqual(AutomationLevel(raw: 35, maximum: 70)?.normalized, 0.5)
        XCTAssertNil(AutomationLevel(raw: 71, maximum: 70), "a reading past the maximum isn't a level")
        XCTAssertNil(AutomationLevel(raw: 1, maximum: 0))
        XCTAssertEqual(AutomationLevel(percent: 40)?.normalized, 0.4)
        XCTAssertNil(AutomationLevel(percent: 100.5))
        XCTAssertEqual(AutomationLevel(clamping: .nan).normalized, 0)
        XCTAssertEqual(AutomationLevel(clamping: 7).normalized, 1)
    }

    func testLevelCodingRefusesOutOfRangeValues() throws {
        let data = try JSONEncoder().encode([try XCTUnwrap(AutomationLevel(normalized: 0.5))])
        XCTAssertEqual(String(data: data, encoding: .utf8), "[0.5]")
        XCTAssertThrowsError(try JSONDecoder().decode([AutomationLevel].self, from: Data("[1.5]".utf8)))
    }

    // MARK: Deltas: explicit relative change in percentage points

    func testDeltaSpellings() {
        XCTAssertEqual(delta("+5%")?.normalized ?? 0, 0.05, accuracy: 1e-12)
        XCTAssertEqual(delta("-5%")?.normalized ?? 0, -0.05, accuracy: 1e-12)
        XCTAssertEqual(delta("5%")?.normalized ?? 0, 0.05, accuracy: 1e-12, "unsigned is an increase")
        XCTAssertEqual(delta("+0.05")?.normalized, 0.05)
        XCTAssertEqual(delta("-0.05")?.normalized, -0.05)
        XCTAssertEqual(delta("-100%")?.normalized, -1)
        for text in ["", "+", "-", "++5%", "+150%", "-1.5", "5", "x%", "+-1"] {
            XCTAssertNil(delta(text), "'\(text)' should be refused")
        }
    }

    /// T34: two rapid +5-point changes accumulate, and clamp at the true maximum.
    func testOffsetsAccumulateAndClampAtTheEndsOfTheSpan() throws {
        let plusFive = try XCTUnwrap(AutomationLevelDelta(percentagePoints: 5))
        let start = try XCTUnwrap(AutomationLevel(normalized: 0.5))
        XCTAssertEqual(start.offset(by: plusFive).offset(by: plusFive).wholePercent, 60)
        let high = try XCTUnwrap(AutomationLevel(normalized: 0.97))
        XCTAssertEqual(high.offset(by: plusFive).normalized, 1)
        XCTAssertEqual(high.offset(by: plusFive).offset(by: plusFive).normalized, 1)
        let minusFive = try XCTUnwrap(AutomationLevelDelta(percentagePoints: -5))
        XCTAssertEqual(try XCTUnwrap(AutomationLevel(normalized: 0.02)).offset(by: minusFive).normalized, 0)
    }

    // MARK: Raw monitor units

    func testRawValuesAcceptDecimalAndHex() {
        XCTAssertEqual(raw("70"), 70)
        XCTAssertEqual(raw("0x46"), 70)
        XCTAssertEqual(raw("0X46"), 70)
        XCTAssertEqual(raw("65535"), 65535)
        XCTAssertEqual(raw("0xFFFF"), 65535)
        for text in ["65536", "0x10000", "-1", "0x", "1.5", "seventy", ""] {
            XCTAssertNil(raw(text), "'\(text)' should be refused")
        }
    }

    // MARK: DDC read-back policy (owner decision #7: the CLI verifies like the app)

    func testDDCReadbackPolicyMatchesTheAppValues() {
        XCTAssertEqual(DDCReadbackPolicy.settleNanoseconds(.continuous), 250_000_000)
        XCTAssertEqual(DDCReadbackPolicy.settleNanoseconds(.discrete), 250_000_000)
        XCTAssertEqual(DDCReadbackPolicy.settleNanoseconds(.colorPreset), 1_000_000_000)
        XCTAssertEqual(DDCReadbackPolicy.tolerance(.continuous), 1)
        XCTAssertEqual(DDCReadbackPolicy.tolerance(.discrete), 0)
        XCTAssertEqual(DDCReadbackPolicy.tolerance(.colorPreset), 0)
    }
}
