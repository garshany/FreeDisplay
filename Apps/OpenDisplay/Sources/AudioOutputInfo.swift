#if os(macOS)
import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import TopologyCore

/// The sound outputs macOS has right now and the one it plays through.
struct AudioOutputSnapshot: Equatable {
    var devices: [AudioOutputDevice] = []
    var defaultOutputUID: String?

    var currentOutput: AudioOutputDevice? {
        defaultOutputUID.flatMap { uid in devices.first { $0.uid == uid } }
    }
}

/// macOS's sound outputs through public CoreAudio (TR-16, SD-16, FA-26): every output device's
/// name, persistent UID, transport and separately reported volume/mute controls; the current
/// default output; and writes of volume and mute to one device chosen by UID.
///
/// It never changes which output macOS plays through, and never creates or edits an aggregate
/// device. Reads go to CoreAudio when asked (a key press reads the current state, not a cache that
/// may predate an output switch); property listeners only tell Settings to redraw.
@MainActor
final class CoreAudioOutputs: NativeAudioControlling {
    /// Called on the main actor whenever CoreAudio reports a change to the device list, the default
    /// output, or the volume/mute of a listed output.
    var onChange: ((AudioOutputSnapshot) -> Void)?

    private var listening = false
    private var deviceListeners: [AudioDeviceID: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)]] = [:]
    private var systemListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    /// A fresh read of every output device and the default output.
    func snapshot() -> AudioOutputSnapshot {
        let ids = Self.outputDeviceIDs()
        let devices = ids.compactMap(Self.device(for:))
        let defaultUID = Self.defaultOutputDeviceID().flatMap(Self.uid(of:))
        return AudioOutputSnapshot(devices: devices, defaultOutputUID: defaultUID)
    }

    /// Starts the change notifications (idempotent). Listening reads and observes; it writes nothing.
    func startListening() {
        guard !listening else { return }
        listening = true
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            let block = listenerBlock()
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                                   DispatchQueue.main, block) == noErr {
                systemListeners.append((address, block))
            }
        }
        refreshDeviceListeners()
    }

    /// Uses the supported HAL scalar properties, never the obsolete Audio Hardware Service
    /// virtual-volume selector (which AudioObject APIs do not implement).
    @discardableResult
    func setVolume(_ level: Float, uid: String) -> NativeAudioWriteResult {
        guard let id = Self.deviceID(forUID: uid),
              let writes = NativeAudioVolume.writes(level: level, channels: Self.volumeChannels(id)) else { return .rejected }
        var applied = false
        var failed = false
        for channel in writes {
            var address = Self.volumeAddress(channel.element)
            var value = Float32(channel.level ?? 0)
            let accepted = AudioObjectSetPropertyData(id, &address, 0, nil,
                                                      UInt32(MemoryLayout<Float32>.size), &value) == noErr
            applied = applied || accepted
            failed = failed || !accepted
        }
        return !applied ? .rejected : failed ? .partial : .accepted
    }

    @discardableResult
    func setMute(_ muted: Bool, uid: String) -> NativeAudioWriteResult {
        guard let id = Self.deviceID(forUID: uid) else { return .rejected }
        var address = Self.muteAddress
        guard Self.access(id, &address).isSettable else { return .rejected }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
            ? .accepted : .rejected
    }

    /// The output with `uid` as CoreAudio reports it now (after a write, the read-back).
    func device(uid: String) -> AudioOutputDevice? {
        Self.deviceID(forUID: uid).flatMap(Self.device(for:))
    }

    // MARK: - Listeners

    private func listenerBlock() -> AudioObjectPropertyListenerBlock {
        { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshDeviceListeners()
                self.onChange?(self.snapshot())
            }
        }
    }

    /// Volume and mute listeners on every current output, so a change made in Control Center or by
    /// another app reaches Settings. Devices that left lose theirs.
    private func refreshDeviceListeners() {
        let current = Set(Self.outputDeviceIDs())
        for (id, listeners) in deviceListeners where !current.contains(id) {
            for (address, block) in listeners {
                var address = address
                AudioObjectRemovePropertyListenerBlock(id, &address, DispatchQueue.main, block)
            }
            deviceListeners[id] = nil
        }
        for id in current where deviceListeners[id] == nil {
            var added: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
            for address in Self.volumeChannels(id).map({ Self.volumeAddress($0.element) }) + [Self.muteAddress] {
                var address = address
                guard AudioObjectHasProperty(id, &address) else { continue }
                let block = listenerBlock()
                if AudioObjectAddPropertyListenerBlock(id, &address, DispatchQueue.main, block) == noErr {
                    added.append((address, block))
                }
            }
            deviceListeners[id] = added
        }
    }

    // MARK: - CoreAudio reads

    private static func volumeAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioObjectPropertyScopeOutput, mElement: element)
    }

    private static func outputChannelCount(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + $1.mNumberChannels }
    }

    private static func volumeChannels(_ id: AudioDeviceID) -> [NativeAudioVolume.Channel] {
        var main = volumeAddress(kAudioObjectPropertyElementMain)
        let count = outputChannelCount(id)
        let elements: [AudioObjectPropertyElement] = AudioObjectHasProperty(id, &main)
            ? [kAudioObjectPropertyElementMain] : count > 0 ? Array(1...count) : []
        return elements.compactMap { element in
            var address = volumeAddress(element)
            let access = access(id, &address)
            guard access != .absent else { return nil }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            let read = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr
            return .init(element: element, access: access, level: read ? value : nil)
        }
    }

    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Every device with at least one output stream.
    private static func outputDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(hasOutputStreams)
    }

    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        outputDeviceIDs().first { self.uid(of: $0) == uid }
    }

    private static func device(for id: AudioDeviceID) -> AudioOutputDevice? {
        guard let uid = uid(of: id) else { return nil }
        let channels = volumeChannels(id)
        var muteAddress = Self.muteAddress
        let volumeAccess = NativeAudioVolume.access(channels)
        let muteAccess = access(id, &muteAddress)
        var mute: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        let muteRead = muteAccess != .absent
            && AudioObjectGetPropertyData(id, &muteAddress, 0, nil, &muteSize, &mute) == noErr
        return AudioOutputDevice(uid: uid, name: stringProperty(id, kAudioObjectPropertyName) ?? "",
                                 transport: transport(id), volume: volumeAccess, mute: muteAccess,
                                 volumeLevel: NativeAudioVolume.level(channels),
                                 isMuted: muteRead ? mute != 0 : nil)
    }

    private static func access(_ id: AudioDeviceID, _ address: inout AudioObjectPropertyAddress) -> AudioControlAccess {
        guard AudioObjectHasProperty(id, &address) else { return .absent }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr else { return .readOnly }
        return settable.boolValue ? .settable : .readOnly
    }

    private static func uid(of id: AudioDeviceID) -> String? {
        stringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func transport(_ id: AudioDeviceID) -> AudioOutputTransport {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else { return .other }
        switch transport {
        case kAudioDeviceTransportTypeHDMI: return .hdmi
        case kAudioDeviceTransportTypeDisplayPort: return .displayPort
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeAggregate: return .aggregate
        case kAudioDeviceTransportTypeVirtual: return .virtual
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        default: return .other
        }
    }
}

/// The volume feedback sound (FA-20/T35): macOS's own volume click, played once when a volume key
/// is released or a volume slider drag ends, on the affected output when that one is known.
@MainActor
enum VolumeFeedbackSoundPlayer {
    /// macOS's "play feedback when volume is changed" switch. It has no public API: this reads the
    /// global preference Sound settings writes, best-effort — nil when it isn't there.
    static var systemPreference: Bool? {
        (UserDefaults.standard.object(forKey: "com.apple.sound.beep.feedback") as? NSNumber)?.boolValue
    }

    /// The sound macOS plays for volume feedback. A system resource, not an API: when a macOS
    /// release moves it, no feedback is played rather than a different sound.
    private static let soundPath = "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"
    private static var current: NSSound?

    /// Plays the sound on the output with `outputUID`, or on the default output when nil.
    static func play(on outputUID: String?) {
        if let outputUID, CoreAudioOutputs().device(uid: outputUID) == nil { return }
        guard let sound = NSSound(contentsOfFile: soundPath, byReference: true) else { return }
        current?.stop()
        if let outputUID { sound.playbackDeviceIdentifier = outputUID }
        current = sound
        sound.play()
    }
}
#endif
