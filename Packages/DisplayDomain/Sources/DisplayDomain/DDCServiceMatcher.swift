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
    public static func score(_ candidate: Candidate, against target: Target) -> Int {
        var total = 0
        let candidateVendor = candidate.legacyManufacturerID
            ?? candidate.manufacturerID.flatMap(vendorNumber(fromPNP:))
        if let vendor = candidateVendor, vendor != 0, vendor == target.vendorNumber { total += 1 }
        if let product = candidate.productID, product != 0, product == target.productNumber { total += 2 }
        if let serial = candidate.serialNumber, serial != 0, serial == target.serialNumber { total += 4 }
        return total
    }

    /// Which service to bind for a display — or why none may be bound.
    public enum Resolution: Equatable, Sendable {
        /// One candidate matches the display's identity strictly better than every other.
        case matched(index: Int)
        /// The only AV service on the Mac, for the only external display that could own one. Nothing
        /// identifies it (e.g. a TV or adapter that strips the identity attributes), but there is no
        /// other monitor a command could reach by mistake.
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
    ///
    /// A unique highest positive score wins — unless another external reports exactly the same
    /// identity as `target`: then a match proves only the model, not which of the twins owns the
    /// service (identical monitors where IOKit labels one service and strips the other would
    /// otherwise both bind to the labelled one). A tie for the best score is refused for the same
    /// reason. Nothing scoring is refused too, except for the single-monitor setup — exactly one
    /// service and exactly one external — where the service can't belong to anything else.
    public static func resolve(_ candidates: [Candidate?], against target: Target,
                               among externals: [Target]) -> Resolution {
        guard !candidates.isEmpty else { return .none }
        let scores = candidates.map { $0.map { score($0, against: target) } ?? 0 }
        let best = scores.max() ?? 0
        if best > 0 {
            if externals.filter({ $0 == target }).count > 1 { return .refused(.ambiguousIdentity) }
            let winners = scores.indices.filter { scores[$0] == best }
            return winners.count == 1 ? .matched(index: winners[0]) : .refused(.ambiguousIdentity)
        }
        if candidates.count == 1, externals.count <= 1 { return .sole(index: 0) }
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
