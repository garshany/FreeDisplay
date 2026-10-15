#if os(macOS)
import AppKit
import Sparkle
import TopologyCore

/// The owner's release channel checks GitHub metadata and opens the release page in the browser.
/// Sparkle is instantiated only if a future build supplies a validated key and feed; source builds
/// always remain metadata-only. The platform-independent policies live in TopologyCore.
@MainActor
final class SoftwareUpdater: NSObject {
    /// Called on the main actor whenever the status changes. `AppModel` mirrors it into a published
    /// property; nothing in this file knows about SwiftUI.
    var onStatusChange: ((SoftwareUpdateStatus) -> Void)?

    /// Called when the user changes the automatic-download preference from inside Sparkle's own
    /// update window ("Automatically download and install updates in the future"), so that choice is
    /// written to the app's settings file rather than quietly reverting at the next launch.
    var onAutomaticDownloadPreferenceChange: ((Bool) -> Void)?

    /// What the UI should currently say about updates.
    private(set) var status = SoftwareUpdateStatus() {
        didSet {
            guard status != oldValue else { return }
            onStatusChange?(status)
        }
    }

    /// Why Sparkle stays off. Source builds retain this explanation alongside GitHub checks.
    let distributionRefusal: UpdateDistribution.Refusal?
    let checksGitHubReleases: Bool
    private var githubCheck: Task<Void, Never>?
    private var githubRelease: GitHubRelease?
    private var automaticGitHubChecks = false

    var presentation: SoftwareUpdatePresentation {
        checksGitHubReleases ? GitHubRelease.presentation(status: status, isLocalBuild: Self.isLocalBuild)
                             : status.presentation
    }

    /// Sparkle's updater and the user driver that wraps its standard windows. Nil whenever
    /// the GitHub metadata channel is active, or distribution validation refuses Sparkle.
    private var updater: SPUUpdater?
    private var userDriver: ObservingUserDriver?

    /// Watches Sparkle's automatic-download flag so its in-window checkbox reaches the settings file.
    private var automaticDownloadObservation: NSKeyValueObservation?

    /// Starts the updater with the user's preferences already applied, so Sparkle's first scheduled
    /// cycle (which begins on the next runloop pass) sees the settings the user actually chose.
    init(behavior: AutomaticUpdateBehavior) {
        let info = Bundle.main.infoDictionary ?? [:]
        checksGitHubReleases = UpdateDistribution.checksGitHubReleases(
            isLocalBuild: Self.isLocalBuild, publicEDKey: info["SUPublicEDKey"] as? String)
        let refusal = UpdateDistribution.refusal(
            isLocalBuild: Self.isLocalBuild,
            feedURL: info["SUFeedURL"] as? String,
            publicEDKey: info["SUPublicEDKey"] as? String)
        distributionRefusal = checksGitHubReleases && !Self.isLocalBuild ? nil : refusal
        super.init()
        if checksGitHubReleases {
            apply(behavior)
            return
        }
        guard distributionRefusal == nil else { return }
        let standard = SPUStandardUserDriver(hostBundle: .main, delegate: self)
        let driver = ObservingUserDriver(standard: standard) { [weak self] report in
            self?.receive(report)
        }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        userDriver = driver
        self.updater = updater
        apply(behavior)
        observeAutomaticDownloadPreference()
        do {
            try updater.start()
        } catch {
            // A start failure is a configuration problem in this build; say so where the update row
            // is rather than in a modal alert at launch.
            record(.failed(.misconfigured))
            self.updater = nil
        }
    }

