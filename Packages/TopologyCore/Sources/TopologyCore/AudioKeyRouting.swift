import DisplayDomain
import Foundation

/// Where one display's volume and mute go (SD-16, TB-08, TR-16).
public enum DisplayAudioSink: Hashable, Sendable {
    /// The monitor's own audio over DDC, with what has been confirmed for each control
    /// (`DDCAudioPolicy.volumeKeysUsable` / `muteKeyUsable`).
    case hardware(volume: Bool, mute: Bool)
    /// A macOS sound output bound to this display (native association). It replaces the monitor's
    /// own audio for this display; it never changes which output macOS plays through.
    case native(AudioOutputDevice)
    /// Native association is on but names no single present output. The display has no audio
    /// control: a missing or ambiguous binding must not redirect the keys anywhere else.
    case unresolvedNative(AudioDeviceResolution)
    /// No audio control at all.
    case none
}

/// One display as the volume keys see it.
public struct AudioKeyCandidate: Hashable, Sendable {
    public var observation: DisplayObservation
    /// The display's product (system) name, used by automatic matching. Not the user's alias: the
    /// sound output carries the product name.
    public var productName: String
    /// The display's own keyboard-control preference.
    public var keyboardEnabled: Bool
    public var sink: DisplayAudioSink
    /// The display's volume-key matching override resolved among the present outputs; `.unset`
    /// means automatic matching by product name.
    public var matchOverride: AudioDeviceResolution

    public init(observation: DisplayObservation, productName: String, keyboardEnabled: Bool = true,
                sink: DisplayAudioSink, matchOverride: AudioDeviceResolution = .unset) {
        self.observation = observation
        self.productName = productName
        self.keyboardEnabled = keyboardEnabled
        self.sink = sink
        self.matchOverride = matchOverride
    }

    public var id: DisplayRecordID { observation.recordID }

    /// This display can carry out `action` from a key: active, keyboard control on, and a confirmed
    /// control for that action (volume and mute are separate capabilities).
    public func supports(_ action: MediaKeyAction, source: KeyRoutingSource = .nativeKey) -> Bool {
        guard observation.isActive, (keyboardEnabled || source == .recordedShortcut), action.isVolume else { return false }
        switch sink {
        case .hardware(let volume, let mute):
            return action == .muteToggle ? mute : volume
        case .native(let device):
            return action == .muteToggle ? device.muteIsToggleable : device.volumeIsAdjustable
        case .unresolvedNative, .none:
            return false
        }
    }

    /// Any audio key can be carried out on this display.
    public var isControllable: Bool { supports(.volumeUp) || supports(.muteToggle) }

    /// The output this display's sound plays on when that is known from its own binding.
    var boundOutputUID: String? {
        if case .native(let device) = sink { return device.uid }
        return nil
    }
}

/// Which displays the current sound output belongs to (SO-28, TB-08, TR-16). Explicit bindings —
/// native association or a matching override that names this output — come first and may name
/// several displays on purpose (a multi-output device). Without one, automatic matching applies the
/// original rules (`AudioOutputDisplayMatcher`: HDMI/DisplayPort only, one unambiguous product-name
/// match) and keeps rejecting ambiguity and unmatched outputs.
public enum AudioOutputAssociation {
    public struct Match: Hashable, Sendable {
        public var displays: [DisplayRecordID]
        /// The match comes from the user's own bindings rather than the product name.
        public var explicit: Bool

        public init(displays: [DisplayRecordID], explicit: Bool) {
            self.displays = displays
            self.explicit = explicit
        }

        public static let none = Match(displays: [], explicit: false)
    }

    public static func displays(matching output: AudioOutputDevice?, candidates: [AudioKeyCandidate]) -> Match {
        guard let output else { return .none }
        let active = candidates.filter { $0.observation.isActive }
        let explicit = active.filter { candidate in
            if !candidate.matchOverride.isUnset { return candidate.matchOverride.device?.uid == output.uid }
            return candidate.boundOutputUID == output.uid
        }.map(\.id)
        if !explicit.isEmpty { return Match(displays: explicit, explicit: true) }

        // Every active display takes part so the ambiguity check sees the real topology;
        // a display whose binding is explicit accepts no
        // automatic match — its binding replaces its product name.
        let names = Dictionary(active.map { ($0.id, $0.productName) }, uniquingKeysWith: { first, _ in first })
        guard let automatic = AudioOutputDisplayMatcher.match(
            deviceName: output.name, transport: output.transport,
            displays: active.map(\.observation), names: names),
            let candidate = active.first(where: { $0.id == automatic }),
            candidate.matchOverride.isUnset
        else { return .none }
        switch candidate.sink {
        case .native, .unresolvedNative: return .none
        case .hardware, .none: return Match(displays: [automatic], explicit: false)
        }
    }
}

