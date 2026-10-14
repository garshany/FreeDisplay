import Foundation

@main
struct CubeLUTChecks {
    static func main() throws {
        let identity = "LUT_3D_SIZE 2\n" + ["0 0 0", "1 0 0", "0 1 0", "1 1 0", "0 0 1", "1 0 1", "0 1 1", "1 1 1"].joined(separator: "\n")
        let lut = try CubeLUT(text: identity)
        precondition(lut.dimension == 2 && lut.rgba.count == 8 * 4 * 4)
        let floats = lut.rgba.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        precondition(Array(floats.prefix(8)) == [0, 0, 0, 1, 1, 0, 0, 1], "RGBA/red-fast ordering")
        _ = try CubeLUT(text: "TITLE \"Identity\"\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n# comment\n" + identity)
        for invalid in ["LUT_3D_SIZE 999", identity + "\n0 0 0", "LUT_3D_SIZE 2\n0 0 0", identity.replacingOccurrences(of: "1 1 1", with: "nan 1 1"), "DOMAIN_MIN -1 0 0\n" + identity, identity.replacingOccurrences(of: "1 1 1", with: "2 1 1"), "LUT_1D_SIZE 2\n0 0 0", "LUT_3D_SIZE 2\n" + identity] {
            do { _ = try CubeLUT(text: invalid); preconditionFailure("Invalid LUT accepted") }
            catch CubeLUT.ParseError.invalid { }
        }
        print("CubeLUT: identity ordering and 8 malformed/domain/size cases passed")
    }
}
