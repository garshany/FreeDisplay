import Foundation
import CoreImage

@main
struct CaptureTransformChecks {
    static func main() throws {
        let colors: [UInt8] = [
            255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,0,255,
            0,255,255,255, 255,0,255,255, 64,64,64,255, 255,255,255,255
        ]
        let input = CIImage(bitmapData: Data(colors), bytesPerRow: 16, size: CGSize(width: 4, height: 2), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let context = CIContext(options: [.useSoftwareRenderer: true, .workingColorSpace: CGColorSpaceCreateDeviceRGB()])
        func render(_ image: CIImage) -> [UInt8] {
            var result = [UInt8](repeating: 0, count: Int(image.extent.width.rounded()) * Int(image.extent.height.rounded()) * 4)
            result.withUnsafeMutableBytes { raw in
                context.render(image, toBitmap: raw.baseAddress!, rowBytes: Int(image.extent.width.rounded()) * 4, bounds: image.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            }
            return result
        }
        let base = render(input)
        precondition(base.contains(255), "Core Image returned no pixels; rendering environment is unavailable")
        let identity = CaptureImageTransform.apply(to: input, crop: 0, flip: false, angle: 0, lut: nil)
        precondition(render(identity) == base)
        let flipped = CaptureImageTransform.apply(to: input, crop: 0, flip: true, angle: 0, lut: nil)
        let flippedBytes = render(flipped)
        precondition(Array(flippedBytes.prefix(4)) == Array(base[12..<16]), "horizontal flip pixel ordering")
        let twice = CaptureImageTransform.apply(to: flipped, crop: 0, flip: true, angle: 0, lut: nil)
        precondition(render(twice) == base)
        for angle in [90, 180, 270] {
            let rotated = CaptureImageTransform.apply(to: input, crop: 0, flip: false, angle: angle, lut: nil)
            let expected = angle == 180 ? CGSize(width: 4, height: 2) : CGSize(width: 2, height: 4)
            precondition(abs(rotated.extent.width - expected.width) < 0.0001 && abs(rotated.extent.height - expected.height) < 0.0001)
            let restored = CaptureImageTransform.apply(to: rotated, crop: 0, flip: false, angle: 360 - angle, lut: nil)
            let restoredBytes = render(restored)
            
            precondition(zip(restoredBytes, base).allSatisfy { abs(Int($0) - Int($1)) <= 2 }, "rotation round trip")
        }
        let geometry = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 20))
        let cropped = CaptureImageTransform.apply(to: geometry, crop: 0.25, flip: false, angle: 0, lut: nil)
        precondition(cropped.extent == CGRect(x: 10, y: 5, width: 20, height: 10))
        let clamped = CaptureImageTransform.apply(to: geometry, crop: 1, flip: false, angle: 0, lut: nil)
        precondition(abs(clamped.extent.width - 8) < 0.0001)
        let invalid = CaptureImageTransform.apply(to: input, crop: .nan, flip: false, angle: 0, lut: nil)
        precondition(invalid.extent == input.extent)
        let lutText = "LUT_3D_SIZE 2\n" + ["0 0 0", "1 0 0", "0 1 0", "1 1 0", "0 0 1", "1 0 1", "0 1 1", "1 1 1"].joined(separator: "\n")
        let lut = try CubeLUT(text: lutText)
        let lutBytes = render(CaptureImageTransform.apply(to: input, crop: 0, flip: false, angle: 0, lut: lut))
        precondition(zip(lutBytes, base).allSatisfy { abs(Int($0) - Int($1)) <= 2 }, "identity LUT rendered pixels")
        let invert = try CubeLUT(text: "LUT_3D_SIZE 2\n" + ["1 1 1", "0 1 1", "1 0 1", "0 0 1", "1 1 0", "0 1 0", "1 0 0", "0 0 0"].joined(separator: "\n"))
        let inverted = render(CaptureImageTransform.apply(to: input, crop: 0, flip: false, angle: 0, lut: invert))
        precondition(inverted[0] <= 2 && inverted[1] >= 253 && inverted[2] >= 253, "inversion LUT red to cyan")
        print("CaptureTransform: synthetic identity, flip/reversal, 90/180/270 rotations, crop bounds/clamp/NaN, identity and inversion LUT pixels passed")
    }
}
