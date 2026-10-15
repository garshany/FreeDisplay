import XCTest
@testable import DisplayDomain

/// TR-06 / owner decision #4: identical serial-less monitors stay refused until the user pairs one
/// with a channel they watched respond; the pairing is keyed by stable identity, applies only on the
/// evidence it was confirmed on, and never lets two displays share a channel.
final class DDCChannelMappingTests: XCTestCase {
    /// Two identical monitors: same vendor and model, no serial on either side.
    private let twin = DDCServiceMatcher.Target(vendorNumber: 0x10AC, productNumber: 0xA0B1, serialNumber: 0)
    private let left = DisplayRecordID.forCGUUID("LEFT")
    private let right = DisplayRecordID.forCGUUID("RIGHT")
    private let modelOnly = DDCServiceMatcher.Candidate(legacyManufacturerID: 0x10AC, productID: 0xA0B1)
    private let date = Date(timeIntervalSince1970: 100)

    private var channels: [DDCChannel] {
        [DDCChannel(path: "IOService:/dcpext0/DCPAVServiceProxy", attributes: modelOnly),
         DDCChannel(path: "IOService:/dcpext1/DCPAVServiceProxy", attributes: modelOnly)]
    }

    private func pairing(_ display: DisplayRecordID, _ channel: Int) -> DDCChannelMapping {
        DDCChannelMappingPolicy.confirm(displayID: display, displayIdentity: twin, channel: channels[channel], at: date)!
    }

    func testIdenticalTwinsStayRefusedWithoutAPairing() {
        let result = DDCChannelMappingPolicy.resolve(channels: channels, target: twin, externals: [twin, twin],
                                                     displayID: left, mapping: nil, otherMappings: [])
        XCTAssertEqual(result.resolution, .refused(.ambiguousIdentity))
        XCTAssertNil(result.status)
    }

    func testAConfirmedPairingBindsExactlyThatChannel() {
        let result = DDCChannelMappingPolicy.resolve(channels: channels, target: twin, externals: [twin, twin],
                                                     displayID: left, mapping: pairing(left, 1),
                                                     otherMappings: [pairing(right, 0)])
        XCTAssertEqual(result.resolution, .matched(index: 1))
        XCTAssertEqual(result.status, .inUse(channelIndex: 1))
    }

    /// Never by a numeric display id: such a display can't be paired, and a pairing never applies to it.
    func testOnlyAStableIDCanBePaired() {
        let numeric = DisplayRecordID(rawValue: "cgid:3")
        XCTAssertFalse(DDCChannelMappingPolicy.canPair(numeric))
        XCTAssertNil(DDCChannelMappingPolicy.confirm(displayID: numeric, displayIdentity: twin,
                                                     channel: channels[0], at: date))
        var forged = pairing(left, 0)
        forged.displayID = numeric
        let result = DDCChannelMappingPolicy.resolve(channels: channels, target: twin, externals: [twin, twin],
                                                     displayID: numeric, mapping: forged, otherMappings: [])
        XCTAssertEqual(result.resolution, .refused(.ambiguousIdentity))
        XCTAssertEqual(result.status, .invalid(.unstableDisplayID))
        XCTAssertNil(DDCChannelMappingPolicy.confirm(displayID: left, displayIdentity: twin,
                                                     channel: DDCChannel(path: "", attributes: nil), at: date))
    }

