import Foundation

/// The resolutions a user has pinned ("favourited") per display, so they surface first and can be
/// recalled quickly. Pure value logic in the cross-platform core (exercised by `make test`); the disk
/// store and UI live elsewhere. Favourites are keyed by **stable display identity**
/// (`DisplayRecordID`), so they survive reconnects, and by the **exact mode** — logical size,
/// framebuffer, unrounded refresh rate, density and (when known) bit depth — so 59.94 Hz and 60 Hz,
/// or a HiDPI and a LoDPI variant of one size, are separate favourites.
///
/// Older versions stored a rounded key (point size + integer refresh + HiDPI marker, e.g.
/// `1920x1080@60@2x`) that could not tell 59.94 from 60 Hz. Such keys are still read — they match
/// every mode they used to — and `migrateLegacyKeys(among:for:)` rewrites them into exact keys for
/// all the modes they covered, so no favourite is lost; a legacy key that matches nothing on hand is
/// kept untouched until it can be resolved.
public struct FavoriteResolutions: Hashable, Sendable, Codable {
    /// Per-display favourite mode keys, **newest first**. The persisted shape is unchanged from the
    /// rounded-key era; only the strings it holds are more precise.
    private var byDisplay: [String: [String]]

    public init(byDisplay: [String: [String]] = [:]) { self.byDisplay = byDisplay }

