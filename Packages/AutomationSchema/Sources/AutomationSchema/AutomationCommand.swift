import DisplayDomain
import Foundation

/// The automation front doors. Each one runs the same typed commands through `AutomationEngine`;
/// what differs is which commands it may run (`AutomationCommandDescriptor.surfaces`) and how it
/// renders the result.
public enum AutomationSurface: String, Hashable, Sendable, Codable, CaseIterable {
    case cli
    case url
    case http
    case appIntent
    /// The in-app command console (FD-040) — declared now so the catalog already says what it may run.
    case console

    /// The actor recorded in audit entries and result envelopes for requests from this surface.
    public var actor: Actor {
        switch self {
        case .cli: return .cli
        case .url: return .url
        case .http: return .httpAPI
        case .appIntent: return .appIntent
        case .console: return .ui
        }
    }
}

/// Stable command names — the wire contract of `POST /v1/command`, `opendisplay commands` and the
/// console. Never rename a case; add an alias in the catalog instead.
public enum AutomationCommandName: String, Hashable, Sendable, Codable, CaseIterable {
    case listDisplays
    case getCapabilities
    case getBrightness
    case setBrightness
    case adjustBrightness
    case getContrast
    case setContrast
    case listModes
    case getMode
    case setMode
    case setMain
    case listColorProfiles
    case getColorProfile
    case setColorProfile
    case resetColorProfile
    case reconnectAll
    case disconnect
}

/// One typed command with its validated arguments. Building one is the only way into the engine, so
/// a value that reached here is already in canonical units.
public enum AutomationCommand: Hashable, Sendable, Codable {
    case listDisplays
    case getCapabilities
    case getBrightness(method: BrightnessMethodRequest)
    case setBrightness(AutomationLevel, method: BrightnessMethodRequest)
    /// A relative change applied atomically against the level at execution time (FA-44).
    case adjustBrightness(AutomationLevelDelta, method: BrightnessMethodRequest)
    case getContrast
    case setContrast(AutomationLevel)
    case listModes
    case getMode
    /// `keepWithoutConfirmation` keeps a verified mode at once instead of opening the keep-or-revert
    /// countdown. Only the App Intent offers it (owner decision #20, default off); the shared parser
    /// never sets it, so no link, HTTP client or console line can skip the countdown.
    case setMode(AutomationModeSpec, keepWithoutConfirmation: Bool = false)
    case setMain
    case listColorProfiles
    case getColorProfile
    case setColorProfile(AutomationProfileSpec)
    case resetColorProfile
    case reconnectAll
    case disconnect

    public var name: AutomationCommandName {
        switch self {
        case .listDisplays: return .listDisplays
        case .getCapabilities: return .getCapabilities
        case .getBrightness: return .getBrightness
        case .setBrightness: return .setBrightness
        case .adjustBrightness: return .adjustBrightness
        case .getContrast: return .getContrast
        case .setContrast: return .setContrast
        case .listModes: return .listModes
        case .getMode: return .getMode
        case .setMode: return .setMode
        case .setMain: return .setMain
        case .listColorProfiles: return .listColorProfiles
        case .getColorProfile: return .getColorProfile
        case .setColorProfile: return .setColorProfile
        case .resetColorProfile: return .resetColorProfile
        case .reconnectAll: return .reconnectAll
        case .disconnect: return .disconnect
        }
    }
}

/// A request as every surface hands it to the engine.
public struct AutomationRequest: Hashable, Sendable, Codable {
    public var command: AutomationCommand
    /// The display selector; nil for commands without a target (and for the brightness action's
    /// documented built-in default, which its surface fills in explicitly).
    public var target: AutomationSelector?
    /// The selector as the caller wrote it, for messages.
    public var targetText: String?
    /// Resolve, validate and choose a route, but change nothing.
    public var dryRun: Bool

    public init(_ command: AutomationCommand, target: AutomationSelector? = nil, targetText: String? = nil,
                dryRun: Bool = false) {
        self.command = command
        self.target = target
        self.targetText = targetText
        self.dryRun = dryRun
    }

    /// A request aimed at one display by its stable record id — what App Intent entities and the
    /// legacy HTTP `displayId` carry.
    public static func byID(_ command: AutomationCommand, _ id: DisplayRecordID, dryRun: Bool = false) -> AutomationRequest {
        AutomationRequest(command, target: .display(.id(id)), targetText: "id:\(id.rawValue)", dryRun: dryRun)
    }
}

/// What kind of change a command makes — decides which surfaces may run it.
public enum AutomationEffect: String, Hashable, Sendable, Codable {
    /// Reads only.
    case read
    /// Changes a display setting (brightness, colour profile) without touching the arrangement.
    case setting
    /// Changes modes or the arrangement; runs only behind the app's verification/keep-or-revert path.
    case arrangement
    /// The always-available recovery action.
    case recovery
    /// Takes a display away (disconnect).
    case disruptive
}

