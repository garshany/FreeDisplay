#if os(macOS)
import AutomationSchema
import Combine
import DisplayDomain
import Foundation
import TopologyCore

@MainActor
final class IntegrationSession: ObservableObject {
    @Published private(set) var configuration = IntegrationConfiguration()
    @Published private(set) var failure: String?
    @Published private(set) var activity: [String] = []
    let runtime = IntegrationControlRuntime()
    let execution = AutomationExecutionGeneration()
    private weak var model: AppModel?
    private var environment: AppIntegrationEnvironment?
    private var store: IntegrationConfigurationStore?
    private var state = IntegrationHookState()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var delayed: [DisplayRecordID: Task<Void, Never>] = [:]
    private var pollKeys: Set<String> = []
    private var pollBindings: [String: AutomationDisplayCandidate] = [:]
    private var shuttingDown = false
    private var isSleeping = false

    func start(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model; environment = AppIntegrationEnvironment(model: model)
        runtime.onChange = { [weak self] in self?.objectWillChange.send() }
        do {
            store = try IntegrationConfigurationStore(directory: SettingsStore.defaultDirectory())
            let loaded = try store!.load()
            let admission = loaded.executionAdmission()
            configuration = admission.configuration
            failure = admission.failure
        } catch { failure = (error as? IntegrationError)?.message ?? error.localizedDescription }
        synchronize()
    }
    var displaySet: AutomationDisplaySet { model?.automationDisplaySet(pointerDisplayID: nil) ?? .init(candidates: []) }
    private func verified(_ id: DisplayRecordID) -> Bool {
        PersistentDisplayIdentity.isPersistent(id) && model?.canPersistDisplaySettings(id) == true
    }
    var safeStartup: Bool { model?.safeStartup ?? true }

