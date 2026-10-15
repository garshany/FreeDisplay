import DisplayDomain
import Foundation
import SceneEngine

/// Preferences the app keeps in UserDefaults rather than settings.json, carried by the archive so
/// that a restore brings them back too.
public struct ArchivedDefaults: Hashable, Sendable, Codable {
    /// Labs › Experimental display rotation.
    public var experimentalRotationEnabled: Bool

    public init(experimentalRotationEnabled: Bool = false) {
        self.experimentalRotationEnabled = experimentalRotationEnabled
    }

    private enum CodingKeys: String, CodingKey { case experimentalRotationEnabled }

    /// Tolerant for the same reason `OpenDisplaySettings` is: a key a later version drops or
    /// reshapes must cost that one preference, not the whole import.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        experimentalRotationEnabled =
            (try? container.decodeIfPresent(Bool.self, forKey: .experimentalRotationEnabled)) ?? false
    }
}

/// A portable, versioned copy of OpenDisplay's own configuration (SO-11/FA-10): what Settings ›
/// About › Manage App Settings exports, validates on import, writes as a backup before any
/// replacement, and uses for a reset.
///
/// Covered: the preferences in settings.json (luminance anchors included), favourite resolutions,
/// the remembered-display registry (names, tags, pairings), saved scenes, the menu layout
/// (menu-layout.json) and the UserDefaults-held preferences in `defaults`. Deliberately not covered: the restore ledgers inside settings.json (they describe
/// a display's state at a moment on one Mac, and replaying them elsewhere would write stale values
/// to hardware), the list of displays the app is keeping off, checkpoints, logs, the macOS display
/// configuration, Launch at Login, the interface language and the tray's remembered expanded
/// sections (window state, not configuration). Those stay as they are on import and on reset.
///
/// The file is JSON with a format marker and a version. A newer version is refused rather than
/// half-read; the `settings` section itself keeps the store's per-key tolerance, so an archive
/// from a slightly different build still imports with defaults for whatever it doesn't carry.
public struct SettingsArchive: Hashable, Sendable {
    /// Identifies the file as an OpenDisplay settings archive, whatever its name or extension.
    public static let formatIdentifier = "dev.opendisplay.settings-archive"
    /// The archive layout this build writes and the newest it can read.
    public static let currentVersion = 1

    public var version: Int
    public var createdAt: Date
    /// The app version that wrote the archive ("0.11.5 (24)"), shown in the import summary.
    public var appVersion: String?
    public var settings: OpenDisplaySettings
    public var favorites: FavoriteResolutions
    public var registry: RegistryState
    public var scenes: [Scene]
    public var defaults: ArchivedDefaults
    /// Menu customisation: item placement, per-display visibility and icons, display order.
    public var menuLayout: MenuLayoutSettings

    /// An archive of the given state. The restore ledgers are always stripped from `settings` —
    /// see the type comment — so no archive this initializer makes can carry them.
    public init(createdAt: Date,
                appVersion: String?,
                settings: OpenDisplaySettings,
                favorites: FavoriteResolutions,
                registry: RegistryState,
                scenes: [Scene],
                defaults: ArchivedDefaults,
                menuLayout: MenuLayoutSettings = .default) {
        self.version = Self.currentVersion
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.settings = settings.withoutRestoreLedgers()
        self.favorites = favorites
        self.registry = registry
        self.scenes = scenes
        self.defaults = defaults
        self.menuLayout = menuLayout
    }

    /// What a reset installs: every covered store back to its first-run state.
    public static func factoryDefaults(createdAt: Date, appVersion: String?) -> SettingsArchive {
        SettingsArchive(createdAt: createdAt, appVersion: appVersion, settings: .default,
                        favorites: FavoriteResolutions(), registry: RegistryState(), scenes: [],
                        defaults: ArchivedDefaults(), menuLayout: .default)
    }

    // MARK: - File format

    /// The archive as file contents (pretty-printed, sorted keys, so two exports diff cleanly).
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Validates and decodes file contents. Throws a `SettingsArchiveError` naming what is wrong;
    /// nothing is read past the first problem, so a refused file can't partly apply.
    public static func decode(_ data: Data) throws -> SettingsArchive {
        do {
            return try JSONDecoder().decode(SettingsArchive.self, from: data)
        } catch let error as SettingsArchiveError {
            throw error
        } catch {
            // Not JSON, or JSON that isn't an object: whatever it is, it isn't one of ours.
            throw SettingsArchiveError.notAnArchive
        }
    }

    /// Reads and validates the archive at `url`.
    public static func read(from url: URL) throws -> SettingsArchive {
        guard let data = try? Data(contentsOf: url) else { throw SettingsArchiveError.unreadable }
        return try decode(data)
    }