/// Which display, if any, a command needs.
public enum AutomationTargetRequirement: String, Hashable, Sendable, Codable {
    /// No target.
    case none
    /// One display, in any state (remembered ones included).
    case anyDisplay
    /// One connected display (active or a mirror member).
    case connectedDisplay
    /// One display that is connected and showing its own desktop.
    case activeDisplay
}

/// One accepted parameter of a command, for discovery and validation.
public struct AutomationParameterSpec: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        /// A display selector (`AutomationSelector` grammar).
        case selector
        /// A level: `0…1` or `N%`.
        case level
        /// A signed change: a signed normalized offset or `±N%`.
        case delta
        case method
        /// `WxH[@Hz][@2x|@1x]` or an exact mode key.
        case mode
        /// An ICC profile file path or profile name.
        case profile
        case flag
    }

    public var name: String
    public var kind: Kind
    public var required: Bool
    public var summary: String

    public init(_ name: String, _ kind: Kind, required: Bool, _ summary: String) {
        self.name = name
        self.kind = kind
        self.required = required
        self.summary = summary
    }
}

/// Everything the engine and the surfaces need to know about one command (FD-066): what it changes,
/// which display it needs, its parameters and which surfaces may run it. `AutomationCatalog` holds
/// one per command; discovery (`opendisplay commands`, `GET /v1/commands`) prints them.
public struct AutomationCommandDescriptor: Hashable, Sendable, Codable {
    public var name: AutomationCommandName
    /// Other spellings `AutomationRequestParser` accepts for the verb (normalized: lowercase, no
    /// `-`/`_`). Some aliases pick between commands by their parameters — see the parser.
    public var aliases: [String]
    public var summary: String
    public var effect: AutomationEffect
    public var target: AutomationTargetRequirement
    public var parameters: [AutomationParameterSpec]
    public var surfaces: Set<AutomationSurface>

    public init(name: AutomationCommandName, aliases: [String] = [], summary: String, effect: AutomationEffect,
                target: AutomationTargetRequirement, parameters: [AutomationParameterSpec] = [],
                surfaces: Set<AutomationSurface>) {
        self.name = name
        self.aliases = aliases
        self.summary = summary
        self.effect = effect
        self.target = target
        self.parameters = parameters
        self.surfaces = surfaces
    }
}

/// The command catalog — the single list every surface dispatches from (FD-066).
///
/// To add a command: add an `AutomationCommandName` + `AutomationCommand` case, a descriptor here,
/// its parameter handling in `AutomationRequestParser`, its step in `AutomationEngine`, and the
/// primitive it needs in `AutomationEnvironment` (with a default that refuses it, so surfaces that
/// can't run it say so). See HANDOVER-command-model.md in the notes folder for the full checklist.
public enum AutomationCatalog {
    private static let display = AutomationParameterSpec(
        "display", .selector, required: true, "The display: id:<id>, alias:<name>, tag:<tag>, name:<name>, nameLike:<text>, main, builtin, pointer, group:<name> or a display number.")
    private static let method = AutomationParameterSpec(
        "method", .method, required: false, "automatic (default), hardware (never software dimming), native, ddc or software.")

    /// Every surface that drives the app's live model.
    private static let appSurfaces: Set<AutomationSurface> = [.cli, .http, .appIntent, .console]

