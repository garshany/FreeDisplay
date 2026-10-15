#if os(macOS)
import AppKit
import OpenDisplayDesignSystem
import SwiftUI
import TopologyCore

/// Custom About window, replacing `orderFrontStandardAboutPanel`. The standard panel only shows
/// the icon + version; this one adds what people actually come for — the running version, build
/// and channel (selectable for bug reports), the update state, and links to the project. Its
/// identity, links and build facts come from `ProjectIdentity` and `BuildMetadata`, the same
/// sources Settings › About reads, so the two surfaces can't disagree (SO-40). Accessibility:
/// semantic fonts (respect the user's text-size setting), real `Link` controls (focusable,
/// VoiceOver-labelled), and the decorative icon hidden from assistive tech.
struct AboutView: View {
    @EnvironmentObject private var model: AppModel

    /// A single project link shown both in this window and in Settings → About, so the two surfaces
    /// can never drift apart on titles, icons, or destinations.
    struct AboutLink: Identifiable {
        let title: String
        let systemImage: String
        let url: URL
        var id: String { url.absoluteString }
    }

    /// The project links AboutView offers, reused verbatim by the Settings → About card: the fork's
    /// source, releases, issues, license and privacy notes, then the upstream project it credits.
    static var projectLinks: [AboutLink] {
        ProjectIdentity.links.map { AboutLink(title: title(for: $0.kind), systemImage: $0.systemImage, url: $0.url) }
    }

    private static func title(for kind: ProjectIdentity.Link.Kind) -> String {
        switch kind {
        case .source: return String(localized: "FreeDisplay source code")
        case .releases: return String(localized: "Releases and checksums")
        case .issues: return String(localized: "Report a problem")
        case .license: return String(localized: "License (GPL-3.0)")
        case .privacy: return String(localized: "Privacy")
        case .upstream: return String(localized: "Upstream project: OpenDisplay by aquitaine")
        }
    }

    /// The running build's marketing version ("0.5.1"), reused by the Settings → About card.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
    /// The running build number, reused by the Settings → About card.
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    var body: some View {
        VStack(spacing: ODSpacing.sm) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text(verbatim: ProjectIdentity.productName)
                .font(.title2.weight(.semibold))
            ForkAttributionText()
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VersionLine()
                .font(.callout.monospacedDigit())
                .padding(.top, 2)
            UpdateCheckStatusView()

            // SO-40: build, channel, macOS and architecture, selectable and copyable for a bug report.
            BuildMetadataView()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ODSpacing.lg)
                .padding(.top, ODSpacing.xs)

            Divider().padding(.vertical, ODSpacing.xs)

            VStack(alignment: .leading, spacing: ODSpacing.sm) {
                ForEach(Self.projectLinks) { link in
                    aboutLink(link)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ODSpacing.lg)

            CopyrightText()
                .font(.footnote).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, ODSpacing.xs)
        }
        .padding(.vertical, ODSpacing.xl)
        .padding(.horizontal, ODSpacing.xl)
        .frame(width: 320)
    }

    private func aboutLink(_ link: AboutLink) -> some View {
        Link(destination: link.url) {
            Label {
                Text(link.title).font(.callout)
            } icon: {
                Image(systemName: link.systemImage).frame(width: 18)
            }
        }
        .foregroundStyle(ODColor.accent)
        .accessibilityHint("Opens in your browser")
    }
}

/// "A fork of OpenDisplay by aquitaine" — the upstream credit both About surfaces carry.
struct ForkAttributionText: View {
    var body: some View {
        Text("Free, open-source display control for macOS. FreeDisplay.app is a fork of OpenDisplay by aquitaine.")
    }
}

/// The copyright and license line, crediting both projects.
struct CopyrightText: View {
    var body: some View {
        Text("© 2026 FreeDisplay contributors. Based on OpenDisplay © its contributors. Distributed under the GNU GPL v3.")
    }
}

/// "Version 0.11.5 (build 24) · source build", selectable — one line for both About surfaces.
struct VersionLine: View {
    private let metadata = BuildMetadata.current

