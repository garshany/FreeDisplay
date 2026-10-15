import AutomationSchema
import DisplayDomain
import Foundation

/// One display as an automation picker offers it (IN-07): Shortcuts' display parameter, typed by the
/// stable record id so a saved shortcut keeps pointing at the same panel across reconnects and
/// reordered ports.
public struct AutomationDisplayEntry: Hashable, Sendable, Identifiable {
    public enum Availability: String, Hashable, Sendable {
        /// Connected and part of the desktop — every action can target it.
        case active
        /// Connected but not a desktop of its own right now (e.g. a mirror member): it can be named,
        /// but actions that need an active display refuse it.
        case inactive
        /// Not connected: turned off by OpenDisplay, unplugged, or only remembered. Still listed so a
        /// saved shortcut resolves and then fails clearly instead of silently retargeting.
        case disconnected
    }

    public var id: DisplayRecordID
    public var name: String
    public var availability: Availability
    public var isMain: Bool
    public var isBuiltIn: Bool

    public init(id: DisplayRecordID, name: String, availability: Availability, isMain: Bool, isBuiltIn: Bool) {
        self.id = id
        self.name = name
        self.availability = availability
        self.isMain = isMain
        self.isBuiltIn = isBuiltIn
    }
}

/// Where an automation action's display parameter points (IN-07/TB-05/TB-06). A missing or inactive
/// target is reported as such — it is never replaced by the main or built-in display.
public enum AutomationDisplayTarget: Hashable, Sendable {
    case active(DisplayObservation)
    /// Present but not an active desktop.
    case inactive(DisplayObservation)
    /// Not among the current displays at all.
    case missing
}

