import Foundation

/// SSDP is a hint, never identity, authorization, a MAC observation or proof of a remote capability.
public struct TVDiscoveryCandidate: Hashable, Sendable, Identifiable {
    public var serviceID: String
    public var host: String
    public var location: URL
    public var id: String { serviceID + "@" + host }
}

public struct TVDiscoveryRequest: Hashable, Sendable {
    public let family: TVFamily
    public let window: TimeInterval
    public let maximumResponseDelaySeconds: UInt
    public init(family: TVFamily, window: TimeInterval, maximumResponseDelaySeconds: UInt) throws {
        guard window.isFinite, window > 0, maximumResponseDelaySeconds > 0 else {
            throw AutomationIssue.invalidValue("discovery", "supply a positive discovery window and SSDP MX response delay")
        }
        self.family = family; self.window = window; self.maximumResponseDelaySeconds = maximumResponseDelaySeconds
    }
    public var searchPacket: Data {
        // This multicast endpoint and header grammar are SSDP protocol constants.
        let target = family == .lgWebOS ? "urn:lge-com:service:webos-second-screen:1" : "ssdp:all"
        return Data("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: \(maximumResponseDelaySeconds)\r\nST: \(target)\r\n\r\n".utf8)
    }
    public func candidate(from data: Data) -> TVDiscoveryCandidate? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let status = lines.first, status.hasPrefix("HTTP/1.1 200 ") || status.hasPrefix("HTTP/1.0 200 ") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let separator = line.firstIndex(of: ":") else { return nil }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, headers[name] == nil else { return nil }
            headers[name] = value
        }
        guard let serviceID = headers["usn"], !serviceID.isEmpty,
              let location = headers["location"].flatMap(URL.init(string:)),
              ["http", "https"].contains(location.scheme?.lowercased() ?? ""),
              location.user == nil, location.password == nil,
              let host = location.host, !host.isEmpty else { return nil }
        let advertised = (headers["st"] ?? "").lowercased()
        let server = (headers["server"] ?? "").lowercased()
        switch family {
        case .lgWebOS:
            guard advertised == "urn:lge-com:service:webos-second-screen:1" else { return nil }
        case .samsungTizen:
            guard advertised.contains("samsung") || server.contains("samsung") else { return nil }
        }
        return TVDiscoveryCandidate(serviceID: serviceID, host: host, location: location)
    }
}

public struct TVDiscoveryState: Sendable {
    public enum Phase: Equatable, Sendable { case idle, searching, finished, failed }
    public private(set) var generation = UUID()
    public private(set) var phase: Phase = .idle
    public private(set) var candidates: [TVDiscoveryCandidate] = []
    public init() {}
    @discardableResult public mutating func begin() -> UUID {
        generation = UUID(); phase = .searching; candidates = []; return generation
    }
    public mutating func add(_ candidate: TVDiscoveryCandidate, generation: UUID) {
        guard self.generation == generation, phase == .searching,
              !candidates.contains(where: { $0.id == candidate.id }) else { return }
        candidates.append(candidate)
    }
    public mutating func finish(generation: UUID, failed: Bool = false) {
        guard self.generation == generation else { return }
        phase = failed ? .failed : .finished
    }
    public mutating func cancel() { generation = UUID(); phase = .idle }
}
