import Foundation
import DisplayDomain
import XCTest
@testable import AutomationSchema

final class LocalHTTPControlTests: XCTestCase {
    private func request(token: String = "secret", extra: String = "", body: String = "{}",
                         path: String = "/v1/reconnect-all") -> Data {
        Data("POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\(extra)\r\n\(body)".utf8)
    }
    func testAuthenticatedExactAllowlist() {
        XCTAssertEqual(LocalHTTPControl.parse(request(), token: "secret"), .reconnectAll)
        XCTAssertEqual(LocalHTTPControl.parse(request(path: "/v1/disconnect"), token: "secret"), .rejected(404))
        XCTAssertEqual(LocalHTTPControl.parse(request(path: "/v1/command/"), token: "secret"), .rejected(404))
        XCTAssertEqual(LocalHTTPControl.parse(request(token: "wrong"), token: "secret"), .rejected(401))
        XCTAssertEqual(LocalHTTPControl.parse(request(), token: ""), .rejected(401))
    }
    func testRejectBrowserOriginsAndAmbiguousFraming() {
        for extra in ["Origin: https://example.com\r\n", "Transfer-Encoding: chunked\r\n",
                      "Content-Length: 2\r\n", "Authorization: Bearer secret\r\n"] {
            XCTAssertEqual(LocalHTTPControl.parse(request(extra: extra), token: "secret"), .rejected(400))
        }
        XCTAssertEqual(LocalHTTPControl.parse(request(body: "{\"command\":\"disconnect\"}"), token: "secret"), .rejected(400))
        XCTAssertEqual(LocalHTTPControl.parse(request(body: "[]"), token: "secret"), .rejected(400))
    }
    func testFragmentationBoundsAndPipelining() {
        let full = request()
        XCTAssertEqual(LocalHTTPControl.parse(full.dropLast(), token: "secret"), .incomplete)
        XCTAssertEqual(LocalHTTPControl.parse(Data(repeating: 65, count: 8193), token: "secret"), .rejected(413))
        var pipeline = full; pipeline.append(full)
        XCTAssertEqual(LocalHTTPControl.parse(pipeline, token: "secret"), .rejected(400))
    }
    func testBrightnessIsTypedBoundedAndExact() {
        func brightness(_ body: String) -> LocalHTTPControl.ParseResult {
            LocalHTTPControl.parse(request(body: body, path: "/v1/brightness"), token: "secret")
        }
        XCTAssertEqual(brightness("{\"displayId\":\"display-123\",\"value\":0.5}"), .brightness(displayId: "display-123", value: 0.5))
        // Invalid bodies are still 400s; they now carry the reason as a typed issue.
        for body in ["{\"displayId\":\"x\",\"value\":true}", "{\"displayId\":\"x\",\"value\":1.1}",
                     "{\"displayId\":\"x\",\"value\":-1}", "{\"displayId\":\"\",\"value\":0}",
                     "{\"displayId\":\"x\",\"value\":0,\"extra\":0}", "{\"displayId\":\"x\"}",
                     "{\"displayId\":\"x y\",\"value\":0.5}", "{\"displayId\":\"x\",\"value\":null}",
                     "{\"displayId\":\"x\",\"value\":\"50\"}"] {
            XCTAssertEqual(brightness(body).rejectionStatus, 400, body)
        }
        let get = Data("GET /v1/displays HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer secret\r\nContent-Length: 0\r\n\r\n".utf8)
        XCTAssertEqual(LocalHTTPControl.parse(get, token: "secret"), .displays)
    }
    /// curl, browsers and URLSession send a body-less GET without Content-Length (RFC 9110 §8.6).
    func testBodylessGetWithoutContentLength() {
        let get = Data("GET /v1/displays HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nUser-Agent: curl/8.7.1\r\nAccept: */*\r\nAuthorization: Bearer secret\r\n\r\n".utf8)
        XCTAssertEqual(LocalHTTPControl.parse(get, token: "secret"), .displays)
        var withBody = get; withBody.append(Data("x".utf8))
        XCTAssertEqual(LocalHTTPControl.parse(withBody, token: "secret"), .rejected(400))
        let unauthenticated = Data("GET /v1/displays HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
        XCTAssertEqual(LocalHTTPControl.parse(unauthenticated, token: "secret"), .rejected(401))
        let postWithoutLength = Data("POST /v1/reconnect-all HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer secret\r\nContent-Type: application/json\r\n\r\n{}".utf8)
        XCTAssertEqual(LocalHTTPControl.parse(postWithoutLength, token: "secret"), .rejected(400))
    }
    func testResponsesHaveExactByteLengths() {
        let body = Data("{\"name\":\"é\"}".utf8)
        let response = LocalHTTPControl.response(status: 200, body: body)
        XCTAssertTrue(String(decoding: response, as: UTF8.self).contains("Content-Length: \(body.count)\r\n"))
        XCTAssertTrue(response.suffix(body.count).elementsEqual(body))
    }

    // MARK: Typed requests through the shared parser (FD-066)

    private func post(_ path: String, _ body: String) -> LocalHTTPControl.ParseResult {
        LocalHTTPControl.parse(request(body: body, path: path), token: "secret")
    }

    func testBrightnessAcceptsSelectorsPercentOffsetAndMethod() {
        let half = AutomationLevel(normalized: 0.5)!
        XCTAssertEqual(post("/v1/brightness", "{\"display\":\"alias:Desk\",\"value\":\"50%\",\"method\":\"hardware\"}"),
                       .command(AutomationRequest(.setBrightness(half, method: .hardware), target: .display(.alias("Desk")),
                                                  targetText: "alias:Desk"), style: .legacyBrightness))
        XCTAssertEqual(post("/v1/brightness", "{\"displayId\":\"cg:1\",\"offset\":-0.05}"),
                       .command(.byID(.adjustBrightness(AutomationLevelDelta(normalized: -0.05)!, method: .automatic),
                                      DisplayRecordID(rawValue: "cg:1")), style: .legacyBrightness))
        // The original body with a method is a typed request too, answered in the original shape.
        XCTAssertEqual(post("/v1/brightness", "{\"displayId\":\"cg:1\",\"value\":0.5,\"method\":\"ddc\"}"),
                       .command(.byID(.setBrightness(half, method: .ddc), DisplayRecordID(rawValue: "cg:1")),
                                style: .legacyBrightness))
    }

    func testBrightnessRefusalsCarryTheirIssue() {
        guard case .invalid(let issue) = post("/v1/brightness", "{\"display\":\"main\",\"value\":0.5,\"offset\":0.1}") else {
            return XCTFail("expected an issue")
        }
        XCTAssertEqual(issue.code, .conflictingParameters)
        XCTAssertEqual(post("/v1/brightness", "{\"display\":\"main\",\"value\":0.5,\"method\":\"warp\"}").rejectionStatus, 400)
        XCTAssertEqual(post("/v1/brightness", "{\"display\":\"main\",\"displayId\":\"x\",\"value\":0.5}").rejectionStatus, 400)
    }

    func testCommandRoute() {
        XCTAssertEqual(post("/v1/command", "{\"command\":\"setMain\",\"display\":\"alias:Desk\"}"),
                       .command(AutomationRequest(.setMain, target: .display(.alias("Desk")), targetText: "alias:Desk"),
                                style: .result))
        XCTAssertEqual(post("/v1/command", "{\"command\":\"reconnect-all\",\"dryRun\":true}"),
                       .command(AutomationRequest(.reconnectAll, dryRun: true), style: .result))
        XCTAssertEqual(post("/v1/command", "{\"command\":\"nuke\"}").rejectionStatus, 404)
        XCTAssertEqual(post("/v1/command", "{\"display\":\"main\"}").rejectionStatus, 400)
        XCTAssertEqual(post("/v1/command", "{\"command\":\"getMode\",\"display\":[\"main\"]}").rejectionStatus, 400)
        XCTAssertEqual(post("/v1/command", "{\"command\":\"getMode\",\"display\":{}}").rejectionStatus, 400)
    }

    func testCatalogRouteIsABodylessAuthenticatedGet() {
        let get = Data("GET /v1/commands HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer secret\r\n\r\n".utf8)
        XCTAssertEqual(LocalHTTPControl.parse(get, token: "secret"), .catalog)
        let anonymous = Data("GET /v1/commands HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
        XCTAssertEqual(LocalHTTPControl.parse(anonymous, token: "secret"), .rejected(401))
    }

    func testIssuesNeverReachAnUnauthenticatedClient() {
        // Authentication is checked before the body is read, so a bad token learns nothing about it.
        let bad = request(token: "wrong", body: "{\"command\":\"nuke\"}", path: "/v1/command")
        XCTAssertEqual(LocalHTTPControl.parse(bad, token: "secret"), .rejected(401))
    }

    func testStatusLinesUseTheirReasonPhrase() {
        let text = String(decoding: LocalHTTPControl.response(status: 422), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 422 Unprocessable Content\r\n"))
    }
}
