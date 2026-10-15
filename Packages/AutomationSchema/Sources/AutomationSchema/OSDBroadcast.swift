import Foundation

/// A stable, cross-process payload describing one OSD event (Batch-3 #6), published over
/// `DistributedNotificationCenter` so external/notch HUD apps can render OpenDisplay's brightness/
/// volume changes. Versioned and tolerant, like `URLCommand` and `DDCPowerMode`.
///
/// Receiver contract (IN-16): every field beyond kind, display and source is optional and new ones
/// are only ever added. A receiver ignores keys it doesn't know, skips an event whose `kind` it
/// doesn't know, and draws what it can from the rest — an icon from `symbol`, a line from `text` —
/// when there is no `value` or no usable `maxValue`. FreeDisplay's own protocol; no compatibility
/// with any other app's notifications is claimed.
public struct OSDBroadcast: Hashable, Sendable, Codable {
    /// Current schema version (bump on any breaking field change).
    public static let schemaVersion = 1
    /// The `DistributedNotificationCenter` name subscribers listen on.
    public static let notificationName = "dev.opendisplay.osd"

    public enum Kind: String, Hashable, Sendable, Codable {
        case brightness
        case volume
        case mute
        /// A display switched to another input (IN-16/T30). Has no level: `text` names the input.
        case input
    }

    /// How far the event's level is known to be true (TR-17) — the `state` key.
    public enum State: String, Hashable, Sendable, CaseIterable {
        /// OpenDisplay itself carries the change (software dimming).
        case applied
        /// Sent to the display; not read back.
        case requested
        /// The display reported the value.
        case verified
    }

    /// Where a change came from — the vocabulary of `source`. Kept as a `String` on the wire so a
    /// newer sender's source never makes an older receiver drop the event.
    public enum Source: String, Hashable, Sendable, CaseIterable {
        /// A slider in the menu-bar panel or Settings.
        case menu
        /// A brightness/volume/mute media key the app intercepted.
        case mediaKey
        /// One of the app's global keyboard shortcuts.
        case hotkey
        /// The local HTTP control server.
        case http
        /// The `opendisplay` command-line tool.
        case cli
        /// A Shortcuts / Siri App Intent.
        case appIntent
        /// OpenDisplay itself (FaceLight, presets, restoring a prior level).
        case app
        /// The bar of OpenDisplay's interactive on-screen display.
        case osd
        /// A display group carrying its leader's change to this display (owner decision #8): the
        /// follower's own event, published once per follower write.
        case groupSync
    }

    public var version: Int
    public var kind: Kind
    /// Normalized level, clamped to 0...1. Nil for an event with no level (an input switch).
    public var value: Double?
    /// The top of the scale `value` is on, so a receiver never has to assume one. Senders set it
    /// to 1 (levels are normalized); nil when an older sender did not say.
    public var maxValue: Double?
    /// The display's stable record id.
    public var displayID: String
    /// The display's user-facing name, when known.
    public var displayName: String?
    /// Where the change came from — one of `Source`'s raw values ("menu", "mediaKey", "hotkey",
    /// "http", "cli", "appIntent", "app"); receivers must tolerate others.
    public var source: String
    /// Seconds since 1970 (kept numeric so the dictionary form stays plist/string-clean).
    public var timestamp: Double
    /// The Core Graphics display number of the screen OpenDisplay chose for feedback — a hint for
    /// where a receiver might draw. Not an identity: use `displayID` for that.
    public var screenID: UInt32?
    /// The SF Symbol OpenDisplay's own HUD shows for this event.
    public var symbol: String?
    /// A short line to show — the input's name for `.input`.
    public var text: String?
    /// What carried the change, e.g. "software", "native", "ddc" — receivers must tolerate others.
    public var control: String?
    /// One of `State`'s raw values; receivers must tolerate others.
    public var state: String?

    public init(
        kind: Kind,
        value: Double?,
        maxValue: Double? = nil,
        displayID: String,
        displayName: String? = nil,
        source: String,
        timestamp: Double,
        screenID: UInt32? = nil,
        symbol: String? = nil,
        text: String? = nil,
        control: String? = nil,
        state: String? = nil
    ) {
        self.version = Self.schemaVersion
        self.kind = kind
        self.value = value.map { Swift.max(0, Swift.min(1, $0)) }
        self.maxValue = maxValue
        self.displayID = displayID
        self.displayName = displayName
        self.source = source
        self.timestamp = timestamp
        self.screenID = screenID
        self.symbol = symbol
        self.text = text
        self.control = control
        self.state = state
    }

    /// String-only dictionary for `DistributedNotificationCenter` userInfo (cross-process safe).
    public var userInfo: [String: String] {
        var info: [String: String] = [
            "version": String(version),
            "kind": kind.rawValue,
            "displayID": displayID,
            "source": source,
            "timestamp": String(timestamp),
        ]
        if let value { info["value"] = String(value) }
        if let displayName { info["displayName"] = displayName }
        if let maxValue { info["maxValue"] = String(maxValue) }
        if let screenID { info["screenID"] = String(screenID) }
        if let symbol { info["symbol"] = symbol }
        if let text { info["text"] = text }
        if let control { info["control"] = control }
        if let state { info["state"] = state }
        return info
    }

    /// Reconstruct from a distributed-notification userInfo dictionary. Tolerant: a missing required
    /// field or a kind this version doesn't know returns nil; unknown extra keys are ignored; an
    /// out-of-range value is clamped. A level kind needs a level; `.input` has none.
    public init?(userInfo: [String: String]) {
        guard let kindRaw = userInfo["kind"], let kind = Kind(rawValue: kindRaw),
              let displayID = userInfo["displayID"], !displayID.isEmpty,
              let source = userInfo["source"]
        else { return nil }
        let value = userInfo["value"].flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
        if kind != .input, value == nil { return nil }
        let timestamp = userInfo["timestamp"].flatMap(Double.init) ?? 0
        // A malformed, zero or negative maximum is dropped rather than failing the event: `value`
        // is still a usable normalized level on its own.
        let maxValue = userInfo["maxValue"].flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.init(kind: kind, value: value, maxValue: maxValue, displayID: displayID,
                  displayName: userInfo["displayName"], source: source, timestamp: timestamp,
                  screenID: userInfo["screenID"].flatMap(UInt32.init), symbol: userInfo["symbol"],
                  text: userInfo["text"], control: userInfo["control"], state: userInfo["state"])
        if let parsedVersion = userInfo["version"].flatMap(Int.init) { self.version = parsedVersion }
    }
}
