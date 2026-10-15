import Foundation

/// Pure scoring that pairs a display with its DDC I2C service when a Mac drives several externals.
///
/// On Apple Silicon each external display exposes one `DCPAVServiceProxy` (the I2C channel DDC/CI
/// runs over), and the display node next to it (`AppleCLCD2`) carries the panel's EDID-derived
/// `ProductAttributes` (manufacturer, product id, serial). Matching the CG display to a service *by
/// enumeration order* silently controls the wrong monitor whenever IOKit and Core Graphics disagree
/// on ordering (dock re-plugs, mixed HDMI/DP, identical models) — so we score every candidate
/// against the CG display's vendor/product/serial and bind only a candidate the evidence singles
/// out. Order is never used as a tie-breaker: a guess that is wrong sends brightness, input or
/// power commands to a different monitor, which is worse than offering no hardware control.
public enum DDCServiceMatcher {
    /// The identity attributes an IORegistry display-service candidate advertises
    /// (`DisplayAttributes` → `ProductAttributes` on the AppleCLCD2 node). All optional: real-world
    /// registries omit any of these, and a candidate with none simply scores zero.
    public struct Candidate: Hashable, Sendable {
        /// Numeric EDID vendor id (`LegacyManufacturerID`), e.g. Samsung = 0x4C2D.
        public var legacyManufacturerID: Int?
        /// Three-letter PnP id (`ManufacturerID`), e.g. "SAM" — converted for scoring when the
        /// numeric field is missing.
        public var manufacturerID: String?
        /// EDID product code (`ProductID`).
        public var productID: Int?
        /// EDID numeric serial (`SerialNumber`). Zero means "not set" and never matches.
        public var serialNumber: Int?

        public init(legacyManufacturerID: Int? = nil, manufacturerID: String? = nil,
                    productID: Int? = nil, serialNumber: Int? = nil) {
            self.legacyManufacturerID = legacyManufacturerID
            self.manufacturerID = manufacturerID
            self.productID = productID
            self.serialNumber = serialNumber
        }
    }

    /// The CG-side identity of the display we want a service for (`CGDisplayVendorNumber` /
    /// `CGDisplayModelNumber` / `CGDisplaySerialNumber`). Zeros are treated as "unknown".
    public struct Target: Hashable, Sendable {
        public var vendorNumber: Int
        public var productNumber: Int
        public var serialNumber: Int

        public init(vendorNumber: Int, productNumber: Int, serialNumber: Int) {
            self.vendorNumber = vendorNumber
            self.productNumber = productNumber
            self.serialNumber = serialNumber
        }
    }

    /// EDID PnP id → numeric vendor: three letters A–Z packed as 5-bit values (A = 1) into a
    /// big-endian 16-bit word, e.g. "SAM" → 0x4C2D, "GSM" → 0x1E6D. Nil for anything that isn't
    /// exactly three ASCII letters — matching on a malformed id would be a false positive.
    public static func vendorNumber(fromPNP id: String) -> Int? {
        let letters = Array(id.uppercased().unicodeScalars)
        guard letters.count == 3, letters.allSatisfy({ (65...90).contains($0.value) }) else { return nil }
        return letters.reduce(0) { ($0 << 5) | (Int($1.value) - 64) }
    }

    /// Match strength of one candidate: serial (4) dominates product (2) dominates vendor (1), so a
    /// serial match can never be outvoted by the weaker signals — mirroring how EDID identity is
    /// trusted elsewhere (`IdentityScorer`). A field only scores when *both* sides know it and it's
    /// non-zero (CG reports 0 for unknown; EDID serials of 0 are "not programmed").
    ///
    /// The score only counts agreement; a field that *disagrees* is not a weaker match but proof of
    /// another monitor — see `contradicts`, which `resolve` applies before any score is compared.
    public static func score(_ candidate: Candidate, against target: Target) -> Int {
        var total = 0
        if let vendor = candidateVendor(candidate), vendor != 0, vendor == target.vendorNumber { total += 1 }
        if let product = candidate.productID, product != 0, product == target.productNumber { total += 2 }
        if let serial = serialWord(of: candidate), serial != 0, serial == serialWord(of: target) { total += 4 }
        return total
    }

    /// Whether a candidate positively names a *different* display than `target`: some identity field
    /// both sides know (non-zero) disagrees — another vendor, another product code, or the same model
    /// with another serial. Such a service can never be this display's, however well the remaining
    /// fields agree: two same-model monitors with different serials share vendor and product, and
    /// letting that partial agreement count would bind one monitor's I2C channel to the other.
    /// Missing fields never contradict — IOKit and CG both omit identity in the wild.
    public static func contradicts(_ candidate: Candidate, _ target: Target) -> Bool {
        if let vendor = candidateVendor(candidate), vendor != 0, target.vendorNumber != 0,
           vendor != target.vendorNumber { return true }
        if let product = candidate.productID, product != 0, target.productNumber != 0,
           product != target.productNumber { return true }
        let targetSerial = serialWord(of: target)
        if let serial = serialWord(of: candidate), serial != 0, targetSerial != 0, serial != targetSerial { return true }
        return false
    }

    /// The candidate's vendor: the numeric id, or the PnP string converted when that is missing.
    private static func candidateVendor(_ candidate: Candidate) -> Int? {
        candidate.legacyManufacturerID ?? candidate.manufacturerID.flatMap(vendorNumber(fromPNP:))
    }

    /// EDID serials are 32-bit words. CG hands them over unsigned, while a registry property can carry
    /// the same bits as a signed number — compared raw, one serial with its top bit set would look like
    /// two different monitors. Both sides are reduced to the 32-bit word before comparing.
    private static func serialWord(of candidate: Candidate) -> UInt32? {
        candidate.serialNumber.map { UInt32(truncatingIfNeeded: $0) }
    }

