import XCTest
@testable import TopologyCore
import AutomationSchema
import DisplayDomain

final class IntegrationPlanTests: XCTestCase {
    let id = DisplayRecordID(rawValue: "desk")
    private var set: AutomationDisplaySet { .init(candidates: [.init(id: id, name: "Desk", availability: .active)]) }
    func testSafeStartupVetoesEveryEnabledHook() throws {
        for phase in IntegrationHookPhase.allCases {
            let config = IntegrationConfiguration(displays: [.init(id: id, enabled: true, hooks: [.init(phase: phase, enabled: true, action: .notification(name: "n", payload: "[*:EVENT_HOOK:*]"))])])
            let event = IntegrationHookEvent(phase: phase, display: id)
            XCTAssertNil(try IntegrationPlan.hook(event, configuration: config, displays: set, safeStartup: true))
            XCTAssertNotNil(try IntegrationPlan.hook(event, configuration: config, displays: set, safeStartup: false))
        }
    }
    func testControllerOffPausedAndNoOpNeverDispatch() throws {
        var config = IntegrationConfiguration(displays: [.init(id: id, hooks: [.init(phase: .hardReconnect, enabled: true, action: .notification(name: "n", payload: "p"))])])
        let event = IntegrationHookEvent(phase: .hardReconnect, display: id)
        XCTAssertNil(try IntegrationPlan.hook(event, configuration: config, displays: set, safeStartup: false))
        config.displays[0].enabled = true; config.displays[0].hooks[0].enabled = false
        XCTAssertNil(try IntegrationPlan.hook(event, configuration: config, displays: set, safeStartup: false))
        config.displays[0].hooks[0].enabled = true; config.displays[0].hooks[0].action = .none
        XCTAssertNil(try IntegrationPlan.hook(event, configuration: config, displays: set, safeStartup: false))
    }
    func testNoRuntimeIDUsesEmptyTokenAndKeepsStableTarget() throws {
        let config = IntegrationConfiguration(displays: [.init(id: id, enabled: true, hooks: [.init(phase: .hardDisconnect, enabled: true, action: .notification(name: "n", payload: "[*:STABLE_ID:*]/[*:DISPLAY_ID:*]"))])])
        let action = try IntegrationPlan.hook(.init(phase: .hardDisconnect, display: id), configuration: config,
            displays: .init(candidates: [.init(id: id, name: "Desk", availability: .disconnected)]), safeStartup: false)
        XCTAssertEqual(action?.target, id); XCTAssertEqual(action?.action, .notification(name: "n", payload: "desk/"))
    }
    func testPollingRequiresExplicitIntervalEnabledParserAndConnectedTarget() throws {
        let control = IntegrationControl(name: "b", kind: .boolean, enabled: true, readAction: .process(executable: "/owned/tool", arguments: [], budget: .init(timeoutSeconds: 2, maximumOutputBytes: 20)), readback: .boolean(on: "ON", off: "OFF", regex: false), pollingSeconds: 0.125, pollingFailurePolicy: .stop)
        var config = IntegrationConfiguration(displays: [.init(id: id, enabled: true, controls: [control])])
        XCTAssertEqual(try IntegrationPlan.polls(configuration: config, displays: set, safeStartup: false, sleeping: false).first?.seconds, 0.125)
        XCTAssertTrue(try IntegrationPlan.polls(configuration: config, displays: set, safeStartup: true, sleeping: false).isEmpty)
        XCTAssertTrue(try IntegrationPlan.polls(configuration: config, displays: set, safeStartup: false, sleeping: true).isEmpty)
        XCTAssertTrue(try IntegrationPlan.polls(configuration: config, displays: .init(candidates: []), safeStartup: false, sleeping: false).isEmpty)
        config.displays[0].controls[0].readback = nil
        XCTAssertTrue(try IntegrationPlan.polls(configuration: config, displays: set, safeStartup: false, sleeping: false).isEmpty)
        XCTAssertEqual(config.displays[0].controls[0].readAction, control.readAction)
    }
    func testRangedBrightnessProducesTheSharedCommandWithoutConversion() throws {
        let level = AutomationLevel(normalized: 0.42)!
        let action = try IntegrationActionPolicy.prepare(.brightness(.hardware), context: .init(display: set.candidates[0], value: "42", input: .level(level)))
        XCTAssertEqual(action.action, .command(.setBrightness(level, method: .hardware)))
        XCTAssertThrowsError(try IntegrationActionPolicy.prepare(.brightness(.hardware), context: .init(display: set.candidates[0])))
    }
}
