#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import TopologyCore

/// One native key event the tap captured, decoded to Sendable values only (CGEvent isn't Sendable).
struct NativeKeyEvent: Sendable, Equatable {
    var action: MediaKeyAction
    /// Key down (a press or an auto-repeat); false for the release.
    var isDown: Bool
    var isRepeat: Bool
    var modifiers: NativeKeyModifiers
    /// The same modifiers as the Carbon mask a recorded shortcut stores.
    var carbonModifiers: UInt32
    /// Set for F14/F15 standing in for a brightness key; nil for a real media key.
    var functionKeyCode: UInt16?
}

/// Captures the native brightness/volume keys — and, when asked, F14/F15 — and routes them to
/// OpenDisplay (Batch-3 #3, SO-25, SO-26).
///
/// macOS delivers media keys as `systemDefined` (`NX_SYSDEFINED`) events, which a Carbon hotkey can't
/// see — so this uses a `CGEventTap`. An *active* tap (not listen-only) is required so OpenDisplay can
/// **consume** a handled key, suppressing the system's own HUD (we draw our own via `OSDHUDController`).
/// That capability needs the **Accessibility** permission; `start()` returns false when it isn't
/// granted, leaving the keys to behave normally. Key presses the handler declines, and every key
/// event that isn't one of these, pass through untouched. A release is consumed exactly when its
/// press was, so macOS never sees half a key.
@MainActor
final class MediaKeyTap {
    /// Handle a key event. Return `true` if OpenDisplay acted on it (the event is then swallowed),
    /// `false` to let it pass through to macOS. Invoked on the main actor (the tap runs on the main
    /// run loop), so it can touch `AppModel`. Releases of consumed presses are delivered too, so the
    /// handler can give release feedback; their return value is ignored.
    private let handler: @MainActor (NativeKeyEvent) -> Bool

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Keys whose press was consumed and whose release hasn't arrived.
    private var sequence = NativeKeySequence()
    var onCancel: (() -> Void)?
    var brightnessWanted = true
    var volumeWanted = true
    /// Whether F14/F15 should be watched. Changing it rebuilds a running tap.
    var functionKeysWanted = false {
        didSet {
            guard functionKeysWanted != oldValue, eventTap != nil else { return }
            stop()
            start()
        }
    }

    init(handler: @escaping @MainActor (NativeKeyEvent) -> Bool) {
        self.handler = handler
    }

