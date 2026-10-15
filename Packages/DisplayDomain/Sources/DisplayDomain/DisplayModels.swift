import Foundation

/// Broad classification of a display endpoint. Drives capability gating and copy.
public enum DisplayClass: String, Hashable, Sendable, Codable {
    case builtIn
    case external
    case projector
    case television
    case sidecar
    case airplay
    case virtual
    case headlessAdapter
    case unknown
}

/// The physical/logical path from the Mac to the display. Capability detection is per-route
/// because a monitor may support DDC directly but not through a dock or KVM (PRD §6.2, REG-008).
public enum ConnectionTransport: String, Hashable, Sendable, Codable {
    case internalPanel
    case usbCDisplayPort
    case thunderbolt
    case hdmi
    case displayPort
    case dock
    case kvm
    case wireless
    case virtual
    case unknown
}

/// A concrete display mode. Modes are resolved by *properties*, never by transient mode
/// handles, because the available mode list can change after reconnect (PRD TOP-005, S24).
public struct DisplayMode: Hashable, Sendable, Codable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var pointWidth: Int
    public var pointHeight: Int
    public var refreshHz: Double
    public var isHiDPI: Bool
    public var bitDepth: Int?

    public init(
        pixelWidth: Int,
        pixelHeight: Int,
        pointWidth: Int,
        pointHeight: Int,
        refreshHz: Double,
        isHiDPI: Bool,
        bitDepth: Int? = nil
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.refreshHz = refreshHz
        self.isHiDPI = isHiDPI
        self.bitDepth = bitDepth
    }
}

public enum Rotation: Int, Hashable, Sendable, Codable, CaseIterable {
    case degrees0 = 0
    case degrees90 = 90
    case degrees180 = 180
    case degrees270 = 270
}

/// A point in the global desktop coordinate space (top-left origin), in points.
public struct DisplayOrigin: Hashable, Sendable, Codable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    public static let zero = DisplayOrigin(x: 0, y: 0)
}

/// An immutable snapshot of what macOS/providers currently report for one endpoint, tied to
/// the topology generation in which it was observed (PRD §13.1 DisplayObservation). Observed
/// state is deliberately kept separate from desired state (REG-009).
public struct DisplayObservation: Hashable, Sendable, Codable {
    public var recordID: DisplayRecordID
    public var cgDisplayID: UInt32?
    public var cgUUID: String?
    public var ioServicePath: String?
    public var isActive: Bool
    public var overlay: PresentationOverlay
    public var origin: DisplayOrigin
    public var mode: DisplayMode?
    public var rotation: Rotation
    public var isMain: Bool
    public var mirrorSourceID: DisplayRecordID?
    /// Whether the output is in HDR mode, or nil when nothing observed it. No current provider
    /// reads HDR output state, so nil is the normal value — and it must stay distinguishable from a
    /// confirmed `false`, or an "HDR off" request would count as already satisfied on no evidence.
    public var hdrEnabled: Bool? {
        get { hdrObserved == true ? hdrReported : nil }
        set {
            hdrReported = newValue ?? false
            hdrObserved = newValue == nil ? nil : true
        }
    }
    /// Storage behind `hdrEnabled`. `hdrReported` keeps the historical "hdrEnabled" key and a plain
    /// Bool, so observations persisted by this build (protected layouts, the revert marker) still
    /// decode in older builds; `hdrObserved` says whether it means anything. Older files lack
    /// `hdrObserved`, and their `false` was never observed — they decode as unknown.
    private var hdrReported: Bool
    private var hdrObserved: Bool?
    public var colorProfileName: String?
    public var transport: ConnectionTransport
    public var displayClass: DisplayClass
    /// Whether the provider found evidence that this is a physical screen (`PhysicalPresence`).
    /// Nil when nothing assessed it — fixtures, and snapshots decoded from before the field existed;
    /// `RecoverySurfacePolicy` then falls back to `displayClass`.
    public var physicalPresence: PhysicalPresence?
    public var generation: TopologyGeneration
    public var observedAt: Date

    public init(
        recordID: DisplayRecordID,
        cgDisplayID: UInt32? = nil,
        cgUUID: String? = nil,
        ioServicePath: String? = nil,
        isActive: Bool,
        overlay: PresentationOverlay = .visible,
        origin: DisplayOrigin = .zero,
        mode: DisplayMode? = nil,
        rotation: Rotation = .degrees0,
        isMain: Bool = false,
        mirrorSourceID: DisplayRecordID? = nil,
        hdrEnabled: Bool? = nil,
        colorProfileName: String? = nil,
        transport: ConnectionTransport = .unknown,
        displayClass: DisplayClass = .unknown,
        physicalPresence: PhysicalPresence? = nil,
        generation: TopologyGeneration,
        observedAt: Date = Date()
    ) {
        self.recordID = recordID
        self.cgDisplayID = cgDisplayID
        self.cgUUID = cgUUID
        self.ioServicePath = ioServicePath
        self.isActive = isActive
        self.overlay = overlay
        self.origin = origin
        self.mode = mode
        self.rotation = rotation
        self.isMain = isMain
        self.mirrorSourceID = mirrorSourceID
        self.hdrReported = hdrEnabled ?? false
        self.hdrObserved = hdrEnabled == nil ? nil : true
        self.colorProfileName = colorProfileName
        self.transport = transport
        self.displayClass = displayClass
        self.physicalPresence = physicalPresence
        self.generation = generation
        self.observedAt = observedAt
    }

