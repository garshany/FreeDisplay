import DisplayDomain
import Foundation

/// Where an item family appears in the tray (AM-11, SO-23, FA-14). Placement is presentation only:
/// it never changes the feature it shows, and it never makes a control appear that the display or
/// build can't actually offer — capability is decided first, placement second.
public enum MenuPlacement: String, Hashable, Sendable, Codable, CaseIterable {
    /// In the display's section itself, without opening anything.
    case visible
    /// Behind the display's «More» chevron.
    case expanded
    /// Not in the tray. The feature keeps working and stays reachable from Settings.
    case hidden
}

/// The tray's item families, one per row or slider a user can place. The registry is declarative so
/// Settings, the tray and the reset agree on the same defaults: the defaults are the layout the tray
/// had before it was customizable, so an untouched install looks exactly as it did.
public enum MenuItemFamily: String, Hashable, Sendable, CaseIterable, Identifiable {
    case brightness = "slider.brightness"
    case resolution = "slider.resolution"
    case volume = "slider.volume"
    case displayMode = "feature.mode"
    case refreshRate = "feature.refresh"
    case toggles = "feature.toggles"
    case picture = "feature.image"
    case monitorControls = "feature.device"
    case inputSource = "feature.input"
    case monitorColorPreset = "feature.colorMode"
    case colorProfile = "feature.profile"
    case rotation = "feature.rotation"
    case mirroring = "feature.mirror"
    case pictureInPicture = "feature.pip"
    case manageDisplay = "feature.manage"
    case scenes = "tool.scenes"
    case arrangement = "tool.arrangement"
    case capture = "tool.capture"
    case edid = "tool.edid"
    case automation = "tool.automation"
    case hotkeysAndDiagnostics = "tool.diagnostics"
    case exportDiagnostics = "tool.exportDiagnostics"
    case updates = "tool.updates"

    public var id: String { rawValue }

    public enum Section: String, Hashable, Sendable, CaseIterable {
        /// A slider at the top of a display's section.
        case slider
        /// A per-display feature row that unfolds in place.
        case displayFeature
        /// A row of the shared Tools section. Tools already sit behind their own «…» button, so they
        /// are either listed there or not.
        case tool
    }

    public var section: Section {
        switch self {
        case .brightness, .resolution, .volume: return .slider
        case .scenes, .arrangement, .capture, .edid, .automation, .hotkeysAndDiagnostics,
             .exportDiagnostics, .updates:
            return .tool
        default: return .displayFeature
        }
    }

    /// The feature id the tray already uses for this row's open/closed state ("<device>|<id>"), so
    /// expansion state and accessibility identifiers keep their existing spelling.
    public var trayID: String {
        String(rawValue.split(separator: ".", maxSplits: 1).last ?? Substring(rawValue))
    }

    public var defaultPlacement: MenuPlacement {
        switch section {
        case .slider, .tool: return .visible
        case .displayFeature: return .expanded
        }
    }

    /// The placements Settings offers. A tool has no «More» level to be moved to.
    public var allowedPlacements: [MenuPlacement] {
        section == .tool ? [.visible, .hidden] : MenuPlacement.allCases
    }

    public static func families(in section: Section) -> [MenuItemFamily] {
        allCases.filter { $0.section == section }
    }
}

/// One display's own tray presentation, keyed by the observation id (`cg:<uuid>`) like every other
/// per-display preference, so forgetting a display finds it with the rest.
public struct DisplayMenuPreferences: Hashable, Sendable, Codable {
    /// Leave the display out of the tray. It stays connected and keeps receiving keys and
    /// automation: hiding is presentation, not a disconnect.
    public var hidden: Bool
    /// An SF Symbol name shown instead of the class glyph. Nil = the glyph for the display's class.
    public var iconSymbol: String?

    public init(hidden: Bool = false, iconSymbol: String? = nil) {
        self.hidden = hidden
        self.iconSymbol = iconSymbol
    }

    public var isDefault: Bool { !hidden && iconSymbol == nil }

    private enum CodingKeys: String, CodingKey { case hidden, iconSymbol }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hidden = (try? container.decodeIfPresent(Bool.self, forKey: .hidden)) ?? false
        iconSymbol = (try? container.decodeIfPresent(String.self, forKey: .iconSymbol)) ?? nil
    }
}

