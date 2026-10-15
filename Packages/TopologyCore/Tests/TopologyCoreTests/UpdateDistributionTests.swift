import XCTest
@testable import TopologyCore

/// SO-15 / FD-027: the updater runs only for a validated FreeDisplay release carrying the fork's own
/// feed and key — never for a source build, and never against upstream OpenDisplay.
final class UpdateDistributionTests: XCTestCase {
    private typealias Distribution = UpdateDistribution

    /// A syntactically valid Ed25519 public key (32 zero-free bytes), not a real signing key.
    private let forkKey = Data((1...32).map { UInt8($0) }).base64EncodedString()
    private let forkFeed = "https://updates.example.org/freedisplay/appcast.xml"

    func testAValidatedForkReleaseMayUpdate() {
        XCTAssertNil(Distribution.refusal(isLocalBuild: false, feedURL: forkFeed, publicEDKey: forkKey))
    }

    /// The local-build guard is checked first and wins whatever else is configured.
    func testALocalBuildNeverUpdates() {
        XCTAssertEqual(Distribution.refusal(isLocalBuild: true, feedURL: forkFeed, publicEDKey: forkKey), .localBuild)
        XCTAssertEqual(Distribution.refusal(isLocalBuild: true, feedURL: nil, publicEDKey: nil), .localBuild)
    }

    func testAMissingFeedOrKeyKeepsTheUpdaterOff() {
        XCTAssertEqual(Distribution.refusal(isLocalBuild: false, feedURL: nil, publicEDKey: forkKey), .noFeed)
        XCTAssertEqual(Distribution.refusal(isLocalBuild: false, feedURL: "  ", publicEDKey: forkKey), .noFeed)
        XCTAssertEqual(Distribution.refusal(isLocalBuild: false, feedURL: forkFeed, publicEDKey: ""), .noPublicKey)
    }

    /// An unexpanded build setting (empty) or a plain-http feed is refused.
    func testAnInsecureOrMalformedFeedIsRefused() {
        XCTAssertEqual(Distribution.refusal(isLocalBuild: false, feedURL: "http://updates.example.org/appcast.xml",
                                            publicEDKey: forkKey), .insecureOrInvalidFeed)
        XCTAssertEqual(Distribution.refusal(isLocalBuild: false, feedURL: "appcast.xml", publicEDKey: forkKey),
                       .insecureOrInvalidFeed)
    }

    func testTheUpstreamFeedIsRefusedHoweverItIsSpelled() {
        for feed in [
            "https://github.com/aquitaine/OpenDisplay/releases/latest/download/appcast.xml",
            "https://GitHub.com/Aquitaine/opendisplay/releases/download/v1/appcast.xml",
            "https://raw.githubusercontent.com/aquitaine/OpenDisplay/main/appcast.xml",
            "https://aquitaine.github.io/OpenDisplay/appcast.xml",
            "https://api.github.com/repos/aquitaine/OpenDisplay/releases/latest",
        ] {
            XCTAssertEqual(Distribution.refusal(isLocalBuild: false, feedURL: feed, publicEDKey: forkKey),
                           .upstreamFeed, feed)
        }
    }

    func testAForkHostedOnGitHubIsNotUpstream() {
        XCTAssertNil(Distribution.refusal(
            isLocalBuild: false,
            feedURL: "https://github.com/garshany/FreeDisplay/releases/latest/download/appcast.xml",
            publicEDKey: forkKey))
        XCTAssertNil(Distribution.refusal(
            isLocalBuild: false, feedURL: "https://github.com/aquitaine-fan/OpenDisplay2/appcast.xml",
            publicEDKey: forkKey))
    }

    /// Trusting upstream's key would let an upstream-signed build replace the fork.
    func testUpstreamsKeyIsRefused() {
        XCTAssertEqual(Distribution.refusal(isLocalBuild: false, feedURL: forkFeed,
                                            publicEDKey: Distribution.upstreamPublicEDKey), .upstreamPublicKey)
    }

    func testAMalformedKeyIsRefused() {
        XCTAssertEqual(Distribution.refusal(isLocalBuild: false, feedURL: forkFeed, publicEDKey: "not base64!"),
                       .invalidPublicKey)
        let short = Data(repeating: 7, count: 16).base64EncodedString()
        XCTAssertEqual(Distribution.refusal(isLocalBuild: false, feedURL: forkFeed, publicEDKey: short),
                       .invalidPublicKey)
    }
}

/// SO-40 / FA-17: one definition of the fork's identity, links and copied build report.
final class ProjectIdentityTests: XCTestCase {
    func testLinksPointAtTheForkAndCreditUpstream() {
        let byKind = Dictionary(uniqueKeysWithValues: ProjectIdentity.links.map { ($0.kind, $0.url.absoluteString) })
        XCTAssertEqual(byKind[.source], "https://github.com/garshany/FreeDisplay")
        XCTAssertEqual(byKind[.releases], "https://github.com/garshany/FreeDisplay/releases")
        XCTAssertEqual(byKind[.issues], "https://github.com/garshany/FreeDisplay/issues")
        XCTAssertEqual(byKind[.license], "https://github.com/garshany/FreeDisplay/blob/main/LICENSE")
        XCTAssertEqual(byKind[.privacy], "https://github.com/garshany/FreeDisplay/blob/main/PRIVACY.md")
        XCTAssertEqual(byKind[.upstream], "https://github.com/aquitaine/OpenDisplay")
        XCTAssertEqual(ProjectIdentity.links.map(\.kind), ProjectIdentity.Link.Kind.allCases)
        XCTAssertEqual(ProjectIdentity.links.last?.kind, .upstream, "the fork's own links come first")
    }

    func testAttributionNamesTheForkUpstreamAndLicense() {
        let line = ProjectIdentity.attribution
        XCTAssertTrue(line.contains("FreeDisplay"))
        XCTAssertTrue(line.contains("OpenDisplay by aquitaine"))
        XCTAssertTrue(line.contains("GPL-3.0"))
    }

    private func report(local: Bool, builtAt: Date? = Date(timeIntervalSince1970: 0)) -> BuildReport {
        BuildReport(version: "0.11.5", build: "24", configuration: .release, apiSurface: .full,
                    isLocalBuild: local, bundleIdentifier: "dev.opendisplay.app",
                    operatingSystem: "Version 15.0 (Build 24A335)", architecture: "arm64", builtAt: builtAt)
    }

    func testChannelFollowsTheLocalBuildFlag() {
        XCTAssertEqual(report(local: true).channel, .sourceBuild)
        XCTAssertEqual(report(local: false).channel, .release)
    }

    func testReportIsFixedFormatEnglish() {
        XCTAssertEqual(report(local: true).reportText, """
        FreeDisplay 0.11.5 (build 24)
        Channel: source build
        Build: Release · full
        Built: 1970-01-01T00:00:00Z
        macOS: Version 15.0 (Build 24A335)
        Architecture: arm64
        Bundle: dev.opendisplay.app (OpenDisplay.app)
        Source: https://github.com/garshany/FreeDisplay
        Based on: OpenDisplay by aquitaine, GPL-3.0
        """)
    }

    func testReportOmitsAnUnknownBuildDate() {
        XCTAssertFalse(report(local: false, builtAt: nil).reportText.contains("Built:"))
        XCTAssertEqual(report(local: false).versionLine, "0.11.5 (24)")
    }
}