    /// Whether the process currently holds the Accessibility (TCC) grant the tap needs.
    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Show the system Accessibility prompt (the one-time grant request). Called only when the user
    /// turns the feature on, so a user who never enables it is never prompted.
    static func promptForAccessibility() {
        // Use the documented constant's literal value rather than the imported global `var`
        // `kAXTrustedCheckOptionPrompt`, which Swift 6 flags as not concurrency-safe to reference.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Create + enable the tap. Returns false (a no-op) when Accessibility isn't granted or the tap
    /// can't be created — the keys then reach macOS unchanged.
    @discardableResult
    func start() -> Bool {
        if let eventTap {
            guard Self.isAccessibilityTrusted else { stop(); return false }
            CGEvent.tapEnable(tap: eventTap, enable: true)
            return isActive
        }
        guard Self.isAccessibilityTrusted else { return false }

        var mask = CGEventMask(1 << 14)  // NSEvent.EventType.systemDefined
        if functionKeysWanted {
            mask |= CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: mediaKeyTapCallback, userInfo: refcon
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        return true
    }

    var isActive: Bool {
        guard let eventTap else { return false }
        return Self.isAccessibilityTrusted && CGEvent.tapIsEnabled(tap: eventTap)
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        sequence.cancel()
        onCancel?()
    }

    /// Re-arm the tap if the system disabled it (timeout / user input). Called from the C callback.
    func reEnableIfNeeded() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Dispatch a decoded key event; returns whether the event is consumed.
    func dispatch(_ event: NativeKeyEvent) -> Bool {
        let key = event.functionKeyCode.map(NativeKeySequence.Key.function) ?? .media(event.action)
        guard event.action.isBrightness ? brightnessWanted : volumeWanted else {
            sequence.cancel(key)
            return false
        }
        let trusted = Self.isAccessibilityTrusted
        if !trusted { onCancel?() }
        if event.isDown {
            return sequence.press(key, isRepeat: event.isRepeat, permissionGranted: trusted) { handler(event) }
        }
        guard sequence.release(key, permissionGranted: trusted) else { return false }
        _ = handler(event)
        return true
    }

    /// Decode a systemDefined CGEvent into a media-key event, or nil if it isn't a media key we
    /// care about. `nonisolated` + pure of actor state, so the C callback can run it before the
    /// main-actor hop.
    nonisolated static func decodeMediaKey(_ cgEvent: CGEvent) -> NativeKeyEvent? {
        guard let nsEvent = NSEvent(cgEvent: cgEvent), nsEvent.subtype.rawValue == 8 else { return nil }
        let data1 = nsEvent.data1
        let keyCode = Int((data1 & 0xFFFF_0000) >> 16)
        let keyFlags = data1 & 0x0000_FFFF
        let state = (keyFlags & 0xFF00) >> 8
        guard state == 0x0A || state == 0x0B, let action = MediaKeyAction.from(nxKeyType: keyCode) else { return nil }
        let flags = cgEvent.flags
        return NativeKeyEvent(action: action, isDown: state == 0x0A, isRepeat: keyFlags & 0x1 != 0,
                              modifiers: modifiers(flags), carbonModifiers: carbonModifiers(flags),
                              functionKeyCode: nil)
    }

    /// Decode an ordinary key event into an F14/F15 brightness event, or nil for every other key —
    /// those return to the system before any main-actor work.
    nonisolated static func decodeFunctionKey(_ cgEvent: CGEvent, type: CGEventType) -> NativeKeyEvent? {
        guard type == .keyDown || type == .keyUp else { return nil }
        let keyCode = UInt16(truncatingIfNeeded: cgEvent.getIntegerValueField(.keyboardEventKeycode))
        guard let action = AlternativeBrightnessKey.action(forKeyCode: keyCode) else { return nil }
        let flags = cgEvent.flags
        return NativeKeyEvent(action: action, isDown: type == .keyDown,
                              isRepeat: cgEvent.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                              modifiers: modifiers(flags), carbonModifiers: carbonModifiers(flags),
                              functionKeyCode: keyCode)
    }

    /// Shift/Control/Option/Command only: Fn, Caps Lock and the keypad flag aren't part of a chord.
    nonisolated private static func modifiers(_ flags: CGEventFlags) -> NativeKeyModifiers {
        var modifiers: NativeKeyModifiers = []
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        return modifiers
    }

    nonisolated private static func carbonModifiers(_ flags: CGEventFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.maskCommand) { mask |= KeyBinding.command }
        if flags.contains(.maskShift) { mask |= KeyBinding.shift }
        if flags.contains(.maskAlternate) { mask |= KeyBinding.option }
        if flags.contains(.maskControl) { mask |= KeyBinding.control }
        return mask
    }
}

/// Top-level C callback (must not capture) for the media-key event tap. Recovers the owning
/// `MediaKeyTap` from `refcon` and consumes the event when handled. The tap runs on the main run loop,
/// so it's safe to hop onto the main actor; only Sendable decoded values cross that hop (not the
/// non-Sendable `CGEvent`).
private func mediaKeyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { tap.reEnableIfNeeded() }
        return Unmanaged.passUnretained(event)
    }

    let decoded = type == .keyDown || type == .keyUp
        ? MediaKeyTap.decodeFunctionKey(event, type: type)
        : MediaKeyTap.decodeMediaKey(event)
    guard let decoded else { return Unmanaged.passUnretained(event) }
    let consumed = MainActor.assumeIsolated { tap.dispatch(decoded) }
    return consumed ? nil : Unmanaged.passUnretained(event)
}
#endif
