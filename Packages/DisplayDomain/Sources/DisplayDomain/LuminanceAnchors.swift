// SPDX-License-Identifier: GPL-3.0-or-later
// Original clean-room implementation for FreeDisplay (SD-13, TR-13, TB-13, FB T20).
import Foundation

/// A luminance figure a display can be described by. Each is an anchor for labelling — a value the
/// user entered or the display's EDID states — never something OpenDisplay measured, and never a
/// setting the panel receives: changing one changes a label, not the light.
public enum LuminanceAnchor: String, Hashable, Sendable, CaseIterable, Codable {
    /// Light at the lowest brightness position (SDR).
    case sdrMinimum
    /// Light at the highest brightness position (SDR). Also what software dimming starts from.
    case sdrMaximum
    /// SDR content white while the display shows HDR.
    case hdrReferenceWhite
    /// What the display holds full-screen in HDR — separate from the peak, which only small or brief
    /// highlights reach.
    case hdrSustained
    /// HDR highlight peak.
    case hdrPeak

    public var isHDR: Bool { self != .sdrMinimum && self != .sdrMaximum }

    /// Pairs kept in order when the user enters both members: lower never above upper.
    public static let orderedPairs: [(lower: LuminanceAnchor, upper: LuminanceAnchor)] = [
        (.sdrMinimum, .sdrMaximum),
        (.hdrReferenceWhite, .hdrPeak),
        (.hdrSustained, .hdrPeak),
    ]
}

/// Where a value the user entered came from, as the user says. OpenDisplay can't verify any of
/// them; the label only carries the user's own account forward.
public enum ManualLuminanceBasis: String, Hashable, Sendable, CaseIterable, Codable {
    case unspecified
    /// From the display's published specification.
    case specification
    /// The user measured it (with a meter of their own).
    case userMeasurement
    /// The user's estimate.
    case userEstimate
}

/// A value the user entered for one anchor.
public struct ManualLuminance: Hashable, Sendable, Codable {
    public var nits: Double
    public var basis: ManualLuminanceBasis

    public init(nits: Double, basis: ManualLuminanceBasis = .unspecified) {
        self.nits = nits
        self.basis = basis
    }

    private enum CodingKeys: String, CodingKey { case nits, basis }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nits = try container.decode(Double.self, forKey: .nits)
        // A basis a later version adds degrades to "not specified", not to a lost value.
        basis = (try? container.decodeIfPresent(ManualLuminanceBasis.self, forKey: .basis)) ?? .unspecified
    }

    /// Luminance is a non-negative, finite number of cd/m².
    public var isUsable: Bool { nits.isFinite && nits >= 0 }
}

/// One display's luminance anchors as the user configured them (SD-13/TB-13). Turning the entered
/// values off keeps them — they are ignored, not deleted — and clearing one is what returns it to
/// whatever the display reports, if anything.
public struct LuminanceAnchorSettings: Hashable, Sendable, Codable {
    /// Whether the entered values are used. On by default, with nothing entered.
    public var manualValuesEnabled: Bool
    public private(set) var overrides: [LuminanceAnchor: ManualLuminance]

    public init(manualValuesEnabled: Bool = true, overrides: [LuminanceAnchor: ManualLuminance] = [:]) {
        self.manualValuesEnabled = manualValuesEnabled
        self.overrides = overrides
    }

    /// Nothing entered and nothing switched off — the same as having no record at all.
    public var isDefault: Bool { manualValuesEnabled && overrides.isEmpty }

    /// The first entered value that isn't a usable luminance (negative or not finite), if any — what
    /// a settings import refuses rather than reinterprets.
    public var unusableAnchor: LuminanceAnchor? {
        LuminanceAnchor.allCases.first { overrides[$0].map { !$0.isUsable } ?? false }
    }

    /// The result of entering a value.
    public struct Edit: Hashable, Sendable {
        public var settings: LuminanceAnchorSettings
        /// The value stored — the entry, or 0 for a negative entry.
        public var storedNits: Double
        /// A negative entry was stored as 0.
        public var raisedToZero: Bool
        /// Entered partners the entry moved to keep their pair in order, with their new values.
        public var movedPartners: [LuminanceAnchor: Double]
    }

    public enum EntryError: Error, Hashable, Sendable {
        /// Not a number, or infinite: nothing is stored and nothing else changes.
        case notFinite
    }

