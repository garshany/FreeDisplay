import AutomationSchema
import DisplayDomain
import Foundation

public enum IntegrationHookPhase: String, CaseIterable, Hashable, Codable, Sendable {
    case softDisconnect, softReconnect, hardDisconnect, hardReconnect
    case systemSleep, systemWakeImmediate, systemWake
}

public struct IntegrationHook: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var phase: IntegrationHookPhase
    public var enabled: Bool
    public var action: IntegrationAction
    public init(id: UUID = UUID(), phase: IntegrationHookPhase, enabled: Bool = false, action: IntegrationAction = .none) {
        self.id = id; self.phase = phase; self.enabled = enabled; self.action = action
    }
}

public struct DisplayIntegration: Hashable, Codable, Sendable, Identifiable {
    public var id: DisplayRecordID
    public var enabled: Bool
    public var parameters: [IntegrationParameter]
    public var controls: [IntegrationControl]
    public var hooks: [IntegrationHook]
    /// Nil means the delayed phase is disabled until its delay is explicitly configured.
    public var wakeDelaySeconds: Double?
    public init(id: DisplayRecordID, enabled: Bool = false, parameters: [IntegrationParameter] = [],
                controls: [IntegrationControl] = [], hooks: [IntegrationHook] = [], wakeDelaySeconds: Double? = nil) {
        self.id = id; self.enabled = enabled; self.parameters = parameters
        self.controls = controls; self.hooks = hooks; self.wakeDelaySeconds = wakeDelaySeconds
    }
}

public struct IntegrationConfiguration: Hashable, Codable, Sendable {
    public var displays: [DisplayIntegration]
    public init(displays: [DisplayIntegration] = []) { self.displays = displays }
    public func pausedForImport() -> Self {
        var result = self
        for i in result.displays.indices {
            result.displays[i].enabled = false
            for h in result.displays[i].hooks.indices { result.displays[i].hooks[h].enabled = false }
            for c in result.displays[i].controls.indices { result.displays[i].controls[c].enabled = false }
        }
        return result
    }
    /// Validation may become stricter after an upgrade. Retain the definitions and disk bytes;
    /// quarantine their execution flags until the user reviews the rejected invocation.
    public func executionAdmission() -> (configuration: Self, failure: String?) {
        do { try validateForStorage(); return (self, nil) }
        catch { return (pausedForImport(), (error as? IntegrationError)?.message ?? error.localizedDescription) }
    }
    public func validateForStorage() throws {
        try validate(in: .init(candidates: displays.map {
            AutomationDisplayCandidate(id: $0.id, name: $0.id.rawValue, availability: .disconnected)
        }))
    }
    public func validate(in set: AutomationDisplaySet) throws {
        guard Set(displays.map(\.id)).count == displays.count else { throw IntegrationError.invalid("Duplicate integration display") }
        for display in displays {
            // Disconnected identities can be edited but never substituted by another monitor.
            let candidate = try AutomationSelectorResolver.resolveOne(.display(.id(display.id)), in: set)
            guard Set(display.hooks.map(\.phase)).count == display.hooks.count,
                  Set(display.hooks.map(\.id)).count == display.hooks.count,
                  Set(display.controls.map(\.id)).count == display.controls.count else {
                throw IntegrationError.invalid("Duplicate control or hook")
            }
            if let delay = display.wakeDelaySeconds, !IntegrationTiming.isRepresentable(delay, allowZero: true) { throw IntegrationError.invalid("Invalid wake delay") }
            _ = try IntegrationContext(display: candidate, parameters: display.parameters).expand("")
            for hook in display.hooks {
                _ = try IntegrationActionPolicy.prepare(hook.action, context: .init(display: candidate, hook: hook.phase.rawValue, parameters: display.parameters))
            }
            for control in display.controls {
                let sample: IntegrationValue
                switch control.kind {
                case .ranged: sample = .level(.minimum)
                case .boolean: sample = .boolean(true)
                case .command: sample = .command("")
                }
                let context = IntegrationContext(display: candidate, value: try control.kind.text(for: sample), parameters: display.parameters, input: sample)
                _ = try IntegrationActionPolicy.prepare(control.action, context: context)
                _ = try IntegrationActionPolicy.prepare(control.offAction, context: context)
                let read = try IntegrationActionPolicy.prepare(control.readAction, context: .init(display: candidate, parameters: display.parameters))
                if control.readback != nil {
                    switch read.action {
                    case .process, .http, .none: break
                    default: throw IntegrationError.invalid("Readback needs process or HTTP output")
                    }
                    // Validate parser syntax even if the sample intentionally does not match.
                    switch control.readback! {
                    case .ranged(let m, let regex, let capture):
                        guard m.isFinite, m != 0, capture >= 0 else { throw IntegrationError.invalid("Invalid parser") }
                        if let regex {
                            let parsed = try NSRegularExpression(pattern: regex)
                            guard capture <= parsed.numberOfCaptureGroups else { throw IntegrationError.invalid("Missing capture group") }
                        }
                    case .boolean(let on, let off, let regex):
                        guard !on.isEmpty, !off.isEmpty, on != off else { throw IntegrationError.invalid("Invalid Boolean parser") }
                        if regex { _ = try NSRegularExpression(pattern: on); _ = try NSRegularExpression(pattern: off) }
                    }
                }
                for interval in [control.pollingSeconds, control.freshnessSeconds].compactMap({ $0 }) {
                    guard interval.isFinite, interval > 0 else { throw IntegrationError.invalid("Invalid polling or freshness interval") }
                }
                if let seconds = control.pollingSeconds, !IntegrationTiming.isRepresentable(seconds) {
                    throw IntegrationError.invalid("Invalid polling or freshness interval")
                }
                if control.pollingSeconds != nil, control.readback == nil || control.pollingFailurePolicy == nil {
                    throw IntegrationError.invalid("Polling needs a parser and an explicit failure policy")
                }
            }
        }
    }
}

