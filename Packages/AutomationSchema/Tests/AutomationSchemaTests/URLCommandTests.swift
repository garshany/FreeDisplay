import XCTest
@testable import AutomationSchema

final class URLCommandTests: XCTestCase {
    private func parse(_ string: String) -> URLCommand? {
        guard let url = URL(string: string) else { return nil }
        return URLCommandParser.parse(url)
    }

    func testReconnectAllVariants() {
        XCTAssertEqual(parse("opendisplay://reconnect-all"), .reconnectAll)
        XCTAssertEqual(parse("opendisplay://reconnectall"), .reconnectAll)
        XCTAssertEqual(parse("opendisplay://reconnect_all"), .reconnectAll)
    }

    func testSchemeIsCaseInsensitiveAndVerbIsCaseInsensitive() {
        XCTAssertEqual(parse("OpenDisplay://Reconnect-All"), .reconnectAll)
        XCTAssertEqual(parse("OPENDISPLAY://RECONNECT-ALL"), .reconnectAll)
    }

    func testDisconnectRequiresSelector() {
        XCTAssertEqual(parse("opendisplay://disconnect?display=cgid:7"), .disconnect(selector: "cgid:7"))
        XCTAssertEqual(parse("opendisplay://disconnect?target=Studio%20Display"),
                       .disconnect(selector: "Studio Display"))
        // Missing or empty selector → not a command (no silent guess at which display to drop).
        XCTAssertNil(parse("opendisplay://disconnect"))
        XCTAssertNil(parse("opendisplay://disconnect?display="))
        XCTAssertNil(parse("opendisplay://disconnect?display=%20"))
    }

    func testWrongSchemeIsRejected() {
        XCTAssertNil(parse("https://reconnect-all"))
        XCTAssertNil(parse("betterdisplay://reconnect-all"))
        XCTAssertNil(parse("opendisplays://reconnect-all"))
    }

    func testUnknownVerbsAreRejected() {
        XCTAssertNil(parse("opendisplay://nuke-everything"))
        XCTAssertNil(parse("opendisplay://"))
        XCTAssertNil(parse("opendisplay://?display=x"))
        // A bare `reconnect` is intentionally NOT reconnect-all (avoids ambiguity with per-display reconnect).
        XCTAssertNil(parse("opendisplay://reconnect"))
    }

    func testRequiresConfirmationGate() {
        XCTAssertFalse(URLCommand.reconnectAll.requiresConfirmation)
        XCTAssertTrue(URLCommand.disconnect(selector: "x").requiresConfirmation)
    }

    func testCommandNames() {
        XCTAssertEqual(URLCommand.reconnectAll.name, "reconnectAll")
        XCTAssertEqual(URLCommand.disconnect(selector: "x").name, "disconnect")
    }

    func testLastQueryValueWinsAndParamNameIsCaseInsensitive() {
        XCTAssertEqual(parse("opendisplay://disconnect?display=a&display=b"), .disconnect(selector: "b"))
        XCTAssertEqual(parse("opendisplay://disconnect?DISPLAY=z"), .disconnect(selector: "z"))
    }

    // MARK: Typed requests through the shared parser (FD-066)

    private func request(_ string: String) -> Result<AutomationRequest, AutomationIssue>? {
        URL(string: string).flatMap(URLCommandParser.parseRequest)
    }

    func testLinksParseEveryCatalogVerbButOnlyRecoveryKeepsTheLegacyCommand() {
        guard case .success(let brightness)? = request("opendisplay://brightness?display=alias:Desk&value=50%25") else {
            return XCTFail("expected a request")
        }
        XCTAssertEqual(brightness.command, .setBrightness(AutomationLevel(normalized: 0.5)!, method: .automatic))
        // Whether a link may run it is the engine's decision; the legacy reading knows two commands.
        XCTAssertNil(parse("opendisplay://brightness?display=alias:Desk&value=50%25"))
    }

    func testCallbackParametersAreDroppedButOtherUnknownOnesFail() {
        XCTAssertEqual(parse("opendisplay://reconnect-all?x-source=Shortcuts&x-success=foo://"), .reconnectAll)
        guard case .failure(let issue)? = request("opendisplay://reconnect-all?force=1") else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(issue.code, .unknownParameter)
        XCTAssertNil(parse("opendisplay://reconnect-all?force=1"))
    }

    func testInvalidValuesAreRefusedWithTheirIssue() {
        guard case .failure(let issue)? = request("opendisplay://brightness?display=main&value=25") else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(issue.code, .invalidValue)
        XCTAssertNil(request("https://brightness?display=main"))
        XCTAssertNil(request("opendisplay://"))
    }
}

