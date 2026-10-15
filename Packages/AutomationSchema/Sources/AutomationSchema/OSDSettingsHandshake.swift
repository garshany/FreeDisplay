import Foundation

/// The wire format of the OSD settings handshake (IN-16): how a receiver app — one that draws its own
/// HUD from `OSDBroadcast` events — reads OpenDisplay's feedback settings, takes them over (events
/// on, OpenDisplay's own HUD off) and gives them back. FreeDisplay's own versioned protocol under its
/// own names; it makes no claim to be compatible with any other app's.
///
/// Requests and responses travel as a JSON string in the distributed notification's `object`, not in
/// `userInfo`: a sandboxed app may only post distributed notifications without `userInfo`, and
/// receivers often are sandboxed.
/// A receiver subscribes to the response name before posting a request and matches responses by the
/// `uuid` it sent. When the app isn't running, nothing answers.
public enum OSDSettingsHandshake {
    public static let schemaVersion = 1
    public static let requestNotificationName = "dev.opendisplay.osd.settings.request"
    public static let responseNotificationName = "dev.opendisplay.osd.settings.response"

    public enum Command: String, Hashable, Sendable, Codable {
        /// Read the current settings and who, if anyone, has them.
        case get
        /// Take the settings over: publish events and hide the HUDs the receiver replaces. What the
        /// user had is remembered for `release`.
        case claim
        /// Give them back: every setting the claim changed, and the user hasn't changed since,
        /// returns to what it was.
        case release
    }

    public struct Request: Hashable, Sendable, Codable {
        public var version: Int?
        /// Echoed in the response, for matching.
        public var uuid: String?
        public var command: Command
        /// The receiver's name, shown to the user while it holds the settings. Required for
        /// `claim` and `release`.
        public var receiver: String?
        /// `claim`: hide OpenDisplay's brightness/volume/mute HUD. Absent means yes — that is what a
        /// receiver replaces.
        public var hideBasic: Bool?
        /// `claim`: hide OpenDisplay's other feedback (the input switch). Absent means no.
        public var hideCustom: Bool?

        public init(command: Command, uuid: String? = nil, receiver: String? = nil,
                    hideBasic: Bool? = nil, hideCustom: Bool? = nil) {
            self.version = OSDSettingsHandshake.schemaVersion
            self.uuid = uuid
            self.command = command
            self.receiver = receiver
            self.hideBasic = hideBasic
            self.hideCustom = hideCustom
        }

        public var jsonString: String { OSDSettingsHandshake.encode(self) }
    }

    public struct Response: Hashable, Sendable, Codable {
        public enum Result: String, Hashable, Sendable, Codable {
            /// Done; the settings fields say how things stand now.
            case ok
            /// Another receiver holds the settings (`claimedBy`); nothing changed.
            case refused
            /// `release` from a receiver that holds nothing; nothing changed.
            case notClaimed
            /// The user hasn't allowed receivers to use the handshake. No settings are reported.
            case disabled
            /// The request couldn't be read; nothing changed.
            case malformed
        }

        public var version: Int
        public var uuid: String?
        public var result: Result
        /// OpenDisplay draws its own brightness/volume/mute HUD.
        public var showsBasic: Bool?
        /// OpenDisplay draws its other feedback.
        public var showsCustom: Bool?
        /// `OSDBroadcast` events are being published.
        public var publishing: Bool?
        /// The receiver holding the settings, if one does.
        public var claimedBy: String?

        public init(result: Result, uuid: String? = nil, showsBasic: Bool? = nil, showsCustom: Bool? = nil,
                    publishing: Bool? = nil, claimedBy: String? = nil) {
            self.version = OSDSettingsHandshake.schemaVersion
            self.uuid = uuid
            self.result = result
            self.showsBasic = showsBasic
            self.showsCustom = showsCustom
            self.publishing = publishing
            self.claimedBy = claimedBy
        }

        public var jsonString: String { OSDSettingsHandshake.encode(self) }

        public static func decode(_ object: String?) -> Response? {
            guard let data = object?.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(Response.self, from: data)
        }
    }

    /// A request as read off the wire.
    public enum Incoming: Hashable, Sendable {
        case request(Request)
        /// Not a request this version understands — not JSON, not an object, or no known command.
        /// The uuid is kept when it could be read, so the sender still gets an answer it can match.
        case malformed(uuid: String?)
    }

    /// Reads a notification object. Never throws and never traps, whatever another process sends.
    public static func decode(_ object: Any?) -> Incoming {
        guard let text = object as? String, let data = text.data(using: .utf8) else { return .malformed(uuid: nil) }
        if let request = try? JSONDecoder().decode(Request.self, from: data),
           request.version == nil || request.version == schemaVersion { return .request(request) }
        let uuid = (try? JSONSerialization.jsonObject(with: data)).flatMap { ($0 as? [String: Any])?["uuid"] as? String }
        return .malformed(uuid: uuid)
    }

    fileprivate static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
