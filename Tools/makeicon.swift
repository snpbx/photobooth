import AppKit
import Foundation

// Generates Resources/AppIcon.icns — a gold photobooth strip on a dark plate.
// Run via ./makeicon.sh; not part of the app build.

func drawIcon(size: CGFloat) -> CGImage? {
    let s = size
    guard let ctx = CGContext(data: nil, width: Int(s), height: Int(s),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high

    // Rounded plate, matching macOS icon proportions.
    let inset = s * 0.055
    let plate = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = plate.width * 0.2237

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    if let grad = CGGradient(colorsSpace: space,
                             colors: [CGColor(red: 0.13, green: 0.14, blue: 0.17, alpha: 1),
                                      CGColor(red: 0.04, green: 0.045, blue: 0.06, alpha: 1)] as CFArray,
                             locations: [0, 1]) {
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: plate.minX, y: plate.maxY),
                               end: CGPoint(x: plate.maxX, y: plate.minY),
                               options: [])
    }
    ctx.restoreGState()

    // Photo strip: four gold frames, the second one filled to read as a "flash".
    let stripW = s * 0.36
    let stripH = s * 0.60
    let strip = CGRect(x: (s - stripW) / 2, y: (s - stripH) / 2, width: stripW, height: stripH)
    let gold = CGColor(red: 0.910, green: 0.702, blue: 0.235, alpha: 1)

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: strip, cornerWidth: s * 0.035, cornerHeight: s * 0.035, transform: nil))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    ctx.fillPath()

    let pad = stripW * 0.115
    let gap = stripH * 0.035
    let cellW = stripW - pad * 2
    let cellH = (stripH - pad * 2 - gap * 3) / 4
    for i in 0..<4 {
        let y = strip.minY + pad + CGFloat(3 - i) * (cellH + gap)
        let cell = CGRect(x: strip.minX + pad, y: y, width: cellW, height: cellH)
        let path = CGPath(roundedRect: cell, cornerWidth: cellH * 0.16, cornerHeight: cellH * 0.16, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(i == 1 ? gold : CGColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 1))
        ctx.fillPath()
    }
    ctx.restoreGState()

    // Aperture ring behind the strip, hinting at the DSLR.
    ctx.setStrokeColor(CGColor(red: 0.910, green: 0.702, blue: 0.235, alpha: 0.55))
    ctx.setLineWidth(s * 0.022)
    let r = s * 0.335
    ctx.strokeEllipse(in: CGRect(x: s / 2 - r, y: s / 2 - r, width: r * 2, height: r * 2))

    return ctx.makeImage()
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32),
                   ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256),
                   ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    guard let cg = drawIcon(size: CGFloat(px)) else { continue }
    let rep = NSBitmapImageRep(cgImage: cg)
    rep.size = NSSize(width: px, height: px)
    if let d = rep.representation(using: .png, properties: [:]) {
        try? d.write(to: out.appendingPathComponent("\(name).png"))
    }
}
print("iconset written")
