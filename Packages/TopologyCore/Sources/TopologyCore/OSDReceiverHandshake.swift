import AutomationSchema
import Foundation

/// A receiver app holding OpenDisplay's feedback settings (IN-16): who it is, what the user had
/// before, and what the claim set. Persisted with the settings, so a receiver that quits or crashes
/// without giving them back leaves a record the user can restore from.
public struct OSDReceiverClaim: Hashable, Sendable, Codable {
    /// The three settings a claim may change.
    public struct Snapshot: Hashable, Sendable, Codable {
        /// The basic (brightness/volume/mute) feedback switch, `osdEnabled`.
        public var showsBasicFeedback: Bool
        public var showsCustomFeedback: Bool
        public var publishing: Bool

        public init(showsBasicFeedback: Bool, showsCustomFeedback: Bool, publishing: Bool) {
            self.showsBasicFeedback = showsBasicFeedback
            self.showsCustomFeedback = showsCustomFeedback
            self.publishing = publishing
        }

        public init(_ settings: OpenDisplaySettings) {
            self.init(showsBasicFeedback: settings.osdEnabled,
                      showsCustomFeedback: settings.osdFeedback.showsCustomFeedback,
                      publishing: settings.publishOSDEventsEnabled)
        }
    }

    public var receiver: String
    /// The user's settings before the claim — what a release gives back.
    public var prior: Snapshot
    /// The settings as the claim left them. A field that no longer matches was changed by the user
    /// afterwards, and a release leaves it as the user set it.
    public var applied: Snapshot

    public init(receiver: String, prior: Snapshot, applied: Snapshot) {
        self.receiver = receiver
        self.prior = prior
        self.applied = applied
    }
}

/// Answers `OSDSettingsHandshake` requests against the settings (IN-16). Pure: the app passes the
/// settings in, saves what comes back and posts the response.
public enum OSDReceiverHandshake {
    public static func handle(_ incoming: OSDSettingsHandshake.Incoming,
                              settings: inout OpenDisplaySettings) -> OSDSettingsHandshake.Response {
        guard settings.osdFeedback.receiverHandshakeEnabled else {
            // Says only that the door is shut — no settings are reported to an app the user hasn't
            // let in.
            switch incoming {
            case .request(let request): return .init(result: .disabled, uuid: request.uuid)
            case .malformed(let uuid): return .init(result: .disabled, uuid: uuid)
            }
        }
        guard case .request(let request) = incoming else {
            if case .malformed(let uuid) = incoming { return state(.malformed, uuid: uuid, settings: settings) }
            return state(.malformed, uuid: nil, settings: settings)
        }
        switch request.command {
        case .get:
            return state(.ok, uuid: request.uuid, settings: settings)
        case .claim:
            guard let receiver = displayName(request.receiver) else {
                return state(.malformed, uuid: request.uuid, settings: settings)
            }
            if let holder = settings.osdFeedback.receiverClaim, holder.receiver != receiver {
                return state(.refused, uuid: request.uuid, settings: settings)
            }
            claim(for: receiver, hideBasic: request.hideBasic ?? true, hideCustom: request.hideCustom ?? false,
                  settings: &settings)
            return state(.ok, uuid: request.uuid, settings: settings)
        case .release:
            guard let receiver = displayName(request.receiver) else {
                return state(.malformed, uuid: request.uuid, settings: settings)
            }
            guard settings.osdFeedback.receiverClaim?.receiver == receiver else {
                return state(.notClaimed, uuid: request.uuid, settings: settings)
            }
            release(&settings)
            return state(.ok, uuid: request.uuid, settings: settings)
        }
    }

    /// Takes the settings over for `receiver`. A receiver claiming again keeps the snapshot from its
    /// first claim, so a second claim can't make OpenDisplay forget what the user had.
    public static func claim(for receiver: String, hideBasic: Bool, hideCustom: Bool,
                             settings: inout OpenDisplaySettings) {
        let prior = settings.osdFeedback.receiverClaim?.prior ?? OSDReceiverClaim.Snapshot(settings)
        // Events on — they are what the receiver draws from. Each HUD it replaces is switched off by
        // its own switch, so one it doesn't replace stays exactly as the user had it. The style is
        // never touched: "External HUD only" stays the user's own choice.
        settings.publishOSDEventsEnabled = true
        settings.osdEnabled = hideBasic ? false : prior.showsBasicFeedback
        settings.osdFeedback.showsCustomFeedback = hideCustom ? false : prior.showsCustomFeedback
        settings.osdFeedback.receiverClaim = OSDReceiverClaim(
            receiver: receiver, prior: prior, applied: OSDReceiverClaim.Snapshot(settings))
    }

    /// Gives the settings back: each one the claim changed returns to what the user had, unless the
    /// user has changed it since — then the user's newer choice stands. Clears the claim. Also what
    /// Settings' "Restore" does when a receiver never gave them back.
    public static func release(_ settings: inout OpenDisplaySettings) {
        guard let claim = settings.osdFeedback.receiverClaim else { return }
        if settings.osdEnabled == claim.applied.showsBasicFeedback { settings.osdEnabled = claim.prior.showsBasicFeedback }
        if settings.osdFeedback.showsCustomFeedback == claim.applied.showsCustomFeedback {
            settings.osdFeedback.showsCustomFeedback = claim.prior.showsCustomFeedback
        }
        if settings.publishOSDEventsEnabled == claim.applied.publishing {
            settings.publishOSDEventsEnabled = claim.prior.publishing
        }
        settings.osdFeedback.receiverClaim = nil
    }

    /// A receiver name fit to show: control characters (line breaks, escapes) become spaces and the
    /// ends are trimmed. Nil when nothing is left. Another process chose it, so it is shown as
    /// plain text and never interpreted.
    public static func displayName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func state(_ result: OSDSettingsHandshake.Response.Result, uuid: String?,
                              settings: OpenDisplaySettings) -> OSDSettingsHandshake.Response {
        .init(result: result, uuid: uuid,
              showsBasic: settings.osdEnabled && settings.osdStyle != .external,
              showsCustom: settings.osdStyle != .external && settings.osdFeedback.showsCustomFeedback,
              publishing: settings.publishOSDEventsEnabled,
              claimedBy: settings.osdFeedback.receiverClaim?.receiver)
    }
}
