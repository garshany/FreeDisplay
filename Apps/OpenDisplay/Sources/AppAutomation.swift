// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import AppKit
import AutomationSchema
import DisplayDomain
import Foundation
import TopologyCore

/// Runs a typed automation request against the running app (FD-066/FD-067). The URL scheme, the
/// local HTTP control and the App Intents all come through here, so target resolution, units,
/// route choice and the verdict on what happened are the shared `AutomationEngine`'s — the surfaces
/// only translate their input into an `AutomationRequest` and the `AutomationResult` into their
/// output.
@MainActor
enum AppAutomation {
    static func run(_ request: AutomationRequest, from surface: AutomationSurface,
                    model: AppModel) async -> AutomationResult {
        AppDiagnostics.shared.record("command=\(request.command.name.rawValue) surface=\(surface.rawValue) started")
        let result = await AutomationEngine(environment: AppAutomationEnvironment(model: model, surface: surface)).run(request)
        AppDiagnostics.shared.record("command=\(request.command.name.rawValue) outcome=\(result.status.rawValue)")
        return result
    }
}

/// The app's primitives for the shared engine: thin calls into `AppModel`'s own funnels — the
/// brightness routes with their coalescing and group sync, the mode change behind the
/// keep-or-revert gate, the ColorSync assignment with its re-read, the ledger-based Reconnect All —
/// so an automated change behaves exactly like the same change made in the menu.
@MainActor
final class AppAutomationEnvironment: AutomationEnvironment {
    nonisolated let surface: AutomationSurface
    private let model: AppModel
    private let beforeClockWrite: (@MainActor () -> AutomationIssue?)?

    init(model: AppModel, surface: AutomationSurface,
         beforeClockWrite: (@MainActor () -> AutomationIssue?)? = nil) {
        self.model = model
        self.surface = surface
        self.beforeClockWrite = beforeClockWrite
    }

    nonisolated func unavailability(of command: AutomationCommandName) -> AutomationIssue? {
        switch command {
        case .getContrast, .setContrast:
            #if PUBLIC_API_ONLY
            return AutomationIssue(.methodUnavailable, "hardware contrast is unavailable in this build")
            #else
            return nil
            #endif
        case .setColorProfile, .resetColorProfile:
            guard FeatureFlags.iccProfileWrite else {
                return AutomationIssue(.capabilityUnavailable, "colour profile changes are turned off in this build",
                                       subject: command.rawValue)
            }
            return nil
        default:
            return nil
        }
    }

    func prepare() async throws(AutomationIssue) {
        await model.prepareForAutomation()
        model.integrationSession.start(model: model)
    }

    func displaySet() async -> AutomationDisplaySet {
        model.automationDisplaySet(pointerDisplayID: Self.pointerDisplayID())
    }

    func feedIntegration(control: UUID, response: String, display: AutomationDisplayCandidate) async throws(AutomationIssue) -> IntegrationSample {
        do { return try model.integrationSession.feed(controlID: control, response: response, displayID: display.id) }
        catch { throw AutomationIssue(.invalidValue, (error as? IntegrationError)?.message ?? error.localizedDescription, subject: control.uuidString) }
    }

    // MARK: Brightness

    func tvCanPerform(_ action: TVAction, on display: AutomationDisplayCandidate) async -> Bool {
        !model.safeStartup && TVControlStore.shared.canPerform(action, display: display.id)
    }

    func tvCapabilities(for display: AutomationDisplayCandidate) async -> TVCapabilityReport? {
        guard !model.safeStartup else { return nil }
        return TVControlStore.shared.capabilities(display: display.id)
    }

    func tvControl(_ action: TVAction, on display: AutomationDisplayCandidate) async throws(AutomationIssue) -> TVCommandReceipt {
        guard !model.safeStartup else { throw AutomationIssue(.capabilityUnavailable, "TV control is disabled during safe startup") }
        return try await TVControlStore.shared.perform(action, display: display.id)
    }

