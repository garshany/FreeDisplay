import XCTest
@testable import AutomationSchema

final class CommandConsoleTests: XCTestCase {
    func testQuotesEscapesUnicodeAndEmptyTokens() throws {
        XCTAssertEqual(try ConsoleGrammar.tokens(#"brightness --display 'alias:Рабочий стол' --value "40%""#),
                       ["brightness", "--display", "alias:Рабочий стол", "--value", "40%"])
        XCTAssertEqual(try ConsoleGrammar.tokens(#"a\ b "" 'x\'y'"#), ["a b", "", "x'y"])
    }

    func testUnclosedQuoteAndTrailingEscapeRefuse() {
        for input in ["brightness 'alias:Desk", "list\\", "list \""] {
            XCTAssertThrowsError(try ConsoleGrammar.parse(input))
        }
    }

    func testShellSyntaxHasNoExecutableMeaning() throws {
        XCTAssertEqual(try ConsoleGrammar.tokens("$(touch /tmp/no) ; | > `date`"),
                       ["$(touch", "/tmp/no)", ";", "|", ">", "`date`"])
        for input in ["curl https://example.com", "list ; touch /tmp/no", "list | cat", "list > x"] {
            XCTAssertThrowsError(try ConsoleGrammar.parse(input))
        }
    }

    func testConsoleBuiltins() throws {
        XCTAssertEqual(try ConsoleGrammar.parse("  "), .empty)
        XCTAssertEqual(try ConsoleGrammar.parse("help"), .help(nil))
        XCTAssertEqual(try ConsoleGrammar.parse("help brightness"), .help("brightness"))
        XCTAssertEqual(try ConsoleGrammar.parse("--help"), .help(nil))
        XCTAssertEqual(try ConsoleGrammar.parse("clear"), .clear)
        XCTAssertEqual(try ConsoleGrammar.parse("exit"), .exit)
        for input in ["exit now", "clear all", "help mode extra"] { XCTAssertThrowsError(try ConsoleGrammar.parse(input)) }
    }

    func testNamedArgumentsDelegateToSharedParser() throws {
        let expected = try AutomationRequestParser.parse(verb: "brightness", parameters: [
            "display": .string("alias:Рабочий стол"), "offset": .string("-5%"), "method": .string("hardware")])
        XCTAssertEqual(try ConsoleGrammar.parse(#"brightness --display 'alias:Рабочий стол' --offset -5% --method hardware"#), .command(expected))
        XCTAssertEqual(try ConsoleGrammar.parse(#"brightness display='alias:Рабочий стол' offset=-5% method=hardware"#), .command(expected))
    }

    func testDuplicateUnknownAndInvalidArgumentsRefuse() {
        for input in ["brightness display=builtin display=main value=40%", "brightness display=builtin --display main value=40%",
                      "brightness display=builtin value=NaN", "list extra=true", "list --bad x", "brightness --display", "bogus"] {
            XCTAssertThrowsError(try ConsoleGrammar.parse(input), input)
        }
    }

    func testDryRunAndConfirmationCannotBeBypassed() throws {
        guard case .command(let request) = try ConsoleGrammar.parse("brightness display=builtin value=40% --dry-run") else { return XCTFail() }
        XCTAssertTrue(request.dryRun)
        XCTAssertThrowsError(try ConsoleGrammar.parse("setMode display=builtin mode=1920x1080 keepWithoutConfirmation=true"))
        XCTAssertFalse(AutomationCatalog.descriptors(for: .console).contains { $0.name == .disconnect })
    }

    func testHistoryDraftRestoresAndDuplicatesCollapse() {
        var session = ConsoleSession(historyCapacity: nil, outputCapacity: nil)
        for line in ["one", "one", "two"] { session.draft = line; _ = session.submit() }
        XCTAssertEqual(session.history, ["one", "two"])
        session.draft = "unfinished"
        session.previous(); XCTAssertEqual(session.draft, "two")
        session.previous(); session.previous(); XCTAssertEqual(session.draft, "one")
        session.next(); XCTAssertEqual(session.draft, "two")
        session.next(); session.next(); XCTAssertEqual(session.draft, "unfinished")
    }

    func testLogAndOutputArrivalsNeverAlterDraftOrHistoryCursor() {
        var session = ConsoleSession(historyCapacity: nil, outputCapacity: nil)
        session.draft = "old"; _ = session.submit(); session.draft = "draft"; session.previous()
        session.append("new log"); session.clear(); session.next()
        XCTAssertEqual(session.draft, "draft")
        XCTAssertEqual(session.history, ["old"])
    }

    func testCallerCapacityEvictsOldestAndCanBeChanged() {
        var session = ConsoleSession(historyCapacity: 2, outputCapacity: 1)
        for line in ["a", "b", "c"] { session.draft = line; _ = session.submit(); session.append(line) }
        XCTAssertEqual(session.history, ["b", "c"]); XCTAssertEqual(session.output, ["c"])
        session.historyCapacity = 0; session.outputCapacity = 0
        XCTAssertTrue(session.history.isEmpty); XCTAssertTrue(session.output.isEmpty)
        session.historyCapacity = nil; session.draft = "next"; _ = session.submit()
        XCTAssertEqual(session.history, ["next"])
    }

    func testNoImplicitThousandEntryCap() {
        var session = ConsoleSession(historyCapacity: nil, outputCapacity: nil)
        for number in 0..<1002 { session.draft = String(number); _ = session.submit() }
        XCTAssertEqual(session.history.count, 1002)
    }

    func testCapacityValidation() throws {
        XCTAssertNil(try ConsoleCapacity.parse(" "))
        XCTAssertEqual(try ConsoleCapacity.parse("0"), 0)
        XCTAssertEqual(try ConsoleCapacity.parse("1000"), 1000)
        for text in ["-1", "1.5", "abc", "999999999999999999999999999999"] { XCTAssertThrowsError(try ConsoleCapacity.parse(text)) }
    }
}
