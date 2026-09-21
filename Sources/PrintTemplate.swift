import Foundation
import CoreGraphics

/// A print sheet the operator has arranged themselves.
///
/// The three built-in layouts compute their slots from margin and gutter
/// settings, which keeps them tidy and makes them impossible to rearrange. A
/// template throws that away: every rectangle on the sheet — photograph, logo,
/// sticker — is stored as a fraction of the canvas, so one template renders
/// identically at 200, 300 or 600 DPI and survives a change of paper size.
///
/// Nothing here is in inches or pixels on purpose. Inches would have to be
/// re-derived every time the sheet changed; fractions never do.
struct PrintTemplate: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String = "Untitled layout"
    var backgroundHex: String = "#FFFFFF"
    var slots: [TemplateSlot] = []
    var overlays: [TemplateOverlay] = []
    var border = TemplateBorder()
    /// Where the guest QR code goes, if the operator wants one on the sheet.
    /// Optional because a template that carries no code is a perfectly good
    /// template — the finish screen still shows one.
    var qr: NormRect?
    var updatedAt = Date()

    /// Photographs this sheet needs before it can be printed. Distinct indices,
    /// because a duplicate strip uses the same photograph twice.
    var photoCount: Int {
        Set(slots.map(\.photoIndex)).count
    }

    var isEmpty: Bool { slots.isEmpty && overlays.isEmpty }
}

/// A rectangle as a fraction of the canvas: 0…1 on both axes, origin top-left.
struct NormRect: Codable, Hashable {
    var x: Double = 0.1
    var y: Double = 0.1
    var w: Double = 0.3
    var h: Double = 0.2

    func rect(in canvas: CGSize) -> CGRect {
        CGRect(x: x * canvas.width, y: y * canvas.height,
               width: w * canvas.width, height: h * canvas.height)
    }

    /// Kept inside the sheet and above a floor, so a stray drag cannot produce a
    /// rectangle with no area or one entirely off the paper.
    mutating func clamp(minSize: Double = 0.04) {
        w = min(max(w, minSize), 1)
        h = min(max(h, minSize), 1)
        x = min(max(x, 0), 1 - w)
        y = min(max(y, 0), 1 - h)
    }

    static func centred(w: Double, h: Double) -> NormRect {
        NormRect(x: (1 - w) / 2, y: (1 - h) / 2, w: w, h: h)
    }
}

/// One photograph's place on the sheet.
struct TemplateSlot: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var rect = NormRect()
    /// Which photograph of the session fills it. Two slots may share an index —
    /// that is how a strip gets printed twice on one sheet.
    var photoIndex: Int = 0
    /// Corner rounding as a fraction of the slot's shorter side, so it scales
    /// with the slot rather than looking heavier as the slot gets smaller.
    var cornerRadius: Double = 0.04
    var cropMode: CropMode = .fill
}

/// A logo, sticker or frame laid over the sheet.
struct TemplateOverlay: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    /// File name inside `BrandingAssets` — imported and normalised to PNG, so
    /// transparency survives and a sticker can genuinely sit over a photograph.
    var file: String = ""
    var rect = NormRect()
    var opacity: Double = 1
    /// Drawn after the photographs, in array order. Moving an overlay up or down
    /// the array is what "bring forward" and "send back" do.
    var behindPhotos: Bool = false
}

struct TemplateBorder: Codable, Hashable {
    var enabled: Bool = false
    /// Fraction of the canvas width, so it holds its weight at any DPI.
    var width: Double = 0.012
    var inset: Double = 0.02
    var colorHex: String = "#111111"
    var cornerRadius: Double = 0.02
}

// MARK: - Store

/// The operator's templates, as one JSON file beside their settings.
///
/// A single file rather than one per template: the whole set is a few kilobytes,
/// and an atomic write of one file cannot leave half a library behind after a
/// power cut mid-event.
@MainActor
final class TemplateStore: ObservableObject {
    @Published private(set) var templates: [PrintTemplate] = []

    private let url: URL

    init() {
        url = SettingsService.supportDirectory.appendingPathComponent("templates.json")
        load()
    }

    func template(_ id: String) -> PrintTemplate? {
        guard !id.isEmpty else { return nil }
        return templates.first { $0.id == id }
    }

    func save(_ t: PrintTemplate) {
        var copy = t
        copy.updatedAt = Date()
        if let i = templates.firstIndex(where: { $0.id == copy.id }) {
            templates[i] = copy
        } else {
            templates.append(copy)
        }
        persist()
    }

    func delete(_ id: String) {
        templates.removeAll { $0.id == id }
        persist()
    }

    func duplicate(_ id: String) -> PrintTemplate? {
        guard var t = template(id) else { return nil }
        t.id = UUID().uuidString
        t.name = "\(t.name) copy"
        save(t)
        return t
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        templates = (try? dec.decode([PrintTemplate].self, from: data)) ?? []
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(templates) else { return }
        try? data.write(to: url, options: .atomic)
        Log.shared.info("Saved \(templates.count) print template(s)")
    }

    // MARK: - Starting points

    /// A template seeded from one of the built-in layouts, so the editor opens on
    /// something that already prints rather than an empty sheet. The slots come
    /// out of `LayoutRenderer` itself, so what appears is exactly what that
    /// layout would have produced.
    static func seeded(from layout: PrintLayout, settings: AppSettings) -> PrintTemplate {
        let canvas = settings.pixelSize
        var t = PrintTemplate()
        t.name = layout.title
        t.backgroundHex = settings.backgroundHex
        t.slots = LayoutRenderer.slots(for: layout, canvas: canvas, settings: settings).map { s in
            TemplateSlot(
                rect: NormRect(x: s.rect.minX / canvas.width,
                               y: s.rect.minY / canvas.height,
                               w: s.rect.width / canvas.width,
                               h: s.rect.height / canvas.height),
                photoIndex: s.photoIndex,
                cropMode: settings.cropMode)
        }
        return t
    }
}
