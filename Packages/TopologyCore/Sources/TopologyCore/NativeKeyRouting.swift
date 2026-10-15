import DisplayDomain
import Foundation

/// The modifier keys that change what a native brightness/volume key does (SO-26). Fn, Caps Lock
/// and the keypad flag are not part of a chord: Fn in particular is set on every media key a
/// keyboard in "standard function keys" mode sends.
public struct NativeKeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = NativeKeyModifiers(rawValue: 1 << 0)
    public static let control = NativeKeyModifiers(rawValue: 1 << 1)
    public static let option = NativeKeyModifiers(rawValue: 1 << 2)
    public static let command = NativeKeyModifiers(rawValue: 1 << 3)
}

/// Which displays a modifier chord asks the brightness keys to change, instead of the configured
/// target mode.
public enum NativeKeyScope: Hashable, Sendable {
    /// The configured `MediaKeyTargetMode`.
    case configured
    /// ⌃: the built-in display.
    case builtIn
    /// ⌃⌘: the external displays, OpenDisplay's own virtual screens excluded.
    case externals
    /// ⇧⌘: every display outside the one under the pointer and its mirror set — including displays
    /// whose keyboard control is off.
    case otherScreens
}

/// What one native key press asks for, once its modifier chord is understood.
public struct NativeKeyIntent: Hashable, Sendable {
    /// ⇧⌥ was held: the step that isn't the default one (`AdjustmentSteps.nativeKeyFraction`).
    public var modifierRequestsFine: Bool
    public var scope: NativeKeyScope
    /// ⇧ alone: change only the chosen displays — group sync is bypassed for this press, and the
    /// all-displays mode narrows to the pointer's display and its mirror set.
    public var bypassesSync: Bool
    /// ⇧ without ⌥: the volume feedback sound does the opposite of the preference for this press.
    public var invertsFeedbackSound: Bool

    public init(modifierRequestsFine: Bool = false, scope: NativeKeyScope = .configured,
                bypassesSync: Bool = false, invertsFeedbackSound: Bool = false) {
        self.modifierRequestsFine = modifierRequestsFine
        self.scope = scope
        self.bypassesSync = bypassesSync
        self.invertsFeedbackSound = invertsFeedbackSound
    }

    /// A plain press: the configured targets, the default step.
    public static let plain = NativeKeyIntent()
}

/// Reads a native key's modifier chord (SO-26). Only the chords listed here are OpenDisplay's;
/// auxiliary actions open Settings or change mirroring; unsupported chords return nil and keep
/// macOS's meaning instead of adjusting a display unexpectedly.
public enum NativeKeyChordPolicy {
    public enum AuxiliaryAction: Equatable, Sendable {
        case displaysSettings
        case soundSettings
        case stopMirroring
        case startMirroring
    }

    public static func auxiliaryAction(for action: MediaKeyAction, modifiers: NativeKeyModifiers,
                                        brightnessRequiresShift: Bool) -> AuxiliaryAction? {
        if action.isBrightness && brightnessRequiresShift { return nil }
        if modifiers == .option { return action.isBrightness ? .displaysSettings : .soundSettings }
        guard modifiers == .command, action.isBrightness else { return nil }
        return action == .brightnessDown ? .stopMirroring : .startMirroring
    }

    /// The existing public mirroring sink mirrors a target to the main display. Resolve identities
    /// before asynchronous work; the caller must retain UUIDs and revalidate them at each write.
    /// Auto-repeat must not toggle the topology repeatedly.
    public static func mirrorTargets(for action: AuxiliaryAction,
                                      in displays: [DisplayObservation]) -> [DisplayRecordID] {
        let active = displays.filter { $0.isActive && $0.cgDisplayID != nil }
        switch action {
        case .stopMirroring: return active.filter { $0.mirrorSourceID != nil }.map(\.recordID)
        case .startMirroring:
            guard let main = active.first(where: \.isMain) else { return [] }
            return active.first { $0.recordID != main.recordID && $0.displayClass == .external
                && $0.physicalPresence != .virtual && $0.mirrorSourceID == nil }.map { [$0.recordID] } ?? []
        case .displaysSettings, .soundSettings: return []
        }
    }

