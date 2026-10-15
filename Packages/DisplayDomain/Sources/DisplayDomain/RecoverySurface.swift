import Foundation

/// Whether a display is evidently a physical screen a person can look at — the question every
/// "always keep one usable screen" safeguard has to ask, and one Core Graphics does not answer.
///
/// To the public display APIs a virtual screen is just another online, active display with a
/// vendor and a mode list: OpenDisplay's own CGVirtualDisplay endpoints, BetterDisplay's virtual
/// screens, DisplayLink and Sidecar all look like a monitor. Counting one as the screen that stays
/// on is how "turn off the built-in" can leave a Mac with nothing visible at all, so a safeguard
/// only trusts what it has evidence for.
public enum PhysicalPresence: String, Hashable, Sendable, Codable {
    /// The built-in panel, or an external display that a connected display-hardware node vouches
    /// for one-to-one (see `PhysicalPresenceClassifier`).
    case physical
    /// A screen that exists only inside the window server: OpenDisplay's own virtual endpoints and
    /// macOS's "no displays at all" placeholder.
    case virtual
    /// No hardware evidence: a third-party virtual screen (DisplayLink, Sidecar, AirPlay and screen
    /// sharing tools look like this through public API too), or a physical display whose hardware
    /// node could not be told apart from another claimant. Fails closed — never a recovery surface.
    case unverified
}

/// Decides `PhysicalPresence` for every online display from public facts: Core Graphics identity
/// numbers and the connected display-hardware nodes in IORegistry (the `DisplayAttributes` →
/// `ProductAttributes` an Apple-silicon display pipe publishes for a panel it is driving).
///
/// A virtual screen has no such node, so an external display is `.physical` only when a node with
/// its vendor and model is there for it. Nodes are matched one-to-one: a serial the node also
/// carries settles it for that display; otherwise, when more displays claim an identity than there
/// are nodes left carrying it, nothing says which one is the impostor, and every unsettled claimant
/// of that identity is `.unverified`. Pure, so `make test` covers the whole table.
public enum PhysicalPresenceClassifier {
    /// The Core Graphics side of one online display.
    public struct Display: Hashable, Sendable {
        public var id: UInt32
        public var isBuiltIn: Bool
        /// macOS's synthetic stand-in for "no displays" (`DisplayActivity.isVirtualPlaceholder`).
        public var isSystemPlaceholder: Bool
        /// `CGDisplayVendorNumber` / `CGDisplayModelNumber` / `CGDisplaySerialNumber`; 0 and
        /// 0xFFFFFFFF mean unknown.
        public var vendorNumber: UInt32
        public var modelNumber: UInt32
        public var serialNumber: UInt32

        public init(id: UInt32, isBuiltIn: Bool = false, isSystemPlaceholder: Bool = false,
                    vendorNumber: UInt32, modelNumber: UInt32, serialNumber: UInt32 = 0) {
            self.id = id
            self.isBuiltIn = isBuiltIn
            self.isSystemPlaceholder = isSystemPlaceholder
            self.vendorNumber = vendorNumber
            self.modelNumber = modelNumber
            self.serialNumber = serialNumber
        }
    }

    /// One connected display-hardware node: the same `ProductAttributes` fields DDC matching reads.
    public typealias HardwareNode = DDCServiceMatcher.Candidate