    func testChangedEvidenceMakesThePairingInert() {
        func status(target: DDCServiceMatcher.Target = DDCServiceMatcher.Target(vendorNumber: 0x10AC, productNumber: 0xA0B1, serialNumber: 0),
                    channels: [DDCChannel]? = nil) -> DDCChannelMappingPolicy.Status? {
            DDCChannelMappingPolicy.resolve(channels: channels ?? self.channels, target: target,
                                            externals: [target, twin], displayID: left,
                                            mapping: pairing(left, 1), otherMappings: []).status
        }
        XCTAssertEqual(status(target: .init(vendorNumber: 0x10AC, productNumber: 0xA0B1, serialNumber: 77)),
                       .invalid(.displayIdentityChanged), "a serial appearing is changed evidence too")
        let serialled = [DDCChannel(path: channels[0].path, attributes: .init(legacyManufacturerID: 0x10AC, productID: 0xA0B1, serialNumber: 1)),
                         DDCChannel(path: channels[1].path, attributes: .init(legacyManufacturerID: 0x10AC, productID: 0xA0B1, serialNumber: 2))]
        XCTAssertEqual(DDCChannelMappingPolicy.resolve(
            channels: serialled, target: .init(vendorNumber: 0x10AC, productNumber: 0xA0B1, serialNumber: 2),
            externals: [.init(vendorNumber: 0x10AC, productNumber: 0xA0B1, serialNumber: 1),
                        .init(vendorNumber: 0x10AC, productNumber: 0xA0B1, serialNumber: 2)],
            displayID: left, mapping: pairing(left, 0), otherMappings: []).status,
                       .notNeeded, "where identity decides, the pairing isn't consulted")
        XCTAssertEqual(status(target: .init(vendorNumber: 0x10AC, productNumber: 0xA0B2, serialNumber: 0)),
                       .invalid(.displayIdentityChanged))
        XCTAssertEqual(status(channels: [channels[0]]), .invalid(.channelMissing))
        var relabelled = channels
        relabelled[1].attributes = DDCServiceMatcher.Candidate(legacyManufacturerID: 0x10AC)
        XCTAssertEqual(status(channels: relabelled), .invalid(.channelIdentityChanged))
    }

    func testAChannelNamingAnotherMonitorIsNeverPaired() {
        let other = DDCServiceMatcher.Candidate(legacyManufacturerID: 0x4C2D, productID: 1)
        let mixed = [channels[0], DDCChannel(path: "IOService:/dcpext1/DCPAVServiceProxy", attributes: other)]
        let stale = DDCChannelMappingPolicy.confirm(displayID: left, displayIdentity: twin, channel: mixed[1], at: date)!
        let result = DDCChannelMappingPolicy.validate(stale, displayID: left, target: twin, channels: mixed,
                                                      externals: [twin, twin], otherMappings: [])
        XCTAssertEqual(result, .failure(.channelContradictsDisplay))
    }

    /// Two displays never share a channel: not through two pairings, and not by pairing the channel
    /// identity already gave to a third monitor.
    func testAChannelIsNeverShared() {
        let doubled = DDCChannelMappingPolicy.resolve(channels: channels, target: twin, externals: [twin, twin],
                                                      displayID: left, mapping: pairing(left, 0),
                                                      otherMappings: [pairing(right, 0)])
        XCTAssertEqual(doubled.resolution, .refused(.ambiguousIdentity))
        XCTAssertEqual(doubled.status, .invalid(.channelClaimedByAnotherDisplay))

        let third = DDCServiceMatcher.Target(vendorNumber: 0x4C2D, productNumber: 7, serialNumber: 99)
        let withThird = channels + [DDCChannel(path: "IOService:/dcpext2/DCPAVServiceProxy",
                                               attributes: .init(legacyManufacturerID: 0x4C2D, productID: 7, serialNumber: 99))]
        let wrong = DDCChannelMappingPolicy.confirm(displayID: left, displayIdentity: twin, channel: withThird[2], at: date)!
        let result = DDCChannelMappingPolicy.validate(wrong, displayID: left, target: twin, channels: withThird,
                                                      externals: [twin, twin, third], otherMappings: [])
        XCTAssertEqual(result, .failure(.channelContradictsDisplay))
        let unlabelledThird = channels + [DDCChannel(path: "IOService:/dcpext2/DCPAVServiceProxy",
                                                     attributes: .init(serialNumber: 99))]
        let borrowed = DDCChannelMappingPolicy.confirm(displayID: left, displayIdentity: twin,
                                                       channel: unlabelledThird[2], at: date)!
        XCTAssertEqual(DDCChannelMappingPolicy.validate(borrowed, displayID: left, target: twin, channels: unlabelledThird,
                                                        externals: [twin, twin, third], otherMappings: []),
                       .failure(.channelClaimedByAnotherDisplay))
    }