/// The pure half of the App Intents display picker and target resolution (IN-07): what to list, in
/// which order, how saved identifiers come back, and which observation an action may act on.
public enum AutomationDisplayCatalog {
    /// Every display the app can currently name: the current ones (main first, then the other active
    /// displays, then inactive ones, each group by name), then the displays OpenDisplay turned off.
    /// A ledger entry whose display is back is listed once, as the current display.
    public static func entries(displays: [DisplayObservation], offline: [ManagedOfflineDisplay],
                               name: (DisplayObservation) -> String) -> [AutomationDisplayEntry] {
        let current = displays.map { observation in
            AutomationDisplayEntry(id: observation.recordID, name: name(observation),
                                   availability: observation.isActive ? .active : .inactive,
                                   isMain: observation.isMain && observation.isActive,
                                   isBuiltIn: observation.displayClass == .builtIn)
        }.sorted(by: listOrder)
        let listed = Set(current.map(\.id))
        let off = offline.filter { !listed.contains($0.recordID) }.map {
            AutomationDisplayEntry(id: $0.recordID, name: $0.name, availability: .disconnected,
                                   isMain: false, isBuiltIn: $0.displayClass == .builtIn)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return current + off
    }

    /// The entries whose name contains `query`, ignoring case and diacritics; an empty query matches
    /// everything.
    public static func entries(matching query: String, in entries: [AutomationDisplayEntry]) -> [AutomationDisplayEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter { $0.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// Brings saved identifiers back, in the order asked. Every identifier comes back: one that isn't
    /// listed right now returns as disconnected — named as the app remembers it, or by its raw id
    /// when it doesn't (records may still be loading right after launch). Dropping it instead would
    /// leave the action's display parameter empty, and an action whose empty display has a default
    /// target would then act on that display instead of failing.
    public static func resolve(_ identifiers: [String], in entries: [AutomationDisplayEntry],
                               rememberedName: (DisplayRecordID) -> String?) -> [AutomationDisplayEntry] {
        identifiers.map { raw in
            let id = DisplayRecordID(rawValue: raw)
            if let entry = entries.first(where: { $0.id == id }) { return entry }
            return AutomationDisplayEntry(id: id, name: rememberedName(id) ?? raw, availability: .disconnected,
                                          isMain: false, isBuiltIn: false)
        }
    }

    /// The observation an action on `id` may use.
    public static func target(_ id: DisplayRecordID, in displays: [DisplayObservation]) -> AutomationDisplayTarget {
        guard let observation = displays.first(where: { $0.recordID == id }) else { return .missing }
        return observation.isActive ? .active(observation) : .inactive(observation)
    }

    /// The active built-in panel — the documented target of the brightness action when no display is
    /// chosen (kept for shortcuts saved before the action took one). Nil on a Mac without one or with
    /// the lid closed; never another display instead.
    public static func activeBuiltIn(in displays: [DisplayObservation]) -> DisplayObservation? {
        displays.first { $0.displayClass == .builtIn && $0.isActive }
    }

    /// The shared automation candidates (FD-066) for a surface's displays: every current observation
    /// with its registry record, then the displays OpenDisplay turned off that aren't observed. A
    /// ledger display that a surface lists as an inactive placeholder observation (the CLI does, to
    /// keep it reachable) is `disconnected`, not merely inactive — it isn't there at all.
    ///
    /// - Parameters:
    ///   - name: the name the surface shows for a live display (the alias first).
    ///   - record: the registry record behind an observation or ledger id, when known.
    ///   - groups: the display groups whose names `group:<name>` resolves.
    ///   - pointerDisplayID: the Core Graphics id of the display under the pointer, or nil when the
    ///     surface can't tell (then `pointer` is refused rather than guessed).
    public static func displaySet(displays: [DisplayObservation], offline: [ManagedOfflineDisplay],
                                  name: (DisplayObservation) -> String,
                                  record: (DisplayRecordID) -> DisplayRecord?,
                                  groups: [DisplayGroup], pointerDisplayID: UInt32?,
                                  generation: UInt64) -> AutomationDisplaySet {
        let offlineIDs = Set(offline.map(\.recordID))
        func groupNames(_ ids: [DisplayRecordID]) -> Set<String> {
            Set(groups.filter { group in ids.contains(where: group.contains) }.map(\.name))
        }
        // A display that isn't there can't hold the pointer, even if its old number now names another.
        func pointer(_ cgID: UInt32?, present: Bool) -> Bool? {
            guard let pointerDisplayID else { return nil }
            return present && cgID == pointerDisplayID
        }
        var listed = Set<DisplayRecordID>()
        var candidates: [AutomationDisplayCandidate] = []
        for observation in displays where listed.insert(observation.recordID).inserted {
            let known = record(observation.recordID)
            let turnedOff = offlineIDs.contains(observation.recordID) && !observation.isActive
            let availability: AutomationDisplayCandidate.Availability =
                turnedOff ? .disconnected : observation.isActive ? .active : .inactive
            let reachability: Reachability =
                offlineIDs.contains(observation.recordID) ? .managedOffline : observation.isActive ? .active : .discoveredInactive
            candidates.append(AutomationDisplayCandidate(
                id: observation.recordID,
                registryID: known.map(\.id).flatMap { $0 == observation.recordID ? nil : $0 },
                cgDisplayID: observation.cgDisplayID, name: name(observation), alias: known?.alias,
                tags: known?.tags ?? [], groups: groupNames([observation.recordID] + (known.map { [$0.id] } ?? [])),
                availability: availability, reachability: reachability, isMain: observation.isMain,
                isBuiltIn: observation.displayClass == .builtIn, vendorID: known?.fingerprint.vendorID,
                productID: known?.fingerprint.productID, serial: known?.fingerprint.serialNumber,
                containsPointer: pointer(observation.cgDisplayID, present: !turnedOff)))
        }
        for display in offline where listed.insert(display.recordID).inserted {
            let known = record(display.recordID)
            candidates.append(AutomationDisplayCandidate(
                id: display.recordID,
                registryID: known.map(\.id).flatMap { $0 == display.recordID ? nil : $0 },
                cgDisplayID: display.cgID, name: known?.alias.flatMap { $0.isEmpty ? nil : $0 } ?? display.name,
                alias: known?.alias, tags: known?.tags ?? [],
                groups: groupNames([display.recordID] + (known.map { [$0.id] } ?? [])),
                availability: .disconnected, reachability: .managedOffline,
                isBuiltIn: display.displayClass == .builtIn, vendorID: known?.fingerprint.vendorID,
                productID: known?.fingerprint.productID, serial: known?.fingerprint.serialNumber,
                containsPointer: pointer(display.cgID, present: false)))
        }
        return AutomationDisplaySet(candidates: candidates, knownGroups: groups.map(\.name), topologyGeneration: generation)
    }

    private static func listOrder(_ lhs: AutomationDisplayEntry, _ rhs: AutomationDisplayEntry) -> Bool {
        func rank(_ entry: AutomationDisplayEntry) -> Int {
            entry.isMain ? 0 : entry.availability == .active ? 1 : 2
        }
        if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
        let byName = lhs.name.localizedStandardCompare(rhs.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        return lhs.id.rawValue < rhs.id.rawValue
    }
}

/// Brightness as App Intents express it (TB-05): whole percent 0–100 of the display's brightness
/// control, plus the comparison that decides whether the display confirmed a requested level.
public enum AutomationBrightness {
    /// What could be read back after a write settled.
    public enum Readback: Hashable, Sendable {
        /// A 0...1 level read from the display (native control), or — for software dimming — the
        /// level OpenDisplay applied on screen.
        case level(Float)
        /// A DDC/CI brightness reading in the monitor's own units.
        case ddc(current: Int, max: Int)
        /// Nothing could be read.
        case none
    }

    public struct Outcome: Hashable, Sendable {
        /// The level the display ended up at, in whole percent; nil when nothing could be read.
        public var resultingPercent: Int?
        /// True when the read-back matches the request.
        public var verified: Bool

        public init(resultingPercent: Int?, verified: Bool) {
            self.resultingPercent = resultingPercent
            self.verified = verified
        }
    }

    /// A 0...1 level in whole percent (the shared unit, `AutomationLevel`).
    public static func percent(_ level: Float) -> Int {
        AutomationLevel(clamping: Double(level)).wholePercent
    }

    /// A requested percentage as the 0...1 level the brightness funnel takes.
    public static func level(percent: Int) -> Float {
        AutomationLevel(clamping: Double(percent) / 100).float
    }

    /// Compares a read-back with the request. A percentage read-back must land on the requested whole
    /// percent — the unit the action speaks. A DDC read-back is judged in the monitor's own units,
    /// exactly as the app's own write verification judges every DDC brightness write (one unit of
    /// rounding/quantisation), so a monitor with a coarse scale isn't called wrong for rounding.
    public static func outcome(requestedPercent: Int, readback: Readback) -> Outcome {
        let requested = min(100, max(0, requestedPercent))
        switch readback {
        case .none:
            return Outcome(resultingPercent: nil, verified: false)
        case .level(let level):
            let actual = percent(level)
            return Outcome(resultingPercent: actual, verified: actual == requested)
        case .ddc(let current, let max):
            guard max > 0 else { return Outcome(resultingPercent: nil, verified: false) }
            // The same scaling `AppModel.setBrightness` uses to turn a level into a DDC target.
            let target = Int((level(percent: requested) * Float(max)).rounded())
            let verdict = DDCWriteVerification.outcome(target: target, readback: current, tolerance: 1)
            return Outcome(resultingPercent: percent(Float(current) / Float(max)), verified: verdict == .applied)
        }
    }
}

/// The display-mode parameter of App Intents (TB-06): the exact choices a display offers, the stable
/// key a saved shortcut stores, and the verdict after a change.
public enum AutomationModeOptions {
    /// Every exact mode the display offers (each framebuffer, refresh rate, density and depth is its
    /// own choice — nothing collapsed or substituted), largest first, with the current mode included.
    public static func options(from modes: [DisplayMode], current: DisplayMode?) -> [DisplayMode] {
        DisplayModeChoices.ordered(from: modes, current: current).reversed()
    }

    /// The identifier a shortcut stores for a mode — the same exact key favourites use.
    public static func key(for mode: DisplayMode) -> String { FavoriteResolutions.key(for: mode) }

    /// The mode a stored identifier names, or nil when it isn't an exact mode key.
    public static func mode(forKey key: String) -> DisplayMode? { FavoriteResolutions.storedMode(forKey: key) }

    /// The offered mode a stored mode names exactly (refresh within floating-point noise), or nil
    /// when the display doesn't offer it now. Never a nearest match.
    public static func offered(_ requested: DisplayMode, among modes: [DisplayMode]) -> DisplayMode? {
        modes.first { DisplayModeChoices.matches($0, requested: requested) }
    }

    public enum Outcome: Hashable, Sendable {
        /// The display was already in the requested mode; nothing changed.
        case alreadyInEffect
        /// macOS confirmed the new mode; it stays only if the user keeps it before the countdown ends.
        case awaitingConfirmation
        /// The change was refused or rolled back, with the app's explanation.
        case failed(String)
        /// No error, but the display isn't in the requested mode either.
        case notConfirmed
    }

    /// Reads the app's state after a mode request: its error message (nil when it raised none),
    /// whether a keep/revert window is open, and the display's mode as observed afterwards.
    public static func outcome(error: String?, revertPending: Bool, actual: DisplayMode?,
                               requested: DisplayMode) -> Outcome {
        if let error { return .failed(error) }
        guard let actual, DisplayModeChoices.matches(actual, requested: requested) else { return .notConfirmed }
        return revertPending ? .awaitingConfirmation : .alreadyInEffect
    }
}