    public static let descriptors: [AutomationCommandDescriptor] = [
        .init(name: .listDisplays, aliases: ["list", "displays"],
              summary: "Lists the displays automation can name, connected or remembered.",
              effect: .read, target: .none, surfaces: [.cli, .http, .appIntent, .console]),
        .init(name: .getCapabilities, aliases: ["capabilities"],
              summary: "Reports command admission and brightness routes for one display on this surface.",
              effect: .read, target: .anyDisplay, parameters: [display],
              surfaces: [.cli, .http, .appIntent, .console]),
        .init(name: .getBrightness, aliases: ["brightness"],
              summary: "Reads a display's brightness (0…1) and says which route reported it.",
              effect: .read, target: .activeDisplay, parameters: [display, method],
              surfaces: [.cli, .http, .appIntent, .console]),
        .init(name: .setBrightness, aliases: ["brightness"],
              summary: "Sets a display's brightness to an absolute level and reports the level read back.",
              effect: .setting, target: .activeDisplay,
              parameters: [display, .init("value", .level, required: true, "0…1, or a percentage like 40%."), method],
              surfaces: [.cli, .http, .appIntent, .console]),
        .init(name: .adjustBrightness, aliases: ["brightness"],
              summary: "Changes a display's brightness by a signed amount, clamped at the ends of its range.",
              effect: .setting, target: .activeDisplay,
              parameters: [display, .init("offset", .delta, required: true, "A signed normalized offset, or percentage points like +5% or -5%."), method],
              surfaces: [.cli, .http, .appIntent, .console]),
        .init(name: .getContrast, aliases: ["contrast"],
              summary: "Reads managed hardware contrast in normalized units, with raw readback when available.",
              effect: .read, target: .activeDisplay, parameters: [display], surfaces: appSurfaces),
        .init(name: .setContrast, aliases: ["contrast"],
              summary: "Sets managed hardware contrast through the running app and reports readback; never software contrast.",
              effect: .setting, target: .activeDisplay,
              parameters: [display, .init("value", .level, required: true, "0…1, or an explicit percentage.")], surfaces: appSurfaces),
        .init(name: .listModes, aliases: ["modes"],
              summary: "Lists every exact mode a connected display offers, current mode first.",
              effect: .read, target: .activeDisplay, parameters: [display],
              surfaces: [.cli, .http, .appIntent, .console]),
        .init(name: .getMode, aliases: ["mode"],
              summary: "Reads a display's current mode: logical size, pixels, refresh rate, HiDPI and depth.",
              effect: .read, target: .activeDisplay, parameters: [display],
              surfaces: [.cli, .http, .appIntent, .console]),
        .init(name: .setMode, aliases: ["mode"],
              summary: "Switches a display to one exact offered mode behind the keep-or-revert countdown.",
              effect: .arrangement, target: .activeDisplay,
              parameters: [display, .init("mode", .mode, required: true, "WxH[@Hz][@2x|@1x] or an exact mode key; must match exactly one offered mode.")],
              surfaces: appSurfaces),
        // CLI requests use the running app's keep-or-revert path over same-user IPC.
        .init(name: .setMain, aliases: ["main"],
              summary: "Makes a connected display the main display, keeping the arrangement.",
              effect: .arrangement, target: .activeDisplay, parameters: [display], surfaces: appSurfaces),
        .init(name: .listColorProfiles, aliases: ["profiles", "colorprofiles"],
              summary: "Lists the installed display ICC profiles.",
              effect: .read, target: .none, surfaces: appSurfaces),
        .init(name: .getColorProfile, aliases: ["profile", "colorprofile"],
              summary: "Reads a display's ICC profile assignment.",
              effect: .read, target: .activeDisplay, parameters: [display], surfaces: appSurfaces),
        .init(name: .setColorProfile, aliases: ["profile", "colorprofile"],
              summary: "Assigns an installed ICC profile to a display and confirms ColorSync reports it.",
              effect: .setting, target: .activeDisplay,
              parameters: [display, .init("profile", .profile, required: true, "The profile's file path, or its name when only one installed profile has it.")],
              surfaces: appSurfaces),
        .init(name: .resetColorProfile, aliases: ["resetprofile"],
              summary: "Returns a display to its factory ICC profile.",
              effect: .setting, target: .activeDisplay, parameters: [display], surfaces: appSurfaces),
        .init(name: .reconnectAll,
              summary: "Reconnects every display FreeDisplay turned off — the always-available recovery action.",
              effect: .recovery, target: .none, surfaces: [.cli, .url, .http, .appIntent, .console]),
        .init(name: .disconnect,
              summary: "Turns one display off; refused when it would leave no usable screen.",
              effect: .disruptive, target: .activeDisplay, parameters: [display],
              surfaces: [.cli]),
    ]

    public static func descriptor(for name: AutomationCommandName) -> AutomationCommandDescriptor {
        // Every name has a descriptor; the catalog test guards it.
        descriptors.first { $0.name == name }!
    }

    /// The descriptors a surface may run.
    public static func descriptors(for surface: AutomationSurface) -> [AutomationCommandDescriptor] {
        descriptors.filter { $0.surfaces.contains(surface) }
    }

    /// A verb in its matching form: lowercase, without `-` or `_`.
    public static func normalize(_ verb: String) -> String {
        verb.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
    }
}

/// A mode as a request names it (FA-18, TB-06). Matching never manufactures or approximates a mode:
/// the request must pick exactly one offered mode, or it fails naming what it matched.
public enum AutomationModeSpec: Hashable, Sendable, Codable {
    /// Every field of an exact mode (what a stored mode key or an App Intent mode entity carries).
    case exact(DisplayMode)
    /// A logical size with optional refresh rate and density; unspecified parts match any value.
    case logical(width: Int, height: Int, refreshHz: Double?, hiDPI: Bool?)

