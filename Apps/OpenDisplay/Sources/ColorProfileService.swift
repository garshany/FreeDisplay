#if os(macOS)
import ApplicationServices
import CoreGraphics
import Foundation

/// An installed ICC display profile the user can assign. Identified by its file, never by its
/// name: two files can carry the same description ("Display P3" in the user and the shared
/// folder), and they are different profiles.
struct ICCProfile: Identifiable, Hashable {
    let id: String   // standardized file path — stable across launches
    let name: String
    let url: URL

    init(name: String, url: URL) {
        self.id = url.standardizedFileURL.path
        self.name = name
        self.url = url
    }

    /// Whether `other` names the same profile file.
    func isFile(_ other: URL?) -> Bool {
        other.map { $0.standardizedFileURL.path == id } ?? false
    }
}

/// What ColorSync reports a display is assigned: a user-chosen profile overriding the factory one,
/// or none, plus the display's factory profile files.
struct ICCAssignment: Hashable, Sendable {
    var customURL: URL?
    var factoryURLs: [URL]

    /// The display shows its factory profile: no custom entry, or one naming its own factory file.
    var isFactory: Bool {
        guard let custom = customURL?.standardizedFileURL else { return true }
        return factoryURLs.contains { $0.standardizedFileURL == custom }
    }
}

/// Per-display ICC colour-profile control via **public ColorSync** (App-Store-safe). Displays are
/// targeted by their persistent ColorSync device UUID (= the CG display UUID), never by index, so a
/// profile change only ever touches the intended display.
///
/// ColorSync's `k…` key constants are imported as non-`Sendable` mutable globals (strict concurrency
/// rejects referencing them), so we use their documented string values directly.
enum ColorProfileService {
    // Computed (not stored) so there's no non-Sendable static state; values are the documented
    // ColorSync constant strings, recovered from the live framework.
    private static var displayClass: CFString { "mntr" as CFString }
    private static var defaultProfileID: CFString { "DeviceDefaultProfileID" as CFString }

    static func deviceUUID(for displayID: CGDirectDisplayID) -> CFUUID? {
        CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
    }

    /// True when ColorSync exposes a device for this display (so writes can target it safely).
    static func isControllable(_ displayID: CGDirectDisplayID) -> Bool {
        guard let uuid = deviceUUID(for: displayID) else { return false }
        return ColorSyncDeviceCopyDeviceInfo(displayClass, uuid)?.takeRetainedValue() != nil
    }

    /// Installed display (RGB) ICC profiles, one row per file (same-named files stay distinct),
    /// sorted by name and then path.
    static func availableProfiles() -> [ICCProfile] {
        var collected: [ICCProfile] = []
        withUnsafeMutablePointer(to: &collected) { pointer in
            let callback: ColorSyncProfileIterateCallback = { dict, context in
                guard let context, let info = dict as NSDictionary? else { return true }
                let list = context.assumingMemoryBound(to: [ICCProfile].self)
                guard let url = info["com.apple.ColorSync.ProfileURL"] as? URL,
                      let name = info["com.apple.ColorSync.ProfileDescription"] as? String
                else { return true }
                // ColorSync reports the ICC four-char code, padded: "RGB " — compare without the padding.
                if let space = info["com.apple.ColorSync.ProfileColorSpace"] as? String,
                   space.trimmingCharacters(in: .whitespaces) != "RGB" {
                    return true
                }
                list.pointee.append(ICCProfile(name: name, url: url))
                return true
            }
            ColorSyncIterateInstalledProfiles(callback, nil, pointer, nil)
        }
        var seen = Set<String>()
        return collected
            .filter { seen.insert($0.id).inserted }
            .sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
    }

    /// The display's assignment, or nil when ColorSync has no readable device info for it.
    static func assignment(for displayID: CGDirectDisplayID) -> ICCAssignment? {
        guard let uuid = deviceUUID(for: displayID),
              let info = ColorSyncDeviceCopyDeviceInfo(displayClass, uuid)?.takeRetainedValue() as NSDictionary?
        else { return nil }
        let custom = (info["CustomProfiles"] as? NSDictionary).flatMap { profileURLs(in: $0).first }
        let factory = (info["FactoryProfiles"] as? NSDictionary).map(profileURLs(in:)) ?? []
        return ICCAssignment(customURL: custom, factoryURLs: factory)
    }

    /// Profile URLs in a ColorSync profiles dictionary, whose values are either the URL itself or a
    /// profile-info dictionary carrying it ("DeviceProfileURL", `kColorSyncDeviceProfileURL`).
    private static func profileURLs(in dictionary: NSDictionary) -> [URL] {
        dictionary.allValues.compactMap { value in
            if let url = value as? URL { return url }
            return (value as? NSDictionary)?["DeviceProfileURL"] as? URL
        }
    }

    /// The display's current profile name (a custom override if set, else its factory default).
    static func currentProfileName(for displayID: CGDirectDisplayID) -> String? {
        guard let assignment = assignment(for: displayID) else { return nil }
        if let url = assignment.customURL {
            return profileDescription(url) ?? url.deletingPathExtension().lastPathComponent
        }
        if let url = assignment.factoryURLs.first {
            let name = profileDescription(url) ?? url.deletingPathExtension().lastPathComponent
            return String(localized: "\(name) (factory)")
        }
        return String(localized: "Factory default")
    }

    private static func profileDescription(_ url: URL) -> String? {
        guard let profile = ColorSyncProfileCreateWithURL(url as CFURL, nil)?.takeRetainedValue() else { return nil }
        return ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String?
    }

    /// Assigns an ICC profile to a display after validating it opens + verifies. Returns success.
    @discardableResult
    static func setProfile(_ profile: ICCProfile, for displayID: CGDirectDisplayID) -> Bool {
        guard let uuid = deviceUUID(for: displayID),
              let cgProfile = ColorSyncProfileCreateWithURL(profile.url as CFURL, nil)?.takeRetainedValue(),
              ColorSyncProfileVerify(cgProfile, nil, nil)
        else { return false }
        let map: [CFString: Any] = [defaultProfileID: profile.url]
        return ColorSyncDeviceSetCustomProfiles(displayClass, uuid, map as CFDictionary)
    }

    /// Removes any custom profile, reverting the display to its factory profile.
    @discardableResult
    static func resetToFactory(for displayID: CGDirectDisplayID) -> Bool {
        guard let uuid = deviceUUID(for: displayID) else { return false }
        let map: [CFString: Any] = [defaultProfileID: kCFNull as Any]
        return ColorSyncDeviceSetCustomProfiles(displayClass, uuid, map as CFDictionary)
    }
}
#endif
