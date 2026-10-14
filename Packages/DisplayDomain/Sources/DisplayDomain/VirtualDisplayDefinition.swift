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
            return "Введите название экрана длиной 1–128 байт без нулевых символов."
        }
        if !(640...8192).contains(pixelWidth) || !(480...8192).contains(pixelHeight) {
            return "Размеры должны быть от 640 × 480 до 8192 × 8192 пикселей."
        }
        if !refreshRate.isFinite || !(24...120).contains(refreshRate) {
            return "Частота обновления должна быть от 24 до 120 Гц."
        }
        if hiDPI && (pixelWidth % 2 != 0 || pixelHeight % 2 != 0) {
            return "Для HiDPI ширина и высота в пикселях должны быть чётными."
        }
        return nil
    }
}
