import Foundation

/// One external DDC channel — an `IOAVService` (`DCPAVServiceProxy`) — as the IORegistry lists it.
public struct DDCChannel: Hashable, Sendable {
    /// The service's IORegistry service-plane path. It names where the channel is (the display
    /// coprocessor and port it hangs off), not its position in an enumeration; empty when IOKit
    /// couldn't report one, and such a channel can't be chosen.
    public var path: String
    /// The identity attributes of the display node next to it, when IOKit reports any.
    public var attributes: DDCServiceMatcher.Candidate?

    public init(path: String, attributes: DDCServiceMatcher.Candidate?) {
        self.path = path
        self.attributes = attributes
    }
}

/// The user's explicit pairing of one display with one DDC channel (TR-06; owner decision #4).
///
/// Identity can't tell two identical monitors without serial numbers apart, so `DDCServiceMatcher`
/// refuses to bind either — no guess ever reaches a monitor. The user can resolve that in the
/// monitor's settings: test a channel (a brightness flash they trigger and watch), then confirm the
/// channel that made *this* monitor respond. The pairing is keyed by the display's stable id
/// (`cg:<uuid>`), never by a numeric display id, and records the evidence it was confirmed on —
/// the display's own vendor/product/serial and the channel's path and attributes. It applies only
/// while all of that evidence is unchanged (`DDCChannelMappingPolicy`).
public struct DDCChannelMapping: Hashable, Sendable, Codable {
    public var displayID: DisplayRecordID
    public var displayIdentity: DDCServiceMatcher.Target
    public var channelPath: String
    public var channelAttributes: DDCServiceMatcher.Candidate?
    public var confirmedAt: Date

    public init(displayID: DisplayRecordID, displayIdentity: DDCServiceMatcher.Target, channelPath: String,
                channelAttributes: DDCServiceMatcher.Candidate?, confirmedAt: Date) {
        self.displayID = displayID
        self.displayIdentity = displayIdentity
        self.channelPath = channelPath
        self.channelAttributes = channelAttributes
        self.confirmedAt = confirmedAt
    }
}

/// When a manual channel pairing may stand in for automatic binding — and when it may not.
///
/// Only a refusal identity can't resolve is liftable (`ambiguousIdentity`, `unidentified`): an
/// Apple display without its override, or a channel whose identity names another monitor, stays
/// refused whatever the user paired. A pairing applies only when every piece of evidence it was
/// confirmed on still holds, the channel names nothing that contradicts the display, no other
/// connected display is bound to that channel by identity, and no other connected display's pairing
/// names it too. Otherwise nothing is bound — the fail-closed answer stands — and the status says
/// why, so the user can choose again. The caller revokes a saved pairing on an invalid result;
/// returning to earlier evidence must not silently revive that consent.
public enum DDCChannelMappingPolicy {
    public enum Status: Hashable, Sendable {
        /// The pairing bound the display to the channel at this index.
        case inUse(channelIndex: Int)
        /// Identity settled the binding by itself (or no pairing can lift its answer); the pairing
        /// wasn't consulted.
        case notNeeded
        /// The pairing exists but doesn't apply.
        case invalid(Invalidity)
    }

    public enum Invalidity: String, Error, Hashable, Sendable, Codable, CaseIterable {
        /// The display has no stable id (only a numeric one) or the pairing names another display.
        case unstableDisplayID
        /// The display's vendor, product or serial differ from when the pairing was confirmed.
        case displayIdentityChanged
        /// No channel is at the paired path now.
        case channelMissing
        /// The channel's own attributes differ from when the pairing was confirmed.
        case channelIdentityChanged
        /// The channel's attributes name another monitor.
        case channelContradictsDisplay
        /// Another connected display is bound to that channel by identity, or paired with it too.
        case channelClaimedByAnotherDisplay
    }

    /// Whether a display can be paired at all: only one with a stable `cg:<uuid>` id.
    public static func canPair(_ displayID: DisplayRecordID) -> Bool {
        displayID.cgUUID.map { !$0.isEmpty } == true
    }

