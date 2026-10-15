import DisplayDomain
import XCTest
@testable import AutomationSchema

final class AutomationWireTests: XCTestCase {
    func testEveryRequestVariantRoundTripsWithoutTransportState() throws {
        let mode = DisplayMode(pixelWidth: 3840, pixelHeight: 2160, pointWidth: 1920, pointHeight: 1080,
                               refreshHz: 60, isHiDPI: true, bitDepth: 10)
        let commands: [AutomationCommand] = [
            .listDisplays, .getCapabilities, .getBrightness(method: .hardware), .setBrightness(.minimum, method: .ddc),
            .adjustBrightness(AutomationLevelDelta(normalized: 4)!, method: .software),
            .listModes, .getMode, .setMode(.exact(mode), keepWithoutConfirmation: true),
            .setMode(.logical(width: 1920, height: 1080, refreshHz: nil, hiDPI: true)), .setMain,
            .listColorProfiles, .getColorProfile, .setColorProfile(.name("Studio")),
            .setColorProfile(.path("/Library/ColorSync/Profiles/Studio.icc")), .resetColorProfile,
            .reconnectAll, .disconnect,
        ]
        let selectors: [AutomationSelector] = [.display(.id(.init(rawValue: "cg:desk"))), .display(.role(.builtin)),
                                                .cgDisplayID(1), .group("Стол"), .nameContains("Écran")]
        for command in commands {
            for selector in selectors {
                let request = AutomationRequest(command, target: selector, targetText: "Стол", dryRun: true)
                let data = try JSONEncoder().encode(request)
                XCTAssertEqual(try JSONDecoder().decode(AutomationRequest.self, from: data), request)
            }
        }
    }

    func testDeltaDecodingUsesTheSameFiniteInvariantAsParsing() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(AutomationLevelDelta.self, from: Data("5".utf8)).normalized, 5)
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "INF", negativeInfinity: "-INF", nan: "NaN")
        XCTAssertThrowsError(try decoder.decode(AutomationLevelDelta.self, from: Data("\"INF\"".utf8)))
        XCTAssertThrowsError(try decoder.decode(AutomationLevelDelta.self, from: Data("\"NaN\"".utf8)))
    }

    func testLegacyHTTPResponseKeepsKeysAndMapsRefusalToFailureStatus() throws {
        let envelope = ResultEnvelope(transactionId: "t", status: .failed, actor: .httpAPI,
                                      requestedAt: Date(timeIntervalSince1970: 0), topologyGeneration: 1)
        let result = AutomationResult(command: .setBrightness, envelope: envelope,
                                      issue: .init(.methodUnavailable, "hardware unavailable"))
        let response = AutomationHTTPResponse(result, style: .legacyBrightness)
        XCTAssertEqual(response.status, 422)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(json["status"] as? String, "rejected")
        XCTAssertEqual(json["physicalEffectVerified"] as? Bool, false)
        XCTAssertEqual(json["code"] as? String, "methodUnavailable")
        XCTAssertEqual(AutomationHTTPResponse(result).body, result.jsonData(prettyPrinted: false))
    }
}