    /// `2560x1440`, `2560x1440@60`, `1512x982@120@2x`, `1920x1080@1x`, or an exact mode key.
    public static func parse(_ text: String, parameter: String = "mode") throws(AutomationIssue) -> AutomationModeSpec {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let exact = FavoriteResolutions.storedMode(forKey: trimmed) { return .exact(exact) }
        var parts = trimmed.lowercased().split(separator: "@", omittingEmptySubsequences: false).map(String.init)
        var hiDPI: Bool?
        if let last = parts.last, parts.count > 1, last == "2x" || last == "1x" {
            hiDPI = last == "2x"
            parts.removeLast()
        }
        guard (1...2).contains(parts.count) else {
            throw .invalidValue(parameter, "'\(text)' is not a mode (use WxH, WxH@Hz, add @2x or @1x for density)")
        }
        let size = parts[0].split(separator: "x", omittingEmptySubsequences: false)
        guard size.count == 2, let width = Int(size[0]), let height = Int(size[1]), width > 0, height > 0 else {
            throw .invalidValue(parameter, "'\(text)' is not a mode (use WxH, WxH@Hz, add @2x or @1x for density)")
        }
        var refresh: Double?
        if parts.count == 2 {
            guard let hz = Double(parts[1]), hz.isFinite, hz > 0 else {
                throw .invalidValue(parameter, "'\(parts[1])' is not a refresh rate in Hz")
            }
            refresh = hz
        }
        return .logical(width: width, height: height, refreshHz: refresh, hiDPI: hiDPI)
    }

    public func matches(_ mode: DisplayMode) -> Bool {
        switch self {
        case .exact(let requested):
            return DisplayModeChoices.matches(mode, requested: requested)
        case .logical(let width, let height, let refreshHz, let hiDPI):
            return mode.pointWidth == width && mode.pointHeight == height
                && (hiDPI == nil || mode.isHiDPI == hiDPI)
                // The same refresh tolerance favourites use, so `@60` never picks 59.94 Hz.
                && (refreshHz == nil || abs(mode.refreshHz - refreshHz!) < 0.01)
        }
    }

    /// The one offered mode this spec names. None is `modeNotOffered`; several is `ambiguousMode`
    /// listing their exact keys, so the caller can repeat the request with one of them.
    public func resolve(among offered: [DisplayMode], displayName: String) throws(AutomationIssue) -> DisplayMode {
        var unique: [DisplayMode] = []
        for mode in offered where matches(mode) && !unique.contains(mode) { unique.append(mode) }
        guard !unique.isEmpty else {
            throw AutomationIssue(.modeNotOffered, "\(displayName) doesn't offer \(description) right now",
                                  subject: description)
        }
        guard unique.count == 1 else {
            let keys = unique.map(FavoriteResolutions.key(for:))
            throw AutomationIssue(.ambiguousMode,
                                  "\(description) matches \(unique.count) modes on \(displayName); name one exactly: \(keys.joined(separator: ", "))",
                                  subject: description, candidates: keys)
        }
        return unique[0]
    }

    public var description: String {
        switch self {
        case .exact(let mode): return FavoriteResolutions.key(for: mode)
        case .logical(let width, let height, let refreshHz, let hiDPI):
            var text = "\(width)x\(height)"
            if let refreshHz { text += "@" + String(format: "%g", refreshHz) }
            if let hiDPI { text += hiDPI ? "@2x" : "@1x" }
            return text
        }
    }
}

/// An installed ICC profile as automation lists and names it. The id is the standardized file path:
/// two files can carry the same description and are still different profiles.
public struct AutomationProfileInfo: Hashable, Sendable, Codable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// An ICC profile as a request names it: a file path (exact), or a name that must match exactly one
/// installed profile.
public enum AutomationProfileSpec: Hashable, Sendable, Codable {
    case path(String)
    case name(String)

    public static func parse(_ text: String, parameter: String = "profile") throws(AutomationIssue) -> AutomationProfileSpec {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw .invalidValue(parameter, "the profile is empty") }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return .path((trimmed as NSString).expandingTildeInPath)
        }
        return .name(trimmed)
    }

    public func resolve(among installed: [AutomationProfileInfo]) throws(AutomationIssue) -> AutomationProfileInfo {
        let matches: [AutomationProfileInfo]
        switch self {
        case .path(let path):
            let wanted = URL(fileURLWithPath: path).standardizedFileURL.path
            matches = installed.filter { URL(fileURLWithPath: $0.id).standardizedFileURL.path == wanted }
        case .name(let name):
            matches = installed.filter { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        }
        guard !matches.isEmpty else {
            throw AutomationIssue(.profileNotFound, "no installed display profile matches '\(description)'",
                                  subject: description)
        }
        guard matches.count == 1 else {
            throw AutomationIssue(.ambiguousProfile,
                                  "\(matches.count) installed profiles are named '\(description)'; name one by its file path",
                                  subject: description, candidates: matches.map(\.id))
        }
        return matches[0]
    }

    public var description: String {
        switch self {
        case .path(let path): return path
        case .name(let name): return name
        }
    }
}