/// Everything about how the tray is laid out, kept apart from `OpenDisplaySettings` so "Reset menu
/// layout" has a scope of its own and can't reach a display setting. Tolerant decoding like the main
/// settings file: an unknown family, placement or key degrades that one entry, never the file.
public struct MenuLayoutSettings: Hashable, Sendable, Codable {
    /// Placement overrides by `MenuItemFamily.rawValue`. Absent = the family's default, which is
    /// why only overrides are stored: a later release can change a default for untouched families.
    public var placements: [String: MenuPlacement]
    /// Per-display presentation, by observation id raw value.
    public var displays: [String: DisplayMenuPreferences]
    /// Manual tray order: observation id raw values, first shown first. Displays not listed follow,
    /// in the automatic order (`MenuDisplayOrder`).
    public var displayOrder: [String]
    /// Restore which «More» sections, features and Tools were open the next time the tray opens.
    /// Off by default: the tray opens compact.
    public var rememberExpandedSections: Bool
    /// Opening one display's «More» closes another's (BetterDisplay's "tidy up").
    public var oneMoreSectionAtATime: Bool
    /// Opening a feature closes the other open features of the same display.
    public var oneFeatureAtATime: Bool
    /// The main display goes first, ahead of the manual order.
    public var mainDisplayFirst: Bool
    /// Animate sections opening and closing. macOS Reduce Motion turns animation off regardless.
    public var animateMenu: Bool
    /// Name each slider above its track.
    public var showSliderNames: Bool
    /// Show the slider's current value next to its track.
    public var showSliderValues: Bool

    public init(
        placements: [String: MenuPlacement] = [:],
        displays: [String: DisplayMenuPreferences] = [:],
        displayOrder: [String] = [],
        rememberExpandedSections: Bool = false,
        oneMoreSectionAtATime: Bool = false,
        oneFeatureAtATime: Bool = false,
        mainDisplayFirst: Bool = false,
        animateMenu: Bool = true,
        showSliderNames: Bool = false,
        showSliderValues: Bool = true
    ) {
        self.placements = placements
        self.displays = displays
        self.displayOrder = displayOrder
        self.rememberExpandedSections = rememberExpandedSections
        self.oneMoreSectionAtATime = oneMoreSectionAtATime
        self.oneFeatureAtATime = oneFeatureAtATime
        self.mainDisplayFirst = mainDisplayFirst
        self.animateMenu = animateMenu
        self.showSliderNames = showSliderNames
        self.showSliderValues = showSliderValues
    }

    public static let `default` = MenuLayoutSettings()

    // MARK: Item placement

    /// The family's placement: the stored override when it's one the family allows, else its default.
    public func placement(of family: MenuItemFamily) -> MenuPlacement {
        guard let stored = placements[family.rawValue], family.allowedPlacements.contains(stored) else {
            return family.defaultPlacement
        }
        return stored
    }

    /// Stores a placement; choosing the default (or one the family doesn't allow) drops the override.
    public mutating func setPlacement(_ placement: MenuPlacement, for family: MenuItemFamily) {
        if placement == family.defaultPlacement || !family.allowedPlacements.contains(placement) {
            placements[family.rawValue] = nil
        } else {
            placements[family.rawValue] = placement
        }
    }

    /// True when every family sits where it does by default.
    public var hasDefaultContents: Bool {
        MenuItemFamily.allCases.allSatisfy { placement(of: $0) == $0.defaultPlacement }
    }

    /// "Reset menu layout": every family back to its default placement. Nothing else — per-display
    /// names, icons, visibility and order, and the behaviour switches, are the user's other choices
    /// and stay; no display setting is part of this type at all.
    public func resettingMenuContents() -> MenuLayoutSettings {
        var reset = self
        reset.placements = [:]
        return reset
    }

    // MARK: Per-display presentation

    public func preferences(for display: DisplayRecordID) -> DisplayMenuPreferences {
        displays[display.rawValue] ?? DisplayMenuPreferences()
    }

    public func isHidden(_ display: DisplayRecordID) -> Bool {
        preferences(for: display).hidden
    }

    /// The custom icon, if one is set and non-blank.
    public func iconSymbol(for display: DisplayRecordID) -> String? {
        guard let symbol = preferences(for: display).iconSymbol?.trimmingCharacters(in: .whitespaces),
              !symbol.isEmpty else { return nil }
        return symbol
    }

    /// Whether the tray lists this display. A display the app turned off always keeps its card:
    /// that card is the one-click way back on, and hiding it would leave a dark screen whose only
    /// recovery is a menu the user removed it from.
    public func showsInTray(_ display: DisplayRecordID, turnedOffByApp: Bool) -> Bool {
        turnedOffByApp || !isHidden(display)
    }

