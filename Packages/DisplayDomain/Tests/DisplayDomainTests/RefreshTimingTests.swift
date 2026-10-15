import XCTest
@testable import DisplayDomain

final class RefreshTimingTests: XCTestCase {
    private func mode(hz: Double, width: Int = 2560) -> DisplayMode {
        DisplayMode(pixelWidth: width, pixelHeight: 1440, pointWidth: width, pointHeight: 1440, refreshHz: hz, isHiDPI: false)
    }

    // MARK: Reported range

    func testReportedRangeRejectsReadingsThatAreNotIntervals() {
        XCTAssertNil(ReportedRefreshRange(minimumInterval: 0, maximumInterval: 1.0 / 60))
        XCTAssertNil(ReportedRefreshRange(minimumInterval: -1, maximumInterval: 1))
        XCTAssertNil(ReportedRefreshRange(minimumInterval: .nan, maximumInterval: 1))
        XCTAssertNil(ReportedRefreshRange(minimumInterval: 1.0 / 60, maximumInterval: .infinity))
        XCTAssertNil(ReportedRefreshRange(minimumInterval: 1.0 / 24, maximumInterval: 1.0 / 120), "minimum above maximum")
        let range = ReportedRefreshRange(minimumInterval: 1.0 / 120, maximumInterval: 1.0 / 24)
        XCTAssertEqual(range?.fastestHz ?? 0, 120, accuracy: 1e-9)
        XCTAssertEqual(range?.slowestHz ?? 0, 24, accuracy: 1e-9)
    }

    func testRangeTextSaysFixedOrVariableAsReported() {
        let l = ReportLocalizer.english
        XCTAssertEqual(RefreshTimingReport.rangeText(ReportedRefreshRange(minimumInterval: 1.0 / 60, maximumInterval: 1.0 / 60), l),
                       "60 Hz, fixed")
        XCTAssertEqual(RefreshTimingReport.rangeText(ReportedRefreshRange(minimumInterval: 1.0 / 120, maximumInterval: 1.0 / 48), l),
                       "48–120 Hz, variable")
        XCTAssertEqual(RefreshTimingReport.rangeText(nil, l), "Not reported")
    }

    // MARK: Meter

    func testNoDataIsNotZero() {
        var meter = FrameCadenceMeter()
        XCTAssertNil(meter.measuredHz)
        XCTAssertNil(meter.meanInterval)
        XCTAssertFalse(meter.hasData)
        meter.record(timestamp: 10)
        XCTAssertNil(meter.measuredHz, "one callback is no interval")
        XCTAssertEqual(meter.intervalCount, 0)
        XCTAssertEqual(meter.acceptedTimestamps, 1)
    }

    func testSteadyCallbacksMeasureTheirRate() throws {
        var meter = FrameCadenceMeter()
        for index in 0...60 { meter.record(timestamp: 100 + Double(index) / 60, reportedFrameDuration: 1.0 / 60) }
        XCTAssertEqual(meter.intervalCount, 60)
        XCTAssertEqual(try XCTUnwrap(meter.measuredHz), 60, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(meter.elapsed), 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(meter.intervalStandardDeviation), 0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(meter.reportedHz), 60, accuracy: 1e-9)
        XCTAssertEqual(meter.reportedDurationCount, 61)
    }

    func testIrregularCallbacksKeepTheirSpreadVisible() throws {
        var meter = FrameCadenceMeter()
        // Intervals 10, 20, 30 ms: mean 20 ms (50 Hz), sample standard deviation 10 ms.
        for time in [0.0, 0.010, 0.030, 0.060] { meter.record(timestamp: time) }
        XCTAssertEqual(try XCTUnwrap(meter.measuredHz), 50, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(meter.shortestInterval), 0.010, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(meter.longestInterval), 0.030, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(meter.latestInterval), 0.030, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(meter.intervalStandardDeviation), 0.010, accuracy: 1e-12)
        XCTAssertNil(meter.reportedHz, "no reported durations were supplied")
    }

    func testBadTimestampsAreCountedNotUsed() throws {
        var meter = FrameCadenceMeter()
        meter.record(timestamp: 1.0)
        meter.record(timestamp: .nan)
        meter.record(timestamp: 0.5)         // goes backwards
        meter.record(timestamp: 1.0)         // repeats
        meter.record(timestamp: 1.0 + 1.0 / 30, reportedFrameDuration: -1)
        meter.record(timestamp: 1.0 + 2.0 / 30, reportedFrameDuration: .infinity)
        XCTAssertEqual(meter.discardedTimestamps, 3)
        XCTAssertEqual(meter.discardedReportedDurations, 2)
        XCTAssertNil(meter.reportedHz)
        XCTAssertEqual(meter.intervalCount, 2)
        XCTAssertEqual(try XCTUnwrap(meter.measuredHz), 30, accuracy: 1e-9)
    }

    func testALongRunStaysExactWithoutKeepingSamples() throws {
        var meter = FrameCadenceMeter()
        let count = 500_000
        for index in 0...count { meter.record(timestamp: 5_000 + Double(index) / 120) }
        XCTAssertEqual(meter.intervalCount, count)
        XCTAssertEqual(try XCTUnwrap(meter.measuredHz), 120, accuracy: 1e-6)
    }

