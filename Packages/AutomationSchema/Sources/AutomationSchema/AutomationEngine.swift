import DisplayDomain
import Foundation

/// What a surface plugs into the engine: its candidate displays and the primitive operations it can
/// perform (FD-066/FD-067). The app implements it over its live model; the CLI over its own
/// providers; tests over fakes. Primitives do the I/O and report what they observed — they don't
/// decide targets, units, routes or verdicts; the engine does, the same way for every surface.
///
/// Every primitive has a default that refuses with `capabilityUnavailable`, so a surface that can't
/// run a command says so instead of pretending. A primitive may throw an issue of its own (`busy`,
/// `executionFailed` with the app's explanation, …).
public protocol AutomationEnvironment: Sendable {
    var surface: AutomationSurface { get }

    /// Waits until the surface can answer (the app: its launch-time load); throws `notReady` if it can't.
    func prepare() async throws(AutomationIssue)
    /// Every display this surface can name now.
    func displaySet() async -> AutomationDisplaySet
    /// Why this surface can't run `command` at all, or nil when it can.
    func unavailability(of command: AutomationCommandName) -> AutomationIssue?

    func brightnessRoutes(for display: AutomationDisplayCandidate) async -> BrightnessRouteAvailability
    /// A fresh read through `route`.
    func readBrightness(of display: AutomationDisplayCandidate, via route: BrightnessRoute) async throws(AutomationIssue) -> BrightnessReadback
    /// Writes `level` through `route`, then reads it back once the write has run.
    func writeBrightness(_ level: AutomationLevel, to display: AutomationDisplayCandidate,
                         via route: BrightnessRoute) async throws(AutomationIssue) -> BrightnessWriteReport
    /// Moves the level by `delta` against the level at execution time, with no other write able to
    /// land between that read and this write (FA-44: two rapid +5 % requests make +10 %).
    func adjustBrightness(by delta: AutomationLevelDelta, of display: AutomationDisplayCandidate,
                          via route: BrightnessRoute) async throws(AutomationIssue) -> BrightnessWriteReport

    func modes(of display: AutomationDisplayCandidate) async throws(AutomationIssue) -> AutomationModeState
    /// Applies an exact offered mode through the surface's verified path; with
    /// `keepWithoutConfirmation` a verified mode is kept at once rather than awaiting the countdown.
    func applyMode(_ mode: DisplayMode, to display: AutomationDisplayCandidate,
                   keepWithoutConfirmation: Bool) async throws(AutomationIssue) -> AutomationModeSettlement
    /// Makes the display main and reports the main display observed afterwards.
    func makeMain(_ display: AutomationDisplayCandidate) async throws(AutomationIssue) -> AutomationMainSettlement

    func installedColorProfiles() async throws(AutomationIssue) -> [AutomationProfileInfo]
    func colorProfile(of display: AutomationDisplayCandidate) async throws(AutomationIssue) -> AutomationColorProfileState
    /// Assigns `profile` (nil: the factory profile) and returns the assignment read back.
    func applyColorProfile(_ profile: AutomationProfileInfo?, to display: AutomationDisplayCandidate) async throws(AutomationIssue) -> AutomationColorProfileState

    func reconnectAll() async throws(AutomationIssue) -> ResultEnvelope
    func disconnect(_ display: AutomationDisplayCandidate) async throws(AutomationIssue) -> ResultEnvelope
    func feedIntegration(control: UUID, response: String, display: AutomationDisplayCandidate) async throws(AutomationIssue) -> IntegrationSample
}

public extension AutomationEnvironment {
    func prepare() async throws(AutomationIssue) {}
    func unavailability(of command: AutomationCommandName) -> AutomationIssue? { nil }

