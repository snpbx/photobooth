import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Builds the animated strip a guest takes away alongside the print.
///
/// The loop is the **print's own layout**, animated. Every slot on the sheet
/// replays the seconds immediately before its shutter fired, and they all run at
/// once — so the whole strip moves, each frame showing what each guest was doing
/// in the run-up to the photograph that ended up in that cell.
///
/// The motion can only come from the live view. A shutter yields one still; the
/// three seconds before it exist nowhere else, which is why `BoothController`
/// keeps the countdown's preview frames and hands them here. The consequence is
/// that the moving picture is preview resolution, not sensor resolution — it is
/// drawn at the size of one cell in a 480px sheet, where that is plenty.
///
/// Geometry comes from `LayoutRenderer.composite`, the same call the print uses,
/// so the loop and the sheet cannot disagree about slots, cropping or footer.
///
/// GIF is the format on purpose rather than by nostalgia: it is the only moving
/// image that plays by itself in a text message, in Messages, WhatsApp and
/// Instagram alike, with nobody pressing anything. What follows is size
/// discipline — 256 colours and every frame stored whole, so frame count and
/// pixels are the entire cost. See `AppSettings.gifFPS`.
enum GIFRenderer {

    enum GIFError: LocalizedError {
        case noMotion
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .noMotion:     return "No live-view frames were captured to animate."
            case .encodeFailed: return "Could not encode the GIF."
            }
        }
    }

    /// Master switch, off while the feature is being reworked.
    ///
    /// Everything the GIF touches is gated on this — building it, the finish
    /// screen, the operator's gallery, the session page, the album and the
    /// uploads — so a session that already has a `session.gif` sitting in its
    /// folder stays hidden too, rather than half-appearing in one place and not
    /// another. Nothing is deleted and no file on disk is touched: set this to
    /// `true` and the whole feature comes back exactly as it was.
    static let enabled = false

    static let fileName = "session.gif"

    /// Run-up window, in seconds. Clamped rather than trusted: a settings file
    /// asking for thirty seconds would hold thirty seconds of preview for every
    /// shot in memory and then encode a GIF nobody waits through.
    static let minSeconds: Double = 1
    static let maxSeconds: Double = 6
    static let minFPS = 5
    static let maxFPS = 20

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

    /// The GIF is the print's shape — 4×6 — because it is the print's layout.
    static func canvasSize(settings: AppSettings) -> CGSize {
        composeSettings(settings).pixelSize
    }

    /// How large a preview frame has to be kept for one cell of the finished GIF.
    /// A little headroom above the slot so a `fill` crop is not resampling up.
    static func motionFrameSize(layout: PrintLayout, settings: AppSettings) -> CGSize {
        let g = composeSettings(settings)
        let slot = LayoutRenderer.largestSlotSize(for: layout, canvas: g.pixelSize, settings: g)
        return CGSize(width: (slot.width * 1.2).rounded(), height: (slot.height * 1.2).rounded())
    }

    static func frameCount(settings: AppSettings) -> Int {
        let seconds = min(max(settings.gifSeconds, minSeconds), maxSeconds)
        let fps = max(minFPS, min(settings.gifFPS, maxFPS))
        return max(2, Int((seconds * Double(fps)).rounded()))
    }

    // MARK: - Rendering

    /// Renders the animated strip. Runs off the main thread.
    ///
    /// - Parameters:
    ///   - motion: preview frames from each shot's run-up, keyed by shot number
    ///     (1-based, as the booth counts them). A shot with no frames falls back
    ///     to its still, so one camera hiccup costs one static cell rather than
    ///     the whole loop.
    ///   - stills: the captured photographs, in shot order — the fallback, and
    ///     what fills any cell the live view never reached.
    static func render(motion: [Int: [CGImage]],
                       stills: [URL],
                       layout: PrintLayout,
                       settings: AppSettings) throws -> Data {
        guard motion.values.contains(where: { !$0.isEmpty }) else { throw GIFError.noMotion }

        let g = composeSettings(settings)
        let canvas = g.pixelSize
        let fps = max(minFPS, min(settings.gifFPS, maxFPS))
        let count = frameCount(settings: settings)

        // Delay is rounded onto GIF's hundredth-of-a-second grid before it is
        // written; handing it 1/15 would silently become 0.06 and the loop would
        // run 10% fast.
        let delay = max(0.02, (1.0 / Double(fps) * 100).rounded() / 100)

        // Loaded once, not once per frame: a cell with no motion shows its still
        // in all `count` frames.
        let fallback: [CGImage?] = stills.map { LayoutRenderer.loadOrientedImage(at: $0) }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData,
                                                          UTType.gif.identifier as CFString,
                                                          count, nil)
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

        for k in 0..<count {
            var images: [CGImage?] = []
            for photoIndex in 0..<max(stills.count, motion.keys.max() ?? 0) {
                let frames = motion[photoIndex + 1] ?? []
                if frames.isEmpty {
                    images.append(photoIndex < fallback.count ? fallback[photoIndex] : nil)
                } else {
                    // Shots rarely end up with identical frame counts — the
                    // preview arrives when it arrives. Each cell is sampled
                    // across its own run, so every cell starts and finishes
                    // together however many frames it actually got.
                    let i = frames.count == 1 ? 0
                        : Int((Double(k) / Double(count - 1) * Double(frames.count - 1)).rounded())
                    images.append(frames[min(max(0, i), frames.count - 1)])
                }
            }
            let sheet = try LayoutRenderer.composite(images: images, layout: layout,
                                                     canvas: canvas, settings: g)
            CGImageDestinationAddImage(dest, sheet, frameProps)
        }

        guard CGImageDestinationFinalize(dest) else { throw GIFError.encodeFailed }
        return out as Data
    }
}
