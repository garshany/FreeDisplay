import XCTest
@testable import TopologyCore

/// AM-20 / SO-14: the complete update lifecycle — failures, compatibility, cancellation, prepared
/// and install-on-quit states, stale results — kept distinguishable on every surface.
final class SoftwareUpdateLifecycleTests: XCTestCase {
    private typealias Policy = SoftwareUpdatePolicy

    private func run(_ events: [SoftwareUpdateEvent], from start: SoftwareUpdatePhase = .idle) -> SoftwareUpdatePhase {
        events.reduce(start) { Policy.phase(after: $1, from: $0) }
    }

    // MARK: - Verdicts never blur

    /// The acceptance line: a network failure never appears "up to date".
    func testANetworkFailureIsNotUpToDate() {
        let phase = run([.checkStarted, .failed(.network), .checkFinished])
        XCTAssertEqual(phase, .failed(.network))
        XCTAssertNotEqual(Policy.presentation(for: phase).title, Policy.presentation(for: .upToDate).title)
        XCTAssertEqual(Policy.presentation(for: phase).tone, .problem)
    }

    func testUpToDateIsGreenAndRetries() {
        let presentation = Policy.presentation(for: run([.checkStarted, .noUpdate(.onLatestVersion)]))
        XCTAssertEqual(presentation.tone, .success)
        XCTAssertEqual(presentation.action, .check)
    }

    func testRunningANewerBuildThanTheFeedIsUpToDate() {
        XCTAssertEqual(run([.checkStarted, .noUpdate(.onNewerThanLatestVersion)]), .upToDate)
    }

    func testAnUnexplainedNoUpdateDoesNotClaimTheAppIsCurrent() {
        let phase = run([.checkStarted, .noUpdate(.unknown)])
        XCTAssertEqual(phase, .failed(.unknownResult))
        XCTAssertEqual(Policy.presentation(for: phase).tone, .problem)
    }

    func testInstallationCompletionIsDistinctFromPreparationAndReplacement() {
        for relaunched in [true, false] {
            let phase = run([.installationStarted, .installationCompleted(relaunched: relaunched), .checkFinished])
            XCTAssertEqual(phase, .installed(relaunched: relaunched))
            XCTAssertEqual(Policy.presentation(for: phase).tone, .success)
            XCTAssertEqual(Policy.presentation(for: phase).action, .none)
        }
        XCTAssertNotEqual(Policy.presentation(for: .installed(relaunched: true)).title,
                          Policy.presentation(for: .installed(relaunched: false)).title)
    }

    func testOSTooOldIsIncompatibleNotUpToDate() {
        let phase = run([.checkStarted, .noUpdate(.systemTooOld(minimum: "15.0"))])
        XCTAssertEqual(phase, .incompatible(.systemTooOld(minimum: "15.0")))
        XCTAssertEqual(Policy.presentation(for: phase).title, "A newer version needs a newer macOS")
    }

    func testOSTooNewAndHardwareAreDistinct() {
        XCTAssertEqual(run([.checkStarted, .noUpdate(.systemTooNew(maximum: "14.9"))]),
                       .incompatible(.systemTooNew(maximum: "14.9")))
        XCTAssertEqual(run([.checkStarted, .noUpdate(.hardwareUnsupported)]), .incompatible(.hardwareUnsupported))
        XCTAssertNotEqual(Policy.presentation(for: .incompatible(.systemTooNew(maximum: nil))).title,
                          Policy.presentation(for: .incompatible(.systemTooOld(minimum: nil))).title)
    }

    func testEveryFailureHasItsOwnWording() {
        let failures: [SoftwareUpdateFailure] = [
            .network, .feedUnreadable, .signatureRejected, .downloadFailed, .extractionFailed,
            .authorizationCancelled, .authorizationDeferred, .authorizationFailed, .installationFailed,
            .relaunchFailed, .downgradeRefused, .cannotUpdateInPlace, .misconfigured,
        ]
        let titles = Set(failures.map(Policy.failureTitle))
        XCTAssertEqual(titles.count, failures.count)
        XCTAssertFalse(titles.contains("Up to date"))
    }