    func brightnessRoutes(for display: AutomationDisplayCandidate) async -> BrightnessRouteAvailability {
        BrightnessRouteAvailability(current: nil, states: [:])
    }
    func readBrightness(of display: AutomationDisplayCandidate, via route: BrightnessRoute) async throws(AutomationIssue) -> BrightnessReadback {
        throw notOffered(.getBrightness)
    }
    func writeBrightness(_ level: AutomationLevel, to display: AutomationDisplayCandidate,
                         via route: BrightnessRoute) async throws(AutomationIssue) -> BrightnessWriteReport {
        throw notOffered(.setBrightness)
    }
    func adjustBrightness(by delta: AutomationLevelDelta, of display: AutomationDisplayCandidate,
                          via route: BrightnessRoute) async throws(AutomationIssue) -> BrightnessWriteReport {
        throw notOffered(.adjustBrightness)
    }
    func modes(of display: AutomationDisplayCandidate) async throws(AutomationIssue) -> AutomationModeState {
        throw notOffered(.listModes)
    }
    func applyMode(_ mode: DisplayMode, to display: AutomationDisplayCandidate,
                   keepWithoutConfirmation: Bool) async throws(AutomationIssue) -> AutomationModeSettlement {
        throw notOffered(.setMode)
    }
    func makeMain(_ display: AutomationDisplayCandidate) async throws(AutomationIssue) -> AutomationMainSettlement {
        throw notOffered(.setMain)
    }
    func installedColorProfiles() async throws(AutomationIssue) -> [AutomationProfileInfo] {
        throw notOffered(.listColorProfiles)
    }
    func colorProfile(of display: AutomationDisplayCandidate) async throws(AutomationIssue) -> AutomationColorProfileState {
        throw notOffered(.getColorProfile)
    }
    func applyColorProfile(_ profile: AutomationProfileInfo?, to display: AutomationDisplayCandidate) async throws(AutomationIssue) -> AutomationColorProfileState {
        throw notOffered(profile == nil ? .resetColorProfile : .setColorProfile)
    }
    func reconnectAll() async throws(AutomationIssue) -> ResultEnvelope {
        throw notOffered(.reconnectAll)
    }
    func disconnect(_ display: AutomationDisplayCandidate) async throws(AutomationIssue) -> ResultEnvelope {
        throw notOffered(.disconnect)
    }

    func feedIntegration(control: UUID, response: String, display: AutomationDisplayCandidate) async throws(AutomationIssue) -> IntegrationSample {
        throw notOffered(.feedIntegration)
    }

    private func notOffered(_ command: AutomationCommandName) -> AutomationIssue {
        AutomationIssue(.capabilityUnavailable, "'\(command.rawValue)' isn't available from \(surface.rawValue)",
                        subject: command.rawValue)
    }
}

/// The one request → validation → execution → settled-outcome path (FD-066/FD-067). Every surface
/// builds an `AutomationRequest`, hands it to `run`, and renders the `AutomationResult` — so target
/// resolution, ambiguity rejection, route choice (hardware-only included), unit handling and the
/// verdict on what happened cannot drift between the CLI, the URL scheme, HTTP and App Intents.
///
/// Order of checks, each refusing before anything changes: may this surface run the command → can
/// it at all → is the surface ready → does the selector name exactly one usable display → does the
/// display offer what's needed → (dry run stops here) → execute → settle from what was read back.
public struct AutomationEngine<Environment: AutomationEnvironment>: Sendable {
    public let environment: Environment
    private let now: @Sendable () -> Date

    public init(environment: Environment, now: @escaping @Sendable () -> Date = { Date() }) {
        self.environment = environment
        self.now = now
    }

    public func run(_ request: AutomationRequest) async -> AutomationResult {
        var context = Context(request: request, surface: environment.surface, requestedAt: now())
        do throws(AutomationIssue) {
            let descriptor = AutomationCatalog.descriptor(for: request.command.name)
            try admit(descriptor)
            if case .setMode(_, keepWithoutConfirmation: true) = request.command,
               environment.surface != .appIntent {
                throw AutomationIssue(.refusedFromSurface, "only App Intents may skip mode confirmation",
                                      subject: request.command.name.rawValue)
            }
            try await environment.prepare()
            let set = await environment.displaySet()
            context.generation = set.topologyGeneration
            let target = try resolveTarget(request, descriptor: descriptor, in: set)
            context.target = target
            return try await execute(request.command, target: target, set: set, context: context)
        } catch {
            return context.refusal(error)
        }
    }

    // MARK: Admission and targets

    private func admit(_ descriptor: AutomationCommandDescriptor) throws(AutomationIssue) {
        guard descriptor.surfaces.contains(environment.surface) else {
            // A link may never fire a disruptive or arrangement change; it names the confirmation the
            // app would need rather than a bare refusal.
            if environment.surface == .url, descriptor.effect == .disruptive || descriptor.effect == .arrangement {
                throw AutomationIssue(.confirmationRequired,
                                      "'\(descriptor.name.rawValue)' changes the display arrangement and is never run from a link",
                                      subject: descriptor.name.rawValue)
            }
            throw AutomationIssue(.refusedFromSurface,
                                  "'\(descriptor.name.rawValue)' isn't accepted from \(environment.surface.rawValue)",
                                  subject: descriptor.name.rawValue)
        }
        if let issue = environment.unavailability(of: descriptor.name) { throw issue }
    }

