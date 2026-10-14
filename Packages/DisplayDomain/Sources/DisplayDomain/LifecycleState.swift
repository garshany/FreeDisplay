import Foundation

/// Where a display sits in the topology lifecycle. These states are never conflated with
/// presentation overlays or monitor power (PRD §9.2 invariant 11; §9.3 reachability model).
public enum Reachability: String, Hashable, Sendable, Codable {
    /// Not currently observed by macOS, and not necessarily disconnected by OpenDisplay.
    case systemAbsent
    /// Known to exist but not part of the active topology.
    case discoveredInactive
    /// Participating in the active macOS topology.
    case active
    /// Mid-flight removal from the active topology.
    case disconnecting
    /// Intentionally placed offline by OpenDisplay; can be reconnected.
    case managedOffline
    /// Mid-flight return to the active topology.
    case reconnecting
}

/// Presentation overlays are orthogonal to reachability — a display can be `active` *and*
/// `blackedOut` at once (PRD §9.3). Black Out is never the same concept as logical disconnect.
public enum PresentationOverlay: String, Hashable, Sendable, Codable {
    case visible
    case blackedOut
    case dimmed
    case filtered
}

/// What we know about the monitor's own power state. A DDC/network sleep command's outcome may
/// be unverifiable — that is its own state, never reported as success (PRD LIF-019, §9.2).
/// NOTE: part of the documented lifecycle vocabulary but not yet wired to a consumer.
public enum MonitorPower: String, Hashable, Sendable, Codable {
    case unknown
    case awake
    case sleepRequested
    case asleepVerified
    case powerFailed
}

/// What "turning a display off" actually does with the lifecycle provider in use. Neither path
/// powers a monitor down, so the menu, recovery text and notifications name this operation instead
/// of promising power-off.
public enum LogicalOffMethod: String, Hashable, Sendable, Codable {
    /// The display leaves the desktop (the experimental SkyLight provider). macOS may let the panel
    /// drop into standby, but whether it does is up to the monitor and the connection.
    case disconnect
    /// The display mirrors the main display (the public Core Graphics fallback, and the only path
    /// in the public-API-only build). It stays lit, showing the main display's picture.
    case mirror
}

extension Reachability {
    /// Legal reachability transitions. Any transition not listed here is a programming error
    /// and is rejected by the coordinator rather than written to hardware (PRD §9.3).
    public func canTransition(to next: Reachability) -> Bool {
        switch (self, next) {
        case (.systemAbsent, .discoveredInactive),
             (.systemAbsent, .active),
             (.discoveredInactive, .active),
             (.discoveredInactive, .systemAbsent),
             (.active, .disconnecting),
             (.active, .systemAbsent),
             (.disconnecting, .managedOffline),
             (.disconnecting, .active),          // rollback path
             (.managedOffline, .reconnecting),
             (.managedOffline, .systemAbsent),   // endpoint physically removed while offline
             (.reconnecting, .active),
             (.reconnecting, .managedOffline):   // reconnect failed; remain offline
            return true
        case let (a, b) where a == b:
            return true                          // idempotent no-op
        default:
            return false
        }
    }
}

/// The serialized transaction state machine that governs every topology/lifecycle mutation
/// (PRD §9.3). At most one transaction may be in a non-terminal state at any time (§9.2 inv. 1).
public enum TransactionState: String, Hashable, Sendable, Codable {
    case idle
    case resolving
    case preflight
    case checkpointed
    case applying
    case observing
    case verifying
    case committed
    case rollingBack
    case recovered
    case degraded
    case failed

    /// Terminal states end a transaction and release the coordinator's exclusivity.
    public var isTerminal: Bool {
        switch self {
        case .committed, .recovered, .degraded, .failed: return true
        default: return false
        }
    }

    public func canTransition(to next: TransactionState) -> Bool {
        switch (self, next) {
        case (.idle, .resolving),
             (.resolving, .preflight),
             (.resolving, .failed),
             (.preflight, .checkpointed),
             (.preflight, .failed),              // preflight blocked (e.g. no safe surface)
             (.checkpointed, .applying),
             (.checkpointed, .failed),           // user cancelled at confirmation
             (.applying, .observing),
             (.applying, .rollingBack),
             (.observing, .verifying),
             (.observing, .rollingBack),
             (.verifying, .committed),
             (.verifying, .rollingBack),
             (.verifying, .degraded),
             (.rollingBack, .recovered),
             (.rollingBack, .degraded),
             (.rollingBack, .failed):
            return true
        default:
            return false
        }
    }
}
