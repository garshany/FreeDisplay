import Foundation

/// A session revision revokes work prepared before cancellation, editing or shutdown.
@MainActor public final class AutomationExecutionGeneration {
    public private(set) var current = UUID()
    public init() {}
    public func invalidate() { current = UUID() }
    public func issue(for generation: UUID) -> AutomationIssue? {
        guard generation == current else {
            return AutomationIssue(.busy, "Integration configuration changed or execution was cancelled")
        }
        return AutomationMutationPolicy.cancellationIssue
    }
}

public enum AutomationMutationPolicy {
    public static var cancellationIssue: AutomationIssue? {
        Task.isCancelled ? AutomationIssue(.busy, "Automation request cancelled before dispatch") : nil
    }
}
