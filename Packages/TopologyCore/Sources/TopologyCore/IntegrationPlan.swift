import AutomationSchema
import DisplayDomain
import Foundation

public struct IntegrationPollPlan: Sendable {
    public var key: String
    public var seconds: Double
    public var action: IntegrationPreparedAction
    public var parser: IntegrationReadback
    public var failurePolicy: IntegrationPollingFailurePolicy
}

public enum IntegrationPlan {
    public static func definition(for id: DisplayRecordID, in configuration: IntegrationConfiguration,
                                  displays: AutomationDisplaySet) -> DisplayIntegration? {
        configuration.displays.first {
            (try? AutomationSelectorResolver.resolveOne(.display(.id($0.id)), in: displays).id) == id
        }
    }
    /// Safe startup is a session veto, independent of persisted enable flags. Observed loss uses
    /// remembered identity; it is allowed to dispatch an external action with no runtime CG id.
    public static func hook(_ event: IntegrationHookEvent, configuration: IntegrationConfiguration,
                            displays: AutomationDisplaySet, safeStartup: Bool) throws -> IntegrationPreparedAction? {
        guard !safeStartup, let display = definition(for: event.display, in: configuration, displays: displays), display.enabled,
              let hook = display.hooks.first(where: { $0.phase == event.phase }), hook.enabled, hook.action != .none else { return nil }
        let candidate = try AutomationSelectorResolver.resolveOne(.display(.id(display.id)), in: displays)
        return try IntegrationActionPolicy.prepare(hook.action, context: .init(display: candidate, hook: event.phase.rawValue, parameters: display.parameters))
    }
    /// Feed is state-only, but still requires the saved controller and control opt-ins.
    public static func feedParser(controlID: UUID, displayID: DisplayRecordID,
                                  configuration: IntegrationConfiguration,
                                  displays: AutomationDisplaySet) throws -> IntegrationReadback {
        guard let display = definition(for: displayID, in: configuration, displays: displays), display.enabled,
              let control = display.controls.first(where: { $0.id == controlID }), control.enabled,
              let parser = control.readback else {
            throw IntegrationError.invalid("Feed needs an enabled controller, enabled control and configured parser")
        }
        return parser
    }
    public static func polls(configuration: IntegrationConfiguration, displays: AutomationDisplaySet,
                             safeStartup: Bool, sleeping: Bool) throws -> [IntegrationPollPlan] {
        guard !safeStartup, !sleeping else { return [] }
        var plans: [IntegrationPollPlan] = []
        for display in configuration.displays where display.enabled {
            guard let candidate = try? AutomationSelectorResolver.resolveOne(.display(.id(display.id)), in: displays),
                  candidate.availability != .disconnected else { continue }
            for control in display.controls where control.enabled {
                guard let seconds = control.pollingSeconds, let parser = control.readback, let failurePolicy = control.pollingFailurePolicy, control.readAction != .none else { continue }
                guard IntegrationTiming.isRepresentable(seconds) else { throw IntegrationError.invalid("Configure a positive polling interval") }
                let action = try IntegrationActionPolicy.prepare(control.readAction, context: .init(display: candidate, parameters: display.parameters))
                plans.append(.init(key: IntegrationControlRuntime.key(display: display.id, control: control.id), seconds: seconds, action: action, parser: parser, failurePolicy: failurePolicy))
            }
        }
        return plans
    }
}
