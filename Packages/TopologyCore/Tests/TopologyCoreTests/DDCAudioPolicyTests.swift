import XCTest
@testable import TopologyCore

final class DDCAudioPolicyTests: XCTestCase {
    private typealias Policy = DDCAudioPolicy

    // MARK: - Volume keys (TB-02)

    func testUnreadVolumeLeavesKeysToMacOS() {
        // The regression: capabilities not read yet used to count as "volume works", so the tap
        // swallowed keys for monitors with no working DDC volume.
        XCTAssertFalse(Policy.volumeKeysUsable(.init(volume: nil)))
    }

    func testConfirmedVolumeIsUsable() {
        XCTAssertTrue(Policy.volumeKeysUsable(.init(volume: 0.4)))
        XCTAssertTrue(Policy.volumeKeysUsable(.init(volume: 0)))
    }

    func testAdvertisedAbsenceOrFailedWriteDisqualifies() {
        XCTAssertFalse(Policy.volumeKeysUsable(.init(volume: 0.4, volumeAdvertised: false)))
        XCTAssertFalse(Policy.volumeKeysUsable(.init(volume: 0.4, volumeWriteFailed: true)))
    }

    // MARK: - Mute (TB-03)

    func testDiscreteMuteIsUsedWhenReadBack() {
        XCTAssertEqual(Policy.muteAction(.init(volume: 0.4, discreteMuted: false), remembered: nil),
                       .discrete(mute: true))
        XCTAssertEqual(Policy.muteAction(.init(volume: 0.4, discreteMuted: true), remembered: nil),
                       .discrete(mute: false))
        // Discrete mute doesn't depend on a readable volume.
        XCTAssertEqual(Policy.muteAction(.init(volume: nil, discreteMuted: false), remembered: nil),
                       .discrete(mute: true))
    }

    func testFailedDiscreteMuteFallsBackToVolume() {
        let capability = Policy.Capability(volume: 0.4, discreteMuted: false, muteWriteFailed: true)
        XCTAssertEqual(Policy.muteAction(capability, remembered: nil), .zeroVolume(remember: 0.4))
    }

    func testZeroVolumeFallbackRemembersTheLevel() {
        XCTAssertEqual(Policy.muteAction(.init(volume: 0.6), remembered: nil), .zeroVolume(remember: 0.6))
    }

    func testUnmuteRestoresOnlyARememberedLevel() {
        XCTAssertEqual(Policy.muteAction(.init(volume: 0), remembered: 0.6), .restore(level: 0.6))
        // The regression: an unknown prior level used to "restore" an invented 50 %.
        XCTAssertEqual(Policy.muteAction(.init(volume: 0), remembered: nil), .unavailable)
        XCTAssertEqual(Policy.muteAction(.init(volume: 0), remembered: 0), .unavailable)
    }

    func testNoAudioControlMeansNoMute() {
        XCTAssertEqual(Policy.muteAction(.init(volume: nil), remembered: 0.5), .unavailable)
        XCTAssertFalse(Policy.muteKeyUsable(.init(volume: nil), remembered: 0.5))
        XCTAssertFalse(Policy.muteKeyUsable(.init(volume: 0.5, volumeWriteFailed: true), remembered: nil))
        XCTAssertTrue(Policy.muteKeyUsable(.init(volume: 0.5), remembered: nil))
    }

    func testDiscreteMuteWireValues() {
        XCTAssertEqual(Policy.discreteMuteState(fromVCPValue: 1), true)
        XCTAssertEqual(Policy.discreteMuteState(fromVCPValue: 2), false)
        XCTAssertNil(Policy.discreteMuteState(fromVCPValue: 0))
        XCTAssertNil(Policy.discreteMuteState(fromVCPValue: 3))
        XCTAssertEqual(Policy.discreteMuteValue(mute: true), 1)
        XCTAssertEqual(Policy.discreteMuteValue(mute: false), 2)
    }
}
