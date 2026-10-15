import DisplayDomain
import Foundation

/// Who keeps the displays awake, and why (FB-12/AM-42).
///
/// FreeDisplay holds at most one macOS power assertion of type `PreventUserIdleDisplaySleep`. It
/// stops the displays from dimming and sleeping while the Mac is idle — and nothing else: macOS
/// still sleeps the system on its own schedule, when the lid closes and when the user chooses
/// Sleep. Two settings can ask for it:
///
/// * **Any external display** (`preventDisplaySleepWithExternal`): every lit external display
///   keeps the displays awake while it is connected.
/// * **This display** (`preventDisplaySleepDisplayIDs`, per display): that display keeps them
///   awake while it is connected and lit — the built-in panel included.
///
/// The assertion is held while at least one lit display owns it and released when the last owner
/// goes. A display that is switched off (by FreeDisplay or macOS), or that is virtual, never owns
/// it: a stale entry for a screen nobody can see must not keep the Mac's displays awake.
public enum DisplaySleepPrevention {
    /// The IOKit assertion type FreeDisplay holds, named as `pmset -g assertions` lists it.
    public static let assertionType = "PreventUserIdleDisplaySleep"

    /// What the policy needs to know about one display.
    public struct Candidate: Hashable, Sendable {
        public var recordID: DisplayRecordID
        public var displayClass: DisplayClass
        /// Online and part of the desktop (not switched off or soft-disconnected).
        public var isActive: Bool
        public var physicalPresence: PhysicalPresence?

        public init(recordID: DisplayRecordID, displayClass: DisplayClass, isActive: Bool,
                    physicalPresence: PhysicalPresence? = nil) {
            self.recordID = recordID
            self.displayClass = displayClass
            self.isActive = isActive
            self.physicalPresence = physicalPresence
        }

        public init(_ observation: DisplayObservation) {
            self.init(recordID: observation.recordID, displayClass: observation.displayClass,
                      isActive: observation.isActive, physicalPresence: observation.physicalPresence)
        }

        /// Requested by the global external-display setting; eligibility is checked separately.
        var isExternal: Bool { displayClass != .builtIn }
    }

    /// Why a display can't own the assertion even though it was asked to.
    public enum Ineligibility: String, Hashable, Sendable {
        /// Switched off, soft-disconnected or otherwise not lit.
        case inactive
        /// A virtual screen: it has no panel to keep awake.
        case virtual
        /// Public observations cannot establish a physical panel (including generic virtual routes).
        case unverified
    }

    /// Which setting made a display an owner.
    public struct Reasons: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// "Keep displays awake while an external display is connected".
        public static let anyExternal = Reasons(rawValue: 1 << 0)
        /// This display's own "keep displays awake while connected".
        public static let thisDisplay = Reasons(rawValue: 1 << 1)
    }

    /// One display's part in the decision.
    public enum Standing: Hashable, Sendable {
        /// Holds the assertion for these reasons.
        case owner(Reasons)
        /// Asked to (by these settings) but can't: see the ineligibility.
        case ineligible(Ineligibility, requestedBy: Reasons)
        /// Nothing asks this display to keep the displays awake.
        case notRequested
    }

    public struct Decision: Hashable, Sendable {
        /// The displays the assertion is held for, in a stable order. Empty: release it.
        public var owners: [DisplayRecordID]
        /// Every candidate's standing, for the UI and diagnostics.
        public var standings: [DisplayRecordID: Standing]

        public init(owners: [DisplayRecordID], standings: [DisplayRecordID: Standing]) {
            self.owners = owners
            self.standings = standings
        }

        /// Hold the assertion exactly when a lit, eligible display asks for it.
        public var shouldHold: Bool { !owners.isEmpty }

        public static let none = Decision(owners: [], standings: [:])
    }

    /// What the app shows: who the assertion is held for, and what macOS granted.
    public struct Snapshot: Hashable, Sendable {
        public var decision: Decision
        public var status: DisplaySleepGuard.Status

        public init(decision: Decision = .none, status: DisplaySleepGuard.Status = .released) {
            self.decision = decision
            self.status = status
        }
    }

    /// Whether `candidate` could own the assertion, or why not.
    public static func ineligibility(of candidate: Candidate) -> Ineligibility? {
        if candidate.displayClass == .virtual || candidate.physicalPresence == .virtual { return .virtual }
        if !candidate.isActive { return .inactive }
        if candidate.displayClass == .headlessAdapter { return .virtual }
        if candidate.displayClass != .builtIn && candidate.physicalPresence != .physical { return .unverified }
        return nil
    }

    /// The decision for the current displays and the two settings. `perDisplay` holds
    /// `DisplayRecordID.rawValue`s, as the settings store them.
    public static func decide(anyExternal: Bool, perDisplay: Set<String>,
                              candidates: [Candidate]) -> Decision {
        var owners: [DisplayRecordID] = []
        var standings: [DisplayRecordID: Standing] = [:]
        for candidate in candidates {
            var reasons: Reasons = []
            if anyExternal, candidate.isExternal { reasons.insert(.anyExternal) }
            if perDisplay.contains(candidate.recordID.rawValue) { reasons.insert(.thisDisplay) }
            guard !reasons.isEmpty else {
                standings[candidate.recordID] = .notRequested
                continue
            }
            if let reason = ineligibility(of: candidate) {
                standings[candidate.recordID] = .ineligible(reason, requestedBy: reasons)
            } else {
                standings[candidate.recordID] = .owner(reasons)
                owners.append(candidate.recordID)
            }
        }
        // A record seen twice in one snapshot owns it once.
        let ordered = Array(Set(owners)).sorted { $0.rawValue < $1.rawValue }
        return Decision(owners: ordered, standings: standings)
    }
}