    func brightnessRoutes(for display: AutomationDisplayCandidate) async -> BrightnessRouteAvailability {
        if model.brightnessMethod[display.id] == nil, let observation = observation(display) {
            await model.refreshBrightness(for: observation)
        }
        return model.automationBrightnessRoutes(for: display.id)
    }

    func readBrightness(of display: AutomationDisplayCandidate,
                        via route: BrightnessRoute) async throws(AutomationIssue) -> BrightnessReadback {
        let observation = try active(display)
        // A fresh read through the display's route; it can find the route changed (a DDC monitor
        // that stopped answering falls back to software), which must not pass as the route asked for.
        await model.refreshBrightness(for: observation)
        try confirmRoute(route, for: display)
        return await model.automationBrightnessReadback(for: observation)
    }

    func writeBrightness(_ level: AutomationLevel, to display: AutomationDisplayCandidate,
                         via route: BrightnessRoute) async throws(AutomationIssue) -> BrightnessWriteReport {
        let observation = try active(display)
        try confirmRoute(route, for: display)
        // The app's own brightness funnel: same routes, coalescing, OSD event and group behaviour as
        // any other change.
        if let issue = beforeClockWrite?() { throw issue }
        model.setBrightness(level.float, for: observation, eventSource: osdSource,
                            syncBypass: beforeClockWrite != nil, policyWrite: beforeClockWrite != nil)
        return await model.automationBrightnessWriteReport(level, for: observation)
    }

    func adjustBrightness(by delta: AutomationLevelDelta, of display: AutomationDisplayCandidate,
                          via route: BrightnessRoute) async throws(AutomationIssue) -> BrightnessWriteReport {
        let observation = try active(display)
        if model.brightness[display.id] == nil { await model.refreshBrightness(for: observation) }
        // From here to the write nothing suspends: on the main actor no other request can move the
        // level between this read and the write, so two quick +5 % requests make +10 % (FA-44).
        try confirmRoute(route, for: display)
        guard let current = model.brightness[display.id] else {
            throw AutomationIssue(.executionFailed, "the current brightness of \(display.name) isn't known",
                                  subject: display.id.rawValue)
        }
        let target = AutomationLevel(clamping: Double(current)).offset(by: delta)
        model.setBrightness(target.float, for: observation, eventSource: osdSource)
        return await model.automationBrightnessWriteReport(target, for: observation)
    }

    func writeGroupBrightness(_ level: AutomationLevel, group: String, dryRun: Bool) async throws(AutomationIssue) -> ResultEnvelope {
        try await model.automationGroupBrightness(level, groupName: group, dryRun: dryRun, actor: surface.actor)
    }

    func readContrast(of display: AutomationDisplayCandidate) async throws(AutomationIssue) -> BrightnessReadback {
        let readback = await model.automationContrastReadback(for: try active(display))
        guard readback.level != nil else { throw AutomationIssue(.methodUnavailable, "hardware contrast is unavailable") }
        return readback
    }
    func writeContrast(_ level: AutomationLevel, to display: AutomationDisplayCandidate) async throws(AutomationIssue) -> BrightnessWriteReport {
        let observation = try active(display)
        model.setHardwareControl(.contrast, level.float, for: observation, eventSource: osdSource)
        return await model.automationContrastWriteReport(level, for: observation)
    }

    // MARK: Modes and main display

    func modes(of display: AutomationDisplayCandidate) async throws(AutomationIssue) -> AutomationModeState {
        // A fresh topology read, so "already in this mode" is judged against the display as it is.
        await model.refresh()
        let observation = try active(display)
        return AutomationModeState(
            current: observation.mode,
            offered: AutomationModeOptions.options(from: model.allModes(for: observation), current: observation.mode))
    }