    /// Whether this is a source build (`OpenDisplayLocalBuild`), which updates from source only.
    static var isLocalBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "OpenDisplayLocalBuild") as? Bool != false
    }

    /// Pushes the user's two update settings into Sparkle.
    ///
    /// Sparkle persists both flags in the app's user defaults and advises against keeping a second
    /// copy. The app keeps one anyway — `settings.json` is the single place every other toggle in the
    /// app lives, and a user who copies that file to a new Mac expects their update preference to
    /// come with it. The duplication is one-way: this app's settings are authoritative and are written
    /// into Sparkle at launch and on every change, so Sparkle's defaults are a mirror rather than a
    /// second source of truth. The single path back is the checkbox in Sparkle's own update window —
    /// see `observeAutomaticDownloadPreference`. Sparkle re-schedules its cycle after either flag
    /// changes, so no explicit reset is needed here.
    func apply(_ behavior: AutomaticUpdateBehavior) {
        if checksGitHubReleases {
            let becameEnabled = behavior.checksForUpdates && !automaticGitHubChecks
            automaticGitHubChecks = behavior.checksForUpdates
            // There is no interval in the app's settings. Check at launch/enable, without inventing
            // another scheduler or carrying Sparkle's automatic-install preference into this channel.
            if becameEnabled { checkGitHubRelease() }
            return
        }
        guard let updater else { return }
        updater.automaticallyChecksForUpdates = behavior.checksForUpdates
        updater.automaticallyDownloadsUpdates = behavior.downloadsAndInstalls
    }

    /// Does what the update affordance's presentation says a click does.
    func perform(_ action: SoftwareUpdatePresentation.Action) {
        switch action {
        case .check: checkForUpdates()
        case .showOffer:
            if checksGitHubReleases, let githubRelease {
                NSWorkspace.shared.open(githubRelease.htmlURL)
            } else {
                checkForUpdates()
            }
        case .cancel: userDriver?.cancelInFlight()
        case .none: break
        }
    }

    /// The user asked about updates — from the menu, the About window, or Settings. Sparkle takes it
    /// from here: the progress, the release notes, the download, and the relaunch prompt are all its
    /// windows. Asking again while an update is already on screen brings that window forward instead
    /// of starting a second check.
    ///
    /// The guard matters. In the one state where Sparkle won't accept a check — a background download
    /// of its own is mid-flight — it drops the request silently, and a phase moved to `checking` would
    /// sit on a spinner no callback ever clears.
    func checkForUpdates() {
        if checksGitHubReleases {
            checkGitHubRelease()
            return
        }
        guard let updater else {
            showWhyUpdatesAreOff()
            return
        }
        guard updater.canCheckForUpdates else { return }
        NotificationCenter.default.post(name: .openDisplayDismissMenu, object: nil)
        activateForUpdaterWindow()
        if !status.phase.isSessionInProgress { record(.checkStarted) }
        updater.checkForUpdates()
    }

    /// Clears a check result that went stale, when a surface shows it again (`staleAfter` nil: never).
    func clearStaleResult(staleAfter: TimeInterval?) {
        var updated = status
        updated.clearIfStale(now: Date(), staleAfter: staleAfter)
        if !checksGitHubReleases {
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            updated.dropOffer(ifNotNewerThanBuild: build) {
                SUStandardVersionComparator.default.compareVersion($0, toVersion: $1)
            }
        }
        status = updated
    }

    private func checkGitHubRelease() {
        guard githubCheck == nil else { return }
        record(.checkStarted)
        githubCheck = Task { [weak self] in
            guard let self else { return }
            defer { githubCheck = nil }
            // URLSession/URLCache own HTTP freshness and disk persistence, with no custom quota or
            // TTL. Revalidation respects GitHub's ETag even on an explicit user check.
            var request = URLRequest(url: GitHubRelease.latestURL, cachePolicy: .reloadRevalidatingCacheData)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("FreeDisplay", forHTTPHeaderField: "User-Agent")
            let cached = URLCache.shared.cachedResponse(for: request)
            if let response = cached?.response as? HTTPURLResponse,
               let etag = response.value(forHTTPHeaderField: "ETag") {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    record(.failed(.feedUnreadable))
                    return
                }
                let release = try GitHubRelease.parse(statusCode: http.statusCode, data: data, cachedData: cached?.data)
                githubRelease = release
                record(release.event(runningVersion: runningVersion))
            } catch is DecodingError {
                record(.failed(.feedUnreadable))
            } catch let error as GitHubRelease.ResponseError {
                switch error {
                case .http: record(.failed(.network))
                case .noCachedRelease, .invalidRelease: record(.failed(.feedUnreadable))
                }
            } catch {
                record(.failed(.network))
            }
        }
    }

    /// A source build, or a build without a FreeDisplay feed and key: explain instead of checking.
    private func showWhyUpdatesAreOff() {
        let alert = NSAlert()
        if distributionRefusal == .localBuild {
            alert.messageText = String(localized: "Local Open-Source Build")
            alert.informativeText = String(localized: "Update this build from the project’s sources. Installing the upstream release automatically is turned off so your changes are kept.")
        } else {
            alert.messageText = String(localized: "Updates aren’t available in this build")
            alert.informativeText = Self.refusalExplanation(distributionRefusal)
        }
        alert.runModal()
    }

    /// Why updates are off, in words — shared with the About surfaces.
    static func refusalExplanation(_ refusal: UpdateDistribution.Refusal?) -> String {
        switch refusal {
        case .none:
            return ""
        case .localBuild:
            return String(localized: "This is a local build. You can check GitHub for a newer release and download it in your browser. Replace the app manually to update.")
        case .noFeed, .insecureOrInvalidFeed:
            return String(localized: "This build has no FreeDisplay update feed, so it never checks for updates.")
        case .upstreamFeed:
            return String(localized: "This build points at the upstream OpenDisplay feed. FreeDisplay never installs upstream releases, so updates are turned off.")
        case .noPublicKey, .invalidPublicKey:
            return String(localized: "This build has no valid update signing key, so it can’t verify an update and never checks for one.")
        case .upstreamPublicKey:
            return String(localized: "This build carries the upstream OpenDisplay signing key. FreeDisplay never trusts upstream-signed updates, so updates are turned off.")
        }
    }

    /// Mirrors Sparkle's automatic-download flag back into the app's settings, which is what makes the
    /// checkbox in Sparkle's update window stick.
    ///
    /// Changes are only mirrored while automatic checks are on. `apply` derives the flag as
    /// "download AND check", so turning automatic checks off writes a `false` here that says nothing
    /// about what the user wants downloaded — mirroring that one back would erase their preference
    /// the moment they paused update checks.
    private func observeAutomaticDownloadPreference() {
        automaticDownloadObservation = updater?.observe(
            \.automaticallyDownloadsUpdates, options: [.new]
        ) { [weak self] _, change in
            guard let downloadsAutomatically = change.newValue else { return }
            Task { @MainActor [weak self] in
                guard let self, self.updater?.automaticallyChecksForUpdates == true else { return }
                self.onAutomaticDownloadPreferenceChange?(downloadsAutomatically)
            }
        }
    }

    /// The running build's marketing version ("0.9.0"), the left-hand side of the downgrade guard.
    private var runningVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private func record(_ event: SoftwareUpdateEvent) {
        var updated = status
        updated.record(event, at: Date())
        updated.canCancel = userDriver?.canCancel ?? false
        status = updated
    }

    /// What the user driver saw.
    private func receive(_ report: ObservingUserDriver.Report) {
        switch report {
        case .event(let event):
            record(event)
        case .error(let error):
            record(error: error)
        case .releaseNotesFailed:
            var updated = status
            updated.recordReleaseNotesFailure()
            status = updated
        case .cancellationChanged:
            var updated = status
            updated.canCancel = userDriver?.canCancel ?? false
            status = updated
        }
    }

    /// Records what an updater error stands for (`SoftwareUpdateErrorClassifier`). `noUpdate`:
    /// whether a "no update" error is recorded here — false where `updaterDidNotFindUpdate` has
    /// already reported it with its reason.
    private func record(error: Error, includingNoUpdate noUpdate: Bool = true) {
        let nsError = error as NSError
        var underlying: [SoftwareUpdateErrorClassifier.ErrorCode] = []
        var next = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        var visited = Set<ObjectIdentifier>([ObjectIdentifier(nsError)])
        while let current = next, visited.insert(ObjectIdentifier(current)).inserted {
            underlying.append(.init(domain: current.domain, code: current.code))
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        switch SoftwareUpdateErrorClassifier.classify(.init(domain: nsError.domain, code: nsError.code),
                                                      underlying: underlying) {
        case .noUpdate:
            if noUpdate { record(Self.noUpdateEvent(for: nsError)) }
        case .releaseNotes:
            // Only the notes failed; the update itself is unaffected.
            var updated = status
            updated.recordReleaseNotesFailure()
            status = updated
        case .failure(let failure):
            record(.failed(failure))
        }
    }

    /// "No update" with Sparkle's reason and, for an OS mismatch, the newest item's OS bounds.
    private static func noUpdateEvent(for error: NSError) -> SoftwareUpdateEvent {
        let reason = (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
        let latest = error.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem
        return .noUpdate(SoftwareUpdateErrorClassifier.noUpdateReason(
            rawValue: reason, minimum: latest?.minimumSystemVersion, maximum: latest?.maximumSystemVersion))
    }

    /// Brings the app forward so a window Sparkle is about to show lands in front. A menu-bar
    /// (`LSUIElement`) app has no Dock icon to bounce and isn't activated for it automatically.
    fileprivate func activateForUpdaterWindow() {
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Why the downgrade guard turned an update away. Sparkle surfaces `errorDescription` verbatim, so it
/// is written for the person reading the alert rather than for a log. Its domain and code are the
/// ones `SoftwareUpdateErrorClassifier` reads as `.downgradeRefused`.
private struct DowngradeRefused: LocalizedError, CustomNSError {
    let advertised: String
    let running: String

    static var errorDomain: String { SoftwareUpdateErrorClassifier.appDomain }
    var errorCode: Int { SoftwareUpdateErrorClassifier.downgradeRefusedCode }

    var errorDescription: String? {
        String(localized: "The update feed offers FreeDisplay \(advertised), which is older than the \(running) you are running. Nothing was installed.")
    }
}

// MARK: - Updater delegate (what Sparkle found, and what it may do)

extension SoftwareUpdater: SPUUpdaterDelegate {
    /// The app owns this preference in its own Settings, so Sparkle's second-launch permission prompt
    /// would be a duplicate question with a different answer store.
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }

    /// The downgrade guard. Sparkle selects its update by build number, so a feed that lists releases
    /// out of order can offer a genuinely older app; `SoftwareUpdatePolicy` refuses that and defers to
    /// Sparkle whenever the two versions can't be compared.
    func updater(
        _ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
        updateCheck: SPUUpdateCheck
    ) throws {
        let advertised = updateItem.displayVersionString
        guard SoftwareUpdatePolicy.mayInstall(advertised: advertised, running: runningVersion) else {
            throw DowngradeRefused(advertised: advertised, running: runningVersion)
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        record(.updateFound(version: item.displayVersionString, build: item.versionString))
    }

    /// Carries Sparkle's reason, so "up to date" and "needs a newer macOS" read differently. This
    /// arrives for scheduled checks too, which show no window of their own.
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        record(Self.noUpdateEvent(for: error as NSError))
    }

    /// "Skip This Version" means don't remind me — so the badge goes away with it. A plain dismissal
    /// ("Remind Me Later") deliberately leaves the badge up.
    func updater(
        _ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState
    ) {
        switch choice {
        case .skip: record(.updateSkipped)
        case .dismiss: record(.offerDismissed)
        default: break
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        record(.installationStarted)
    }

    /// An automatic download prepared an update that installs when the app quits. Sparkle keeps
    /// ownership of that install (returning false lets its scheduler carry on); the app only says
    /// so, and its own quit cleanup runs first as on every quit.
    func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        record(.installOnQuitScheduled(version: item.displayVersionString))
        return false
    }

    /// Errors of scheduled checks reach only this delegate (the user driver isn't told), so the
    /// row can still say the check failed rather than staying silent.
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        record(error: error)
    }

    /// Fires at the end of every cycle, with or without an error — the one hook that reliably clears a
    /// check which produced no verdict.
    func updater(
        _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?
    ) {
        // "No update" was already reported with its reason by `updaterDidNotFindUpdate`.
        if let error { record(error: error, includingNoUpdate: false) }
        record(.checkFinished)
    }
}

// MARK: - Standard user driver delegate (when Sparkle's own windows appear)

/// Sparkle calls this protocol from its standard user driver, which is itself main-actor-bound, so
/// every callback arrives on the main thread; the `assumeIsolated` hops below are assertions of that
/// fact rather than thread hops. The protocol isn't annotated for Swift concurrency, which is why the
/// conformances have to be declared `nonisolated`.
extension SoftwareUpdater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Let Sparkle show a scheduled update only when it already proposes to do so in immediate focus
    /// (just after launch, or an idle machine). Otherwise the menu badge is the whole reminder, and
    /// the window waits for the user to click it.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        MainActor.assumeIsolated { activateForUpdaterWindow() }
    }

    /// A modal alert would otherwise open behind the menu-bar pop-out, which sits above ordinary
    /// windows; closing the pop-out first also matches what every other window-opening action does.
    nonisolated func standardUserDriverWillShowModalAlert() {
        MainActor.assumeIsolated {
            NotificationCenter.default.post(name: .openDisplayDismissMenu, object: nil)
            activateForUpdaterWindow()
        }
    }
}

