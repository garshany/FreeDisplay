import Foundation

public enum TVFamily: String, CaseIterable, Hashable, Sendable, Codable {
    case lgWebOS, samsungTizen
}

public struct TVCertificatePin: Hashable, Sendable {
    public let hex: String
    public init(_ text: String) throws {
        let hex = text.replacingOccurrences(of: ":", with: "").lowercased()
        // SHA-256 length is a wire/cryptographic invariant, not a user-policy limit.
        guard hex.utf8.count == 64, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw AutomationIssue.invalidValue("certificate", "expected the TV certificate's SHA-256 fingerprint")
        }
        self.hex = hex
    }
}

public enum TVCertificateTrustPolicy {
    /// Used only for this explicit per-device exception. Without a pin the adapter must perform
    /// normal system validation; an invalid/mismatched pin must never fall back to accepting it.
    public static func permitsPinnedLeaf(endpoint: TVEndpoint, approvedPin: String, challengeHost: String,
                                         challengePort: Int, leafSHA256: String) -> Bool {
        guard endpoint.tls, endpoint.host.caseInsensitiveCompare(challengeHost) == .orderedSame,
              Int(endpoint.port) == challengePort,
              let expected = try? TVCertificatePin(approvedPin),
              let observed = try? TVCertificatePin(leafSHA256) else { return false }
        return expected == observed
    }
}

/// An explicit endpoint, independent of both the display's video identity and its wake interface.
/// No discovery result or DHCP address silently authorizes a different device.
public struct TVEndpoint: Hashable, Sendable, Codable {
    public let host: String
    public let port: UInt16
    public let tls: Bool

    public init(host: String, port: UInt16, tls: Bool) throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, port != 0,
              !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              !host.contains(where: { "/?#@%".contains($0) }) else {
            throw AutomationIssue.invalidValue("endpoint", "give a host and a nonzero service port, without a URL path or credentials")
        }
        var parts = URLComponents()
        parts.scheme = tls ? "wss" : "ws"
        parts.host = host
        parts.port = Int(port)
        guard parts.url != nil else { throw AutomationIssue.invalidValue("host", "invalid network host") }
        self.host = host
        self.port = port
        self.tls = tls
    }

    public func url(family: TVFamily, token: String?) -> URL {
        var parts = URLComponents()
        parts.scheme = tls ? "wss" : "ws"
        parts.host = host
        parts.port = Int(port)
        if family == .samsungTizen {
            parts.path = "/api/v2/channels/samsung.remote.control"
            parts.queryItems = [URLQueryItem(name: "name", value: Data("FreeDisplay".utf8).base64EncodedString())]
            if let token { parts.queryItems?.append(URLQueryItem(name: "token", value: token)) }
        }
        return parts.url!
    }

    private enum CodingKeys: String, CodingKey { case host, port, tls }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(host: c.decode(String.self, forKey: .host), port: c.decode(UInt16.self, forKey: .port),
                      tls: c.decode(Bool.self, forKey: .tls))
    }
}

/// All deadlines are supplied by the caller. No retry, discovery or polling cadence is implicit.
public struct TVDeadlines: Hashable, Sendable, Codable {
    public let connection: TimeInterval
    public let response: TimeInterval
    public let sessionLifetime: TimeInterval

    public init(connection: TimeInterval, response: TimeInterval, sessionLifetime: TimeInterval) throws {
        guard connection.isFinite, response.isFinite, sessionLifetime.isFinite,
              connection > 0, response > 0, sessionLifetime > 0 else {
            throw AutomationIssue.invalidValue("deadlines", "connection, response and session durations must be finite and positive")
        }
        self.connection = connection
        self.response = response
        self.sessionLifetime = sessionLifetime
    }

    private enum CodingKeys: String, CodingKey { case connection, response, sessionLifetime }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(connection: c.decode(Double.self, forKey: .connection), response: c.decode(Double.self, forKey: .response),
                      sessionLifetime: c.decode(Double.self, forKey: .sessionLifetime))
    }
}

public struct TVMACAddress: Hashable, Sendable, Codable {
    public let bytes: [UInt8]
    public init(_ text: String) throws {
        let parts = text.replacingOccurrences(of: "-", with: ":").split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else {
            throw AutomationIssue.invalidValue("MAC", "expected six hexadecimal octets")
        }
        bytes = try parts.map { part in
            guard let byte = UInt8(part, radix: 16) else { throw AutomationIssue.invalidValue("MAC", "invalid octet") }
            return byte
        }
        guard bytes != Array(repeating: 0, count: 6), bytes[0] & 1 == 0 else {
            throw AutomationIssue.invalidValue("MAC", "expected a unicast network interface address")
        }
    }
    public var text: String { bytes.map { String(format: "%02X", $0) }.joined(separator: ":") }
    /// The six-byte prefix and sixteen MAC repetitions are the WOL wire format, not policy limits.
    public var magicPacket: Data { Data(Array(repeating: UInt8(0xff), count: 6) + Array(repeating: bytes, count: 16).flatMap { $0 }) }
    public init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(text) }
}

public struct TVWakeConfiguration: Hashable, Sendable, Codable {
    public var mac: TVMACAddress
    public var destination: TVEndpoint
    public init(mac: TVMACAddress, destination: TVEndpoint) { self.mac = mac; self.destination = destination }
}

