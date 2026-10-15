#if os(macOS)
import AutomationSchema
import CoreGraphics
import DisplayDomain
import Foundation
import TopologyCore

extension AppModel {
    func clockModeOwnsBrightness(_ id: DisplayRecordID) -> Bool {
        settings.clockMode?.displays.contains { $0.displayID == id } == true
    }

    func reconcileClockMode() {
        let wanted = settings.clockScheduleEnabled && !safeStartup && !clockModeLifecycleSuspended
            && settings.clockMode?.displays.isEmpty == false
        guard wanted else {
            clockModeTask?.cancel()
            clockModeTask = nil
            return
        }
        guard clockModeTask == nil else { return }
        clockModeTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.clockModeTick()
                try? await Task.sleep(nanoseconds: ClockSchedulePolicy.samplingNanoseconds)
            }
        }
    }

    func clockSample(_ schedule: ClockDisplaySchedule, at now: Date) throws(AutomationIssue) -> ClockCalendarPolicy.Sample? {
        guard let zone = settings.clockMode?.timeZone(current: .current) else {
            throw AutomationIssue(.invalidValue, "invalid Clock Mode time zone")
        }
        return try ClockCalendarPolicy.sample(at: now, schedule: schedule, timeZone: zone,
                                              coordinate: settings.clockManualLocation)
    }

    func noteManualClockBrightness(_ id: DisplayRecordID) {
        guard let schedule = settings.clockMode?.displays.first(where: { $0.displayID == id }) else { return }
        clockModeSession.noteManualChange(to: id, sample: try? clockSample(schedule, at: Date()))
        clockModeLastRequests[id] = nil
    }

    func clockModeTargetSleeping(_ id: DisplayRecordID) -> Bool {
        clockModeIsSleeping || (displays.first(where: { $0.recordID == id })?.cgDisplayID
            .map { CGDisplayIsAsleep($0) != 0 } ?? false)
    }

    func clockDecision(_ schedule: ClockDisplaySchedule, at now: Date) throws(AutomationIssue) -> ClockModeSession.Decision {
        let asleep = clockModeTargetSleeping(schedule.displayID)
        return clockModeSession.decision(schedule: schedule, sample: try clockSample(schedule, at: now),
                                         enabled: settings.clockScheduleEnabled && !clockModeLifecycleSuspended, safeStartup: safeStartup,
                                         sleeping: clockModeIsSleeping || asleep,
                                         competingPolicy: clockModeHasCompetitor(schedule.displayID))
    }

    func clockModeTick() async {
        guard !clockModeTickInProgress, !clockModeLifecycleSuspended,
              let configuration = settings.clockMode, settings.clockScheduleEnabled, !safeStartup else { return }
        clockModeTickInProgress = true
        defer { clockModeTickInProgress = false }
        for schedule in configuration.displays {
            guard !Task.isCancelled, settings.clockMode == configuration, settings.clockScheduleEnabled else { return }
            do {
                let plannedAt = Date()
                let intervalStart = try clockSample(schedule, at: plannedAt)?.intervalStart
                switch try clockDecision(schedule, at: plannedAt) {
                case .hold(let reason):
                    clockModeHolds[schedule.displayID] = reason
                    clockModeLastRequests[schedule.displayID] = nil
                case .request(let request):
                    clockModeHolds[schedule.displayID] = nil
                    // A settled absolute request needs no repeated transport write in the same state.
                    if clockModeLastRequests[schedule.displayID] == request { continue }
                    let result = await runClockRequest(request, schedule: schedule, recurring: true, intervalStart: intervalStart)
                    guard !Task.isCancelled, settings.clockMode == configuration,
                          settings.clockScheduleEnabled, !clockModeLifecycleSuspended else { return }
                    clockModeResults[schedule.displayID] = result
                    if result.issue == nil, result.status == .committed || result.status == .noOp {
                        clockModeLastRequests[schedule.displayID] = request
                    }
                }
            } catch {
                clockModeHolds[schedule.displayID] = nil
                clockModeResults[schedule.displayID] = nil
                clockModeConfigurationError = String(localized: "Clock Mode configuration is invalid. Check the time zone, times and duplicate points.")
            }
        }
    }

    /// Both one-shot Apply Now and recurring execution send exactly the same typed absolute request.
    func applyClockRecipe(_ schedule: ClockDisplaySchedule) async {
        do {
            guard let sample = try clockSample(schedule, at: Date()) else {
                clockModeHolds[schedule.displayID] = .noAnchor
                return
            }
            let request = AutomationRequest.byID(.setBrightness(sample.level, method: schedule.method), schedule.displayID)
            clockModeResults[schedule.displayID] = await runClockRequest(request, schedule: schedule, recurring: false)
        } catch {
            clockModeConfigurationError = String(localized: "Clock Mode configuration is invalid. Check the time zone, times and duplicate points.")
        }
    }

    func restoreClockRecipe(_ schedule: ClockDisplaySchedule) async {
        // Disable before dispatch: no future policy request may overtake this explicit Restore.
        updateClockMode(settings.clockMode, enabled: false)
        clockModeResults[schedule.displayID] = await runClockRequest(schedule.restoreRequest, schedule: schedule,
                                                                    recurring: false)
    }

    func resumeClockRecipes() {
        clockModeSession.resume()
        clockModeLastRequests.removeAll()
        clockModeHolds.removeAll()
        Task { await clockModeTick() }
    }

    private func runClockRequest(_ request: AutomationRequest, schedule: ClockDisplaySchedule,
                                 recurring: Bool, intervalStart: Date? = nil) async -> AutomationResult {
        let configuration = settings.clockMode
        let environment = AppAutomationEnvironment(model: self, surface: .console, beforeClockWrite: { [weak self] in
            guard let self, self.settings.clockMode == configuration,
                  configuration?.displays.filter({ $0.displayID == schedule.displayID }).count == 1,
                  !Task.isCancelled, !self.clockModeLifecycleSuspended,
                  !self.clockModeTargetSleeping(schedule.displayID),
                  !self.clockModeHasCompetitor(schedule.displayID) else {
                return AutomationIssue(.busy, "Clock Mode target is held by another policy or its configuration changed")
            }
            // Route discovery and startup readiness suspend. Re-evaluate immediately before writing.
            if recurring {
                do throws(AutomationIssue) {
                    guard let intervalStart,
                          self.clockModeSession.allowsDispatch(schedule: schedule, intervalStart: intervalStart,
                              sample: try self.clockSample(schedule, at: Date()),
                              enabled: self.settings.clockScheduleEnabled, safeStartup: self.safeStartup,
                              sleeping: self.clockModeTargetSleeping(schedule.displayID),
                              competingPolicy: self.clockModeHasCompetitor(schedule.displayID)) else {
                        return AutomationIssue(.busy, "Clock Mode changed or paused before dispatch")
                    }
                } catch { return error }
            }
            return nil
        })
        return await AutomationEngine(environment: environment).run(request)
    }
}
#endif