    func save(_ value: IntegrationConfiguration) throws {
        guard value.displays.allSatisfy({ verified($0.id) || configuration.displays.contains($0) }) else {
            throw IntegrationError.invalid("A verified persistent display identity is required. Earlier provisional associations remain saved but inactive.")
        }
        try value.validate(in: displaySet)
        guard let store else { throw IntegrationError.invalid("Integration storage is unavailable") }
        try store.save(value)
        // Editing invalidates in-flight work and never executes an action. Newly configured polling
        // waits its full configured interval. Hook edges are not replayed after reconfiguration.
        stopWork(); configuration = value; failure = nil; reconcilePolling()
    }
    func install(_ value: IntegrationConfiguration) throws {
        try value.validateForStorage()
        guard let store else { throw IntegrationError.invalid("Integration storage is unavailable") }
        try store.save(value)
        stopWork(); configuration = value
    }
    func synchronize() {
        guard !shuttingDown else { return }
        let set = displaySet
        let connected = Set(set.candidates.filter { $0.availability != .disconnected }.map(\.id))
        let remembered = Set(set.candidates.filter { $0.availability == .disconnected }.map(\.id))
        let events = state.topology(connected: connected, remembered: remembered, ready: connected)
        for event in events where event.phase == .hardDisconnect {
            delayed.removeValue(forKey: event.display)?.cancel()
        }
        // Preserve polling cadence on an unchanged binding; a rebind cancels its old work.
        reconcilePolling()
        deliver(events)
    }
    func soft(_ phase: IntegrationHookPhase, display: DisplayRecordID, attempt: UUID) {
        deliver(state.soft(phase, display: display, attempt: attempt))
    }
    func sleep() {
        isSleeping = true
        delayed.values.forEach { $0.cancel() }; delayed.removeAll()
        runtime.cancelAll(); pollKeys.removeAll()
        deliver(state.sleep())
    }
    func wake() {
        isSleeping = false
        let events = state.wake(); deliver(events)
        for event in events {
            guard let display = definition(for: event.display), let delay = display.wakeDelaySeconds,
                  delay.isFinite, delay >= 0, let generation = event.wakeGeneration else { continue }
            delayed[event.display]?.cancel()
            delayed[event.display] = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)); try Task.checkCancellation() } catch { return }
                guard let self, let event = self.state.delayedWake(display: event.display, generation: generation) else { return }
                self.deliver([event]); self.delayed.removeValue(forKey: event.display)
            }
        }
        reconcilePolling()
    }
    private func definition(for id: DisplayRecordID) -> DisplayIntegration? {
        guard verified(id) else { return nil }
        return IntegrationPlan.definition(for: id, in: configuration, displays: displaySet)
    }
    private func deliver(_ events: [IntegrationHookEvent]) {
        guard !shuttingDown else { return }
        for event in events {
            activity.append("event=\(event.phase.rawValue) target=\(event.display.rawValue) transition=\(event.transition)")
            guard verified(event.display), let environment else { continue }
            do {
                guard let action = try IntegrationPlan.hook(event, configuration: configuration, displays: displaySet, safeStartup: safeStartup) else { continue }
                let id = UUID()
                tasks[id] = Task { [weak self] in
                    let receipt = await environment.execute(action)
                    guard let self else { return }
                    self.record(receipt, target: action.target.rawValue, label: event.phase.rawValue)
                    self.tasks.removeValue(forKey: id)
                }
            } catch { failure = (error as? IntegrationError)?.message ?? error.localizedDescription }
        }
    }
    func invoke(_ control: IntegrationControl, on definition: DisplayIntegration, value: IntegrationValue) async {
        guard verified(definition.id), !safeStartup, !shuttingDown, definition.enabled, control.enabled, let environment else { return }
        do {
            let candidate = try AutomationSelectorResolver.resolveOne(.display(.id(definition.id)), in: displaySet)
            guard candidate.availability != .disconnected else { throw IntegrationError.invalid("Display is disconnected") }
            let selected = value == .boolean(false) ? control.offAction : control.action
            let action = try IntegrationActionPolicy.prepare(selected, context: .init(display: candidate,
                value: try control.kind.text(for: value), parameters: definition.parameters, input: value))
            let key = IntegrationControlRuntime.key(display: definition.id, control: control.id)
            let receipt = await runtime.write(action, key: key, environment: environment)
            record(receipt, target: candidate.id.rawValue, label: control.name)
        } catch { failure = (error as? IntegrationError)?.message ?? error.localizedDescription }
    }
    func pull(_ control: IntegrationControl, on display: DisplayIntegration) async {
        guard verified(display.id), !safeStartup, !shuttingDown, !isSleeping, display.enabled, control.enabled,
              let parser = control.readback, control.readAction != .none, let environment else { return }
        do {
            let candidate = try AutomationSelectorResolver.resolveOne(.display(.id(display.id)), in: displaySet)
            guard candidate.availability != .disconnected else { throw IntegrationError.invalid("Display is disconnected") }
            let action = try IntegrationActionPolicy.prepare(control.readAction, context: .init(display: candidate, parameters: display.parameters))
            await runtime.read(action, parser: parser, key: IntegrationControlRuntime.key(display: display.id, control: control.id), environment: environment)
        } catch { failure = (error as? IntegrationError)?.message ?? error.localizedDescription }
    }
    func feed(controlID: UUID, response: String, displayID: DisplayRecordID) throws -> IntegrationSample {
        guard !shuttingDown else { throw IntegrationError.invalid("Integration session is stopping") }
        let parser = try IntegrationPlan.feedParser(controlID: controlID, displayID: displayID,
            configuration: configuration, displays: displaySet)
        let display = definition(for: displayID)!
        let key = IntegrationControlRuntime.key(display: display.id, control: controlID)
        let value = try parser.parse(response)
        runtime.feed(value, key: key, at: Date())
        return runtime.samples[key]!
    }
    func feed(_ text: String, control: IntegrationControl, display: DisplayIntegration) async {
        guard let model else { return }
        let result = await AppAutomation.run(.byID(.feedIntegration(control: control.id, response: text), display.id), from: .console, model: model)
        if let issue = result.issue { failure = issue.message }
    }
    private func reconcilePolling() {
        guard !safeStartup, !shuttingDown, !isSleeping, let environment else { runtime.cancelAll(); pollKeys.removeAll(); return }
        do {
            let plans = try IntegrationPlan.polls(configuration: configuration, displays: displaySet, safeStartup: safeStartup, sleeping: isSleeping)
                .filter { verified($0.action.target) }
            let wanted = Set(plans.map(\.key))
            for plan in plans where pollBindings[plan.key] != plan.action.binding {
                runtime.cancel(plan.key); pollKeys.remove(plan.key)
            }
            for plan in plans where !pollKeys.contains(plan.key) {
                try runtime.startPolling(seconds: plan.seconds, key: plan.key, parser: plan.parser, environment: environment, failurePolicy: plan.failurePolicy,
                                         prepare: { [weak self] in
                                             guard let self, !self.shuttingDown else { return nil }
                                             return try IntegrationPlan.polls(configuration: self.configuration,
                                                 displays: self.displaySet, safeStartup: self.safeStartup,
                                                 sleeping: self.isSleeping)
                                                 // A poll re-checks the persistent identity each time it runs.
                                                 .first { $0.key == plan.key && self.verified($0.action.target) }?.action
                                         },
                                         sleep: { try await Task.sleep(for: .seconds($0)) })
            }
            for key in pollKeys.subtracting(wanted) { runtime.cancel(key) }
            // Manual read/write slots also stop when their display disappears.
            for display in configuration.displays {
                let candidate = try? AutomationSelectorResolver.resolveOne(.display(.id(display.id)), in: displaySet)
                if candidate == nil || candidate?.availability == .disconnected || !display.enabled {
                    for control in display.controls { runtime.cancel(IntegrationControlRuntime.key(display: display.id, control: control.id)) }
                }
            }
            pollKeys = wanted
            pollBindings = Dictionary(uniqueKeysWithValues: plans.compactMap { plan in
                plan.action.binding.map { (plan.key, $0) }
            })
        } catch { failure = (error as? IntegrationError)?.message ?? error.localizedDescription; runtime.cancelAll(); pollKeys.removeAll() }
    }

    func stopWork() {
        execution.invalidate()
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        delayed.values.forEach { $0.cancel() }; delayed.removeAll()
        runtime.cancelAll(); pollKeys.removeAll()
    }
    func stop() { shuttingDown = true; stopWork() }
    private func record(_ receipt: IntegrationReceipt, target: String, label: String) {
        let encoded = (try? JSONEncoder().encode(receipt)).flatMap { String(data: $0, encoding: .utf8) } ?? receipt.outcome.rawValue
        activity.append("target=\(target) action=\(label) \(encoded)")
    }
}
#endif