public struct IntegrationHookEvent: Hashable, Sendable {
    public var phase: IntegrationHookPhase
    public var display: DisplayRecordID
    public var transition: UUID
    public var wakeGeneration: UUID?
    public init(phase: IntegrationHookPhase, display: DisplayRecordID, transition: UUID = UUID(), wakeGeneration: UUID? = nil) {
        self.phase = phase; self.display = display; self.transition = transition; self.wakeGeneration = wakeGeneration
    }
}

/// Event edges, not a continuous desired-state policy. Startup seeds connected records without
/// replay. Remembered records must be observed absent before their first eligible return.
public struct IntegrationHookState: Sendable {
    private var initialized = false
    private var connected: Set<DisplayRecordID> = []
    private var absent: Set<DisplayRecordID> = []
    private var pendingReady: Set<DisplayRecordID> = []
    private var sleeping = false
    private var delayedEligible: Set<DisplayRecordID> = []
    private var delayedDelivered: Set<DisplayRecordID> = []
    private var softSeen: Set<IntegrationHookEvent> = []
    public private(set) var wakeGeneration = UUID()
    public init() {}
    public mutating func topology(connected next: Set<DisplayRecordID>, remembered: Set<DisplayRecordID>,
                                  ready: Set<DisplayRecordID>) -> [IntegrationHookEvent] {
        guard initialized else {
            initialized = true; connected = next; absent = remembered.subtracting(next); return []
        }
        let lost = connected.subtracting(next)
        delayedEligible.subtract(lost)
        absent.formUnion(lost)
        absent.formUnion(remembered.subtracting(next))
        pendingReady.formUnion(next.subtracting(connected).intersection(absent))
        pendingReady.formIntersection(next)
        let returned = pendingReady.intersection(ready)
        pendingReady.subtract(returned); absent.subtract(returned); connected = next
        return lost.sorted(by: { $0.rawValue < $1.rawValue }).map { .init(phase: .hardDisconnect, display: $0) }
            + returned.sorted(by: { $0.rawValue < $1.rawValue }).map { .init(phase: .hardReconnect, display: $0) }
    }
    public mutating func soft(_ phase: IntegrationHookPhase, display: DisplayRecordID, attempt: UUID) -> [IntegrationHookEvent] {
        guard phase == .softDisconnect || phase == .softReconnect else { return [] }
        let event = IntegrationHookEvent(phase: phase, display: display, transition: attempt)
        return softSeen.insert(event).inserted ? [event] : []
    }
    public mutating func sleep() -> [IntegrationHookEvent] {
        guard !sleeping else { return [] }
        sleeping = true; wakeGeneration = UUID(); delayedDelivered.removeAll(); delayedEligible.removeAll()
        return connected.sorted(by: { $0.rawValue < $1.rawValue }).map { .init(phase: .systemSleep, display: $0) }
    }
    public mutating func wake() -> [IntegrationHookEvent] {
        guard sleeping else { return [] }
        sleeping = false; wakeGeneration = UUID(); delayedDelivered.removeAll(); delayedEligible = connected
        return connected.sorted(by: { $0.rawValue < $1.rawValue }).map {
            .init(phase: .systemWakeImmediate, display: $0, wakeGeneration: wakeGeneration)
        }
    }
    public mutating func delayedWake(display: DisplayRecordID, generation: UUID) -> IntegrationHookEvent? {
        guard !sleeping, generation == wakeGeneration, delayedEligible.contains(display), connected.contains(display), delayedDelivered.insert(display).inserted else { return nil }
        return .init(phase: .systemWake, display: display, transition: generation, wakeGeneration: generation)
    }
}

/// Separate from legacy stores: missing means empty; malformed JSON is surfaced, never overwritten.
public struct IntegrationConfigurationStore: Sendable {
    public let url: URL
    public init(directory: URL) { url = directory.appendingPathComponent("integration-actions.json") }
    public func load() throws -> IntegrationConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        return try JSONDecoder().decode(IntegrationConfiguration.self, from: Data(contentsOf: url))
    }
    public func save(_ value: IntegrationConfiguration) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
