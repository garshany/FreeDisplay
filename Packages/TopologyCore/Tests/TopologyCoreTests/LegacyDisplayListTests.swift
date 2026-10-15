import AutomationSchema
import DisplayDomain
import XCTest
@testable import TopologyCore

private struct ListEnvironment: AutomationEnvironment {
    let surface = AutomationSurface.cli
    let set: AutomationDisplaySet
    func displaySet() async -> AutomationDisplaySet { set }
}

final class LegacyDisplayListTests: XCTestCase, @unchecked Sendable {
    func testLegacyArrayAndFieldsSurviveStandaloneAndAppIPCRoundTrip() async throws {
        let observation = DisplayObservation(recordID: .init(rawValue: "screen"), cgDisplayID: 7,
            isActive: true, origin: .init(x: -1920, y: 0),
            mode: .init(pixelWidth: 1920, pixelHeight: 1080, pointWidth: 1920, pointHeight: 1080, refreshHz: 60, isHiDPI: false), isMain: true, displayClass: .external,
            generation: .initial)
        let record = DisplayRecord(id: .init(rawValue: "registry-screen"), alias: "Desk", tags: ["work"], fingerprint: .init())
        let offline = ManagedOfflineDisplay(recordID: .init(rawValue: "off"), cgID: 8, name: "Off", displayClass: .external)
        let set = AutomationDisplayCatalog.displaySet(displays: [observation], offline: [offline],
            name: { _ in "Desk" }, record: { $0 == observation.recordID ? record : nil }, groups: [],
            pointerDisplayID: nil, generation: 1)
        let result = await AutomationEngine(environment: ListEnvironment(set: set)).run(.init(.listDisplays))
        let response = LocalAutomationProtocol.Response(id: UUID(), payload: .result(result))
        let decoded = try JSONDecoder().decode(LocalAutomationProtocol.Response.self, from: JSONEncoder().encode(response))
        guard case .result(let ipcResult) = decoded.payload else { return XCTFail() }
        for pathResult in [result, ipcResult] {
            let rows = try LegacyDisplayListRenderer.rows(from: pathResult)
            let array = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(rows)) as? [[String: Any]])
            let live = try XCTUnwrap(array.first { $0["id"] as? String == "screen" })
            XCTAssertEqual(live["recordId"] as? String, "registry-screen")
            XCTAssertEqual(live["active"] as? Bool, true); XCTAssertEqual(live["main"] as? Bool, true)
            XCTAssertEqual(live["managedOffline"] as? Bool, false)
            XCTAssertEqual(live["displayClass"] as? String, "external")
            XCTAssertEqual(live["mode"] as? String, "1920x1080@60")
            XCTAssertEqual(live["origin"] as? String, "(-1920,0)")
            XCTAssertEqual(array.first { $0["id"] as? String == "off" }?["managedOffline"] as? Bool, true)
        }
        // The explicitly named command still exposes the typed envelope.
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
    }
}
