import XCTest
@testable import TopologyCore

final class NativeAudioVolumeTests: XCTestCase {
    func testChannelVolumePreservesBalanceAndUsesKnownMaximum() {
        let channels: [NativeAudioVolume.Channel] = [.init(element: 1, access: .settable, level: 0.4),
                                                      .init(element: 2, access: .settable, level: 0.2)]
        XCTAssertEqual(NativeAudioVolume.level(channels), 0.4)
        XCTAssertEqual(NativeAudioVolume.writes(level: 0.8, channels: channels)?.compactMap(\.level), [0.8, 0.4])
    }

    func testMainElementAndSilenceHaveExplicitBehavior() {
        let main: [NativeAudioVolume.Channel] = [.init(element: 0, access: .settable, level: 0)]
        XCTAssertEqual(NativeAudioVolume.writes(level: 0.25, channels: main)?.first?.level, 0.25)
        let stereo: [NativeAudioVolume.Channel] = [.init(element: 1, access: .settable, level: 0),
                                                    .init(element: 2, access: .settable, level: 0)]
        XCTAssertEqual(NativeAudioVolume.writes(level: 0.125, channels: stereo)?.compactMap(\.level), [0.125, 0.125])
    }

    func testReadOnlyOrMissingChannelsDoNotCreateAWritableMaster() {
        let readOnly: [NativeAudioVolume.Channel] = [.init(element: 1, access: .settable, level: 0.4),
                                                      .init(element: 2, access: .readOnly, level: 0.2)]
        XCTAssertEqual(NativeAudioVolume.access(readOnly), .readOnly)
        XCTAssertNil(NativeAudioVolume.writes(level: 0.5, channels: readOnly))
        XCTAssertEqual(NativeAudioVolume.access([]), .absent)
        XCTAssertNil(NativeAudioVolume.level([]))
    }

    func testUnknownOrNonfiniteChannelLevelNeverCreatesAnAssumedStep() {
        for value: Float? in [nil, .nan, .infinity, -1, 2] {
            let channels = [NativeAudioVolume.Channel(element: 1, access: .settable, level: value)]
            XCTAssertNil(NativeAudioVolume.level(channels))
            XCTAssertNil(NativeAudioVolume.writes(level: 0.4, channels: channels))
        }
    }
}
