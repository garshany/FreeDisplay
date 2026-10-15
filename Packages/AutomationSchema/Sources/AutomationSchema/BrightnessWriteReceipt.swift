import Foundation
import DisplayDomain

/// One request owns its transport/readback evidence, even when a writer coalesces later requests.
@MainActor public final class BrightnessWriteReceipt {
    public let requested: AutomationLevel
    public nonisolated let authorization: WriteAuthorization
    private var result: BrightnessWriteReport?
    private var waiters: [CheckedContinuation<BrightnessWriteReport, Never>] = []
    private let beforeDispatch: (() -> AutomationIssue?)?
    public init(_ requested: AutomationLevel, authorization: WriteAuthorization = WriteAuthorization(),
                beforeDispatch: (() -> AutomationIssue?)? = nil) {
        self.authorization = authorization
        self.requested = requested
        self.beforeDispatch = beforeDispatch
    }
    public func admitDispatch() -> Bool {
        guard result == nil else { return false }
        guard authorization.isAuthorized else { reject("Automation request cancelled before dispatch"); return false }
        if let issue = beforeDispatch?() { authorization.revoke(); reject(issue.message); return false }
        return true
    }
    /// Followers own their evidence while sharing the leader request's revocation. Completion or
    /// supersession of one member must not cancel another member that is still authorized.
    public func follower(_ requested: AutomationLevel) -> BrightnessWriteReceipt {
        BrightnessWriteReceipt(requested, authorization: authorization, beforeDispatch: beforeDispatch)
    }
    public func complete(accepted: Bool, readback: BrightnessReadback) {
        finish(.init(requested: requested, accepted: accepted, readback: readback,
                     failure: accepted ? nil : "The display transport rejected this request"))
    }
    public func reject(_ message: String = "Request superseded before its readback; no result was borrowed from a later request") {
        finish(.init(requested: requested, accepted: false, readback: .none, failure: message))
    }
    private func finish(_ report: BrightnessWriteReport) {
        guard result == nil else { return }
        result = report
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume(returning: report) }
    }
    public func report() async -> BrightnessWriteReport {
        await withTaskCancellationHandler {
            if let result { return result }
            return await withCheckedContinuation { waiters.append($0) }
        } onCancel: { authorization.revoke() }
    }
}

@MainActor public final class CoalescedBrightnessReceipts<Key: Hashable> {
    private var pending: [Key: BrightnessWriteReceipt] = [:]
    public init() {}
    public func enqueue(_ receipt: BrightnessWriteReceipt?, for key: Key) {
        pending.removeValue(forKey: key)?.reject()
        pending[key] = receipt
    }
    public func take(_ key: Key) -> BrightnessWriteReceipt? { pending.removeValue(forKey: key) }
    public func invalidate(_ key: Key) { take(key)?.reject("Request cancelled before dispatch") }
    public func retain(only keys: Set<Key>) {
        for key in pending.keys where !keys.contains(key) { invalidate(key) }
    }
}


/// A cancelled writer can resume after its replacement has queued work for the same display.
/// Only the current instance may consume targets or clean up shared receipts and writer state.
@MainActor public final class CoalescedWriterOwnership<Key: Hashable> {
    private var current: [Key: UUID] = [:]
    public init() {}
    public func begin(_ key: Key) -> UUID {
        let generation = UUID()
        current[key] = generation
        return generation
    }
    public func isCurrent(_ generation: UUID, for key: Key) -> Bool { current[key] == generation }
    public func invalidate(_ key: Key) { current[key] = nil }
    public func finish(_ generation: UUID, for key: Key, cleanup: () -> Void) {
        guard isCurrent(generation, for: key) else { return }
        current[key] = nil
        cleanup()
    }
}