    /// - Parameter brightnessRequiresShift: the older "Require Shift for the brightness keys"
    ///   setting. While on, ⇧ is what lets a brightness key through (⇧ = standard, ⇧⌥ = fine) and so
    ///   can't also mean "bypass sync"; the scope chords aren't available.
    public static func intent(for action: MediaKeyAction, modifiers: NativeKeyModifiers,
                              brightnessRequiresShift: Bool) -> NativeKeyIntent? {
        if action.isBrightness && brightnessRequiresShift {
            switch modifiers {
            case [.shift]: return .plain
            case [.shift, .option]: return NativeKeyIntent(modifierRequestsFine: true)
            default: return nil
            }
        }
        switch modifiers {
        case []:
            return .plain
        case [.shift]:
            return NativeKeyIntent(bypassesSync: true, invertsFeedbackSound: true)
        case [.shift, .option]:
            return NativeKeyIntent(modifierRequestsFine: true)
        case [.control] where action.isBrightness:
            return NativeKeyIntent(scope: .builtIn)
        case [.control, .command] where action.isBrightness:
            return NativeKeyIntent(scope: .externals)
        case [.shift, .command] where action.isBrightness:
            return NativeKeyIntent(scope: .otherScreens, bypassesSync: true)
        default:
            return nil
        }
    }
}

/// F14/F15 as brightness keys (SO-25/FA-19): Scroll Lock and Pause on many PC keyboards send these.
public enum AlternativeBrightnessKey {
    /// `kVK_F14` / `kVK_F15` (Carbon `Events.h`), held here so the core needn't import Carbon.
    public static let f14: UInt16 = 0x6B
    public static let f15: UInt16 = 0x71

    public static func action(forKeyCode keyCode: UInt16) -> MediaKeyAction? {
        switch keyCode {
        case f14: return .brightnessDown
        case f15: return .brightnessUp
        default: return nil
        }
    }

    /// Whether this F14/F15 press is the brightness key's: the mapping is on and no global shortcut
    /// already uses this exact chord — a recorded shortcut always wins over the mapping.
    public static func isMapped(keyCode: UInt16, carbonModifiers: UInt32, enabled: Bool,
                                shortcutInUse: (KeyBinding) -> Bool) -> Bool {
        guard enabled, action(forKeyCode: keyCode) != nil else { return false }
        return !shortcutInUse(KeyBinding(keyCode: UInt32(keyCode), modifiers: carbonModifiers))
    }
}

/// The display relationships native keys respect (SO-27): a hardware mirror set shows one picture on
/// several displays, so a key aimed at one of them is aimed at all of them.
public enum DisplayRelationships {
    /// Only active full-screen streams belong here; preview/PIP windows are not display targets.
    /// The stream owner supplies these directed edges, rather than inferring them from geometry.
    public struct StreamTarget: Hashable, Sendable {
        public var source: DisplayRecordID
        public var target: DisplayRecordID

        public init(source: DisplayRecordID, target: DisplayRecordID) {
            self.source = source
            self.target = target
        }
    }

    public static func controlSet(of display: DisplayRecordID, in displays: [DisplayObservation],
                                   streams: [StreamTarget]) -> [DisplayRecordID] {
        var result = mirrorSet(of: display, in: displays)
        var seen = Set(result)
        var index = 0
        // A stream can target a mirror set, another streamed surface, or form a cycle. Each actual
        // display is visited once; no arbitrary traversal depth hides a legitimate target.
        while index < result.count {
            let source = result[index]
            index += 1
            for stream in streams where stream.source == source {
                for target in mirrorSet(of: stream.target, in: displays) where seen.insert(target).inserted {
                    result.append(target)
                }
            }
        }
        return result
    }

    /// `display` and every active display mirroring the same source, source first. A display that
    /// is not mirrored is a set of one.
    public static func mirrorSet(of display: DisplayRecordID, in displays: [DisplayObservation]) -> [DisplayRecordID] {
        let active = displays.filter(\.isActive)
        guard let member = active.first(where: { $0.recordID == display }) else { return [] }
        let source = member.mirrorSourceID ?? member.recordID
        var set: [DisplayRecordID] = active.contains(where: { $0.recordID == source }) ? [source] : []
        for other in active where other.mirrorSourceID == source && !set.contains(other.recordID) {
            set.append(other.recordID)
        }
        if !set.contains(display) { set.append(display) }
        return set
    }
}

/// The display under the pointer (global top-left coordinates, as `DisplayObservation.origin`).
public enum PointerScreen {
    /// Mirror members share their bounds; the source answers for its set. A pointer resting on a
    /// display's far edge (outside the half-open bounds by rounding) still belongs to that display —
    /// but a point outside every display has none: there is no fallback to another screen.
    public static func display(at point: DisplayOrigin, in displays: [DisplayObservation]) -> DisplayObservation? {
        let active = displays.filter(\.isActive)
        let ordered = active.filter { $0.mirrorSourceID == nil } + active.filter { $0.mirrorSourceID != nil }
        return ordered.first { contains($0, point, closed: false) }
            ?? ordered.first { contains($0, point, closed: true) }
    }

