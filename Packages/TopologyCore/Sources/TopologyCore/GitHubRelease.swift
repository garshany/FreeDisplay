import Foundation

/// Metadata only: downloading/installing code always stays in the browser and Finder.
public struct GitHubRelease: Decodable, Hashable, Sendable {
    public let tagName: String
    public let htmlURL: URL
    public let draft: Bool
    public let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", htmlURL = "html_url", draft, prerelease
    }

    public static let latestURL = URL(string: "https://api.github.com/repos/garshany/FreeDisplay/releases/latest")!

    /// Validate the API's link before handing it to the browser. A response cannot redirect the
    /// update button to another publisher, a download asset, or a non-HTTPS URL.
    public static func parse(statusCode: Int, data: Data, cachedData: Data? = nil) throws -> GitHubRelease {
        let body: Data
        switch statusCode {
        case 200: body = data
        case 304:
            guard let cachedData else { throw ResponseError.noCachedRelease }
            body = cachedData
        default: throw ResponseError.http(statusCode)
        }
        let release = try JSONDecoder().decode(Self.self, from: body)
        guard !release.draft, !release.prerelease,
              let version = SemanticVersion(release.tagName), version.prerelease.isEmpty,
              let url = URLComponents(url: release.htmlURL, resolvingAgainstBaseURL: false),
              url.scheme == "https", url.host == "github.com", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.percentEncodedPath == "/garshany/FreeDisplay/releases/tag/\(release.tagName)" else {
            throw ResponseError.invalidRelease
        }
        return release
    }

    public func event(runningVersion: String) -> SoftwareUpdateEvent {
        switch SoftwareUpdatePolicy.relation(ofAdvertised: tagName, toRunning: runningVersion) {
        case .newer(let version): return .updateFound(version: version, build: nil)
        case .same, .older: return .noUpdateFound
        case nil: return .failed(.unknownResult)
        }
    }

    /// The existing update states, with a browser action rather than Sparkle's installer offer.
    public static func presentation(status: SoftwareUpdateStatus, isLocalBuild: Bool) -> SoftwareUpdatePresentation {
        if case .available(let version) = status.phase {
            return SoftwareUpdatePresentation(title: "A new version is available → Download",
                systemImage: "arrow.down.circle.fill", badge: version, tone: .attention, action: .showOffer)
        }
        if isLocalBuild, status.phase == .idle {
            return SoftwareUpdatePresentation(title: "Check GitHub for a newer release", systemImage: "arrow.down.circle")
        }
        return status.presentation
    }

    public enum ResponseError: Error, Equatable {
        case http(Int)
        case noCachedRelease
        case invalidRelease
    }
}
