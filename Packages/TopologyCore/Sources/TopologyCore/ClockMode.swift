import AutomationSchema
import DisplayDomain
import Foundation

public enum ClockResumePolicy: String, Codable, Hashable, Sendable, CaseIterable {
    case currentInterval
    case pauseUntilResumed
}

/// Explicit brightness-only recipes. Restore is authored, never inferred from a stale snapshot.
public struct ClockDisplaySchedule: Codable, Hashable, Sendable, Identifiable {
    public var displayID: DisplayRecordID
    public var entries: [ClockScheduleEntry]
    public var method: BrightnessMethodRequest
    public var restoreLevel: AutomationLevel
    public var rampMinutes: Int
    public var id: DisplayRecordID { displayID }

    public init(displayID: DisplayRecordID, entries: [ClockScheduleEntry], method: BrightnessMethodRequest,
                restoreLevel: AutomationLevel, rampMinutes: Int) {
        self.displayID = displayID
        self.entries = entries
        self.method = method
        self.restoreLevel = restoreLevel
        self.rampMinutes = rampMinutes
    }

    public var restoreRequest: AutomationRequest {
        .byID(.setBrightness(restoreLevel, method: method), displayID)
    }
}

public struct ClockModeConfiguration: Codable, Hashable, Sendable {
    /// nil follows the time zone supplied at evaluation; a named zone stays fixed when travelling.
    public var timeZoneIdentifier: String?
    public var resumePolicy: ClockResumePolicy
    public var displays: [ClockDisplaySchedule]

    public init(timeZoneIdentifier: String?, resumePolicy: ClockResumePolicy, displays: [ClockDisplaySchedule]) {
        self.timeZoneIdentifier = timeZoneIdentifier
        self.resumePolicy = resumePolicy
        self.displays = displays
    }

    public func timeZone(current: TimeZone) -> TimeZone? {
        guard let timeZoneIdentifier else { return current }
        return TimeZone(identifier: timeZoneIdentifier)
    }
}

/// Calendar evaluation uses real occurrences, so a repeated DST hour cannot run a transition twice
/// or revert to its previous interval. Missing wall times move to the first valid time after the gap.
public enum ClockCalendarPolicy {
    public struct Sample: Equatable, Sendable {
        public var level: AutomationLevel
        public var intervalStart: Date
    }

    private struct Point {
        var date: Date
        var entry: ClockScheduleEntry
    }

