import DisplayDomain
import Foundation

public enum IntegrationError: Error, Equatable, Sendable {
    case invalid(String)
    case cancelled
    case busy
    public var message: String {
        switch self {
        case .invalid(let message): return message
        case .cancelled: return "Action cancelled; external effects may remain"
        case .busy: return "An action is already running for this control"
        }
    }
}

/// Reject values the Swift clock cannot represent, without choosing a product duration bound.
public enum IntegrationTiming {
    public static func isRepresentable(_ seconds: Double, allowZero: Bool = false) -> Bool {
        guard seconds.isFinite, seconds >= 0, Int64(exactly: seconds.rounded(.down)) != nil else { return false }
        let duration = Duration.seconds(seconds)
        return allowZero ? duration >= .zero : duration > .zero
    }
}

/// No execution budgets are chosen here. Process/HTTP actions require the owner's explicit values.
public struct IntegrationBudget: Hashable, Codable, Sendable {
    public var timeoutSeconds: Double
    public var maximumOutputBytes: Int
    public init(timeoutSeconds: Double, maximumOutputBytes: Int) {
        self.timeoutSeconds = timeoutSeconds
        self.maximumOutputBytes = maximumOutputBytes
    }
    public func validate() throws {
        guard IntegrationTiming.isRepresentable(timeoutSeconds), maximumOutputBytes > 0 else {
            throw IntegrationError.invalid("Configure a positive timeout and output byte budget")
        }
    }
}

public struct IntegrationParameter: Hashable, Codable, Sendable {
    public var name: String
    public var value: String
    public init(_ name: String, _ value: String) { self.name = name; self.value = value }
}

public enum IntegrationAction: Hashable, Codable, Sendable {
    case none
    case command(AutomationCommand)
    case brightness(BrightnessMethodRequest)
    /// An interpreter is an explicit executable and script path/arguments, never an implicit -c shell.
    case process(executable: String, arguments: [String], budget: IntegrationBudget)
    case http(url: String, budget: IntegrationBudget)
    case openURL(String)
    case notification(name: String, payload: String)
}

public struct IntegrationContext: Sendable {
    public var display: AutomationDisplayCandidate
    public var hook: String?
    public var value: String?
    public var input: IntegrationValue?
    public var parameters: [IntegrationParameter]
    public init(display: AutomationDisplayCandidate, hook: String? = nil, value: String? = nil,
                parameters: [IntegrationParameter] = [], input: IntegrationValue? = nil) {
        self.display = display; self.hook = hook; self.value = value; self.parameters = parameters; self.input = input
    }