    static func contains(_ display: DisplayObservation, _ p: DisplayOrigin, closed: Bool) -> Bool {
        guard let mode = display.mode else { return false }
        let maxX = display.origin.x + mode.pointWidth
        let maxY = display.origin.y + mode.pointHeight
        guard p.x >= display.origin.x, p.y >= display.origin.y else { return false }
        return closed ? (p.x <= maxX && p.y <= maxY) : (p.x < maxX && p.y < maxY)
    }
}

/// The display showing the focused window (SO-27/FA-19): the one holding most of the window's area.
public enum FocusedWindowScreen {
    public struct Bounds: Hashable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// - Returns: the display with the largest share of `window` (mirror sources only, since mirror
    ///   members share bounds); nil when the window lies on no active display.
    public static func display(for window: Bounds, in displays: [DisplayObservation]) -> DisplayRecordID? {
        var best: (id: DisplayRecordID, area: Double)?
        for display in displays where display.isActive && display.mirrorSourceID == nil {
            guard let mode = display.mode else { continue }
            let width = min(window.x + window.width, Double(display.origin.x + mode.pointWidth))
                - max(window.x, Double(display.origin.x))
            let height = min(window.y + window.height, Double(display.origin.y + mode.pointHeight))
                - max(window.y, Double(display.origin.y))
            guard width > 0, height > 0 else { continue }
            let area = width * height
            if area > (best?.area ?? 0) { best = (display.recordID, area) }
        }
        return best?.id
    }
}

/// Chooses which displays a brightness key changes (SO-27, FA-19, T27). Pure: the app supplies each
/// display's eligibility and controller facts and applies the result.
///
/// No suitable display means no change and the key goes back to macOS — never a fallback to an
/// unrelated screen. A display is changed once per press: mirror sets are expanded and deduplicated,
/// and several displays following one sync group are written through one member (the group carries
/// the rest) unless the press bypasses sync, in which case each is written directly.
public enum BrightnessKeyRouter {
    public struct Candidate: Hashable, Sendable {
        public var observation: DisplayObservation
        /// The display's own keyboard-control preference (`DisplayKeyboardAudioPreferences`).
        public var keyboardEnabled: Bool
        /// OpenDisplay has a brightness route that shows on this surface. A mirror member whose only
        /// route is an overlay window is not: nothing drawn there would be seen.
        public var controllable: Bool
        /// macOS's own brightness keys already adjust this display (Apple native brightness).
        public var macOSControllable: Bool
        /// The brightness sync group this display follows, if any.
        public var syncGroup: UUID?

        public init(observation: DisplayObservation, keyboardEnabled: Bool = true, controllable: Bool = true,
                    macOSControllable: Bool = false, syncGroup: UUID? = nil) {
            self.observation = observation
            self.keyboardEnabled = keyboardEnabled
            self.controllable = controllable
            self.macOSControllable = macOSControllable
            self.syncGroup = syncGroup
        }

        public var id: DisplayRecordID { observation.recordID }
    }

    public struct Context: Hashable, Sendable {
        public var mode: MediaKeyTargetMode
        public var takeover: BrightnessKeyTakeover
        public var pointer: DisplayOrigin?
        public var focusedDisplay: DisplayRecordID?
        public var streamTargets: [DisplayRelationships.StreamTarget]

        public init(mode: MediaKeyTargetMode, takeover: BrightnessKeyTakeover = .anyControllableDisplay,
                    pointer: DisplayOrigin? = nil, focusedDisplay: DisplayRecordID? = nil,
                    streamTargets: [DisplayRelationships.StreamTarget] = []) {
            self.streamTargets = streamTargets
            self.mode = mode
            self.takeover = takeover
            self.pointer = pointer
            self.focusedDisplay = focusedDisplay
        }
    }

    public struct Target: Hashable, Sendable {
        public var display: DisplayRecordID
        /// Write this display alone: its sync group does not follow.
        public var bypassesSync: Bool

        public init(display: DisplayRecordID, bypassesSync: Bool) {
            self.display = display
            self.bypassesSync = bypassesSync
        }
    }

    public enum PassReason: Hashable, Sendable {
        /// No display the press may change.
        case noTarget
        /// Every display the press would change is one macOS adjusts itself, and the takeover
        /// policy leaves those to macOS.
        case macOSHandles
    }

    public enum Decision: Hashable, Sendable {
        case adjust([Target])
        case passThrough(PassReason)

        public var targets: [Target] {
            if case .adjust(let targets) = self { return targets }
            return []
        }
    }

