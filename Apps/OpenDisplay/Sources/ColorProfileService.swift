#if os(macOS)
import ApplicationServices
import CoreGraphics
import Foundation
import TopologyCore

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

// MARK: - Profile files (inspection, user folder)

/// What OpenDisplay can tell about one profile file, read from the file itself (identity = URL).
struct ICCProfileDetails: Identifiable, Hashable, Sendable {
    var id: String { url.standardizedFileURL.path }
    let url: URL
    /// The profile's description; nil when the file can't be opened as a profile.
    let name: String?
    let header: ICCProfileHeader?
    let provenance: ICCProfileProvenance
    let exists: Bool

    var displayName: String { name ?? url.deletingPathExtension().lastPathComponent }
    /// Only the user's own copies, and only while the file is there.
    var isRemovable: Bool { exists && ICCProfileCatalog.isRemovable(provenance) }
}

/// Why a profile file operation didn't happen.
enum ICCProfileFileError: Error, Equatable {
    /// ColorSync can't open or verify the file as an ICC profile.
    case notAProfile
    /// A valid profile, but not RGB, so macOS can't use it for a display.
    case notRGB
    /// The file system refused; carries its explanation.
    case fileSystem(String)
}

extension ColorProfileService {
    /// The current user's own profiles folder — the only one OpenDisplay writes to.
    static var userProfilesFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/ColorSync/Profiles", isDirectory: true)
    }

    /// Reads a profile file's description and header. `factoryURLs` are the display's own factory
    /// profiles, so its factory file is recognised wherever ColorSync keeps it.
    static func details(of url: URL, factoryURLs: [URL]) -> ICCProfileDetails {
        let exists = FileManager.default.fileExists(atPath: url.path)
        let profile = exists ? ColorSyncProfileCreateWithURL(url as CFURL, nil)?.takeRetainedValue() : nil
        let name = profile.flatMap { ColorSyncProfileCopyDescriptionString($0)?.takeRetainedValue() as String? }
        let header = profile.flatMap(headerBytes).flatMap(ICCProfileHeader.init(bytes:))
        let provenance = ICCProfileCatalog.provenance(of: url.path, factoryPaths: factoryURLs.map(\.path),
                                                      userFolder: userProfilesFolder.path)
        return ICCProfileDetails(url: url, name: name, header: header, provenance: provenance, exists: exists)
    }

    private static func headerBytes(_ profile: ColorSyncProfile) -> [UInt8]? {
        guard let data = ColorSyncProfileCopyHeader(profile)?.takeRetainedValue() as Data? else { return nil }
        return [UInt8](data)
    }

    /// The profile files in the user's folder (subfolders included), read fresh from disk each time
    /// so files added or removed in Finder show up. Sorted by name, then path.
    static func userFolderProfiles(factoryURLs: [URL]) -> [ICCProfileDetails] {
        let folder = userProfilesFolder
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles]) else { return [] }
        var found: [ICCProfileDetails] = []
        for case let url as URL in enumerator where ICCProfileCatalog.isProfileFileName(url.lastPathComponent) {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            found.append(details(of: url, factoryURLs: factoryURLs))
        }
        return found.sorted {
            let order = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    enum ImportResult: Equatable, Sendable {
        /// Copied into the user folder at this URL.
        case imported(URL)
        /// The same file (byte for byte) is already in the user folder, at this URL; nothing copied.
        case alreadyInstalled(URL)
    }

    /// Enough of a file's identity to tell whether it is still the one OpenDisplay wrote.
    struct FileStamp: Equatable, Sendable {
        let size: Int?
        let modified: Date?
    }

    static func fileStamp(_ url: URL) -> FileStamp? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return nil
        }
        return FileStamp(size: values.fileSize, modified: values.contentModificationDate)
    }

    /// COPIES a profile into the user's folder — the source is never moved or changed — after
    /// ColorSync opens and verifies it as an RGB profile. A name already taken gets a numbered
    /// variant; an identical file already anywhere in the folder is reused instead of duplicated.
    /// A symbolic link is followed, so the copy is the profile itself, not a link to it.
    static func importProfile(from source: URL) throws -> ImportResult {
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        guard let profile = ColorSyncProfileCreateWithURL(source as CFURL, nil)?.takeRetainedValue(),
              ColorSyncProfileVerify(profile, nil, nil) else { throw ICCProfileFileError.notAProfile }
        guard headerBytes(profile).flatMap(ICCProfileHeader.init(bytes:))?.isRGB == true else {
            throw ICCProfileFileError.notRGB
        }
        let folder = userProfilesFolder.standardizedFileURL
        if source.path.hasPrefix(folder.path + "/") { return .alreadyInstalled(source) }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let sourceData = try Data(contentsOf: source)
            if let enumerator = manager.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey],
                                                   options: [.skipsHiddenFiles]) {
                for case let candidate as URL in enumerator
                where ICCProfileCatalog.isProfileFileName(candidate.lastPathComponent) {
                    let size = (try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                    if size == sourceData.count, (try? Data(contentsOf: candidate)) == sourceData {
                        return .alreadyInstalled(candidate)
                    }
                }
            }
            let existing = try manager.contentsOfDirectory(atPath: folder.path)
            let name = ICCProfileCatalog.importFileName(for: source.lastPathComponent, existing: Set(existing))
            let destination = folder.appendingPathComponent(name)
            try manager.copyItem(at: source, to: destination)
            return .imported(destination)
        } catch {
            throw ICCProfileFileError.fileSystem(error.localizedDescription)
        }
    }

    /// Moves a user-folder profile to the Trash (reversible) and returns where it went. Refuses
    /// anything that isn't the user's own copy — including a display's factory file, wherever it
    /// is kept: those belong to macOS or an administrator.
    static func moveToTrash(_ url: URL, factoryURLs: [URL]) throws -> URL {
        let provenance = ICCProfileCatalog.provenance(of: url.path, factoryPaths: factoryURLs.map(\.path),
                                                      userFolder: userProfilesFolder.path)
        guard ICCProfileCatalog.isRemovable(provenance) else {
            throw ICCProfileFileError.fileSystem(String(localized: "Only profiles in your own profiles folder can be removed here."))
        }
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        } catch {
            throw ICCProfileFileError.fileSystem(error.localizedDescription)
        }
        guard let trashed = resulting as URL? else {
            throw ICCProfileFileError.fileSystem(String(localized: "The Trash didn’t report where the file went."))
        }
        return trashed
    }

    /// Puts a trashed profile back where it was; never overwrites a file that took its place.
    static func restoreFromTrash(_ trashed: URL, to original: URL) throws {
        do {
            try FileManager.default.createDirectory(at: original.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: trashed, to: original)
        } catch {
            throw ICCProfileFileError.fileSystem(error.localizedDescription)
        }
    }
}
#endif
