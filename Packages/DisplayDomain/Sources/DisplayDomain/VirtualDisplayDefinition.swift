import Foundation

/// Explicit user-created definition. Physical pixel dimensions; HiDPI halves logical size.
public struct VirtualDisplayDefinition: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var pixelWidth: UInt32
    public var pixelHeight: UInt32
    public var refreshRate: Double
    public var hiDPI: Bool

    public init(id: UUID = UUID(), name: String, pixelWidth: UInt32 = 1920,
                pixelHeight: UInt32 = 1080, refreshRate: Double = 60, hiDPI: Bool = false) {
        self.id = id; self.name = name; self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight; self.refreshRate = refreshRate; self.hiDPI = hiDPI
    }

    public var validationError: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.utf8.count > 128 || name.contains("\0") {
            return "Enter a display name of 1–128 bytes with no null characters."
        }
        if !(640...8192).contains(pixelWidth) || !(480...8192).contains(pixelHeight) {
            return "Dimensions must be between 640 × 480 and 8192 × 8192 pixels."
        }
        if !refreshRate.isFinite || !(24...120).contains(refreshRate) {
            return "The refresh rate must be between 24 and 120 Hz."
        }
        if hiDPI && (pixelWidth % 2 != 0 || pixelHeight % 2 != 0) {
            return "For HiDPI, the pixel width and height must be even."
        }
        return nil
    }
}
