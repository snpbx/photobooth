import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The operator's own artwork for the print footer.
///
/// The chosen file is **copied** into Application Support rather than referenced
/// where it was found. A booth runs for a whole evening off a laptop whose
/// Desktop gets tidied and whose USB sticks get pulled; a settings file pointing
/// at `~/Downloads/logo-final-v3.png` is a print that silently loses its footer
/// three hours in. Once imported, the artwork travels with the settings.
///
/// Everything is normalised to PNG on the way in, whatever was handed over, so
/// transparency survives and the renderer only ever has one format to read.
enum BrandingAssets {

    enum BrandingError: LocalizedError {
        case unreadable
        case tooLarge(Int)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable:        return "That file could not be read as an image."
            case .tooLarge(let mb):  return "That image is \(mb) MB. Choose something under 40 MB."
            case .writeFailed(let m): return "Could not save the image: \(m)"
            }
        }
    }

    /// Anything wider than this is more resolution than a two-inch strip can
    /// print, and every extra pixel is carried through every render.
    static let maxLongEdge = 2400
    static let maxInputBytes = 40 * 1024 * 1024

    static var directory: URL {
        let d = SettingsService.supportDirectory.appendingPathComponent("Branding", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Resolves a stored file name. Returns nil for an empty name or a file that
    /// has since gone, so a missing asset prints as no footer image rather than
    /// failing the whole sheet.
    static func url(for fileName: String) -> URL? {
        let name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        // Only ever a bare file name inside our own folder — never a path out of it.
        guard !name.contains("/"), name != "..", !name.hasPrefix(".") else { return nil }
        let u = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Copies an image in, converting to PNG and shrinking it if need be.
    /// Returns the stored file name to put in settings.
    @discardableResult
    static func importImage(from source: URL) throws -> String {
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxInputBytes else { throw BrandingError.tooLarge(size / 1024 / 1024) }

        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(src) > 0,
              let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw BrandingError.unreadable }

        let prepared = downscale(image, longEdge: maxLongEdge) ?? image

        // A fresh name every import: the delivery of a print is cached by
        // whatever last read the file, and reusing one name means a replaced
        // logo can come back as the old one.
        let name = "footer-\(UInt32.random(in: 0..<UInt32.max)).png"
        let dest = directory.appendingPathComponent(name)

        guard let out = CGImageDestinationCreateWithURL(dest as CFURL,
                                                        UTType.png.identifier as CFString, 1, nil)
        else { throw BrandingError.writeFailed("could not create \(name)") }
        CGImageDestinationAddImage(out, prepared, nil)
        guard CGImageDestinationFinalize(out) else {
            throw BrandingError.writeFailed("could not write \(name)")
        }
        return name
    }

    /// Decoded once and kept. A template can carry a dozen stickers and the
    /// sheet is redrawn on every editor keystroke; decoding each PNG each time
    /// would make the editor feel like treacle.
    private static let cache = NSCache<NSString, CGImageBox>()
    private final class CGImageBox { let image: CGImage; init(_ i: CGImage) { image = i } }

    static func loadCGImage(_ fileName: String) -> CGImage? {
        if let hit = cache.object(forKey: fileName as NSString) { return hit.image }
        guard let u = url(for: fileName),
              let src = CGImageSourceCreateWithURL(u as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        cache.setObject(CGImageBox(img), forKey: fileName as NSString)
        return img
    }

    static func remove(_ fileName: String) {
        guard let u = url(for: fileName) else { return }
        try? FileManager.default.removeItem(at: u)
    }

    private static func downscale(_ image: CGImage, longEdge: Int) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let scale = min(CGFloat(longEdge) / max(w, h), 1)
        guard scale < 1 else { return image }
        let nw = max(1, Int((w * scale).rounded())), nh = max(1, Int((h * scale).rounded()))
        // premultipliedLast, not noneSkipLast: a logo is usually a shape on
        // nothing, and flattening its transparency onto black would be the end
        // of it.
        guard let ctx = CGContext(data: nil, width: nw, height: nh,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage()
    }
}