    public static func classify(_ displays: [Display],
                                hardware: [HardwareNode]) -> [UInt32: PhysicalPresence] {
        var result: [UInt32: PhysicalPresence] = [:]
        var nodes = hardware.map { Node(key: key(of: $0), serial: $0.serialNumber) }
        var pending: [Display] = []
        for display in displays {
            if display.isBuiltIn {
                result[display.id] = .physical
            } else if display.isSystemPlaceholder
                        || display.vendorNumber == VirtualDisplaySafetyPolicy.providerVendorID {
                // The vendor id OpenDisplay stamps on its own endpoints. A real monitor that happened
                // to carry it would only stop counting as a recovery surface — the safe direction.
                result[display.id] = .virtual
            } else {
                pending.append(display)
            }
        }
        // The built-in panel is trusted on CGDisplayIsBuiltin alone, but it still owns its node:
        // otherwise the panel's attributes could vouch for an external screen that copied them.
        for builtIn in displays where builtIn.isBuiltIn {
            if let index = nodeIndex(for: builtIn, in: nodes) { nodes.remove(at: index) }
        }
        let groups = Dictionary(grouping: pending, by: key(of:))
        for (identity, members) in groups {
            var available = nodes.filter { $0.key == identity }
            // A serial the hardware also reports settles it for that display alone: when there are at
            // least as many nodes carrying the serial as displays claiming it, they are those
            // displays. Fewer nodes than claimants (an impostor copying the serial too) leaves the
            // claimants to the anonymous round below.
            var unsettled: [Display] = []
            for (serial, claimants) in Dictionary(grouping: members, by: \.serialNumber) {
                let carriers = available.indices.filter { serial != 0 && available[$0].serial == Int(serial) }
                guard serial != 0, carriers.count >= claimants.count else {
                    unsettled.append(contentsOf: claimants)
                    continue
                }
                for index in carriers.prefix(claimants.count).reversed() { available.remove(at: index) }
                for display in claimants { result[display.id] = .physical }
            }
            // The rest can only be vouched for by a node whose serial doesn't contradict theirs, and
            // only all together: if one of them is left without a node, nothing says which one is
            // the screen without hardware, so none of them counts. Serialled displays choose first.
            let ordered = unsettled.sorted {
                ($0.serialNumber == 0 ? 1 : 0, $0.id) < ($1.serialNumber == 0 ? 1 : 0, $1.id)
            }
            var everyoneMatched = true
            for display in ordered {
                guard let index = nodeIndex(for: display, in: available) else {
                    everyoneMatched = false
                    break
                }
                available.remove(at: index)
            }
            for display in unsettled { result[display.id] = everyoneMatched ? .physical : .unverified }
        }
        return result
    }

    // MARK: - Private

    /// Vendor + model, or `nil` for "this side doesn't know" — an EDID-less display can only be
    /// vouched for by a node that doesn't know either.
    private struct IdentityKey: Hashable {
        var vendor: Int
        var model: Int
    }

    private struct Node {
        var key: IdentityKey?
        var serial: Int?
    }

    private static func key(of display: Display) -> IdentityKey? {
        func known(_ value: UInt32) -> Int? { value == 0 || value == 0xFFFF_FFFF ? nil : Int(value) }
        guard let vendor = known(display.vendorNumber), let model = known(display.modelNumber) else { return nil }
        return IdentityKey(vendor: vendor, model: model)
    }

    private static func key(of node: HardwareNode) -> IdentityKey? {
        let legacy = node.legacyManufacturerID.flatMap { $0 == 0 ? nil : $0 }
        let vendor = legacy ?? node.manufacturerID.flatMap(DDCServiceMatcher.vendorNumber(fromPNP:))
        guard let vendor, vendor != 0, let model = node.productID, model != 0 else { return nil }
        return IdentityKey(vendor: vendor, model: model)
    }

    /// The node to pair `display` with: an exact serial match first, else one whose serial doesn't
    /// contradict the display's (either side unknown).
    private static func nodeIndex(for display: Display, in nodes: [Node]) -> Int? {
        let identity = key(of: display)
        let serial = Int(display.serialNumber)
        let sameIdentity = nodes.indices.filter { nodes[$0].key == identity }
        if serial != 0, let exact = sameIdentity.first(where: { nodes[$0].serial == serial }) {
            return exact
        }
        return sameIdentity.first { index in
            guard serial != 0, let nodeSerial = nodes[index].serial, nodeSerial != 0 else { return true }
            return nodeSerial == serial
        }
    }
}

