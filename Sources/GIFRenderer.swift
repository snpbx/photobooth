import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Builds the animated loop a guest takes away alongside the print.
///
/// Every photograph of the session in turn, each one filling a page dressed in
/// the sheet's own branding — the same background, border, footer and logos, so
/// the loop plainly came from the same booth as the print in their hand.
///
/// A whole page rather than the printed strip: the print is the same picture
/// twice, or six small ones, and at the size a GIF is watched on a phone that
/// leaves every face the size of a thumbnail.
///
/// It is built from the photographs themselves rather than from the live view.
/// Stills are what a session always has — whatever the camera was doing between
/// shots, and whether or not live view was even running — so the loop is never
/// the thing that fails.
///
/// GIF is the format on purpose rather than by nostalgia: it is the only moving
/// image that plays by itself in a text message, in Messages, WhatsApp and
/// Instagram alike, with nobody pressing anything. What follows is size
/// discipline — 256 colours and every frame stored whole, so frame count and
/// pixels are the entire cost, and this loop holds one frame per photograph.
enum GIFRenderer {

    enum GIFError: LocalizedError {
        case noPhotos
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .noPhotos:     return "The session has no photographs to animate."
            case .encodeFailed: return "Could not encode the GIF."
            }
        }
    }

    /// Master switch. Everything the GIF touches is gated on this — building it,
    /// the finish screen, the operator's gallery, the session page, the album and
    /// the uploads — so the feature is never half-present.
    static let enabled = true

    static let fileName = "session.gif"

    /// How long one photograph is held, in seconds. Clamped rather than trusted:
    /// a settings file asking for thirty would hand the guest a loop nobody
    /// watches to the end.
    static let minSeconds: Double = 0.3
    static let maxSeconds: Double = 3

    // MARK: - Geometry

    private static func clampedLongEdge(_ s: AppSettings) -> Int {
        max(200, min(s.gifLongEdge, 1000))
    }

    /// The loop's frame: the photograph's own shape at the chosen long edge.
    ///
    /// There is nothing else in the frame, so there is nothing else to size it
    /// around — no margin, no footer band, no sheet. A 3:2 photograph makes a
    /// 3:2 loop.
    static func canvasSize(settings: AppSettings, photoAspect: CGFloat = 1.5) -> CGSize {
        let long = CGFloat(clampedLongEdge(settings))
        let aspect = max(0.2, min(photoAspect, 5))
        return aspect >= 1
            ? CGSize(width: long.rounded(), height: (long / aspect).rounded())
            : CGSize(width: (long * aspect).rounded(), height: long.rounded())
    }

    /// The camera's own shape, from the first photograph that will go in.
    private static func aspect(of stills: [URL]) -> CGFloat {
        for url in stills {
            if let img = LayoutRenderer.loadOrientedImage(at: url), img.height > 0 {
                return CGFloat(img.width) / CGFloat(img.height)
            }
        }
        return 1.5
    }

    // MARK: - Rendering

    /// Builds the take-away loop: every photograph of the session in turn, each
    /// one filling a page in the sheet's own branding.
    ///
    /// The photographs are what a guest wants to send on — not the seconds
    /// before them — and stills are what a session always has, whether or not
    /// live view was running when the shutter fired.
    ///
    /// **The photographs and nothing else.** The loop was composed like the
    /// sheet for a while: the background, the border, the operator's logos. But
    /// the branding is already on the strip in their hand, and on a phone a
    /// frame of logo around a small picture is simply a smaller picture. The
    /// sheet's layout therefore has no bearing on this at all, which is why
    /// neither it nor the template is asked for any more.
    ///
    /// Runs off the main thread.
    static func renderSlideshow(stills: [URL], settings: AppSettings) throws -> Data {
        guard !stills.isEmpty else { throw GIFError.noPhotos }

        let canvas = canvasSize(settings: settings, photoAspect: aspect(of: stills))
        let hold = min(max(settings.gifSeconds, minSeconds), maxSeconds)
        // GIF stores delay on a hundredth-of-a-second grid; rounding here rather
        // than letting the encoder do it keeps the loop running at the length
        // the operator asked for.
        let delay = max(0.02, (hold * 100).rounded() / 100)

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData,
                                                          UTType.gif.identifier as CFString,
                                                          stills.count, nil)
        else { throw GIFError.encodeFailed }

        // 0 = loop forever. A photobooth GIF that stops after one pass looks broken.
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)

        let frameProps = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                // Some players honour only the unclamped value, others only the
                // clamped one. Writing both is the difference between a loop that
                // runs at the intended speed everywhere and one that races in Safari.
                kCGImagePropertyGIFUnclampedDelayTime: delay
            ]
        ] as CFDictionary

        var written = 0
        for url in stills {
            guard let photo = LayoutRenderer.loadOrientedImage(at: url),
                  let frame = LayoutRenderer.scaled(photo, to: canvas) else { continue }
            CGImageDestinationAddImage(dest, frame, frameProps)
            written += 1
        }
        guard written > 0 else { throw GIFError.noPhotos }
        guard CGImageDestinationFinalize(dest) else { throw GIFError.encodeFailed }
        return out as Data
    }

}
