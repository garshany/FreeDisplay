// SPDX-License-Identifier: GPL-3.0-or-later
// Original clean-room implementation for FreeDisplay (AM-13, TR T04, FB T10).
import Foundation

/// The refresh-interval range macOS states for a screen (`NSScreen.minimumRefreshInterval` and
/// `maximumRefreshInterval`). A real range is what a variable-refresh display reports; a fixed
/// one reports the same interval twice. Nil-constructed from anything that isn't a usable pair of
/// intervals, so no rate is ever derived from a missing or zero reading.
public struct ReportedRefreshRange: Hashable, Sendable {
    /// Shortest frame interval in seconds — the fastest rate.
    public let minimumInterval: Double
    /// Longest frame interval in seconds — the slowest rate.
    public let maximumInterval: Double

    public init?(minimumInterval: Double, maximumInterval: Double) {
        guard minimumInterval.isFinite, maximumInterval.isFinite,
              minimumInterval > 0, maximumInterval >= minimumInterval else { return nil }
        self.minimumInterval = minimumInterval
        self.maximumInterval = maximumInterval
    }

    public var fastestHz: Double { 1 / minimumInterval }
    public var slowestHz: Double { 1 / maximumInterval }
}

/// Running statistics of display-link callbacks, built from timestamps the caller supplies (in
/// seconds, on one monotonic clock). It keeps no list of samples, so a measurement can run for as
/// long as the user leaves it running without growing; nothing here decides how long that is.
///
/// What it measures is how often macOS called the display link — the operating system's frame
/// timing for that screen — not the panel's scan-out or the cable's timing.
public struct FrameCadenceMeter: Hashable, Sendable {
    /// Callbacks whose timestamp was used.
    public private(set) var acceptedTimestamps = 0
    /// Callbacks whose timestamp wasn't finite or didn't come after the previous one. Counted, not
    /// silently dropped, so a reading built on a disturbed clock says so.
    public private(set) var discardedTimestamps = 0
    public private(set) var firstTimestamp: Double?
    public private(set) var lastTimestamp: Double?
    /// The interval between the last two accepted callbacks.
    public private(set) var latestInterval: Double?
    public private(set) var shortestInterval: Double?
    public private(set) var longestInterval: Double?
    // Welford's running mean and sum of squared deviations of the intervals.
    private var intervalMean = 0.0
    private var intervalSquaredDeviations = 0.0

    /// Frame durations the display link itself reported (its target time minus its timestamp).
    public private(set) var reportedDurationCount = 0
    public private(set) var discardedReportedDurations = 0
    public private(set) var latestReportedDuration: Double?
    private var reportedDurationMean = 0.0

    public init() {}

    /// Intervals measured: one fewer than the accepted timestamps.
    public var intervalCount: Int { max(0, acceptedTimestamps - 1) }

    public mutating func record(timestamp: Double, reportedFrameDuration: Double? = nil) {
        if let duration = reportedFrameDuration {
            if duration.isFinite, duration > 0 {
                reportedDurationCount += 1
                reportedDurationMean += (duration - reportedDurationMean) / Double(reportedDurationCount)
                latestReportedDuration = duration
            } else {
                discardedReportedDurations += 1
            }
        }
        guard timestamp.isFinite else {
            discardedTimestamps += 1
            return
        }
        guard let previous = lastTimestamp else {
            firstTimestamp = timestamp
            lastTimestamp = timestamp
            acceptedTimestamps = 1
            return
        }
        guard timestamp > previous else {
            discardedTimestamps += 1
            return
        }
        let interval = timestamp - previous
        acceptedTimestamps += 1
        lastTimestamp = timestamp
        latestInterval = interval
        shortestInterval = min(shortestInterval ?? interval, interval)
        longestInterval = max(longestInterval ?? interval, interval)
        let count = Double(intervalCount)
        let delta = interval - intervalMean
        intervalMean += delta / count
        intervalSquaredDeviations += delta * (interval - intervalMean)
    }

