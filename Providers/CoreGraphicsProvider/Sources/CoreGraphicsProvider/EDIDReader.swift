#if os(macOS)
import CoreGraphics
import DisplayDomain
import Foundation
import IOKit

/// Reads the raw EDID blob for a display from IORegistry (public IOKit — no private SPI). On Apple
/// Silicon the EDID lives on display nodes under the DCP; we collect every EDID-shaped property and
/// bind one to the requested display through `EDIDBinding`: the blob must carry the display's own
/// vendor, product code and serial as Core Graphics reports them, and must be the only one that
/// does. The registry walk can't say which node belongs to which display, so anything short of
/// that is reported as such — never answered with whichever blob came first, which for identical
/// monitors or an unexposed EDID is another display's bytes.
public enum EDIDReader {
    /// The binding outcome for `cgID`: its bytes, or why there is no single blob to call its own.
    public static func lookup(for cgID: CGDirectDisplayID) -> EDIDBinding.Outcome {
        let target = EDIDBinding.Target(vendorNumber: CGDisplayVendorNumber(cgID),
                                        modelNumber: CGDisplayModelNumber(cgID),
                                        serialNumber: CGDisplaySerialNumber(cgID))
        return EDIDBinding.bind(allEDIDs(), to: target)
    }

    /// The raw EDID bytes for `cgID` when exactly one exposed blob is unambiguously its own.
    public static func rawEDID(for cgID: CGDirectDisplayID) -> [UInt8]? {
        if case .matched(let bytes) = lookup(for: cgID) { return bytes }
        return nil
    }

    /// Every EDID-shaped Data property found by walking the whole IORegistry service plane (the EDID
    /// node's class varies across Apple-Silicon macOS versions, so a recursive walk is more robust than
    /// guessing service classes), deduplicated in tree order.
    private static func allEDIDs() -> [[UInt8]] {
        var iter = io_iterator_t()
        guard IORegistryCreateIterator(
            kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iter
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }
        var seen: Set<[UInt8]> = []
        var result: [[UInt8]] = []
        var entry = IOIteratorNext(iter)
        while entry != 0 {
            if let edid = edidProperty(entry), !seen.contains(edid) {
                seen.insert(edid); result.append(edid)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iter)
        }
        return result
    }

    private static func edidProperty(_ entry: io_registry_entry_t) -> [UInt8]? {
        for key in ["EDID", "IODisplayEDID"] {
            guard let prop = IORegistryEntryCreateCFProperty(
                entry, key as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() else { continue }
            if let data = prop as? Data, data.count >= 128 { return [UInt8](data) }
        }
        return nil
    }
}
#endif