    /// Enters `nits` for `anchor`. A negative entry is stored as 0 (light can't be negative); a
    /// non-finite one is refused and changes nothing. When the anchor's partner in an ordered pair
    /// is also entered and the new value crosses it, the partner moves to the same value — so the
    /// pair stays ordered — and the edit says so. A partner that isn't entered is never touched.
    public func setting(_ anchor: LuminanceAnchor, nits: Double,
                        basis: ManualLuminanceBasis? = nil) throws(EntryError) -> Edit {
        guard nits.isFinite else { throw .notFinite }
        let stored = max(0, nits)
        var updated = self
        updated.overrides[anchor] = ManualLuminance(nits: stored, basis: basis ?? overrides[anchor]?.basis ?? .unspecified)
        var moved: [LuminanceAnchor: Double] = [:]
        for pair in LuminanceAnchor.orderedPairs {
            if pair.lower == anchor, var partner = updated.overrides[pair.upper], partner.nits < stored {
                partner.nits = stored
                updated.overrides[pair.upper] = partner
                moved[pair.upper] = stored
            } else if pair.upper == anchor, var partner = updated.overrides[pair.lower], partner.nits > stored {
                partner.nits = stored
                updated.overrides[pair.lower] = partner
                moved[pair.lower] = stored
            }
        }
        return Edit(settings: updated, storedNits: stored, raisedToZero: nits < 0, movedPartners: moved)
    }

    /// Changes only the stated basis of an entered value; nothing when the anchor isn't entered.
    public func settingBasis(_ basis: ManualLuminanceBasis, for anchor: LuminanceAnchor) -> LuminanceAnchorSettings {
        guard var entry = overrides[anchor] else { return self }
        var updated = self
        entry.basis = basis
        updated.overrides[anchor] = entry
        return updated
    }

    /// Removes the entered value: the anchor goes back to what the display reports, or unknown.
    public func clearing(_ anchor: LuminanceAnchor) -> LuminanceAnchorSettings {
        var updated = self
        updated.overrides[anchor] = nil
        return updated
    }

    private enum CodingKeys: String, CodingKey { case manualValuesEnabled, overrides }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(manualValuesEnabled, forKey: .manualValuesEnabled)
        let keyed = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
        try container.encode(keyed, forKey: .overrides)
    }

    /// Tolerant like the rest of the settings: an anchor this build doesn't know (written by a later
    /// version) is skipped, not allowed to cost the others.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        manualValuesEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .manualValuesEnabled)) ?? true
        let raw = (try? container.decodeIfPresent([String: LenientEntry].self, forKey: .overrides)) ?? [:]
        var overrides: [LuminanceAnchor: ManualLuminance] = [:]
        for (key, entry) in raw {
            if let anchor = LuminanceAnchor(rawValue: key), let value = entry.value { overrides[anchor] = value }
        }
        self.overrides = overrides
    }

    /// One entry that may not decode — so a damaged entry costs only itself.
    private struct LenientEntry: Decodable {
        let value: ManualLuminance?
        init(from decoder: Decoder) throws { value = try? ManualLuminance(from: decoder) }
    }
}

/// Which part of a display's EDID stated a luminance.
public enum LuminanceReportSource: Hashable, Sendable {
    /// The CTA-861 HDR Static Metadata block: the content luminance the display asks for.
    case ctaHDRStaticMetadata(block: Int)
    /// The DisplayID 2.x Display Parameters block: the panel's native luminance.
    case displayIDParameters(block: Int)
}

/// A luminance the display's own EDID states.
public struct ReportedLuminanceValue: Hashable, Sendable {
    public var nits: Double
    public var source: LuminanceReportSource

    public init(nits: Double, source: LuminanceReportSource) {
        self.nits = nits
        self.source = source
    }
}

/// The luminance figures a display's EDID states, mapped onto anchors. Only HDR anchors can come
/// from here: no EDID field states SDR desktop luminance, so SDR anchors stay unknown unless
/// entered. The first block that states a figure wins; a CTA block's figure comes before a
/// DisplayID block's in the same position.
public struct ReportedLuminance: Hashable, Sendable {
    public var values: [LuminanceAnchor: ReportedLuminanceValue]
    /// The minimum luminance the EDID states. Kept for the report; it is the darkest black, not the
    /// light at the lowest brightness position, so it anchors nothing.
    public var minimum: ReportedLuminanceValue?
    /// The EDID says the display accepts an HDR transfer function (PQ or HLG).
    public var statesHDRTransfer: Bool

    public init(values: [LuminanceAnchor: ReportedLuminanceValue] = [:], minimum: ReportedLuminanceValue? = nil,
                statesHDRTransfer: Bool = false) {
        self.values = values
        self.minimum = minimum
        self.statesHDRTransfer = statesHDRTransfer
    }