    // MARK: Session

    func testAMeasurementRunsOnlyBetweenStartAndStop() {
        var session = RefreshMeasurementSession()
        session.record(timestamp: 1, reportedFrameDuration: nil)
        session.record(timestamp: 2, reportedFrameDuration: nil)
        XCTAssertFalse(session.meter.hasData, "nothing is measured before Start")
        session.start(mode: mode(hz: 60))
        XCTAssertTrue(session.isRunning)
        session.record(timestamp: 10, reportedFrameDuration: nil)
        session.record(timestamp: 10.5, reportedFrameDuration: nil)
        session.stop(.user)
        session.record(timestamp: 11, reportedFrameDuration: nil)
        XCTAssertEqual(session.phase, .stopped(.user))
        XCTAssertEqual(session.meter.intervalCount, 1, "a stopped measurement keeps its result and takes no more")
        XCTAssertEqual(RefreshTimingReport.measurementRows(session, .english).first?.value, "Stopped by you")
        session.stop(.viewClosed)
        XCTAssertEqual(session.phase, .stopped(.user), "stopping twice keeps the first reason")
    }

    func testAModeChangeRestartsARunningMeasurementOnly() {
        var session = RefreshMeasurementSession()
        session.start(mode: mode(hz: 60))
        session.record(timestamp: 0, reportedFrameDuration: nil)
        session.record(timestamp: 1.0 / 60, reportedFrameDuration: nil)
        session.modeChanged(to: mode(hz: 60))
        XCTAssertEqual(session.meter.intervalCount, 1, "the same mode isn't a change")
        session.modeChanged(to: mode(hz: 60, width: 1920))
        XCTAssertEqual(session.meter.intervalCount, 0, "a different mode at the same rate still starts over")
        XCTAssertEqual(session.restartsForModeChange, 1)
        session.modeChanged(to: mode(hz: 144))
        XCTAssertEqual(session.nominalHz, 144)
        session.stop(.displayUnavailable)
        session.modeChanged(to: mode(hz: 60))
        XCTAssertEqual(session.nominalHz, 144, "a stopped result stays labelled with the mode it measured")
        session.start(mode: mode(hz: 60))
        XCTAssertEqual(session.restartsForModeChange, 0)
    }

    // MARK: Report rows

    func testNominalReportedAndMeasuredHaveSeparateRows() {
        var session = RefreshMeasurementSession()
        session.start(mode: mode(hz: 60))
        for index in 0...120 { session.record(timestamp: Double(index) / 60, reportedFrameDuration: 1.0 / 60) }
        let section = RefreshTimingReport.section(
            nominalHz: 59.94, range: ReportedRefreshRange(minimumInterval: 1.0 / 120, maximumInterval: 1.0 / 48),
            session: session)
        let rows = Dictionary(uniqueKeysWithValues: section.rows.map { ($0.label, $0.value) })
        XCTAssertEqual(rows["Mode rate (nominal)"], "59.94 Hz")
        XCTAssertEqual(rows["Refresh range macOS reports"], "48–120 Hz, variable")
        XCTAssertEqual(rows["Measurement"], "Measuring")
        XCTAssertEqual(rows["Measured cadence"], "60 Hz average over 120 intervals (2 s)")
        XCTAssertEqual(rows["Frame duration the display link reports"], "16.67 ms (60 Hz)")
        XCTAssertNil(rows["Callbacks not counted"], "nothing was discarded")
        XCTAssertTrue(section.notes.contains { $0.contains("not the panel’s or the cable’s timing") })
    }

    func testAnIdleSessionAddsNoMeasurementAndAZeroRateIsNotStated() {
        let section = RefreshTimingReport.section(nominalHz: 0, range: nil, session: RefreshMeasurementSession())
        XCTAssertEqual(section.rows.map(\.label), ["Mode rate (nominal)", "Refresh range macOS reports"])
        XCTAssertEqual(section.rows.first?.value, "Not stated by the mode")
        var started = RefreshMeasurementSession()
        started.start(mode: nil)
        let rows = RefreshTimingReport.measurementRows(started, .english)
        XCTAssertEqual(rows.first { $0.label == "Measured cadence" }?.value, "No intervals yet")
    }

    func testStopReasonsAndDiscardsAreStated() {
        var session = RefreshMeasurementSession()
        session.start(mode: mode(hz: 60))
        session.record(timestamp: 1, reportedFrameDuration: nil)
        session.record(timestamp: .nan, reportedFrameDuration: nil)
        session.stop(.displayUnavailable)
        let rows = Dictionary(uniqueKeysWithValues: RefreshTimingReport.measurementRows(session, .english).map { ($0.label, $0.value) })
        XCTAssertEqual(rows["Measurement"], "Stopped: the display is no longer available")
        XCTAssertEqual(rows["Callbacks not counted"], "1 (timestamp missing or out of order)")
    }
}
