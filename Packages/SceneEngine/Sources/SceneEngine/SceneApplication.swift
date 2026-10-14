import DisplayDomain
import Foundation

/// Applying a scene, judged by what actually changed (TB-04).
///
/// Scene apply executes exactly two fields — position and mode — through one Core Graphics
/// arrangement transaction. Every other field the scene schema can carry (on/off, rotation,
/// brightness, colour profile, HDR, relative placement) is checked against the topology but never
/// written, so presence in the schema is not support: those fields are reported as `skipped` unless
/// the display already has the requested value. The two executed fields are judged against the
/// topology read AFTER the write, so a rejected mode, a moved-back origin or a provider failure
/// shows up as `notApplied` instead of an apparently clean application.
public enum SceneApplication {
    /// One display's slice of the arrangement transaction: only the fields that differ.
    public struct ArrangementWrite: Hashable, Sendable {
        public var target: DisplayRecordID
        public var origin: DisplayOrigin?
        public var mode: DisplayMode?

        public init(target: DisplayRecordID, origin: DisplayOrigin?, mode: DisplayMode?) {
            self.target = target
            self.origin = origin
            self.mode = mode
        }
    }

    /// What to write, and which members can't take part.
    public struct Preparation: Hashable, Sendable {
        public var writes: [ArrangementWrite]
        /// Required members with no present display. Any of these blocks the whole apply.
        public var missingRequired: [String]
        /// Optional members with no present display; the rest of the scene still applies.
        public var missingOptional: [String]

        public var isBlocked: Bool { !missingRequired.isEmpty }
    }

    /// Resolves members against the topology before the write. A member resolved to a record the
    /// snapshot doesn't contain (a display that is off or unplugged) counts as missing.
    public static func prepare(scene: Scene, resolution: ScenePlanner.Resolution,
                               before: TopologySnapshot) -> Preparation {
        var writes: [ArrangementWrite] = []
        var missingRequired: [String] = []
        var missingOptional: [String] = []
        for member in scene.members {
            guard let id = resolution[member.selector], let observed = before.observation(for: id) else {
                if member.required { missingRequired.append(member.selector) }
                else { missingOptional.append(member.selector) }
                continue
            }
            let origin = member.desired.position.flatMap { $0 == observed.origin ? nil : $0 }
            let mode = member.desired.mode.flatMap { modeMatches(observed.mode, $0) ? nil : $0 }
            if origin != nil || mode != nil {
                writes.append(ArrangementWrite(target: id, origin: origin, mode: mode))
            }
        }
        return Preparation(writes: writes, missingRequired: missingRequired, missingOptional: missingOptional)
    }

    /// Judges every field of every present member. `after` must be read once the arrangement
    /// transaction has completed; `providerWarnings` are carried through verbatim.
    public static func report(scene: Scene, preparation: Preparation,
                              resolution: ScenePlanner.Resolution, before: TopologySnapshot,
                              after: TopologySnapshot, providerWarnings: [String]) -> SceneApplyReport {
        var entries: [SceneApplyReport.Entry] = []
        if !preparation.isBlocked {
            for member in scene.members {
                guard let id = resolution[member.selector], let was = before.observation(for: id) else { continue }
                entries += judge(member, target: id, before: was, after: after.observation(for: id))
            }
        }
        let presentMembers = scene.members.count - preparation.missingOptional.count
            - preparation.missingRequired.count
        return SceneApplyReport(
            sceneID: scene.id, sceneName: scene.name, entries: entries,
            missingRequired: preparation.missingRequired, missingOptional: preparation.missingOptional,
            providerWarnings: providerWarnings,
            status: status(blocked: preparation.isBlocked, hadMembers: !scene.members.isEmpty,
                           presentMembers: presentMembers, entries: entries))
    }

    // MARK: - Judging

    private static func judge(_ member: Scene.Member, target: DisplayRecordID,
                              before was: DisplayObservation, after now: DisplayObservation?)
        -> [SceneApplyReport.Entry] {
        let desired = member.desired
        var entries: [SceneApplyReport.Entry] = []
        func add(_ field: SceneApplyReport.Field, _ outcome: SceneApplyReport.Outcome,
                 requested: String, observed: String? = nil) {
            entries.append(.init(selector: member.selector, target: target, field: field,
                                 outcome: outcome, requested: requested, observed: observed))
        }
        let gone = "display disappeared"

        if let connected = desired.connected {
            let label = { (on: Bool) in on ? "connected" : "off" }
            if was.isActive == connected { add(.connected, .alreadySatisfied, requested: label(connected)) }
            else { add(.connected, .skipped, requested: label(connected), observed: label(was.isActive)) }
        }
        if desired.main == true {
            if now?.isMain == true {
                add(.main, was.isMain ? .alreadySatisfied : .applied, requested: "main")
            } else {
                // Core Graphics makes the display at (0, 0) main, so a scene reaches "main" only
                // through a position; without one nothing here can make it main.
                add(.main, desired.position == nil ? .skipped : .notApplied, requested: "main",
                    observed: now == nil ? gone : "not main")
            }
        }
        if let position = desired.position {
            if now?.origin == position {
                add(.position, was.origin == position ? .alreadySatisfied : .applied, requested: describe(position))
            } else {
                add(.position, .notApplied, requested: describe(position),
                    observed: now.map { describe($0.origin) } ?? gone)
            }
        }
        if let mode = desired.mode {
            if let now, modeMatches(now.mode, mode) {
                add(.mode, modeMatches(was.mode, mode) ? .alreadySatisfied : .applied, requested: describe(mode))
            } else {
                add(.mode, .notApplied, requested: describe(mode),
                    observed: now.map { $0.mode.map(describe) ?? "unknown mode" } ?? gone)
            }
        }
        if let rotation = desired.rotation {
            if was.rotation == rotation { add(.rotation, .alreadySatisfied, requested: "\(rotation.rawValue)°") }
            else { add(.rotation, .skipped, requested: "\(rotation.rawValue)°", observed: "\(was.rotation.rawValue)°") }
        }
        if let relative = desired.relativePosition {
            add(.relativePosition, .skipped,
                requested: "\(relative.edge.rawValue) \(relative.relativeToSelector)")
        }
        if let profile = desired.colorProfile {
            if was.colorProfileName == profile { add(.colorProfile, .alreadySatisfied, requested: profile) }
            else { add(.colorProfile, .skipped, requested: profile, observed: was.colorProfileName) }
        }
        if let hdr = desired.hdr {
            let label = { (on: Bool) in on ? "on" : "off" }
            // Unknown HDR state (nil — no provider observes it yet) never counts as satisfied.
            if was.hdrEnabled == hdr { add(.hdr, .alreadySatisfied, requested: label(hdr)) }
            else { add(.hdr, .skipped, requested: label(hdr), observed: was.hdrEnabled.map(label) ?? "unknown") }
        }
        // The topology doesn't carry brightness, so there is nothing to compare against either.
        if let brightness = desired.brightness {
            add(.brightness, .skipped, requested: "\(Int((brightness * 100).rounded()))%")
        }
        return entries
    }

