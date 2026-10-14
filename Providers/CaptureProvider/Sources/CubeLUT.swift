import Foundation

/// Strict, bounded 3D .cube reader. Red changes fastest, as required by CIColorCube.
public struct CubeLUT: Sendable {
    public let dimension: Int
    public let rgba: Data
    public enum ParseError: LocalizedError {
        case invalid(String)
        public var errorDescription: String? {
            switch self { case .invalid(let message): return message }
        }
    }

    public init(text: String) throws {
        guard text.utf8.count <= 16_000_000 else { throw ParseError.invalid("LUT exceeds 16 MB") }
        var size: Int?
        var values: [Float] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard let first = parts.first else { continue }
            switch first {
            case "TITLE": continue
            case "LUT_3D_SIZE":
                guard size == nil, parts.count == 2, let n = Int(parts[1]), (2...64).contains(n) else {
                    throw ParseError.invalid("Specify a single 3D LUT size from 2 to 64")
                }
                size = n
            case "DOMAIN_MIN", "DOMAIN_MAX":
                let expected: Float = first == "DOMAIN_MIN" ? 0 : 1
                guard parts.count == 4, parts.dropFirst().allSatisfy({ Float($0) == expected }) else {
                    throw ParseError.invalid("Only the standard 0…1 domain is supported")
                }
            default:
                guard size != nil, parts.count == 3 else { throw ParseError.invalid("Unsupported directive or missing size") }
                for part in parts {
                    guard let value = Float(part), value.isFinite, (0...1).contains(value) else {
                        throw ParseError.invalid("RGB values must be finite numbers from 0 to 1")
                    }
                    values.append(value)
                }
                values.append(1)
                guard values.count <= 64 * 64 * 64 * 4 else { throw ParseError.invalid("Too many samples") }
            }
        }
        guard let n = size, values.count == n * n * n * 4 else { throw ParseError.invalid("Wrong number of samples") }
        dimension = n
        rgba = values.withUnsafeBytes { Data($0) }
    }
}
