import XCTest
@testable import AutomationSchema

final class CLIArgumentsTests: XCTestCase {
    private func run(_ arguments: [String]) throws -> CLIInvocation {
        guard case .run(let invocation) = try CLIGrammar.parse(arguments) else {
            XCTFail("expected a verb to run for \(arguments)")
            return CLIInvocation(command: "")
        }
        return invocation
    }

    // MARK: Help never falls through to a verb

    func testHelpSpellingsAllMeanHelp() throws {
        for arguments in [["help"], ["--help"], ["-h"], ["list", "--help"],
                          ["brightness", "main", "0.5", "-h"], ["--json", "--help"]] {
            XCTAssertEqual(try CLIGrammar.parse(arguments), .help, "\(arguments)")
        }
    }

    func testHelpWinsOverAnUnknownOption() throws {
        // Asking for help must never be answered with an error about the rest of the line.
        XCTAssertEqual(try CLIGrammar.parse(["--bogus", "--help"]), .help)
    }

    func testHelpAsASelectorIsNotHelp() throws {
        // Only the verb position means help, so a display aliased "help" stays reachable.
        let invocation = try run(["alias", "help", "Desk"])
        XCTAssertEqual(invocation.command, "alias")
        XCTAssertEqual(invocation.positional, ["help", "Desk"])
    }

    // MARK: Unknown and unsupported options are errors, not the default verb

    func testUnknownOptionIsRejected() {
        XCTAssertThrowsError(try CLIGrammar.parse(["--bogus"])) {
            XCTAssertEqual($0 as? CLIArgumentError, .unknownOption("--bogus"))
        }
        XCTAssertThrowsError(try CLIGrammar.parse(["list", "-x"])) {
            XCTAssertEqual($0 as? CLIArgumentError, .unknownOption("-x"))
        }
    }

    func testOptionAVerbDoesNotHonourIsRejected() {
        // The dangerous case: `--dry-run` on a verb that writes would otherwise perform the write.
        XCTAssertThrowsError(try CLIGrammar.parse(["brightness", "main", "0.4", "--dry-run"])) {
            XCTAssertEqual($0 as? CLIArgumentError,
                           .unsupportedOption(option: "--dry-run", command: "brightness"))
        }
        XCTAssertThrowsError(try CLIGrammar.parse(["listen", "--json"])) {
            XCTAssertEqual($0 as? CLIArgumentError, .unsupportedOption(option: "--json", command: "listen"))
        }
    }

    func testValuedOptionWithoutValueIsRejected() {
        XCTAssertThrowsError(try CLIGrammar.parse(["edid", "main", "--out"])) {
            XCTAssertEqual($0 as? CLIArgumentError, .missingValue("--out"))
        }
    }

    // MARK: Normal command lines

    func testNoArgumentsListsDisplays() throws {
        XCTAssertEqual(try run([]), CLIInvocation(command: "list"))
    }

    func testOptionsAloneStillMeanList() throws {
        XCTAssertEqual(try run(["--json"]), CLIInvocation(command: "list", flags: ["--json"]))
    }

    func testFlagsAreSeparatedFromPositionals() throws {
        let invocation = try run(["disconnect", "--dry-run", "alias:Desk", "--json"])
        XCTAssertEqual(invocation.command, "disconnect")
        XCTAssertEqual(invocation.positional, ["alias:Desk"])
        XCTAssertEqual(invocation.flags, ["--dry-run", "--json"])
        XCTAssertEqual(invocation.argument1, "alias:Desk")
        XCTAssertNil(invocation.argument2)
    }

    func testValuedOptionConsumesItsValue() throws {
        // The path after --out used to be left among the positionals.
        let invocation = try run(["edid", "main", "--out", "/tmp/edid.bin"])
        XCTAssertEqual(invocation.positional, ["main"])
        XCTAssertEqual(invocation.values, ["--out": "/tmp/edid.bin"])
    }

    func testUnknownVerbIsLeftForTheDispatcher() throws {
        // The dispatcher's message lists the real verbs; the parser must not pre-empt it.
        XCTAssertEqual(try run(["frobnicate", "--json"]).command, "frobnicate")
    }

    func testEveryVerbWithOptionsIsAKnownCommand() {
        XCTAssertTrue(Set(CLIGrammar.supportedOptions.keys).isSubset(of: CLIGrammar.commands))
        let options = CLIGrammar.valuelessOptions.union(CLIGrammar.valuedOptions)
        for (command, allowed) in CLIGrammar.supportedOptions {
            XCTAssertTrue(allowed.isSubset(of: options), command)
        }
    }

    // MARK: Exit codes

    func testExitCodesFollowEnvelopeStatus() {
        XCTAssertEqual(CLIExitCode(.committed), .success)
        XCTAssertEqual(CLIExitCode(.noOp), .success)
        XCTAssertEqual(CLIExitCode(.partial), .partial)
        XCTAssertEqual(CLIExitCode(.failed), .failure)
        XCTAssertEqual(CLIExitCode(.rolledBack), .failure)
        XCTAssertEqual(CLIExitCode.usage.rawValue, 2)
        XCTAssertNotEqual(CLIExitCode.partial.rawValue, CLIExitCode.success.rawValue)
    }
}
