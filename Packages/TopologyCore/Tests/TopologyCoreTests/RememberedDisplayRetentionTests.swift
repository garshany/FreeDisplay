import XCTest
import DisplayDomain
@testable import TopologyCore

/// SD-09 / SD-10 / FB-13: automatic forgetting is off unless the user sets a period, counts real
/// elapsed days, and never touches a display that is here, owed a way back, or might be here.
final class RememberedDisplayRetentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000_000)
    private let day: TimeInterval = 86_400

    private func entry(status: RememberedDisplay.Status = .notConnected, lastSeen: Date?,
                       registered: Bool = true, provisional: Bool = false, mayBeConnected: Bool = false,
                       displayClass: DisplayClass = .external,
                       ledger: [ManagedOfflineDisplay] = []) -> RememberedDisplay {
        let record = DisplayRecord(id: .init(rawValue: "disp_a"), fingerprint: DisplayFingerprint(vendorID: 1, productID: 1),
                                   displayClass: displayClass, lastSeen: lastSeen,
                                   unresolvedCandidates: provisional ? [] : nil)
        return RememberedDisplay(id: "disp_a", record: record, isRegistered: registered,
                                 observationIDs: [.forCGUUID("A")], status: status, offlineEntries: ledger,
                                 mayBeConnectedDisplay: mayBeConnected)
    }

    func testOffUnlessAPositiveNumberOfDaysIsSet() {
        let old = entry(lastSeen: now.addingTimeInterval(-1000 * day))
        XCTAssertEqual(RememberedDisplayRetention.verdict(for: old, days: nil, now: now), .off)
        XCTAssertEqual(RememberedDisplayRetention.verdict(for: old, days: 0, now: now), .off,
                       "zero is off, never 'forget at once'")
        XCTAssertEqual(RememberedDisplayRetention.verdict(for: old, days: -3, now: now), .off)
        XCTAssertNil(RememberedDisplayRetention.normalizedDays(0))
        XCTAssertEqual(RememberedDisplayRetention.normalizedDays(400), 400, "no upper bound of our own")
    }

    /// Days are days: 86 400 seconds each, measured from the last time the display was seen.
    func testThePeriodIsRealElapsedDays() {
        let justInside = entry(lastSeen: now.addingTimeInterval(-day + 1))
        XCTAssertEqual(RememberedDisplayRetention.verdict(for: justInside, days: 1, now: now),
                       .keptUntil(now.addingTimeInterval(1)))
        let exactly = entry(lastSeen: now.addingTimeInterval(-day))
        XCTAssertEqual(RememberedDisplayRetention.verdict(for: exactly, days: 1, now: now), .due(since: now))
        let recent = entry(lastSeen: now.addingTimeInterval(-89 * day))
        XCTAssertEqual(RememberedDisplayRetention.verdict(for: recent, days: 90, now: now),
                       .keptUntil(now.addingTimeInterval(day)))
    }

    func testDisplaysThatAreHereOrOwedAWayBackAreExempt() {
        let long = now.addingTimeInterval(-500 * day)
        let failed = ManagedOfflineDisplay(recordID: .forCGUUID("A"), cgID: 3, name: "A", displayClass: .external,
                                           reconnectFailedAt: long)
        let cases: [(RememberedDisplay, RememberedDisplayRetention.Exemption)] = [
            (entry(status: .connected, lastSeen: long), .connected),
            (entry(status: .turnedOff, lastSeen: long), .turnedOffByApp),
            (entry(status: .reconnectFailed, lastSeen: long, ledger: [failed]), .reconnectFailed),
            (entry(lastSeen: long, registered: false), .notRegistered),
            (entry(lastSeen: long, provisional: true), .provisional),
            (entry(lastSeen: long, mayBeConnected: true), .mayBeConnectedDisplay),
            (entry(lastSeen: long, displayClass: .virtual), .virtualDisplay),
            (entry(lastSeen: nil), .unknownLastSeen),
        ]
        for (candidate, exemption) in cases {
            XCTAssertEqual(RememberedDisplayRetention.verdict(for: candidate, days: 1, now: now), .exempt(exemption))
        }
        XCTAssertTrue(RememberedDisplayRetention.dueEntries(cases.map(\.0), days: 1, now: now).isEmpty)
    }

    func testDueEntriesAreOnlyTheExpiredOnes() {
        let expired = entry(lastSeen: now.addingTimeInterval(-31 * day))
        var fresh = entry(lastSeen: now.addingTimeInterval(-2 * day))
        fresh.id = "disp_fresh"
        XCTAssertEqual(RememberedDisplayRetention.dueEntries([expired, fresh], days: 30, now: now).map(\.id), ["disp_a"])
    }

    func testTheSettingDefaultsOffAndRoundTrips() throws {
        XCTAssertNil(OpenDisplaySettings().rememberedDisplayRetentionDays)
        var settings = OpenDisplaySettings()
        settings.rememberedDisplayRetentionDays = 120
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(OpenDisplaySettings.self, from: data).rememberedDisplayRetentionDays, 120)
        let edited = Data(#"{"rememberedDisplayRetentionDays": 0}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(OpenDisplaySettings.self, from: edited).rememberedDisplayRetentionDays)
        let older = Data("{}".utf8)
        XCTAssertNil(try JSONDecoder().decode(OpenDisplaySettings.self, from: older).rememberedDisplayRetentionDays)
    }
}
