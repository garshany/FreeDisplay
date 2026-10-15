#if os(macOS)
import AutomationSchema
import CryptoKit
import Foundation
import Network
import Security

/// Each controller has its own session and trust delegate. An explicitly approved leaf pin is
/// scoped to that endpoint; no shared URLSession or global trust policy is altered.
private final class TVTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionWebSocketDelegate {
    let endpoint: TVEndpoint
    let pin: String?
    let opening: TVSocketOpening
    init(endpoint: TVEndpoint, pin: String?, opening: TVSocketOpening) {
        self.endpoint = endpoint; self.pin = pin; self.opening = opening
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task { @MainActor in opening.finish(error: nil) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        Task { @MainActor in opening.finish(error: error ?? CancellationError()) }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        guard let pin else { completionHandler(.performDefaultHandling, nil); return }
        guard challenge.protectionSpace.host.caseInsensitiveCompare(endpoint.host) == .orderedSame,
              challenge.protectionSpace.port == Int(endpoint.port),
              let trust = challenge.protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = certificates.first else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        guard TVCertificateTrustPolicy.permitsPinnedLeaf(endpoint: endpoint, approvedPin: pin,
                challengeHost: challenge.protectionSpace.host, challengePort: challenge.protectionSpace.port,
                leafSHA256: digest) else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Samsung tokens live in the vendor query grammar. Never forward one to a redirect target.
        completionHandler(nil)
    }
}

@MainActor private final class TVSocketOpening {
    private var result: Result<Void, any Error>?
    private var completion: CheckedContinuation<Void, any Error>?
    func wait() async throws {
        try Task.checkCancellation()
        if let result { return try result.get() }
        try await withCheckedThrowingContinuation { completion = $0 }
    }
    func finish(error: (any Error)?) {
        guard result == nil else { return }
        let value: Result<Void, any Error> = error.map(Result.failure) ?? .success(())
        result = value
        completion?.resume(with: value); completion = nil
    }
}

@MainActor final class TVWebSocket: TVSocket {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let opening: TVSocketOpening

    init(configuration: TVControllerConfiguration, credential: TVCredential?) {
        let settings = URLSessionConfiguration.ephemeral
        settings.urlCache = nil
        settings.httpCookieStorage = nil
        settings.urlCredentialStorage = nil
        settings.timeoutIntervalForRequest = configuration.deadlines.connection
        settings.timeoutIntervalForResource = configuration.deadlines.sessionLifetime
        let opening = TVSocketOpening()
        self.opening = opening
        let delegate = TVTrustDelegate(endpoint: configuration.endpoint, pin: credential?.certificateSHA256, opening: opening)
        session = URLSession(configuration: settings, delegate: delegate, delegateQueue: nil)
        let url = configuration.endpoint.url(family: configuration.family, token: credential?.token)
        task = session.webSocketTask(with: url)
    }

    func start() async throws {
        try Task.checkCancellation()
        task.resume()
        try await opening.wait()
    }
    func send(_ text: String) async throws { try await task.send(.string(text)) }
    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                throw AutomationIssue(.executionFailed, "TV returned invalid UTF-8")
            }
            return text
        @unknown default: throw AutomationIssue(.executionFailed, "unsupported TV WebSocket frame")
        }
    }
    func close() {
        opening.finish(error: CancellationError())
        task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel()
    }
}

@MainActor final class TVKeychain: TVCredentialStore {
    private let service = "dev.opendisplay.tv-controller"
    func read(id: UUID) throws -> TVCredential? {
        var query = base(id)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw failure() }
        return try JSONDecoder().decode(TVCredential.self, from: data)
    }
    func write(_ credential: TVCredential, id: UUID) throws {
        let data = try JSONEncoder().encode(credential)
        let status = SecItemUpdate(base(id) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = base(id)
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw failure() }
        } else if status != errSecSuccess { throw failure() }
    }
    func remove(id: UUID) throws {
        let status = SecItemDelete(base(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure() }
    }
    private func base(_ id: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id.uuidString,
         kSecAttrSynchronizable: false]
    }
    private func failure() -> AutomationIssue { AutomationIssue(.executionFailed, "TV credential storage is unavailable") }
}

/// NWConnection completion is packet submission, not proof that a sleeping TV received it.
@MainActor private final class TVWakeSend {
    private var connection: NWConnection?
    private var completion: CheckedContinuation<Void, any Error>?
    private var deadline: Task<Void, Never>?
    private var submitted = false

    func send(_ packet: Data, endpoint: TVEndpoint, seconds: TimeInterval) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                let connection = NWConnection(host: NWEndpoint.Host(endpoint.host),
                    port: NWEndpoint.Port(rawValue: endpoint.port)!, using: .udp)
                self.connection = connection
                connection.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        guard let self, self.completion != nil else { return }
                        switch state {
                        case .ready:
                            guard !self.submitted else { return }
                            self.submitted = true
                            connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                                Task { @MainActor in self?.finish(error) }
                            })
                        case .failed(let error): self.finish(error)
                        case .cancelled: self.finish(CancellationError())
                        default: break
                        }
                    }
                }
                deadline = Task { [weak self] in
                    do { try await TVNetworkDelay.wait(seconds) } catch { return }
                    self?.finish(AutomationIssue(.notConfirmed, "WOL submission deadline expired"))
                }
                connection.start(queue: .global())
            }
        } onCancel: { Task { @MainActor in self.finish(CancellationError()) } }
    }
    private func finish(_ error: (any Error)?) {
        guard let completion else { return }
        self.completion = nil
        deadline?.cancel(); deadline = nil
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
        if let error { completion.resume(throwing: error) } else { completion.resume() }
    }
}

@MainActor enum TVNetworkFactory {
    static func controller(_ configuration: TVControllerConfiguration, credentials: any TVCredentialStore) -> TVController {
        TVController(configuration: configuration, credentials: credentials,
            factory: { TVWebSocket(configuration: $0, credential: $1) },
            wait: { try await TVNetworkDelay.wait($0) },
            wakeSender: { packet, endpoint, seconds in
                try await TVWakeSend().send(packet, endpoint: endpoint, seconds: seconds)
            })
    }
}
#endif
