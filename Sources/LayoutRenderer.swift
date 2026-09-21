import Foundation
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

enum RenderError: LocalizedError {
    case noContext
    case noPhotos
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .noContext:     return "Could not create the print canvas."
        case .noPhotos:      return "There are no photographs to lay out."
        case .encodeFailed:  return "Could not encode the final print image."
        }
    }
}

/// One photo slot on the 4×6 sheet, in top-left pixel coordinates.
struct Slot {
    let rect: CGRect
    let photoIndex: Int   // 0-based index into the session's photos
}

/// Builds the flattened 4×6 print image. Pure geometry + drawing: it knows
/// nothing about cameras, printers or sessions.
enum LayoutRenderer {

    static let cornerRadius: CGFloat = 10

    /// Height of the footer strip.
    ///
    /// A QR code needs about 20 mm square on paper before phone cameras read it
    /// reliably, so switching the QR on grows the strip rather than shrinking the
    /// code into something decorative that nobody can scan.
    /// The duplicate-strip sheet gets a taller footer when it carries a code: two
    /// footers means each is only half the width, and a 20 mm square beside two
    /// lines of type does not fit in two inches. Stacked, it does.
    static func footerHeight(_ settings: AppSettings, layout: PrintLayout? = nil) -> CGFloat {
        let dpi = CGFloat(settings.dpi)
        guard settings.footerEnabled else { return 0 }
        guard settings.printQRCode else { return 0.42 * dpi }
        return (layout == .duplicateStrips ? 1.30 : 0.95) * dpi
    }

    // MARK: - Geometry

    /// Slots for a layout at a given canvas size. Top-left origin, y grows downward.
    static func slots(for layout: PrintLayout, canvas: CGSize, settings: AppSettings) -> [Slot] {
        let dpi = CGFloat(settings.dpi)
        let m = max(0, CGFloat(settings.outerMarginInches) * dpi)
        let g = max(0, CGFloat(settings.gutterInches) * dpi)
        let footer = settings.footerEnabled ? footerHeight(settings, layout: layout) : m * 0.5
        let W = canvas.width, H = canvas.height

        switch layout {
        case .duplicateStrips:
            // Two identical 2×6 strips. Build one strip, then mirror it to the right half.
            let stripW = W / 2
            let n = 4
            let pw = stripW - 2 * m
            let availH = H - 2 * m - footer - CGFloat(n - 1) * g
            let ph = availH / CGFloat(n)
            var out: [Slot] = []
            for side in 0..<2 {
                let x = CGFloat(side) * stripW + m
                for i in 0..<n {
                    let y = m + CGFloat(i) * (ph + g)
                    out.append(Slot(rect: CGRect(x: x, y: y, width: pw, height: ph), photoIndex: i))
                }
            }
            return out

        case .eightUnique:
            let cols = 2, rows = 4
            let pw = (W - 2 * m - CGFloat(cols - 1) * g) / CGFloat(cols)
            let availH = H - 2 * m - footer - CGFloat(rows - 1) * g
            let ph = availH / CGFloat(rows)
            var out: [Slot] = []
            for r in 0..<rows {
                for c in 0..<cols {
                    let x = m + CGFloat(c) * (pw + g)
                    let y = m + CGFloat(r) * (ph + g)
                    out.append(Slot(rect: CGRect(x: x, y: y, width: pw, height: ph),
                                    photoIndex: r * cols + c))
                }
            }
            return out

        case .fourFullPage:
            // Two by two, portrait frames on a wide mat.
            //
            // The frames are held at a true 2:3 — a 3:2 negative stood on its
            // end — rather than being stretched to fill whatever space is left.
            // Whichever way the sheet runs out first decides where the slack
            // goes: wider side mats when height runs out, a deeper foot when
            // width does. That is what gives the arrangement its air.
            let gap = max(g, 0.10 * dpi)
            let boxW = W - 2 * m - gap
            let boxH = H - 2 * m - footer - gap
            var cw = boxW / 2
            var ch = cw * 1.5
            if ch > boxH / 2 {
                ch = boxH / 2
                cw = ch / 1.5
            }
            let blockW = 2 * cw + gap
            let x0 = (W - blockW) / 2
            var out: [Slot] = []
            for r in 0..<2 {
                for c in 0..<2 {
                    out.append(Slot(rect: CGRect(x: x0 + CGFloat(c) * (cw + gap),
                                                 y: m + CGFloat(r) * (ch + gap),
                                                 width: cw, height: ch),
                                    photoIndex: r * 2 + c))
                }
            }
            return out
        }
    }