    public mutating func setHidden(_ hidden: Bool, for displays: [DisplayRecordID]) {
        update(displays) { $0.hidden = hidden }
    }

    /// Sets (or, with nil/blank, clears) the custom icon.
    public mutating func setIconSymbol(_ symbol: String?, for displays: [DisplayRecordID]) {
        let trimmed = symbol?.trimmingCharacters(in: .whitespaces)
        update(displays) { $0.iconSymbol = (trimmed?.isEmpty ?? true) ? nil : trimmed }
    }

    /// Everything this type remembers about these displays, gone: presentation and order position.
    public func forgetting(_ ids: Set<DisplayRecordID>) -> MenuLayoutSettings {
        var trimmed = self
        let raw = Set(ids.map(\.rawValue))
        for key in raw { trimmed.displays[key] = nil }
        trimmed.displayOrder.removeAll { raw.contains($0) }
        return trimmed
    }

    /// Whether this type holds anything about these displays (what a forget preview reports).
    public func remembers(_ ids: Set<DisplayRecordID>) -> Bool {
        ids.contains { displays[$0.rawValue].map { !$0.isDefault } ?? false }
            || displayOrder.contains { key in ids.contains { $0.rawValue == key } }
    }

    private mutating func update(_ ids: [DisplayRecordID], _ change: (inout DisplayMenuPreferences) -> Void) {
        for id in ids {
            var prefs = preferences(for: id)
            change(&prefs)
            displays[id.rawValue] = prefs.isDefault ? nil : prefs
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case placements, displays, displayOrder, rememberExpandedSections, oneMoreSectionAtATime
        case oneFeatureAtATime, mainDisplayFirst, animateMenu, showSliderNames, showSliderValues
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MenuLayoutSettings.default
        // Raw strings first, so one placement a newer or older build doesn't know drops alone.
        let rawPlacements = (try? container.decodeIfPresent([String: String].self, forKey: .placements)) ?? nil
        placements = (rawPlacements ?? [:]).compactMapValues(MenuPlacement.init(rawValue:))
        displays = ((try? container.decodeIfPresent([String: DisplayMenuPreferences].self, forKey: .displays)) ?? nil)
            ?? defaults.displays
        displayOrder = ((try? container.decodeIfPresent([String].self, forKey: .displayOrder)) ?? nil)
            ?? defaults.displayOrder
        func flag(_ key: CodingKeys, _ fallback: Bool) -> Bool {
            ((try? container.decodeIfPresent(Bool.self, forKey: key)) ?? nil) ?? fallback
        }
        rememberExpandedSections = flag(.rememberExpandedSections, defaults.rememberExpandedSections)
        oneMoreSectionAtATime = flag(.oneMoreSectionAtATime, defaults.oneMoreSectionAtATime)
        oneFeatureAtATime = flag(.oneFeatureAtATime, defaults.oneFeatureAtATime)
        mainDisplayFirst = flag(.mainDisplayFirst, defaults.mainDisplayFirst)
        animateMenu = flag(.animateMenu, defaults.animateMenu)
        showSliderNames = flag(.showSliderNames, defaults.showSliderNames)
        showSliderValues = flag(.showSliderValues, defaults.showSliderValues)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(placements.mapValues(\.rawValue), forKey: .placements)
        try container.encode(displays, forKey: .displays)
        try container.encode(displayOrder, forKey: .displayOrder)
        try container.encode(rememberExpandedSections, forKey: .rememberExpandedSections)
        try container.encode(oneMoreSectionAtATime, forKey: .oneMoreSectionAtATime)
        try container.encode(oneFeatureAtATime, forKey: .oneFeatureAtATime)
        try container.encode(mainDisplayFirst, forKey: .mainDisplayFirst)
        try container.encode(animateMenu, forKey: .animateMenu)
        try container.encode(showSliderNames, forKey: .showSliderNames)
        try container.encode(showSliderValues, forKey: .showSliderValues)
    }
}

/// Atomic, on-disk store for `MenuLayoutSettings` at `<dir>/menu-layout.json`, beside the other
/// Application Support state. A missing or unreadable file degrades to the default layout.
public struct MenuLayoutStore: Sendable {
    private let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("menu-layout.json")
    }

    public func load() -> MenuLayoutSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let layout = try? JSONDecoder().decode(MenuLayoutSettings.self, from: data) else {
            return .default
        }
        return layout
    }

    public func save(_ layout: MenuLayoutSettings) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(layout).write(to: fileURL, options: .atomic)
    }
}

