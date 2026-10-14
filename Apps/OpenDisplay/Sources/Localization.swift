// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import AppKit
import Foundation

extension String {
    /// Looks up a runtime string that is not a source literal — a package-provided label or an
    /// error description — in the app's string catalog. Source literals go through
    /// `String(localized:)` or a SwiftUI `LocalizedStringKey` instead, so Xcode extracts them;
    /// entries for these runtime strings are added to Localizable.xcstrings by hand.
    var appLocalized: String { Bundle.main.localizedString(forKey: self, value: self, table: nil) }
}

/// The interface language. `.system` follows the macOS language list; the others pin this app's
/// own `AppleLanguages` default, which macOS reads at launch, so a change takes effect on relaunch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case russian = "ru"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "System")
        case .english: return "English"  // endonyms stay untranslated so either can be found
        case .russian: return "Русский"
        }
    }

    /// Reads the app's own domain only: `UserDefaults.standard` would fall through to the global
    /// language list and report a pin that was never made.
    static var current: AppLanguage {
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        guard let first = (domain?["AppleLanguages"] as? [String])?.first else { return .system }
        if first.hasPrefix("ru") { return .russian }
        if first.hasPrefix("en") { return .english }
        return .system
    }

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }

    /// Relaunches the app so the new language is read. A second instance would hand off to this one
    /// and exit, so the new launch waits for this process to finish terminating first.
    @MainActor static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                          Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
#endif
