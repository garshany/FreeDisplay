import Foundation

/// What OpenDisplay's Shortcuts actions can do, for Settings to describe (SO-18). The App Intents
/// themselves live in the app; this is the shared, tested statement of their targets, results and
/// requirements, so Settings never promises more than an action does — in particular, a build
/// without private API never lists a private-only action as usable, and says which brightness
/// routes it really has.
public enum AutomationIntentCatalog {
    /// One Shortcuts action, by the App Intent behind it.
    public enum Action: String, Hashable, Sendable, CaseIterable {
        case getBrightness
        case setBrightness
        case setDisplayMode
        case setMainDisplay
        case reconnectAll
    }

    /// Which build is running.
    public enum Build: Hashable, Sendable {
        /// The full build, which may use the private display frameworks.
        case full
        /// The public-API-only build.
        case publicAPIOnly
    }

    /// What an action acts on.
    public enum Target: Hashable, Sendable {
        /// No display parameter: every display OpenDisplay turned off.
        case displaysTurnedOff
        /// One display chosen in the action. The picker lists connected displays and the ones
        /// OpenDisplay turned off; a display that isn't connected, or isn't showing its own desktop,
        /// fails the action — another display is never substituted.
        case chosenDisplay
        /// As `chosenDisplay`, except that leaving the parameter empty means the built-in display.
        case chosenDisplayOrBuiltIn
    }

    /// How a brightness action reaches the display.
    public enum BrightnessRoute: String, Hashable, Sendable, CaseIterable {
        /// The display's own brightness control (DisplayServices) — built-in and Apple displays.
        case native
        /// Monitor hardware over DDC/CI.
        case hardware
        /// Software dimming applied by OpenDisplay.
        case software
    }

    /// What the action hands back for the next step of a shortcut — a typed value to branch on,
    /// never only a sentence.
    public enum Result: Hashable, Sendable {
        /// Display, level, requested level, whether the display confirmed it, and the route.
        case brightness
        /// Display, mode, outcome and the seconds left to keep it.
        case displayMode
        /// The main display macOS reports afterwards.
        case mainDisplay
        /// Outcome and how many displays came back.
        case reconnect
    }

    public struct Entry: Hashable, Sendable, Identifiable {
        public var action: Action
        public var target: Target
        public var result: Result
        /// The brightness routes in this build; empty for other actions.
        public var brightnessRoutes: [BrightnessRoute]
        /// The change stays only if it is kept in OpenDisplay before the countdown ends.
        public var needsKeepConfirmation: Bool

        public var id: Action { action }
    }

    /// The actions this build offers, in the order Settings lists them.
    public static func entries(for build: Build) -> [Entry] {
        Action.allCases.compactMap { entry($0, build: build) }
    }

    /// One action as this build offers it, or nil when the build can't run it at all.
    public static func entry(_ action: Action, build: Build) -> Entry? {
        guard isAvailable(action, in: build) else { return nil }
        switch action {
        case .getBrightness:
            return Entry(action: action, target: .chosenDisplay, result: .brightness,
                         brightnessRoutes: brightnessRoutes(build), needsKeepConfirmation: false)
        case .setBrightness:
            return Entry(action: action, target: .chosenDisplayOrBuiltIn, result: .brightness,
                         brightnessRoutes: brightnessRoutes(build), needsKeepConfirmation: false)
        case .setDisplayMode:
            return Entry(action: action, target: .chosenDisplay, result: .displayMode, brightnessRoutes: [],
                         needsKeepConfirmation: true)
        case .setMainDisplay:
            return Entry(action: action, target: .chosenDisplay, result: .mainDisplay, brightnessRoutes: [],
                         needsKeepConfirmation: false)
        case .reconnectAll:
            return Entry(action: action, target: .displaysTurnedOff, result: .reconnect, brightnessRoutes: [],
                         needsKeepConfirmation: false)
        }
    }

    /// Every current action runs in both builds: the public-only build reaches brightness through
    /// software dimming and turns displays off and on through public API. An action added later
    /// that needs private API is listed here as unavailable to `.publicAPIOnly`.
    public static func isAvailable(_ action: Action, in build: Build) -> Bool {
        switch action {
        case .getBrightness, .setBrightness, .setDisplayMode, .setMainDisplay, .reconnectAll:
            return true
        }
    }

    /// The public-only build has software dimming alone; the full build tries the display's own
    /// control, then DDC/CI, and dims in software where neither answers.
    public static func brightnessRoutes(_ build: Build) -> [BrightnessRoute] {
        switch build {
        case .full: return [.native, .hardware, .software]
        case .publicAPIOnly: return [.software]
        }
    }
}