/// Tray order (FA-12): menu order only — it never moves a display on the desktop.
///
/// Rank, first decisive rule wins:
///   1. the main display, when "main display first" is on;
///   2. the manual order, for displays that have a place in it;
///   3. automatic order: the built-in panel, then by the name shown (case-insensitive, numbers in
///      numeric order), then by id, so two identically named monitors still never swap places.
/// Renaming moves a display only within the automatic part; a manually placed display keeps its slot.
public enum MenuDisplayOrder {
    public struct Candidate: Hashable, Sendable {
        /// The candidate's identity in the result (an observation id, or an inventory entry id).
        public var id: String
        /// The ids the manual order may list it under — the observation ids it has been seen with.
        public var orderKeys: [String]
        public var name: String
        public var isMain: Bool
        public var isBuiltIn: Bool

        public init(id: String, orderKeys: [String]? = nil, name: String, isMain: Bool = false,
                    isBuiltIn: Bool = false) {
            self.id = id
            self.orderKeys = orderKeys ?? [id]
            self.name = name
            self.isMain = isMain
            self.isBuiltIn = isBuiltIn
        }
    }

    public static func sorted(_ candidates: [Candidate], manualOrder: [String], mainFirst: Bool) -> [Candidate] {
        var rankByKey: [String: Int] = [:]
        for (index, key) in manualOrder.enumerated() where rankByKey[key] == nil { rankByKey[key] = index }
        func rank(_ candidate: Candidate) -> Int? { candidate.orderKeys.compactMap { rankByKey[$0] }.min() }
        return candidates.sorted { lhs, rhs in
            if mainFirst, lhs.isMain != rhs.isMain { return lhs.isMain }
            switch (rank(lhs), rank(rhs)) {
            case let (l?, r?) where l != r: return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            if lhs.isBuiltIn != rhs.isBuiltIn { return lhs.isBuiltIn }
            let byName = lhs.name.compare(rhs.name, options: [.caseInsensitive, .numeric])
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    /// The manual order that pins the given sequence: every candidate's keys, in sequence. Writing
    /// the whole visible sequence (rather than just the moved one) is what makes a move stick once
    /// automatic ordering would otherwise have interleaved the others.
    public static func manualOrder(pinning sequence: [Candidate]) -> [String] {
        var seen: Set<String> = []
        return sequence.flatMap(\.orderKeys).filter { seen.insert($0).inserted }
    }

    /// `sequence` with the candidate at `index` moved to `destination` (an index into the result),
    /// clamped to the list. Out-of-range `index` returns the sequence unchanged.
    public static func moving(_ sequence: [Candidate], from index: Int, to destination: Int) -> [Candidate] {
        guard sequence.indices.contains(index) else { return sequence }
        var result = sequence
        let moved = result.remove(at: index)
        result.insert(moved, at: min(max(destination, 0), result.count))
        return result
    }
}

/// Tray expansion bookkeeping (FA-13), kept pure so the policies are testable. Feature ids are
/// "<device>|<feature>", the form the tray stores.
public enum MenuExpansionPolicy {
    /// The open «More» sections after toggling `device`. With "one at a time", opening one closes
    /// the others — only the More areas: an open feature inside a closed More reappears with it.
    public static func togglingMore(_ open: Set<String>, device: String, oneAtATime: Bool) -> Set<String> {
        if open.contains(device) { return open.subtracting([device]) }
        return oneAtATime ? [device] : open.union([device])
    }

    /// The open features after toggling `feature`. With "one at a time", opening closes the other
    /// open features of the same display; other displays' features are left as they are.
    public static func togglingFeature(_ open: Set<String>, feature: String, oneAtATime: Bool) -> Set<String> {
        if open.contains(feature) { return open.subtracting([feature]) }
        guard oneAtATime, let device = device(ofFeature: feature) else { return open.union([feature]) }
        return open.filter { self.device(ofFeature: $0) != device }.union([feature])
    }

    /// Drops every entry that belongs to one of `devices` — a whole-device key or one of its features.
    public static func forgetting(_ entries: Set<String>, devices: Set<String>) -> Set<String> {
        entries.filter { entry in
            !devices.contains(entry) && !(device(ofFeature: entry).map(devices.contains) ?? false)
        }
    }

    public static func device(ofFeature feature: String) -> String? {
        guard let bar = feature.lastIndex(of: "|") else { return nil }
        return String(feature[..<bar])
    }
}