    func testRefusalsAPairingMustNotLift() {
        XCTAssertTrue(DDCChannelMappingPolicy.isLiftable(.ambiguousIdentity))
        XCTAssertTrue(DDCChannelMappingPolicy.isLiftable(.unidentified))
        XCTAssertFalse(DDCChannelMappingPolicy.isLiftable(.appleDisplay))
        XCTAssertFalse(DDCChannelMappingPolicy.isLiftable(.contradictingIdentity))
        let other = DDCServiceMatcher.Candidate(legacyManufacturerID: 0x4C2D, productID: 1)
        let lone = [DDCChannel(path: "IOService:/dcpext0/DCPAVServiceProxy", attributes: other)]
        let mapping = DDCChannelMappingPolicy.confirm(displayID: left, displayIdentity: twin, channel: lone[0], at: date)
        let result = DDCChannelMappingPolicy.resolve(channels: lone, target: twin, externals: [twin],
                                                     displayID: left, mapping: mapping, otherMappings: [])
        XCTAssertEqual(result.resolution, .refused(.contradictingIdentity))
        XCTAssertEqual(result.status, .notNeeded)
    }

    func testSavingReplacesTheDisplaysPairingAndDisplacesTheChannelsOldOwner() {
        let existing = [pairing(left, 0), pairing(right, 1)]
        let moved = pairing(left, 1)
        XCTAssertEqual(DDCChannelMappingPolicy.displaced(by: moved, in: existing), [right])
        XCTAssertEqual(DDCChannelMappingPolicy.saving(moved, into: existing), [moved])
    }

    func testAPairingRoundTrips() throws {
        let saved = pairing(left, 1)
        let decoded = try JSONDecoder().decode(DDCChannelMapping.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded, saved)
    }

    // MARK: - Test flash

    func testTheFlashGoesToTheFarEndAndBack() async {
        XCTAssertEqual(DDCChannelTest.flashLevel(current: 70, max: 100), 0)
        XCTAssertEqual(DDCChannelTest.flashLevel(current: 50, max: 100), 0)
        XCTAssertEqual(DDCChannelTest.flashLevel(current: 20, max: 100), 100)
        var writes: [Int] = []
        var held = false
        let outcome = await DDCChannelTest.run(read: { (current: 30, max: 100) },
                                               write: { writes.append($0); return true },
                                               hold: { held = true })
        XCTAssertEqual(outcome, .flashed(original: 30, flashLevel: 100, restored: true))
        XCTAssertEqual(writes, [100, 30])
        XCTAssertTrue(held)
    }

    func testNothingIsWrittenWithoutALevelToPutBack() async {
        var writes: [Int] = []
        let silent = await DDCChannelTest.run(read: { nil }, write: { writes.append($0); return true }, hold: {})
        XCTAssertEqual(silent, .noReply)
        let zeroRange = await DDCChannelTest.run(read: { (current: 0, max: 0) },
                                                 write: { writes.append($0); return true }, hold: {})
        XCTAssertEqual(zeroRange, .noReply)
        XCTAssertTrue(writes.isEmpty)
    }

    func testAFailedFlashStillPutsTheLevelBack() async {
        var writes: [Int] = []
        let outcome = await DDCChannelTest.run(read: { (current: 80, max: 100) },
                                               write: { writes.append($0); return $0 == 80 },
                                               hold: { XCTFail("no hold after a failed flash") })
        XCTAssertEqual(outcome, .flashWriteFailed(original: 80, restored: true))
        XCTAssertEqual(writes, [0, 80])
    }
}
