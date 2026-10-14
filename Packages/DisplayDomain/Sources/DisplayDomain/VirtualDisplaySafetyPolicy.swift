/// Read-only public CoreGraphics facts used by the experimental session's safety guard.
/// `physicalPresence` is the shared classification (`PhysicalPresenceClassifier`) when the caller
/// could compute it; without it, a nonzero external vendor is a recovery-screen heuristic, not proof
/// of physical hardware.
public struct VirtualDisplaySurface: Sendable, Hashable {
    public var displayID: UInt32
    public var vendorID: UInt32
    public var isBuiltIn: Bool
    public var mirroredSourceID: UInt32
    public var physicalPresence: PhysicalPresence?
    public init(displayID: UInt32, vendorID: UInt32, isBuiltIn: Bool = false,
                mirroredSourceID: UInt32 = 0, physicalPresence: PhysicalPresence? = nil) {
        self.displayID = displayID; self.vendorID = vendorID
        self.isBuiltIn = isBuiltIn; self.mirroredSourceID = mirroredSourceID
        self.physicalPresence = physicalPresence
    }
}

/// Callers must supply only currently active surfaces, never remembered/disconnected records.
public enum VirtualDisplaySafetyPolicy {
    public static let providerVendorID: UInt32 = 0x4f44
    /// A new virtual endpoint needs a physical screen to stay visible beside it. When presence was
    /// assessed it decides, exactly as it does for lifecycle preflight — a third-party virtual
    /// screen, DisplayLink or Sidecar doesn't qualify; only the vendor heuristic remains for
    /// callers that couldn't classify.
    public static func canCreate(activeSurfaces: [VirtualDisplaySurface]) -> Bool {
        activeSurfaces.contains { surface in
            if let presence = surface.physicalPresence { return presence == .physical }
            return surface.isBuiltIn || (surface.vendorID != 0 && surface.vendorID != providerVendorID)
        }
    }
    public static func canRemove(displayID: UInt32, activeSurfaces: [VirtualDisplaySurface]) -> Bool {
        activeSurfaces.contains { $0.displayID != displayID && $0.mirroredSourceID != displayID }
    }
}