    private func resolveTarget(_ request: AutomationRequest, descriptor: AutomationCommandDescriptor,
                               in set: AutomationDisplaySet) throws(AutomationIssue) -> AutomationDisplayCandidate? {
        guard descriptor.target != .none else { return nil }
        guard let selector = request.target else {
            throw AutomationIssue.missing("display", for: descriptor.name.rawValue)
        }
        let candidate = try AutomationSelectorResolver.resolveOne(selector, text: request.targetText, in: set)
        if let issue = AutomationSelectorResolver.availabilityIssue(candidate, requirement: descriptor.target) {
            throw issue
        }
        return candidate
    }

    // MARK: Execution

    private func execute(_ command: AutomationCommand, target: AutomationDisplayCandidate?, set: AutomationDisplaySet,
                         context: Context) async throws(AutomationIssue) -> AutomationResult {
        switch command {
        case .feedIntegration(let control, let response):
            let display = try required(target)
            if context.request.dryRun { return context.plan("parse and feed integration control \(control) on \(display.name); no setter") }
            let sample = try await environment.feedIntegration(control: control, response: response, display: display)
            var result = context.result(status: .committed)
            result.integrationSample = sample
            return result

        case .listDisplays:
            var result = context.result(status: .noOp)
            result.displays = set.candidates.map(AutomationDisplaySummary.init)
            return result

        case .getCapabilities:
            let display = try required(target)
            let commands = AutomationCatalog.descriptors.map { descriptor in
                let issue: AutomationIssue?
                do throws(AutomationIssue) {
                    try admit(descriptor)
                    issue = AutomationSelectorResolver.availabilityIssue(display, requirement: descriptor.target)
                } catch { issue = error }
                return AutomationCommandAvailability(command: descriptor.name, issue: issue)
            }
            let routes = display.availability == .active
                ? await environment.brightnessRoutes(for: display)
                : BrightnessRouteAvailability(current: nil, states: [:])
            var result = context.result(status: .noOp)
            result.capabilities = AutomationCapabilityReport(displayId: display.id.rawValue,
                                                              surface: environment.surface, commands: commands,
                                                              brightnessRoutes: routes)
            return result

        case .getBrightness(let method):
            let display = try required(target)
            let route = try await chooseRoute(method, for: display)
            if context.request.dryRun { return context.plan("read the brightness of \(display.name) via \(route.rawValue)") }
            let readback = try await environment.readBrightness(of: display, via: route)
            guard let level = readback.level else {
                throw AutomationIssue(.executionFailed, "the brightness of \(display.name) can't be read via \(route.rawValue)",
                                      subject: display.id.rawValue)
            }
            let report = brightnessReport(display, route: route, requested: nil, level: level, outcome: nil,
                                          readback: readback, note: readback.isReportedByDisplay ? nil
                                              : "software dimming: the level FreeDisplay applies; the display can't report it")
            var result = context.result(status: .noOp, operations: [
                .init(field: "brightness", observed: .double(level.normalized),
                      verification: readback.isReportedByDisplay ? .verified : .readBackUnavailable,
                      provider: route.provider)])
            result.brightness = report
            return result

        case .setBrightness(let level, let method):
            let display = try required(target)
            let route = try await chooseRoute(method, for: display)
            if context.request.dryRun {
                return context.plan("set the brightness of \(display.name) to \(level.wholePercent)% via \(route.rawValue)",
                                    field: "brightness", requested: .double(level.normalized))
            }
            let report = try await environment.writeBrightness(level, to: display, via: route)
            return settleBrightness(report, display: display, route: route, context: context)

        case .adjustBrightness(let delta, let method):
            let display = try required(target)
            let route = try await chooseRoute(method, for: display)
            if context.request.dryRun {
                return context.plan("change the brightness of \(display.name) by \(delta) via \(route.rawValue)",
                                    field: "brightness")
            }
            let report = try await environment.adjustBrightness(by: delta, of: display, via: route)
            return settleBrightness(report, display: display, route: route, context: context)

        case .listModes, .getMode:
            let display = try required(target)
            let state = try await environment.modes(of: display)
            if command == .getMode, state.current == nil {
                throw AutomationIssue(.executionFailed, "the current mode of \(display.name) can't be read",
                                      subject: display.id.rawValue)
            }
            var result = context.result(status: .noOp, operations: state.current.map {
                [.init(field: "mode", observed: .string(FavoriteResolutions.key(for: $0)), verification: .verified)]
            } ?? [])
            result.modes = modeList(display, state: state)
            return result

        case .setMode(let spec, let keep):
            let display = try required(target)
            let state = try await environment.modes(of: display)
            let mode = try spec.resolve(among: state.offered + [state.current].compactMap { $0 }, displayName: display.name)
            let key = FavoriteResolutions.key(for: mode)
            if let current = state.current, DisplayModeChoices.matches(current, requested: mode) {
                var result = context.result(status: .noOp, operations: [
                    .init(field: "mode", requested: .string(key), observed: .string(key), verification: .verified,
                          outcome: .alreadySatisfied)])
                result.mode = modeReport(display, mode: mode, settlement: .alreadyInEffect)
                return result
            }
            if context.request.dryRun {
                return context.plan("switch \(display.name) to \(key)", field: "mode", requested: .string(key))
            }
            let settlement = try await environment.applyMode(mode, to: display, keepWithoutConfirmation: keep)
            var warnings: [String] = []
            if case .awaitingConfirmation(let seconds) = settlement {
                warnings.append("keepPending: the mode reverts unless it is kept in the app"
                    + (seconds.map { " within \($0) seconds" } ?? ""))
            }
            let outcome: OperationOutcome = settlement == .alreadyInEffect ? .alreadySatisfied : .verified
            var result = context.result(status: .aggregate([outcome]), operations: [
                .init(field: "mode", requested: .string(key), observed: .string(key), verification: .verified,
                      warnings: warnings, outcome: outcome)])
            result.mode = modeReport(display, mode: mode, settlement: settlement)
            return result

        case .setMain:
            let display = try required(target)
            if display.isMain {
                var result = context.result(status: .noOp, operations: [
                    .init(field: "main", requested: .bool(true), observed: .bool(true), verification: .verified,
                          outcome: .alreadySatisfied)])
                result.main = AutomationMainReport(displayId: display.id.rawValue, displayName: display.name, changed: false,
                                                   awaitingConfirmation: false, secondsToKeep: nil)
                return result
            }
            if context.request.dryRun {
                return context.plan("make \(display.name) the main display", field: "main", requested: .bool(true))
            }
            let settlement = try await environment.makeMain(display)
            guard settlement.observedMain == display.id else {
                throw AutomationIssue(.notConfirmed, "macOS didn't make \(display.name) the main display",
                                      subject: display.id.rawValue)
            }
            let warnings = settlement.awaitingConfirmation
                ? ["keepPending: the arrangement reverts unless it is kept in the app"
                    + (settlement.secondsToKeep.map { " within \($0) seconds" } ?? "")]
                : []
            var result = context.result(status: .committed, operations: [
                .init(field: "main", requested: .bool(true), observed: .bool(true), verification: .verified,
                      warnings: warnings, outcome: .verified)])
            result.main = AutomationMainReport(displayId: display.id.rawValue, displayName: display.name, changed: true,
                                               awaitingConfirmation: settlement.awaitingConfirmation,
                                               secondsToKeep: settlement.secondsToKeep)
            return result

        case .listColorProfiles:
            var result = context.result(status: .noOp)
            result.colorProfiles = try await environment.installedColorProfiles()
            return result

        case .getColorProfile:
            let display = try required(target)
            let state = try await environment.colorProfile(of: display)
            var result = context.result(status: .noOp, operations: [
                .init(field: "colorProfile", observed: state.name.map(AnyCodableValue.string), verification: .verified)])
            result.colorProfile = AutomationColorProfileReport(displayId: display.id.rawValue, displayName: display.name,
                                                               state: state, changed: nil)
            return result

        case .setColorProfile(let spec):
            let display = try required(target)
            let profile = try spec.resolve(among: try await environment.installedColorProfiles())
            return try await changeColorProfile(to: profile, display: display, context: context)

        case .resetColorProfile:
            let display = try required(target)
            return try await changeColorProfile(to: nil, display: display, context: context)

        case .reconnectAll:
            if context.request.dryRun { return context.plan("reconnect every display FreeDisplay turned off") }
            let envelope = try await environment.reconnectAll()
            var result = AutomationResult(command: .reconnectAll, envelope: envelope)
            if envelope.status == .failed {
                result.issue = AutomationIssue(.executionFailed, "no display that was turned off came back")
            }
            return result

        case .disconnect:
            let display = try required(target)
            if context.request.dryRun { return context.plan("turn \(display.name) off", field: "connected") }
            let envelope = try await environment.disconnect(display)
            var result = AutomationResult(command: .disconnect, envelope: envelope)
            if envelope.status == .failed || envelope.status == .rolledBack {
                result.issue = AutomationIssue(.executionFailed, "\(display.name) was not turned off",
                                               subject: display.id.rawValue)
            }
            return result
        }
    }