    /// Writes the archive to `url` atomically — an interrupted export never leaves half a file.
    public func write(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }

    // MARK: - Display identity

    /// One remembered display an archive refers to, with the name the archive knows it by.
    public struct ArchivedDisplay: Hashable, Sendable {
        public let id: DisplayRecordID
        /// The alias or model name from the archive's registry; nil when the archive has no record.
        public let name: String?
    }

    /// Every display the archived preferences are keyed to: per-display brightness routes and DDC
    /// overrides, learned offsets, luminance anchors, keyboard/audio preferences, app-preset targets,
    /// group members, input-switch shortcuts, protected layouts, favourite resolutions and
    /// per-display menu preferences and order.
    public var referencedDisplayIDs: Set<DisplayRecordID> {
        var ids = Set<DisplayRecordID>()
        ids.formUnion(settings.softwareBrightnessDisplayIDs.map(DisplayRecordID.init(rawValue:)))
        ids.formUnion(settings.ddcAppleDisplayOverrideIDs.map(DisplayRecordID.init(rawValue:)))
        ids.formUnion(settings.ddcChannelMappings.map(\.displayID))
        ids.formUnion(settings.adaptiveBrightnessOffsetByDisplay.keys.map(DisplayRecordID.init(rawValue:)))
        ids.formUnion(settings.keyboardAudioByDisplay.keys.map(DisplayRecordID.init(rawValue:)))
        for preset in settings.appPresets {
            if case .display(let raw) = preset.target { ids.insert(DisplayRecordID(rawValue: raw)) }
        }
        for group in settings.displayGroups { ids.formUnion(group.memberRecordIDs) }
        ids.formUnion(settings.hotkeyShortcuts.inputSwitchBindings.map(\.displayID))
        for layout in settings.protectedLayouts.values {
            ids.formUnion(LayoutProtectionPolicy.members(of: layout))
        }
        ids.formUnion(favorites.displayIDs)
        ids.formUnion(settings.luminanceAnchorsByDisplay.keys.map(DisplayRecordID.init(rawValue:)))
        ids.formUnion(menuLayout.displays.keys.map(DisplayRecordID.init(rawValue:)))
        ids.formUnion(menuLayout.displayOrder.map(DisplayRecordID.init(rawValue:)))
        return ids
    }

    /// The referenced displays that aren't among `known` — the displays this Mac remembers or has
    /// on the desk now. Their settings import as they are and apply only if a display with that
    /// identity turns up; the import summary lists them so nothing is retargeted silently.
    /// Sorted by name, then id, so the list reads the same every time.
    public func unmatchedDisplays(known: Set<DisplayRecordID>) -> [ArchivedDisplay] {
        referencedDisplayIDs.subtracting(known)
            .map { ArchivedDisplay(id: $0, name: archivedName(for: $0)) }
            .sorted { ($0.name ?? $0.id.rawValue, $0.id.rawValue) < ($1.name ?? $1.id.rawValue, $1.id.rawValue) }
    }

    /// The name the archive's registry gives a display: observation ids (`cg:<uuid>`) go through
    /// the registry's UUID index, registry-minted ids match a record directly.
    private func archivedName(for id: DisplayRecordID) -> String? {
        let recordID = id.cgUUID.flatMap { registry.cgUUIDIndex[$0] } ?? id
        return registry.records.first { $0.id == recordID }?.displayName
    }
}

/// Why an archive was refused. The app words each case; nothing has been changed when one is thrown.
public enum SettingsArchiveError: Error, Hashable, Sendable {
    /// The file couldn't be read at all (missing, no permission).
    case unreadable
    /// The file isn't an OpenDisplay settings archive.
    case notAnArchive
    /// Written by a newer OpenDisplay with a layout this build doesn't know.
    case newerVersion(Int)
    /// A version number no OpenDisplay ever wrote.
    case unsupportedVersion(Int)
    /// The named section is missing or malformed.
    case damaged(section: String)
    /// The named section decodes, but `item` holds a value OpenDisplay can't use as it is — a
    /// number it can't represent or count with (`OpenDisplaySettings.unusableValueKey`,
    /// `Scene.invalidValues`). Refused rather than clamped: nothing in the file is reinterpreted.
    case invalidValue(section: String, item: String)
}

