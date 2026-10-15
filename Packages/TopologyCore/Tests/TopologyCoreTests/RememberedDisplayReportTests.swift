import XCTest
import DisplayDomain
@testable import TopologyCore

final class RememberedDisplayReportTests: XCTestCase {
    private func entry() -> RememberedDisplay {
        let record = DisplayRecord(id: .init(rawValue: "record:A"), alias: "Desk",
                                   fingerprint: .init(vendorID: 123, productID: 456, serialNumber: "789"),
                                   displayClass: .external)
        return RememberedDisplay(id: record.id.rawValue, record: record, isRegistered: true,
                                 observationIDs: [.init(rawValue: "cg:old"), .init(rawValue: "cg:new")],
                                 status: .notConnected, offlineEntries: [])
    }

    func testSavedReportExportsIdentityAndAnchorsWithoutInventingCurrentState() throws {
        let anchors = try LuminanceAnchorSettings().setting(.sdrMaximum, nits: 350, basis: .userEstimate).settings
        let facts = entry().savedReportFacts(appVersion: "1", generatedAt: "today", name: "Desk", lastSeen: "yesterday",
                                             luminanceSettings: ["cg:old": anchors])
        XCTAssertEqual(facts.presence, .savedOnly)
        XCTAssertEqual(facts.vendorNumber, 123)
        XCTAssertEqual(facts.modelNumber, 456)
        XCTAssertEqual(facts.serialNumber, 789)
        XCTAssertEqual(facts.uuid, "new, old")
        XCTAssertEqual(facts.luminanceAnchors, anchors)
        XCTAssertNil(facts.cgDisplayID)
        XCTAssertNil(facts.currentMode)
        XCTAssertNil(facts.hdrOutput)
        XCTAssertNil(facts.brightnessLevel)
        let report = DisplayInformationReport.build(facts)
        XCTAssertTrue(report.plainText().contains("only saved information is shown"))
        XCTAssertTrue(report.plainText().contains("350 nits"))
        XCTAssertFalse(report.sections.contains { $0.title == "Current mode" })
        let privateCopy = DiagnosticPrivacy().redactedReport(report).plainText()
        XCTAssertFalse(privateCopy.contains("new, old"))
        XCTAssertFalse(privateCopy.contains("789"))
    }

    func testConflictingHistoricalAnchorsAreNotSilentlySelected() throws {
        let a = try LuminanceAnchorSettings().setting(.sdrMaximum, nits: 350).settings
        let b = try LuminanceAnchorSettings().setting(.sdrMaximum, nits: 400).settings
        let facts = entry().savedReportFacts(appVersion: "1", generatedAt: "today", name: "Desk", lastSeen: nil,
                                             luminanceSettings: ["cg:old": a, "cg:new": b])
        XCTAssertNil(facts.luminanceAnchors)
        let same = entry().savedReportFacts(appVersion: "1", generatedAt: "today", name: "Desk", lastSeen: nil,
                                            luminanceSettings: ["cg:old": a, "cg:new": a])
        XCTAssertEqual(same.luminanceAnchors, a)
    }
}
