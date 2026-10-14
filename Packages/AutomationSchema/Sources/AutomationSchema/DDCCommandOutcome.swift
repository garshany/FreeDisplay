import Foundation

/// What is known after asking a monitor to do something over DDC/CI, before any read-back.
///
/// Why this exists: a DDC/CI Set-VCP has no acknowledgement of *effect*. A transport-level success
/// only means the I2C transaction went through — the panel may still ignore the command, and power
/// or input commands typically take the picture (and often the DDC channel) away, so nothing can be
/// read back afterwards. The UI must therefore never turn `.sent` into "done", and must never
/// report a change for `.failed` or `.notSent`.
public enum DDCCommandOutcome: String, Equatable, Sendable {
    /// The I2C write went through. Whether the monitor acted on it is unverified.
    case sent
    /// The I2C write failed: the command did not reach the monitor (or the monitor NAKed it).
    case failed
    /// Nothing was sent: there is no usable DDC channel to this display (none found, the binding was
    /// refused, or this build has no DDC support).
    case notSent

    public init(transportAccepted: Bool) {
        self = transportAccepted ? .sent : .failed
    }

    /// Status word for the audit log.
    public var auditStatus: String { rawValue }
}

/// How much a DDC power command risks leaving the user without a usable screen (AM-04 / SD-03).
///
/// A DDC Standby/Off does not change the macOS arrangement: the display stays connected and keeps
/// whatever it hosts (menu bar, Dock, windows, the OpenDisplay menu) while its picture is gone, and
/// many monitors cannot be woken again over DDC. So the warning depends on what remains visible.
public enum DDCPowerRisk: Equatable, Sendable {
    /// Another visible screen stays on and this isn't the main display.
    case otherScreensRemain
    /// The menu bar and Dock live on this display; other screens remain to work from.
    case mainDisplay
    /// No other visible screen would remain.
    case onlyScreen

    /// - Parameters:
    ///   - isMain: the target is the current main display.
    ///   - otherVisibleScreens: active screens other than the target that would still show a picture
    ///     (callers exclude placeholders and blacked-out screens).
    public static func assess(isMain: Bool, otherVisibleScreens: Int) -> DDCPowerRisk {
        if otherVisibleScreens <= 0 { return .onlyScreen }
        return isMain ? .mainDisplay : .otherScreensRemain
    }
}

extension DDCPowerMode {
    /// Standby and Off take the picture away, possibly for good as far as DDC is concerned, so they are
    /// confirmed first. On can't make anything worse and is sent directly.
    public var needsConfirmation: Bool { self != .on }
}

/// Input-source switch bookkeeping that keeps "what we asked for" apart from "what the monitor
/// reports" (AM-05 / TB-01 / FB-06).
public struct DDCInputSwitch: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// Queued or being written.
        case sending
        /// The write went through; the switch itself is unconfirmed.
        case sent
        /// The write failed — the monitor is presumably still on its previous input.
        case failed
        /// Nothing was sent (no usable DDC channel).
        case notSent
    }

    /// The raw VCP 0x60 code that was requested.
    public var requested: Int
    public var status: Status

    public init(requested: Int, status: Status) {
        self.requested = requested
        self.status = status
    }

    public init(requested: Int, outcome: DDCCommandOutcome) {
        self.requested = requested
        switch outcome {
        case .sent: status = .sent
        case .failed: status = .failed
        case .notSent: status = .notSent
        }
    }

    /// The input to show as the monitor's current one after a switch attempt finished.
    ///
    /// A failed or unsent request changed nothing, so the last reported input stays. A sent request
    /// makes the old report stale — the monitor has probably moved — so it becomes unknown (nil)
    /// until the monitor is read again, unless the monitor was already reported on the requested
    /// input. The requested code itself is never promoted to "current": after a switch the monitor
    /// often stops answering DDC on this Mac's connection, so nothing confirms it.
    public static func reportedInput(after outcome: DDCCommandOutcome, requested: Int,
                                     previouslyReported: Int?) -> Int? {
        switch outcome {
        case .failed, .notSent: return previouslyReported
        case .sent: return previouslyReported == requested ? requested : nil
        }
    }
}