/// Decides what a volume or mute key does (SO-25, SO-27, SO-28, TA-06, TB-08, FA-26). Pure.
///
/// Engagement (whether OpenDisplay takes the key) and targeting (which displays change) are
/// separate settings. A taken key acts on every target that supports the action; when none does,
/// the native fallback may act on the current output through macOS's audio interface; when that
/// can't either, the key goes to macOS — a key OpenDisplay can't act on is never swallowed.
public enum AudioKeyRouter {
    public struct Context: Hashable, Sendable {
        public var engagement: AudioKeyEngagement
        public var targetMode: AudioKeyTargetMode
        public var nativeFallback: Bool
        public var muteLeftToMacOS: Bool
        /// The output macOS currently plays through, if any.
        public var currentOutput: AudioOutputDevice?
        public var pointer: DisplayOrigin?
        public var focusedDisplay: DisplayRecordID?
        public var streamTargets: [DisplayRelationships.StreamTarget]
        public var source: KeyRoutingSource

        public init(engagement: AudioKeyEngagement = .outputMatchesDisplay,
                    targetMode: AudioKeyTargetMode = .matchingOutput, nativeFallback: Bool = true,
                    muteLeftToMacOS: Bool = false, currentOutput: AudioOutputDevice?,
                    pointer: DisplayOrigin? = nil, focusedDisplay: DisplayRecordID? = nil,
                    streamTargets: [DisplayRelationships.StreamTarget] = [], source: KeyRoutingSource = .nativeKey) {
            self.source = source
            self.streamTargets = streamTargets
            self.engagement = engagement
            self.targetMode = targetMode
            self.nativeFallback = nativeFallback
            self.muteLeftToMacOS = muteLeftToMacOS
            self.currentOutput = currentOutput
            self.pointer = pointer
            self.focusedDisplay = focusedDisplay
        }

        public init(_ preferences: NativeKeyPreferences, currentOutput: AudioOutputDevice?,
                    pointer: DisplayOrigin? = nil, focusedDisplay: DisplayRecordID? = nil) {
            self.init(engagement: preferences.audioEngagement, targetMode: preferences.audioTarget,
                      nativeFallback: preferences.nativeAudioFallback,
                      muteLeftToMacOS: preferences.muteKeyLeftToMacOS, currentOutput: currentOutput,
                      pointer: pointer, focusedDisplay: focusedDisplay)
        }
    }

    public enum Recipient: Hashable, Sendable {
        /// The monitor's own audio over DDC.
        case hardware(DisplayRecordID)
        /// The output bound to a display.
        case native(DisplayRecordID, AudioOutputDevice)
        /// The fallback: the current output, which no display handled.
        case currentOutput(AudioOutputDevice)

        public var display: DisplayRecordID? {
            switch self {
            case .hardware(let id), .native(let id, _): return id
            case .currentOutput: return nil
            }
        }
    }

    public enum PassReason: Hashable, Sendable {
        /// "Leave the mute key to macOS" is on.
        case muteLeftToMacOS
        /// The engagement rule doesn't take keys in the current situation (e.g. headphones).
        case notEngaged
        /// Engaged, but no target supports this action and the fallback can't act either.
        case noCapableTarget
    }

    public enum Decision: Hashable, Sendable {
        /// Carry out the action on every recipient. `feedbackOutputUID` is where the release sound
        /// plays; nil means the system's default output.
        case adjust([Recipient], feedbackOutputUID: String?)
        case passThrough(PassReason)

        public var recipients: [Recipient] {
            if case .adjust(let recipients, _) = self { return recipients }
            return []
        }
    }

