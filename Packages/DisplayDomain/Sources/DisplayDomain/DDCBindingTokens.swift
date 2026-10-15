import Foundation

/// Decides whether a DDC binding that finished building may still be used (FB-08, TR-06).
///
/// Binding a display's I2C service runs off the main actor as one synchronous IOKit walk that
/// cancellation can't interrupt, so the question it answers can go stale while it runs: the display
/// may leave, or the user may revoke (or grant) its Apple-display override. Every caller awaiting a
/// build — the one that started it and each one that joined it — has to re-check when it resumes;
/// otherwise a power or input command queued behind the build reaches an Apple display after its
/// override was turned off.
///
/// Each build gets a token that is never handed out again. Dropping a display's binding
/// (`retain(only:)`) forgets the token it answers to, and a newer build for the same display
/// replaces it, so a finished build is usable only while its token is still the display's current
/// one AND the override it was started under is still the user's choice.
public struct DDCBindingTokens: Sendable {
    /// One build: its token and the Apple-display override it was started under.
    public struct Build: Hashable, Sendable {
        public let token: UInt64
        public let allowAppleDisplay: Bool
    }

    private var current: [DisplayRecordID: UInt64] = [:]
    private var lastIssued: UInt64 = 0

    public init() {}

    /// Starts a build for `id` under the given override, superseding any earlier build for it.
    public mutating func begin(_ id: DisplayRecordID, allowAppleDisplay: Bool) -> Build {
        lastIssued += 1
        current[id] = lastIssued
        return Build(token: lastIssued, allowAppleDisplay: allowAppleDisplay)
    }

    /// Forgets the binding of every display not in `kept` — they left, or their binding is being
    /// dropped (an override change). Builds started for them before this answer an outdated question.
    public mutating func retain(only kept: Set<DisplayRecordID>) {
        if !current.keys.allSatisfy(kept.contains) { current = current.filter { kept.contains($0.key) } }
    }

    /// Whether a finished `build` still answers the current question for `id`: nothing dropped or
    /// replaced the binding since it started, and the override is still what it was started under.
    public func isCurrent(_ build: Build, for id: DisplayRecordID, allowAppleDisplay: Bool) -> Bool {
        current[id] == build.token && build.allowAppleDisplay == allowAppleDisplay
    }
}
