import XCTest
@testable import TopologyCore

/// SD-16 / TB-08 / TR-16: resolving a typed output name or UID, and native volume/mute steps.
final class AudioDeviceSelectorTests: XCTestCase {
    private let dellA = AudioOutputDevice(uid: "AppleGFXHDMI:1:A", name: "DELL U2720Q", transport: .hdmi)
    private let dellB = AudioOutputDevice(uid: "AppleGFXHDMI:2:B", name: "DELL U2720Q", transport: .hdmi)
    private let usb = AudioOutputDevice(uid: "USB-DAC-77", name: "Desk Speakers", transport: .usb,
                                        volume: .settable, mute: .settable, volumeLevel: 0.5, isMuted: false)
    private let headphones = AudioOutputDevice(uid: "BT-AirPods", name: "AirPods Pro", transport: .bluetooth,
                                               volume: .settable, mute: .absent, volumeLevel: 0.3)

    private var all: [AudioOutputDevice] { [dellA, dellB, usb, headphones] }

    func testBlankTextIsUnsetNeverTheFirstOutput() {
        XCTAssertEqual(AudioDeviceSelector.resolve(nil, in: all, strictness: .allowsFragment), .unset)
        XCTAssertEqual(AudioDeviceSelector.resolve("   ", in: all, strictness: .allowsFragment), .unset)
    }

    func testExactUIDDisambiguatesIdenticalMonitors() {
        XCTAssertEqual(AudioDeviceSelector.resolve("AppleGFXHDMI:2:B", in: all, strictness: .exact), .matched(dellB))
        XCTAssertEqual(AudioDeviceSelector.resolve("applegfxhdmi:1:a", in: all, strictness: .exact), .matched(dellA))
    }

    func testANameSharedByTwoOutputsIsAmbiguous() {
        XCTAssertEqual(AudioDeviceSelector.resolve("dell  u2720q", in: all, strictness: .exact),
                       .ambiguous([dellA, dellB]))
    }

    func testExactNameIsCaseAndSpacingInsensitive() {
        XCTAssertEqual(AudioDeviceSelector.resolve("  desk   SPEAKERS ", in: all, strictness: .exact), .matched(usb))
    }

    func testFragmentsOnlyWhereAllowedAndOnlyWhenUnique() {
        XCTAssertEqual(AudioDeviceSelector.resolve("speakers", in: all, strictness: .exact), .missing)
        XCTAssertEqual(AudioDeviceSelector.resolve("speakers", in: all, strictness: .allowsFragment), .matched(usb))
        XCTAssertEqual(AudioDeviceSelector.resolve("usb-dac", in: all, strictness: .allowsFragment), .matched(usb))
        XCTAssertEqual(AudioDeviceSelector.resolve("dell", in: all, strictness: .allowsFragment),
                       .ambiguous([dellA, dellB]))
    }

    func testDigitsAreKeptSoModelNumbersDoNotCollide() {
        let other = AudioOutputDevice(uid: "x", name: "DELL U2720", transport: .hdmi)
        XCTAssertEqual(AudioDeviceSelector.resolve("DELL U2720", in: [dellA, other], strictness: .exact),
                       .matched(other))
    }

    func testAbsentOutputIsMissing() {
        XCTAssertEqual(AudioDeviceSelector.resolve("Studio Display", in: all, strictness: .allowsFragment), .missing)
    }

    // MARK: - Capabilities

    func testVolumeAndMuteAreSeparateCapabilities() {
        XCTAssertTrue(headphones.volumeIsAdjustable)
        XCTAssertFalse(headphones.muteIsToggleable, "a volume-only output is not mute-capable")
        let muteOnly = AudioOutputDevice(uid: "m", name: "m", transport: .usb, volume: .readOnly, mute: .settable,
                                         volumeLevel: 0.4, isMuted: true)
        XCTAssertFalse(muteOnly.volumeIsAdjustable)
        XCTAssertTrue(muteOnly.muteIsToggleable)
        let unknownLevel = AudioOutputDevice(uid: "u", name: "u", transport: .usb, volume: .settable)
        XCTAssertFalse(unknownLevel.volumeIsAdjustable, "a step is never computed from an assumed level")
    }

    // MARK: - Native steps

    func testRaisingAMutedOutputUnmutesIt() {
        var muted = usb
        muted.isMuted = true
        let result = NativeVolumeStep.step(muted, delta: 0.0625)
        XCTAssertEqual(result?.level ?? -1, 0.5625, accuracy: 1e-6)
        XCTAssertEqual(result?.mute, false)
    }

    func testReachingTheMinimumMutesWhereMuteExists() {
        var low = usb
        low.volumeLevel = 0.05
        XCTAssertEqual(NativeVolumeStep.step(low, delta: -0.0625), .init(level: 0, mute: true))
        var quiet = headphones
        quiet.volumeLevel = 0.05
        XCTAssertEqual(NativeVolumeStep.step(quiet, delta: -0.0625), .init(level: 0, mute: nil),
                       "no mute control: the level alone is written")
    }

    func testOrdinaryStepsLeaveMuteAlone() {
        XCTAssertEqual(NativeVolumeStep.step(usb, delta: -0.0625), .init(level: 0.4375, mute: nil))
        XCTAssertEqual(NativeVolumeStep.step(usb, delta: 1), .init(level: 1, mute: nil))
    }

    func testUnsteppableOutputsReturnNil() {
        XCTAssertNil(NativeVolumeStep.step(dellA, delta: 0.1))
        XCTAssertNil(NativeVolumeStep.toggledMute(headphones))
        XCTAssertEqual(NativeVolumeStep.toggledMute(usb), true)
    }
}