    public static func decide(_ action: MediaKeyAction, intent: NativeKeyIntent,
                              candidates: [AudioKeyCandidate], context: Context) -> Decision {
        guard action.isVolume else { return .passThrough(.noCapableTarget) }
        if action == .muteToggle && context.muteLeftToMacOS { return .passThrough(.muteLeftToMacOS) }
        let active = candidates.filter { $0.observation.isActive }
        let byID = Dictionary(active.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let match = AudioOutputAssociation.displays(matching: context.currentOutput, candidates: active)

        func controllable(_ candidate: AudioKeyCandidate) -> Bool {
            candidate.supports(.volumeUp, source: context.source) || candidate.supports(.muteToggle, source: context.source)
        }
        let engaged: Bool
        switch context.engagement {
        case .outputMatchesDisplay:
            engaged = match.displays.contains { byID[$0].map(controllable) == true }
        case .outputLacksVolumeControl:
            engaged = context.currentOutput != nil && context.currentOutput?.volumeIsAdjustable != true
                && active.contains(where: controllable)
        case .anyControllableDisplay:
            engaged = active.contains(where: controllable)
        case .always:
            engaged = true
        }
        guard engaged else { return .passThrough(.notEngaged) }

        let observations = active.map(\.observation)
        func related(_ id: DisplayRecordID?) -> [DisplayRecordID] {
            id.map { DisplayRelationships.controlSet(of: $0, in: observations, streams: context.streamTargets) } ?? []
        }
        let mode = context.targetMode == .allDisplays && intent.bypassesSync ? .underCursor : context.targetMode
        let chosen: [DisplayRecordID]
        switch mode {
        case .matchingOutput:
            chosen = match.displays
        case .underCursor:
            chosen = related(context.pointer.flatMap { PointerScreen.display(at: $0, in: observations)?.recordID })
        case .focusedWindow:
            chosen = related(context.focusedDisplay)
        case .allDisplays:
            chosen = active.map(\.id)
        }

        // One write per control endpoint: two displays bound to the same output change it once.
        var recipients: [Recipient] = []
        var seenOutputs = Set<String>()
        var seenDisplays = Set<DisplayRecordID>()
        for id in chosen {
            guard let candidate = byID[id], candidate.supports(action, source: context.source), seenDisplays.insert(id).inserted else { continue }
            switch candidate.sink {
            case .hardware:
                recipients.append(.hardware(id))
            case .native(let device):
                if seenOutputs.insert(device.uid).inserted { recipients.append(.native(id, device)) }
            case .unresolvedNative, .none:
                continue
            }
        }
        if !recipients.isEmpty {
            return .adjust(recipients, feedbackOutputUID: feedbackOutput(for: recipients, match: match,
                                                                         currentOutput: context.currentOutput))
        }
        // A selected but unresolved explicit association must not redirect control to a different
        // output. Ordinary absence of a target can still use the separately enabled native fallback.
        let unresolvedSelection = chosen.contains { id in
            if case .unresolvedNative = byID[id]?.sink { return true }
            return false
        }
        if !unresolvedSelection, context.nativeFallback, let output = context.currentOutput,
           action == .muteToggle ? output.muteIsToggleable : output.volumeIsAdjustable {
            return .adjust([.currentOutput(output)], feedbackOutputUID: output.uid)
        }
        return .passThrough(.noCapableTarget)
    }

    /// A single recipient whose output is known gets the sound; several, or one whose output isn't
    /// known, leave it to the default output (FA-20/T35). A monitor's own DDC audio is known to be
    /// the current output only when the display matched it.
    static func feedbackOutput(for recipients: [Recipient], match: AudioOutputAssociation.Match,
                               currentOutput: AudioOutputDevice?) -> String? {
        guard recipients.count == 1 else { return nil }
        switch recipients[0] {
        case .native(_, let device), .currentOutput(let device):
            return device.uid
        case .hardware(let id):
            return match.displays.contains(id) ? currentOutput?.uid : nil
        }
    }
}

/// What the volume keys would do right now (SO-25): shown as the audio listening status.
public enum AudioKeyStatus: Hashable, Sendable {
    /// Volume-key capture is off.
    case off
    /// Neither key would be taken in the current situation.
    case disengaged
    case volumeOnly
    case muteOnly
    case volumeAndMute

