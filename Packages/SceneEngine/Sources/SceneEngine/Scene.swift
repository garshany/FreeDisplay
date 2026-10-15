import DisplayDomain
import Foundation

/// A named, partial desired state for displays. Omitted fields are left unchanged — a scene only
/// asserts what it explicitly sets (PRD §13.2, TOP-010).
public struct Scene: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var schemaVersion: String
    public var members: [Member]
    public var policy: Policy

    public init(
        id: String,
        name: String,
        schemaVersion: String = "1.0",
        members: [Member],
        policy: Policy = Policy()
    ) {
        self.id = id
        self.name = name
        self.schemaVersion = schemaVersion
        self.members = members
        self.policy = policy
    }

    /// One participant in a scene: a selector, whether it is required, and the fields to assert.
    public struct Member: Hashable, Sendable, Codable {
        public var selector: String
        public var required: Bool
        public var desired: DesiredState

        public init(selector: String, required: Bool, desired: DesiredState) {
            self.selector = selector
            self.required = required
            self.desired = desired
        }
    }

    public struct Policy: Hashable, Sendable, Codable {
        public enum MissingOptional: String, Hashable, Sendable, Codable {
            case continueApplying
            case skip
        }
        public enum UnsupportedField: String, Hashable, Sendable, Codable {
            case warn
            case fail
        }
        public enum WindowPlacement: String, Hashable, Sendable, Codable {
            case unchanged
            case restore
        }

        public var missingOptional: MissingOptional
        public var unsupportedField: UnsupportedField
        public var windowPlacement: WindowPlacement
        public var rollbackOnRequiredFailure: Bool

        public init(
            missingOptional: MissingOptional = .continueApplying,
            unsupportedField: UnsupportedField = .warn,
            windowPlacement: WindowPlacement = .unchanged,
            rollbackOnRequiredFailure: Bool = true
        ) {
            self.missingOptional = missingOptional
            self.unsupportedField = unsupportedField
            self.windowPlacement = windowPlacement
            self.rollbackOnRequiredFailure = rollbackOnRequiredFailure
        }
    }
}

/// The independently-applied fields a scene member may assert. Each is optional; `nil` means
/// "leave as-is" (PRD §13.2 desired-state).
public struct DesiredState: Hashable, Sendable, Codable {
    public var connected: Bool?
    public var main: Bool?
    public var position: DisplayOrigin?
    public var relativePosition: RelativePosition?
    public var mode: DisplayMode?
    public var rotation: Rotation?
    public var brightness: Double?
    public var colorProfile: String?
    public var hdr: Bool?

    public init(
        connected: Bool? = nil,
        main: Bool? = nil,
        position: DisplayOrigin? = nil,
        relativePosition: RelativePosition? = nil,
        mode: DisplayMode? = nil,
        rotation: Rotation? = nil,
        brightness: Double? = nil,
        colorProfile: String? = nil,
        hdr: Bool? = nil
    ) {
        self.connected = connected
        self.main = main
        self.position = position
        self.relativePosition = relativePosition
        self.mode = mode
        self.rotation = rotation
        self.brightness = brightness
        self.colorProfile = colorProfile
        self.hdr = hdr
    }

    public struct RelativePosition: Hashable, Sendable, Codable {
        public var relativeToSelector: String
        public var edge: DisplaySelector.TopologyEdge
        public var gap: Int

        public init(relativeToSelector: String, edge: DisplaySelector.TopologyEdge, gap: Int = 0) {
            self.relativeToSelector = relativeToSelector
            self.edge = edge
            self.gap = gap
        }
    }
}

// MARK: - Technical validity

extension Scene {
    /// One member value that can't be used as it is.
    public struct InvalidValue: Hashable, Sendable, Codable {
        public var selector: String
        public var field: SceneApplyReport.Field

        public init(selector: String, field: SceneApplyReport.Field) {
            self.selector = selector
            self.field = field
        }
    }

    /// The member values that can't be used as they are, in member order. Scenes arrive from files
    /// anyone can edit (scenes.json, a settings archive), and these are the numbers that can't mean
    /// anything: a brightness that isn't a number in its 0...1 level domain (the same level every
    /// brightness path takes), a refresh rate that isn't a finite, non-negative number of hertz, a
    /// position Core Graphics can't take (its display origins are 32-bit). Technical validity only —
    /// any level, mode or position a display could actually have passes. A settings import refuses
    /// a file carrying one; scene apply refuses the scene before writing anything.
    public var invalidValues: [InvalidValue] {
        var invalid: [InvalidValue] = []
        for member in members {
            let desired = member.desired
            if let position = desired.position,
               Int32(exactly: position.x) == nil || Int32(exactly: position.y) == nil {
                invalid.append(InvalidValue(selector: member.selector, field: .position))
            }
            if let mode = desired.mode, !mode.refreshHz.isFinite || mode.refreshHz < 0 {
                invalid.append(InvalidValue(selector: member.selector, field: .mode))
            }
            if let brightness = desired.brightness, !brightness.isFinite || !(0...1).contains(brightness) {
                invalid.append(InvalidValue(selector: member.selector, field: .brightness))
            }
        }
        return invalid
    }
}

/// Display text for a scene's numbers that can't trap, whatever the file held: a value the
/// validity check above would refuse can still reach a dry-run plan or a report.
enum SceneValueText {
    /// "60" for a whole number of hertz, "59.94" otherwise — and for anything `Int` can't hold.
    static func refresh(_ hz: Double) -> String {
        if hz.rounded() == hz, let whole = Int(exactly: hz) { return String(whole) }
        return String(format: "%.2f", hz)
    }

    /// "62%" for a 0...1 level; a value outside what `Int` can hold is shown as the number it is.
    static func percent(_ level: Double) -> String {
        guard let whole = Int(exactly: (level * 100).rounded()) else { return "\(level)" }
        return "\(whole)%"
    }
}