// MARK: - Observing user driver

/// Sparkle's standard windows, observed. Every `SPUUserDriver` call is forwarded unchanged to
/// `SPUStandardUserDriver` — which keeps owning every window, button and reply — and reported to
/// the updater shell first, so the app's own rows can follow the session. The cancellation blocks
/// Sparkle hands over (a check the user started, a download) are kept so the app's rows can cancel
/// too; each is wrapped so it runs at most once, whichever control is used.
@MainActor
private final class ObservingUserDriver: NSObject, SPUUserDriver {
    enum Report {
        case event(SoftwareUpdateEvent)
        case error(Error)
        case releaseNotesFailed
        case cancellationChanged
    }

    /// A cancellation Sparkle handed over: the block, the event it means, and a token that tells
    /// this cancellation apart from a later one.
    private struct Cancellation {
        let token: UUID
        let block: () -> Void
        let event: SoftwareUpdateEvent
    }

    private let standard: SPUStandardUserDriver
    private let report: @MainActor (Report) -> Void
    private var cancellation: Cancellation?
    private var inlineCheck = false

    init(standard: SPUStandardUserDriver, report: @escaping @MainActor (Report) -> Void) {
        self.standard = standard
        self.report = report
    }

    var canCancel: Bool { cancellation != nil }

    /// Cancels the check or download in flight, from the app's own controls.
    func cancelInFlight() {
        guard let token = cancellation?.token else { return }
        fireCancellation(token)
    }