    /// Whether a manual pairing may lift this refusal.
    public static func isLiftable(_ refusal: DDCBindingRefusal) -> Bool {
        refusal == .ambiguousIdentity || refusal == .unidentified
    }

    /// The pairing the user just confirmed for `channel`, or nil when the display has no stable id.
    public static func confirm(displayID: DisplayRecordID, displayIdentity: DDCServiceMatcher.Target,
                               channel: DDCChannel, at date: Date) -> DDCChannelMapping? {
        guard canPair(displayID), !channel.path.isEmpty else { return nil }
        return DDCChannelMapping(displayID: displayID, displayIdentity: displayIdentity, channelPath: channel.path,
                                 channelAttributes: channel.attributes, confirmedAt: date)
    }

    /// The saved pairings after confirming `mapping`: it replaces the display's previous one, and any
    /// other display's pairing with the same channel goes — the user has just watched which monitor
    /// that channel reaches.
    public static func saving(_ mapping: DDCChannelMapping, into existing: [DDCChannelMapping]) -> [DDCChannelMapping] {
        existing.filter { $0.displayID != mapping.displayID && $0.channelPath != mapping.channelPath } + [mapping]
    }

    /// The display ids whose pairing `saving(mapping, into: existing)` drops besides the display's own.
    public static func displaced(by mapping: DDCChannelMapping, in existing: [DDCChannelMapping]) -> [DisplayRecordID] {
        existing.filter { $0.displayID != mapping.displayID && $0.channelPath == mapping.channelPath }.map(\.displayID)
    }

    /// Binds `target` (shown under `displayID`) among `channels`: identity first
    /// (`DDCServiceMatcher.resolve`), and the display's pairing only when identity refused in a way
    /// a pairing may lift. `externals` are every external display that could own a channel, the
    /// target included; `otherMappings` are the pairings of the other connected displays.
    public static func resolve(channels: [DDCChannel], target: DDCServiceMatcher.Target,
                               externals: [DDCServiceMatcher.Target], displayID: DisplayRecordID,
                               mapping: DDCChannelMapping?, otherMappings: [DDCChannelMapping],
                               unobservedExternalCount: Int = 0)
        -> (resolution: DDCServiceMatcher.Resolution, status: Status?) {
        let attributes = channels.map(\.attributes)
        let automatic = DDCServiceMatcher.resolve(attributes, against: target, among: externals,
                                                  unobservedExternalCount: unobservedExternalCount)
        guard let mapping else { return (automatic, nil) }
        let validation = validate(mapping, displayID: displayID, target: target, channels: channels,
                                  externals: externals, otherMappings: otherMappings)
        // Evidence changes revoke the saved pairing even if automatic matching no longer needs it.
        // A positively resolved automatic route remains safe to use on its own evidence.
        if case .failure(let reason) = validation { return (automatic, .invalid(reason)) }
        guard case .refused(let refusal) = automatic, isLiftable(refusal) else { return (automatic, .notNeeded) }
        switch validation {
        case .success(let index): return (.matched(index: index), .inUse(channelIndex: index))
        case .failure(let reason): return (automatic, .invalid(reason))
        }
    }

    /// Whether `mapping` holds for the display now, and at which channel index.
    public static func validate(_ mapping: DDCChannelMapping, displayID: DisplayRecordID,
                                target: DDCServiceMatcher.Target, channels: [DDCChannel],
                                externals: [DDCServiceMatcher.Target],
                                otherMappings: [DDCChannelMapping]) -> Result<Int, Invalidity> {
        guard canPair(displayID), mapping.displayID == displayID else { return .failure(.unstableDisplayID) }
        guard mapping.displayIdentity == target else { return .failure(.displayIdentityChanged) }
        guard !mapping.channelPath.isEmpty,
              channels.filter({ $0.path == mapping.channelPath }).count == 1,
              let index = channels.firstIndex(where: { $0.path == mapping.channelPath }) else {
            return .failure(.channelMissing)
        }
        let channel = channels[index]
        guard channel.attributes == mapping.channelAttributes else { return .failure(.channelIdentityChanged) }
        if let attributes = channel.attributes, DDCServiceMatcher.contradicts(attributes, target) {
            return .failure(.channelContradictsDisplay)
        }
        if otherMappings.contains(where: { $0.displayID != displayID && $0.channelPath == mapping.channelPath }) {
            return .failure(.channelClaimedByAnotherDisplay)
        }
        // A display identity binds by itself owns its channel; a pairing must never share it.
        var rivals = externals
        if let own = rivals.firstIndex(of: target) { rivals.remove(at: own) }
        let attributes = channels.map(\.attributes)
        for rival in rivals {
            switch DDCServiceMatcher.resolve(attributes, against: rival, among: externals) {
            case .matched(let claimed), .sole(let claimed):
                if claimed == index { return .failure(.channelClaimedByAnotherDisplay) }
            case .refused, .none:
                continue
            }
        }
        return .success(index)
    }
}