    private func required(_ target: AutomationDisplayCandidate?) throws(AutomationIssue) -> AutomationDisplayCandidate {
        guard let target else { throw AutomationIssue(.missingParameter, "no display was named", subject: "display") }
        return target
    }

    private func chooseRoute(_ method: BrightnessMethodRequest,
                             for display: AutomationDisplayCandidate) async throws(AutomationIssue) -> BrightnessRoute {
        let availability = await environment.brightnessRoutes(for: display)
        return try BrightnessRoutePolicy.choose(method, availability: availability, displayName: display.name)
    }

    private func settleBrightness(_ report: BrightnessWriteReport, display: AutomationDisplayCandidate,
                                  route: BrightnessRoute, context: Context) -> AutomationResult {
        let verdict = BrightnessSettlement.settle(report)
        let verification: VerificationState
        switch verdict.outcome {
        case .verified: verification = .verified
        case .sent: verification = .readBackUnavailable
        default: verification = .notApplicable
        }
        var result = context.result(status: .aggregate([verdict.outcome]), operations: [
            .init(field: "brightness", requested: .double(report.requested.normalized),
                  observed: verdict.observed.map { .double($0.normalized) }, verification: verification,
                  provider: route.provider, warnings: verdict.note.map { [$0] } ?? [], outcome: verdict.outcome)])
        if verdict.outcome == .failed {
            let issue = AutomationIssue(.executionFailed, "\(display.name): \(verdict.note ?? "the write failed")",
                                        subject: display.id.rawValue)
            result.issue = issue
            result.envelope.errors = [issue.errorInfo]
        }
        result.brightness = brightnessReport(display, route: route, requested: report.requested, level: verdict.observed,
                                             outcome: verdict.outcome, readback: report.readback, note: verdict.note,
                                             reportedByDisplay: verdict.verifiedByDisplay
                                                 || (report.readback.isReportedByDisplay && verdict.observed != nil))
        return result
    }