/// Stored separately from existing settings archives. Secrets and certificate pins never enter it.
public struct TVControllerConfiguration: Hashable, Sendable, Codable {
    public var id: UUID
    public var family: TVFamily
    public var endpoint: TVEndpoint
    public var deadlines: TVDeadlines
    public var enabled: Bool
    public var requirePIN: Bool
    public var wake: TVWakeConfiguration?
    public init(id: UUID = UUID(), family: TVFamily, endpoint: TVEndpoint, deadlines: TVDeadlines,
                enabled: Bool = false, requirePIN: Bool = false, wake: TVWakeConfiguration? = nil) {
        self.id = id; self.family = family; self.endpoint = endpoint; self.deadlines = deadlines
        self.enabled = enabled; self.requirePIN = requirePIN; self.wake = wake
    }
}

public enum TVAction: Hashable, Sendable, Codable {
    case volumeUp, volumeDown, muteToggle, powerOff, source, hdmi, refreshInputs, switchInput(String), wake

    public var name: String {
        switch self {
        case .switchInput: return "switchInput"
        case .volumeUp: return "volumeUp"
        case .volumeDown: return "volumeDown"
        case .muteToggle: return "muteToggle"
        case .powerOff: return "powerOff"
        case .source: return "source"
        case .hdmi: return "hdmi"
        case .refreshInputs: return "refreshInputs"
        case .wake: return "wake"
        }
    }

    public static func parse(_ text: String, input: String?) throws(AutomationIssue) -> Self {
        let value: Self
        switch AutomationCatalog.normalize(text) {
        case "volumeup": value = .volumeUp
        case "volumedown": value = .volumeDown
        case "mutetoggle": value = .muteToggle
        case "poweroff": value = .powerOff
        case "source": value = .source
        case "hdmi": value = .hdmi
        case "refreshinputs": value = .refreshInputs
        case "wake": value = .wake
        case "switchinput":
            guard let input, !input.isEmpty, !input.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw .missing("input", for: "switchInput")
            }
            return .switchInput(input)
        default: throw .invalidValue("action", "unsupported TV action")
        }
        guard input == nil else { throw .invalidValue("input", "only switchInput takes an input identifier") }
        return value
    }
}

public struct TVInput: Hashable, Sendable, Codable {
    public var id: String
    public var label: String
    public var connected: Bool?
    public init(id: String, label: String, connected: Bool?) { self.id = id; self.label = label; self.connected = connected }
}

public enum TVConnectionState: String, Hashable, Sendable, Codable {
    case disabled, configured, connecting, waitingForPrompt, waitingForPIN, ready, pairedIdle
    case authorizationDenied, unreachable, manifestRejected, credentialFailure
}

/// Session identity prevents a cancelled task or an old address from publishing readiness/results.
public struct TVSessionState: Hashable, Sendable {
    public private(set) var generation = UUID()
    public private(set) var connection: TVConnectionState = .disabled
    public private(set) var paired = false
    public private(set) var inputs: [TVInput] = []
    public private(set) var requestedInput: String?
    public private(set) var featureOutcomes: [String: TVCommandReceipt] = [:]
    public init() {}
    @discardableResult public mutating func reset(to state: TVConnectionState, paired: Bool) -> UUID {
        generation = UUID(); connection = state; self.paired = paired
        inputs = []; requestedInput = nil; featureOutcomes = [:]
        return generation
    }
    public mutating func transition(_ state: TVConnectionState, generation: UUID, paired: Bool? = nil) {
        guard generation == self.generation else { return }
        connection = state
        if let paired { self.paired = paired }
    }
    public mutating func record(_ receipt: TVCommandReceipt, action: TVAction, generation: UUID) {
        guard generation == self.generation else { return }
        featureOutcomes[action.name] = receipt
        if case .refreshInputs = action, let inputs = receipt.inputs { self.inputs = inputs }
        if case .switchInput(let id) = action, receipt.delivery != .failed { requestedInput = id }
    }
}

/// Acknowledgement means protocol acceptance, never observed panel/audio/input/wake state.
public struct TVCommandReceipt: Hashable, Sendable, Codable {
    public enum Delivery: String, Hashable, Sendable, Codable { case sent, acknowledged, failed }
    public var delivery: Delivery
    public var inputs: [TVInput]?
    public init(_ delivery: Delivery, inputs: [TVInput]? = nil) { self.delivery = delivery; self.inputs = inputs }
}

public struct TVCapabilityReport: Hashable, Sendable, Codable {
    public var family: TVFamily
    public var connection: TVConnectionState
    public var authorizedSession: Bool
    public var actions: [String]
    public var inputs: [TVInput]
    public var featureOutcomes: [String: TVCommandReceipt]
    public init(family: TVFamily, connection: TVConnectionState, authorizedSession: Bool, actions: [String],
                inputs: [TVInput], featureOutcomes: [String: TVCommandReceipt]) {
        self.family = family; self.connection = connection; self.authorizedSession = authorizedSession
        self.actions = actions; self.inputs = inputs; self.featureOutcomes = featureOutcomes
    }
}
