import Foundation
import AppKit
import CoreGraphics
import CoreImage
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

    /// One photograph on the whole page, in the sheet's own branding.
    ///
    /// This is what the take-away GIF is made of. The print is a strip — the
    /// same picture twice, or six small ones — which at GIF size leaves each
    /// photograph the size of a stamp and the loop unreadable on a phone. So the
    /// frame keeps everything that makes the sheet theirs (background, footer,
    /// border, logos and stickers) and gives the photograph all the room the
    /// photographs had between them.
    ///
    /// The single slot is the union of the sheet's own slots, so the picture
    /// occupies exactly the area the arrangement set aside for pictures and
    /// nothing lands on top of a logo that was placed clear of them.
    static func compositeFullPage(image: CGImage?,
                                  layout: PrintLayout,
                                  canvas: CGSize,
                                  settings: AppSettings,
                                  template: PrintTemplate?) throws -> CGImage {
        if let t = template, !t.slots.isEmpty {
            return try composite(images: [image], template: fullPageTemplate(from: t),
                                 canvas: canvas, settings: settings)
        }
        let boxes = slots(for: layout, canvas: canvas, settings: settings).map(\.rect)
        let area = boxes.reduce(CGRect.null) { $0.union($1) }
        return try draw(canvas: canvas, settings: settings) { ctx in
            if let image {
                drawPhoto(ctx, image: image, in: area, canvasH: canvas.height, mode: settings.cropMode)
            }
            if settings.footerEnabled {
                // One footer across the page, even for the duplicate strip: the
                // GIF is never cut down the middle, so it needs one title, not
                // two half-width ones facing away from each other.
                for region in footerRegions(for: .fourFullPage, canvas: canvas, settings: settings) {
                    drawFooter(ctx, canvas: canvas, region: region, settings: settings, qrPayload: nil)
                }
            }
        }
    }

    /// The take-away loop's own frame: the camera's picture whole, on the
    /// sheet's background, with the sheet's artwork under it.
    ///
    /// **Landscape, and nothing cropped.** The print is a portrait strip, so a
    /// 3:2 frame placed in it has a third of its width cut away — which is the
    /// shot a guest is most likely to send on, with whoever was standing at the
    /// edge of it removed. The loop has no paper to match, so it takes the
    /// camera's own shape and fits the picture inside rather than filling it.
    ///
    /// The artwork keeps its proportions. Overlay rectangles are expressed as
    /// fractions of a 4×6 sheet; read against a 6×4 one they would stretch a
    /// logo half as wide again, so each is drawn to fit inside the space it was
    /// given instead of filling it, along a band at the foot of the frame.
    static func compositeLandscape(image: CGImage?,
                                   canvas: CGSize,
                                   settings: AppSettings,
                                   template: PrintTemplate?) throws -> CGImage {
        let marks = loopMarks(of: template)
        let band  = marks.isEmpty ? 0 : canvas.height * Self.artworkBand
        let inset = canvas.width * Self.frameInset
        let frame = CGRect(x: inset, y: inset,
                           width: canvas.width - inset * 2,
                           height: canvas.height - band - inset * 2)

        var look = settings
        if let t = template { look.backgroundHex = t.backgroundHex }
        look.footerEnabled = settings.footerEnabled && marks.isEmpty

        return try draw(canvas: canvas, settings: look) { ctx in
            if let image, frame.width > 0, frame.height > 0 {
                drawPhoto(ctx, image: image, in: frame, canvasH: canvas.height, mode: .fit)
            }
            // The artwork, along the foot, each piece at its own aspect ratio.
            if !marks.isEmpty {
                let mid = canvas.height - band / 2
                let room = canvas.width - inset * 2
                var pieces: [(img: CGImage, size: CGSize, centre: CGFloat)] = []
                for o in marks {
                    guard let art = BrandingAssets.loadCGImage(o.file) else { continue }
                    let img = o.inverted ? (inverted(art) ?? art) : art
                    guard img.width > 0, img.height > 0 else { continue }
                    let h = band * 0.62
                    let w = CGFloat(img.width) * (h / CGFloat(img.height))
                    pieces.append((img, CGSize(width: w, height: h),
                                   (o.rect.x + o.rect.w / 2) * canvas.width))
                }
                let gap = inset
                let total = pieces.reduce(0) { $0 + $1.size.width }
                    + gap * CGFloat(max(0, pieces.count - 1))
                if pieces.count == 1 {
                    // The only thing down there belongs in the middle.
                    pieces[0].centre = canvas.width / 2
                } else if total > room {
                    // More artwork than the band can hold at its own positions:
                    // shrink it all by the same amount and space it evenly, so
                    // nothing overlaps and nothing is singled out.
                    let shrink = room / total
                    var x = inset
                    for i in pieces.indices {
                        pieces[i].size = CGSize(width: pieces[i].size.width * shrink,
                                                height: pieces[i].size.height * shrink)
                        pieces[i].centre = x + pieces[i].size.width / 2
                        x += pieces[i].size.width + gap * shrink
                    }
                }
                for p in pieces {
                    let x = min(max(inset, p.centre - p.size.width / 2),
                                canvas.width - inset - p.size.width)
                    drawImage(ctx, p.img,
                              in: CGRect(x: x, y: mid - p.size.height / 2,
                                         width: p.size.width, height: p.size.height),
                              canvasH: canvas.height)
                }
            }
            if look.footerEnabled {
                for region in footerRegions(for: .fourFullPage, canvas: canvas, settings: look) {
                    drawFooter(ctx, canvas: canvas, region: region, settings: look, qrPayload: nil)
                }
            }
        }
    }

    /// The artwork a single loop frame should carry.
    ///
    /// A sheet with a cutting line down it is two strips that will be torn
    /// apart and handed to two guests, so its artwork is placed once per half.
    /// The loop is one frame and is never cut, so it takes one half's worth —
    /// otherwise the logo appears twice side by side, which reads as a mistake
    /// rather than as a strip for each of them.
    static func loopMarks(of template: PrintTemplate?) -> [TemplateOverlay] {
        let all = (template?.overlays ?? []).filter { !$0.file.isEmpty }
        guard let cut = template?.cutGuide, cut.orientation == .vertical else { return all }
        let half = all.filter { $0.rect.x + $0.rect.w / 2 < cut.position }
        return half.isEmpty ? all : half
    }

    /// How much of the loop's frame the sheet's artwork is given, and how far
    /// the picture sits from the edge. Shared with whoever works out how big
    /// the frame should be in the first place, so the picture lands exactly
    /// across it rather than nearly.
    static let artworkBand: CGFloat = 0.16
    static let frameInset: CGFloat = 0.015

    /// Draws an image into a top-left rectangle without scaling it to fit the
    /// box's shape — the box is where it goes, the image keeps its own.
    private static func drawImage(_ ctx: CGContext, _ img: CGImage,
                                  in topLeftRect: CGRect, canvasH: CGFloat) {
        ctx.saveGState()
        ctx.draw(img, in: flip(topLeftRect, canvasH: canvasH))
        ctx.restoreGState()
    }

    /// Where a code goes on a sheet whose layout never placed one.
    ///
    /// Under the photographs, in whatever space is left — and **one per strip**
    /// when the sheet carries a cutting line down the middle, because two
    /// halves cut apart need a code each; a single code in the middle would be
    /// sliced in two and neither guest would have one.
    ///
    /// When there is no room below, it sits in the bottom corner over whatever
    /// is there. A code printed over the edge of a photograph is a code; no code
    /// is a guest with nothing to scan.
    static func autoQRBoxes(for t: PrintTemplate) -> [NormRect] {
        let bottom = t.slots.map { $0.rect.y + $0.rect.h }.max() ?? 0.8
        let free = 1 - bottom
        let split = t.cutGuide.flatMap { $0.orientation == .vertical ? $0.position : nil }

        // Comfortable in the band, but never so large it dominates the sheet.
        let side = min(max(free * 0.62, 0.10), 0.16)
        let y = free >= 0.12 ? bottom + (free - side) / 2 : 1 - side - 0.02

        func box(centre x: Double) -> NormRect {
            var r = NormRect(x: x - side / 2, y: y, w: side, h: side)
            r.clamp()
            return r
        }
        guard let split else { return [box(centre: 0.5)] }
        return [box(centre: split / 2), box(centre: split + (1 - split) / 2)]
    }

    /// The operator's own sheet with its photograph slots collapsed into one.
    /// Everything else — background, border, every overlay and where it sits —
    /// is carried across untouched, which is the whole point: the loop has to
    /// look like it came from the same booth as the print.
    static func fullPageTemplate(from t: PrintTemplate) -> PrintTemplate {
        var g = t
        let minX = t.slots.map(\.rect.x).min() ?? 0.08
        let minY = t.slots.map(\.rect.y).min() ?? 0.08
        let maxX = t.slots.map { $0.rect.x + $0.rect.w }.max() ?? 0.92
        let maxY = t.slots.map { $0.rect.y + $0.rect.h }.max() ?? 0.80
        var slot = t.slots.first ?? TemplateSlot()
        slot.rect = NormRect(x: minX, y: minY, w: max(0.05, maxX - minX), h: max(0.05, maxY - minY))
        slot.photoIndex = 0
        // A turned slot is a deliberate tilt for one picture among several; a
        // single full-page frame turned by the same amount only looks broken.
        slot.rotation = 0
        g.slots = [slot]
        g.qrBoxes = []
        // Nothing is ever cut out of a GIF.
        g.cutGuide = nil
        return g
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
                    guard !o.file.isEmpty, let loaded = overlayImage(o.file) else { continue }
                    let img = o.inverted ? (inverted(loaded) ?? loaded) : loaded
                    let r = flip(o.rect.rect(in: canvas), canvasH: canvas.height)
                    ctx.saveGState()
                    turn(ctx, o.rotation, about: r)
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
                    drawPlaceholder(ctx, rect: rect, canvasH: canvas.height,
                                    number: slot.photoIndex + 1, rotation: slot.rotation)
                    continue
                }
                drawPhoto(ctx, image: img, in: rect, canvasH: canvas.height,
                          mode: slot.cropMode, radius: radius, rotation: slot.rotation)
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

            // The cut line goes over everything but the code: it is the last
            // thing the paper carries, and a photograph printed across the line
            // is exactly what it is there to be cut through.
            if let cut = template.cutGuide {
                drawCutGuide(ctx, cut, canvas: canvas)
            }

            if let payload = qrPayload, !payload.isEmpty {
                // The operator's own box when they placed one; otherwise the
                // free space under the photographs, a code per strip where the
                // sheet is going to be cut. A layout with no box used to print
                // no code at all, which is a guest holding a strip with no way
                // to reach anything.
                let boxes = template.qrBoxes.isEmpty
                    ? autoQRBoxes(for: template)
                    : template.qrBoxes.map(\.rect)
                for box in boxes {
                    let r = flip(box.rect(in: canvas), canvasH: canvas.height)
                    let side = min(r.width, r.height)
                    let square = CGRect(x: r.midX - side / 2, y: r.midY - side / 2,
                                        width: side, height: side)
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

    /// The faint dotted line the operator cuts along.
    ///
    /// Drawn in the page's own coordinates rather than through `flip`, because a
    /// line has no top or bottom to get wrong and the inset should read the same
    /// from either end.
    private static func drawCutGuide(_ ctx: CGContext, _ cut: CutGuide, canvas: CGSize) {
        let long = max(canvas.width, canvas.height)
        let line = max(1, cut.width * canvas.width)
        let dash = max(2, cut.dash * long)
        let gap = max(2, cut.gap * long)
        let inset = max(0, cut.inset) * long
        let p = min(max(cut.position, 0.02), 0.98)

        ctx.saveGState()
        ctx.setStrokeColor(cgColor(cut.colorHex).copy(alpha: min(max(cut.opacity, 0.02), 1))
                            ?? cgColor(cut.colorHex))
        ctx.setLineWidth(line)
        ctx.setLineDash(phase: 0, lengths: [dash, gap])
        ctx.setLineCap(.butt)
        switch cut.orientation {
        case .vertical:
            let x = canvas.width * p
            ctx.move(to: CGPoint(x: x, y: inset))
            ctx.addLine(to: CGPoint(x: x, y: canvas.height - inset))
        case .horizontal:
            let y = canvas.height * p
            ctx.move(to: CGPoint(x: inset, y: y))
            ctx.addLine(to: CGPoint(x: canvas.width - inset, y: y))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// The same artwork with its colours turned over and its transparency left
    /// alone, so a white-on-nothing logo becomes a black-on-nothing one.
    ///
    /// Cached by the image it was made from: a sheet draws its overlays once,
    /// but a proof, a GIF frame and the real print all ask for the same picture,
    /// and inverting is the only expensive thing done to one.
    static func inverted(_ image: CGImage) -> CGImage? {
        invertLock.lock()
        if let hit = invertCache.object(forKey: ObjectIdentifier(image).hashValue as NSNumber) {
            invertLock.unlock()
            return hit
        }
        invertLock.unlock()

        guard let filter = CIFilter(name: "CIColorInvert") else { return nil }
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        guard let output = filter.outputImage,
              let made = ciContext.createCGImage(output, from: output.extent) else { return nil }

        invertLock.lock()
        invertCache.setObject(made, forKey: ObjectIdentifier(image).hashValue as NSNumber)
        invertLock.unlock()
        return made
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private static let invertCache = NSCache<NSNumber, CGImage>()
    private static let invertLock = NSLock()

    /// Turns everything drawn after it about the centre of `rect`.
    ///
    /// Negated because the page is drawn bottom-up: positive degrees mean
    /// clockwise as the guest holds the print, which is counter-clockwise in a
    /// context whose y axis points the other way. Callers wrap this in
    /// save/restore, and the turn has to come before the clip so the clip turns
    /// with it rather than slicing a straight hole in a turned photograph.
    private static func turn(_ ctx: CGContext, _ degrees: Double, about rect: CGRect) {
        guard degrees != 0 else { return }
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.rotate(by: -CGFloat(degrees) * .pi / 180)
        ctx.translateBy(x: -rect.midX, y: -rect.midY)
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
                                  radius: CGFloat? = nil,
                                  rotation: Double = 0) {
        let rect = flip(topLeftRect, canvasH: canvasH)
        ctx.saveGState()
        turn(ctx, rotation, about: rect)
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

    /// A numbered stand-in, for proofing a layout before any photographs exist.
    static func placeholderImage(number: Int, size: CGSize = CGSize(width: 900, height: 600)) -> CGImage? {
        try? draw(canvas: size, settings: AppSettings()) { ctx in
            drawPlaceholder(ctx, rect: CGRect(origin: .zero, size: size),
                            canvasH: size.height, number: number)
        }
    }

    private static func drawPlaceholder(_ ctx: CGContext, rect: CGRect, canvasH: CGFloat,
                                        number: Int, rotation: Double = 0) {
        let r = flip(rect, canvasH: canvasH)
        ctx.saveGState()
        turn(ctx, rotation, about: r)
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

    static func drawText(_ ctx: CGContext,
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

    /// The same photograph in black and white, at its own size and DPI.
    ///
    /// `CIPhotoEffectMono` rather than simply draining the colour out: a flat
    /// desaturation leaves a red dress and a green wall the same middling grey,
    /// because they were about as bright as each other. The mono filter carries
    /// a film's own tonal curve, which separates them — and on a dye-sublimation
    /// printer, where grey is three inks laid over one another, a picture with
    /// no blacks and no whites in it is the one that comes out looking muddy.
    static func monochromeJPEG(_ data: Data, dpi: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let filter = CIFilter(name: "CIPhotoEffectMono") else { return nil }
        filter.setValue(CIImage(cgImage: cg), forKey: kCIInputImageKey)
        guard let output = filter.outputImage,
              let made = ciContext.createCGImage(output, from: output.extent) else { return nil }
        return jpegData(from: made, dpi: dpi)
    }

    /// The same photograph, lifted or pulled down by `stops` of exposure.
    ///
    /// Exposure rather than "brightness": adding a constant to every pixel
    /// washes the blacks out to grey and leaves the picture flat, while a stop
    /// is what the camera itself would have done — the whole scene, lighter,
    /// with its contrast intact. One stop either way is as far as this goes,
    /// which is about the range a booth's flash gets wrong.
    static func brightenedJPEG(_ data: Data, stops: Double, dpi: Int) -> Data? {
        guard abs(stops) > 0.001 else { return data }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let filter = CIFilter(name: "CIExposureAdjust") else { return nil }
        filter.setValue(CIImage(cgImage: cg), forKey: kCIInputImageKey)
        filter.setValue(max(-2, min(2, stops)), forKey: kCIInputEVKey)
        guard let output = filter.outputImage,
              let made = ciContext.createCGImage(output, from: output.extent) else { return nil }
        return jpegData(from: made, dpi: dpi)
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