    /// Eligibility also constrains group fan-out for this operation; a group must not reintroduce
    /// an excluded display or an ineffective mirror overlay through a follower write.
    public static func syncEligibleDisplays(_ candidates: [Candidate]) -> Set<DisplayRecordID> {
        Set(candidates.filter { $0.observation.isActive && $0.keyboardEnabled && $0.controllable }.map(\.id))
    }

    public static func decide(intent: NativeKeyIntent, candidates: [Candidate], context: Context) -> Decision {
        let active = candidates.filter { $0.observation.isActive }
        let observations = active.map(\.observation)
        let byID = Dictionary(active.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pointerID = context.pointer.flatMap { PointerScreen.display(at: $0, in: observations)?.recordID }
        func related(_ id: DisplayRecordID?) -> [DisplayRecordID] {
            id.map { DisplayRelationships.controlSet(of: $0, in: observations, streams: context.streamTargets) } ?? []
        }

        var primary: DisplayRecordID?
        var chosen: [DisplayRecordID]
        var respectsKeyboardPreference = true
        var bypass = intent.bypassesSync
        let allMode = context.mode == .allDisplays

        if allMode && !intent.bypassesSync {
            // All-displays mode outranks the built-in/external chords and writes every display
            // directly: group sync on top would write its members twice.
            chosen = active.map(\.id)
            bypass = true
        } else if intent.scope == .otherScreens {
            guard pointerID != nil else { return .passThrough(.noTarget) }
            let excluded = Set(related(pointerID))
            chosen = active.map(\.id).filter { !excluded.contains($0) }
            respectsKeyboardPreference = false
        } else if allMode {
            // ⇧ in all-displays mode: the pointer's display and its mirror set only.
            primary = pointerID
            chosen = related(pointerID)
        } else {
            switch intent.scope {
            case .builtIn:
                chosen = active.filter { $0.observation.displayClass == .builtIn }.map(\.id)
            case .externals:
                chosen = active.filter {
                    $0.observation.displayClass == .external && $0.observation.physicalPresence != .virtual
                }.map(\.id)
            case .configured, .otherScreens:
                switch context.mode {
                case .underCursor, .allDisplays:
                    primary = pointerID
                    chosen = related(pointerID)
                case .focusedWindow:
                    primary = context.focusedDisplay.flatMap { byID[$0] != nil ? $0 : nil }
                    chosen = related(primary)
                case .mainDisplay:
                    primary = active.first { $0.observation.isMain }?.id
                    chosen = related(primary)
                case .builtInAlways:
                    chosen = active.filter { $0.observation.displayClass == .builtIn }.map(\.id)
                case .externalOnly:
                    let externals = active.filter { $0.observation.displayClass == .external }
                    let pick = externals.first { $0.id == pointerID }
                        ?? externals.first { $0.observation.isMain } ?? externals.first
                    primary = pick?.id
                    chosen = related(pick?.id).filter { byID[$0]?.observation.displayClass == .external }
                }
            }
        }

        var eligible = orderedUnique(chosen, primary: primary, byID: byID).filter { id in
            guard let candidate = byID[id], candidate.controllable else { return false }
            return candidate.keyboardEnabled || !respectsKeyboardPreference
        }
        if !bypass {
            // One member per sync group: the group's own rules carry the change to the others.
            var seenGroups = Set<UUID>()
            eligible = eligible.filter { id in
                guard let group = byID[id]?.syncGroup else { return true }
                return seenGroups.insert(group).inserted
            }
        }
        guard !eligible.isEmpty else { return .passThrough(.noTarget) }
        if context.takeover == .onlyWhenMacOSCannot,
           eligible.allSatisfy({ byID[$0]?.macOSControllable == true }) {
            return .passThrough(.macOSHandles)
        }
        return .adjust(eligible.map { Target(display: $0, bypassesSync: bypass) })
    }

    /// The primary display first, then the rest left to right, top to bottom — a stable order, so a
    /// press resolves the same way every time.
    private static func orderedUnique(_ ids: [DisplayRecordID], primary: DisplayRecordID?,
                                      byID: [DisplayRecordID: Candidate]) -> [DisplayRecordID] {
        var seen = Set<DisplayRecordID>()
        let unique = ids.filter { seen.insert($0).inserted }
        let rest = unique.filter { $0 != primary }.sorted { lhs, rhs in
            let l = byID[lhs]?.observation.origin ?? .zero
            let r = byID[rhs]?.observation.origin ?? .zero
            if l.x != r.x { return l.x < r.x }
            if l.y != r.y { return l.y < r.y }
            return lhs.rawValue < rhs.rawValue
        }
        guard let primary, unique.contains(primary) else { return rest }
        return [primary] + rest
    }
}
