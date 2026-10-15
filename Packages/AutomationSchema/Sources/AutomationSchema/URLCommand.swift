import DisplayDomain
import Foundation

/// A command parsed from an `opendisplay://` URL. The URL scheme is a third automation front door
/// (alongside the CLI and App Intents); like them it routes onto the shared `CommandGateway`, so it
/// inherits the same safety, verification, and audit path.
///
/// Security: a URL can be triggered by any app or web link, so only non-destructive recovery actions
/// are safe to auto-run. Arrangement-altering commands are still *parsed*, but flagged
/// `requiresConfirmation` so the host never applies them silently. The app has no in-app review
/// flow for them and refuses them with a visible explanation; a host that adds one must confirm
/// before acting.
public enum URLCommand: Hashable, Sendable {
    /// Reconnect every managed-offline display — the always-available recovery action. Safe to auto-run.
    case reconnectAll
    /// Logically disconnect the display named by `selector`. Arrangement-altering → must be confirmed
    /// in-app, never fired silently from a URL.
    case disconnect(selector: String)

    /// True for commands that change the active arrangement or are otherwise destructive. The URL
    /// handler must NOT execute these without explicit in-app confirmation.
    public var requiresConfirmation: Bool {
        switch self {
        case .reconnectAll: return false
        case .disconnect: return true
        }
    }

    /// Stable short name for logs and the audit trail.
    public var name: String {
        switch self {
        case .reconnectAll: return "reconnectAll"
        case .disconnect: return "disconnect"
        }
    }
}

/// Parses `opendisplay://` URLs. `parseRequest` is the typed path (FD-066): the verb is the URL host
/// (`opendisplay://reconnect-all`, or a path form), query items are named parameters, and both go
/// through `AutomationRequestParser` like every other key/value surface. Which parsed commands a link
/// may actually run is the engine's decision (`AutomationCatalog` surfaces), not the parser's.
///
/// `parse` keeps the original two-command answer for callers and tests written against it.
public enum URLCommandParser {
    public static let scheme = "opendisplay"

    /// The request a URL asks for: nil when it isn't an `opendisplay://` URL or names no verb,
    /// `.failure` when the verb or its parameters are invalid.
    ///
    /// A repeated query item takes its last value; `target` is the original spelling of `display`.
    /// `x-`-prefixed items (x-callback-url's `x-source`, `x-success`, …) are dropped: no callback is
    /// implemented, and a launcher adding them must not make the recovery link fail.
    public static func parseRequest(_ url: URL) -> Result<AutomationRequest, AutomationIssue>? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // The verb is the URL host (opendisplay://reconnect-all); tolerate a path form too.
        let host = components?.host ?? url.host
        let pathVerb = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let verb = (host?.isEmpty == false ? host : nil) ?? pathVerb
        guard !verb.isEmpty else { return nil }

        var parameters: [String: AutomationParameterValue] = [:]
        for item in components?.queryItems ?? [] {
            guard let value = item.value else { continue }
            let name = item.name.lowercased()
            guard !name.hasPrefix("x-") else { continue }
            parameters[name == "target" ? "display" : name] = .string(value)
        }
        do {
            return .success(try AutomationRequestParser.parse(verb: verb, parameters: parameters))
        } catch {
            return .failure(error)
        }
    }

    /// The original two-command reading: reconnect-all, or a disconnect with its selector text. Any
    /// other URL — malformed, unknown, or a command links don't carry — is nil.
    public static func parse(_ url: URL) -> URLCommand? {
        guard case .success(let request)? = parseRequest(url) else { return nil }
        switch request.command {
        case .reconnectAll: return .reconnectAll
        case .disconnect: return request.targetText.map(URLCommand.disconnect(selector:))
        default: return nil
        }
    }
}