    public static func from(_ edid: EDIDDecoded) -> ReportedLuminance {
        var reported = ReportedLuminance()
        func offer(_ anchor: LuminanceAnchor, _ nits: Double?, _ source: LuminanceReportSource) {
            guard reported.values[anchor] == nil, let nits, nits.isFinite, nits > 0 else { return }
            reported.values[anchor] = ReportedLuminanceValue(nits: nits, source: source)
        }
        func offerMinimum(_ nits: Double?, _ source: LuminanceReportSource) {
            guard reported.minimum == nil, let nits, nits.isFinite, nits >= 0 else { return }
            reported.minimum = ReportedLuminanceValue(nits: nits, source: source)
        }
        for ext in edid.extensions {
            guard case .cta(let cta) = ext.content, let hdr = cta.hdrStaticMetadata else { continue }
            let source = LuminanceReportSource.ctaHDRStaticMetadata(block: ext.block)
            if hdr.pq || hdr.hlg { reported.statesHDRTransfer = true }
            offer(.hdrPeak, hdr.maxLuminance, source)
            offer(.hdrSustained, hdr.maxFrameAverageLuminance, source)
            offerMinimum(hdr.minLuminance, source)
        }
        for ext in edid.extensions {
            guard case .displayID(let id) = ext.content, let parameters = id.parameters else { continue }
            let source = LuminanceReportSource.displayIDParameters(block: ext.block)
            offer(.hdrPeak, parameters.maxLuminanceTenPercent, source)
            offer(.hdrSustained, parameters.maxLuminanceFullCoverage, source)
            offerMinimum(parameters.minLuminance, source)
        }
        return reported
    }
}

/// Where an anchor's value in use came from.
public enum LuminanceProvenance: Hashable, Sendable {
    case manual(ManualLuminanceBasis)
    case reported(LuminanceReportSource)
}

/// The value an anchor has, with its provenance.
public struct ResolvedLuminance: Hashable, Sendable {
    public var nits: Double
    public var provenance: LuminanceProvenance
    /// An entered value set aside: it exists but manual values are off.
    public var ignoredManual: ManualLuminance?
    /// The reported value an entered one replaces (kept visible beside it).
    public var replacedReport: ReportedLuminanceValue?
}

/// Combines what the user entered with what the display reports, and calculates estimates from
/// the result. Every number it produces carries where it came from.
public enum LuminanceAnchorResolver {
    /// One anchor's state: in use (with provenance), or unknown — possibly with an entered value
    /// set aside while manual values are off.
    public struct Entry: Hashable, Sendable {
        public var anchor: LuminanceAnchor
        public var resolved: ResolvedLuminance?
        /// The entered value while manual values are off (retained, not used).
        public var ignoredManual: ManualLuminance?
    }

    public static func resolve(_ settings: LuminanceAnchorSettings?, reported: ReportedLuminance,
                               anchor: LuminanceAnchor) -> Entry {
        let settings = settings ?? LuminanceAnchorSettings()
        let manual = settings.overrides[anchor].flatMap { $0.isUsable ? $0 : nil }
        let report = reported.values[anchor]
        if let manual, settings.manualValuesEnabled {
            return Entry(anchor: anchor, resolved: ResolvedLuminance(
                nits: manual.nits, provenance: .manual(manual.basis), ignoredManual: nil, replacedReport: report))
        }
        let ignored = settings.manualValuesEnabled ? nil : manual
        guard let report else { return Entry(anchor: anchor, resolved: nil, ignoredManual: ignored) }
        return Entry(anchor: anchor, resolved: ResolvedLuminance(
            nits: report.nits, provenance: .reported(report.source), ignoredManual: ignored, replacedReport: nil),
            ignoredManual: ignored)
    }

    public static func resolveAll(_ settings: LuminanceAnchorSettings?,
                                  reported: ReportedLuminance) -> [LuminanceAnchor: Entry] {
        Dictionary(uniqueKeysWithValues: LuminanceAnchor.allCases.map { ($0, resolve(settings, reported: reported, anchor: $0)) })
    }

    /// Whether the HDR anchors belong on screen: the display shows signs of HDR (an HDR transfer
    /// function or luminance in its EDID, or macOS reporting EDR headroom above SDR), or the user
    /// already entered one — which stays reachable so it can be cleared. Showing them enables
    /// nothing.
    public static func showsHDRAnchors(reported: ReportedLuminance, potentialEDRHeadroom: Double?,
                                       settings: LuminanceAnchorSettings?) -> Bool {
        if reported.statesHDRTransfer || reported.values.keys.contains(where: \.isHDR) { return true }
        if let headroom = potentialEDRHeadroom, headroom.isFinite, headroom > 1 { return true }
        return settings?.overrides.keys.contains(where: \.isHDR) ?? false
    }