extension SettingsArchive: Codable {
    private enum CodingKeys: String, CodingKey {
        case format, version, createdAt, appVersion, settings, favorites, registry, scenes, defaults, menuLayout
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.formatIdentifier, forKey: .format)
        try container.encode(version, forKey: .version)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(appVersion, forKey: .appVersion)
        try container.encode(settings, forKey: .settings)
        try container.encode(favorites, forKey: .favorites)
        try container.encode(registry, forKey: .registry)
        try container.encode(scenes, forKey: .scenes)
        try container.encode(defaults, forKey: .defaults)
        try container.encode(menuLayout, forKey: .menuLayout)
    }

    /// Checks the marker and version before touching any section, then decodes each section with
    /// its own error, so the message can say which part of the file is the problem.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard (try? container.decode(String.self, forKey: .format)) == Self.formatIdentifier else {
            throw SettingsArchiveError.notAnArchive
        }
        guard let version = try? container.decode(Int.self, forKey: .version) else {
            throw SettingsArchiveError.damaged(section: CodingKeys.version.rawValue)
        }
        guard version <= Self.currentVersion else { throw SettingsArchiveError.newerVersion(version) }
        guard version >= 1 else { throw SettingsArchiveError.unsupportedVersion(version) }
        self.version = version
        createdAt = try Self.section(.createdAt, in: container) { try $0.decode(Date.self, forKey: .createdAt) }
        appVersion = try? container.decodeIfPresent(String.self, forKey: .appVersion)
        // Stripped here too, not only by the memberwise init: an archive edited by hand (or written
        // by some other tool) must not smuggle a restore ledger in.
        settings = try Self.section(.settings, in: container) {
            try $0.decode(OpenDisplaySettings.self, forKey: .settings)
        }.withoutRestoreLedgers()
        if let key = settings.unusableValueKey {
            throw SettingsArchiveError.invalidValue(section: CodingKeys.settings.rawValue, item: key)
        }
        favorites = try Self.section(.favorites, in: container) {
            try $0.decode(FavoriteResolutions.self, forKey: .favorites)
        }
        registry = try Self.section(.registry, in: container) { try $0.decode(RegistryState.self, forKey: .registry) }
        scenes = try Self.section(.scenes, in: container) { try $0.decode([Scene].self, forKey: .scenes) }
        for scene in scenes {
            if let invalid = scene.invalidValues.first {
                throw SettingsArchiveError.invalidValue(
                    section: CodingKeys.scenes.rawValue,
                    item: "\(scene.name) › \(invalid.selector) › \(invalid.field.rawValue)")
            }
        }
        defaults = try Self.section(.defaults, in: container) {
            try $0.decodeIfPresent(ArchivedDefaults.self, forKey: .defaults)
        } ?? ArchivedDefaults()
        // Archives written before the menu layout was archived don't carry it; like a missing
        // `defaults`, an absent section installs the first-run layout — import replaces, it
        // doesn't merge.
        menuLayout = try Self.section(.menuLayout, in: container) {
            try $0.decodeIfPresent(MenuLayoutSettings.self, forKey: .menuLayout)
        } ?? .default
    }

    private static func section<T>(_ key: CodingKeys, in container: KeyedDecodingContainer<CodingKeys>,
                                   _ decode: (KeyedDecodingContainer<CodingKeys>) throws -> T) throws -> T {
        do { return try decode(container) } catch {
            throw SettingsArchiveError.damaged(section: key.rawValue)
        }
    }
}

extension OpenDisplaySettings {
    /// The key of the first setting whose value can't be used as it is, or nil when every one can.
    /// Technical validity only — a value that can't be represented, or would overflow, where the
    /// app uses it. Product ranges stay with the features that own them (the revert window's
    /// 3-second floor, for one), so nothing here limits what a user may choose.
    public var unusableValueKey: String? {
        // The keep-or-revert countdown turns these seconds into a TimeInterval and back into whole
        // seconds: a count `Double` can't hold exactly (Int.max rounds up to 2^63, past Int) is not
        // representable there, and a negative duration isn't a countdown at all.
        if arrangementAutoRevertSeconds < 0 || Double(exactly: arrangementAutoRevertSeconds) == nil {
            return "arrangementAutoRevertSeconds"
        }
        // The disconnect countdown takes the same Double round trip.
        if confirmationCountdownSeconds < 0 || Double(exactly: confirmationCountdownSeconds) == nil {
            return "confirmationCountdownSeconds"
        }
        // Each of these is defined as a minute of the day; anything else names no time at all.
        if !(0..<Self.minutesPerDay).contains(adaptiveDayStartMinute) { return "adaptiveDayStartMinute" }
        if !(0..<Self.minutesPerDay).contains(adaptiveNightStartMinute) { return "adaptiveNightStartMinute" }
        // Durations in minutes become seconds where they're scheduled: a negative one isn't a
        // duration, and one whose seconds overflow `Int` traps there.
        if !Self.isMinuteDuration(adaptiveTransitionMinutes) { return "adaptiveTransitionMinutes" }
        if let minutes = xdrAutoOffMinutes, !Self.isMinuteDuration(minutes) { return "xdrAutoOffMinutes" }
        // Levels are fractions of the panel's range (0...1 is their defined domain); a non-finite or
        // out-of-domain level trapped Settings when it was shown as a whole percentage.
        if !Self.isLevel(adaptiveFallbackDayLevel) { return "adaptiveFallbackDayLevel" }
        if !Self.isLevel(adaptiveFallbackNightLevel) { return "adaptiveFallbackNightLevel" }
        if let percent = xdrLowBatteryCutoffPercent, !(0...100).contains(percent) { return "xdrLowBatteryCutoffPercent" }
        // Luminance is a non-negative number of cd/m²; an entry outside that names no light.
        if luminanceAnchorsByDisplay.values.contains(where: { $0.unusableAnchor != nil }) {
            return "luminanceAnchorsByDisplay"
        }
        // Delays and durations are scheduled in nanoseconds: negative, non-finite or overflowing
        // seconds can't be. Names the invalid key on import; application falls back to automatic.
        if let field = applicationTiming.unusableFieldKey { return "applicationTiming.\(field)" }
        return nil
    }

