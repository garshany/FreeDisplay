import DisplayDomain
import Foundation

/// Public audio glue implements these operations by persistent UID. There is deliberately no
/// operation for selecting the system output or creating an aggregate device.
@MainActor
public protocol NativeAudioControlling {
    func device(uid: String) -> AudioOutputDevice?
    @discardableResult func setVolume(_ level: Float, uid: String) -> NativeAudioWriteResult
    @discardableResult func setMute(_ muted: Bool, uid: String) -> NativeAudioWriteResult
}

public enum NativeAudioAdjustment {
    /// Only observed state is feedback. Mute-only outputs can confirm mute without inventing a
    /// volume level; an unreadable unmuted output has no level to report.
    public static func feedback(_ after: AudioOutputDevice) -> OSDContent? {
        if after.isMuted == true { return OSDContent(kind: .mute, value: 0, assurance: .verified) }
        guard let level = after.volumeLevel, level.isFinite, (0...1).contains(level) else { return nil }
        return OSDContent(kind: .volume, value: level, assurance: .verified)
    }

    public enum Outcome: Equatable, Sendable {
        case unavailable
        /// A setter rejected the command. A previous command may already have been accepted.
        case failed(partiallyApplied: Bool)
        /// Accepted by the audio API; readback may be absent and is not physical confirmation.
        case accepted(AudioOutputDevice?)

        public var handled: Bool {
            switch self {
            case .unavailable: return false
            case .failed(let partiallyApplied): return partiallyApplied
            case .accepted: return true
            }
        }
    }

    /// Re-read the resolved UID before computing a relative step. A disappearing output never
    /// redirects a pending operation to the default output, nor to an identically named device.
    @MainActor
    public static func apply(_ action: MediaKeyAction, uid: String, delta: Float,
                             controller: any NativeAudioControlling) -> Outcome {
        guard let device = controller.device(uid: uid), device.uid == uid else { return .unavailable }
        if action == .muteToggle {
            guard let mute = NativeVolumeStep.toggledMute(device) else { return .unavailable }
            let result = controller.setMute(mute, uid: uid)
            guard result == .accepted else { return .failed(partiallyApplied: result.wasApplied) }
        } else {
            guard action.isVolume, let step = NativeVolumeStep.step(device, delta: delta) else { return .unavailable }
            return setLevel(step.level, mute: step.mute, uid: uid, controller: controller)
        }
        return .accepted(controller.device(uid: uid))
    }

    @MainActor
    public static func setLevel(_ level: Float, uid: String,
                                controller: any NativeAudioControlling) -> Outcome {
        guard level.isFinite, let device = controller.device(uid: uid), device.uid == uid,
              device.volume.isSettable else { return .unavailable }
        let value = min(1, max(0, level))
        let mute: Bool? = device.muteIsToggleable && device.isMuted != (value == 0) ? value == 0 : nil
        return setLevel(value, mute: mute, uid: uid, controller: controller)
    }

    @MainActor
    private static func setLevel(_ level: Float, mute: Bool?, uid: String,
                                  controller: any NativeAudioControlling) -> Outcome {
        let result = controller.setVolume(level, uid: uid)
        guard result == .accepted else { return .failed(partiallyApplied: result.wasApplied) }
        if let mute, controller.setMute(mute, uid: uid) != .accepted { return .failed(partiallyApplied: true) }
        return .accepted(controller.device(uid: uid))
    }
}
