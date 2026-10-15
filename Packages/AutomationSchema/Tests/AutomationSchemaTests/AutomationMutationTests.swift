import DisplayDomain
import XCTest
@testable import AutomationSchema

@MainActor private final class PreparingContrast: AutomationEnvironment {
    let surface = AutomationSurface.console
    let generation = AutomationExecutionGeneration()
    let token: UUID
    var readStarted: CheckedContinuation<Void, Never>?
    var preparation: CheckedContinuation<Void, Never>?
    var writes = 0
    init() { token = generation.current }
    func displaySet() async -> AutomationDisplaySet {
        .init(candidates: [.init(id: .init(rawValue: "desk"), name: "Desk", availability: .active)])
    }
    func readContrast(of display: AutomationDisplayCandidate) async throws(AutomationIssue) -> BrightnessReadback {
        await withCheckedContinuation { preparation = $0; readStarted?.resume(); readStarted = nil }
        return .ddc(current: 20, max: 100)
    }
    func validateMutation() async throws(AutomationIssue) {
        if let issue = generation.issue(for: token) { throw issue }
    }
    func writeContrast(_ level: AutomationLevel, to display: AutomationDisplayCandidate) async throws(AutomationIssue) -> BrightnessWriteReport {
        writes += 1
        return .init(requested: level, accepted: true, readback: .none)
    }
    func waitForRead() async {
        if preparation != nil { return }
        await withCheckedContinuation { readStarted = $0 }
    }
}

@MainActor final class AutomationMutationTests: XCTestCase {
    func testCancellationAfterPrerequisiteReadPreventsContrastMutation() async {
        let fake = PreparingContrast()
        let action = Task { await AutomationEngine(environment: fake).run(.byID(.setContrast(.maximum), .init(rawValue: "desk"))) }
        await fake.waitForRead()
        action.cancel(); fake.preparation?.resume()
        let result = await action.value
        XCTAssertEqual(fake.writes, 0); XCTAssertEqual(result.issue?.code, .busy)
    }
    func testConfigurationChangeOrShutdownInvalidatesPreparedMutation() async {
        let fake = PreparingContrast()
        let action = Task { await AutomationEngine(environment: fake).run(.byID(.setContrast(.maximum), .init(rawValue: "desk"))) }
        await fake.waitForRead()
        fake.generation.invalidate(); fake.preparation?.resume()
        let result = await action.value
        XCTAssertEqual(fake.writes, 0); XCTAssertEqual(result.issue?.code, .busy)
    }
}
