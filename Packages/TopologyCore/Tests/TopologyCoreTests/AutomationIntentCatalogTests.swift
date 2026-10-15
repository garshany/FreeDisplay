import XCTest
@testable import TopologyCore

/// SO-18: what Settings says about the Shortcuts actions matches what each build can do.
final class AutomationIntentCatalogTests: XCTestCase {
    func testEveryActionIsListedOnceInBothBuilds() {
        for build in [AutomationIntentCatalog.Build.full, .publicAPIOnly] {
            let actions = AutomationIntentCatalog.entries(for: build).map(\.action)
            XCTAssertEqual(actions, AutomationIntentCatalog.Action.allCases, "\(build)")
        }
    }

    func testThePublicBuildOffersSoftwareBrightnessOnly() {
        for action in [AutomationIntentCatalog.Action.getBrightness, .setBrightness] {
            XCTAssertEqual(AutomationIntentCatalog.entry(action, build: .publicAPIOnly)?.brightnessRoutes, [.software])
            XCTAssertEqual(AutomationIntentCatalog.entry(action, build: .full)?.brightnessRoutes,
                           [.native, .hardware, .software])
        }
    }

    func testNoPublicEntryNamesAPrivateRoute() {
        let routes = AutomationIntentCatalog.entries(for: .publicAPIOnly).flatMap(\.brightnessRoutes)
        XCTAssertFalse(routes.contains(.native))
        XCTAssertFalse(routes.contains(.hardware))
    }

    func testAnUnavailableActionIsNotListed() {
        for build in [AutomationIntentCatalog.Build.full, .publicAPIOnly] {
            for action in AutomationIntentCatalog.Action.allCases {
                XCTAssertEqual(AutomationIntentCatalog.entry(action, build: build) != nil,
                               AutomationIntentCatalog.isAvailable(action, in: build))
            }
        }
    }

    func testTargetsResultsAndConfirmation() {
        let full = Dictionary(uniqueKeysWithValues: AutomationIntentCatalog.entries(for: .full).map { ($0.action, $0) })
        XCTAssertEqual(full[.setBrightness]?.target, .chosenDisplayOrBuiltIn)
        XCTAssertEqual(full[.getBrightness]?.target, .chosenDisplay)
        XCTAssertEqual(full[.reconnectAll]?.target, .displaysTurnedOff)
        XCTAssertEqual(full[.setDisplayMode]?.needsKeepConfirmation, true)
        XCTAssertEqual(full.values.filter(\.needsKeepConfirmation).map(\.action), [.setDisplayMode])
        XCTAssertEqual(full[.setMainDisplay]?.result, .mainDisplay)
        XCTAssertTrue(full.values.filter { $0.result != .brightness }.allSatisfy { $0.brightnessRoutes.isEmpty })
    }
}