    private static func status(blocked: Bool, hadMembers: Bool, presentMembers: Int,
                               entries: [SceneApplyReport.Entry]) -> SceneApplyReport.Status {
        if blocked { return .blocked }
        // A scene whose every member is absent did nothing at all, which is not "no change needed".
        if hadMembers && presentMembers == 0 { return .failed }
        let problems = entries.filter { $0.outcome == .notApplied || $0.outcome == .skipped }.count
        if problems == 0 {
            return entries.allSatisfy { $0.outcome == .alreadySatisfied } ? .noChange : .applied
        }
        return problems == entries.count ? .failed : .partial
    }

    /// The same exact-mode rule the arrangement writer uses (`DisplayModeChoices.matches`), plus
    /// plain equality so a recorded mode always matches itself.
    static func modeMatches(_ actual: DisplayMode?, _ requested: DisplayMode) -> Bool {
        guard let actual else { return false }
        return actual == requested || DisplayModeChoices.matches(actual, requested: requested)
    }

    private static func describe(_ origin: DisplayOrigin) -> String { "(\(origin.x), \(origin.y))" }

    private static func describe(_ mode: DisplayMode) -> String {
        let hz = mode.refreshHz.rounded() == mode.refreshHz
            ? String(Int(mode.refreshHz)) : String(format: "%.2f", mode.refreshHz)
        return "\(mode.pixelWidth)x\(mode.pixelHeight)@\(hz)\(mode.isHiDPI ? " HiDPI" : "")"
    }
}

/// Field-by-field result of one scene apply.
public struct SceneApplyReport: Hashable, Sendable, Codable {
    public enum Field: String, Hashable, Sendable, Codable, CaseIterable {
        case connected, main, position, relativePosition, mode, rotation, brightness, colorProfile, hdr
    }

    public enum Outcome: String, Hashable, Sendable, Codable {
        /// Written, and the topology afterwards shows the requested value.
        case applied
        /// The display already had it; nothing needed writing.
        case alreadySatisfied
        /// Written (or meant to be), but the topology afterwards shows something else.
        case notApplied
        /// Scene apply does not execute this field, and the display doesn't already have it.
        case skipped
    }

    public struct Entry: Hashable, Sendable, Codable {
        public var selector: String
        public var target: DisplayRecordID
        public var field: Field
        public var outcome: Outcome
        /// What the scene asked for, as display text.
        public var requested: String
        /// What the display has instead, when the field didn't end up as requested.
        public var observed: String?

        public init(selector: String, target: DisplayRecordID, field: Field, outcome: Outcome,
                    requested: String, observed: String? = nil) {
            self.selector = selector
            self.target = target
            self.field = field
            self.outcome = outcome
            self.requested = requested
            self.observed = observed
        }
    }

    public enum Status: String, Hashable, Sendable, Codable {
        /// Everything the scene asks for is now in place, and something had to change.
        case applied
        /// Everything was already in place.
        case noChange
        /// Some fields are in place, others were skipped or didn't take.
        case partial
        /// Nothing the scene needed was achieved (or no member was present).
        case failed
        /// A required member is missing, so nothing was written.
        case blocked
    }

    public var sceneID: String
    public var sceneName: String
    public var entries: [Entry]
    public var missingRequired: [String]
    public var missingOptional: [String]
    public var providerWarnings: [String]
    public var status: Status

    public init(sceneID: String, sceneName: String, entries: [Entry], missingRequired: [String],
                missingOptional: [String], providerWarnings: [String], status: Status) {
        self.sceneID = sceneID
        self.sceneName = sceneName
        self.entries = entries
        self.missingRequired = missingRequired
        self.missingOptional = missingOptional
        self.providerWarnings = providerWarnings
        self.status = status
    }

    /// Entries that didn't end up as the scene asked, in report order.
    public var problems: [Entry] { entries.filter { $0.outcome == .notApplied || $0.outcome == .skipped } }
}
