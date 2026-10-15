import Foundation
import XCTest
@testable import AutomationSchema

final class DiagnosticExportTests: XCTestCase {
    func testEveryArtifactAndFilenameIsSanitizedBeforeArchiving() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "12345678-ABCD-4321-ABCD-1234567890AB"
        try Data("{\"serialNumber\":123,\"token\":\"secret\"}".utf8).write(to: root.appendingPathComponent("\(id).json"))
        try Data("{\"authorization\":\"secret\"}\n".utf8).write(to: root.appendingPathComponent("audit.jsonl"))
        try Data("Serial Number: 789\nIOService:/path\n\"IODisplayEDID\" = <00112233>\n".utf8).write(to: root.appendingPathComponent("ioreg.txt"))
        try Data([0xff, 0x00]).write(to: root.appendingPathComponent("binary.bin"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("external"), withDestinationURL: URL(fileURLWithPath: "/does/not/exist"))
        let manifest = try DiagnosticExport.redactStagedDirectory(root, privacy: .init())
        XCTAssertEqual(manifest.omittedArtifacts, ["binary.bin", "external"])
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 3)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for secret in ["secret", "123", "789", "IOService:/path", "00112233", id] {
                XCTAssertFalse(text.contains(secret), secret)
                XCTAssertFalse(file.lastPathComponent.contains(id))
            }
        }
    }

    func testSourcesStayUntouchedAndMalformedStructuredFileIsOmitted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("invalid json".utf8).write(to: root.appendingPathComponent("bad.json"))
        let manifest = try DiagnosticExport.redactStagedDirectory(root, privacy: .init())
        XCTAssertEqual(manifest.omittedArtifacts, ["bad.json"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("bad.json").path))
    }
}
