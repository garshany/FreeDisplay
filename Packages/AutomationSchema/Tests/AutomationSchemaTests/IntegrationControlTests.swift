import XCTest
@testable import AutomationSchema
import DisplayDomain

final class IntegrationControlTests: XCTestCase {
    func testNumericReadbackRequiresExactlyOneFiniteValue() throws {
        let parser = IntegrationReadback.ranged(multiplier: 100, regex: nil, capture: 0)
        XCTAssertEqual(try parser.parse(" 42\n"), .level(AutomationLevel(normalized: 0.42)!))
        for text in ["1 2", "value=42", "nan", "inf", "", "101", "-1"] { XCTAssertThrowsError(try parser.parse(text)) }
    }
    func testCaptureGroupAndMismatchAreExplicit() throws {
        let parser = IntegrationReadback.ranged(multiplier: 100, regex: #"level=(\d+)"#, capture: 1)
        XCTAssertEqual(try parser.parse("other=50 level=42"), .level(AutomationLevel(normalized: 0.42)!))
        for text in ["level=1 level=2", "42", "level=nan"] { XCTAssertThrowsError(try parser.parse(text)) }
        XCTAssertThrowsError(try IntegrationReadback.ranged(multiplier: 100, regex: "[", capture: 1).parse("42"))
        XCTAssertThrowsError(try IntegrationReadback.ranged(multiplier: 100, regex: "(42)", capture: 2).parse("42"))
        XCTAssertThrowsError(try IntegrationReadback.ranged(multiplier: 0, regex: nil, capture: 0).parse("42"))
    }
    func testBooleanNewlinesAndCollisionAreNotGuessed() throws {
        let exact = IntegrationReadback.boolean(on: "ON\n", off: "OFF\n", regex: false)
        XCTAssertEqual(try exact.parse("ON\n"), .boolean(true))
        XCTAssertThrowsError(try exact.parse("ON"))
        XCTAssertThrowsError(try IntegrationReadback.boolean(on: "ON", off: "ON", regex: false).parse("ON"))
        XCTAssertThrowsError(try IntegrationReadback.boolean(on: "yes", off: "no", regex: true).parse("yes no"))
    }
    func testRangedFormattingRejectsUnusableSettings() throws {
        XCTAssertEqual(try IntegrationControlKind.ranged(multiplier: 100, decimalPlaces: 0).text(for: .level(AutomationLevel(normalized: 0.42)!)), "42")
        XCTAssertEqual(try IntegrationControlKind.ranged(multiplier: 100, decimalPlaces: 2).text(for: .level(AutomationLevel(normalized: 0.42)!)), "42.00")
        XCTAssertThrowsError(try IntegrationControlKind.ranged(multiplier: 0, decimalPlaces: 0).text(for: .level(.minimum)))
        XCTAssertThrowsError(try IntegrationControlKind.ranged(multiplier: 100, decimalPlaces: -1).text(for: .level(.minimum)))
        XCTAssertThrowsError(try IntegrationControlKind.boolean.text(for: .level(.minimum)))
    }
    func testFreshnessRequiresOwnerConfiguration() {
        let sample = IntegrationSample(value: .boolean(true), at: Date(timeIntervalSince1970: 10), source: .feed)
        XCTAssertFalse(sample.isFresh(at: sample.at, for: nil))
        XCTAssertTrue(sample.isFresh(at: Date(timeIntervalSince1970: 12), for: 2))
        XCTAssertFalse(sample.isFresh(at: Date(timeIntervalSince1970: 13), for: 2))
        XCTAssertFalse(sample.isFresh(at: Date(timeIntervalSince1970: 9), for: 2))
    }
}

@MainActor final class IntegrationControlRuntimeTests: XCTestCase {
    private func action(_ name: String) -> IntegrationPreparedAction { .init(action: .notification(name: name, payload: "p"), target: .init(rawValue: "desk")) }
    func testNoOpHasNoEnvironmentIO() async {
        let runtime = IntegrationControlRuntime(), fake = IntegrationFake()
        let receipt = await runtime.write(.init(action: .none, target: .init(rawValue: "desk")), key: "a", environment: fake)
        XCTAssertEqual(receipt.outcome, .noOp); XCTAssertTrue(fake.calls.isEmpty)
    }
    func testFeedUpdatesWithoutSetter() {
        let runtime = IntegrationControlRuntime()
        runtime.feed(.boolean(true), key: "a", at: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(runtime.samples["a"]?.source, .feed)
        XCTAssertTrue(runtime.receipts.isEmpty)
    }
    func testFeedWinsOverAnOlderReadCompletion() async {
        let runtime = IntegrationControlRuntime(), fake = IntegrationFake()
        let read = Task { await runtime.read(action("read"), parser: .ranged(multiplier: 100, regex: nil, capture: 0), key: "a", environment: fake) }
        await fake.waitForCalls(1)
        runtime.feed(.level(AutomationLevel(normalized: 0.8)!), key: "a", at: Date())
        fake.complete(0, .init(.processExited, exitCode: 0, stdout: "20"))
        await read.value
        XCTAssertEqual(runtime.samples["a"]?.value, .level(AutomationLevel(normalized: 0.8)!))
        XCTAssertEqual(runtime.samples["a"]?.source, .feed)
    }
    func testCancellationRejectsLateReadback() async {
        let runtime = IntegrationControlRuntime(), fake = IntegrationFake()
        let read = Task { await runtime.read(action("read"), parser: .boolean(on: "ON", off: "OFF", regex: false), key: "a", environment: fake) }
        await fake.waitForCalls(1); runtime.cancel("a")
        fake.complete(0, .init(.processExited, exitCode: 0, stdout: "ON"))
        await read.value
        XCTAssertNil(runtime.samples["a"])
    }
    func testWritesSerializePerControlButOtherControlsProceed() async {
        let runtime = IntegrationControlRuntime(), fake = IntegrationFake()
        let a = Task { await runtime.write(action("a1"), key: "a", environment: fake) }
        await fake.waitForCalls(1)
        let b = Task { await runtime.write(action("b"), key: "b", environment: fake) }
        await fake.waitForCalls(2)
        let a2 = Task { await runtime.write(action("a2"), key: "a", environment: fake) }
        fake.complete(0, .init(.dispatched)); _ = await a.value
        await fake.waitForCalls(3)
        XCTAssertEqual(fake.calls.map(\.action), [action("a1").action, action("b").action, action("a2").action])
        fake.complete(1, .init(.dispatched)); fake.complete(2, .init(.dispatched))
        _ = await b.value; _ = await a2.value
    }
    func testReadDoesNotOverlapAWriteAndFailuresAreVisible() async {
        let runtime = IntegrationControlRuntime(), fake = IntegrationFake()
        let write = Task { await runtime.write(action("w"), key: "a", environment: fake) }
        await fake.waitForCalls(1)
        await runtime.read(action("r"), parser: .boolean(on: "ON", off: "OFF", regex: false), key: "a", environment: fake)
        XCTAssertEqual(fake.calls.count, 1)
        fake.complete(0, .init(.dispatched)); _ = await write.value
        let read = Task { await runtime.read(action("r"), parser: .boolean(on: "ON", off: "OFF", regex: false), key: "a", environment: fake) }
        await fake.waitForCalls(2); fake.complete(1, .init(.timedOut)); await read.value
        XCTAssertEqual(runtime.failures["a"], "Action timed out; external effects may remain"); XCTAssertNil(runtime.samples["a"])
    }
    func testPollingUsesOnlySuppliedCadenceAndStopsAfterCancellation() async throws {
        let runtime = IntegrationControlRuntime(), fake = IntegrationFake(), clock = IntegrationTestClock()
        try runtime.startPolling(seconds: 0.375, key: "a", action: action("r"), parser: .boolean(on: "ON", off: "OFF", regex: false), environment: fake, failurePolicy: .stop, sleep: { try await clock.sleep($0) })
        let firstDelay = await clock.requested()
        XCTAssertEqual(firstDelay, 0.375)
        XCTAssertTrue(fake.calls.isEmpty)
        await clock.release()
        await fake.waitForCalls(1)
        fake.complete(0, .init(.processExited, exitCode: 0, stdout: "ON"))
        let secondDelay = await clock.requested()
        XCTAssertEqual(secondDelay, 0.375)
        XCTAssertEqual(runtime.samples["a"]?.value, .boolean(true))
        runtime.cancel("a")
        await clock.release()
        XCTAssertEqual(fake.calls.count, 1)
    }
    func testConfiguredStopPolicyStopsPollingAfterVisibleFailure() async throws {
        let runtime = IntegrationControlRuntime(), fake = IntegrationFake(), clock = IntegrationTestClock()
        try runtime.startPolling(seconds: 0.125, key: "a", action: action("r"), parser: .boolean(on: "ON", off: "OFF", regex: false), environment: fake, failurePolicy: .stop, sleep: { try await clock.sleep($0) })
        _ = await clock.requested(); await clock.release(); await fake.waitForCalls(1)
        let stopped = Task { @MainActor in
            if runtime.stoppedPolls.contains("a") { return }
            await withCheckedContinuation { continuation in
                runtime.onChange = {
                    if runtime.stoppedPolls.contains("a") { runtime.onChange = nil; continuation.resume() }
                }
            }
        }
        fake.complete(0, .init(.timedOut, processMayBeRunning: true))
        await stopped.value
        XCTAssertNotNil(runtime.failures["a"])
        XCTAssertTrue(runtime.stoppedPolls.contains("a"))
        XCTAssertEqual(fake.calls.count, 1)
        runtime.cancelAll()
    }
    func testCancelInvalidatesQueuedWritesAndAllInFlightControls() async {
        let runtime = IntegrationControlRuntime(), fake = IntegrationFake()
        let first = Task { await runtime.write(action("a1"), key: "a", environment: fake) }
        await fake.waitForCalls(1)
        let second = Task { await runtime.write(action("a2"), key: "a", environment: fake) }
        let third = Task { await runtime.write(action("b"), key: "b", environment: fake) }
        await fake.waitForCalls(2)
        runtime.cancelAll()
        fake.complete(0, .init(.dispatched)); fake.complete(1, .init(.dispatched))
        _ = await first.value; let queued = await second.value; _ = await third.value
        XCTAssertEqual(queued.outcome, .cancelled)
        XCTAssertEqual(fake.calls.count, 2)
        XCTAssertTrue(runtime.receipts.isEmpty)
    }
    func testPollingOffMakesNoRequestsAndInvalidIntervalsRefuse() throws {
        let runtime = IntegrationControlRuntime(), fake = IntegrationFake()
        try runtime.startPolling(seconds: nil, key: "a", action: action("r"), parser: .boolean(on: "ON", off: "OFF", regex: false), environment: fake, failurePolicy: .stop, sleep: { _ in XCTFail("Polling is off") })
        XCTAssertTrue(fake.calls.isEmpty)
        for seconds in [0, -1, Double.nan, Double.infinity] {
            XCTAssertThrowsError(try runtime.startPolling(seconds: seconds, key: "a", action: action("r"), parser: .boolean(on: "ON", off: "OFF", regex: false), environment: fake, failurePolicy: .stop, sleep: { _ in }))
        }
    }
}

@MainActor private final class IntegrationFake: IntegrationActionEnvironment {
    var calls: [IntegrationPreparedAction] = []
    private var pending: [Int: CheckedContinuation<IntegrationReceipt, Never>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func execute(_ action: IntegrationPreparedAction) async -> IntegrationReceipt {
        let index = calls.count; calls.append(action)
        return await withCheckedContinuation { continuation in
            pending[index] = continuation
            let ready = waiters.filter { $0.0 <= calls.count }; waiters.removeAll { $0.0 <= calls.count }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForCalls(_ count: Int) async {
        if calls.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func complete(_ index: Int, _ receipt: IntegrationReceipt) { pending.removeValue(forKey: index)?.resume(returning: receipt) }
}

private actor IntegrationTestClock {
    private var pending: CheckedContinuation<Void, Never>?
    private var delays: [Double] = []
    private var observer: CheckedContinuation<Double, Never>?
    func sleep(_ seconds: Double) async throws {
        try Task.checkCancellation()
        await withCheckedContinuation { continuation in
            pending = continuation
            if let observer { self.observer = nil; observer.resume(returning: seconds) }
            else { delays.append(seconds) }
        }
        try Task.checkCancellation()
    }
    func requested() async -> Double {
        if !delays.isEmpty { return delays.removeFirst() }
        return await withCheckedContinuation { observer = $0 }
    }
    func release() { let p = pending; pending = nil; p?.resume() }
}