    private static func serialWord(of target: Target) -> UInt32 {
        UInt32(truncatingIfNeeded: target.serialNumber)
    }

    /// The score a candidate can claim for `target`, or nil when it names a different display.
    private static func compatibleScore(_ candidate: Candidate?, against target: Target) -> Int? {
        guard let candidate else { return 0 }
        return contradicts(candidate, target) ? nil : score(candidate, against: target)
    }

    /// Which service to bind for a display — or why none may be bound.
    public enum Resolution: Equatable, Sendable {
        /// One candidate matches the display's identity strictly better than every other, contradicts
        /// none of it, and no other external display claims that candidate as strongly.
        case matched(index: Int)
        /// The only AV service on the Mac, for the only external display that could own one. Nothing
        /// identifies it (e.g. a TV or adapter that strips the identity attributes), but there is no
        /// other monitor a command could reach by mistake. Never a service whose own identity names
        /// another monitor: that one belongs to a display Core Graphics isn't listing (one turned
        /// off in software, one still arriving) rather than to this one.
        case sole(index: Int)
        /// Several services (or several displays) are possible owners and identity can't tell them
        /// apart. Nothing must be written: any choice would be a guess.
        case refused(DDCBindingRefusal)
        /// No external AV service exists — the display has no DDC channel.
        case none
    }

    /// Decides which candidate (if any) to bind for `target`.
    ///
    /// - `externals`: the CG identities of every external display that could own a service,
    ///   including `target` itself (OpenDisplay's own virtual screens excluded by the caller).
    /// - `unobservedExternalCount`: managed-offline monitors missing from that enumeration. They
    ///   still own services, so even one rules out a one-service/one-display fallback.
    ///
    /// A candidate that contradicts `target` (`contradicts`) is out before anything is scored. Among
    /// the rest, a unique highest positive score wins — and only if the assignment is exclusive: no
    /// other external may claim that same service at least as strongly. Two same-model monitors and a
    /// service labelled with the model but not the serial match both of them equally, so binding it
    /// to either would be a guess; the same holds for identical twins that report exactly the same
    /// identity, where IOKit labels one service and strips the other. A tie for the best score is
    /// refused for the same reason. Nothing scoring is refused too, except for the single-monitor
    /// setup — exactly one service and exactly one external — where the service can't belong to
    /// anything else, unless its identity says it does.
    public static func resolve(_ candidates: [Candidate?], against target: Target,
                               among externals: [Target], unobservedExternalCount: Int = 0) -> Resolution {
        guard !candidates.isEmpty else { return .none }
        let scores = candidates.map { compatibleScore($0, against: target) }
        let best = scores.compactMap { $0 }.max() ?? 0
        if best > 0 {
            let winners = scores.indices.filter { scores[$0] == best }
            guard winners.count == 1 else { return .refused(.ambiguousIdentity) }
            // The other externals: everyone in `externals` except one entry for the target itself.
            var rivals = externals
            if let own = rivals.firstIndex(of: target) { rivals.remove(at: own) }
            let chosen = candidates[winners[0]]
            let contested = rivals.contains { rival in
                guard let claim = compatibleScore(chosen, against: rival) else { return false }
                return claim >= best
            }
            return contested ? .refused(.ambiguousIdentity) : .matched(index: winners[0])
        }
        if candidates.count == 1, externals.count <= 1, unobservedExternalCount == 0 {
            return scores[0] == nil ? .refused(.contradictingIdentity) : .sole(index: 0)
        }
        return .refused(.unidentified)
    }
}

/// Why OpenDisplay refuses to talk DDC/CI to a display. Every case means no command is sent.
public enum DDCBindingRefusal: Equatable, Sendable {
    /// Another connected monitor reports the same identity (typically the same model with no serial
    /// number), so the I2C service for this one can't be told apart from the other's.
    case ambiguousIdentity
    /// Several monitors could own the available I2C service(s) and none of them carries enough
    /// identity to pick the right one.
    case unidentified
    /// The only I2C service macOS reports carries another monitor's identity (vendor, model or
    /// serial) — it belongs to a display Core Graphics isn't listing, not to this one.
    case contradictingIdentity
    /// An Apple-made display (see `DDCEligibility`): generic DDC is withheld unless the user
    /// explicitly overrides it for this display.
    case appleDisplay
}

/// Which displays may receive generic DDC/CI at all (FB-08), before any service is bound.
///
/// Apple's own displays are controlled through DisplayServices, not DDC/CI, and some older Apple
/// models are reported to end up unable to wake (a black screen that persists) after receiving
/// generic DDC traffic. A failed native read must therefore not fall through to DDC probing:
/// every Apple-vendor display is excluded unless the user turned on the per-display override.
/// Gated on the vendor alone because no verified list of safe/unsafe Apple product codes exists here;
/// modern Apple displays don't implement DDC/CI, so excluding them costs nothing.
public enum DDCEligibility {
    /// EDID vendor number of Apple displays (PnP "APP").
    public static let appleVendorNumber = 0x0610

    /// Whether generic DDC/CI may be used for a display with this EDID vendor number.
    /// `appleOverride` is the user's explicit per-display opt-in for an Apple display.
    public static func allowsGenericDDC(vendorNumber: Int, appleOverride: Bool) -> Bool {
        vendorNumber != appleVendorNumber || appleOverride
    }

    /// True for Apple-vendor displays — the ones that need the override.
    public static func isAppleDisplay(vendorNumber: Int) -> Bool {
        vendorNumber == appleVendorNumber
    }
}
