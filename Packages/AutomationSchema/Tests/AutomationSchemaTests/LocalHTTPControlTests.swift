import Foundation
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
        for body in ["{\"displayId\":\"x\",\"value\":true}", "{\"displayId\":\"x\",\"value\":1.1}",
                     "{\"displayId\":\"x\",\"value\":-1}", "{\"displayId\":\"\",\"value\":0}",
                     "{\"displayId\":\"x\",\"value\":0,\"extra\":0}"] {
            XCTAssertEqual(brightness(body), .rejected(400))
        }
        let get = Data("GET /v1/displays HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer secret\r\nContent-Length: 0\r\n\r\n".utf8)
        XCTAssertEqual(LocalHTTPControl.parse(get, token: "secret"), .displays)
    }
    func testResponsesHaveExactByteLengths() {
        let body = Data("{\"name\":\"é\"}".utf8)
        let response = LocalHTTPControl.response(status: 200, body: body)
        XCTAssertTrue(String(decoding: response, as: UTF8.self).contains("Content-Length: \(body.count)\r\n"))
        XCTAssertTrue(response.suffix(body.count).elementsEqual(body))
    }
}
