import Foundation
import DisplayDomain

/// A session revision revokes work prepared before cancellation, editing or shutdown.
@MainActor public final class AutomationExecutionGeneration {
    public private(set) var current = UUID()
    public private(set) var authorization = WriteAuthorization()
    public init() {}
    public func invalidate() {
        authorization.revoke()
        authorization = WriteAuthorization()
        current = UUID()
    }
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