    private static let minutesPerDay = 24 * 60

    private static func isMinuteDuration(_ minutes: Int) -> Bool {
        minutes >= 0 && !minutes.multipliedReportingOverflow(by: 60).overflow
    }

    private static func isLevel(_ level: Float) -> Bool {
        level.isFinite && (0...1).contains(level)
    }

    /// These settings with every restore ledger emptied. The ledgers record what a display looked
    /// like before FaceLight, an evening preset or an app preset changed it — and which receiver app
    /// holds the feedback settings, with the user's own to give back (IN-16); they belong to the
    /// live session on this Mac, so an archive never carries them.
    public func withoutRestoreLedgers() -> OpenDisplaySettings {
        var copy = self
        // Export the user's preferences, not the temporary receiver overlay.
        OSDReceiverHandshake.release(&copy)
        copy.faceLightPriorStateByDisplay = [:]
        copy.adaptiveDayPresetByDisplay = [:]
        copy.appPresetPriorStateByDisplay = [:]
        copy.osdFeedback.receiverClaim = nil
        return copy
    }

    /// These settings carrying `live`'s restore ledgers. An import or reset replaces preferences,
    /// never a debt: a display FaceLight or a preset currently holds is still owed its own values
    /// back, and dropping the ledger would strand it at the applied ones.
    public func withRestoreLedgers(from live: OpenDisplaySettings) -> OpenDisplaySettings {
        var copy = self
        copy.faceLightPriorStateByDisplay = live.faceLightPriorStateByDisplay
        copy.adaptiveDayPresetByDisplay = live.adaptiveDayPresetByDisplay
        copy.appPresetPriorStateByDisplay = live.appPresetPriorStateByDisplay
        // Import is an explicit replacement of feedback preferences too. A receiver's older
        // snapshot must never undo those newly imported choices on a later release.
        copy.osdFeedback.receiverClaim = nil
        return copy
    }
}

/// Where settings backups go, and the replace sequence that must write one first (SO-11/FA-10).
/// Backups are ordinary archives — restore one with Import — kept next to the other Application
/// Support state. Nothing prunes them; each is a few kilobytes.
public struct SettingsBackupStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `<Application Support>/OpenDisplay/settings-backups`.
    public static func defaultDirectory(fileManager: FileManager = .default) throws -> URL {
        try SettingsStore.defaultDirectory(fileManager: fileManager)
            .appendingPathComponent("settings-backups", isDirectory: true)
    }

    /// Writes `archive` as a new, timestamped backup and returns its location. Never overwrites an
    /// earlier backup: a second one in the same second gets a numbered name.
    @discardableResult
    public func backUp(_ archive: SettingsArchive, now: Date = Date()) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = "settings-backup-\(formatter.string(from: now))"
        var url = directory.appendingPathComponent("\(stem).json")
        var counter = 2
        while fileManager.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(stem)-\(counter).json")
            counter += 1
        }
        try archive.write(to: url)
        return url
    }

    /// What to install, and where the backup of the state it replaces went.
    public struct Replacement: Hashable, Sendable {
        public let backupURL: URL
        /// The incoming archive with the live restore ledgers carried over into its settings.
        public let archive: SettingsArchive
    }

    /// The first half of an import or reset: back up `current`, then hand back `incoming` with
    /// `live`'s restore ledgers carried over (`withRestoreLedgers(from:)`). Throws without
    /// producing anything to install when the backup can't be written — replacing settings with
    /// no way back is exactly what this sequence exists to prevent.
    public func prepareReplacement(current: SettingsArchive, live: OpenDisplaySettings,
                                   incoming: SettingsArchive, now: Date = Date()) throws -> Replacement {
        let backupURL = try backUp(current, now: now)
        var toInstall = incoming
        toInstall.settings = incoming.settings.withRestoreLedgers(from: live)
        return Replacement(backupURL: backupURL, archive: toInstall)
    }
}
