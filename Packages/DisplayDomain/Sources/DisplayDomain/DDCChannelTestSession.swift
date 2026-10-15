import Foundation

/// Quit owns the same task that owes the original brightness; cancellation ends the caller's hold,
/// then completion waits for the restore write. No timeout can discard that obligation.
@MainActor
public final class DDCChannelTestSession {
    private var task: Task<DDCChannelTest.Outcome, Never>?
    public var isRunning: Bool { task != nil }

    public init() {}

    public func run(_ operation: @escaping @MainActor () async -> DDCChannelTest.Outcome) async -> DDCChannelTest.Outcome? {
        guard task == nil else { return nil }
        let running = Task { await operation() }
        task = running
        defer { task = nil }
        return await running.value
    }

    public func cancelAndRestore() async {
        guard let running = task else { return }
        running.cancel()
        _ = await running.value
    }
}