    public func expand(_ text: String, urlEncoded: Bool = false) throws -> String {
        let reserved = ["VALUE", "EVENT_HOOK", "DEVICE_NAME", "DEVICE_DESCRIPTION", "DISPLAY_ID", "STABLE_ID"]
        var names = Set<String>()
        for p in parameters {
            guard !p.name.isEmpty, !p.name.contains(":*]"), !reserved.contains(p.name), names.insert(p.name).inserted else {
                throw IntegrationError.invalid("Blank, duplicate or reserved parameter identifier")
            }
        }
        let builtins = [IntegrationParameter("DEVICE_NAME", display.name),
                        .init("DEVICE_DESCRIPTION", display.name), .init("DISPLAY_ID", display.availability == .disconnected ? "" : display.cgDisplayID.map(String.init) ?? ""),
                        .init("STABLE_ID", display.id.rawValue)]
            + (hook.map { [.init("EVENT_HOOK", $0)] } ?? [])
            + (value.map { [.init("VALUE", $0)] } ?? [])
        // Each source token is expanded once. Inserted metadata is never reinterpreted as a template.
        let regex = try NSRegularExpression(pattern: #"\[\*:([^\]]+):\*\]"#)
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let keyRange = Range(match.range(at: 1), in: text), let range = Range(match.range, in: result),
                  let parameter = (builtins + parameters).first(where: { $0.name == String(text[keyRange]) }) else {
                throw IntegrationError.invalid("Unknown placeholder")
            }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            let replacement = urlEncoded ? (parameter.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") : parameter.value
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }
}

public struct IntegrationPreparedAction: Hashable, Sendable {
    public var action: IntegrationAction
    public var target: DisplayRecordID
    public var binding: AutomationDisplayCandidate? = nil
}

public enum IntegrationActionPolicy {
    public static func prepare(_ action: IntegrationAction, context: IntegrationContext) throws -> IntegrationPreparedAction {
        let prepared: IntegrationAction
        switch action {
        case .none: prepared = .none
        case .brightness(let method):
            guard case .level(let level) = context.input else { throw IntegrationError.invalid("Brightness action requires a ranged value") }
            prepared = .command(.setBrightness(level, method: method))
        case .command(let command):
            // Lifecycle mutations from lifecycle hooks would create a recursive event source.
            guard AutomationCatalog.descriptor(for: command.name).target != .none,
                  command.name != .disconnect, command.name != .feedIntegration, command.name != .tvControl else {
                throw IntegrationError.invalid("Integration commands require one display and cannot change its connection or invoke feeds or TV remotes")
            }
            if case .setMode(_, keepWithoutConfirmation: true) = command {
                throw IntegrationError.invalid("Integration cannot bypass mode confirmation")
            }
            prepared = action
        case .process(let path, let arguments, let budget):
            try budget.validate()
            guard path.hasPrefix("/"), !path.contains("[*:"), !path.utf8.contains(0) else {
                throw IntegrationError.invalid("Executable must be an absolute literal path")
            }
            // -c/-e would reinterpret expanded metadata as code. Scripts are passed as owned files.
            guard !arguments.contains(where: { ["-c", "-e", "--command", "--eval"].contains($0) }) else {
                throw IntegrationError.invalid("Inline interpreter code is not supported; use a script file and argument array")
            }
            try validateInvocation(path, arguments: arguments[...])
            let args = try arguments.map { try context.expand($0) }
            guard !args.contains(where: { $0.utf8.contains(0) }) else { throw IntegrationError.invalid("NUL in argument") }
            prepared = .process(executable: path, arguments: args, budget: budget)
        case .http(let template, let budget):
            try budget.validate()
            let value = try validatedURL(template, context: context, schemes: ["http", "https"])
            prepared = .http(url: value, budget: budget)
        case .openURL(let template):
            let value = try validatedURL(template, context: context, schemes: nil)
            guard let scheme = URL(string: value)?.scheme?.lowercased(), !["http", "https", "file", "opendisplay"].contains(scheme) else {
                throw IntegrationError.invalid("Use HTTP for readback; file and recursive FreeDisplay URLs are refused")
            }
            prepared = .openURL(value)
        case .notification(let name, let payload):
            guard !name.isEmpty, !name.contains("[*:") else { throw IntegrationError.invalid("Notification name must be a literal") }
            prepared = .notification(name: name, payload: try context.expand(payload))
        }
        return .init(action: prepared, target: context.display.id, binding: context.display)
    }

    private static func validateInvocation(_ path: String, arguments: ArraySlice<String>) throws {
        let executable = URL(fileURLWithPath: path).lastPathComponent
        let interpreters = ["sh", "bash", "zsh", "dash", "ksh", "fish", "python", "python3", "ruby", "perl", "node", "osascript", "swift"]
        if executable == "env" {
            // env is an executable wrapper, not a script interpreter. Validate the nested argv
            // before expanding data; option forms such as -S can reinterpret an argument as code.
            guard let nested = arguments.first, nested.hasPrefix("/"), !nested.contains("[*:") else {
                throw IntegrationError.invalid("env requires an absolute literal executable and a validated argument array")
            }
            let nestedName = URL(fileURLWithPath: nested).lastPathComponent
            guard nestedName == "env" || interpreters.contains(nestedName) else {
                throw IntegrationError.invalid("env must wrap a supported interpreter with a literal script file")
            }
            try validateInvocation(nested, arguments: arguments.dropFirst())
        } else if interpreters.contains(executable) {
            guard let script = arguments.first, script.hasPrefix("/"), !script.contains("[*:") else {
                throw IntegrationError.invalid("Interpreters require an absolute literal script path as the first argument")
            }
        }
    }

    private static func validatedURL(_ template: String, context: IntegrationContext, schemes: [String]?) throws -> String {
        // Placeholders may only occur after the authority. Metadata cannot change scheme/host.
        guard let components = URLComponents(string: template), let scheme = components.scheme,
              !scheme.contains("[*:"), !(components.host?.contains("[*:") ?? false),
              components.user == nil, components.password == nil,
              schemes == nil || components.host?.isEmpty == false,
              schemes == nil || schemes!.contains(scheme.lowercased()) else {
            throw IntegrationError.invalid("Invalid URL scheme, authority or credentials")
        }
        let value = try context.expand(template, urlEncoded: true)
        guard URL(string: value) != nil else { throw IntegrationError.invalid("Invalid URL") }
        return value
    }
}

/// Transport evidence is deliberately separate from the command engine's readback/device verdict.
public struct IntegrationReceipt: Hashable, Codable, Sendable {
    public enum Outcome: String, Codable, Sendable { case noOp, dispatched, processExited, transportCompleted, failed, cancelled, timedOut, outputLimit }
    public var outcome: Outcome
    public var exitCode: Int32?
    public var httpStatus: Int?
    public var stdout: String
    public var stderr: String
    public var processMayBeRunning: Bool
    public var commandResult: AutomationResult?
    public var detail: String?
    public init(_ outcome: Outcome, exitCode: Int32? = nil, httpStatus: Int? = nil,
                stdout: String = "", stderr: String = "", processMayBeRunning: Bool = false,
                commandResult: AutomationResult? = nil, detail: String? = nil) {
        self.outcome = outcome; self.exitCode = exitCode; self.httpStatus = httpStatus
        self.stdout = stdout; self.stderr = stderr; self.processMayBeRunning = processMayBeRunning
        self.commandResult = commandResult; self.detail = detail
    }
    public var failureMessage: String? {
        switch outcome {
        case .failed: return detail ?? "Action failed"
        case .cancelled: return "Action cancelled; external effects may remain"
        case .timedOut: return "Action timed out; external effects may remain"
        case .outputLimit: return "Configured output byte budget exceeded; external effects may remain"
        case .processExited where exitCode != 0: return "Process exited unsuccessfully; inspect its exit code and output"
        case .transportCompleted where httpStatus.map({ !(200..<300).contains($0) }) == true:
            return "HTTP request failed; inspect its status and response"
        default:
            if let commandResult, !commandResult.succeeded { return "Automation command failed; inspect its typed result" }
            return nil
        }
    }
    public var readableText: String? {
        switch outcome {
        case .processExited where exitCode == 0: return stdout + stderr
        case .transportCompleted where httpStatus.map({ (200..<300).contains($0) }) == true: return stdout
        default: return nil
        }
    }
}

@MainActor public protocol IntegrationActionEnvironment: AnyObject {
    func execute(_ action: IntegrationPreparedAction) async -> IntegrationReceipt
}