    func applyMode(_ mode: DisplayMode, to display: AutomationDisplayCandidate,
                   keepWithoutConfirmation: Bool) async throws(AutomationIssue) -> AutomationModeSettlement {
        let observation = try active(display)
        guard model.pendingRevert == nil else {
            throw AutomationIssue(.busy, "another display change is waiting to be kept or reverted; finish it first",
                                  subject: display.id.rawValue)
        }
        // The menu's own path: exact-mode check, verified apply, rollback on mismatch, then the
        // keep-or-revert countdown.
        await model.setMode(mode, for: observation)
        let actual = model.displays.first { $0.recordID == display.id }?.mode
        switch AutomationModeOptions.outcome(error: model.modeChangeError, revertPending: model.pendingRevert != nil,
                                             actual: actual, requested: mode) {
        case .alreadyInEffect:
            return .alreadyInEffect
        case .awaitingConfirmation:
            // Owner decision #20: the Intent may ask to keep a verified mode without the countdown.
            // macOS has confirmed the mode by now; only the timed rollback is skipped.
            if keepWithoutConfirmation {
                model.confirmArrangementChange()
                return .applied
            }
            return .awaitingConfirmation(secondsToKeep: model.pendingRevert?.secondsRemaining)
        case .failed(let message):
            throw AutomationIssue(.executionFailed, message, subject: display.id.rawValue)
        case .notConfirmed:
            throw AutomationIssue(.notConfirmed, "macOS didn't confirm the new mode on \(display.name)",
                                  subject: display.id.rawValue)
        }
    }

    func makeMain(_ display: AutomationDisplayCandidate) async throws(AutomationIssue) -> AutomationMainSettlement {
        // `setMain` re-reads the topology only when it moves something; read it first so the check
        // afterwards sees the current arrangement.
        await model.refresh()
        guard model.pendingRevert == nil else {
            throw AutomationIssue(.busy, "another display change is waiting to be kept or reverted; finish it first")
        }
        let observation = try active(display)
        let windowBefore = model.pendingRevert
        if !observation.isMain {
            // The app's own funnel opens the keep/revert window; a change that didn't open one
            // was refused or not confirmed by macOS.
            guard await model.setMain(for: observation), model.pendingRevert?.kind == .mainDisplay else {
                throw AutomationIssue(.notConfirmed,
                                      model.modeChangeError ?? "macOS didn't confirm \(display.name) as the main display",
                                      subject: display.id.rawValue)
            }
        }
        let main = model.displays.first { $0.isMain && $0.isActive }?.recordID
        // Only a window this change opened says it may revert.
        let opened = windowBefore == nil && model.pendingRevert != nil
        return AutomationMainSettlement(observedMain: main, awaitingConfirmation: opened,
                                        secondsToKeep: opened ? model.pendingRevert?.secondsRemaining : nil)
    }

    // MARK: Colour profiles

    func installedColorProfiles() async throws(AutomationIssue) -> [AutomationProfileInfo] {
        if model.availableColorProfilesCache.isEmpty { await model.reloadInstalledColorProfiles() }
        return model.availableColorProfilesCache.map { AutomationProfileInfo(id: $0.id, name: $0.name) }
    }

    func colorProfile(of display: AutomationDisplayCandidate) async throws(AutomationIssue) -> AutomationColorProfileState {
        let observation = try active(display)
        await model.refreshColorProfile(for: observation)
        return model.automationColorProfileState(for: display.id)
    }

    func applyColorProfile(_ profile: AutomationProfileInfo?,
                           to display: AutomationDisplayCandidate) async throws(AutomationIssue) -> AutomationColorProfileState {
        let observation = try active(display)
        if let profile {
            guard let installed = model.availableColorProfilesCache.first(where: { $0.id == profile.id }) else {
                throw AutomationIssue(.profileNotFound, "\(profile.name) is no longer installed", subject: profile.id)
            }
            await model.setColorProfile(installed, for: observation)
        } else {
            await model.resetColorProfile(for: observation)
        }
        if let failure = model.colorProfileError[display.id] {
            throw AutomationIssue(.executionFailed, failure, subject: display.id.rawValue)
        }
        return model.automationColorProfileState(for: display.id)
    }

