import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// QR codes for the "scan to get your photos" card.
///
/// Uses CoreImage's own generator rather than a third-party encoder, so there is
/// nothing extra to bundle or licence. The generator emits one pixel per module,
/// which is then scaled up with nearest-neighbour sampling — smoothing a QR code
/// is what makes phone cameras fail to read it.
enum QRCode {

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// - Parameter minimumSide: the shortest side, in pixels, the result should
    ///   reach. The module size is rounded up so the code stays crisp.
    static func image(for string: String,
                      minimumSide: CGFloat,
                      dark: CIColor = CIColor(red: 0, green: 0, blue: 0),
                      light: CIColor = CIColor(red: 1, green: 1, blue: 1)) -> NSImage? {
        guard let cg = cgImage(for: string, minimumSide: minimumSide, dark: dark, light: light) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    static func cgImage(for string: String,
                        minimumSide: CGFloat,
                        dark: CIColor = CIColor(red: 0, green: 0, blue: 0),
                        light: CIColor = CIColor(red: 1, green: 1, blue: 1)) -> CGImage? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let payload = trimmed.data(using: .utf8) else { return nil }

        let gen = CIFilter.qrCodeGenerator()
        gen.message = payload
        // Medium recovery: enough to survive a phone screen's glare and a print's
        // dot gain without inflating the module count and shrinking each module.
        gen.correctionLevel = "M"
        guard let raw = gen.outputImage else { return nil }

        let tint = CIFilter.falseColor()
        tint.inputImage = raw
        tint.color0 = dark
        tint.color1 = light
        guard let coloured = tint.outputImage else { return nil }

        let modules = max(raw.extent.width, 1)
        let scale = max(1, ceil(minimumSide / modules))
        let scaled = coloured
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        return context.createCGImage(scaled, from: scaled.extent)
    }
}