    /// Cancelling the administrator prompt is the user's choice, not an error shown in red.
    func testCancelledAuthorizationIsNeutral() {
        XCTAssertEqual(Policy.presentation(for: .failed(.authorizationCancelled)).tone, .neutral)
        XCTAssertEqual(Policy.presentation(for: .failed(.signatureRejected)).tone, .problem)
    }

    // MARK: - Offers persist until resolved

    /// A later background check that can't reach the server doesn't retract a found update.
    func testACheckFailureDoesNotRetractAFoundUpdate() {
        let phase = run([.checkStarted, .updateFound(version: "1.1.0"), .checkFinished,
                         .checkStarted, .failed(.network), .checkFinished])
        XCTAssertEqual(phase, .available(version: "1.1.0"))
    }

    func testDismissingTheOfferKeepsIt() {
        XCTAssertEqual(run([.updateFound(version: "1.1.0"), .offerDismissed, .checkFinished]),
                       .available(version: "1.1.0"))
    }

    /// Clicking an available row opens the existing offer — never a duplicate check, never "installed".
    func testAnAvailableRowShowsTheOffer() {
        let presentation = Policy.presentation(for: .available(version: "1.1.0"))
        XCTAssertEqual(presentation.action, .showOffer)
        XCTAssertEqual(presentation.tone, .attention)
        XCTAssertFalse(presentation.showsProgress)
    }

    func testSkippingClearsTheOffer() {
        XCTAssertEqual(run([.updateFound(version: "1.1.0"), .updateSkipped]), .idle)
    }

    // MARK: - Cancellation

    func testCancellingACheckClearsTheInlineState() {
        XCTAssertEqual(run([.checkStarted, .checkCancelled]), .idle)
    }

    func testCheckingIsCancellableOnlyWhenTheShellCanCancel() {
        XCTAssertEqual(Policy.presentation(for: .checking, canCancel: true).action, .cancel)
        XCTAssertEqual(Policy.presentation(for: .checking, canCancel: false).action, .none)
        XCTAssertFalse(Policy.presentation(for: .checking).isActionable)
    }

    func testCancellingADownloadLeavesTheOffer() {
        let phase = run([.updateFound(version: "1.1.0"), .downloadStarted, .downloadReceived(10), .downloadCancelled])
        XCTAssertEqual(phase, .available(version: "1.1.0"))
    }

    /// After a cancel the abandoned session may still report an error or end; neither may replace
    /// the cleared state the user asked for.
    func testAnErrorAfterTheUserCancelledIsIgnored() {
        var status = SoftwareUpdateStatus()
        let t = Date(timeIntervalSince1970: 0)
        status.record(.checkStarted, at: t)
        status.record(.checkCancelled, at: t)
        status.record(.failed(.other(code: 4007)), at: t)
        status.record(.checkFinished, at: t)
        XCTAssertEqual(status.phase, .idle)
        // …and the next check works normally again.
        status.record(.checkStarted, at: t)
        status.record(.failed(.network), at: t)
        XCTAssertEqual(status.phase, .failed(.network))
    }

    // MARK: - Download, preparation, installation

    func testDownloadProgressCountsBytes() {
        let phase = run([.updateFound(version: "1.1.0"), .downloadStarted, .downloadExpectedLength(200),
                         .downloadReceived(50), .downloadReceived(50)])
        XCTAssertEqual(phase, .downloading(version: "1.1.0", receivedBytes: 100, expectedBytes: 200))
        XCTAssertEqual(Policy.presentation(for: phase).fraction, 0.5)
    }

    func testDownloadWithoutAKnownSizeHasNoFraction() {
        let phase = run([.updateFound(version: "1.1.0"), .downloadStarted, .downloadReceived(7)])
        XCTAssertNil(Policy.presentation(for: phase).fraction)
        XCTAssertTrue(Policy.presentation(for: phase).showsProgress)
    }

