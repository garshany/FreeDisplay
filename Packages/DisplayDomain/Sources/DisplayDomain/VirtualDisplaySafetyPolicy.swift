/// Read-only public CoreGraphics facts used by the experimental session's safety guard.
/// A nonzero external vendor is a recovery-screen heuristic, not proof of physical hardware.
public struct VirtualDisplaySurface: Sendable, Hashable {
    public var displayID: UInt32
    public var vendorID: UInt32
    public var isBuiltIn: Bool
    public var mirroredSourceID: UInt32
    public init(displayID: UInt32, vendorID: UInt32, isBuiltIn: Bool = false,
                mirroredSourceID: UInt32 = 0) {
        self.displayID = displayID; self.vendorID = vendorID
        self.isBuiltIn = isBuiltIn; self.mirroredSourceID = mirroredSourceID
    }
}

/// Callers must supply only currently active surfaces, never remembered/disconnected records.
public enum VirtualDisplaySafetyPolicy {
    public static let providerVendorID: UInt32 = 0x4f44
    public static func canCreate(activeSurfaces: [VirtualDisplaySurface]) -> Bool {
        activeSurfaces.contains {
            $0.isBuiltIn || ($0.vendorID != 0 && $0.vendorID != providerVendorID)
        }
    }
    public static func canRemove(displayID: UInt32, activeSurfaces: [VirtualDisplaySurface]) -> Bool {
        activeSurfaces.contains { $0.displayID != displayID && $0.mirroredSourceID != displayID }
    }
}