    // MARK: Recovery

    func validateDisconnect(_ display: AutomationDisplayCandidate) async throws(AutomationIssue) {
        guard !model.busy, model.pendingRevert == nil else {
            throw AutomationIssue(.busy, "another display operation is in progress")
        }
        guard model.canTurnOff(try active(display)) else {
            throw AutomationIssue(.capabilityUnavailable, "disconnect would leave no usable recovery screen")
        }
    }
    func disconnect(_ display: AutomationDisplayCandidate) async throws(AutomationIssue) -> ResultEnvelope {
        try await validateDisconnect(display)
        let committed = await model.setDisplayActive(false, for: try active(display), as: surface.actor)
        return ResultEnvelope(transactionId: "txn_disconnect", status: committed ? .committed : .failed,
            actor: surface.actor, requestedAt: Date(), topologyGeneration: model.displays.map(\.generation.value).max() ?? 0,
            targets: [.init(displayId: display.id.rawValue, alias: display.alias, identityConfidence: 1,
                            operations: [.init(field: "connected", requested: .bool(false),
                                               verification: committed ? .verified : .notApplicable,
                                               outcome: committed ? .verified : .failed)])])
    }

    func reconnectAll() async throws(AutomationIssue) -> ResultEnvelope {
        guard !model.busy else { throw AutomationIssue(.busy, "another display operation is in progress") }
        guard surface == .http else { return await model.reconnectAll(actor: surface.actor) }
        // A verified reconnect watches each display until it lights (with one escalation), which
        // outlasts an HTTP connection, so it runs as its own operation — the socket closing doesn't
        // cancel it — and the answer says what was requested (`sent`). The outcome goes to the audit
        // log; GET /v1/displays shows displays returning.
        guard !model.busy else {
            throw AutomationIssue(.busy, "another display operation is in progress")
        }
        let pending = model.managedOffline.map(\.recordID.rawValue)
        Task { @MainActor [model] in _ = await model.reconnectAll(actor: .httpAPI) }
        return ResultEnvelope(
            transactionId: "txn_reconnectAll", status: pending.isEmpty ? .noOp : .committed, actor: .httpAPI,
            requestedAt: Date(), topologyGeneration: model.displays.map(\.generation.value).max() ?? 0,
            targets: pending.map {
                .init(displayId: $0, alias: nil, identityConfidence: 1.0, operations: [
                    .init(field: "reconnect", verification: .readBackUnavailable, outcome: .sent)])
            })
    }

    // MARK: Helpers

    private var osdSource: OSDBroadcast.Source {
        switch surface {
        case .http: return .http
        case .appIntent: return .appIntent
        case .cli: return .cli
        case .url, .console: return .app
        }
    }

    private func observation(_ display: AutomationDisplayCandidate) -> DisplayObservation? {
        model.displays.first { $0.recordID == display.id }
    }

    /// The live observation of a display the engine resolved as active; it may have gone since.
    private func active(_ display: AutomationDisplayCandidate) throws(AutomationIssue) -> DisplayObservation {
        guard let observation = observation(display), observation.isActive else {
            throw AutomationIssue(.displayNotConnected, "\(display.name) isn't connected any more",
                                  subject: display.id.rawValue)
        }
        return observation
    }

    private func confirmRoute(_ route: BrightnessRoute, for display: AutomationDisplayCandidate) throws(AutomationIssue) {
        let routes = model.automationBrightnessRoutes(for: display.id)
        guard routes.current == route else {
            throw AutomationIssue(
                .methodUnavailable,
                "\(display.name) is now driven \(routes.current.map { "through \($0.rawValue)" } ?? "through no route"), not \(route.rawValue); nothing was changed",
                subject: route.rawValue)
        }
    }

    /// The Core Graphics id of the display under the pointer.
    private static func pointerDisplayID() -> UInt32? {
        let location = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(location, $0.frame, false) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return number.uint32Value
    }
}
#endif