/// The one predicate every "keep a usable screen" safeguard shares — lifecycle preflight
/// (`SafetyEngine`), the always-one-active net (`WakeConvergencePolicy`), and the menu's switch
/// enablement — so they can never disagree about what counts as a screen to recover from.
public enum RecoverySurfacePolicy {
    /// Whether `observation` is a physical screen, ignoring whether it is lit right now.
    ///
    /// A provider that assessed presence is believed, and anything short of `.physical` fails
    /// closed. Observations that carry no assessment (simulator fixtures, snapshots decoded from
    /// older checkpoints) are judged by their class: the virtual and remote classes never count.
    public static func isPhysical(_ observation: DisplayObservation) -> Bool {
        if let presence = observation.physicalPresence { return presence == .physical }
        switch observation.displayClass {
        case .virtual, .sidecar, .airplay, .headlessAdapter:
            return false
        case .builtIn, .external, .projector, .television, .unknown:
            return true
        }
    }

    /// The lit physical screens — what the safety net needs at least one of.
    public static func liveSurfaces(in observations: [DisplayObservation]) -> [DisplayObservation] {
        observations.filter { $0.isActive && isPhysical($0) }
    }

    /// The screens a disconnect may leave the user on: lit, physical, not mirroring another
    /// display, not blacked out, and not among `targets`.
    public static func safeSurfaceCandidates(in observations: [DisplayObservation],
                                             excluding targets: Set<DisplayRecordID>) -> [DisplayObservation] {
        liveSurfaces(in: observations).filter { observation in
            !targets.contains(observation.recordID)
                && !observation.isMirrored
                && (observation.overlay == .visible || observation.overlay == .dimmed)
        }
    }
}

/// Black Out under the same rule: an opaque, click-through overlay (plus the gamma floor) that
/// leaves a display lit and enumerated while showing the user nothing. No provider can report it —
/// it is this process's own window and colour-table state — so the safeguards only see it once it is
/// stamped into the observations they judge (`stamping`), and `RecoverySurfacePolicy` then treats a
/// blacked-out screen as no screen at all.
public enum BlackOutPolicy {
    /// `observations` with every display in `blackedOut` carrying the `.blackedOut` overlay — and
    /// every display mirroring one of them, which shows its source's picture, overlay included. The
    /// rest keep whatever overlay they were observed with.
    public static func stamping(_ blackedOut: Set<DisplayRecordID>,
                                into observations: [DisplayObservation]) -> [DisplayObservation] {
        guard !blackedOut.isEmpty else { return observations }
        return observations.map { observation in
            let covered = blackedOut.contains(observation.recordID)
                || observation.mirrorSourceID.map(blackedOut.contains) == true
            guard covered else { return observation }
            var stamped = observation
            stamped.overlay = .blackedOut
            return stamped
        }
    }

    /// Whether `target` may be blacked out: some other screen must stay one the user can be left on —
    /// lit, physical (a virtual, Sidecar or DisplayLink screen shows nobody anything), not mirroring
    /// (a mirror shows its source, which may be the target) and not blacked out itself. The very
    /// candidates a disconnect preflight accepts, so the two can never disagree.
    public static func mayBlackOut(_ target: DisplayRecordID, in observations: [DisplayObservation],
                                   blackedOut: Set<DisplayRecordID>) -> Bool {
        !RecoverySurfacePolicy.safeSurfaceCandidates(in: stamping(blackedOut, into: observations),
                                                     excluding: [target]).isEmpty
    }

    /// The blackouts emergency recovery must lift: all of them once no screen the user can be left on
    /// remains outside them (the other screen was unplugged, turned off by another process, or
    /// became a mirror), none while one does. Lifting is the cheapest rescue there is — the display
    /// is right there, lit; only this app's overlay is hiding it.
    public static func blackOutsToLift(in observations: [DisplayObservation],
                                       blackedOut: Set<DisplayRecordID>) -> Set<DisplayRecordID> {
        guard !blackedOut.isEmpty else { return [] }
        let usable = RecoverySurfacePolicy.safeSurfaceCandidates(
            in: stamping(blackedOut, into: observations), excluding: [])
        return usable.isEmpty ? blackedOut : []
    }
}
