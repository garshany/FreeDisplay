import XCTest
@testable import TopologyCore

final class GitHubReleaseTests: XCTestCase {
    // Inline API fixtures: deterministic, no network or bundle dependencies.
    private func fixture(tag: String = "v1.2.0", url: String? = nil,
                         draft: Bool = false, prerelease: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "html_url": url ?? "https://github.com/garshany/FreeDisplay/releases/tag/\(tag)",
            "draft": draft, "prerelease": prerelease, "name": "A human-readable release name",
        ])
    }

    func testReleaseVersionComesFromTagAndOpensOwnedPage() throws {
        let release = try GitHubRelease.parse(statusCode: 200, data: fixture())
        XCTAssertEqual(release.tagName, "v1.2.0")
        XCTAssertEqual(release.htmlURL.absoluteString, "https://github.com/garshany/FreeDisplay/releases/tag/v1.2.0")
        XCTAssertEqual(release.event(runningVersion: "1.1.99"), .updateFound(version: "1.2.0", build: nil))
        XCTAssertEqual(release.event(runningVersion: "1.2.0"), .noUpdateFound)
        XCTAssertEqual(release.event(runningVersion: "2.0.0"), .noUpdateFound)
        XCTAssertEqual(release.event(runningVersion: "dev"), .failed(.unknownResult))
    }

    func testConditionalResponseReusesCachedBody() throws {
        let cached = try fixture()
        XCTAssertEqual(try GitHubRelease.parse(statusCode: 304, data: Data(), cachedData: cached),
                       try GitHubRelease.parse(statusCode: 200, data: cached))
        XCTAssertThrowsError(try GitHubRelease.parse(statusCode: 304, data: Data()))
    }

    func testHTTPErrorsNeverClaimUpToDateOrReuseStaleOffer() throws {
        for code in [403, 404, 429, 500] {
            XCTAssertThrowsError(try GitHubRelease.parse(statusCode: code, data: Data(), cachedData: fixture())) {
                XCTAssertEqual($0 as? GitHubRelease.ResponseError, .http(code))
            }
        }
    }

    func testMalformedMissingAndPrereleaseMetadataIsRejected() throws {
        for body in [Data("{}".utf8), Data("not JSON".utf8), try fixture(tag: "latest"),
                     try fixture(tag: "v1.2.0-rc.1"), try fixture(draft: true), try fixture(prerelease: true)] {
            XCTAssertThrowsError(try GitHubRelease.parse(statusCode: 200, data: body))
        }
    }

    func testOnlyExactOwnedReleasePageIsAccepted() throws {
        for url in ["http://github.com/garshany/FreeDisplay/releases/tag/v1.2.0",
                    "https://github.com/aquitaine/OpenDisplay/releases/tag/v1.2.0",
                    "https://github.com.evil.test/garshany/FreeDisplay/releases/tag/v1.2.0",
                    "https://github.com/garshany/FreeDisplay/releases/download/v1.2.0/FreeDisplay.zip",
                    "https://user@github.com/garshany/FreeDisplay/releases/tag/v1.2.0",
                    "https://github.com/garshany/FreeDisplay/releases/tag/v1.2.0?x=1",
                    "https://github.com/garshany/FreeDisplay/releases/tag/v9.0.0"] {
            XCTAssertThrowsError(try GitHubRelease.parse(statusCode: 200, data: fixture(url: url)), url)
        }
    }

    func testNoKeySelectsGitHubAndLocalBuildCannotInstallEvenWithKey() {
        XCTAssertTrue(UpdateDistribution.checksGitHubReleases(isLocalBuild: false, publicEDKey: nil))
        XCTAssertTrue(UpdateDistribution.checksGitHubReleases(isLocalBuild: false, publicEDKey: " \n"))
        XCTAssertTrue(UpdateDistribution.checksGitHubReleases(isLocalBuild: true, publicEDKey: "configured"))
        XCTAssertFalse(UpdateDistribution.checksGitHubReleases(isLocalBuild: false, publicEDKey: "invalid-nonempty"))
    }

    func testGitHubPresentationOffersBrowserDownloadAndRetainsOtherStates() {
        var status = SoftwareUpdateStatus()
        XCTAssertEqual(GitHubRelease.presentation(status: status, isLocalBuild: true).title,
                       "Check GitHub for a newer release")
        status.record(.checkStarted, at: Date())
        XCTAssertEqual(GitHubRelease.presentation(status: status, isLocalBuild: false), status.presentation)
        status.record(.updateFound(version: "1.2.0", build: nil), at: Date())
        let offer = GitHubRelease.presentation(status: status, isLocalBuild: false)
        XCTAssertEqual(offer.action, .showOffer)
        XCTAssertEqual(offer.title, "A new version is available → Download")
        XCTAssertEqual(offer.badge, "1.2.0")
    }
}
