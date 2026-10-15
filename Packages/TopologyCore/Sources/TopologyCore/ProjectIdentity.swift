import Foundation

/// Who this app is, defined once (SO-40/FA-17): the fork's name and links, the upstream project it
/// is built on and credits, and the license. Both About surfaces, the copied build report and the
/// docs state the same facts from here.
///
/// The built product is FreeDisplay.app. Internal executable, CLI, URL scheme and storage
/// identities keep their compatibility names so existing scripts and preferences keep working.
public enum ProjectIdentity {
    public static let productName = "FreeDisplay"
    /// The built app bundle name, for presentation in build reports.
    public static let bundleName = "FreeDisplay"
    public static let upstreamName = "OpenDisplay"
    public static let upstreamAuthor = "aquitaine"
    /// The license the fork is distributed under, inherited from upstream.
    public static let license = "GPL-3.0"

    public static let sourceRepository = URL(string: "https://github.com/garshany/FreeDisplay")!
    public static let upstreamRepository = URL(string: "https://github.com/aquitaine/OpenDisplay")!

    /// One project link. Titles are worded by the app, per `Kind`, so they are translated.
    public struct Link: Hashable, Sendable, Identifiable {
        public enum Kind: String, Hashable, Sendable, CaseIterable {
            /// FreeDisplay's source code.
            case source
            /// FreeDisplay's releases, with notes and checksums.
            case releases
            /// Reporting a FreeDisplay problem.
            case issues
            /// The GPL-3.0 text the fork is distributed under.
            case license
            /// What data FreeDisplay handles, and where it goes.
            case privacy
            /// The upstream OpenDisplay project, credited.
            case upstream
        }

        public let kind: Kind
        public let url: URL
        public let systemImage: String
        public var id: Kind { kind }
    }

    /// The links both About surfaces show, in order: the fork's own first, upstream credited last.
    public static let links: [Link] = [
        Link(kind: .source, url: sourceRepository, systemImage: "chevron.left.forwardslash.chevron.right"),
        Link(kind: .releases, url: sourceRepository.appendingPathComponent("releases"), systemImage: "shippingbox"),
        Link(kind: .issues, url: sourceRepository.appendingPathComponent("issues"), systemImage: "ladybug"),
        Link(kind: .license, url: sourceRepository.appendingPathComponent("blob/main/LICENSE"), systemImage: "checkmark.seal"),
        Link(kind: .privacy, url: sourceRepository.appendingPathComponent("blob/main/PRIVACY.md"), systemImage: "hand.raised"),
        Link(kind: .upstream, url: upstreamRepository, systemImage: "arrow.triangle.branch"),
    ]

    public static func link(_ kind: Link.Kind) -> Link {
        links.first { $0.kind == kind }!
    }

    /// The attribution line, in English: what the copied report and the docs carry.
    public static var attribution: String {
        "\(productName) is a fork of \(upstreamName) by \(upstreamAuthor) (\(upstreamRepository.absoluteString)), distributed under \(license)."
    }
}

/// The running build's identity, as the About surfaces show it and the Copy button puts it on the
/// pasteboard. The app collects the facts from its bundle; the wording and the channel live here.
public struct BuildReport: Hashable, Sendable {
    public enum Configuration: String, Hashable, Sendable { case debug = "Debug", release = "Release" }
    public enum APISurface: String, Hashable, Sendable { case full = "full", publicOnly = "public-API-only" }

    /// How this build is kept up to date — what "channel" means for the fork today.
    public enum Channel: String, Hashable, Sendable {
        /// Built from source (`OpenDisplayLocalBuild`): updated by pulling and rebuilding; the
        /// in-app updater is off.
        case sourceBuild = "source build"
        /// A published FreeDisplay release, updated through its signed feed.
        case release = "release"
    }

    public var version: String
    public var build: String
    public var configuration: Configuration
    public var apiSurface: APISurface
    public var channel: Channel
    public var bundleIdentifier: String
    public var operatingSystem: String
    public var architecture: String
    /// When the executable was written — the closest thing to a build stamp the bundle carries.
    public var builtAt: Date?

    public init(version: String, build: String, configuration: Configuration, apiSurface: APISurface,
                isLocalBuild: Bool, bundleIdentifier: String, operatingSystem: String,
                architecture: String, builtAt: Date?) {
        self.version = version
        self.build = build
        self.configuration = configuration
        self.apiSurface = apiSurface
        self.channel = isLocalBuild ? .sourceBuild : .release
        self.bundleIdentifier = bundleIdentifier
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.builtAt = builtAt
    }

    /// "0.11.5 (24)".
    public var versionLine: String { "\(version) (\(build))" }

    /// The text the Copy button puts on the pasteboard. English and fixed-format on purpose: it is
    /// meant for bug reports, which are read by people who may not share the interface language.
    public var reportText: String {
        var lines = [
            "\(ProjectIdentity.productName) \(version) (build \(build))",
            "Channel: \(channel.rawValue)",
            "Build: \(configuration.rawValue) · \(apiSurface.rawValue)",
        ]
        if let builtAt {
            lines.append("Built: \(ISO8601DateFormatter().string(from: builtAt))")
        }
        lines += [
            "macOS: \(operatingSystem)",
            "Architecture: \(architecture)",
            "Bundle: \(bundleIdentifier) (\(ProjectIdentity.bundleName).app)",
            "Source: \(ProjectIdentity.sourceRepository.absoluteString)",
            "Based on: \(ProjectIdentity.upstreamName) by \(ProjectIdentity.upstreamAuthor), \(ProjectIdentity.license)",
        ]
        return lines.joined(separator: "\n")
    }
}
