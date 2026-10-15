import Foundation

/// Positional CLI spelling is an edge adapter only. Selectors, units, methods, mode/profile matching
/// and command admission remain the shared parser/engine's responsibility.
public enum CLIAppRequest {
    public static let commands: Set<String> = [
        "list", "recover", "disconnect", "brightness", "contrast", "mode", "capabilities",
        "main", "profile", "profiles", "command", "ready"
    ]
    public static func timeout(_ invocation: CLIInvocation) throws(AutomationIssue) -> TimeInterval? {
        guard let text = invocation.values["--timeout"] else { return nil }
        guard let value = Double(text), value.isFinite, value > 0 else {
            throw .invalidValue("timeout", "expected finite positive seconds")
        }
        return value
    }
    /// nil is a readiness request. No providers or persistent settings are consulted here.
    public static func request(_ invocation: CLIInvocation) throws(AutomationIssue) -> AutomationRequest? {
        var parameters: [String: AutomationParameterValue] = [:]
        let args = invocation.positional
        let verb: String
        switch invocation.command {
        case "ready", "list", "recover", "profiles":
            guard args.isEmpty else { throw .invalidValue("arguments", "this command takes no positional arguments") }
            if invocation.command == "ready" { return nil }
            verb = ["list": "listDisplays", "recover": "reconnectAll", "profiles": "listColorProfiles"][invocation.command]!
        case "command":
            guard let name = args.first else { throw .missing("command", for: "command") }
            verb = name
            for item in args.dropFirst() {
                let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2, !pair[0].isEmpty else { throw .invalidValue("parameter", "expected name=value") }
                let key = String(pair[0])
                guard parameters[key] == nil else { throw AutomationIssue(.conflictingParameters, "duplicate parameter", subject: key) }
                parameters[key] = .string(String(pair[1]))
            }
        default:
            guard let selector = args.first, args.count <= 2 else {
                throw .missing("display", for: invocation.command)
            }
            parameters["display"] = .string(selector)
            switch invocation.command {
            case "brightness", "contrast":
                verb = invocation.command
                if args.count == 2 { parameters["value"] = .string(args[1]) }
                if let method = invocation.values["--method"] { parameters["method"] = .string(method) }
                if let offset = invocation.values["--offset"] { parameters["offset"] = .string(offset) }
            case "mode":
                verb = args.count == 2 ? "setMode" : "listModes"
                if args.count == 2 { parameters["mode"] = .string(args[1]) }
            case "profile":
                verb = "profile"
                if args.count == 2 { parameters["profile"] = .string(args[1]) }
            case "main", "disconnect", "capabilities":
                guard args.count == 1 else { throw .invalidValue("arguments", "expected one selector") }
                verb = ["main": "setMain", "disconnect": "disconnect", "capabilities": "getCapabilities"][invocation.command]!
            default: throw AutomationIssue(.unknownCommand, "not an app IPC command")
            }
        }
        if invocation.flags.contains("--dry-run") { parameters["dryRun"] = .bool(true) }
        return try AutomationRequestParser.parse(verb: verb, parameters: parameters)
    }
}
