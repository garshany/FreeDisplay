// Original OpenDisplay work, GPL-3.0-or-later.
import Foundation
import Network
import Security
import AutomationSchema
import TopologyCore

/// Explicit opt-in, session-only local control. Constructing this object does not bind a socket.
/// The caller must show the token privately; never persist/log it or embed it in a URL.
@MainActor
final class LocalControlServer {
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var commands: [UUID: Task<Void, Never>] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private(set) var token: String?
    private(set) var port: UInt16?
    private(set) var failure: String?

    typealias Handler = @MainActor @Sendable (LocalHTTPControl.ParseResult) async -> AutomationHTTPResponse

    /// Every authenticated route goes to `handler`, which runs against the app's live model.
    func start(handler: @escaping Handler) throws {
        guard listener == nil else { return }
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            throw NSError(domain: "LocalControlServer", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Couldn’t create a secure session token")])
        }
        let secret = random.map { String(format: "%02x", $0) }.joined()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let newListener = try NWListener(using: parameters)
        token = secret
        failure = nil
        listener = newListener
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            Task { @MainActor [weak newListener] in
                guard let self, let newListener, self.listener === newListener else { return }
                switch state {
                case .ready: self.port = newListener.port?.rawValue
                case .failed(let error): self.stop(); self.failure = String(localized: "Local server error: \(error.localizedDescription)")
                default: break
                }
            }
        }
        newListener.newConnectionHandler = { [weak self, weak newListener] connection in
            Task { @MainActor [weak newListener] in
                guard let self, let newListener, self.listener === newListener, self.connections.count < 8 else {
                    connection.cancel(); return
                }
                let id = UUID()
                self.connections[id] = connection
                connection.start(queue: .main)
                self.tasks[id] = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    self?.finish(id)
                }
                self.receive(connection, id: id, data: Data(), token: secret, handler: handler)
            }
        }
        newListener.start(queue: .main)
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        for task in tasks.values { task.cancel() }
        for task in commands.values { task.cancel() }
        connections.removeAll(); tasks.removeAll(); commands.removeAll()
        token = nil; port = nil
    }

    private func finish(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
        tasks.removeValue(forKey: id)?.cancel()
        commands.removeValue(forKey: id)?.cancel()
    }

    private func receive(_ connection: NWConnection, id: UUID, data: Data,
                         token: String, handler: @escaping Handler) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8193 - data.count) {
            [weak self] chunk, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                self.commands[id] = Task { @MainActor in
                    guard !Task.isCancelled, self.connections[id] != nil else { return }
                    var accumulated = data
                    if let chunk { accumulated.append(chunk) }
                    let parsed = LocalHTTPControl.parse(accumulated, token: token)
                    switch parsed {
                    case .incomplete:
                        if complete || error != nil { self.finish(id) }
                        else { self.receive(connection, id: id, data: accumulated, token: token, handler: handler) }
                    case .rejected(let status):
                        self.send(LocalHTTPControl.response(status: status), connection: connection, id: id)
                    case .displays, .brightness, .reconnectAll, .command, .catalog, .invalid:
                        // Reconnect-all goes to the live model too: a gateway composed here would
                        // never see the app's managed-offline ledger and always answer noOp.
                        let response = await handler(parsed)
                        guard !Task.isCancelled, self.connections[id] != nil else { return }
                        self.send(LocalHTTPControl.response(status: response.status, body: response.body), connection: connection, id: id)
                    }
                }
            }
        }
    }

    private func send(_ data: Data, connection: NWConnection, id: UUID) {
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.finish(id) }
        })
    }
}
