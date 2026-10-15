#if os(macOS)
import AppKit
import AutomationSchema
import Foundation

@MainActor
final class AppIntegrationEnvironment: IntegrationActionEnvironment {
    weak var model: AppModel?
    init(model: AppModel) { self.model = model }
    func execute(_ prepared: IntegrationPreparedAction) async -> IntegrationReceipt {
        guard !Task.isCancelled else { return .init(.cancelled) }
        switch prepared.action {
        case .none: return .init(.noOp)
        case .brightness: return .init(.failed, detail: "Action was not prepared")
        case .command(let command):
            guard let model else { return .init(.failed, detail: "FreeDisplay is unavailable") }
            let execution = model.integrationSession.execution
            let generation = execution.current
            let result = await AppAutomation.run(.byID(command, prepared.target), from: .console, model: model,
                authorization: execution.authorization, beforeMutation: { execution.issue(for: generation) })
            return .init(.transportCompleted, commandResult: result)
        case .process(let executable, let arguments, let budget):
            let job = IntegrationProcessJob()
            return await withTaskCancellationHandler {
                await job.run(executable: executable, arguments: arguments, budget: budget)
            } onCancel: { job.cancel() }
        case .http(let url, let budget):
            guard let url = URL(string: url) else { return .init(.failed, detail: "Invalid URL") }
            let job = IntegrationHTTPJob(budget: budget)
            return await withTaskCancellationHandler { await job.run(url) } onCancel: { job.cancel() }
        case .openURL(let text):
            guard let url = URL(string: text) else { return .init(.failed, detail: "Invalid URL") }
            return .init(NSWorkspace.shared.open(url) ? .dispatched : .failed)
        case .notification(let name, let payload):
            guard !payload.isEmpty else { return .init(.noOp) }
            DistributedNotificationCenter.default().postNotificationName(.init(name), object: payload, userInfo: nil, deliverImmediately: true)
            return .init(.dispatched)
        }
    }
}

/// The lock arbitrates termination, EOF, deadline and cancellation. Only a direct child receives
/// SIGTERM; a receipt never promises descendant termination or rollback of external effects.
private final class IntegrationProcessJob: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let output = Pipe(), errors = Pipe()
    private var continuation: CheckedContinuation<IntegrationReceipt, Never>?
    private var result: IntegrationReceipt?
    private var stdout = Data(), stderr = Data()
    private var ended = false, outEOF = false, errEOF = false
    private var limit = 0
    private var deadline: Task<Void, Never>?

    func run(executable: String, arguments: [String], budget: IntegrationBudget) async -> IntegrationReceipt {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result { lock.unlock(); continuation.resume(returning: result); return }
            self.continuation = continuation; limit = budget.maximumOutputBytes
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output; process.standardError = errors
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.receive(handle.availableData, error: false) }
            errors.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.receive(handle.availableData, error: true) }
            process.terminationHandler = { [weak self] _ in self?.terminated() }
            do {
                try process.run()
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(budget.timeoutSeconds)) } catch { return }
                    self?.finish(.timedOut, terminate: true)
                }
                lock.unlock()
            } catch {
                lock.unlock(); finish(.failed, detail: String(describing: error), terminate: false)
            }
        }
    }
    private func receive(_ data: Data, error: Bool) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        if data.isEmpty {
            if error { errEOF = true } else { outEOF = true }
        } else {
            guard data.count <= limit - stdout.count - stderr.count else {
                lock.unlock(); finish(.outputLimit, terminate: true); return
            }
            if error { stderr.append(data) } else { stdout.append(data) }
        }
        let complete = ended && outEOF && errEOF
        lock.unlock()
        if complete { finish(.processExited, terminate: false) }
    }
    private func terminated() {
        lock.lock(); ended = true; let complete = outEOF && errEOF; lock.unlock()
        if complete { finish(.processExited, terminate: false) }
    }
    func cancel() { finish(.cancelled, terminate: true) }
    private func finish(_ outcome: IntegrationReceipt.Outcome, detail: String? = nil, terminate: Bool) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        let running = process.isRunning
        if terminate && running { process.terminate() }
        let outText = String(data: stdout, encoding: .utf8), errText = String(data: stderr, encoding: .utf8)
        let invalidUTF8 = outText == nil || errText == nil
        let receipt = IntegrationReceipt(invalidUTF8 ? .failed : outcome, exitCode: ended ? process.terminationStatus : nil,
            stdout: outText ?? "", stderr: errText ?? "",
            processMayBeRunning: process.isRunning, detail: invalidUTF8 ? "Response is not UTF-8" : detail)
        result = receipt
        let waiter = continuation; continuation = nil
        deadline?.cancel(); deadline = nil
        output.fileHandleForReading.readabilityHandler = nil; errors.fileHandleForReading.readabilityHandler = nil
        lock.unlock()
        waiter?.resume(returning: receipt)
    }
}

private final class IntegrationHTTPJob: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let budget: IntegrationBudget
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<IntegrationReceipt, Never>?
    private var result: IntegrationReceipt?
    private var body = Data()
    private var status: Int?
    init(budget: IntegrationBudget) { self.budget = budget }
    func run(_ url: URL) async -> IntegrationReceipt {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result { lock.unlock(); continuation.resume(returning: result); return }
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = budget.timeoutSeconds
            configuration.timeoutIntervalForResource = budget.timeoutSeconds
            configuration.httpCookieStorage = nil; configuration.urlCache = nil
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.dataTask(with: url); self.task = task
            lock.unlock(); task.resume()
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); status = (response as? HTTPURLResponse)?.statusCode; let stopped = result != nil; lock.unlock()
        completionHandler(stopped ? .cancel : .allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let exceeds = data.count > budget.maximumOutputBytes - body.count
        if !exceeds && result == nil { body.append(data) }
        lock.unlock()
        if exceeds { finish(.outputLimit) }
    }
    // Redirects need explicit configuration/review; do not send an action to an unexpected peer.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { finish((error as? URLError)?.code == .timedOut ? .timedOut : .failed, detail: String(describing: error)) }
        else { finish(.transportCompleted) }
    }
    func cancel() { finish(.cancelled) }
    private func finish(_ outcome: IntegrationReceipt.Outcome, detail: String? = nil) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        let validUTF8 = String(data: body, encoding: .utf8)
        let receipt = IntegrationReceipt(validUTF8 == nil ? .failed : outcome, httpStatus: status,
            stdout: validUTF8 ?? "", detail: validUTF8 == nil ? "Response is not UTF-8" : detail)
        result = receipt; let waiter = continuation; continuation = nil
        let session = self.session; self.session = nil
        lock.unlock()
        session?.invalidateAndCancel(); waiter?.resume(returning: receipt)
    }
}
#endif