    var body: some View {
        Text("Version \(AboutView.version) (build \(AboutView.build)) · \(metadata.channelTitle)")
            .textSelection(.enabled)
            .accessibilityLabel("Version \(AboutView.version), build \(AboutView.build), \(metadata.channelTitle)")
    }
}

/// The update affordance shared by the About window and Settings › About, reading the same
/// `SoftwareUpdateStatus` presentation the menu rows do: all of them say the same thing about the
/// same state, colour it the same way and do the same thing when clicked — check or retry, cancel
/// what is in flight, or bring the waiting offer forward (never a duplicate check). A build whose
/// updater is off says why instead of offering a check that can't happen.
struct UpdateCheckStatusView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if let refusal = model.updateDistributionRefusal {
                Label(refusal == .localBuild ? String(localized: "Local build · updates from source")
                                             : String(localized: "Updates aren’t set up in this build"),
                      systemImage: refusal == .localBuild ? "hammer" : "nosign")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(SoftwareUpdater.refusalExplanation(refusal))
            } else {
                statusControl(model.updateStatus.presentation)
            }
        }
        // AM-20/SO-14: a result that went stale clears when the surface is shown again.
        .onAppear { model.updateSurfaceAppeared() }
    }

    @ViewBuilder
    private func statusControl(_ presentation: SoftwareUpdatePresentation) -> some View {
        let title = Self.localizedTitle(presentation)
        VStack(spacing: 4) {
            Button {
                model.performUpdateAction(presentation.action)
            } label: {
                HStack(spacing: 6) {
                    if presentation.showsProgress {
                        if let fraction = presentation.fraction {
                            ProgressView(value: fraction).frame(width: 60)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    } else {
                        Image(systemName: presentation.systemImage).foregroundStyle(Self.tint(presentation.tone))
                    }
                    Text(title)
                    if presentation.action == .cancel {
                        Text("Cancel").foregroundStyle(ODColor.accent)
                    }
                }
            }
            .buttonStyle(.borderless)
            .disabled(!presentation.isActionable)
            .accessibilityHint(Self.hint(for: presentation.action))
            if let detail = Self.detail(for: model.updateStatus) {
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
    }

    /// `SoftwareUpdatePolicy` returns English source text, so the title is looked up in the string
    /// catalog here; the version badge is appended as-is, the way `combinedTitle` folds it in.
    static func localizedTitle(_ presentation: SoftwareUpdatePresentation) -> String {
        let title = presentation.title.appLocalized
        guard let badge = presentation.badge else { return title }
        return "\(title): \(badge)"
    }

    static func tint(_ tone: SoftwareUpdatePresentation.Tone) -> Color {
        switch tone {
        case .neutral: return .secondary
        case .success: return ODColor.connected
        case .attention: return ODColor.caution
        case .problem: return ODColor.danger
        }
    }

    private static func hint(for action: SoftwareUpdatePresentation.Action) -> String {
        switch action {
        case .check: return String(localized: "Checks for a new version")
        case .cancel: return String(localized: "Cancels the check or download in progress")
        case .showOffer: return String(localized: "Shows the waiting update")
        case .none: return ""
        }
    }

    /// The second line some states need: which macOS a newer version wants, that the release notes
    /// failed to load (the update itself is fine), or what a cancelled install means.
    static func detail(for status: SoftwareUpdateStatus) -> String? {
        switch status.phase {
        case .incompatible(.systemTooOld(let minimum?)):
            return String(localized: "It needs macOS \(minimum) or later.")
        case .incompatible(.systemTooNew(let maximum?)):
            return String(localized: "It supports macOS up to \(maximum).")
        case .failed(.authorizationCancelled):
            return String(localized: "Nothing was changed. Your update settings stay as they are.")
        case .failed(.network):
            return String(localized: "Check the connection and try again. This doesn’t mean the app is up to date.")
        case .readyToInstall(_, true):
            return String(localized: "It installs as FreeDisplay quits, after its usual cleanup.")
        case .available where status.releaseNotesFailed:
            return String(localized: "The release notes couldn’t be loaded. The update itself isn’t affected.")
        default:
            return nil
        }
    }
}
#endif
