import XCTest
@testable import TopologyCore

final class NativeAudioAdjustmentTests: XCTestCase {
    @MainActor
    private final class Audio: NativeAudioControlling {
        var output: AudioOutputDevice? = .init(uid: "USB", name: "Speakers", transport: .usb,
                                              volume: .settable, mute: .settable,
                                              volumeLevel: 0.25, isMuted: true)
        var writes: [String] = []
        var rejectVolume = false
        var partiallyRejectVolume = false
        var rejectMute = false
        var disappearAfterWrite = false

        func device(uid: String) -> AudioOutputDevice? { output?.uid == uid ? output : nil }
        func setVolume(_ level: Float, uid: String) -> NativeAudioWriteResult {
            writes.append("volume:\(uid):\(level)")
            guard !rejectVolume else { return .rejected }
            if partiallyRejectVolume { return .partial }
            output?.volumeLevel = level
            if disappearAfterWrite { output = nil }
            return .accepted
        }
        func setMute(_ muted: Bool, uid: String) -> NativeAudioWriteResult {
            writes.append("mute:\(uid):\(muted)")
            guard !rejectMute else { return .rejected }
            output?.isMuted = muted
            return .accepted
        }
    }

    @MainActor func testRelativeStepUsesFreshUIDLevelAndUnmutesAfterVolume() async {
        let audio = Audio()
        let outcome = NativeAudioAdjustment.apply(.volumeUp, uid: "USB", delta: 0.0625, controller: audio)
        XCTAssertTrue(outcome.handled)
        XCTAssertEqual(audio.writes, ["volume:USB:0.3125", "mute:USB:false"])
        XCTAssertEqual(outcome, .accepted(audio.output))
    }

    @MainActor func testMissingUIDNeverWritesAnotherOutput() async {
        let audio = Audio()
        XCTAssertEqual(NativeAudioAdjustment.apply(.volumeUp, uid: "gone", delta: 0.1, controller: audio), .unavailable)
        XCTAssertTrue(audio.writes.isEmpty)
    }

    @MainActor func testFailedVolumeDoesNotUnmuteAndDoesNotConsumeKey() async {
        let audio = Audio()
        audio.rejectVolume = true
        let result = NativeAudioAdjustment.apply(.volumeUp, uid: "USB", delta: 0.0625, controller: audio)
        XCTAssertEqual(result, .failed(partiallyApplied: false))
        XCTAssertFalse(result.handled)
        XCTAssertEqual(audio.writes, ["volume:USB:0.3125"])
        XCTAssertEqual(audio.output?.volumeLevel, 0.25)
    }

    @MainActor func testPartialFailureIsExplicitAndNeverRetriesAnotherDevice() async {
        let audio = Audio()
        audio.rejectMute = true
        let result = NativeAudioAdjustment.apply(.volumeUp, uid: "USB", delta: 0.0625, controller: audio)
        XCTAssertEqual(result, .failed(partiallyApplied: true))
        XCTAssertTrue(result.handled, "volume was changed, so macOS must not perform a second adjustment")
        XCTAssertEqual(audio.writes.count, 2)
    }

    @MainActor func testAcceptedWriteDoesNotFabricateReadback() async {
        let audio = Audio()
        audio.output?.isMuted = false
        audio.disappearAfterWrite = true
        XCTAssertEqual(NativeAudioAdjustment.apply(.volumeDown, uid: "USB", delta: -0.0625, controller: audio),
                       .accepted(nil))
    }

    @MainActor func testVolumeOnlyAndMuteOnlyAreIndependent() async {
        let audio = Audio()
        audio.output?.volume = .absent
        audio.output?.volumeLevel = nil
        XCTAssertEqual(NativeAudioAdjustment.apply(.volumeUp, uid: "USB", delta: 0.1, controller: audio), .unavailable)
        XCTAssertTrue(NativeAudioAdjustment.apply(.muteToggle, uid: "USB", delta: 0, controller: audio).handled)
        XCTAssertEqual(audio.writes, ["mute:USB:false"])
        audio.output?.volume = .settable
        audio.output?.volumeLevel = 0.25
        audio.output?.mute = .absent
        XCTAssertEqual(NativeAudioAdjustment.apply(.muteToggle, uid: "USB", delta: 0, controller: audio), .unavailable)
        XCTAssertTrue(NativeAudioAdjustment.apply(.volumeDown, uid: "USB", delta: -0.0625, controller: audio).handled)
        XCTAssertEqual(audio.writes, ["mute:USB:false", "volume:USB:0.1875"])
    }

    @MainActor func testAbsoluteMinimumRequestsMuteAndRaisingRequestsUnmute() async {
        let audio = Audio()
        audio.output?.isMuted = false
        XCTAssertTrue(NativeAudioAdjustment.setLevel(0, uid: "USB", controller: audio).handled)
        XCTAssertEqual(audio.writes, ["volume:USB:0.0", "mute:USB:true"])
        XCTAssertTrue(NativeAudioAdjustment.setLevel(0.125, uid: "USB", controller: audio).handled)
        XCTAssertEqual(audio.output?.isMuted, false)
    }

    @MainActor func testNonfiniteLevelNeverReachesWriter() async {
        let audio = Audio()
        XCTAssertEqual(NativeAudioAdjustment.setLevel(.nan, uid: "USB", controller: audio), .unavailable)
        XCTAssertEqual(NativeAudioAdjustment.apply(.volumeUp, uid: "USB", delta: .infinity, controller: audio), .unavailable)
        audio.output?.volumeLevel = .nan
        XCTAssertEqual(NativeAudioAdjustment.apply(.volumeDown, uid: "USB", delta: -0.1, controller: audio), .unavailable)
        XCTAssertTrue(audio.writes.isEmpty)
    }
    @MainActor func testPartialChannelWriteFailureIsConsumedAndReported() async {
        let audio = Audio()
        audio.partiallyRejectVolume = true
        let result = NativeAudioAdjustment.apply(.volumeUp, uid: "USB", delta: 0.0625, controller: audio)
        XCTAssertEqual(result, .failed(partiallyApplied: true))
        XCTAssertTrue(result.handled)
        XCTAssertEqual(audio.writes.count, 1, "no unmute follows a partial volume failure")
    }

}