    /// Where the footer goes. The duplicate-strip sheet is cut down the middle,
    /// so each half needs its own title and its own code — one footer across the
    /// whole sheet would be sliced in two and neither guest would have a usable
    /// one.
    static func footerRegions(for layout: PrintLayout,
                              canvas: CGSize,
                              settings: AppSettings) -> [CGRect] {
        guard settings.footerEnabled else { return [] }
        let dpi = CGFloat(settings.dpi)
        let m = max(0, CGFloat(settings.outerMarginInches) * dpi)
        let footerH = footerHeight(settings, layout: layout)
        let y = canvas.height - m - footerH

        switch layout {
        case .duplicateStrips:
            let stripW = canvas.width / 2
            return (0..<2).map { side in
                CGRect(x: CGFloat(side) * stripW + m, y: y,
                       width: stripW - 2 * m, height: footerH)
            }
        case .eightUnique, .fourFullPage:
            return [CGRect(x: m, y: y, width: canvas.width - 2 * m, height: footerH)]
        }
    }

    /// Aspect ratio of the first slot — drives the guest framing guide so people
    /// are not surprised by what the print crops away.
    static func cellAspect(for layout: PrintLayout, settings: AppSettings,
                           template: PrintTemplate? = nil) -> CGFloat {
        let canvas = settings.pixelSize
        // A template's own first slot, so the guide on the guest screen keeps
        // telling the truth once the operator has rearranged the sheet.
        if let t = template, let first = t.slots.first {
            let r = first.rect.rect(in: canvas)
            return r.height > 0 ? r.width / r.height : 1.5
        }
        guard let first = slots(for: layout, canvas: canvas, settings: settings).first else { return 1.5 }
        return first.rect.width / first.rect.height
    }

    // MARK: - Rendering

    /// Renders the final flattened print. Runs off the main thread.
    static func renderPrint(photos: [URL],
                            layout: PrintLayout,
                            settings: AppSettings,
                            qrPayload: String? = nil,
                            template: PrintTemplate? = nil) throws -> Data {
        guard !photos.isEmpty else { throw RenderError.noPhotos }
        let canvas = settings.pixelSize
        let images = photos.map { loadOrientedImage(at: $0) }

        let cg: CGImage
        if let template, !template.slots.isEmpty {
            cg = try composite(images: images, template: template, canvas: canvas,
                               settings: settings, qrPayload: qrPayload)
        } else {
            cg = try composite(images: images, layout: layout, canvas: canvas,
                               settings: settings, qrPayload: qrPayload)
        }
        guard let data = jpegData(from: cg, dpi: settings.dpi) else { throw RenderError.encodeFailed }
        return data
    }

    /// Composes one sheet from images already in memory, at any canvas size.
    ///
    /// Split out of `renderPrint` so the animated GIF can call it once per frame
    /// with a different set of pictures. That sharing is the point: the loop and
    /// the sheet come out of the same slot geometry, the same crop rule and the
    /// same footer, so they cannot drift apart when a margin setting changes.
    ///
    /// - Parameter images: indexed by `Slot.photoIndex`, so a layout that repeats
    ///   a photograph — the duplicate strip prints each one twice — needs only
    ///   one entry per distinct shot.
    static func composite(images: [CGImage?],
                          layout: PrintLayout,
                          canvas: CGSize,
                          settings: AppSettings,
                          qrPayload: String? = nil) throws -> CGImage {
        try draw(canvas: canvas, settings: settings) { ctx in
            for slot in slots(for: layout, canvas: canvas, settings: settings) {
                guard slot.photoIndex < images.count, let img = images[slot.photoIndex] else {
                    drawPlaceholder(ctx, rect: slot.rect, canvasH: canvas.height, number: slot.photoIndex + 1)
                    continue
                }
                drawPhoto(ctx, image: img, in: slot.rect, canvasH: canvas.height, mode: settings.cropMode)
            }
            if settings.footerEnabled {
                for region in footerRegions(for: layout, canvas: canvas, settings: settings) {
                    drawFooter(ctx, canvas: canvas, region: region,
                               settings: settings, qrPayload: qrPayload)
                }
            }
        }
    }

