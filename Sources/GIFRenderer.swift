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

    /// The settings the GIF is composed under: the print's geometry rescaled to
    /// the GIF's canvas, minus the QR code.
    ///
    /// The rescale is the part that matters. Margins, gutters and footer type
    /// are all specified in inches and turned into pixels through `dpi`, so
    /// handing 300 DPI settings to a 320px sheet draws a quarter-inch margin as
    /// a third of the page and sets the event name in letters wider than the
    /// sheet itself. Moving `dpi` to match the canvas keeps every proportion the
    /// print has — `schematic` does the same for the layout picker.
    ///
    /// The QR goes because it is unreadable at the size it would occupy here,
    /// and because hard black-and-white detail is the most expensive thing a
    /// 256-colour format can carry, repeated in every frame. Dropping it in the
    /// settings rather than at draw time keeps the footer band sized for what is
    /// actually in it, so the slots above stay where the print puts them.
    static func composeSettings(_ s: AppSettings) -> AppSettings {
        var g = s
        g.printQRCode = false
        // 6in is the long edge of the sheet.
        g.dpi = max(20, Int((Double(clampedLongEdge(s)) / 6.0).rounded()))
        return g
    }

    /// The loop's shape: **landscape**, because it carries one whole photograph
    /// rather than a sheet of them.
    ///
    /// It used to be the sheet's own 4×6, which made sense while the frame was
    /// composed like a page — but a 3:2 photograph in a portrait page is either
    /// cropped to a third of its width or floated in a sea of background. On a
    /// 6×4 the camera's picture very nearly fills the frame.
    static func canvasSize(settings: AppSettings,
                           photoAspect: CGFloat = 1.5,
                           hasArtwork: Bool = false) -> CGSize {
        let w = CGFloat(clampedLongEdge(settings))
        // Never taller than wide: a portrait photograph is letterboxed rather
        // than turning the loop on its end.
        let aspect = max(1, photoAspect)
        let inset = w * LayoutRenderer.frameInset
        let picture = w - inset * 2
        let height = (picture / aspect + inset * 2)
            / (hasArtwork ? (1 - LayoutRenderer.artworkBand) : 1)
        return CGSize(width: w.rounded(), height: height.rounded())
    }

    /// The camera's own shape, from the first photograph that will go in.
    ///
    /// Taken from the pictures rather than assumed: a 6D gives 3:2, a webcam
    /// 16:9, and a frame built for the wrong one puts the guests in a letterbox
    /// of brand colour for the whole loop.
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
    /// live view was running when the shutter fired. Each frame is a whole page
    /// rather than the printed strip because a six-up strip at phone size leaves
    /// every face the size of a thumbnail.
    ///
    /// Runs off the main thread.
    static func renderSlideshow(stills: [URL],
                                layout: PrintLayout,
                                settings: AppSettings,
                                template: PrintTemplate?) throws -> Data {
        guard !stills.isEmpty else { throw GIFError.noPhotos }

        let g = composeSettings(settings)
        let marked = !(template?.overlays.filter { !$0.file.isEmpty }.isEmpty ?? true)
        let canvas = canvasSize(settings: settings,
                                photoAspect: aspect(of: stills),
                                hasArtwork: marked)
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
            guard let photo = LayoutRenderer.loadOrientedImage(at: url) else { continue }
            let page = try LayoutRenderer.compositeLandscape(image: photo, canvas: canvas,
                                                             settings: g, template: template)
            CGImageDestinationAddImage(dest, page, frameProps)
            written += 1
        }
        guard written > 0 else { throw GIFError.noPhotos }
        guard CGImageDestinationFinalize(dest) else { throw GIFError.encodeFailed }
        return out as Data
    }

}
