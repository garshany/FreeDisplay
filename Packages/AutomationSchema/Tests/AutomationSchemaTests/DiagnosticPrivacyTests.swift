import XCTest
import DisplayDomain
@testable import AutomationSchema

final class DiagnosticPrivacyTests: XCTestCase {
    let uuid = "12345678-ABCD-4321-ABCD-1234567890AB"

    func testSecretsURLsAndHardwareAreRemovedAtIngestion() {
        let source = "token=abc password='hello world' Bearer secret https://user:pass@host/path?q=key UUID=\(uuid) Serial number: 98765\nIOService:/Apple/Display"
        let record = DiagnosticRecord(source)
        for secret in ["abc", "hello world", "Bearer secret", "user:pass", "host/path", uuid, "98765", "Apple/Display"] {
            XCTAssertFalse(record.message.contains(secret), secret)
        }
    }

    func testKnownUnlabelledSecretsAndSerials() {
        let policy = DiagnosticPrivacy(knownSecrets: ["shared-secret"], knownSerials: ["MONITOR-7"])
        XCTAssertEqual(policy.redact("failure shared-secret MONITOR-7"), "failure <redacted> <redacted>")
    }

    func testIdentifierOptInNeverEnablesCredentialExport() {
        let policy = DiagnosticPrivacy(removeSerials: false, removeUUIDs: false, removeRegistryPaths: false)
        let result = policy.redact("uuid=\(uuid) Serial: 42\ntoken=private IOService:/path")
        XCTAssertTrue(result.contains(uuid)); XCTAssertTrue(result.contains("42")); XCTAssertTrue(result.contains("IOService:/path"))
        XCTAssertFalse(result.contains("private"))
    }