    /// Seconds from the first to the last accepted callback; nil before two callbacks.
    public var elapsed: Double? {
        guard intervalCount > 0, let first = firstTimestamp, let last = lastTimestamp else { return nil }
        return last - first
    }

    /// The mean interval — the whole span divided by the intervals in it, so it doesn't drift
    /// with rounding however long the run. Nil before two callbacks: no data is not zero.
    public var meanInterval: Double? {
        elapsed.map { $0 / Double(intervalCount) }
    }

    /// The measured cadence in Hz, from `meanInterval`.
    public var measuredHz: Double? { meanInterval.map { 1 / $0 } }

    /// Sample standard deviation of the intervals; nil before three callbacks.
    public var intervalStandardDeviation: Double? {
        guard intervalCount > 1 else { return nil }
        return (max(0, intervalSquaredDeviations) / Double(intervalCount - 1)).squareRoot()
    }

    public var meanReportedDuration: Double? {
        reportedDurationCount > 0 ? reportedDurationMean : nil
    }

    /// The rate the display link's own reported frame durations imply.
    public var reportedHz: Double? { meanReportedDuration.map { 1 / $0 } }

    public var hasData: Bool { intervalCount > 0 || reportedDurationCount > 0 }
}

/// One user-run refresh measurement: it starts only when asked, stops when asked (or when the view
/// showing it closes, or the display goes away), and restarts when the display's mode changes
/// underneath it, so one result never mixes two modes. Pure state; the app feeds it display-link
/// callbacks while it is running and ignores none of the rules here.
public struct RefreshMeasurementSession: Hashable, Sendable {
    public enum Phase: Hashable, Sendable {
        case idle
        case running
        case stopped(StopReason)
    }

    public enum StopReason: Hashable, Sendable {
        case user
        /// The view showing the measurement closed.
        case viewClosed
        /// The display left, or its screen could no longer be found.
        case displayUnavailable
    }

    public private(set) var phase: Phase = .idle
    public private(set) var meter = FrameCadenceMeter()
    /// The display mode being measured; nil when macOS didn't report one.
    public private(set) var mode: DisplayMode?
    /// How many times this run started over because the mode changed while it was running.
    public private(set) var restartsForModeChange = 0

    public init() {}

    public var isRunning: Bool { phase == .running }

    /// The nominal rate of the mode being measured (nil, or 0: the mode states none).
    public var nominalHz: Double? { mode?.refreshHz }

    public mutating func start(mode: DisplayMode?) {
        phase = .running
        meter = FrameCadenceMeter()
        self.mode = mode
        restartsForModeChange = 0
    }

    /// Stops a running measurement and keeps its result. Stopping anything else changes nothing.
    public mutating func stop(_ reason: StopReason) {
        guard phase == .running else { return }
        phase = .stopped(reason)
    }

    /// Feeds one display-link callback; ignored unless running.
    public mutating func record(timestamp: Double, reportedFrameDuration: Double?) {
        guard phase == .running else { return }
        meter.record(timestamp: timestamp, reportedFrameDuration: reportedFrameDuration)
    }

    /// The display's mode is now `mode`. A running measurement starts over for the new mode; a
    /// stopped result stays as it is, still labelled with the mode it measured.
    public mutating func modeChanged(to mode: DisplayMode?) {
        guard phase == .running, mode != self.mode else { return }
        meter = FrameCadenceMeter()
        self.mode = mode
        restartsForModeChange += 1
    }
}

