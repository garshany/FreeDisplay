#if os(macOS)
import AutomationSchema
import CoreGraphics
import DisplayDomain
import Foundation

/// Publishes OSD events to other processes (Batch-3 #6) so an external/notch HUD app can render
/// OpenDisplay's changes. Uses `DistributedNotificationCenter` with the stable, versioned
/// `OSDBroadcast` payload. Opt-in (gated by the caller on `publishOSDEventsEnabled`).
enum OSDBroadcaster {
    /// - Parameters:
    ///   - screenID: the screen OpenDisplay chose for feedback, as a hint for where to draw.
    ///   - control: what carried the change ("native", "ddc", "software").
    static func publish(_ content: OSDContent, displayID: String, displayName: String?, source: String,
                        screenID: CGDirectDisplayID?, control: String?, now: Date = Date()) {
        let hasLevel = content.kind != .input
        // Levels are normalized; saying so lets a receiver scale without assuming (FA-06). An input
        // switch has no level at all (IN-16), only the input's name.
        let broadcast = OSDBroadcast(
            kind: kind(content.kind), value: hasLevel ? Double(content.value) : nil, maxValue: hasLevel ? 1 : nil,
            displayID: displayID, displayName: displayName, source: source,
            timestamp: now.timeIntervalSince1970, screenID: screenID, symbol: content.glyph,
            text: content.label, control: control, state: state(content.assurance)?.rawValue)
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name(OSDBroadcast.notificationName),
            object: nil, userInfo: broadcast.userInfo, deliverImmediately: true)
    }

    private static func kind(_ kind: OSDContent.Kind) -> OSDBroadcast.Kind {
        switch kind {
        case .brightness: return .brightness
        case .volume: return .volume
        case .mute: return .mute
        case .input: return .input
        }
    }

    /// An event is posted as the change is made, so it is applied or requested; a verdict that
    /// arrives later is shown on the local HUD only, never as a second event for the same change.
    private static func state(_ assurance: OSDContent.Assurance) -> OSDBroadcast.State? {
        switch assurance {
        case .applied: return .applied
        case .requested: return .requested
        case .verified: return .verified
        case .notConfirmed: return nil
        }
    }
}

/// Listens for receiver apps' OSD settings handshake requests (IN-16) and posts each answer. The
/// request is read here, off the wire, before anything else sees it; what it may change is decided
/// by `OSDReceiverHandshake` through `answer`.
@MainActor
final class OSDReceiverHandshakeListener {
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(answer: @escaping @MainActor (OSDSettingsHandshake.Incoming) -> OSDSettingsHandshake.Response) {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(OSDSettingsHandshake.requestNotificationName), object: nil,
            queue: .main
        ) { notification in
            let incoming = OSDSettingsHandshake.decode(notification.object)
            MainActor.assumeIsolated {
                let response = answer(incoming)
                // The answer travels as the object too, so a receiver reads both directions the
                // same way (a sandboxed one can only post its requests that way).
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name(OSDSettingsHandshake.responseNotificationName),
                    object: response.jsonString, userInfo: nil, deliverImmediately: true)
            }
        }
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }
}
#endif
