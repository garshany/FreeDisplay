#if os(macOS)
import CoreGraphics
import DisplayDomain
import Foundation
import IOKit

/// The public facts `PhysicalPresenceClassifier` decides from: each online display's Core Graphics
/// identity, and the display-hardware nodes IORegistry publishes for panels the Mac is driving.
///
/// On Apple silicon every display the display pipe drives — the built-in panel and each external —
/// has a framebuffer node carrying `DisplayAttributes`, whose `ProductAttributes` hold the EDID
/// identity (the same fields DDC matching reads). A window-server-only screen — a CGVirtualDisplay
/// from this or any other app, DisplayLink's and Sidecar's screens — has none. Public IOKit and
/// Core Graphics reads only.
public enum DisplayHardwareEvidence {
    /// The presence verdict for every display in `ids`, from one IORegistry query.
    public static func physicalPresence(of ids: [CGDirectDisplayID]) -> [CGDirectDisplayID: PhysicalPresence] {
        PhysicalPresenceClassifier.classify(ids.map(facts(for:)), hardware: connectedDisplayHardware())
    }

    /// The Core Graphics half of the evidence for one display.
    static func facts(for id: CGDirectDisplayID) -> PhysicalPresenceClassifier.Display {
        let isBuiltIn = CGDisplayIsBuiltin(id) != 0
        let vendor = CGDisplayVendorNumber(id)
        let model = CGDisplayModelNumber(id)
        // macOS's synthetic stand-in for "no displays at all" must never read as a screen.
        let isPlaceholder = !isBuiltIn && DisplayActivity.isVirtualPlaceholder(
            vendorNumber: vendor, modelNumber: model,
            modeCount: (CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode])?.count ?? 0)
        return PhysicalPresenceClassifier.Display(
            id: id, isBuiltIn: isBuiltIn, isSystemPlaceholder: isPlaceholder,
            vendorNumber: vendor, modelNumber: model, serialNumber: CGDisplaySerialNumber(id))
    }

    /// Every IORegistry service that carries `DisplayAttributes`, reduced to its product identity.
    /// Framebuffers without a panel attached were seen to carry no such property, so this is the
    /// set of displays the hardware is driving; a node left over from a display that is logically
    /// disabled only adds spare evidence for that display's own identity. A node without
    /// `ProductAttributes` (an EDID-less panel) is kept as an anonymous node: it can vouch only for
    /// a display whose own identity is unknown too. A registry that changes mid-query can cut the
    /// list short; that only makes this snapshot more cautious, and the next one re-reads it.
    static func connectedDisplayHardware() -> [PhysicalPresenceClassifier.HardwareNode] {
        let matching = ["IOPropertyExistsMatch": "DisplayAttributes"] as CFDictionary
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var nodes: [PhysicalPresenceClassifier.HardwareNode] = []
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let raw = IORegistryEntryCreateCFProperty(
                entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let attributes = raw as? [String: Any] {
                let product = attributes["ProductAttributes"] as? [String: Any] ?? [:]
                nodes.append(PhysicalPresenceClassifier.HardwareNode(
                    legacyManufacturerID: product["LegacyManufacturerID"] as? Int,
                    manufacturerID: product["ManufacturerID"] as? String,
                    productID: product["ProductID"] as? Int,
                    serialNumber: product["SerialNumber"] as? Int))
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return nodes
    }
}
#endif
