import Foundation

/// A stable, cross-process payload describing one OSD event (Batch-3 #6), published over
/// `DistributedNotificationCenter` so external/notch HUD apps can render OpenDisplay's brightness/
/// volume changes. Versioned and tolerant, like `URLCommand` and `DDCPowerMode`.
public struct OSDBroadcast: Hashable, Sendable, Codable {
    /// Current schema version (bump on any breaking field change).
    public static let schemaVersion = 1
    /// The `DistributedNotificationCenter` name subscribers listen on.
    public static let notificationName = "dev.opendisplay.osd"

    public enum Kind: String, Hashable, Sendable, Codable {
        case brightness
        case volume
        case mute
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
    }

    public var version: Int
    public var kind: Kind
    /// Normalized level, clamped to 0...1.
    public var value: Double
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

    public init(
        kind: Kind,
        value: Double,
        maxValue: Double? = nil,
        displayID: String,
        displayName: String? = nil,
        source: String,
        timestamp: Double
    ) {
        self.version = Self.schemaVersion
        self.kind = kind
        self.value = Swift.max(0, Swift.min(1, value))
        self.maxValue = maxValue
        self.displayID = displayID
        self.displayName = displayName
        self.source = source
        self.timestamp = timestamp
    }

    /// String-only dictionary for `DistributedNotificationCenter` userInfo (cross-process safe).
    public var userInfo: [String: String] {
        var info: [String: String] = [
            "version": String(version),
            "kind": kind.rawValue,
            "value": String(value),
            "displayID": displayID,
            "source": source,
            "timestamp": String(timestamp),
        ]
        if let displayName { info["displayName"] = displayName }
        if let maxValue { info["maxValue"] = String(maxValue) }
        return info
    }

    /// Reconstruct from a distributed-notification userInfo dictionary. Tolerant: a missing required
    /// field returns nil; unknown extra keys are ignored; an out-of-range value is clamped.
    public init?(userInfo: [String: String]) {
        guard let kindRaw = userInfo["kind"], let kind = Kind(rawValue: kindRaw),
              let valueRaw = userInfo["value"], let value = Double(valueRaw),
              let displayID = userInfo["displayID"], !displayID.isEmpty,
              let source = userInfo["source"]
        else { return nil }
        let timestamp = userInfo["timestamp"].flatMap(Double.init) ?? 0
        // A malformed, zero or negative maximum is dropped rather than failing the event: `value`
        // is still a usable normalized level on its own.
        let maxValue = userInfo["maxValue"].flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.init(kind: kind, value: value, maxValue: maxValue, displayID: displayID,
                  displayName: userInfo["displayName"], source: source, timestamp: timestamp)
        if let parsedVersion = userInfo["version"].flatMap(Int.init) { self.version = parsedVersion }
    }
}