    /// The exact key for a mode: `<pt>x<pt>/<px>x<px>@<hz to 3 decimals>[@2x][#<bits>]`, e.g.
    /// `1920x1080/3840x2160@59.940@2x`. The `/` is what tells it apart from a legacy key.
    public static func key(for mode: DisplayMode) -> String {
        let hz = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), mode.refreshHz)
        return "\(mode.pointWidth)x\(mode.pointHeight)/\(mode.pixelWidth)x\(mode.pixelHeight)@\(hz)"
            + (mode.isHiDPI ? "@2x" : "") + (mode.bitDepth.map { "#\($0)" } ?? "")
    }

    /// The rounded key older versions stored: point size + integer refresh + HiDPI marker.
    public static func legacyKey(for mode: DisplayMode) -> String {
        "\(mode.pointWidth)x\(mode.pointHeight)@\(Int(mode.refreshHz.rounded()))" + (mode.isHiDPI ? "@2x" : "")
    }

    /// Whether a stored key names `mode`. Exact keys compare like `DisplayModeChoices.matches`
    /// (framebuffer and density exactly, refresh within floating-point noise, depth when the key
    /// carries one); legacy keys keep their old rounded meaning.
    public static func key(_ key: String, matches mode: DisplayMode) -> Bool {
        guard let stored = exactMode(from: key) else { return key == legacyKey(for: mode) }
        return DisplayModeChoices.matches(mode, requested: stored)
    }

    public func isFavorite(_ mode: DisplayMode, for display: DisplayRecordID) -> Bool {
        (byDisplay[display.rawValue] ?? []).contains { Self.key($0, matches: mode) }
    }

    public func favoriteKeys(for display: DisplayRecordID) -> [String] {
        byDisplay[display.rawValue] ?? []
    }

    /// Adds the mode as a favourite if absent (newest first), removes it if already present.
    ///
    /// Pass every mode the display currently offers as `available` whenever it is known: a legacy
    /// key that also covers a sibling (the 59.94 Hz twin of a 60 Hz mode) is first expanded into
    /// exact keys, so un-favouriting one mode doesn't silently un-favourite the other.
    public mutating func toggle(_ mode: DisplayMode, among available: [DisplayMode] = [],
                                for display: DisplayRecordID) {
        if isFavorite(mode, for: display) {
            remove(mode, among: available, for: display)
        } else {
            add(mode, for: display)
        }
    }

    public mutating func add(_ mode: DisplayMode, for display: DisplayRecordID) {
        guard !isFavorite(mode, for: display) else { return }
        byDisplay[display.rawValue, default: []].insert(Self.key(for: mode), at: 0)
    }

    /// Removes the mode. See `toggle` for why `available` matters to a legacy key.
    public mutating func remove(_ mode: DisplayMode, among available: [DisplayMode] = [],
                                for display: DisplayRecordID) {
        guard isFavorite(mode, for: display) else { return }
        migrateLegacyKeys(among: available + [mode], for: display)
        let list = (byDisplay[display.rawValue] ?? []).filter { !Self.key($0, matches: mode) }
        byDisplay[display.rawValue] = list.isEmpty ? nil : list
    }

    /// Rewrites each legacy key, in place, into the exact keys of every mode in `modes` it matches,
    /// skipping exact keys already present. A legacy key that matches none of `modes` is retained:
    /// the display may simply not offer that mode right now. Returns whether anything changed.
    @discardableResult
    public mutating func migrateLegacyKeys(among modes: [DisplayMode], for display: DisplayRecordID) -> Bool {
        let list = byDisplay[display.rawValue] ?? []
        guard list.contains(where: { Self.exactMode(from: $0) == nil }) else { return false }
        var migrated: [String] = []
        for key in list {
            guard Self.exactMode(from: key) == nil else {
                if !migrated.contains(key) { migrated.append(key) }
                continue
            }
            let expanded = modes.filter { Self.key(key, matches: $0) }.map(Self.key(for:))
            if expanded.isEmpty {
                migrated.append(key)
            } else {
                for exact in expanded where !migrated.contains(exact) && !list.contains(exact) {
                    migrated.append(exact)
                }
            }
        }
        guard migrated != list else { return false }
        byDisplay[display.rawValue] = migrated.isEmpty ? nil : migrated
        return true
    }

    /// The favourite modes among `available`, newest favourite first. A legacy key resolves to every
    /// mode it matches; favourites the display doesn't offer right now are simply absent here (they
    /// stay stored — see `favoriteKeys(for:)`).
    public func favoriteModes(among available: [DisplayMode], for display: DisplayRecordID) -> [DisplayMode] {
        var result: [DisplayMode] = []
        for key in byDisplay[display.rawValue] ?? [] {
            for mode in available where Self.key(key, matches: mode) && !result.contains(mode) {
                result.append(mode)
            }
        }
        return result
    }

    /// The stored keys naming none of `available` — favourites the display doesn't offer right now,
    /// newest first. They are kept and never substituted by a near match; listing them is what lets
    /// a user still see and remove them.
    public func unavailableKeys(among available: [DisplayMode], for display: DisplayRecordID) -> [String] {
        favoriteKeys(for: display).filter { key in !available.contains { Self.key(key, matches: $0) } }
    }

    /// Removes one stored key as it is — an unavailable favourite has no offered mode to match.
    public mutating func removeKey(_ key: String, for display: DisplayRecordID) {
        let list = (byDisplay[display.rawValue] ?? []).filter { $0 != key }
        byDisplay[display.rawValue] = list.isEmpty ? nil : list
    }

    /// Drops every favourite of one display — part of forgetting it, never of an ordinary edit.
    public mutating func removeAll(for display: DisplayRecordID) {
        byDisplay[display.rawValue] = nil
    }

    /// Removes every stored key naming this logical size, density and refresh rate (within the
    /// usual tolerance) whatever its framebuffer — for a caller that knows only those, like the CLI
    /// un-setting a favourite the display no longer offers. Legacy keys go when their rounded form
    /// equals the spec's. Returns the removed keys.
    @discardableResult
    public mutating func removeKeys(matchingLogical spec: DisplayMode, for display: DisplayRecordID) -> [String] {
        let list = byDisplay[display.rawValue] ?? []
        let removed = list.filter { key in
            guard let stored = Self.exactMode(from: key) else { return key == Self.legacyKey(for: spec) }
            return stored.pointWidth == spec.pointWidth && stored.pointHeight == spec.pointHeight
                && stored.isHiDPI == spec.isHiDPI && abs(stored.refreshHz - spec.refreshHz) < 0.01
        }
        let kept = list.filter { !removed.contains($0) }
        byDisplay[display.rawValue] = kept.isEmpty ? nil : kept
        return removed
    }

    /// The mode an exact key names; nil for a legacy rounded key, which never recorded one.
    public static func storedMode(forKey key: String) -> DisplayMode? { exactMode(from: key) }

    /// Favourites (newest first, resolved against `stops` so stale ones drop out) followed by the
    /// remaining area-sorted stops — deduped. The single list a resolution control steps through.
    public func merged(stops: [DisplayMode], for display: DisplayRecordID) -> [DisplayMode] {
        let favorites = favoriteModes(among: stops, for: display)
        return favorites + stops.filter { !favorites.contains($0) }
    }

    /// Parses an exact key back into the mode it names, or nil for a legacy (or foreign) key.
    static func exactMode(from key: String) -> DisplayMode? {
        var rest = Substring(key)
        var bitDepth: Int?
        if let hash = rest.lastIndex(of: "#") {
            guard let bits = Int(rest[rest.index(after: hash)...]) else { return nil }
            bitDepth = bits
            rest = rest[..<hash]
        }
        let isHiDPI = rest.hasSuffix("@2x")
        if isHiDPI { rest = rest.dropLast(3) }
        let sizesAndRate = rest.split(separator: "@")
        guard sizesAndRate.count == 2, let hz = Double(sizesAndRate[1]) else { return nil }
        let sizes = sizesAndRate[0].split(separator: "/")
        guard sizes.count == 2 else { return nil }
        let points = sizes[0].split(separator: "x").compactMap { Int($0) }
        let pixels = sizes[1].split(separator: "x").compactMap { Int($0) }
        guard points.count == 2, pixels.count == 2 else { return nil }
        return DisplayMode(pixelWidth: pixels[0], pixelHeight: pixels[1],
                           pointWidth: points[0], pointHeight: points[1],
                           refreshHz: hz, isHiDPI: isHiDPI, bitDepth: bitDepth)
    }
}
