import Foundation

/// FreeDisplay-owned, same-user IPC. One JSON document per connection, terminated by EOF.
/// There is deliberately no payload cap or default deadline. Clients never retry a command after
/// losing its response: disconnecting does not undo an already accepted display operation.
public enum LocalAutomationProtocol {
    public static let version = 1

    public struct Request: Codable, Sendable, Equatable {
        public var version: Int
        public var id: UUID
        public var command: AutomationRequest?
        public init(id: UUID = UUID(), command: AutomationRequest? = nil) {
            version = LocalAutomationProtocol.version
            self.id = id
            self.command = command
        }
    }

    public enum State: String, Codable, Sendable { case starting, ready, stopping }
    public enum Failure: String, Error, Codable, Sendable {
        case malformed, versionMismatch, notReady, correlationMismatch, invalidResponse
    }
    public enum Payload: Codable, Sendable, Equatable {
        case readiness(State)
        case result(AutomationResult)
        case failure(Failure)
    }
    public struct Response: Codable, Sendable, Equatable {
        public var version: Int
        public var id: UUID?
        public var payload: Payload
        public init(id: UUID?, payload: Payload) {
            version = LocalAutomationProtocol.version
            self.id = id
            self.payload = payload
        }
        public func validated(for request: Request) throws -> Payload {
            guard version == LocalAutomationProtocol.version else { throw Failure.versionMismatch }
            guard id == request.id else { throw Failure.correlationMismatch }
            switch (request.command, payload) {
            case (nil, .result), (.some, .readiness): throw Failure.invalidResponse
            case (.some(let command), .result(let result)) where command.command.name != result.command:
                throw Failure.invalidResponse
            default: return payload
            }
        }
    }

    /// The peer cannot provide an automation surface. The server's adapter always uses `.cli`,
    /// preserving the engine's prohibition on impersonating an Intent to bypass confirmation.
    public static func respond(to data: Data, state: State,
                               execute: @Sendable (AutomationRequest) async -> AutomationResult) async -> Response {
        guard let request = try? JSONDecoder().decode(Request.self, from: data) else {
            return Response(id: nil, payload: .failure(.malformed))
        }
        guard request.version == version else { return Response(id: request.id, payload: .failure(.versionMismatch)) }
        guard let command = request.command else { return Response(id: request.id, payload: .readiness(state)) }
        guard state == .ready else { return Response(id: request.id, payload: .failure(.notReady)) }
        return Response(id: request.id, payload: .result(await execute(command)))
    }
}

/// Persisted HTTP configuration contains no credentials. A missing chosen port asks the OS for a
/// free port once; the owner persists the actual bound port before advertising readiness.
public struct IntegrationHTTPConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var port: UInt16?
    public var remoteAccess: Bool
    public init(enabled: Bool = false, port: UInt16? = nil, remoteAccess: Bool = false) {
        self.enabled = enabled; self.port = port; self.remoteAccess = remoteAccess
    }
    public var host: String { remoteAccess ? "0.0.0.0" : "127.0.0.1" }
    public func shouldStart(safeStartup: Bool) -> Bool { enabled && !safeStartup }

    /// Revoking exposure must succeed even while the port editor contains an invalid draft.
    public func updating(enabled: Bool, port draft: String, remoteAccess: Bool) throws -> Self {
        let reducingAccess = !enabled || (self.enabled && self.remoteAccess && !remoteAccess)
        let port: UInt16?
        do { port = try Self.parsePort(draft) }
        catch {
            guard reducingAccess else { throw error }
            port = self.port
        }
        return .init(enabled: enabled, port: port, remoteAccess: remoteAccess)
    }
    public static func parsePort(_ text: String) throws -> UInt16? {
        if text.isEmpty { return nil }
        guard text.allSatisfy({ $0.isASCII && $0.isNumber }), let port = UInt16(text), port != 0 else {
            throw AutomationIssue.invalidValue("port", "expected a port from 1 to 65535, or blank to choose once")
        }
        return port
    }
}
