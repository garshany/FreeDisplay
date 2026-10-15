import DisplayDomain
import Foundation

/// Persisted registry state: the remembered display records plus a same-Mac fast-path index from
/// the (stable on this machine) CG display UUID to a record. The UUID index is a routing hint, not
/// portable identity — cross-machine recognition relies on the scored fingerprint.
public struct RegistryState: Hashable, Sendable, Codable {
    public var records: [DisplayRecord]
    public var cgUUIDIndex: [String: DisplayRecordID]

    public init(records: [DisplayRecord] = [], cgUUIDIndex: [String: DisplayRecordID] = [:]) {
        self.records = records
        self.cgUUIDIndex = cgUUIDIndex
    }
}

/// Persistence backend for the registry. `save` reports a write that didn't happen: most callers
/// treat persistence as best-effort, but a settings import must know (`DisplayRegistry.replaceState`).
public protocol RegistryStoring: Sendable {
    func load() async -> RegistryState
    func save(_ state: RegistryState) async throws
}

/// In-memory store for tests and previews.
public actor InMemoryRegistryStore: RegistryStoring {
    private var state: RegistryState
    public init(_ state: RegistryState = RegistryState()) { self.state = state }
    public func load() -> RegistryState { state }
    public func save(_ state: RegistryState) { self.state = state }
}

/// Atomic JSON store at `<dir>/registry.json` (pure Foundation; covered by `make test`).
public struct DiskRegistryStore: RegistryStoring {
    private let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("registry.json")
    }

    public static func defaultDirectory(
        appName: String = "OpenDisplay",
        fileManager: FileManager = .default
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return base.appendingPathComponent(appName, isDirectory: true)
    }

    public func load() async -> RegistryState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(RegistryState.self, from: data) else {
            return RegistryState()
        }
        return state
    }

    /// Atomic: a write that fails leaves the previous file as it was, and throws.
    public func save(_ state: RegistryState) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }
}