    public static func evaluate(captureEnabled: Bool, volume: AudioKeyRouter.Decision,
                                mute: AudioKeyRouter.Decision) -> AudioKeyStatus {
        guard captureEnabled else { return .off }
        switch (volume.recipients.isEmpty, mute.recipients.isEmpty) {
        case (false, false): return .volumeAndMute
        case (false, true): return .volumeOnly
        case (true, false): return .muteOnly
        case (true, true): return .disengaged
        }
    }
}

/// Owner #6: discovery and capture enablement use the same initial-read plan. Only the existing
/// DDC sink needs a probe; a native binding must never start DDC traffic as a side effect.
public enum DisplayAudioInitialRead {
    public static func targets(candidates: [AudioKeyCandidate], confirmedVolume: Set<DisplayRecordID>,
                               captureEnabled: Bool, safeStartup: Bool) -> [DisplayRecordID] {
        guard captureEnabled, !safeStartup else { return [] }
        return candidates.filter {
            guard $0.observation.isActive, $0.observation.displayClass == .external,
                  $0.observation.physicalPresence != .virtual, $0.keyboardEnabled,
                  !confirmedVolume.contains($0.id) else { return false }
            if case .hardware = $0.sink { return true }
            return false
        }.map(\.id)
    }
}

/// Whether the native keys are being listened to (SO-25/T27). Permission, an armed tap and a
/// capable target are separate facts; this reports the first two honestly.
public enum NativeKeyListening {
    public enum State: Hashable, Sendable {
        /// The feature is off, or both brightness and volume capture are off — no permission needed.
        case off
        /// Capture is wanted but the Accessibility permission is missing: every key goes to macOS.
        case permissionMissing
        /// Permission is there but the key tap isn't running yet: keys still go to macOS.
        case waitingForCapture
        case listening
    }

    /// The key tap is needed at all.
    public static func needsCapture(featureEnabled: Bool, preferences: NativeKeyPreferences) -> Bool {
        featureEnabled && (preferences.brightnessKeysEnabled || preferences.volumeKeysEnabled)
    }

    public static func state(featureEnabled: Bool, preferences: NativeKeyPreferences,
                             permissionGranted: Bool, tapActive: Bool) -> State {
        guard needsCapture(featureEnabled: featureEnabled, preferences: preferences) else { return .off }
        guard permissionGranted else { return .permissionMissing }
        return tapActive ? .listening : .waitingForCapture
    }
}

/// The volume feedback sound (FA-20/T35): whether a released key plays it, and the one-sound-per-
/// press bookkeeping between a handled press and its release.
public enum VolumeFeedbackPolicy {
    /// - Parameters:
    ///   - systemPreference: macOS's own "play feedback" preference when it could be read.
    ///   - inverted: ⇧ without ⌥ (keys) — the opposite of the preference for this operation.
    public static func plays(_ setting: VolumeFeedbackSound, systemPreference: Bool?, inverted: Bool) -> Bool {
        let base: Bool
        switch setting {
        case .followSystem: base = systemPreference ?? false
        case .always: base = true
        case .never: base = false
        }
        return base != inverted
    }
}

/// Remembers the feedback owed for a held volume key so it plays once, on release — not for every
/// auto-repeat — and only for a press OpenDisplay handled.
public struct KeyReleaseFeedback: Sendable {
    /// Where a feedback sound plays: an output UID, or nil for the system's default output.
    public struct Request: Hashable, Sendable {
        public var outputUID: String?
        public init(outputUID: String?) { self.outputUID = outputUID }

        /// A resolved output that disappeared cannot redirect its sound to another output.
        public func canPlay(availableUIDs: Set<String>) -> Bool {
            outputUID.map(availableUIDs.contains) ?? true
        }
    }

    private var pending: [MediaKeyAction: Request] = [:]

    public init() {}

    /// A press (or repeat) was handled; `request` is nil when it owes no sound. The latest
    /// handled press decides.
    public mutating func pressHandled(_ action: MediaKeyAction, request: Request?) {
        pending[action] = request
    }

    /// The key went up: the sound owed for it, once.
    public mutating func released(_ action: MediaKeyAction) -> Request? {
        pending.removeValue(forKey: action)
    }

    public mutating func cancel() { pending.removeAll() }
}
