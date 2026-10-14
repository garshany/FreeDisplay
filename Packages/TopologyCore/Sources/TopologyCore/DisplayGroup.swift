import DisplayDomain
import Foundation

/// A user-defined set of displays whose brightness (and optionally contrast) moves together — the
/// "groups, sync" half of PRD §5.3's controls line. Distinct from Adaptive Display's built-in →
/// external mirror: the members are chosen by hand, any member drives the rest, and the group keeps
/// working with the built-in panel turned off.
///
/// `offsetByMember` is what keeps two mismatched panels usable together: a follower is written at
/// `leader + offset`, and the offset is *learned* from the user's own correction rather than
/// configured up front (see `GroupSyncPolicy.classify`, outcome `.followerCorrection`). Keys are
/// `DisplayRecordID.rawValue` — raw-representable dictionary keys encode as flat arrays in JSON, the
/// same reason `adaptiveBrightnessOffsetByDisplay` is String-keyed.
public struct DisplayGroup: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var memberRecordIDs: [DisplayRecordID]
    public var syncBrightness: Bool
    public var syncContrast: Bool
    public var offsetByMember: [String: Float]
    /// How a leader's brightness reaches the followers (TR-15/SO-05). Groups saved before the choice
    /// existed decode as `.offsets` — exactly what they did then.
    public var brightnessMode: BrightnessSyncMode
    /// Whether a brightness change made outside OpenDisplay (macOS keys, System Settings,
    /// auto-brightness) that the app only observed leads the group. On for groups saved before the
    /// switch existed, which always followed such changes.
    public var followsOutsideChanges: Bool

    public init(id: UUID = UUID(), name: String, memberRecordIDs: [DisplayRecordID] = [],
                syncBrightness: Bool = true, syncContrast: Bool = false,
                offsetByMember: [String: Float] = [:],
                brightnessMode: BrightnessSyncMode = .offsets,
                followsOutsideChanges: Bool = true) {
        self.id = id
        self.name = name
        self.memberRecordIDs = memberRecordIDs
        self.syncBrightness = syncBrightness
        self.syncContrast = syncContrast
        self.offsetByMember = offsetByMember
        self.brightnessMode = brightnessMode
        self.followsOutsideChanges = followsOutsideChanges
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, memberRecordIDs, syncBrightness, syncContrast, offsetByMember
        case brightnessMode, followsOutsideChanges
    }

    /// Missing or unreadable new keys take the pre-existing behaviour, so a groups list saved by an
    /// older build keeps syncing the way it did — and one written by a newer build with a mode this
    /// build doesn't know still loads instead of losing every group.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        memberRecordIDs = try container.decode([DisplayRecordID].self, forKey: .memberRecordIDs)
        syncBrightness = try container.decode(Bool.self, forKey: .syncBrightness)
        syncContrast = try container.decode(Bool.self, forKey: .syncContrast)
        offsetByMember = try container.decode([String: Float].self, forKey: .offsetByMember)
        brightnessMode = ((try? container.decodeIfPresent(BrightnessSyncMode.self, forKey: .brightnessMode))
            ?? nil) ?? .offsets
        followsOutsideChanges = ((try? container.decodeIfPresent(Bool.self, forKey: .followsOutsideChanges))
            ?? nil) ?? true
    }

    /// The fixed identity of the Default group, so its leader state and settings survive relaunches
    /// without ever colliding with a named group's random UUID.
    public static let defaultGroupID = UUID(uuidString: "00000000-0000-0000-0000-00000000D0D0")!

    /// The Default group as first configured (SO-05/AM-17): brightness only, OFF until the user turns
    /// it on, delta mode — so switching it on never makes a display jump; the first move carries each
    /// display along from wherever it already is. Its members aren't stored: they are every eligible
    /// connected display no named group claims (`DisplayGroupStore.resolvedDefaultGroup`). The name
    /// is a placeholder; the UI shows a localized one.
    public static let defaultGroup = DisplayGroup(
        id: defaultGroupID, name: "Default", syncBrightness: false, syncContrast: false,
        brightnessMode: .delta, followsOutsideChanges: true)

    public var isDefaultGroup: Bool { id == Self.defaultGroupID }

    /// Widest offset the policy will learn or apply, mirroring `AdaptiveDisplayPolicy`'s own
    /// ±1 clamp on a learned offset. A tighter bound would silently discard part of a correction the
    /// user actually made and re-impose the clipped value on the next fan-out — the slider war the
    /// learning exists to prevent.
    public static let offsetLimit: Float = 1

    /// The range the settings ± slider spans by default. Real panels sit well inside it; a learned
    /// offset beyond it stays legal (see `offsetLimit`) and the slider widens to show it.
    public static let nominalOffsetLimit: Float = 0.5

    public func contains(_ member: DisplayRecordID) -> Bool {
        memberRecordIDs.contains(member)
    }

    /// This member's learned brightness offset relative to the group's leader (0 when nothing has
    /// been learned yet, which is the right answer for a fresh member).
    public func offset(for member: DisplayRecordID) -> Float {
        offsetByMember[member.rawValue] ?? 0
    }

    public mutating func setOffset(_ offset: Float, for member: DisplayRecordID) {
        offsetByMember[member.rawValue] = Self.clampOffset(offset)
    }

    public static func clampOffset(_ offset: Float) -> Float {
        min(offsetLimit, max(-offsetLimit, offset))
    }
}

