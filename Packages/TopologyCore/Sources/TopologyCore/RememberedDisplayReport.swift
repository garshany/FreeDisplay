import DisplayDomain
import Foundation

extension RememberedDisplay {
    /// Saved-only facts never reuse a ledger's runtime display ID or pretend to have current mode,
    /// HDR or link data. Multiple historical UUIDs may carry conflicting anchors: choose none
    /// rather than letting dictionary order decide which screen's settings the report describes.
    public func savedReportFacts(appVersion: String, generatedAt: String, name: String,
                                 lastSeen: String?, luminanceSettings: [String: LuminanceAnchorSettings]) -> DisplayReportFacts {
        var facts = DisplayReportFacts(
            appName: "FreeDisplay", appVersion: appVersion, generatedAt: generatedAt, presence: .savedOnly,
            name: name, displayClass: record?.displayClass ?? offline?.displayClass ?? .unknown, recordID: id)
        facts.alias = record?.alias
        facts.lastSeen = lastSeen
        facts.vendorNumber = record?.fingerprint.vendorID.flatMap(UInt32.init(exactly:))
        facts.modelNumber = record?.fingerprint.productID.flatMap(UInt32.init(exactly:))
        facts.serialNumber = record?.fingerprint.serialNumber.flatMap(UInt32.init)
        let uuids = observationIDs.compactMap(\.cgUUID).sorted()
        facts.uuid = uuids.isEmpty ? nil : uuids.joined(separator: ", ")
        let keys = Set(observationIDs.map(\.rawValue)).union([id])
        let anchors = Set(keys.filter { PersistentDisplayIdentity.isPersistent(.init(rawValue: $0)) }
            .compactMap { luminanceSettings[$0] })
        if anchors.count == 1 { facts.luminanceAnchors = anchors.first }
        return facts
    }
}