    func testJSONRecursesAndRetainsMachineReadableShape() throws {
        let source: [String: Any] = ["serialNumber": 123, "nested": ["authToken": "secret", "uuid": uuid],
                                     "value": 0.4, "active": true, "url": "https://host/token", "edid": "base64-secret"]
        let data = try JSONSerialization.data(withJSONObject: source)
        let redacted = try XCTUnwrap(DiagnosticPrivacy().redactedArtifact(data, pathExtension: "json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: redacted) as? [String: Any])
        XCTAssertEqual(object["serialNumber"] as? String, "<redacted>")
        XCTAssertEqual(object["value"] as? Double, 0.4)
        XCTAssertEqual(object["active"] as? Bool, true)
        for secret in ["secret", uuid, "host/token"] { XCTAssertFalse(String(decoding: redacted, as: UTF8.self).contains(secret)) }
    }

    func testJSONLStaysOneObjectPerLineAndMalformedFileIsOmitted() throws {
        let source = Data("{\"token\":\"secret\"}\n{\"value\":1}\n".utf8)
        let data = try XCTUnwrap(DiagnosticPrivacy().redactedArtifact(source, pathExtension: "jsonl"))
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        for line in lines { XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8))) }
        XCTAssertNil(DiagnosticPrivacy().redactedArtifact(Data("{bad".utf8), pathExtension: "jsonl"))
    }

    func testBinaryPlistIsInspectedAndOpaqueEDIDCannotLeak() throws {
        let source: [String: Any] = ["DisplaySerialNumber": 1234, "EDID": Data([1, 2, 3]), "name": "Display", "UUID": uuid]
        let data = try PropertyListSerialization.data(fromPropertyList: source, format: .binary, options: 0)
        let redacted = try XCTUnwrap(DiagnosticPrivacy().redactedArtifact(data, pathExtension: "plist"))
        let result = try XCTUnwrap(PropertyListSerialization.propertyList(from: redacted, format: nil) as? [String: Any])
        XCTAssertEqual(result["DisplaySerialNumber"] as? String, "<redacted>")
        XCTAssertEqual(result["EDID"] as? String, "<redacted>")
        XCTAssertEqual(result["name"] as? String, "Display")
    }

    func testUnknownBinaryAndMalformedStructuredArtifactsAreOmitted() {
        XCTAssertNil(DiagnosticPrivacy().redactedArtifact(Data([0xff, 0x00]), pathExtension: "bin"))
        XCTAssertNil(DiagnosticPrivacy().redactedArtifact(Data("broken".utf8), pathExtension: "json"))
        XCTAssertNil(DiagnosticPrivacy().redactedArtifact(Data("<plist><dict>".utf8), pathExtension: "plist"))
    }

    func testRedactedDictionaryKeysNeverCrashOrDropValues() {
        let result = DiagnosticPrivacy().object([uuid: 1, "87654321-ABCD-4321-ABCD-1234567890AB": 2]) as? [String: Any]
        XCTAssertEqual(result?.count, 2)
        XCTAssertFalse(result?.keys.contains(uuid) ?? true)
    }

    func testLocalizedReportRowsAndRawEDIDFollowSameOptions() {
        let report = InfoReport(title: "test", sections: [.init(title: "данные", rows: [
            .init("Серийный номер", "987"), .init("UUID", uuid), .init("Путь", "IOService:/A"), .init("Base64", "opaque"), .init("Mode", "1920×1080")])])
        let result = DiagnosticPrivacy().redactedReport(report, serialLabels: ["Серийный номер"], uuidLabels: ["UUID"], registryLabels: ["Путь"], opaqueLabels: ["Base64"]).plainText()
        for secret in ["987", uuid, "IOService:/A", "opaque"] { XCTAssertFalse(result.contains(secret)) }
        XCTAssertTrue(result.contains("1920×1080"))
    }

    func testOpaqueReportSectionsAreOmittedOnlyWhenIdentifiersAreRemoved() {
        let report = InfoReport(title: "test", sections: [.init(title: "EDID — extension", rows: [.init("Tile", "encoded serial")]), .init(title: "Mode", rows: [.init("Size", "1920")])])
        let hidden = DiagnosticPrivacy().redactedReport(report, serialLabels: [], uuidLabels: [], registryLabels: [], opaqueLabels: [], opaqueSectionPrefixes: ["EDID"])
        XCTAssertEqual(hidden.sections.map(\.title), ["Mode"])
        let kept = DiagnosticPrivacy(removeSerials: false, removeUUIDs: false).redactedReport(report, serialLabels: [], uuidLabels: [], registryLabels: [], opaqueLabels: [], opaqueSectionPrefixes: ["EDID"])
        XCTAssertEqual(kept.sections.count, 2)
    }

    func testBufferCapacityAndClear() {
        var buffer = DiagnosticBuffer(capacity: 2)
        for number in 0..<3 { buffer.append(DiagnosticRecord(String(number))) }
        XCTAssertEqual(buffer.records.map(\.message), ["1", "2"])
        buffer.capacity = 1; XCTAssertEqual(buffer.records.map(\.message), ["2"])
        buffer.clear(); XCTAssertTrue(buffer.records.isEmpty)
        buffer.capacity = nil
        for number in 0..<1002 { buffer.append(DiagnosticRecord(String(number))) }
        XCTAssertEqual(buffer.records.count, 1002)
    }

    func testCLIStderrLoggingLeavesArgumentsAndJSONUnchanged() throws {
        let options = try CLIDiagnosticOptions.parse(["list", "--json", "-v2e"])
        XCTAssertEqual(options.stream, .stderr)
        XCTAssertEqual(options.arguments, ["list", "--json"])
        XCTAssertEqual(try CLIDiagnosticOptions.parse(["--log-output", "off", "list"]).stream, .off)
        XCTAssertEqual(try CLIDiagnosticOptions.parse(["list", "-v"]).stream, .stdout)
    }

    func testCLIConflictingInvalidAndMissingModesRefuseBeforeProviders() {
        for arguments in [["list", "--json", "-v"], ["-v", "listen"], ["-v2e", "-v"], ["--log-output"], ["--log-output", "bogus"]] {
            XCTAssertThrowsError(try CLIDiagnosticOptions.parse(arguments))
        }
    }
}
