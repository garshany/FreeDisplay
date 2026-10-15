import XCTest
@testable import AutomationSchema

final class DiagnosticLoggingTests: XCTestCase {
    let uuid = "12345678-ABCD-4321-ABCD-1234567890AB"
    func testSecretsURLsAndHardwareAreRemovedAtIngestion() {
        let source = "token=abc password='hello world' Bearer secret https://user:pass@host/path?q=key UUID=\(uuid) Serial number: 98765\nIOService:/Apple/Display"
        let record = DiagnosticRecord(source)
        for secret in ["abc", "hello world", "Bearer secret", "user:pass", "host/path", uuid, "98765", "Apple/Display"] {
            XCTAssertFalse(record.message.contains(secret), secret)
        }
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