    func testByteCountsSaturateInsteadOfTrapping() {
        let phase = run([.downloadReceived(.max)],
                        from: .downloading(version: nil, receivedBytes: 10, expectedBytes: nil))
        XCTAssertEqual(phase, .downloading(version: nil, receivedBytes: .max, expectedBytes: nil))
    }

    func testAnOverlongDownloadNeverShowsMoreThanFull() {
        let phase = run([.downloadReceived(500)], from: .downloading(version: nil, receivedBytes: 0, expectedBytes: 100))
        XCTAssertEqual(Policy.presentation(for: phase).fraction, 1)
    }

    func testExtractionCannotBeCancelled() {
        let phase = run([.updateFound(version: "1.1.0"), .downloadStarted, .extractionStarted])
        XCTAssertEqual(phase, .extracting(version: "1.1.0"))
        XCTAssertNotEqual(Policy.presentation(for: phase, canCancel: true).action, .cancel)
    }

    func testPreparedUpdateWaitsForRelaunch() {
        let phase = run([.updateFound(version: "1.1.0"), .downloadStarted, .extractionStarted, .readyToInstall])
        XCTAssertEqual(phase, .readyToInstall(version: "1.1.0", installsOnQuit: false))
        XCTAssertEqual(Policy.presentation(for: phase).action, .showOffer)
    }

    func testInstallOnQuitIsItsOwnState() {
        let onQuit = run([.installOnQuitScheduled(version: "1.1.0"), .checkFinished])
        XCTAssertEqual(onQuit, .readyToInstall(version: "1.1.0", installsOnQuit: true))
        XCTAssertNotEqual(Policy.presentation(for: onQuit).title,
                          Policy.presentation(for: .readyToInstall(version: "1.1.0", installsOnQuit: false)).title)
    }

    func testAnOpenSessionSurvivesANewCheck() {
        for phase: SoftwareUpdatePhase in [.downloading(version: "1", receivedBytes: 0, expectedBytes: nil),
                                           .extracting(version: "1"),
                                           .readyToInstall(version: "1", installsOnQuit: true), .installing] {
            XCTAssertEqual(Policy.phase(after: .checkStarted, from: phase), phase)
        }
    }

    func testASessionThatEndsMidDownloadFallsBackToTheOffer() {
        XCTAssertEqual(run([.checkFinished], from: .downloading(version: "1.1.0", receivedBytes: 1, expectedBytes: nil)),
                       .available(version: "1.1.0"))
    }

    func testASignatureFailureDuringDownloadIsReported() {
        XCTAssertEqual(run([.updateFound(version: "1.1.0"), .downloadStarted, .extractionStarted,
                            .failed(.signatureRejected), .checkFinished]),
                       .failed(.signatureRejected))
    }

    func testInstallingCannotBeInterrupted() {
        XCTAssertEqual(Policy.presentation(for: .installing).action, .none)
    }

    // MARK: - Stale results clear only on re-entry, and only when configured

    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testAResultIsStampedWhenItArrives() {
        var status = SoftwareUpdateStatus()
        status.record(.checkStarted, at: t0)
        XCTAssertNil(status.resultAt)
        status.record(.noUpdateFound, at: t0.addingTimeInterval(2))
        XCTAssertEqual(status.resultAt, t0.addingTimeInterval(2))
    }

    func testStaleResultClearsOnlyAfterTheThreshold() {
        var status = SoftwareUpdateStatus()
        status.record(.noUpdateFound, at: t0)
        XCTAssertFalse(status.clearIfStale(now: t0.addingTimeInterval(10), staleAfter: 10))
        XCTAssertEqual(status.phase, .upToDate)
        XCTAssertTrue(status.clearIfStale(now: t0.addingTimeInterval(10.5), staleAfter: 10))
        XCTAssertEqual(status.phase, .idle)
        XCTAssertNil(status.resultAt)
    }

