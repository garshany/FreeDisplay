import DisplayDomain
import Foundation

/// Shared semantics for the recorder's fixed actions. No new timing or repeat interval: Carbon
/// supplies the system repeat events and discrete actions run only on the initial press.
public enum ShortcutActionPolicy {
    public enum Adjustment: Equatable, Sendable {
        case brightness(delta: Float)
        case contrast(delta: Float)
        case temperature(delta: Float)
        case volume(delta: Float)
    }

    public static func adjustment(for action: HotkeyAction, steps: AdjustmentSteps) -> Adjustment? {
        let standard = steps.fraction(fine: false)
        let fine = steps.fraction(fine: true)
        switch action {
        case .brightnessUp: return .brightness(delta: standard)
        case .brightnessDown: return .brightness(delta: -standard)
        case .brightnessUpFine: return .brightness(delta: fine)
        case .brightnessDownFine: return .brightness(delta: -fine)
        case .softwareContrastUp: return .contrast(delta: standard)
        case .softwareContrastDown: return .contrast(delta: -standard)
        case .softwareContrastUpFine: return .contrast(delta: fine)
        case .softwareContrastDownFine: return .contrast(delta: -fine)
        case .warmer: return .temperature(delta: -standard)
        case .cooler: return .temperature(delta: standard)
        case .volumeUp: return .volume(delta: standard)
        case .volumeDown: return .volume(delta: -standard)
        case .volumeUpFine: return .volume(delta: fine)
        case .volumeDownFine: return .volume(delta: -fine)
        default: return nil
        }
    }

    public static func repeats(_ action: HotkeyAction) -> Bool {
        adjustment(for: action, steps: .default) != nil
    }

    /// A recorded shortcut explicitly engages audio. Native interception switches do not disable
    /// it; endpoint selection, ambiguity refusal and native fallback remain the shared policy.
    public static func audioDecision(_ action: MediaKeyAction, preferences: NativeKeyPreferences,
                                     candidates: [AudioKeyCandidate], currentOutput: AudioOutputDevice?,
                                     pointer: DisplayOrigin?, focusedDisplay: DisplayRecordID?) -> AudioKeyRouter.Decision {
        AudioKeyRouter.decide(action, intent: .plain, candidates: candidates,
            context: .init(engagement: .always, targetMode: preferences.audioTarget,
                           nativeFallback: preferences.nativeAudioFallback, muteLeftToMacOS: false,
                           currentOutput: currentOutput, pointer: pointer, focusedDisplay: focusedDisplay))
    }

    public static func contrast(_ current: Float?, delta: Float) -> Float {
        SoftwareContrast.factor(forPosition: SoftwareContrast.position(forFactor: current ?? SoftwareContrast.neutral) + delta)
    }

    public static func temperature(_ current: Float?, delta: Float) -> Float {
        min(ColorTemperatureCurve.maxKelvin, max(ColorTemperatureCurve.minKelvin,
            (current ?? ColorTemperatureCurve.neutralKelvin)
                + delta * (ColorTemperatureCurve.maxKelvin - ColorTemperatureCurve.minKelvin)))
    }
}

public struct ShortcutKeyGesture: Sendable {
    public enum Effect: Equatable, Sendable { case invoke, release, ignore }
    private var held = false
    public init() {}

    public mutating func event(isDown: Bool, repeats: Bool) -> Effect {
        if isDown {
            let invoke = !held || repeats
            held = true
            return invoke ? .invoke : .ignore
        }
        guard held else { return .ignore }
        held = false
        return .release
    }
}

/// A volume shortcut owes at most one completion sound on release, independently of other chords.
/// Clearing registrations or cancelling capture discards any old release obligation.
public struct ShortcutReleaseFeedback: Sendable {
    private var pending: [HotkeyAction: KeyReleaseFeedback.Request] = [:]
    public init() {}
    public mutating func pressHandled(_ action: HotkeyAction, request: KeyReleaseFeedback.Request?) {
        pending[action] = request
    }
    public mutating func released(_ action: HotkeyAction) -> KeyReleaseFeedback.Request? {
        pending.removeValue(forKey: action)
    }
    public mutating func cancel() { pending.removeAll() }
}