    /// Keeps `block` as the way to cancel, and returns the wrapper Sparkle's own window calls. The
    /// app's rows and that window share it, and it runs at most once, whichever is used first.
    private func holdCancellation(_ block: @escaping () -> Void, reporting event: SoftwareUpdateEvent) -> () -> Void {
        let token = UUID()
        cancellation = Cancellation(token: token, block: block, event: event)
        report(.cancellationChanged)
        return { @Sendable [weak self] in
            MainActor.assumeIsolated { self?.fireCancellation(token) }
        }
    }

    private func fireCancellation(_ token: UUID) {
        guard let held = cancellation, held.token == token else { return }
        cancellation = nil
        report(.cancellationChanged)
        report(.event(held.event))
        held.block()
    }

    /// Sparkle moved past the point where the held cancellation applies.
    private func dropCancellation() {
        guard cancellation != nil else { return }
        cancellation = nil
        report(.cancellationChanged)
    }

    func show(_ request: SPUUpdatePermissionRequest,
                                     reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        standard.show(request, reply: reply)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        inlineCheck = true
        report(.event(.checkStarted))
        _ = holdCancellation(cancellation, reporting: .checkCancelled)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        inlineCheck = false
        dropCancellation()
        report(.event(.updateFound(version: appcastItem.displayVersionString, build: appcastItem.versionString)))
        if state.stage == .installing {
            report(.event(.installOnQuitScheduled(version: appcastItem.displayVersionString)))
        }
        standard.showUpdateFound(with: appcastItem, state: state, reply: reply)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        standard.showUpdateReleaseNotes(with: downloadData)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        report(.releaseNotesFailed)
        standard.showUpdateReleaseNotesFailedToDownloadWithError(error)
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        dropCancellation()
        report(.error(error))
        if inlineCheck {
            inlineCheck = false
            acknowledgement()
        } else {
            standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
        }
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        dropCancellation()
        report(.error(error))
        if inlineCheck {
            inlineCheck = false
            acknowledgement()
        } else {
            standard.showUpdaterError(error, acknowledgement: acknowledgement)
        }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        report(.event(.downloadStarted))
        standard.showDownloadInitiated(cancellation: holdCancellation(cancellation, reporting: .downloadCancelled))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        report(.event(.downloadExpectedLength(expectedContentLength)))
        standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        report(.event(.downloadReceived(length)))
        standard.showDownloadDidReceiveData(ofLength: length)
    }

    /// From here on Sparkle no longer accepts a cancel.
    func showDownloadDidStartExtractingUpdate() {
        dropCancellation()
        report(.event(.extractionStarted))
        standard.showDownloadDidStartExtractingUpdate()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        standard.showExtractionReceivedProgress(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        report(.event(.readyToInstall))
        standard.showReady(toInstallAndRelaunch: reply)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        report(.event(.installationStarted))
        standard.showInstallingUpdate(withApplicationTerminated: applicationTerminated,
                                      retryTerminatingApplication: retryTerminatingApplication)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        report(.event(.installationCompleted(relaunched: relaunched)))
        standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }

    func showUpdateInFocus() {
        standard.showUpdateInFocus()
    }

    func dismissUpdateInstallation() {
        inlineCheck = false
        dropCancellation()
        standard.dismissUpdateInstallation()
    }
}
#endif