    /// No threshold configured (the default): a result stays until the next check.
    func testWithoutAThresholdNothingGoesStale() {
        var status = SoftwareUpdateStatus()
        status.record(.failed(.network), at: t0)
        XCTAssertFalse(status.clearIfStale(now: t0.addingTimeInterval(1_000_000), staleAfter: nil))
        XCTAssertEqual(status.phase, .failed(.network))
    }

    func testAnAvailableUpdateNeverGoesStale() {
        var status = SoftwareUpdateStatus()
        status.record(.updateFound(version: "1.1.0"), at: t0)
        XCTAssertFalse(status.clearIfStale(now: t0.addingTimeInterval(1_000), staleAfter: 10))
        XCTAssertEqual(status.phase, .available(version: "1.1.0"))
    }

    func testIncompatibleAndFailedResultsCanGoStale() {
        for event: SoftwareUpdateEvent in [.noUpdate(.systemTooOld(minimum: nil)), .failed(.feedUnreadable)] {
            var status = SoftwareUpdateStatus()
            status.record(event, at: t0)
            XCTAssertTrue(status.clearIfStale(now: t0.addingTimeInterval(11), staleAfter: 10), "\(event)")
        }
    }

    func testAnOfferNoLongerNewerIsDroppedByBuildNumber() {
        var status = SoftwareUpdateStatus()
        status.record(.updateFound(version: "1.1.0", build: "24"), at: t0)
        let compare: (String, String) -> ComparisonResult = { $0.compare($1, options: .numeric) }
        XCTAssertFalse(status.dropOffer(ifNotNewerThanBuild: "23", compare: compare))
        XCTAssertTrue(status.dropOffer(ifNotNewerThanBuild: "24", compare: compare))
        XCTAssertEqual(status.phase, .idle)
    }

    func testMarketingVersionCannotRetractANewerRebuild() {
        var status = SoftwareUpdateStatus()
        status.record(.updateFound(version: "1.1.0", build: "25"), at: t0)
        XCTAssertFalse(status.dropOffer(ifNotNewerThanBuild: "24") { $0.compare($1, options: .numeric) })
        XCTAssertEqual(status.phase, .available(version: "1.1.0"))
    }

    func testWithoutBuildMetadataOfferIsKept() {
        var status = SoftwareUpdateStatus()
        status.record(.updateFound(version: "1.1.0"), at: t0)
        XCTAssertFalse(status.dropOffer(ifNotNewerThanBuild: "24") { _, _ in .orderedSame })
    }

    func testReleaseNotesFailureIsIndependentOfTheOffer() {
        var status = SoftwareUpdateStatus()
        status.record(.updateFound(version: "1.1.0"), at: t0)
        status.recordReleaseNotesFailure()
        XCTAssertTrue(status.releaseNotesFailed)
        XCTAssertEqual(status.phase, .available(version: "1.1.0"))
        status.record(.updateFound(version: "1.2.0"), at: t0)
        XCTAssertFalse(status.releaseNotesFailed)
    }

    func testStatusPresentationUsesItsCancelCapability() {
        var status = SoftwareUpdateStatus()
        status.record(.checkStarted, at: t0)
        status.canCancel = true
        XCTAssertEqual(status.presentation.action, .cancel)
    }

    // MARK: - Error classification

    private typealias Classifier = SoftwareUpdateErrorClassifier
    private func sparkle(_ code: Int) -> Classifier.ErrorCode { .init(domain: Classifier.sparkleDomain, code: code) }

    func testNoUpdateErrorIsNotAFailure() {
        XCTAssertEqual(Classifier.classify(sparkle(1001)), .noUpdate)
    }

