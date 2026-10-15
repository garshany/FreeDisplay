import Foundation

/// Semantic precedence, including prereleases. Build metadata never changes precedence.
/// One/two-component app versions and a leading v remain supported for older builds.
public struct SemanticVersion: Hashable, Sendable, Comparable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [String]

    public init?(_ string: String) {
        let value = string.hasPrefix("v") || string.hasPrefix("V") ? String(string.dropFirst()) : string
        let metadata = value.split(separator: "+", omittingEmptySubsequences: false)
        guard metadata.count <= 2 else { return nil }
        if metadata.count == 2, !Self.validIdentifiers(String(metadata[1]), numericLeadingZeros: true) { return nil }
        let parts = metadata[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(numbers.count) else { return nil }
        var parsed: [Int] = []
        for number in numbers {
            guard Self.isNumeric(String(number)), number.count == 1 || number.first != "0",
                  let n = Int(number) else { return nil }
            parsed.append(n)
        }
        while parsed.count < 3 { parsed.append(0) }
        major = parsed[0]; minor = parsed[1]; patch = parsed[2]
        if parts.count == 2 {
            guard Self.validIdentifiers(String(parts[1]), numericLeadingZeros: false) else { return nil }
            prerelease = parts[1].split(separator: ".").map(String.init)
        } else {
            prerelease = []
        }
    }

    private static func isNumeric(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func validIdentifiers(_ value: String, numericLeadingZeros: Bool) -> Bool {
        value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
            } && (numericLeadingZeros || !isNumeric(String(part)) || part.count == 1 || part.first != "0")
        }
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let left = (lhs.major, lhs.minor, lhs.patch), right = (rhs.major, rhs.minor, rhs.patch)
        if left != right { return left < right }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            let an = isNumeric(a), bn = isNumeric(b)
            if an != bn { return an }
            // Compare arbitrarily long numeric identifiers without integer overflow.
            if an && a.count != b.count { return a.count < b.count }
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

/// How a release advertised in the update feed stands relative to the running build.
public enum ReleaseRelation: Hashable, Sendable {
    /// Newer than what's running; `version` is its display string (a leading `v` stripped).
    case newer(version: String)
    /// The same marketing version — typically a re-built release of what is already installed.
    case same
    /// Behind the running build: a dev build ahead of the feed, or a mis-ordered release.
    case older
}

/// Where the app is in an update session, as far as its own UI is concerned. The updater (Sparkle)
/// owns the download, the signature check, the install, and every window shown along the way; this
/// is what the menu rows, the About surfaces and the Settings sidebar need in order to render one
/// honest line — and to keep apart results that must never be confused: "up to date" only ever
/// means a feed that was read and offers nothing newer, never a check that failed.
public enum SoftwareUpdatePhase: Hashable, Sendable {
    /// Nothing known: the launch state, where a check without a verdict lands, and where a stale
    /// result is cleared to.
    case idle
    /// A check is in flight — the user's, or the updater's scheduled one.
    case checking
    /// The feed was read and offers nothing newer for this build.
    case upToDate
    /// The feed offers something newer, but not for this Mac.
    case incompatible(SoftwareUpdateIncompatibility)
    /// The check, the download or the installation failed — never shown as "up to date".
    case failed(SoftwareUpdateFailure)
    /// A newer release is waiting; `version` is its display string ("0.9.1"). It stays until it is
    /// installed or skipped, or stops being newer than the running build.
    case available(version: String)
    /// Downloading the offered release. `expectedBytes` is nil until the server says.
    case downloading(version: String?, receivedBytes: UInt64, expectedBytes: UInt64?)
    /// Unpacking and verifying the download. It can no longer be cancelled.
    case extracting(version: String?)
    /// Downloaded and verified: installs on relaunch, or when the app quits (`installsOnQuit`).
    case readyToInstall(version: String?, installsOnQuit: Bool)
    /// The update is being installed and the app is about to relaunch.
    case installing
    /// Sparkle completed installation; this process can remain open when no relaunch was requested.
    case installed(relaunched: Bool)

    /// The release this phase is about, when it is about one.
    public var version: String? {
        switch self {
        case .available(let version): return version
        case .downloading(let version, _, _), .extracting(let version), .readyToInstall(let version, _):
            return version
        case .idle, .checking, .upToDate, .incompatible, .failed, .installing, .installed:
            return nil
        }
    }

    /// An offer is open or being acted on: a new check must not replace it, and clicking the row
    /// brings the updater's window back instead.
    public var isSessionInProgress: Bool {
        switch self {
        case .available, .downloading, .extracting, .readyToInstall, .installing: return true
        case .idle, .checking, .upToDate, .incompatible, .failed, .installed: return false
        }
    }

    /// A finished check's answer that only describes that moment: it may be cleared when it goes
    /// stale. An available update is not one — it stays until resolved.
    public var isTemporaryResult: Bool {
        switch self {
        case .upToDate, .incompatible, .failed: return true
        default: return false
        }
    }
}

/// Why a newer release isn't offered to this Mac.
public enum SoftwareUpdateIncompatibility: Hashable, Sendable {
    /// It needs a newer macOS (`minimum` from the feed, when known).
    case systemTooOld(minimum: String?)
    /// It doesn't support a macOS this new (`maximum` from the feed, when known).
    case systemTooNew(maximum: String?)
    /// It needs hardware this Mac doesn't have.
    case hardwareUnsupported
}

/// Why an update session failed. Each case is its own observable outcome (SO-14): a network failure
/// is never "up to date", a signature failure never a download problem, and an authorization the
/// user cancelled never an error they didn't cause.
public enum SoftwareUpdateFailure: Hashable, Sendable {
    /// The update server couldn't be reached (offline, DNS, timeout, TLS).
    case network
    /// No applicability reason was supplied; cannot claim the running build is current.
    case unknownResult
    /// The update feed was missing or unreadable.
    case feedUnreadable
    /// The download failed the EdDSA or code-signature check, so nothing was installed.
    case signatureRejected
    /// The download didn't complete.
    case downloadFailed
    /// The download couldn't be unpacked.
    case extractionFailed
    /// The administrator prompt was cancelled; nothing changed.
    case authorizationCancelled
    /// The user chose to authorize later; the update waits.
    case authorizationDeferred
    /// Authorization failed.
    case authorizationFailed
    /// Installing failed after the download was verified.
    case installationFailed
    /// The update was installed but the app couldn't be reopened.
    case relaunchFailed
    /// The feed offered an older build than the one running, and it was refused.
    case downgradeRefused
    /// The app runs from a disk image or a translocated copy, where it can't replace itself.
    case cannotUpdateInPlace
    /// The updater itself is misconfigured (feed address, signing key, bundle).
    case misconfigured
    /// Anything else, by Sparkle error code.
    case other(code: Int)

    /// A failure of the check itself, before anything was downloaded. Such a failure in a later
    /// check doesn't retract an update already found.
    public var happensBeforeDownload: Bool {
        switch self {
        case .network, .feedUnreadable, .misconfigured, .cannotUpdateInPlace: return true
        default: return false
        }
    }

    /// The user's own choice rather than something going wrong.
    public var isUserChoice: Bool {
        self == .authorizationCancelled || self == .authorizationDeferred
    }
}

/// Why Sparkle said there was nothing to install, as its `SPUNoUpdateFoundReason` reports it.
public enum SoftwareUpdateNoUpdateReason: Hashable, Sendable {
    case onLatestVersion
    case onNewerThanLatestVersion
    case systemTooOld(minimum: String?)
    case systemTooNew(maximum: String?)
    case hardwareUnsupported
    /// Sparkle read the feed but gave no reason.
    case unknown
}

/// What the updater just reported — one case per thing the app can observe, so the phase machine
/// below stays a pure function of (phase, event) and is exercised by `make test`.
public enum SoftwareUpdateEvent: Hashable, Sendable {
    /// A check began.
    case checkStarted
    /// A newer release was found; `version` is its display string.
    case updateFound(version: String, build: String? = nil)
    /// The feed had nothing newer to offer.
    case noUpdateFound
    /// The feed had nothing to install here, for `reason`.
    case noUpdate(SoftwareUpdateNoUpdateReason)
    /// The user chose "Skip This Version" — they aren't reminded again unless they ask.
    case updateSkipped
    /// The user dismissed the offer ("Remind Me Later", or closed it). It stays available.
    case offerDismissed
    /// The user cancelled a check in flight.
    case checkCancelled
    /// Downloading began.
    case downloadStarted
    /// The server announced the download's size.
    case downloadExpectedLength(UInt64)
    /// More of the download arrived.
    case downloadReceived(UInt64)
    /// The user cancelled the download. The offer itself still stands.
    case downloadCancelled
    /// Unpacking and verification began.
    case extractionStarted
    /// Prepared, and waiting for the user to install and relaunch.
    case readyToInstall
    /// Prepared to install when the app quits (an automatic download).
    case installOnQuitScheduled(version: String)
    /// Installation started; the relaunch follows.
    case installationStarted
    case installationCompleted(relaunched: Bool)
    /// The session failed.
    case failed(SoftwareUpdateFailure)
    /// The update cycle ended, with or without an error.
    case checkFinished
}

/// How one update affordance — a menu row, the About window's control, the Settings row — should
/// render. Every surface reads the same value, so they can't drift apart on wording, icon, colour,
/// or what a click does.
public struct SoftwareUpdatePresentation: Hashable, Sendable {
    /// What clicking the affordance does.
    public enum Action: Hashable, Sendable {
        /// Start a check — or retry one that failed or went stale.
        case check
        /// Cancel what is in flight.
        case cancel
        /// Bring the updater's own window for the waiting update forward. Never starts a duplicate
        /// check, and opening it is not installing.
        case showOffer
        /// Nothing to do while this phase lasts.
        case none
    }

    /// The colour family: green for a known "nothing newer", orange for something waiting, red for
    /// a failure, neutral otherwise.
    public enum Tone: Hashable, Sendable { case neutral, success, attention, problem }

    /// The row's label ("Check for Updates…").
    public let title: String
    /// SF Symbol shown beside the title.
    public let systemImage: String
    /// Trailing version pill, when there is a version worth showing.
    public let badge: String?
    /// True while work is in flight: the surface shows a spinner.
    public let showsProgress: Bool
    public let tone: Tone
    public let action: Action
    /// Download progress, 0...1, when the total size is known.
    public let fraction: Double?

    public init(title: String, systemImage: String, badge: String? = nil, showsProgress: Bool = false,
                tone: Tone = .neutral, action: Action = .check, fraction: Double? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.badge = badge
        self.showsProgress = showsProgress
        self.tone = tone
        self.action = action
        self.fraction = fraction
    }

    /// Title with the badge folded in ("Update available: 0.9.1"), for the surfaces that render the
    /// whole state on one line rather than as a row plus a pill.
    public var combinedTitle: String {
        guard let badge else { return title }
        return "\(title): \(badge)"
    }

    /// Whether a click does anything.
    public var isActionable: Bool { action != .none }
}

/// The update state the UI shows, with what the phase alone doesn't carry: when a result arrived
/// (to clear it once stale), whether the release notes failed to load (which says nothing about the
/// update itself), and whether what is in flight can be cancelled from the app's own controls.
public struct SoftwareUpdateStatus: Hashable, Sendable {
    public private(set) var phase: SoftwareUpdatePhase = .idle
    /// When the current temporary result (`SoftwareUpdatePhase.isTemporaryResult`) arrived.
    public private(set) var resultAt: Date?
    /// The offer's release notes couldn't be loaded. Independent of whether the update is fine.
    public private(set) var releaseNotesFailed = false
    public private(set) var offeredBuild: String?
    /// Set by the updater shell while it holds a way to cancel what is in flight.
    public var canCancel = false
    /// The user cancelled, and the updater may still report the abandoned session's error or end;
    /// neither replaces the cleared state the cancel asked for.
    private var cancelledByUser = false

    public init() {}

    /// Applies `event`, observed at `date`.
    public mutating func record(_ event: SoftwareUpdateEvent, at date: Date) {
        switch event {
        case .checkStarted, .updateFound, .downloadStarted:
            cancelledByUser = false
        case .checkCancelled, .downloadCancelled:
            cancelledByUser = true
        case .failed, .checkFinished:
            if cancelledByUser {
                if event == .checkFinished { cancelledByUser = false }
                return
            }
        default:
            break
        }
        if case .updateFound(_, let build) = event {
            releaseNotesFailed = false
            offeredBuild = build
        }
        let next = SoftwareUpdatePolicy.phase(after: event, from: phase)
        if next != phase {
            phase = next
            resultAt = next.isTemporaryResult ? date : nil
        }
    }

    /// The offer's release notes failed to load.
    public mutating func recordReleaseNotesFailure() {
        releaseNotesFailed = true
    }

    /// Clears a temporary result older than `staleAfter` when a surface shows it again — the clear
    /// happens on re-entry, never on a timer. Nil `staleAfter` keeps results until the next check.
    /// Returns whether anything changed.
    @discardableResult
    public mutating func clearIfStale(now: Date, staleAfter: TimeInterval?) -> Bool {
        guard let staleAfter, phase.isTemporaryResult, let resultAt,
              now.timeIntervalSince(resultAt) > staleAfter else { return false }
        phase = .idle
        self.resultAt = nil
        return true
    }

    /// Drop an offer only by its actual CFBundleVersion. Marketing versions may be identical for
    /// different builds; the app supplies Sparkle's comparator instead of duplicating its rules.
    @discardableResult
    public mutating func dropOffer(ifNotNewerThanBuild running: String,
                                   compare: (String, String) -> ComparisonResult) -> Bool {
        guard case .available = phase, let offeredBuild,
              compare(offeredBuild, running) != .orderedDescending else { return false }
        phase = .idle
        resultAt = nil
        self.offeredBuild = nil
        return true
    }

    /// How the status renders.
    public var presentation: SoftwareUpdatePresentation {
        SoftwareUpdatePolicy.presentation(for: phase, canCancel: canCancel)
    }
}

/// What the updater may do unattended, derived from the two user settings.
public struct AutomaticUpdateBehavior: Hashable, Sendable {
    /// Check the feed on a schedule.
    public let checksForUpdates: Bool
    /// Download a found update and install it without being asked each time.
    public let downloadsAndInstalls: Bool

    public init(checksForUpdates: Bool, downloadsAndInstalls: Bool) {
        self.checksForUpdates = checksForUpdates
        self.downloadsAndInstalls = downloadsAndInstalls
    }
}

/// Pure decision logic for software updates: how a release compares to the running build, how the UI
/// phase advances as the updater reports events, how each phase renders, and what the updater may do
/// unattended. Deterministic and unit-tested; the Sparkle plumbing that feeds it is app-side in
/// `SoftwareUpdater`, which stays a thin I/O shell.
public enum SoftwareUpdatePolicy {
    /// Compares an advertised release against the running build. Returns nil when either side doesn't
    /// parse — an unparseable version must not produce a verdict a caller can act on.
    public static func relation(
        ofAdvertised advertised: String, toRunning running: String
    ) -> ReleaseRelation? {
        guard let runningVersion = SemanticVersion(running),
              let advertisedVersion = SemanticVersion(advertised) else { return nil }
        guard advertisedVersion > runningVersion else {
            return advertisedVersion == runningVersion ? .same : .older
        }
        var display = advertised
        if display.hasPrefix("v") || display.hasPrefix("V") { display.removeFirst() }
        return .newer(version: display)
    }

    /// Whether a release the feed offers may be installed over the running build. Sparkle picks its
    /// update by build number (`CFBundleVersion`), so a feed listing releases out of order — a hotfix
    /// for an older line published after a newer one — can offer a real downgrade. Refusing that is
    /// the same belt-and-braces posture the display transactions take; when the two versions can't be
    /// compared at all we defer to the updater rather than block a legitimate update.
    public static func mayInstall(advertised: String, running: String) -> Bool {
        relation(ofAdvertised: advertised, toRunning: running) != .older
    }

    /// The phase an `event` moves the UI to. The rules that carry the behaviour:
    ///
    /// * A cycle that ends without a verdict (no reason given) falls back to `idle` rather than
    ///   claiming the app is up to date; a failure is its own phase, never "up to date".
    /// * An ending cycle never retracts a phase that already has something to say — dismissing the
    ///   update alert leaves "Update available" standing, which is the point of a gentle reminder.
    /// * An open session is sticky across a new check: clicking a badged row only brings the
    ///   updater's own window back, and swapping the badge for a spinner would strand the row if no
    ///   fresh cycle runs. For the same reason a later check that fails before downloading doesn't
    ///   retract an update already found.
    /// * Cancelling a check clears the inline state; cancelling a download leaves the offer standing.
    public static func phase(
        after event: SoftwareUpdateEvent, from phase: SoftwareUpdatePhase
    ) -> SoftwareUpdatePhase {
        switch event {
        case .checkStarted:
            return phase.isSessionInProgress ? phase : .checking
        case .updateFound(let version, _):
            return .available(version: version)
        case .noUpdateFound:
            return .upToDate
        case .noUpdate(let reason):
            switch reason {
            case .onLatestVersion, .onNewerThanLatestVersion: return .upToDate
            case .unknown: return .failed(.unknownResult)
            case .systemTooOld(let minimum): return .incompatible(.systemTooOld(minimum: minimum))
            case .systemTooNew(let maximum): return .incompatible(.systemTooNew(maximum: maximum))
            case .hardwareUnsupported: return .incompatible(.hardwareUnsupported)
            }
        case .updateSkipped:
            return .idle
        case .offerDismissed:
            return phase
        case .checkCancelled:
            return phase == .checking ? .idle : phase
        case .downloadStarted:
            return .downloading(version: phase.version, receivedBytes: 0, expectedBytes: nil)
        case .downloadExpectedLength(let length):
            guard case .downloading(let version, let received, _) = phase else { return phase }
            return .downloading(version: version, receivedBytes: received, expectedBytes: length)
        case .downloadReceived(let length):
            guard case .downloading(let version, let received, let expected) = phase else { return phase }
            let (sum, overflow) = received.addingReportingOverflow(length)
            return .downloading(version: version, receivedBytes: overflow ? .max : sum, expectedBytes: expected)
        case .downloadCancelled:
            guard case .downloading(let version, _, _) = phase else { return phase }
            return version.map { .available(version: $0) } ?? .idle
        case .extractionStarted:
            return .extracting(version: phase.version)
        case .readyToInstall:
            return .readyToInstall(version: phase.version, installsOnQuit: false)
        case .installOnQuitScheduled(let version):
            return .readyToInstall(version: version, installsOnQuit: true)
        case .installationStarted:
            return .installing
        case .installationCompleted(let relaunched):
            return .installed(relaunched: relaunched)
        case .failed(let failure):
            if case .available = phase, failure.happensBeforeDownload { return phase }
            return .failed(failure)
        case .checkFinished:
            switch phase {
            case .checking:
                return .idle
            case .downloading(let version, _, _), .extracting(let version):
                // The session ended without finishing the download: the offer is what remains.
                return version.map { .available(version: $0) } ?? .idle
            default:
                return phase
            }
        }
    }

    /// How `phase` renders on a menu row or in the About surfaces. `canCancel`: the updater shell
    /// holds a way to cancel what is in flight (a check the user started, or a download).
    public static func presentation(
        for phase: SoftwareUpdatePhase, canCancel: Bool = false
    ) -> SoftwareUpdatePresentation {
        switch phase {
        case .idle:
            return SoftwareUpdatePresentation(title: "Check for Updates…", systemImage: "arrow.down.circle")
        case .checking:
            return SoftwareUpdatePresentation(
                title: "Checking for updates…", systemImage: "arrow.down.circle", showsProgress: true,
                action: canCancel ? .cancel : .none)
        case .upToDate:
            return SoftwareUpdatePresentation(title: "Up to date", systemImage: "checkmark.circle", tone: .success)
        case .incompatible(let incompatibility):
            let title: String
            switch incompatibility {
            case .systemTooOld: title = "A newer version needs a newer macOS"
            case .systemTooNew: title = "A newer version doesn't support this macOS"
            case .hardwareUnsupported: title = "A newer version doesn't support this Mac"
            }
            return SoftwareUpdatePresentation(title: title, systemImage: "exclamationmark.circle")
        case .failed(let failure):
            return SoftwareUpdatePresentation(
                title: failureTitle(failure),
                systemImage: failure.isUserChoice ? "xmark.circle" : "exclamationmark.triangle",
                tone: failure.isUserChoice ? .neutral : .problem)
        case .available(let version):
            return SoftwareUpdatePresentation(
                title: "Update available", systemImage: "arrow.down.circle.fill", badge: version,
                tone: .attention, action: .showOffer)
        case .downloading(let version, let received, let expected):
            let fraction = expected.flatMap { $0 > 0 ? min(1, Double(received) / Double($0)) : nil }
            return SoftwareUpdatePresentation(
                title: "Downloading update…", systemImage: "arrow.down.circle", badge: version,
                showsProgress: true, tone: .attention, action: canCancel ? .cancel : .showOffer,
                fraction: fraction)
        case .extracting(let version):
            return SoftwareUpdatePresentation(
                title: "Preparing update…", systemImage: "arrow.down.circle", badge: version,
                showsProgress: true, tone: .attention, action: .showOffer)
        case .readyToInstall(let version, let installsOnQuit):
            return SoftwareUpdatePresentation(
                title: installsOnQuit ? "Update installs when you quit" : "Update ready: relaunch to install",
                systemImage: "arrow.triangle.2.circlepath", badge: version, tone: .attention,
                action: .showOffer)
        case .installed(let relaunched):
            return SoftwareUpdatePresentation(
                title: relaunched ? "Update installed and reopened" : "Update installed; reopen FreeDisplay to use it",
                systemImage: "checkmark.circle", tone: .success, action: .none)
        case .installing:
            return SoftwareUpdatePresentation(
                title: "Installing update…", systemImage: "arrow.down.circle.fill", showsProgress: true,
                action: .none)
        }
    }

    /// The one-line wording of each failure (English source; the app looks it up in its catalog).
    public static func failureTitle(_ failure: SoftwareUpdateFailure) -> String {
        switch failure {
        case .network: return "Couldn’t reach the update server"
        case .unknownResult: return "Update availability is unknown"
        case .feedUnreadable: return "Couldn’t read the update information"
        case .signatureRejected: return "Update rejected: its signature didn’t check out"
        case .downloadFailed: return "The update download failed"
        case .extractionFailed: return "The update couldn’t be unpacked"
        case .authorizationCancelled: return "Installation cancelled"
        case .authorizationDeferred: return "Installation postponed"
        case .authorizationFailed: return "Not authorized to install the update"
        case .installationFailed: return "The update couldn’t be installed"
        case .relaunchFailed: return "Updated, but couldn’t reopen"
        case .downgradeRefused: return "An older version was offered and refused"
        case .cannotUpdateInPlace: return "Move the app to Applications to update it"
        case .misconfigured: return "Updates aren’t set up correctly in this build"
        case .other: return "The update failed"
        }
    }

    /// What the updater may do unattended, given the two settings. Downloading is gated on checking:
    /// an updater that never looks at the feed can't install from it, so the download preference is
    /// remembered but inert until automatic checks are on — the same way Sparkle reads the pair (see
    /// its `allowsAutomaticUpdates`).
    public static func automaticBehavior(
        checkEnabled: Bool, downloadEnabled: Bool
    ) -> AutomaticUpdateBehavior {
        AutomaticUpdateBehavior(
            checksForUpdates: checkEnabled, downloadsAndInstalls: checkEnabled && downloadEnabled)
    }
}