/// The provider's enumeration boundary. An empty enumeration is evidence of a missing channel,
/// so it must pass through consent validation just like a nonempty one.
public enum DDCChannelLookup {
    public static func resolve(channels: [DDCChannel], target: DDCServiceMatcher.Target,
                               externals: [DDCServiceMatcher.Target], displayID: DisplayRecordID?,
                               mapping: DDCChannelMapping?, otherMappings: [DDCChannelMapping],
                               unobservedExternalCount: Int = 0)
        -> (resolution: DDCServiceMatcher.Resolution, status: DDCChannelMappingPolicy.Status?) {
        DDCChannelMappingPolicy.resolve(channels: channels, target: target, externals: externals,
            displayID: displayID ?? DisplayRecordID(rawValue: ""), mapping: displayID == nil ? nil : mapping,
            otherMappings: otherMappings, unobservedExternalCount: unobservedExternalCount)
    }
}

/// The test the user runs before pairing a channel: a brightness flash on that channel, held long
/// enough to see which physical monitor responds, then put back. Only brightness (VCP 0x10) is
/// touched — never input or power — and nothing is written unless the channel first answers a
/// brightness read, because without the current level there is nothing to put back.
public enum DDCChannelTest {
    /// Values come from the user; no flash level or duration is chosen by the library.
    public struct Parameters: Hashable, Sendable {
        public let levelPercent: Double
        public let duration: Duration

        public init?(levelPercent: Double, durationSeconds: Double) {
            guard levelPercent.isFinite, (0...100).contains(levelPercent),
                  durationSeconds.isFinite, durationSeconds > 0,
                  durationSeconds < Double(Int64.max) else { return nil }
            self.levelPercent = levelPercent
            self.duration = .seconds(durationSeconds)
        }
    }
    public enum Outcome: Hashable, Sendable {
        /// The channel flashed from `original` to `flashLevel` and back (`restored` false: the
        /// write putting `original` back failed — the monitor may be left at `flashLevel`).
        case flashed(original: Int, flashLevel: Int, restored: Bool)
        /// The channel didn't answer a brightness read; nothing was written.
        case noReply
        /// The flash write failed. The original level was written back anyway, in case the write
        /// took effect without acknowledging it.
        case flashWriteFailed(original: Int, restored: Bool)
    }

    /// Runs the flash: read, write the flash level, `hold` (the caller decides how long), write the
    /// original back.
    public static func run(isolation: isolated (any Swift.Actor)? = #isolation,
                           parameters: Parameters, read: () async -> (current: Int, max: Int)?,
                           write: (Int) async -> Bool,
                           hold: () async -> Void) async -> Outcome {
        guard !Task.isCancelled, let reading = await read(), !Task.isCancelled, reading.max > 0, reading.current >= 0,
              reading.current <= reading.max else { return .noReply }
        let scaled = Double(reading.max) * parameters.levelPercent / 100
        guard scaled < Double(Int.max) else { return .noReply }
        let level = Int(scaled.rounded(.down))
        guard await write(level) else {
            return .flashWriteFailed(original: reading.current, restored: await write(reading.current))
        }
        if !Task.isCancelled { await hold() }
        return .flashed(original: reading.current, flashLevel: level, restored: await write(reading.current))
    }
}