/// The source of remembered display identity (PRD §10.5, REG-003/004/005). Resolves a live
/// observation's fingerprint to a stable `DisplayRecord` — recognizing a display we've seen before
/// or minting a new record — and owns user-attached alias/tag/pairing edits. A record whose identity
/// positively conflicts with the observation (`IdentityScorer.identitiesConflict`: another vendor or
/// model, or the same model with another serial) takes part in none of the stages. Resolution order:
///   1. serial match qualified by vendor and model (`IdentityScorer.serialsMatch`); when several
///      records share it, the one this CG UUID already points at,
///   2. same-Mac CG-UUID fast path,
///   3. the single best scored fingerprint match above the recognition threshold (`IdentityScorer`),
///   4. otherwise mint a new record.
/// Two identical monitors with no serial therefore stay distinct until paired, rather than being
/// silently merged.
///
/// Recognition never guesses. Several records sharing the qualified serial with nothing to pick
/// between them, a tie for the best score, or two displays present at the same time claiming one
/// record — each of those yields a *provisional* record (`DisplayRecord.unresolvedCandidates`): no
/// alias, tags or pairing from any candidate, nothing persisted, the candidates left untouched. A
/// record claimed twice goes to the claimant with strictly stronger evidence (serial and CG UUID,
/// then serial, then CG UUID, then score) and to neither on a tie. The user naming, tagging or
/// pairing a provisional display is the resolution: it becomes a record of its own.
public actor DisplayRegistry {
    private var state: RegistryState
    private let store: any RegistryStoring
    private let recognitionThreshold: Double
    /// The provisional records handed out by the latest resolve, with the CG UUID each was seen
    /// under. In memory only: provisional records are answers about the current topology.
    private var provisional: [DisplayRecordID: (record: DisplayRecord, cgUUID: String?)] = [:]

    public init(store: any RegistryStoring, recognitionThreshold: Double = 0.5) async {
        self.store = store
        self.recognitionThreshold = recognitionThreshold
        self.state = await store.load()
    }

    public func allRecords() -> [DisplayRecord] { state.records }

    public func record(for id: DisplayRecordID) -> DisplayRecord? {
        state.records.first { $0.id == id } ?? provisional[id]?.record
    }

    /// The record previously minted for a CG UUID, if any. Recognition normally goes through
    /// `resolve` (fingerprint first), but a display that is currently turned OFF has no live
    /// hardware to fingerprint — this index is the only way to recover its alias and tags.
    public func record(forCGUUID cgUUID: String) -> DisplayRecord? {
        state.cgUUIDIndex[cgUUID].flatMap(record(for:))
    }

    /// Every remembered display keyed by the OBSERVATION id (`cg:<uuid>`) rather than the registry's
    /// own minted id — the form group membership, the settings ledgers, and the UI hold. A display
    /// that isn't plugged in has no observation to carry its name, so this is what lets a membership
    /// list offer it (and name it) instead of hiding it until it comes back.
    public func recordsByObservationID() -> [DisplayRecordID: DisplayRecord] {
        var byObservationID: [DisplayRecordID: DisplayRecord] = [:]
        for (cgUUID, recordID) in state.cgUUIDIndex {
            guard let known = record(for: recordID) else { continue }
            byObservationID[.forCGUUID(cgUUID)] = known
        }
        return byObservationID
    }

    /// Resolves a fingerprint (+ optional CG UUID) to a stable record, recognizing or minting.
    public func resolve(
        fingerprint: DisplayFingerprint,
        cgUUID: String?,
        displayClass: DisplayClass = .unknown,
        now: Date = Date()
    ) async -> DisplayRecord {
        let record = resolveLocked([(fingerprint, cgUUID, displayClass)], now: now)[0].record
        await persist()
        return record
    }

    /// Batched resolve: recognizes/mints every input against in-memory state, then persists EXACTLY
    /// once. The inputs are the displays present together, so this is also where one record is kept
    /// from being handed to two of them. Only the disk write is coalesced, so N-displays-per-refresh
    /// no longer means N full-registry JSON writes.
    public func resolveAll(
        _ inputs: [(fingerprint: DisplayFingerprint, cgUUID: String?, displayClass: DisplayClass)],
        now: Date = Date()
    ) async -> [DisplayRecord] {
        await resolveAllExplained(inputs, now: now).map(\.record)
    }

    /// `resolveAll`, with how each display was matched (TB-09): the explanation is the very value
    /// the decision was taken from, including a record lost to another present display.
    public func resolveAllExplained(
        _ inputs: [(fingerprint: DisplayFingerprint, cgUUID: String?, displayClass: DisplayClass)],
        now: Date = Date()
    ) async -> [(record: DisplayRecord, explanation: IdentityMatchExplanation)] {
        let resolved = resolveLocked(inputs, now: now)
        if !inputs.isEmpty { await persist() }
        return resolved
    }

    private enum Claim {
        case record(DisplayRecordID, IdentityMatchEvidence)
        case ambiguous([DisplayRecordID])
        case mint
    }

    /// The recognize-or-mint logic plus the recency/fingerprint mutation, WITHOUT persisting. Callers
    /// persist once after applying every mutation they intend to (see `resolve` / `resolveAll`).
    private func resolveLocked(
        _ inputs: [(fingerprint: DisplayFingerprint, cgUUID: String?, displayClass: DisplayClass)],
        now: Date
    ) -> [(record: DisplayRecord, explanation: IdentityMatchExplanation)] {
        var explanations = inputs.map { explain($0.fingerprint, cgUUID: $0.cgUUID, excluding: []) }
        var claims = explanations.map(Self.claim(from:))

        // One record per present display. Two displays on the desk at once are two displays, so a
        // record both claim can be at most one of them: the strictly better-evidenced claimant
        // keeps it; on a tie nothing says which, and neither does.
        var claimants: [DisplayRecordID: [Int]] = [:]
        for (index, claim) in claims.enumerated() {
            if case .record(let id, _) = claim { claimants[id, default: []].append(index) }
        }
        var outranked: [Int] = []
        for (id, indices) in claimants where indices.count > 1 {
            let strengths = indices.map { index -> IdentityMatchEvidence in
                guard case .record(_, let evidence) = claims[index] else { return .scored }
                return evidence
            }
            let best = strengths.max()
            let strongest = indices.indices.filter { strengths[$0] == best }.map { indices[$0] }
            for index in indices where strongest.count > 1 || strongest.first != index {
                claims[index] = .ambiguous([id])
                explanations[index].decision = .ambiguous([id], .claimedByAnotherDisplay)
                if strongest.count == 1 { outranked.append(index) }
            }
        }
        // A display that lost its record to a better-evidenced one is known NOT to be that record,
        // so it resolves once more without any record already held — to its own, a score, or a new
        // one. Should two of them land on the same record again, neither gets it.
        if !outranked.isEmpty {
            var held: Set<DisplayRecordID> = []
            for claim in claims { if case .record(let id, _) = claim { held.insert(id) } }
            var retried: [DisplayRecordID: [Int]] = [:]
            for index in outranked {
                var retry = explain(inputs[index].fingerprint, cgUUID: inputs[index].cgUUID, excluding: held)
                let next = Self.claim(from: retry)
                // `.ambiguous` from this round is about the remaining candidates; keep the one it lost too.
                if case .ambiguous(let candidates) = next, case .ambiguous(let lost) = claims[index] {
                    claims[index] = .ambiguous(lost + candidates)
                    retry.decision = .ambiguous(lost + candidates, .claimedByAnotherDisplay)
                } else {
                    claims[index] = next
                }
                explanations[index] = retry
                if case .record(let id, _) = claims[index] { retried[id, default: []].append(index) }
            }
            for (id, indices) in retried where indices.count > 1 {
                for index in indices {
                    claims[index] = .ambiguous([id])
                    explanations[index].decision = .ambiguous([id], .claimedByAnotherDisplay)
                }
            }
        }

        var handedOut: [DisplayRecordID: (record: DisplayRecord, cgUUID: String?)] = [:]
        var resolved: [(record: DisplayRecord, explanation: IdentityMatchExplanation)] = []
        for (index, input) in inputs.enumerated() {
            switch claims[index] {
            case .record(let id, _):
                resolved.append((touchLocked(id, fingerprint: input.fingerprint, cgUUID: input.cgUUID, now: now),
                                 explanations[index]))
            case .mint:
                let record = DisplayRecord(
                    id: .generate(now: now), fingerprint: input.fingerprint,
                    displayClass: input.displayClass, lastSeen: now)
                state.records.append(record)
                if let cgUUID = input.cgUUID { state.cgUUIDIndex[cgUUID] = record.id }
                resolved.append((record, explanations[index]))
            case .ambiguous(let candidates):
                // A stable id per CG UUID keeps the answer the same across refreshes; the index
                // only tells apart two provisional displays reporting the same UUID.
                var id = DisplayRecordID(rawValue: "unresolved:\(input.cgUUID ?? "#\(index)")")
                if handedOut[id] != nil { id = DisplayRecordID(rawValue: "\(id.rawValue)#\(index)") }
                let record = DisplayRecord(
                    id: id, fingerprint: input.fingerprint, displayClass: input.displayClass,
                    lastSeen: now, unresolvedCandidates: candidates.sorted { $0.rawValue < $1.rawValue })
                handedOut[id] = (record, input.cgUUID)
                resolved.append((record, explanations[index]))
            }
        }
        provisional = handedOut
        return resolved
    }

    /// What one display claims on its own, before the batch's one-record-per-display rule, among
    /// the records not in `excluded` — the matching stages of `IdentityMatching.evaluate`. A record
    /// whose own vendor, model or qualified serial says it is a different display is out of EVERY
    /// stage: the CG UUID index is a same-Mac routing hint, and a score is a sum of agreements (a
    /// paired record of the same model still scores 0.925 for its twin with another serial).
    /// Following either would merge the two displays, hand this one the other's alias and tags, and
    /// overwrite the record's identity with this display's serial.
    private func explain(_ fingerprint: DisplayFingerprint, cgUUID: String?,
                         excluding excluded: Set<DisplayRecordID>) -> IdentityMatchExplanation {
        IdentityMatching.evaluate(fingerprint: fingerprint, cgUUID: cgUUID, records: state.records,
                                  cgUUIDIndex: state.cgUUIDIndex, excluding: excluded,
                                  recognitionThreshold: recognitionThreshold)
    }

    private static func claim(from explanation: IdentityMatchExplanation) -> Claim {
        switch explanation.decision {
        case .record(let id, let evidence): return .record(id, evidence)
        case .ambiguous(let candidates, _): return .ambiguous(candidates)
        case .newRecord: return .mint
        }
    }

    /// How a display reporting `fingerprint` would be matched against the registry as it is now,
    /// on its own — for a display that isn't connected to ask about, or a test. A live display's
    /// actual answer comes from `resolveAllExplained`, which also knows about the displays beside it.
    public func explainMatch(fingerprint: DisplayFingerprint, cgUUID: String?) -> IdentityMatchExplanation {
        explain(fingerprint, cgUUID: cgUUID, excluding: [])
    }

    public func setAlias(_ alias: String?, for id: DisplayRecordID) async {
        try? await mutate(id) { $0.alias = alias?.isEmpty == true ? nil : alias }
    }

    public func addTag(_ tag: String, to id: DisplayRecordID) async {
        try? await mutate(id) { $0.tags.insert(tag) }
    }

    public func removeTag(_ tag: String, from id: DisplayRecordID) async {
        try? await mutate(id) { $0.tags.remove(tag) }
    }

    /// Marks a record as an explicit user pairing, lifting its identity confidence (REG-004).
    public func confirmPairing(for id: DisplayRecordID) async {
        try? await mutate(id) { $0.pairingConfirmed = true }
    }

    /// The persisted state as it stands — what a settings export carries (SO-11). Provisional
    /// records are left out: they answer a question about the live topology, not a memory.
    public func currentState() -> RegistryState { state }

    /// Replaces everything remembered with `newState` and persists it — a settings import or
    /// reset (SO-11). Provisional answers about the old state are dropped with it; the next
    /// resolve works from the new records. Throws when registry.json couldn't be written: memory
    /// then holds `newState` while the file still holds what was there, and the caller decides —
    /// an import puts the previous state back the same way.
    public func replaceState(_ newState: RegistryState) async throws {
        state = newState
        provisional.removeAll()
        try await store.save(state)
    }

    /// Every persisted record with the observation ids (`cg:<uuid>`) the CG UUID index points at it —
    /// the inventory Settings lists, connected or not. A record whose display never reported a UUID
    /// has no observation id here; the live resolution supplies it while that display is present.
    public func rememberedDisplays() -> [(record: DisplayRecord, observationIDs: [DisplayRecordID])] {
        var byRecord: [DisplayRecordID: [DisplayRecordID]] = [:]
        for (cgUUID, recordID) in state.cgUUIDIndex { byRecord[recordID, default: []].append(.forCGUUID(cgUUID)) }
        return state.records.map { record in
            (record, (byRecord[record.id] ?? []).sorted { $0.rawValue < $1.rawValue })
        }
    }

    /// Removes a remembered record and every CG UUID index entry pointing at it (SD-09). Its display,
    /// if it is ever seen again, is recognized afresh — matched like any new display or minted.
    /// Returns false when there was no such persisted record (a provisional one has nothing stored).
    @discardableResult
    public func forget(_ id: DisplayRecordID) async -> Bool {
        guard state.records.contains(where: { $0.id == id }) else { return false }
        state.records.removeAll { $0.id == id }
        state.cgUUIDIndex = state.cgUUIDIndex.filter { $0.value != id }
        await persist()
        return true
    }

    /// Clears what the user attached to a record — its name and tags, and the history of settings
    /// moved onto it — while keeping the identity evidence (fingerprint, pairing, CG UUID routing),
    /// so a connected display whose settings are reset is still recognized as itself rather than
    /// re-matched from scratch.
    public func clearUserData(for id: DisplayRecordID) async {
        guard state.records.contains(where: { $0.id == id }) else { return }
        try? await mutate(id) {
            $0.alias = nil
            $0.tags = []
            $0.provenance = nil
        }
    }

    /// The registry half of a confirmed settings transfer (SD-10, `DisplaySettingsTransfer`): the
    /// destination takes the source's name and/or tags — replacing its own, not merged — and records
    /// where they came from; the source record and every CG UUID index entry pointing at it go, as
    /// with `forget`. The destination keeps its own fingerprint, pairing and index entries: settings
    /// move, identities never merge, so if the source's display is ever seen again it is recognized
    /// afresh. A provisional destination becomes a record of its own, like any user edit makes it.
    /// One write. Returns the destination's persisted id, or nil (and changes nothing) when the
    /// destination is unknown or the source is the destination.
    @discardableResult
    public func transferUserData(from source: DisplayRecordID?, to destination: DisplayRecordID,
                                 alias: Bool, tags: Bool,
                                 provenance: DisplayRecordProvenance) async -> DisplayRecordID? {
        guard source != destination else { return nil }
        let sourceRecord = source.flatMap { id in state.records.first { $0.id == id } }
        guard let index = state.records.firstIndex(where: { $0.id == destination }) ?? materializeLocked(destination)
        else { return nil }
        if alias { state.records[index].alias = sourceRecord?.alias }
        if tags { state.records[index].tags = sourceRecord?.tags ?? [] }
        state.records[index].provenance = (state.records[index].provenance ?? []) + [provenance]
        let destinationID = state.records[index].id
        if let source, sourceRecord != nil {
            state.records.removeAll { $0.id == source }
            state.cgUUIDIndex = state.cgUUIDIndex.filter { $0.value != source }
        }
        await persist()
        return destinationID
    }

    /// Notes on a record that settings were moved onto it from one of its own earlier identifiers
    /// (`DisplaySettingsTransfer` migration). Nothing about recognition changes.
    public func appendProvenance(_ provenance: DisplayRecordProvenance, to id: DisplayRecordID) async {
        guard state.records.contains(where: { $0.id == id }) else { return }
        try? await mutate(id) { $0.provenance = ($0.provenance ?? []) + [provenance] }
    }

    // MARK: - Private

    private enum RegistryError: Error { case unknownRecord }

    private func mutate(_ id: DisplayRecordID, _ change: (inout DisplayRecord) -> Void) async throws {
        guard let index = state.records.firstIndex(where: { $0.id == id }) ?? materializeLocked(id) else {
            throw RegistryError.unknownRecord
        }
        change(&state.records[index])
        await persist()
    }

    /// Turns a provisional record into a remembered display of its own, at the moment the user
    /// attaches something to it: naming *this* display is the one piece of evidence recognition
    /// lacked. Its CG UUID now points here; the candidates it couldn't be told from keep their
    /// alias, tags and pairing, and the CG UUIDs that still point at them. Returns the new index.
    private func materializeLocked(_ id: DisplayRecordID) -> Int? {
        guard let pending = provisional.removeValue(forKey: id) else { return nil }
        var record = pending.record
        record.id = .generate(now: record.lastSeen ?? Date())
        record.unresolvedCandidates = nil
        state.records.append(record)
        if let cgUUID = pending.cgUUID { state.cgUUIDIndex[cgUUID] = record.id }
        return state.records.count - 1
    }

    private func touchLocked(
        _ id: DisplayRecordID, fingerprint: DisplayFingerprint, cgUUID: String?, now: Date
    ) -> DisplayRecord {
        let index = state.records.firstIndex { $0.id == id }!
        state.records[index].fingerprint = Self.merged(state.records[index].fingerprint, fingerprint)
        state.records[index].lastSeen = now
        if let cgUUID { state.cgUUIDIndex[cgUUID] = id }
        return state.records[index]
    }

    /// Best-effort, as it always was for resolves and edits: the next change writes the whole state
    /// again. Only `replaceState` needs the error, and it saves through the store directly.
    private func persist() async {
        try? await store.save(state)
    }

    /// Fills gaps in `base` from `new` without dropping evidence we already had.
    private static func merged(_ base: DisplayFingerprint, _ new: DisplayFingerprint) -> DisplayFingerprint {
        DisplayFingerprint(
            vendorID: new.vendorID ?? base.vendorID,
            productID: new.productID ?? base.productID,
            serialNumber: new.serialNumber ?? base.serialNumber,
            serialHash: new.serialHash ?? base.serialHash,
            modelName: new.modelName ?? base.modelName,
            manufactureYear: new.manufactureYear ?? base.manufactureYear,
            manufactureWeek: new.manufactureWeek ?? base.manufactureWeek,
            physicalWidthMM: new.physicalWidthMM ?? base.physicalWidthMM,
            physicalHeightMM: new.physicalHeightMM ?? base.physicalHeightMM,
            edidHash: new.edidHash ?? base.edidHash
        )
    }
}