    private func brightnessReport(_ display: AutomationDisplayCandidate, route: BrightnessRoute,
                                  requested: AutomationLevel?, level: AutomationLevel?, outcome: OperationOutcome?,
                                  readback: BrightnessReadback, note: String?,
                                  reportedByDisplay: Bool? = nil) -> AutomationBrightnessReport {
        var raw: Int?
        var rawMaximum: Int?
        if case .ddc(let current, let max) = readback {
            raw = current
            rawMaximum = max
        }
        return AutomationBrightnessReport(displayId: display.id.rawValue, displayName: display.name, route: route,
                                          requested: requested, level: level, outcome: outcome,
                                          reportedByDisplay: reportedByDisplay ?? readback.isReportedByDisplay,
                                          raw: raw, rawMaximum: rawMaximum, note: note)
    }

    private func modeList(_ display: AutomationDisplayCandidate, state: AutomationModeState) -> AutomationModeList {
        let current = state.current.map { AutomationModeEntry(mode: $0, isCurrent: true) }
        let others = state.offered.filter { mode in
            guard let current = state.current else { return true }
            return !DisplayModeChoices.matches(mode, requested: current)
        }
        return AutomationModeList(displayId: display.id.rawValue, displayName: display.name, current: current,
                                  available: (current.map { [$0] } ?? []) + others.map { AutomationModeEntry(mode: $0, isCurrent: false) })
    }

    private func modeReport(_ display: AutomationDisplayCandidate, mode: DisplayMode,
                            settlement: AutomationModeSettlement) -> AutomationModeReport {
        let kind: AutomationModeReport.Settlement
        var seconds: Int?
        switch settlement {
        case .alreadyInEffect: kind = .alreadyInEffect
        case .applied: kind = .applied
        case .awaitingConfirmation(let left):
            kind = .awaitingConfirmation
            seconds = left
        }
        return AutomationModeReport(displayId: display.id.rawValue, displayName: display.name,
                                    mode: AutomationModeEntry(mode: mode, isCurrent: true), settlement: kind,
                                    secondsToKeep: seconds)
    }