/// Words nominal, reported and measured refresh as report rows, each under its own label — the
/// mode's nominal rate, the range macOS reports, the display link's own frame duration and the
/// cadence measured from its callbacks are four different things and never share a row.
public enum RefreshTimingReport {
    public static func section(nominalHz: Double?, range: ReportedRefreshRange?,
                               session: RefreshMeasurementSession? = nil,
                               _ l: ReportLocalizer = .english) -> InfoReport.Section {
        var section = InfoReport.Section(title: l("Refresh timing"))
        section.rows.append(.init(l("Mode rate (nominal)"), nominalText(nominalHz, l)))
        section.rows.append(.init(l("Refresh range macOS reports"), rangeText(range, l)))
        if let session { section.rows.append(contentsOf: measurementRows(session, l)) }
        section.notes = [
            l("The nominal rate is what the display mode states. A variable range is shown only when macOS reports one."),
            l("A measured cadence is how often macOS asked for frames on this screen, not the panel’s or the cable’s timing. With variable refresh or a busy system it can differ from the nominal rate, and both readings are valid."),
            l("The connection’s own timing (link rate) isn’t read by this version."),
        ]
        return section
    }

    public static func nominalText(_ hz: Double?, _ l: ReportLocalizer) -> String {
        guard let hz, hz.isFinite, hz > 0 else { return l("Not stated by the mode") }
        return hzText(hz, l)
    }

    /// The range at the precision shown: two readings that print alike are one rate.
    public static func rangeText(_ range: ReportedRefreshRange?, _ l: ReportLocalizer) -> String {
        guard let range else { return l("Not reported") }
        let fastest = l.decimal(range.fastestHz, 2), slowest = l.decimal(range.slowestHz, 2)
        if fastest == slowest { return l.fill("%1 Hz, fixed", fastest) }
        return l.fill("%1–%2 Hz, variable", slowest, fastest)
    }

    public static func measurementRows(_ session: RefreshMeasurementSession,
                                       _ l: ReportLocalizer) -> [InfoReport.Row] {
        let meter = session.meter
        var rows: [InfoReport.Row] = []
        let state: String
        switch session.phase {
        case .idle: return []
        case .running: state = l("Measuring")
        case .stopped(.user): state = l("Stopped")
        case .stopped(.viewClosed): state = l("Stopped when the view closed")
        case .stopped(.displayUnavailable): state = l("Stopped: the display is no longer available")
        }
        rows.append(.init(l("Measurement"), state))
        if session.restartsForModeChange > 0 {
            rows.append(.init(l("Restarted for a mode change"), "\(session.restartsForModeChange)"))
        }
        if let hz = meter.measuredHz, let elapsed = meter.elapsed {
            rows.append(.init(l("Measured cadence"), l.fill("%1 average over %2 intervals (%3 s)",
                                                             hzText(hz, l), "\(meter.intervalCount)",
                                                             l.decimal(elapsed, 1))))
        } else {
            rows.append(.init(l("Measured cadence"), l("No intervals yet")))
        }
        if let latest = meter.latestInterval {
            rows.append(.init(l("Latest interval"), msText(latest, l)))
        }
        if let shortest = meter.shortestInterval, let longest = meter.longestInterval {
            rows.append(.init(l("Shortest / longest interval"),
                              l.fill("%1 / %2", msText(shortest, l), msText(longest, l))))
        }
        if let deviation = meter.intervalStandardDeviation {
            rows.append(.init(l("Interval variation (standard deviation)"), msText(deviation, l)))
        }
        if let duration = meter.meanReportedDuration, let hz = meter.reportedHz {
            rows.append(.init(l("Frame duration the display link reports"),
                              l.fill("%1 (%2)", msText(duration, l), hzText(hz, l))))
        }
        if meter.discardedTimestamps > 0 {
            rows.append(.init(l("Callbacks not counted"), l.fill("%1 (timestamp missing or out of order)",
                                                                  "\(meter.discardedTimestamps)")))
        }
        return rows
    }

    static func hzText(_ hz: Double, _ l: ReportLocalizer) -> String { l.fill("%1 Hz", l.decimal(hz, 2)) }

    static func msText(_ seconds: Double, _ l: ReportLocalizer) -> String {
        l.fill("%1 ms", l.decimal(seconds * 1000, 2))
    }
}