    // MARK: Estimates

    /// Why no estimate can be given.
    public enum EstimateUnavailable: Error, Hashable, Sendable {
        /// These anchors are unknown.
        case missingAnchors([LuminanceAnchor])
        /// The minimum in use is above the maximum in use.
        case anchorsOutOfOrder
        /// The position isn't a number.
        case positionNotFinite
    }

    /// A luminance calculated from a brightness position and the SDR anchors. An estimate: the
    /// position is assumed to map linearly onto the light between the two anchors, which a real
    /// panel or controller need not do.
    public struct NitsEstimate: Hashable, Sendable {
        public var nits: Double
        /// The position used, within 0...1.
        public var position: Double
        /// The position asked for was outside 0...1 and was held at the nearer end.
        public var positionClamped: Bool
        public var minimum: ResolvedLuminance
        public var maximum: ResolvedLuminance
    }

    public static func estimateNits(atPosition position: Double,
                                    anchors: [LuminanceAnchor: Entry]) -> Result<NitsEstimate, EstimateUnavailable> {
        guard position.isFinite else { return .failure(.positionNotFinite) }
        let range: (ResolvedLuminance, ResolvedLuminance)
        switch sdrRange(anchors) {
        case .success(let found): range = found
        case .failure(let reason): return .failure(reason)
        }
        let clamped = min(1, max(0, position))
        let nits = range.0.nits + (range.1.nits - range.0.nits) * clamped
        return .success(NitsEstimate(nits: nits, position: clamped, positionClamped: clamped != position,
                                     minimum: range.0, maximum: range.1))
    }

    /// The position that, by the same linear estimate, gives `nits`.
    public struct PositionEstimate: Hashable, Sendable {
        public enum Saturation: Hashable, Sendable {
            case none
            /// The requested light is below the minimum anchor: held at position 0.
            case belowMinimum
            /// The requested light is above the maximum anchor: held at position 1.
            case aboveMaximum
        }
        public var position: Double
        public var saturation: Saturation
    }

    public static func estimatePosition(forNits nits: Double,
                                        anchors: [LuminanceAnchor: Entry]) -> Result<PositionEstimate, EstimateUnavailable> {
        guard nits.isFinite else { return .failure(.positionNotFinite) }
        let range: (ResolvedLuminance, ResolvedLuminance)
        switch sdrRange(anchors) {
        case .success(let found): range = found
        case .failure(let reason): return .failure(reason)
        }
        let low = range.0.nits, high = range.1.nits
        if nits < low { return .success(PositionEstimate(position: 0, saturation: .belowMinimum)) }
        if nits > high { return .success(PositionEstimate(position: 1, saturation: .aboveMaximum)) }
        // Equal anchors: every position gives the same light; the lowest position is the answer.
        guard high > low else { return .success(PositionEstimate(position: 0, saturation: .none)) }
        return .success(PositionEstimate(position: (nits - low) / (high - low), saturation: .none))
    }

    private static func sdrRange(_ anchors: [LuminanceAnchor: Entry])
        -> Result<(ResolvedLuminance, ResolvedLuminance), EstimateUnavailable> {
        let minimum = anchors[.sdrMinimum]?.resolved, maximum = anchors[.sdrMaximum]?.resolved
        guard let minimum, let maximum else {
            return .failure(.missingAnchors([minimum == nil ? .sdrMinimum : nil,
                                             maximum == nil ? .sdrMaximum : nil].compactMap { $0 }))
        }
        guard minimum.nits <= maximum.nits else { return .failure(.anchorsOutOfOrder) }
        return .success((minimum, maximum))
    }
}

/// Words luminance anchors and estimates for the report and the settings card: each value with its
/// provenance, unknowns as unknown, and estimates labelled as estimates.
public enum LuminanceReport {
    public static func anchorName(_ anchor: LuminanceAnchor, _ l: ReportLocalizer = .english) -> String {
        switch anchor {
        case .sdrMinimum: return l("SDR minimum (lowest brightness)")
        case .sdrMaximum: return l("SDR maximum (highest brightness)")
        case .hdrReferenceWhite: return l("HDR reference white (SDR content in HDR)")
        case .hdrSustained: return l("HDR sustained (full screen)")
        case .hdrPeak: return l("HDR peak (highlights)")
        }
    }

    public static func nitsText(_ nits: Double, _ l: ReportLocalizer = .english) -> String {
        l.fill("%1 nits", l.decimal(nits, 1))
    }