/// The basic brightness synchronization semantics a group can use (TR-15/SO-05/TB-14). Levels are
/// each display's own control position (0...1 of its brightness range), so percentages are matched,
/// never luminance: equal percentages on two panels need not look equally bright.
public enum BrightnessSyncMode: String, Hashable, Sendable, Codable, CaseIterable {
    /// The original FreeDisplay behaviour: followers sit at the group's base level plus the offset
    /// each one learned from the user's own corrections (or that was set by hand).
    case offsets
    /// Every follower takes the leader's level. Learned offsets are kept but not applied, so
    /// switching back to `.offsets` finds them unchanged.
    case absolute
    /// Every follower moves by the leader's change, keeping the differences that already exist
    /// until a follower reaches the top or bottom of its range (where it simply stops).
    case delta
}

/// Pure store logic for the configured groups (`OpenDisplaySettings.displayGroups`). Every mutation
/// is a value-in / value-out transform so the app layer only has to persist the result.
///
/// The one invariant worth naming: **a display belongs to at most one group**. Two groups claiming
/// the same display would each fan a leader write out to it, and the display would end up wherever
/// the later write happened to land. Adding a display to a second group therefore removes it from
/// the first rather than failing. ::
///
///     addMember(desk, to: gaming, in: [work(desk, laptop), gaming()])
///     ok: [work(laptop), gaming(desk)]   — desk left `work` on the way in
public enum DisplayGroupStore {
    /// The group a display belongs to, or nil when it is ungrouped.
    public static func group(containing member: DisplayRecordID,
                             in groups: [DisplayGroup]) -> DisplayGroup? {
        groups.first { $0.contains(member) }
    }

