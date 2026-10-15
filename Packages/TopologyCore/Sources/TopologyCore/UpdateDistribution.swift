import Foundation

// FreeDisplay's own update distribution (SO-15): whether this build may run its updater at all,
// and how the updater's errors read. Pure, so the gate and the classification are unit-tested; the
// Sparkle shell in the app only collects the facts.

/// Whether this build's updater may run. It may only when the build is a release build of the fork
/// AND it carries a FreeDisplay feed AND the fork's own EdDSA public key. Anything else — a source
/// build, a missing or upstream feed, a missing, malformed or upstream key — keeps the updater off,
/// so a fork build can never fetch or install an upstream OpenDisplay release in place of itself.
public enum UpdateDistribution {
    /// Why the updater stays off.
    public enum Refusal: Hashable, Sendable {
        /// `OpenDisplayLocalBuild` is set: this build is updated from source. Kept until a FreeDisplay
        /// release has been validated end to end (see scripts/sparkle-setup.md).
        case localBuild
        /// No update feed is configured (`SUFeedURL` is empty).
        case noFeed
        /// The feed isn't an https URL.
        case insecureOrInvalidFeed
        /// The feed is upstream OpenDisplay's: installing from it would replace this fork.
        case upstreamFeed
        /// No EdDSA public key is configured (`SUPublicEDKey` is empty).
        case noPublicKey
        /// The key isn't a base64-encoded 32-byte Ed25519 public key.
        case invalidPublicKey
        /// The key is upstream OpenDisplay's: it would trust upstream-signed builds.
        case upstreamPublicKey
    }

    /// Upstream OpenDisplay's published EdDSA public key — never a key this fork may trust.
    public static let upstreamPublicEDKey = "G9aQchK8B0eqrXhKwKWat4SRCR/XboPdgpmfuHrBnuE="

    /// Why the updater must stay off, or nil when it may run. Checked in order: the local-build
    /// guard first, so a source build reports exactly that whatever else is configured.
    public static func refusal(isLocalBuild: Bool, feedURL: String?, publicEDKey: String?) -> Refusal? {
        if isLocalBuild { return .localBuild }
        let feed = (feedURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !feed.isEmpty else { return .noFeed }
        guard let components = URLComponents(string: feed), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty else { return .insecureOrInvalidFeed }
        if isUpstream(host: host.lowercased(), path: components.path.lowercased()) { return .upstreamFeed }
        let key = (publicEDKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .noPublicKey }
        if key == upstreamPublicEDKey { return .upstreamPublicKey }
        guard let data = Data(base64Encoded: key), data.count == 32 else { return .invalidPublicKey }
        return nil
    }

    /// Upstream's repository and its GitHub Pages site, however the URL spells them.
    static func isUpstream(host: String, path: String) -> Bool {
        if host == "aquitaine.github.io" { return true }
        let trimmed = path.split(separator: "/", omittingEmptySubsequences: true)
        guard trimmed.count >= 2 else { return false }
        let owner = trimmed[0], repository = trimmed[1].replacingOccurrences(of: ".git", with: "")
        let githubHosts: Set<String> = ["github.com", "www.github.com", "raw.githubusercontent.com",
                                        "objects.githubusercontent.com", "api.github.com"]
        if host == "api.github.com", trimmed.count >= 3, trimmed[0] == "repos" {
            return trimmed[1] == "aquitaine" && trimmed[2] == "opendisplay"
        }
        return githubHosts.contains(host) && owner == "aquitaine" && repository == "opendisplay"
    }
}

/// Reads the updater's errors (Sparkle's `NSError`s, as plain domain/code facts) as outcomes.
public enum SoftwareUpdateErrorClassifier {
    /// Sparkle's error domain (`SUSparkleErrorDomain`).
    public static let sparkleDomain = "SUSparkleErrorDomain"
    /// The domain of errors FreeDisplay's own update checks raise (the downgrade guard).
    public static let appDomain = "FreeDisplayUpdateErrorDomain"
    public static let downgradeRefusedCode = 1

    /// One error in a chain: its domain and code.
    public struct ErrorCode: Hashable, Sendable {
        public var domain: String
        public var code: Int
        public init(domain: String, code: Int) {
            self.domain = domain
            self.code = code
        }
    }

    public enum Outcome: Hashable, Sendable {
        /// Not a failure: the feed simply had nothing to install (Sparkle's `SUNoUpdateError`).
        case noUpdate
        /// Only the release notes failed; the update itself is unaffected.
        case releaseNotes
        case failure(SoftwareUpdateFailure)
    }

    /// Classifies an error and the errors underneath it (`NSUnderlyingErrorKey`, outermost first).
    public static func classify(_ error: ErrorCode, underlying: [ErrorCode] = []) -> Outcome {
        let isNetwork = ([error] + underlying).contains(where: isNetworkError)
        if error.domain == appDomain, error.code == downgradeRefusedCode { return .failure(.downgradeRefused) }
        guard error.domain == sparkleDomain else {
            return isNetwork ? .failure(.network) : .failure(.other(code: error.code))
        }
        switch error.code {
        case 1001: return .noUpdate                               // SUNoUpdateError
        case 1006, 1007: return .releaseNotes                     // web view ended, release notes
        case 1, 2, 3, 4, 5, 6, 7, 5000: return .failure(.misconfigured)
        case 1000, 1002, 1004: return .failure(isNetwork ? .network : .feedUnreadable)
        case 1003, 1005: return .failure(.cannotUpdateInPlace)    // disk image, translocated
        case 2000: return .failure(.downloadFailed)               // temporary directory
        case 2001: return .failure(isNetwork ? .network : .downloadFailed)
        case 3000: return .failure(.extractionFailed)
        case 3001, 3002: return .failure(.signatureRejected)      // signature, validation
        case 4001: return .failure(.authorizationFailed)
        case 4004: return .failure(.relaunchFailed)
        case 4006: return .failure(.downgradeRefused)
        case 4007: return .failure(.authorizationCancelled)
        case 4008: return .failure(.authorizationDeferred)
        case 4000, 4002, 4003, 4005, 4009, 4010, 4012: return .failure(.installationFailed)
        default: return .failure(.other(code: error.code))
        }
    }

    /// Sparkle's `SPUNoUpdateFoundReason` raw value as a reason; `minimum`/`maximum` are the
    /// newest feed item's OS bounds, when Sparkle passed it along.
    public static func noUpdateReason(rawValue: Int?, minimum: String?, maximum: String?) -> SoftwareUpdateNoUpdateReason {
        switch rawValue {
        case 1: return .onLatestVersion
        case 2: return .onNewerThanLatestVersion
        case 3: return .systemTooOld(minimum: minimum)
        case 4: return .systemTooNew(maximum: maximum)
        case 5: return .hardwareUnsupported
        default: return .unknown
        }
    }

    private static func isNetworkError(_ error: ErrorCode) -> Bool {
        error.domain == "NSURLErrorDomain" || error.domain == "kCFErrorDomainCFNetwork"
    }
}
