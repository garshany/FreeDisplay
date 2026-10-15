import Foundation

/// One request owns its transport/readback evidence, even when a writer coalesces later requests.
@MainActor public final class BrightnessWriteReceipt {
    public let requested: AutomationLevel
    private let cancellation = WriteCancellation()
    private var result: BrightnessWriteReport?
    private var waiters: [CheckedContinuation<BrightnessWriteReport, Never>] = []
    private let beforeDispatch: (() -> AutomationIssue?)?
    public init(_ requested: AutomationLevel, beforeDispatch: (() -> AutomationIssue?)? = nil) {
        self.requested = requested
        self.beforeDispatch = beforeDispatch
    }
    public func admitDispatch() -> Bool {
        guard result == nil else { return false }
        guard !cancellation.isCancelled else { reject("Automation request cancelled before dispatch"); return false }
        if let issue = beforeDispatch?() { reject(issue.message); return false }
        return true
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
        } onCancel: { cancellation.cancel() }
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

/// Cancellation handlers run outside the main actor; the transport admission reads this flag there.
private final class WriteCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