    func testAppcastErrorOverTheNetworkIsANetworkFailure() {
        XCTAssertEqual(Classifier.classify(sparkle(1002), underlying: [.init(domain: "NSURLErrorDomain", code: -1009)]),
                       .failure(.network))
        XCTAssertEqual(Classifier.classify(sparkle(1002)), .failure(.feedUnreadable))
        XCTAssertEqual(Classifier.classify(sparkle(1000)), .failure(.feedUnreadable))
    }

    func testDownloadErrors() {
        XCTAssertEqual(Classifier.classify(sparkle(2001), underlying: [.init(domain: "NSURLErrorDomain", code: -1001)]),
                       .failure(.network))
        XCTAssertEqual(Classifier.classify(sparkle(2001)), .failure(.downloadFailed))
    }

    func testSignatureAndAuthorizationErrors() {
        XCTAssertEqual(Classifier.classify(sparkle(3001)), .failure(.signatureRejected))
        XCTAssertEqual(Classifier.classify(sparkle(3002)), .failure(.signatureRejected))
        XCTAssertEqual(Classifier.classify(sparkle(4007)), .failure(.authorizationCancelled))
        XCTAssertEqual(Classifier.classify(sparkle(4008)), .failure(.authorizationDeferred))
        XCTAssertEqual(Classifier.classify(sparkle(4001)), .failure(.authorizationFailed))
    }

    func testInstallAndRelaunchErrors() {
        XCTAssertEqual(Classifier.classify(sparkle(4005)), .failure(.installationFailed))
        XCTAssertEqual(Classifier.classify(sparkle(4012)), .failure(.installationFailed))
        XCTAssertEqual(Classifier.classify(sparkle(4004)), .failure(.relaunchFailed))
        XCTAssertEqual(Classifier.classify(sparkle(4006)), .failure(.downgradeRefused))
        XCTAssertEqual(Classifier.classify(sparkle(1003)), .failure(.cannotUpdateInPlace))
    }

    func testConfigurationErrorsAreMisconfiguration() {
        for code in [1, 2, 3, 4, 5, 6, 7, 5000] {
            XCTAssertEqual(Classifier.classify(sparkle(code)), .failure(.misconfigured), "\(code)")
        }
    }

    func testReleaseNotesErrorIsSeparate() {
        XCTAssertEqual(Classifier.classify(sparkle(1007)), .releaseNotes)
    }

    func testTheDowngradeGuardsOwnError() {
        XCTAssertEqual(Classifier.classify(.init(domain: Classifier.appDomain, code: Classifier.downgradeRefusedCode)),
                       .failure(.downgradeRefused))
    }

    func testForeignErrors() {
        XCTAssertEqual(Classifier.classify(.init(domain: "NSURLErrorDomain", code: -1009)), .failure(.network))
        XCTAssertEqual(Classifier.classify(.init(domain: "NSCocoaErrorDomain", code: 4)), .failure(.other(code: 4)))
        XCTAssertEqual(Classifier.classify(sparkle(9999)), .failure(.other(code: 9999)))
    }

    func testNoUpdateReasons() {
        XCTAssertEqual(Classifier.noUpdateReason(rawValue: 1, minimum: nil, maximum: nil), .onLatestVersion)
        XCTAssertEqual(Classifier.noUpdateReason(rawValue: 2, minimum: nil, maximum: nil), .onNewerThanLatestVersion)
        XCTAssertEqual(Classifier.noUpdateReason(rawValue: 3, minimum: "15.0", maximum: nil), .systemTooOld(minimum: "15.0"))
        XCTAssertEqual(Classifier.noUpdateReason(rawValue: 4, minimum: nil, maximum: "14.9"), .systemTooNew(maximum: "14.9"))
        XCTAssertEqual(Classifier.noUpdateReason(rawValue: 5, minimum: nil, maximum: nil), .hardwareUnsupported)
        XCTAssertEqual(Classifier.noUpdateReason(rawValue: 0, minimum: nil, maximum: nil), .unknown)
        XCTAssertEqual(Classifier.noUpdateReason(rawValue: nil, minimum: nil, maximum: nil), .unknown)
    }
}
