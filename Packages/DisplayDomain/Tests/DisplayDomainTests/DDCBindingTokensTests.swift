import XCTest
@testable import DisplayDomain

/// R1 P1 (FB-08): a DDC binding that finished building is used only if nothing withdrew it while it
/// ran — for the caller that started it and for every caller that joined it.
final class DDCBindingTokensTests: XCTestCase {
    private let apple = DisplayRecordID(rawValue: "disp_apple")
    private let other = DisplayRecordID(rawValue: "disp_other")

    func testAnUndisturbedBuildIsCurrentForEveryWaiter() {
        var tokens = DDCBindingTokens()
        let build = tokens.begin(apple, allowAppleDisplay: true)
        // The starter and any joiner check the same build — both may use it.
        XCTAssertTrue(tokens.isCurrent(build, for: apple, allowAppleDisplay: true))
        XCTAssertTrue(tokens.isCurrent(build, for: apple, allowAppleDisplay: true))
    }

    func testRevokingTheOverrideMidBuildInvalidatesEveryWaiter() {
        // The override is turned off while the bind runs: the app prunes the display, and the
        // override no longer matches. Neither check alone may be skipped by a joining caller.
        var tokens = DDCBindingTokens()
        let build = tokens.begin(apple, allowAppleDisplay: true)
        tokens.retain(only: [other])
        XCTAssertFalse(tokens.isCurrent(build, for: apple, allowAppleDisplay: false))
        XCTAssertFalse(tokens.isCurrent(build, for: apple, allowAppleDisplay: true),
                       "a prune alone already withdraws the build")
    }

    func testAnOverrideChangeWithoutAPruneStillInvalidates() {
        var tokens = DDCBindingTokens()
        let build = tokens.begin(apple, allowAppleDisplay: true)
        XCTAssertFalse(tokens.isCurrent(build, for: apple, allowAppleDisplay: false))
    }

    func testRevokeThenRegrantDoesNotReviveTheOldBuild() {
        // Off then on again while the first bind still runs: the setting reads the same as when it
        // started, but the build answers a question the user withdrew in between.
        var tokens = DDCBindingTokens()
        let old = tokens.begin(apple, allowAppleDisplay: true)
        tokens.retain(only: [])
        let fresh = tokens.begin(apple, allowAppleDisplay: true)
        XCTAssertFalse(tokens.isCurrent(old, for: apple, allowAppleDisplay: true))
        XCTAssertTrue(tokens.isCurrent(fresh, for: apple, allowAppleDisplay: true))
    }

    func testAPruneOnlyTouchesTheDisplaysItDrops() {
        var tokens = DDCBindingTokens()
        let kept = tokens.begin(other, allowAppleDisplay: false)
        let dropped = tokens.begin(apple, allowAppleDisplay: true)
        tokens.retain(only: [other])
        XCTAssertTrue(tokens.isCurrent(kept, for: other, allowAppleDisplay: false))
        XCTAssertFalse(tokens.isCurrent(dropped, for: apple, allowAppleDisplay: true))
    }

    func testTokensAreNeverReusedAcrossDisplays() {
        var tokens = DDCBindingTokens()
        let first = tokens.begin(apple, allowAppleDisplay: false)
        let second = tokens.begin(other, allowAppleDisplay: false)
        XCTAssertNotEqual(first.token, second.token)
        // A build is only ever current for the display it was started for.
        XCTAssertFalse(tokens.isCurrent(first, for: other, allowAppleDisplay: false))
    }
}
