#if os(macOS)
import Foundation

/// Foundation accepts the caller's TimeInterval without converting it to bounded integer
/// nanoseconds. Cancellation invalidates the timer; there is no polling cadence or chosen cap.
@MainActor final class TVNetworkDelay {
    private var timer: Timer?
    private var completion: CheckedContinuation<Void, any Error>?

    static func wait(_ seconds: TimeInterval) async throws {
        try await TVNetworkDelay().sleep(seconds)
    }
    private func sleep(_ seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.finish(cancelled: false) }
                }
                self.timer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        } onCancel: { Task { @MainActor in self.finish(cancelled: true) } }
    }
    private func finish(cancelled: Bool) {
        guard let completion else { return }
        self.completion = nil
        timer?.invalidate(); timer = nil
        if cancelled { completion.resume(throwing: CancellationError()) } else { completion.resume() }
    }
}
#endif
