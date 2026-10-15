import Foundation
import XCTest
@testable import AutomationSchema

final class TVDiscoveryTests: XCTestCase {
    private func request(_ family: TVFamily = .lgWebOS) throws -> TVDiscoveryRequest {
        try TVDiscoveryRequest(family: family, window: 19, maximumResponseDelaySeconds: 7)
    }
    private func response(st: String = "urn:lge-com:service:webos-second-screen:1", server: String = "webOS", host: String = "192.0.2.4") -> Data {
        Data("HTTP/1.1 200 OK\r\nST: \(st)\r\nUSN: uuid:fixture\r\nLOCATION: http://\(host):1234/device.xml\r\nSERVER: \(server)\r\n\r\n".utf8)
    }
    func testSearchUsesCallerSuppliedMXAndSeparateDiscoveryWindow() throws {
        let request = try request()
        let packet = String(decoding: request.searchPacket, as: UTF8.self)
        XCTAssertTrue(packet.contains("MX: 7\r\n"))
        XCTAssertEqual(request.window, 19)
        XCTAssertTrue(packet.contains("ST: urn:lge-com:service:webos-second-screen:1\r\n"))
        XCTAssertTrue(String(decoding: try self.request(.samsungTizen).searchPacket, as: UTF8.self).contains("ST: ssdp:all\r\n"))
        XCTAssertThrowsError(try TVDiscoveryRequest(family: .lgWebOS, window: 0, maximumResponseDelaySeconds: 1))
        XCTAssertThrowsError(try TVDiscoveryRequest(family: .lgWebOS, window: 1, maximumResponseDelaySeconds: 0))
    }
    func testAdvertisementProducesOnlyAnUntrustedAddressHint() throws {
        let request = try request()
        let candidate = try XCTUnwrap(request.candidate(from: response()))
        XCTAssertEqual(candidate.host, "192.0.2.4")
        XCTAssertEqual(candidate.serviceID, "uuid:fixture")
        XCTAssertEqual(candidate.location.port, 1234, "descriptor port is not the remote WebSocket service port")
        XCTAssertNil(request.candidate(from: response(st: "urn:schemas-upnp-org:device:MediaRenderer:1", server: "Other")))
    }
    func testSamsungHintsDoNotClaimAnLGControllerOrTizenCapabilities() throws {
        let samsung = try request(.samsungTizen)
        XCTAssertNotNil(samsung.candidate(from: response(st: "urn:schemas-upnp-org:device:MediaRenderer:1", server: "Samsung SmartTV")))
        XCTAssertNil(samsung.candidate(from: response()))
    }
    func testMalformedDuplicateAndCredentialBearingAdvertisementsAreIgnored() throws {
        let request = try request()
        for text in ["", "NOTIFY * HTTP/1.1\r\n\r\n", "HTTP/1.1 200 OK\r\nBadHeader\r\n\r\n",
                     "HTTP/1.1 200 OK\r\nST: urn:lge-com:service:webos-second-screen:1\r\nUSN: x\r\nLOCATION: http://user:secret@tv.invalid/info\r\n\r\n",
                     "HTTP/1.1 200 OK\r\nST: urn:lge-com:service:webos-second-screen:1\r\nUSN: x\r\nLOCATION: http://tv.invalid\r\nlocation: http://other.invalid\r\n\r\n"] {
            XCTAssertNil(request.candidate(from: Data(text.utf8)))
        }
    }
    func testCancelledDiscoveryRejectsLateHintsAndKeepsConflictingAddressesSeparate() throws {
        var state = TVDiscoveryState()
        let request = try request()
        let first = try XCTUnwrap(request.candidate(from: response()))
        let old = state.begin()
        state.cancel()
        state.add(first, generation: old)
        XCTAssertTrue(state.candidates.isEmpty)
        let current = state.begin()
        state.add(first, generation: current)
        state.add(first, generation: current)
        let changed = try XCTUnwrap(request.candidate(from: response(host: "192.0.2.5")))
        state.add(changed, generation: current)
        XCTAssertEqual(state.candidates.count, 2)
        state.finish(generation: current)
        XCTAssertEqual(state.phase, .finished)
        state.add(first, generation: current)
        XCTAssertEqual(state.candidates.count, 2)
    }
}