    /// Case-insensitive name lookup — what the `group:<name>` CLI selector resolves through.
    public static func group(named name: String, in groups: [DisplayGroup]) -> DisplayGroup? {
        groups.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Appends a new group, or nil when the name is already taken (names are the CLI's handle on a
    /// group, so two groups sharing one would make `group:desk` ambiguous).
    public static func create(named name: String, in groups: [DisplayGroup],
                              id: UUID = UUID()) -> [DisplayGroup]? {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, group(named: cleaned, in: groups) == nil else { return nil }
        return groups + [DisplayGroup(id: id, name: cleaned)]
    }

    public static func delete(id: UUID, from groups: [DisplayGroup]) -> [DisplayGroup] {
        groups.filter { $0.id != id }
    }

    /// Replaces the stored group with the same id, re-applying the one-group-per-display invariant
    /// against the members it now claims. Unknown ids are ignored.
    public static func update(_ group: DisplayGroup, in groups: [DisplayGroup]) -> [DisplayGroup] {
        guard groups.contains(where: { $0.id == group.id }) else { return groups }
        return groups.map { existing in
            guard existing.id != group.id else { return group }
            return withoutMembers(group.memberRecordIDs, from: existing)
        }
    }

    /// Adds a display to a group, removing it from whichever group held it before.
    public static func addMember(_ member: DisplayRecordID, to groupID: UUID,
                                 in groups: [DisplayGroup]) -> [DisplayGroup] {
        groups.map { existing in
            guard existing.id == groupID else { return withoutMembers([member], from: existing) }
            guard !existing.contains(member) else { return existing }
            var claimed = existing
            claimed.memberRecordIDs.append(member)
            return claimed
        }
    }

    /// Drops a display from a group, forgetting the offset learned for it there — a member that
    /// rejoins later is a fresh relationship, not a resumption of the old one.
    public static func removeMember(_ member: DisplayRecordID, from groupID: UUID,
                                    in groups: [DisplayGroup]) -> [DisplayGroup] {
        groups.map { existing in
            guard existing.id == groupID else { return existing }
            return withoutMembers([member], from: existing)
        }
    }

    /// True when this display's brightness is driven by a group, so the caller (`adaptiveTick`) can
    /// leave it alone: Adaptive Display and group sync are mutually exclusive per display.
    public static func isGroupGoverned(_ member: DisplayRecordID, in groups: [DisplayGroup]) -> Bool {
        group(containing: member, in: groups)?.syncBrightness ?? false
    }

    // MARK: - Default group (SO-05/AM-17)

    /// The Default group with its live membership: every `eligible` display (connected, in the
    /// caller's order) that no named group claims. Named groups always outrank it, so a display a
    /// named group holds — even one with sync switched off — is never driven by the Default group as
    /// well. ::
    ///
    ///     resolvedDefaultGroup(default, eligible: [builtIn, desk, side], groups: [work(desk)])
    ///     ok: members [builtIn, side] — desk belongs to `work`
    public static func resolvedDefaultGroup(_ defaultGroup: DisplayGroup, eligible: [DisplayRecordID],
                                            groups: [DisplayGroup]) -> DisplayGroup {
        var resolved = defaultGroup
        resolved.memberRecordIDs = eligible.filter { group(containing: $0, in: groups) == nil }
        return resolved
    }

    /// The group whose brightness rules apply to a display: its named group, or else the Default
    /// group when the display is one of its live members. Nil for a display neither covers (an
    /// ineligible one, such as a virtual screen, outside every named group).
    public static func syncGroup(containing member: DisplayRecordID, in groups: [DisplayGroup],
                                 defaultGroup: DisplayGroup, eligible: [DisplayRecordID]) -> DisplayGroup? {
        if let named = group(containing: member, in: groups) { return named }
        let resolved = resolvedDefaultGroup(defaultGroup, eligible: eligible, groups: groups)
        return resolved.contains(member) ? resolved : nil
    }

    /// `isGroupGoverned` counting the Default group too: true when a group — named, or the Default
    /// group switched on — drives this display's brightness.
    public static func isGroupGoverned(_ member: DisplayRecordID, in groups: [DisplayGroup],
                                       defaultGroup: DisplayGroup, eligible: [DisplayRecordID]) -> Bool {
        syncGroup(containing: member, in: groups, defaultGroup: defaultGroup, eligible: eligible)?
            .syncBrightness ?? false
    }

    private static func withoutMembers(_ members: [DisplayRecordID],
                                       from group: DisplayGroup) -> DisplayGroup {
        let leaving = Set(members)
        guard group.memberRecordIDs.contains(where: leaving.contains) else { return group }
        var trimmed = group
        trimmed.memberRecordIDs.removeAll(where: leaving.contains)
        for member in leaving { trimmed.offsetByMember[member.rawValue] = nil }
        return trimmed
    }
}
