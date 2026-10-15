import XCTest
@testable import AutomationSchema
import DisplayDomain

final class IntegrationActionTests: XCTestCase {
    private let display = AutomationDisplayCandidate(id: .init(rawValue: "desk"), name: "Desk $(touch /tmp/never); ' &\n", availability: .active)
    private let budget = IntegrationBudget(timeoutSeconds: 12, maximumOutputBytes: 4096)
    func testNoOpNeedsNoBudgetAndNeverExpands() throws {
        let result = try IntegrationActionPolicy.prepare(.none, context: .init(display: display))
        XCTAssertEqual(result.action, .none)
        XCTAssertEqual(result.target, display.id)
    }
    func testProcessKeepsHostileMetadataInOneArgument() throws {
        let result = try IntegrationActionPolicy.prepare(.process(executable: "/usr/bin/tool", arguments: ["--name", "[*:DEVICE_NAME:*]", "[*:DISPLAY_ID:*]"], budget: budget), context: .init(display: display))
        XCTAssertEqual(result.action, .process(executable: "/usr/bin/tool", arguments: ["--name", display.name, ""], budget: budget))
    }
    func testInterpreterMustBeExplicitAndInlineCodeIsRejected() throws {
        XCTAssertNoThrow(try IntegrationActionPolicy.prepare(.process(executable: "/bin/bash", arguments: ["/owned/script.sh", "[*:DEVICE_NAME:*]"], budget: budget), context: .init(display: display)))
        for arguments in [["-c", "[*:DEVICE_NAME:*]"], ["-e", "[*:DEVICE_NAME:*]"]] {
            XCTAssertThrowsError(try IntegrationActionPolicy.prepare(.process(executable: "/bin/bash", arguments: arguments, budget: budget), context: .init(display: display)))
        }
    }
    func testRelativeExecutableAndNULAreRejected() {
        for action in [IntegrationAction.process(executable: "tool", arguments: [], budget: budget), .process(executable: "/tool", arguments: ["x\0y"], budget: budget)] {
            XCTAssertThrowsError(try IntegrationActionPolicy.prepare(action, context: .init(display: display)))
        }
    }
    func testBudgetsHaveNoChosenDefaultsAndRejectUnusableValues() {
        for timeout in [0, -1, Double.infinity, Double.nan, Double.greatestFiniteMagnitude] {
            XCTAssertThrowsError(try IntegrationBudget(timeoutSeconds: timeout, maximumOutputBytes: 1).validate())
        }
        XCTAssertThrowsError(try IntegrationBudget(timeoutSeconds: 1, maximumOutputBytes: 0).validate())
        XCTAssertNoThrow(try IntegrationBudget(timeoutSeconds: 0.001, maximumOutputBytes: 1).validate())
    }
    func testTimingRejectsUnrepresentableDurationsWithoutInventingACadence() {
        XCTAssertFalse(IntegrationTiming.isRepresentable(Double.greatestFiniteMagnitude))
        XCTAssertFalse(IntegrationTiming.isRepresentable(0))
        XCTAssertTrue(IntegrationTiming.isRepresentable(0, allowZero: true))
        XCTAssertTrue(IntegrationTiming.isRepresentable(0.125))
    }
    func testParametersAreCaseSensitiveAndNonrecursive() throws {
        let context = IntegrationContext(display: display, parameters: [.init("A", "[*:B:*]"), .init("B", "done")])
        XCTAssertEqual(try context.expand("[*:A:*] [*:B:*]"), "[*:B:*] done")
        XCTAssertThrowsError(try context.expand("[*:a:*]"))
    }
    func testDuplicateBlankAndReservedParametersRefuse() {
        for parameters in [[IntegrationParameter("", "x")], [.init("A", "a"), .init("A", "b")], [.init("VALUE", "42")]] {
            XCTAssertThrowsError(try IntegrationContext(display: display, parameters: parameters).expand("x"))
        }
    }
    func testURLMetadataCannotChangeTheHostOrAddQueryFields() throws {
        let result = try IntegrationActionPolicy.prepare(.http(url: "https://example.invalid/read?name=[*:DEVICE_NAME:*]", budget: budget), context: .init(display: display))
        guard case .http(let url, _) = result.action else { return XCTFail() }
        let components = try XCTUnwrap(URLComponents(string: url))
        XCTAssertEqual(components.host, "example.invalid")
        XCTAssertEqual(components.queryItems?.count, 1)
        XCTAssertEqual(components.queryItems?.first?.value, display.name)
        XCTAssertThrowsError(try IntegrationActionPolicy.prepare(.http(url: "https://[*:DEVICE_NAME:*]/", budget: budget), context: .init(display: display)))
    }
    func testNotificationNameIsLiteralAndPayloadExpands() throws {
        let result = try IntegrationActionPolicy.prepare(.notification(name: "org.example.command", payload: "[*:STABLE_ID:*]"), context: .init(display: display))
        XCTAssertEqual(result.action, .notification(name: "org.example.command", payload: "desk"))
        XCTAssertThrowsError(try IntegrationActionPolicy.prepare(.notification(name: "[*:DEVICE_NAME:*]", payload: "x"), context: .init(display: display)))
    }
    func testTypedActionsKeepSharedUnitsAndRejectRecursiveConnectionCommands() throws {
        let command = AutomationCommand.setBrightness(AutomationLevel(normalized: 0.4)!, method: .hardware)
        XCTAssertEqual(try IntegrationActionPolicy.prepare(.command(command), context: .init(display: display)).action, .command(command))
        for command in [AutomationCommand.disconnect, .reconnectAll] {
            XCTAssertThrowsError(try IntegrationActionPolicy.prepare(.command(command), context: .init(display: display)))
        }
    }
    func testSentNotificationAndNonzeroExitHaveNoReadableDeviceValue() {
        XCTAssertNil(IntegrationReceipt(.dispatched, stdout: "0.4").readableText)
        XCTAssertNil(IntegrationReceipt(.processExited, exitCode: 1, stdout: "0.4").readableText)
        XCTAssertEqual(IntegrationReceipt(.processExited, exitCode: 0, stdout: "a", stderr: "b").readableText, "ab")
        XCTAssertNil(IntegrationReceipt(.transportCompleted, httpStatus: 500, stdout: "0.4").readableText)
        XCTAssertNil(IntegrationReceipt(.timedOut, processMayBeRunning: true).readableText)
    }
    func testActionsAndReceiptsRoundTrip() throws {
        let actions: [IntegrationAction] = [.none, .command(.getCapabilities), .process(executable: "/tool", arguments: ["a"], budget: budget), .http(url: "https://example.invalid/", budget: budget), .openURL("app://open"), .notification(name: "n", payload: "p")]
        for action in actions { XCTAssertEqual(try JSONDecoder().decode(IntegrationAction.self, from: JSONEncoder().encode(action)), action) }
        let receipt = IntegrationReceipt(.cancelled, processMayBeRunning: true, detail: "Termination requested; no rollback")
        XCTAssertEqual(try JSONDecoder().decode(IntegrationReceipt.self, from: JSONEncoder().encode(receipt)), receipt)
    }
}