    private func changeColorProfile(to profile: AutomationProfileInfo?, display: AutomationDisplayCandidate,
                                    context: Context) async throws(AutomationIssue) -> AutomationResult {
        let before = try await environment.colorProfile(of: display)
        guard before.controllable else {
            throw AutomationIssue(.capabilityUnavailable,
                                  "ColorSync has no profile device for \(display.name), so no profile can be assigned",
                                  subject: display.id.rawValue)
        }
        let field = "colorProfile"
        let requested: AnyCodableValue = .string(profile?.id ?? "factory")
        if Self.holds(before, profile) {
            var result = context.result(status: .noOp, operations: [
                .init(field: field, requested: requested, observed: before.name.map(AnyCodableValue.string),
                      verification: .verified, outcome: .alreadySatisfied)])
            result.colorProfile = AutomationColorProfileReport(displayId: display.id.rawValue, displayName: display.name,
                                                               state: before, changed: false)
            return result
        }
        if context.request.dryRun {
            return context.plan("assign \(profile?.name ?? "the factory profile") to \(display.name)",
                                field: field, requested: requested)
        }
        let after = try await environment.applyColorProfile(profile, to: display)
        guard Self.holds(after, profile) else {
            throw AutomationIssue(.notConfirmed,
                                  "ColorSync doesn't report \(profile?.name ?? "the factory profile") on \(display.name); the profile shown is the one in effect",
                                  subject: display.id.rawValue)
        }
        var result = context.result(status: .committed, operations: [
            .init(field: field, requested: requested, observed: after.name.map(AnyCodableValue.string),
                  verification: .verified, outcome: .verified)])
        result.colorProfile = AutomationColorProfileReport(displayId: display.id.rawValue, displayName: display.name,
                                                           state: after, changed: true)
        return result
    }

    /// Whether `state` shows `profile` in effect (nil: the factory profile).
    private static func holds(_ state: AutomationColorProfileState, _ profile: AutomationProfileInfo?) -> Bool {
        guard let profile else { return state.isFactory }
        guard let path = state.customProfilePath else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.path == URL(fileURLWithPath: profile.id).standardizedFileURL.path
    }

    // MARK: Result assembly

    private struct Context {
        var request: AutomationRequest
        var surface: AutomationSurface
        var requestedAt: Date
        var generation: UInt64 = 0
        var target: AutomationDisplayCandidate?

        /// Brightness commands keep the transaction id the CLI always printed for them.
        var transactionID: String {
            switch request.command.name {
            case .getBrightness, .setBrightness, .adjustBrightness: return "txn_brightness"
            default: return "txn_\(request.command.name.rawValue)"
            }
        }

        func envelope(status: ResultEnvelope.Status, operations: [ResultEnvelope.OperationResult] = [],
                      errors: [ResultEnvelope.ErrorInfo] = []) -> ResultEnvelope {
            let targets = target.map {
                [ResultEnvelope.TargetResult(displayId: $0.id.rawValue, alias: $0.alias, identityConfidence: 1.0,
                                             operations: operations)]
            } ?? []
            return ResultEnvelope(transactionId: transactionID, status: status, actor: surface.actor,
                                  requestedAt: requestedAt, topologyGeneration: generation, targets: targets,
                                  errors: errors)
        }

        func result(status: ResultEnvelope.Status, operations: [ResultEnvelope.OperationResult] = []) -> AutomationResult {
            AutomationResult(command: request.command.name, envelope: envelope(status: status, operations: operations),
                             dryRun: request.dryRun)
        }

        func plan(_ description: String, field: String? = nil, requested: AnyCodableValue? = nil) -> AutomationResult {
            let operations = field.map {
                [ResultEnvelope.OperationResult(field: $0, requested: requested, verification: .notApplicable,
                                                warnings: ["dryRun"], outcome: .skipped)]
            } ?? []
            var result = AutomationResult(command: request.command.name,
                                          envelope: envelope(status: .noOp, operations: operations), dryRun: true)
            result.plan = description
            return result
        }

        func refusal(_ issue: AutomationIssue) -> AutomationResult {
            AutomationResult(command: request.command.name,
                             envelope: envelope(status: .failed, errors: [issue.errorInfo]),
                             issue: issue, dryRun: request.dryRun)
        }
    }
}

extension BrightnessRoute {
    /// The provider name result envelopes have always used for this route.
    var provider: String {
        switch self {
        case .native: return "displayServices"
        case .ddc: return "ddc"
        case .software: return "software"
        }
    }
}
