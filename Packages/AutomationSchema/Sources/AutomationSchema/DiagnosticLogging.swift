import Foundation

public enum DiagnosticStream: String, Sendable, CaseIterable {
    case off, stdout, stderr
}

/// Result streams and diagnostic streams must never share stdout for machine-readable results.
public struct CLIDiagnosticOptions: Sendable, Equatable {
    public var stream: DiagnosticStream
    public var arguments: [String]

    public static func parse(_ arguments: [String]) throws(AutomationIssue) -> Self {
        var result: [String] = []
        var selected: DiagnosticStream?
        var index = 0
        while index < arguments.count {
            let token = arguments[index]; index += 1
            let stream: DiagnosticStream?
            switch token {
            case "-v": stream = .stdout
            case "-v2e": stream = .stderr
            case "--log-output":
                guard index < arguments.count, let value = DiagnosticStream(rawValue: arguments[index]) else {
                    throw .invalidValue("log-output", "Expected off, stdout or stderr.")
                }
                stream = value; index += 1
            default: stream = nil
            }
            if let stream {
                guard selected == nil else { throw .invalidValue("log-output", "Choose one diagnostic output mode.") }
                selected = stream
            } else { result.append(token) }
        }
        if selected == .stdout, result.contains("--json") || result.first == "listen" {
            throw .invalidValue("log-output", "Machine-readable output requires stderr diagnostics or logging off.")
        }
        return .init(stream: selected ?? .off, arguments: result)
    }
}

public struct DiagnosticRecord: Sendable, Equatable {
    public static let subsystem = "dev.opendisplay.diagnostics"
    public static let category = "automation"
    public var date: Date
    public var message: String

    /// Redact at ingestion so retained buffers and all sinks receive the same safe text.
    public init(_ message: String, date: Date = Date(), privacy: DiagnosticPrivacy = .init()) {
        self.date = date
        self.message = privacy.redact(message)
    }

    public var line: String { "[FreeDisplay] \(ISO8601DateFormatter().string(from: date)) \(message)" }
}

public struct DiagnosticBuffer: Sendable {
    public var capacity: Int? { didSet { prune() } }
    public private(set) var records: [DiagnosticRecord] = []
    public init(capacity: Int?) { self.capacity = capacity }
    public mutating func append(_ record: DiagnosticRecord) { records.append(record); prune() }
    public mutating func clear() { records.removeAll() }
    private mutating func prune() {
        if let capacity { records.removeFirst(max(0, records.count - max(0, capacity))) }
    }
}