    public static func provenanceText(_ provenance: LuminanceProvenance, _ l: ReportLocalizer = .english) -> String {
        switch provenance {
        case .manual(.unspecified): return l("entered by you")
        case .manual(.specification): return l("entered by you, from the display’s specification")
        case .manual(.userMeasurement): return l("entered by you, from your own measurement")
        case .manual(.userEstimate): return l("entered by you as an estimate")
        case .reported(let source): return sourceText(source, l)
        }
    }

    public static func sourceText(_ source: LuminanceReportSource, _ l: ReportLocalizer = .english) -> String {
        switch source {
        case .ctaHDRStaticMetadata(let block):
            return l.fill("stated by the EDID (HDR static metadata, block %1)", "\(block)")
        case .displayIDParameters(let block):
            return l.fill("stated by the EDID (DisplayID display parameters, block %1)", "\(block)")
        }
    }

    /// One anchor as a single value: "600 nits — stated by …", "Unknown", plus what's set aside.
    public static func entryText(_ entry: LuminanceAnchorResolver.Entry, _ l: ReportLocalizer = .english) -> String {
        var parts: [String] = []
        if let resolved = entry.resolved {
            parts.append(l.fill("%1 — %2", nitsText(resolved.nits, l), provenanceText(resolved.provenance, l)))
            if let report = resolved.replacedReport {
                parts.append(l.fill("replaces %1 %2", nitsText(report.nits, l), sourceText(report.source, l)))
            }
        } else {
            parts.append(l("Unknown"))
        }
        if let ignored = entry.ignoredManual {
            parts.append(l.fill("your %1 is kept but not used while entered values are off", nitsText(ignored.nits, l)))
        }
        return parts.joined(separator: "; ")
    }

    public static func estimateText(_ estimate: Result<LuminanceAnchorResolver.NitsEstimate, LuminanceAnchorResolver.EstimateUnavailable>,
                                    _ l: ReportLocalizer = .english) -> String {
        switch estimate {
        case .success(let value):
            var text = l.fill("about %1 (estimated, not measured)", nitsText(value.nits, l))
            if value.positionClamped { text += "; " + l("the position was outside the range and was held at its end") }
            return text
        case .failure(.missingAnchors(let anchors)):
            return l.fill("No estimate: %1 unknown", anchors.map { anchorName($0, l) }.joined(separator: ", "))
        case .failure(.anchorsOutOfOrder):
            return l("No estimate: the minimum in use is above the maximum")
        case .failure(.positionNotFinite):
            return l("No estimate: the brightness position isn’t known")
        }
    }

    /// The report section: every anchor (HDR ones when `includeHDR`), the reported minimum black,
    /// the estimate at `brightnessPosition` when one is given, and what all of it does and doesn't mean.
    public static func section(settings: LuminanceAnchorSettings?, reported: ReportedLuminance,
                               includeHDR: Bool, brightnessPosition: Double?,
                               estimateNote: String? = nil,
                               _ l: ReportLocalizer = .english) -> InfoReport.Section {
        var section = InfoReport.Section(title: l("Luminance"))
        let entries = LuminanceAnchorResolver.resolveAll(settings, reported: reported)
        let manualOn = (settings ?? LuminanceAnchorSettings()).manualValuesEnabled
        section.rows.append(.init(l("Entered values"), manualOn ? l("Used") : l("Off (kept, not used)")))
        for anchor in LuminanceAnchor.allCases where includeHDR || !anchor.isHDR {
            guard let entry = entries[anchor] else { continue }
            section.rows.append(.init(anchorName(anchor, l), entryText(entry, l)))
        }
        if let minimum = reported.minimum {
            section.rows.append(.init(l("Minimum (black) the EDID states"),
                                      l.fill("%1 — %2", l.fill("%1 nits", l.decimal(minimum.nits, 4)), sourceText(minimum.source, l))))
        }
        if let position = brightnessPosition {
            let estimate = LuminanceAnchorResolver.estimateNits(atPosition: position, anchors: entries)
            section.rows.append(.init(l.fill("At the current brightness (%1%)", l.decimal(position * 100, 0)),
                                      estimateText(estimate, l)))
        } else if let estimateNote {
            section.rows.append(.init(l("At the current brightness"), estimateNote))
        }
        section.notes = [
            l("FreeDisplay doesn’t measure light. These are values you entered or the display’s EDID states; nits (cd/m²) shown for a brightness position are calculated from them, assuming light changes linearly between the SDR minimum and maximum."),
            l("Changing a value changes labels and estimates only. It doesn’t change the display, turn on HDR or raise what the panel can do."),
        ]
        if brightnessPosition != nil {
            section.notes.append(l("The estimate covers the brightness control alone: software dimming, colour temperature and contrast aren’t included."))
        }
        return section
    }
}
