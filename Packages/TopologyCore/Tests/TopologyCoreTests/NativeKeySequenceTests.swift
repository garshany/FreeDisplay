import XCTest
@testable import TopologyCore

final class NativeKeySequenceTests: XCTestCase {
    func testUnconsumedPressCannotBeStolenOnRepeat() {
        var sequence = NativeKeySequence()
        let key = NativeKeySequence.Key.media(.volumeUp)
        XCTAssertFalse(sequence.press(key, isRepeat: false, permissionGranted: true) { false })
        XCTAssertFalse(sequence.press(key, isRepeat: true, permissionGranted: true) {
            XCTFail("an unhandled press belongs to macOS for the whole sequence")
            return true
        })
        XCTAssertFalse(sequence.release(key, permissionGranted: true))
    }

    func testOwnedPressRepeatsAndReleasesExactlyOnce() {
        var sequence = NativeKeySequence()
        let key = NativeKeySequence.Key.media(.volumeDown)
        XCTAssertTrue(sequence.press(key, isRepeat: false, permissionGranted: true) { true })
        XCTAssertTrue(sequence.press(key, isRepeat: true, permissionGranted: true) { true })
        XCTAssertTrue(sequence.release(key, permissionGranted: true))
        XCTAssertFalse(sequence.release(key, permissionGranted: true))
    }

    func testDeniedAndRevokedPermissionDoNotDispatchOrConsumeRelease() {
        var sequence = NativeKeySequence()
        let key = NativeKeySequence.Key.media(.brightnessUp)
        XCTAssertFalse(sequence.press(key, isRepeat: false, permissionGranted: false) {
            XCTFail("no permission: no dispatch")
            return true
        })
        XCTAssertTrue(sequence.press(key, isRepeat: false, permissionGranted: true) { true })
        XCTAssertFalse(sequence.release(key, permissionGranted: false))
        XCTAssertFalse(sequence.release(key, permissionGranted: true))
    }

    func testCancellationAndFunctionKeysHaveIndependentIdentity() {
        var sequence = NativeKeySequence()
        XCTAssertTrue(sequence.press(.function(AlternativeBrightnessKey.f15), isRepeat: false,
                                     permissionGranted: true) { true })
        XCTAssertFalse(sequence.release(.media(.brightnessUp), permissionGranted: true))
        sequence.cancel()
        XCTAssertFalse(sequence.release(.function(AlternativeBrightnessKey.f15), permissionGranted: true))
    }

    func testDisablingOneCaptureLeavesTheOtherSequenceOwned() {
        var sequence = NativeKeySequence()
        XCTAssertTrue(sequence.press(.media(.brightnessDown), isRepeat: false, permissionGranted: true) { true })
        XCTAssertTrue(sequence.press(.media(.volumeDown), isRepeat: false, permissionGranted: true) { true })
        sequence.cancel(.media(.brightnessDown))
        XCTAssertFalse(sequence.release(.media(.brightnessDown), permissionGranted: true))
        XCTAssertTrue(sequence.release(.media(.volumeDown), permissionGranted: true))
    }
}
