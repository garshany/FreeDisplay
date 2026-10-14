#if os(macOS)
import CoreImage

/// The preview transform path, also exercised with generated pixels without screen access.
public enum CaptureImageTransform {
    public static func apply(to input: CIImage, crop: Double, flip: Bool, angle: Int, lut: CubeLUT?) -> CIImage {
        var image = input
        let fraction = crop.isFinite ? min(0.4, max(0, crop)) : 0
        if fraction > 0 {
            image = image.cropped(to: image.extent.insetBy(dx: image.extent.width * fraction, dy: image.extent.height * fraction))
        }
        if flip { image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1)) }
        let rotation: CGAffineTransform
        switch ((angle % 360) + 360) % 360 {
        case 90: rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
        case 180: rotation = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        case 270: rotation = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
        case 0: rotation = .identity
        default: rotation = CGAffineTransform(rotationAngle: CGFloat(angle % 360) * .pi / 180)
        }
        if !rotation.isIdentity { image = image.transformed(by: rotation) }
        if let lut {
            image = image.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": lut.dimension, "inputCubeData": lut.rgba])
        }
        return image
    }
}
#endif
