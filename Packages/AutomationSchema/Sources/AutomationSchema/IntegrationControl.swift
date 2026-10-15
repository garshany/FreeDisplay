import DisplayDomain
import Foundation

public enum IntegrationValue: Hashable, Codable, Sendable {
    case level(AutomationLevel)
    case boolean(Bool)
    case command(String)
}

public enum IntegrationReadback: Hashable, Codable, Sendable {
    /// Without a regex the entire trimmed response must be one finite number. With a regex,
    /// exactly one match and the explicitly selected capture must contain that number.
    case ranged(multiplier: Double, regex: String?, capture: Int)
    case boolean(on: String, off: String, regex: Bool)

    public func parse(_ response: String) throws -> IntegrationValue {
        switch self {
        case .ranged(let multiplier, let pattern, let capture):
            guard multiplier.isFinite, multiplier != 0, capture >= 0 else { throw IntegrationError.invalid("Invalid readback multiplier or capture") }
            var text = response.trimmingCharacters(in: .whitespacesAndNewlines)
            if let pattern {
                let regex = try NSRegularExpression(pattern: pattern)
                let matches = regex.matches(in: response, range: NSRange(response.startIndex..., in: response))
                guard matches.count == 1, capture < matches[0].numberOfRanges,
                      let range = Range(matches[0].range(at: capture), in: response) else {
                    throw IntegrationError.invalid("Readback regex must select exactly one value")
                }
                text = String(response[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let number = Double(text), number.isFinite else { throw IntegrationError.invalid("Readback is not one finite number") }
            guard let level = AutomationLevel(normalized: number / multiplier) else { throw IntegrationError.invalid("Readback outside normalized range") }
            return .level(level)
        case .boolean(let on, let off, let regex):
            guard !on.isEmpty, !off.isEmpty, on != off else { throw IntegrationError.invalid("Distinct nonempty Boolean responses are required") }
            func matches(_ pattern: String) throws -> Bool {
                if !regex { return response == pattern }
                return try NSRegularExpression(pattern: pattern).firstMatch(in: response, range: NSRange(response.startIndex..., in: response)) != nil
            }
            let isOn = try matches(on), isOff = try matches(off)
            guard isOn != isOff else { throw IntegrationError.invalid("Boolean readback matches neither or both states") }
            return .boolean(isOn)
        }
    }
}

public enum IntegrationControlKind: Hashable, Codable, Sendable {
    /// Decimal places are configured, not an unsafe printf format supplied to Foundation.
    case ranged(multiplier: Double, decimalPlaces: Int)
    case boolean
    case command

    public func text(for value: IntegrationValue) throws -> String {
        switch (self, value) {
        case (.ranged(let multiplier, let places), .level(let level)):
            guard multiplier.isFinite, multiplier != 0, places >= 0,
                  (level.normalized * multiplier).isFinite else { throw IntegrationError.invalid("Invalid outgoing range format") }
            return (level.normalized * multiplier).formatted(.number.locale(Locale(identifier: "en_US_POSIX"))
                .grouping(.never).precision(.fractionLength(places)))
        case (.boolean, .boolean(let value)): return value ? "1" : "0"
        case (.command, .command(let text)): return text
        default: throw IntegrationError.invalid("Control value has the wrong type")
        }
    }
}

public enum IntegrationPollingFailurePolicy: String, Hashable, Codable, Sendable {
    case stop
    case continuePolling
}

public struct IntegrationControl: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: IntegrationControlKind
    public var enabled: Bool
    public var action: IntegrationAction
    public var offAction: IntegrationAction
    public var readAction: IntegrationAction
    public var readback: IntegrationReadback?
    public var pollingSeconds: Double?
    public var pollingFailurePolicy: IntegrationPollingFailurePolicy?
    public var freshnessSeconds: Double?
    public init(id: UUID = UUID(), name: String, kind: IntegrationControlKind,
                enabled: Bool = false, action: IntegrationAction = .none, offAction: IntegrationAction = .none,
                readAction: IntegrationAction = .none, readback: IntegrationReadback? = nil,
                pollingSeconds: Double? = nil, freshnessSeconds: Double? = nil,
                pollingFailurePolicy: IntegrationPollingFailurePolicy? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.enabled = enabled
        self.action = action; self.offAction = offAction; self.readAction = readAction
        self.readback = readback; self.pollingSeconds = pollingSeconds; self.freshnessSeconds = freshnessSeconds
        self.pollingFailurePolicy = pollingFailurePolicy
    }
}

public struct IntegrationSample: Hashable, Codable, Sendable {
    public enum Source: String, Codable, Sendable { case readback, feed }
    public var value: IntegrationValue
    public var at: Date
    public var source: Source
    public init(value: IntegrationValue, at: Date, source: Source) { self.value = value; self.at = at; self.source = source }
    public func isFresh(at now: Date, for seconds: Double?) -> Bool {
        guard let seconds, seconds.isFinite, seconds > 0 else { return false }
        return now >= at && now.timeIntervalSince(at) <= seconds
    }
}

/// A slot belongs to one display/control. Writes queue independently per slot; reads refuse while
/// the slot is busy. Cancellation invalidates completions without pretending to undo external work.
@MainActor public final class IntegrationControlRuntime {
    public private(set) var samples: [String: IntegrationSample] = [:]
    public private(set) var receipts: [String: IntegrationReceipt] = [:]
    public private(set) var stoppedPolls: Set<String> = []
    public private(set) var failures: [String: String] = [:]
    private var jobs: [String: [UUID: Task<IntegrationReceipt, Never>]] = [:]
    private var tails: [String: Task<IntegrationReceipt, Never>] = [:]
    private var tokens: [String: UUID] = [:]
    private var polls: [String: Task<Void, Never>] = [:]
    private var revisions: [String: UUID] = [:]
    public var onChange: (@MainActor () -> Void)?
    public init() {}
    nonisolated public static func key(display: DisplayRecordID, control: UUID) -> String { "\(display.rawValue)/\(control)" }

    public func cancel(_ key: String) {
        defer { onChange?() }
        stoppedPolls.remove(key)
        tokens[key] = UUID(); revisions[key] = UUID()
        polls.removeValue(forKey: key)?.cancel()
        jobs.removeValue(forKey: key)?.values.forEach { $0.cancel() }
        tails.removeValue(forKey: key)?.cancel()
    }
    public func cancelAll() {
        for key in Set(tokens.keys).union(polls.keys).union(tails.keys) { cancel(key) }
    }
    public func feed(_ value: IntegrationValue, key: String, at: Date) {
        defer { onChange?() }
        revisions[key] = UUID()
        samples[key] = .init(value: value, at: at, source: .feed)
        failures.removeValue(forKey: key)
    }
    public func write(_ action: IntegrationPreparedAction, key: String,
                      environment: any IntegrationActionEnvironment) async -> IntegrationReceipt {
        revisions[key] = UUID()
        return await perform(action, key: key, environment: environment)
    }
    private var tailIDs: [String: UUID] = [:]
    private func perform(_ action: IntegrationPreparedAction, key: String,
                         environment: any IntegrationActionEnvironment,
                         isCurrent: @escaping @MainActor () -> Bool = { true }) async -> IntegrationReceipt {
        let prior = tails[key]
        let revision = revisions[key]
        let token = tokens[key] ?? UUID(); tokens[key] = token
        let taskID = UUID(); tailIDs[key] = taskID
        let task = Task { @MainActor in
            if let prior { _ = await prior.value }
            guard !Task.isCancelled, self.tokens[key] == token, isCurrent() else { return IntegrationReceipt(.cancelled) }
            if action.action == .none { return IntegrationReceipt(.noOp) }
            return await environment.execute(action)
        }
        tails[key] = task
        jobs[key, default: [:]][taskID] = task
        let receipt = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        jobs[key]?.removeValue(forKey: taskID)
        if tokens[key] == token {
            if revisions[key] == revision, isCurrent() {
                receipts[key] = receipt
                if let failure = receipt.failureMessage { failures[key] = failure }
                else { failures.removeValue(forKey: key) }
            }
            if tailIDs[key] == taskID { tails.removeValue(forKey: key) }
        }
        onChange?()
        return receipt
    }
    public func read(_ action: IntegrationPreparedAction, parser: IntegrationReadback, key: String,
                     environment: any IntegrationActionEnvironment, now: @escaping @MainActor () -> Date = { Date() },
                     isCurrent: @escaping @MainActor () -> Bool = { true }) async {
        defer { onChange?() }
        guard tails[key] == nil else { return }
        let revision = UUID(); revisions[key] = revision
        let token = tokens[key] ?? UUID(); tokens[key] = token
        let receipt = await perform(action, key: key, environment: environment, isCurrent: isCurrent)
        guard tokens[key] == token, revisions[key] == revision, isCurrent() else { return }
        guard let text = receipt.readableText else { failures[key] = receipt.failureMessage ?? "Action returned no readable response"; return }
        do {
            samples[key] = .init(value: try parser.parse(text), at: now(), source: .readback)
            failures.removeValue(forKey: key)
        } catch { failures[key] = (error as? IntegrationError)?.message ?? error.localizedDescription }
    }
    public func startPolling(seconds: Double?, key: String, action: IntegrationPreparedAction,
                             parser: IntegrationReadback, environment: any IntegrationActionEnvironment,
                             failurePolicy: IntegrationPollingFailurePolicy,
                             sleep: @escaping @Sendable (Double) async throws -> Void) throws {
        try startPolling(seconds: seconds, key: key, parser: parser, environment: environment,
                         failurePolicy: failurePolicy, prepare: { action }, sleep: sleep)
    }
    public func startPolling(seconds: Double?, key: String, parser: IntegrationReadback,
                             environment: any IntegrationActionEnvironment,
                             failurePolicy: IntegrationPollingFailurePolicy,
                             prepare: @escaping @MainActor () throws -> IntegrationPreparedAction?,
                             sleep: @escaping @Sendable (Double) async throws -> Void) throws {
        cancel(key)
        guard let seconds else { return }
        guard IntegrationTiming.isRepresentable(seconds) else { throw IntegrationError.invalid("Configure a positive polling interval") }
        polls[key] = Task { @MainActor in
            while !Task.isCancelled {
                do { try await sleep(seconds); try Task.checkCancellation() } catch { return }
                do {
                    guard let action = try prepare() else { return }
                    await self.read(action, parser: parser, key: key, environment: environment,
                                    isCurrent: { (try? prepare()) == action })
                } catch { self.failures[key] = (error as? IntegrationError)?.message ?? error.localizedDescription }

                if !Task.isCancelled, self.failures[key] != nil, failurePolicy == .stop {
                    self.stoppedPolls.insert(key); self.onChange?(); return
                }
            }
        }
    }
}