    public static func sample(at now: Date, schedule: ClockDisplaySchedule, timeZone: TimeZone,
                              coordinate: GeoCoordinate?) throws(AutomationIssue) -> Sample? {
        guard schedule.rampMinutes >= 0, Double(exactly: schedule.rampMinutes) != nil else {
            throw AutomationIssue(.invalidValue, "invalid Clock Mode ramp duration")
        }
        if let coordinate {
            guard coordinate.latitude.isFinite, coordinate.longitude.isFinite,
                  (-90...90).contains(coordinate.latitude), (-180...180).contains(coordinate.longitude) else {
                throw AutomationIssue(.invalidValue, "invalid Clock Mode solar coordinates")
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        // Adjacent calendar days define the cyclic segment containing now, including 23/25h days.
        let days = [-1, 0, 1].compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        var points: [Point] = []
        for day in days {
            let solar = coordinate.map { SolarCalculator.events(on: day, in: timeZone, coordinate: $0) }
            for entry in schedule.entries {
                guard (0..<1440).contains(entry.timeMinute),
                      AutomationLevel(normalized: Double(entry.brightness)) != nil,
                      !1440.addingReportingOverflow(entry.offsetMinutes).overflow,
                      !entry.offsetMinutes.subtractingReportingOverflow(1440).overflow else {
                    throw AutomationIssue(.invalidValue, "invalid Clock Mode schedule point")
                }
                // Resolve the legacy wrapped offset first: old saved schedules keep their meaning.
                guard let minute = ClockSchedulePolicy.resolvedMinute(for: entry, solar: solar),
                      let date = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0,
                                               of: day, matchingPolicy: .nextTime,
                                               repeatedTimePolicy: .first, direction: .forward) else { continue }
                points.append(Point(date: date, entry: entry))
            }
        }
        points.sort { $0.date < $1.date }
        // Coincident points have no unique prescribed state. Refuse instead of choosing array order.
        if zip(points, points.dropFirst()).contains(where: { $0.date == $1.date }) {
            throw AutomationIssue(.invalidValue, "Clock Mode schedule points coincide")
        }
        guard let previous = points.last(where: { $0.date <= now }) else { return nil }
        let upcoming = points.first { $0.date > now }
        let from = Double(previous.entry.brightness)
        var value = from
        if let upcoming {
            let gap = upcoming.date.timeIntervalSince(previous.date)
            let remaining = upcoming.date.timeIntervalSince(now)
            switch upcoming.entry.transition {
            case .instant: break
            case .continuous:
                value += (Double(upcoming.entry.brightness) - from) * (1 - remaining / gap)
            case .ramp:
                let width = min(Double(schedule.rampMinutes) * 60, gap)
                if width > 0, remaining < width {
                    value += (Double(upcoming.entry.brightness) - from) * (1 - remaining / width)
                }
            }
        }
        guard let level = AutomationLevel(normalized: value) else { return nil }
        return Sample(level: level, intervalStart: previous.date)
    }
}

/// Session state has no clock, timer, transport, retry budget or persistence side effects.
public struct ClockModeSession: Sendable {
    public enum Hold: Equatable, Sendable {
        case disabled, safeStartup, sleeping, resumePaused, manualOverride, competingPolicy, noAnchor, provisionalIdentity
    }
    public enum Decision: Equatable, Sendable {
        case hold(Hold)
        case request(AutomationRequest)
    }
    public private(set) var resumePaused = false
    private var manualIntervals: [DisplayRecordID: Date] = [:]

    public init() {}

    public mutating func didWake(policy: ClockResumePolicy) {
        resumePaused = policy == .pauseUntilResumed
    }

    public mutating func resume() {
        resumePaused = false
        manualIntervals.removeAll()
    }

    public mutating func noteManualChange(to id: DisplayRecordID, sample: ClockCalendarPolicy.Sample?) {
        manualIntervals[id] = sample?.intervalStart
    }

    /// A ramp's value changes while command preparation suspends. Its interval and hold policy
    /// determine eligibility; the request keeps the single level sampled at planning time.
    public func allowsDispatch(schedule: ClockDisplaySchedule, intervalStart: Date,
                               sample: ClockCalendarPolicy.Sample?, enabled: Bool, safeStartup: Bool,
                               sleeping: Bool, competingPolicy: Bool) -> Bool {
        guard sample?.intervalStart == intervalStart else { return false }
        if case .request = decision(schedule: schedule, sample: sample, enabled: enabled,
                                    safeStartup: safeStartup, sleeping: sleeping, competingPolicy: competingPolicy) {
            return true
        }
        return false
    }

    public func decision(schedule: ClockDisplaySchedule, sample: ClockCalendarPolicy.Sample?,
                         enabled: Bool, safeStartup: Bool, sleeping: Bool, competingPolicy: Bool) -> Decision {
        guard PersistentDisplayIdentity.isPersistent(schedule.displayID) else { return .hold(.provisionalIdentity) }
        if !enabled { return .hold(.disabled) }
        if safeStartup { return .hold(.safeStartup) }
        if sleeping { return .hold(.sleeping) }
        if resumePaused { return .hold(.resumePaused) }
        if competingPolicy { return .hold(.competingPolicy) }
        guard let sample else { return .hold(.noAnchor) }
        if manualIntervals[schedule.displayID] == sample.intervalStart { return .hold(.manualOverride) }
        return .request(.byID(.setBrightness(sample.level, method: schedule.method), schedule.displayID))
    }
}
