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
    /// Where the guest codes go. Usually none or one — and two on a sheet that
    /// is cut into strips, since each half leaves with somebody different and a
    /// single code in the middle would be cut in two.
    var qrBoxes: [TemplateQR] = []
    /// The single box layouts used to carry. Read when an older file is opened
    /// and folded into `qrBoxes`; never written again.
    private var qr: NormRect?
    /// The dotted line the operator cuts along. Optional because most sheets are
    /// not cut at all — only the ones printed two strips to a page.
    var cutGuide: CutGuide?
    var updatedAt = Date()

    /// Photographs this sheet needs before it can be printed. Distinct indices,
    /// because a duplicate strip uses the same photograph twice.
    var photoCount: Int {
        Set(slots.map(\.photoIndex)).count
    }

    var isEmpty: Bool { slots.isEmpty && overlays.isEmpty }
}

/// The line a sheet is cut along, printed faintly so the cut has something to
/// follow and the halves carry no visible mark afterwards.
///
/// Printed rather than drawn on screen only: a guillotine at a venue is a pair of
/// scissors and somebody's judgement, and a line down the middle of the paper is
/// the difference between two clean strips and two crooked ones. Low opacity is
/// the whole trick — dark enough to follow under venue lighting, light enough
/// that a millimetre of it left on an edge does not read as a mistake.
struct CutGuide: Codable, Hashable {
    enum Orientation: String, Codable, CaseIterable, Identifiable {
        case vertical, horizontal
        var id: String { rawValue }
        var title: String { self == .vertical ? "Down the middle" : "Across the middle" }
    }

    var orientation: Orientation = .vertical
    /// Where it sits, as a fraction across the sheet. Half is the whole point of
    /// it, but a sheet cut into unequal parts is somebody's layout, not an error.
    var position: Double = 0.5
    var opacity: Double = 0.25
    /// Fraction of the canvas width, so the line holds its weight at any DPI.
    var width: Double = 0.0025
    /// Dash and gap, as fractions of the canvas's long edge.
    var dash: Double = 0.012
    var gap: Double = 0.010
    var colorHex: String = "#000000"
    /// How far in from the ends the line stops, so it does not run into the
    /// trimmed edge of a borderless print.
    var inset: Double = 0.02
}

/// One guest code on the sheet. Carries an id of its own because the editor
/// needs to tell two of them apart — select one, drag it, resize it, remove it —
/// and a bare rectangle cannot be referred to.
struct TemplateQR: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var rect = NormRect(x: 0.72, y: 0.84, w: 0.2, h: 0.13)
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
    /// Degrees clockwise about the slot's own centre. The rectangle stored in
    /// `rect` is the unturned one, so turning something never moves it and
    /// straightening it needs no second nudge.
    var rotation: Double = 0
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
    /// Degrees clockwise about the image's own centre — a sticker pinned on at
    /// an angle, a logo set square.
    var rotation: Double = 0
    /// Turns the artwork's colours over, alpha untouched.
    ///
    /// Almost always for one reason: a logo drawn white for a dark screen is
    /// invisible on white paper, and the operator has one file, not two.
    var inverted: Bool = false
}

// MARK: - Lenient decoding
//
// Swift's synthesised decoder treats a missing key as an error even when the
// property has a default, so the day a field is added every layout saved before
// it stops decoding — and a store that cannot decode its file comes up empty.
// Losing an operator's library to a new field is not a trade worth making, so
// both of these are decoded by hand. They live in extensions to keep the
// memberwise initialiser the rest of the app builds them with.

extension PrintTemplate {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id            = try c.decodeIfPresent(String.self, forKey: .id)             ?? id
        name          = try c.decodeIfPresent(String.self, forKey: .name)           ?? name
        backgroundHex = try c.decodeIfPresent(String.self, forKey: .backgroundHex)  ?? backgroundHex
        slots         = try c.decodeIfPresent([TemplateSlot].self, forKey: .slots)  ?? slots
        overlays      = try c.decodeIfPresent([TemplateOverlay].self, forKey: .overlays) ?? overlays
        border        = try c.decodeIfPresent(TemplateBorder.self, forKey: .border) ?? border
        qrBoxes       = try c.decodeIfPresent([TemplateQR].self, forKey: .qrBoxes)  ?? qrBoxes
        // A layout saved when there could only be one code keeps it.
        if qrBoxes.isEmpty, let single = try c.decodeIfPresent(NormRect.self, forKey: .qr) {
            qrBoxes = [TemplateQR(rect: single)]
        }
        cutGuide      = try c.decodeIfPresent(CutGuide.self, forKey: .cutGuide)
        updatedAt     = try c.decodeIfPresent(Date.self, forKey: .updatedAt)        ?? updatedAt
    }
}

extension TemplateSlot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id           = try c.decodeIfPresent(String.self,   forKey: .id)           ?? id
        rect         = try c.decodeIfPresent(NormRect.self, forKey: .rect)         ?? rect
        photoIndex   = try c.decodeIfPresent(Int.self,      forKey: .photoIndex)   ?? photoIndex
        cornerRadius = try c.decodeIfPresent(Double.self,   forKey: .cornerRadius) ?? cornerRadius
        cropMode     = try c.decodeIfPresent(CropMode.self, forKey: .cropMode)     ?? cropMode
        rotation     = try c.decodeIfPresent(Double.self,   forKey: .rotation)     ?? rotation
    }
}

extension TemplateOverlay {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id           = try c.decodeIfPresent(String.self,   forKey: .id)           ?? id
        file         = try c.decodeIfPresent(String.self,   forKey: .file)         ?? file
        rect         = try c.decodeIfPresent(NormRect.self, forKey: .rect)         ?? rect
        opacity      = try c.decodeIfPresent(Double.self,   forKey: .opacity)      ?? opacity
        behindPhotos = try c.decodeIfPresent(Bool.self,     forKey: .behindPhotos) ?? behindPhotos
        rotation     = try c.decodeIfPresent(Double.self,   forKey: .rotation)     ?? rotation
        inverted     = try c.decodeIfPresent(Bool.self,     forKey: .inverted)     ?? inverted
    }
}

/// Degrees, wrapped into (-180, 180] so "turn left" from straight reads as -90
/// rather than 270, and two layouts that look identical compare equal.
func normalisedAngle(_ degrees: Double) -> Double {
    var d = degrees.truncatingRemainder(dividingBy: 360)
    if d > 180 { d -= 360 }
    if d <= -180 { d += 360 }
    return d == 0 ? 0 : d   // keeps -0 out of the file
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

    /// Moves a layout one place up or down the list.
    ///
    /// The order in the file *is* the order on the Print Layout card and in
    /// every other chooser, so there is no separate position to keep in step —
    /// and no way for the two to disagree.
    func move(_ id: String, by offset: Int) {
        guard let i = templates.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard templates.indices.contains(j) else { return }
        templates.swapAt(i, j)
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