    /// Composes a sheet the operator arranged themselves.
    ///
    /// Shares every primitive with the built-in path — the same photo draw, the
    /// same crop rule, the same rounded clip — so a template and a layout cannot
    /// disagree about how a photograph meets its slot.
    ///
    /// Order is the whole grammar here: background, any overlay marked as
    /// sitting behind, the photographs, then the rest of the overlays, then the
    /// border, then the code. That is what makes a sticker a sticker and a
    /// backdrop a backdrop.
    static func composite(images: [CGImage?],
                          template: PrintTemplate,
                          canvas: CGSize,
                          settings: AppSettings,
                          qrPayload: String? = nil,
                          overlayImage: (String) -> CGImage? = { BrandingAssets.loadCGImage($0) }) throws -> CGImage {
        var s = settings
        s.backgroundHex = template.backgroundHex

        return try draw(canvas: canvas, settings: s) { ctx in
            func drawOverlays(behind: Bool) {
                for o in template.overlays where o.behindPhotos == behind {
                    guard !o.file.isEmpty, let img = overlayImage(o.file) else { continue }
                    let r = flip(o.rect.rect(in: canvas), canvasH: canvas.height)
                    ctx.saveGState()
                    ctx.setAlpha(max(0, min(o.opacity, 1)))
                    ctx.interpolationQuality = .high
                    // Aspect-fit: a logo squashed to fill its box is worse than a
                    // logo with air around it, and the operator sized the box.
                    let iw = CGFloat(img.width), ih = CGFloat(img.height)
                    if iw > 0, ih > 0 {
                        let scale = min(r.width / iw, r.height / ih)
                        let w = iw * scale, h = ih * scale
                        ctx.draw(img, in: CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h))
                    }
                    ctx.restoreGState()
                }
            }

            drawOverlays(behind: true)

            for slot in template.slots {
                let rect = slot.rect.rect(in: canvas)
                let radius = slot.cornerRadius * min(rect.width, rect.height)
                guard slot.photoIndex < images.count, let img = images[slot.photoIndex] else {
                    drawPlaceholder(ctx, rect: rect, canvasH: canvas.height, number: slot.photoIndex + 1)
                    continue
                }
                drawPhoto(ctx, image: img, in: rect, canvasH: canvas.height,
                          mode: slot.cropMode, radius: radius)
            }

            drawOverlays(behind: false)

            if template.border.enabled {
                let b = template.border
                let inset = b.inset * canvas.width
                let line = max(1, b.width * canvas.width)
                let r = CGRect(origin: .zero, size: canvas)
                    .insetBy(dx: inset + line / 2, dy: inset + line / 2)
                ctx.saveGState()
                ctx.setStrokeColor(cgColor(b.colorHex))
                ctx.setLineWidth(line)
                ctx.addPath(roundedPath(r, radius: b.cornerRadius * canvas.width))
                ctx.strokePath()
                ctx.restoreGState()
            }

            if let payload = qrPayload, !payload.isEmpty, let box = template.qr {
                let r = flip(box.rect(in: canvas), canvasH: canvas.height)
                let side = min(r.width, r.height)
                let square = CGRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side)
                if let qr = QRCode.cgImage(for: payload, minimumSide: side * 2) {
                    ctx.saveGState()
                    ctx.interpolationQuality = .none   // never smooth a QR code
                    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                    ctx.fill(square.insetBy(dx: -side * 0.04, dy: -side * 0.04))
                    ctx.draw(qr, in: square)
                    ctx.restoreGState()
                }
            }
        }
    }

    /// The largest slot on a given canvas — how big a live-view frame has to be
    /// kept for the GIF, and no bigger.
    static func largestSlotSize(for layout: PrintLayout, canvas: CGSize, settings: AppSettings) -> CGSize {
        slots(for: layout, canvas: canvas, settings: settings)
            .map(\.rect.size)
            .max { $0.width * $0.height < $1.width * $1.height } ?? canvas
    }

    /// Low-resolution schematic used for the layout picker in Admin.
    static func schematic(for layout: PrintLayout, settings: AppSettings, width: CGFloat) -> NSImage? {
        let canvas = CGSize(width: width, height: width * 1.5)
        var s = settings
        s.dpi = Int(width / 4.0)
        guard let cg = try? draw(canvas: canvas, settings: s, body: { ctx in
            for slot in slots(for: layout, canvas: canvas, settings: s) {
                drawPlaceholder(ctx, rect: slot.rect, canvasH: canvas.height, number: slot.photoIndex + 1)
            }
            for region in footerRegions(for: layout, canvas: canvas, settings: s) {
                drawFooter(ctx, canvas: canvas, region: region, settings: s,
                           qrPayload: s.printQRCode ? "https://example.invalid/preview" : nil)
            }
        }) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: canvas.width, height: canvas.height))
    }

    // MARK: - Footer artwork

    /// Loaded once and kept, because a print, the layout schematic and the Admin
    /// preview all ask for it and decoding a 2400px PNG each time is wasted work.
    /// Keyed by file name, which `BrandingAssets` makes unique per import, so a
    /// replaced logo can never be served from the old entry.
    private static let footerImageCache = NSCache<NSString, CGImageBox>()
    private final class CGImageBox { let image: CGImage; init(_ i: CGImage) { image = i } }

    static func footerImage(_ settings: AppSettings) -> CGImage? {
        let name = settings.footerImageFile
        guard !name.isEmpty else { return nil }
        if let hit = footerImageCache.object(forKey: name as NSString) { return hit.image }
        guard let url = BrandingAssets.url(for: name),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        footerImageCache.setObject(CGImageBox(img), forKey: name as NSString)
        return img
    }

    /// Draws artwork centred in a band, scaled to fit and never enlarged past
    /// its own resolution — a small logo blown up to fill a strip looks worse
    /// than the same logo printed at the size it was drawn.
    ///
    /// `band` is already in CoreGraphics' bottom-left space. Every caller works
    /// from the footer region the surrounding code has flipped once, so flipping
    /// again here would put the artwork off the top of the sheet.
    private static func drawFooterArt(_ ctx: CGContext, image: CGImage, in band: CGRect) {
        let r = band
        guard r.width > 0, r.height > 0 else { return }
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        guard iw > 0, ih > 0 else { return }
        let scale = min(r.width / iw, r.height / ih)
        let w = iw * scale, h = ih * scale
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h))
        ctx.restoreGState()
    }

    // MARK: - Drawing primitives

    private static func draw(canvas: CGSize,
                             settings: AppSettings,
                             body: (CGContext) -> Void) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil,
                                  width: Int(canvas.width),
                                  height: Int(canvas.height),
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw RenderError.noContext
        }
        ctx.interpolationQuality = .high
        ctx.setFillColor(cgColor(settings.backgroundHex))
        ctx.fill(CGRect(origin: .zero, size: canvas))
        body(ctx)
        guard let img = ctx.makeImage() else { throw RenderError.noContext }
        return img
    }

    /// Converts a top-left rect into CoreGraphics' bottom-left space.
    private static func flip(_ r: CGRect, canvasH: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: canvasH - r.maxY, width: r.width, height: r.height)
    }

    private static func roundedPath(_ r: CGRect, radius: CGFloat) -> CGPath {
        let rad = min(radius, min(r.width, r.height) / 2)
        return CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
    }

    private static func drawPhoto(_ ctx: CGContext,
                                  image: CGImage,
                                  in topLeftRect: CGRect,
                                  canvasH: CGFloat,
                                  mode: CropMode,
                                  radius: CGFloat? = nil) {
        let rect = flip(topLeftRect, canvasH: canvasH)
        ctx.saveGState()
        ctx.addPath(roundedPath(rect, radius: radius ?? cornerRadius))
        ctx.clip()

        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let target: CGRect
        switch mode {
        case .fill:
            // Scale to cover, then centre — nothing is stretched.
            let scale = max(rect.width / iw, rect.height / ih)
            let w = iw * scale, h = ih * scale
            target = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        case .fit:
            let scale = min(rect.width / iw, rect.height / ih)
            let w = iw * scale, h = ih * scale
            target = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        }
        ctx.draw(image, in: target)
        ctx.restoreGState()
    }

    private static func drawPlaceholder(_ ctx: CGContext, rect: CGRect, canvasH: CGFloat, number: Int) {
        let r = flip(rect, canvasH: canvasH)
        ctx.saveGState()
        ctx.addPath(roundedPath(r, radius: cornerRadius))
        ctx.setFillColor(CGColor(gray: 0.90, alpha: 1))
        ctx.fillPath()
        ctx.addPath(roundedPath(r, radius: cornerRadius))
        ctx.setStrokeColor(CGColor(gray: 0.78, alpha: 1))
        ctx.setLineWidth(max(1, r.width * 0.006))
        ctx.strokePath()
        let size = min(r.width, r.height) * 0.34
        drawText(ctx, "\(number)",
                 centeredIn: r,
                 fontSize: size,
                 weight: .bold,
                 color: CGColor(gray: 0.62, alpha: 1))
        ctx.restoreGState()
    }

    private static func drawFooter(_ ctx: CGContext,
                                   canvas: CGSize,
                                   region: CGRect,
                                   settings: AppSettings,
                                   qrPayload: String?) {
        let footerH = region.height
        let r = flip(region, canvasH: canvas.height)

        let title = settings.footerText.isEmpty ? settings.eventTitle : settings.footerText
        let ink = CGColor(gray: 0.16, alpha: 1)
        let subInk = CGColor(gray: 0.42, alpha: 1)

        // QR first: it claims a square at the left of the strip and the caption
        // takes whatever is left, so a long event name can never squeeze it.
        var textRect = r
        if settings.printQRCode, let payload = qrPayload, !payload.isEmpty {
            // Half-width footers have no room beside a scannable code, so they
            // stack instead: code on top, name and caption beneath it.
            if region.width < footerH * 2 {
                drawStackedFooter(ctx, region: r, footerH: footerH,
                                  payload: payload, title: title, settings: settings, ink: ink)
                return
            }
            let side = footerH * 0.86
            let box = CGRect(x: r.minX, y: r.midY - side / 2, width: side, height: side)
            if let qr = QRCode.cgImage(for: payload, minimumSide: side * 2) {
                ctx.saveGState()
                ctx.interpolationQuality = .none   // never smooth a QR code
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fill(box.insetBy(dx: -side * 0.04, dy: -side * 0.04))
                ctx.draw(qr, in: box)
                ctx.restoreGState()
            }
            let gap = footerH * 0.16
            textRect = CGRect(x: box.maxX + gap, y: r.minY,
                              width: max(0, r.maxX - box.maxX - gap), height: r.height)

            let capSize = footerH * 0.15
            let caption = settings.qrCaption.isEmpty ? "SCAN TO GET YOUR PHOTOS" : settings.qrCaption
            drawText(ctx, caption.uppercased(),
                     centeredIn: CGRect(x: textRect.minX, y: textRect.minY + footerH * 0.22,
                                        width: textRect.width, height: footerH * 0.28),
                     fontSize: capSize,
                     weight: .medium,
                     color: subInk,
                     tracking: capSize * 0.16)

            let nameBand = CGRect(x: textRect.minX, y: textRect.minY + footerH * 0.50,
                                  width: textRect.width, height: footerH * 0.30)
            if let art = footerImage(settings) {
                drawFooterArt(ctx, image: art, in: nameBand)
                return
            }
            guard !title.isEmpty else { return }
            let size = footerH * 0.22
            drawText(ctx, title.uppercased(),
                     centeredIn: nameBand,
                     fontSize: size,
                     weight: .semibold,
                     color: ink,
                     tracking: size * 0.14)
            return
        }

        // No code to make room for, so artwork gets the whole band.
        if let art = footerImage(settings) {
            drawFooterArt(ctx, image: art, in: r.insetBy(dx: 0, dy: footerH * 0.12))
            return
        }
        guard !title.isEmpty else { return }
        let size = footerH * 0.40
        let band = CGRect(x: textRect.minX, y: textRect.minY + footerH * 0.22,
                          width: textRect.width, height: footerH * 0.5)
        drawText(ctx, title.uppercased(),
                 centeredIn: band,
                 fontSize: size,
                 weight: .semibold,
                 color: ink,
                 tracking: size * 0.14)
    }

    /// Code centred on top, name and caption beneath — the arrangement a 2-inch
    /// strip can actually hold.
    private static func drawStackedFooter(_ ctx: CGContext,
                                          region r: CGRect,
                                          footerH: CGFloat,
                                          payload: String,
                                          title: String,
                                          settings: AppSettings,
                                          ink: CGColor) {
        // The photographs end exactly where the footer begins, so the code needs
        // a little air above it or its white bleed clips the last frame.
        let pad = footerH * 0.05
        let side = min(r.width * 0.56, (footerH - pad) * 0.64)
        let box = CGRect(x: r.midX - side / 2, y: r.maxY - side - pad, width: side, height: side)
        if let qr = QRCode.cgImage(for: payload, minimumSide: side * 2) {
            ctx.saveGState()
            ctx.interpolationQuality = .none   // never smooth a QR code
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(box.insetBy(dx: -side * 0.04, dy: -side * 0.04))
            ctx.draw(qr, in: box)
            ctx.restoreGState()
        }

        let below = CGRect(x: r.minX, y: r.minY, width: r.width, height: box.minY - r.minY)
        guard below.height > 0 else { return }

        let capSize = min(footerH * 0.085, below.height * 0.34)
        let caption = settings.qrCaption.isEmpty ? "SCAN TO GET YOUR PHOTOS" : settings.qrCaption
        drawText(ctx, caption.uppercased(),
                 centeredIn: CGRect(x: below.minX, y: below.minY, width: below.width, height: below.height * 0.46),
                 fontSize: capSize,
                 weight: .medium,
                 color: CGColor(gray: 0.42, alpha: 1),
                 tracking: capSize * 0.14)

        let nameBand = CGRect(x: below.minX, y: below.minY + below.height * 0.44,
                              width: below.width, height: below.height * 0.5)
        if let art = footerImage(settings) {
            drawFooterArt(ctx, image: art, in: nameBand)
            return
        }
        guard !title.isEmpty else { return }
        let size = min(footerH * 0.125, below.height * 0.46)
        drawText(ctx, title.uppercased(),
                 centeredIn: nameBand,
                 fontSize: size,
                 weight: .semibold,
                 color: ink,
                 tracking: size * 0.12)
    }

    private static func drawText(_ ctx: CGContext,
                                 _ string: String,
                                 centeredIn rect: CGRect,
                                 fontSize: CGFloat,
                                 weight: NSFont.Weight,
                                 color: CGColor,
                                 tracking: CGFloat = 0) {
        // Sizes are proportional to the footer's height, but a duplicate-strip
        // footer is barely half as wide as a full-page one, so a long event name
        // has to be allowed to shrink rather than run off the paper.
        func line(_ size: CGFloat) -> (CTLine, CGRect) {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: NSColor(cgColor: color) ?? .black
            ]
            if tracking != 0 { attrs[.kern] = tracking * (size / fontSize) }
            let l = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
            return (l, CTLineGetBoundsWithOptions(l, .useOpticalBounds))
        }

        var (ctLine, bounds) = line(fontSize)
        if bounds.width > rect.width, bounds.width > 0 {
            let shrunk = max(fontSize * 0.45, fontSize * (rect.width / bounds.width))
            (ctLine, bounds) = line(shrunk)
        }
        let line = ctLine

        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.setTextDrawingMode(.fill)
        let x = rect.midX - bounds.width / 2 - bounds.minX
        let y = rect.midY - bounds.height / 2 - bounds.minY
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: - Image IO

    /// Loads a JPEG with its EXIF orientation baked in, so portrait-held shots
    /// are not laid out sideways.
    static func loadOrientedImage(at url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }

        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let raw = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        guard raw != 1 else { return cg }

        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let swapped = [5, 6, 7, 8].contains(Int(raw))
        let outSize = CGSize(width: swapped ? h : w, height: swapped ? w : h)

        guard let ctx = CGContext(data: nil,
                                  width: Int(outSize.width),
                                  height: Int(outSize.height),
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return cg }
        ctx.interpolationQuality = .high

        switch raw {
        case 2: ctx.translateBy(x: w, y: 0);      ctx.scaleBy(x: -1, y: 1)
        case 3: ctx.translateBy(x: w, y: h);      ctx.rotate(by: .pi)
        case 4: ctx.translateBy(x: 0, y: h);      ctx.scaleBy(x: 1, y: -1)
        case 5: ctx.rotate(by: -.pi / 2);         ctx.scaleBy(x: -1, y: 1)
        case 6: ctx.translateBy(x: 0, y: h);      ctx.rotate(by: -.pi / 2); ctx.translateBy(x: -w, y: 0)
        case 7: ctx.translateBy(x: outSize.width, y: outSize.height); ctx.rotate(by: .pi / 2); ctx.scaleBy(x: -1, y: 1)
        case 8: ctx.translateBy(x: outSize.width, y: 0); ctx.rotate(by: .pi / 2)
        default: break
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? cg
    }

    /// Flips a JPEG left-to-right, keeping its pixel dimensions and DPI.
    static func mirroredJPEG(_ data: Data, dpi: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let ctx = CGContext(data: nil, width: cg.width, height: cg.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: CGFloat(cg.width), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        guard let out = ctx.makeImage() else { return nil }
        return jpegData(from: out, dpi: dpi)
    }

    static func jpegData(from image: CGImage, dpi: Int) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    static func cgColor(_ hex: String) -> CGColor {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return CGColor(gray: 1, alpha: 1) }
        return CGColor(red:   CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue:  CGFloat(v & 0xFF) / 255,
                       alpha: 1)
    }
}
