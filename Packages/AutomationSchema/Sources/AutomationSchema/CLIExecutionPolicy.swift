import Foundation

public enum CLIExecutionPath: String, Codable, Sendable {
    case app, standalone

    /// Adds provenance without wrapping or replacing the existing command/result schema.
    public func annotating(_ data: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AutomationIssue(.executionFailed, "CLI result must be a JSON object")
        }
        object["servedBy"] = rawValue
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
    }
}

public enum CLIExecutionPolicy {
    /// The transport returns nil ONLY for an absent/refused endpoint before sending any bytes.
    /// Errors (including a lost reply, bad permissions or cancellation) never select standalone.
    /// Recheck app presence after an unavailable endpoint, so app startup still fails closed.
    public static func appResponse<Response>(
        exchangeIfAvailable: () async throws -> Response?,
        appIsRunning: () -> Bool
    ) async throws -> Response? {
        if let response = try await exchangeIfAvailable() { return response }
        guard !appIsRunning() else {
            throw AutomationIssue(.notReady, "FreeDisplay is running but its IPC endpoint is unavailable; no standalone command was attempted")
        }
        return nil
    }

    /// w4's standalone CLI cannot hold app-owned keep/revert, ICC or atomic offset state.
    public static func standaloneUnavailability(of command: AutomationCommandName) -> AutomationIssue? {
        switch command {
        case .adjustBrightness:
            return AutomationIssue(.capabilityUnavailable, "atomic CLI offsets require the running FreeDisplay app")
        case .setMode, .setMain, .listColorProfiles, .getColorProfile, .setColorProfile, .resetColorProfile:
            return AutomationIssue(.refusedFromSurface, "this command requires the running FreeDisplay app", subject: command.rawValue)
        default: return nil
        }
    }

    /// Legacy reads may compose providers, but must never persist their registry observations.
    /// Unknown or malformed forms are not granted a mutation exemption.
    public static func legacyMayRunWithApp(_ invocation: CLIInvocation) -> Bool {
        let args = invocation.positional
        switch invocation.command {
        case "diagnose", "lux", "lid", "listen", "edid": return true
        case "scene": return args.isEmpty || ["list", "show", "plan"].contains(args[0])
        case "group": return args.isEmpty || args[0] == "list"
        case "layout": return args.isEmpty || args[0] == "status"
        case "favorite", "favourite": return args.first?.lowercased() == "list"
        case "ddc":
            guard args.count >= 2 else { return false }
            switch args[1].lowercased() {
            case "reset", "power": return false
            case "vcp": return args.count == 3
            default: return args.count == 2
            }
        default: return false
        }
    }
}