    /// `true` when this display is mirroring another endpoint.
    public var isMirrored: Bool { mirrorSourceID != nil }

    /// Spelled out only to keep `hdrReported` under its historical "hdrEnabled" key. EVERY stored
    /// property must be listed: an optional one left out would compile and then silently never
    /// persist (`testEveryStoredFieldSurvivesCoding` guards it).
    private enum CodingKeys: String, CodingKey {
        case recordID, cgDisplayID, cgUUID, ioServicePath, isActive, overlay, origin, mode, rotation
        case isMain, mirrorSourceID
        case hdrReported = "hdrEnabled"
        case hdrObserved
        case colorProfileName, transport, displayClass, physicalPresence, generation, observedAt
    }
}

/// The persistent record that user intent (alias, tags, pairing, policies) attaches to. It is
/// linked to observations through scored identity evidence (PRD §10.5). Persists across the
/// active/offline lifecycle (REG-006).
public struct DisplayRecord: Hashable, Sendable, Codable, Identifiable {
    public var id: DisplayRecordID
    public var alias: String?
    public var tags: Set<String>
    public var fingerprint: DisplayFingerprint
    public var displayClass: DisplayClass
    public var lastSeen: Date?
    public var pairingConfirmed: Bool
    /// Set only on a *provisional* record: the registry could not tell this live display apart from
    /// these remembered records (a shared serial, a tied score, or two displays present at once
    /// claiming one record), so it attached none of their alias, tags or pairing to it. Never
    /// persisted — the record exists only until the user names, tags or pairs the display, which
    /// makes it a display of its own (`DisplayRegistry`).
    public var unresolvedCandidates: [DisplayRecordID]?
    /// Where this record's saved settings came from when the user moved them here from another
    /// record or from an earlier identifier of the same display (SD-10/TB-09), oldest first. Nil
    /// (and absent from the file) for a record nothing was ever moved to, so older registries read
    /// unchanged and records written before the field existed encode exactly as they did.
    public var provenance: [DisplayRecordProvenance]?

    public init(
        id: DisplayRecordID,
        alias: String? = nil,
        tags: Set<String> = [],
        fingerprint: DisplayFingerprint,
        displayClass: DisplayClass = .unknown,
        lastSeen: Date? = nil,
        pairingConfirmed: Bool = false,
        unresolvedCandidates: [DisplayRecordID]? = nil,
        provenance: [DisplayRecordProvenance]? = nil
    ) {
        self.id = id
        self.alias = alias
        self.tags = tags
        self.fingerprint = fingerprint
        self.displayClass = displayClass
        self.lastSeen = lastSeen
        self.pairingConfirmed = pairingConfirmed
        self.unresolvedCandidates = unresolvedCandidates
        self.provenance = provenance
    }

    /// True when automatic recognition was ambiguous and this record is the registry's explicit
    /// "can't tell which one" answer rather than a remembered display.
    public var isProvisional: Bool { unresolvedCandidates != nil }

    /// A user-facing name: the explicit alias if set, otherwise the model name, otherwise the ID.
    public var displayName: String {
        alias ?? fingerprint.modelName ?? id.rawValue
    }

    /// A name a person can act on for a display that may not be plugged in right now: the alias,
    /// else the EDID model name, else a class (+ resolution when there is a live mode) label. Never
    /// the raw record id — `cg:37D8832A-2D66-…` in a group-membership checkbox identifies nothing to
    /// the human reading it, and an absent display is exactly when a name matters most. ::
    ///
    ///     friendlyName(mode: 3840×2160) on an unaliased external
    ///     ok: "External 3840×2160"
    ///
    ///     friendlyName() on the same display while it is unplugged
    ///     ok: "External display"
    public func friendlyName(mode: DisplayMode? = nil) -> String {
        if let alias, !alias.isEmpty { return alias }
        if let modelName = fingerprint.modelName, !modelName.isEmpty { return modelName }
        if displayClass == .builtIn { return "Built-in Display" }
        let classLabel = displayClass.rawValue.capitalized
        guard let mode else { return "\(classLabel) display" }
        return "\(classLabel) \(mode.pixelWidth)×\(mode.pixelHeight)"
    }
}

/// One deliberate move of saved settings onto a record (SD-10, TB-09): the user transferred them
/// from another remembered record, or brought them over from an identifier this same display was
/// seen under before. Kept so "where did these settings come from?" has an answer after the source
/// is gone. Recognition never reads it — it is history, not identity evidence.
public struct DisplayRecordProvenance: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        /// From another record, which was removed by the transfer.
        case transferredFrom
        /// From an earlier identifier (`cg:<uuid>`) of this same record.
        case migratedFrom
    }

    public var kind: Kind
    public var date: Date
    /// The name the source was shown under when the user confirmed the move.
    public var sourceName: String
    /// The removed record, for a transfer from a registered one.
    public var sourceRecordID: DisplayRecordID?
    /// The ids the moved settings were saved under.
    public var sourceObservationIDs: [DisplayRecordID]
    /// The kinds of settings moved (`DisplaySettingsTransfer.Category` raw values).
    public var categories: [String]

    public init(kind: Kind, date: Date, sourceName: String, sourceRecordID: DisplayRecordID? = nil,
                sourceObservationIDs: [DisplayRecordID], categories: [String]) {
        self.kind = kind
        self.date = date
        self.sourceName = sourceName
        self.sourceRecordID = sourceRecordID
        self.sourceObservationIDs = sourceObservationIDs
        self.categories = categories
    }
}
