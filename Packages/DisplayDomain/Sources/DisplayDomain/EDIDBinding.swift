import Foundation

/// Decides which raw EDID blob, if any, is *this* display's — the step between "IORegistry holds
/// some EDIDs" and "here are the bytes of the monitor you asked about".
///
/// The registry walk that finds EDIDs can't say which display each one belongs to, so the binding
/// rests on the identity Core Graphics reports for the display (`CGDisplayVendorNumber`,
/// `CGDisplayModelNumber`, `CGDisplaySerialNumber`, all read from that display's own EDID) and the
/// same three fields inside each blob. Only a blob agreeing on all three is a candidate, and only a
/// single candidate is an answer: two same-model monitors without programmed serials, or a display
/// whose blob isn't exposed at all, get an explicit "can't tell" instead of whichever blob came
/// first. Byte-identical blobs are one candidate — the same EDID published on two nodes is still
/// the same answer. Pure, so `make test` covers it.
public enum EDIDBinding {
    /// The Core Graphics identity of the display the bytes are wanted for. 0 and 0xFFFFFFFF in
    /// vendor/model mean unknown; a serial of 0 means "not programmed", and is matched as such.
    public struct Target: Hashable, Sendable {
        public var vendorNumber: UInt32
        public var modelNumber: UInt32
        public var serialNumber: UInt32

        public init(vendorNumber: UInt32, modelNumber: UInt32, serialNumber: UInt32) {
            self.vendorNumber = vendorNumber
            self.modelNumber = modelNumber
            self.serialNumber = serialNumber
        }
    }

    public enum Outcome: Hashable, Sendable {
        /// Exactly one blob carries the display's vendor, model and serial.
        case matched([UInt8])
        /// Several different blobs carry the same vendor, model and serial — typically identical
        /// monitors with unprogrammed serials. Returning any of them could be another monitor's.
        case ambiguous(candidates: Int)
        /// No blob carries this display's identity (it isn't exposed, or only other displays' are).
        case notFound
        /// Core Graphics doesn't know the display's vendor or model, so no blob can be tied to it.
        case unidentifiedTarget
    }

    public static func bind(_ blobs: [[UInt8]], to target: Target) -> Outcome {
        func known(_ value: UInt32) -> Bool { value != 0 && value != 0xFFFF_FFFF }
        guard known(target.vendorNumber), known(target.modelNumber) else { return .unidentifiedTarget }
        var seen: Set<[UInt8]> = []
        var matches: [[UInt8]] = []
        for blob in blobs where seen.insert(blob).inserted {
            guard let identity = identity(of: blob),
                  identity.vendor == target.vendorNumber,
                  identity.model == target.modelNumber,
                  identity.serial == target.serialNumber
            else { continue }
            matches.append(blob)
        }
        switch matches.count {
        case 0: return .notFound
        case 1: return .matched(matches[0])
        default: return .ambiguous(candidates: matches.count)
        }
    }

    /// The identity fields of a well-formed base block, in the encodings Core Graphics reports:
    /// the big-endian manufacturer word (bytes 8–9), the little-endian product code (10–11) and
    /// the little-endian numeric serial (12–15). Nil when the block doesn't parse.
    private static func identity(of blob: [UInt8]) -> (vendor: UInt32, model: UInt32, serial: UInt32)? {
        guard let edid = EDID.parse(blob) else { return nil }
        let vendor = (UInt32(blob[8]) << 8) | UInt32(blob[9])
        return (vendor, UInt32(edid.productCode), edid.serialNumber)
    }
}
