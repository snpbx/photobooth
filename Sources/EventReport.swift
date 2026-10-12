import AppKit
import CoreGraphics
import Foundation

/// What an event cost and what it produced, in one page the operator can send.
///
/// The booth already knows all of this — it took the photographs and queued the
/// sheets — so the report is read from the session records rather than kept as a
/// second set of books that could disagree with them.
struct EventReport {

    struct Line {
        let time: Date
        let layout: String
        let photos: Int
        let copies: Int
        let status: PrintStatus
        /// Sheets this session actually accounts for: copies when it printed,
        /// nothing when it did not.
        var sheets: Int { status == .printed ? max(1, copies) : 0 }
    }

    let event: EventRecord
    let lines: [Line]
    /// What one sheet costs the operator — paper and ink together, which is how
    /// SELPHY packs are sold.
    let costPerSheet: Double
    let currency: String

    var clients: Int { lines.count }
    var photographs: Int { lines.reduce(0) { $0 + $1.photos } }
    var printed: Int { lines.reduce(0) { $0 + $1.sheets } }
    var pending: Int {
        lines.filter { $0.status == .queued || $0.status == .printing }
            .reduce(0) { $0 + max(1, $1.copies) }
    }
    var failed: Int {
        lines.filter { $0.status == .failed }.reduce(0) { $0 + max(1, $1.copies) }
    }
    var cost: Double { Double(printed) * costPerSheet }

    /// Which layouts were used, and how many guests had each. The question an
    /// operator actually asks of a past event: which sheet did people get?
    var layoutCounts: [(name: String, count: Int)] {
        var tally: [String: Int] = [:]
        for l in lines { tally[l.layout, default: 0] += 1 }
        return tally.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { (name: $0.key, count: $0.value) }
    }

    func money(_ value: Double) -> String {
        String(format: "%@%.2f", currency, value)
    }

    // MARK: - Building

    /// - Parameter layoutName: resolves a session's layout to what the operator
    ///   calls it, since a session records the built-in it started from while the
    ///   sheet may have been one of their own.
    static func build(event: EventRecord,
                      sessions: [SessionRecord],
                      costPerSheet: Double,
                      currency: String,
                      layoutName: (SessionRecord) -> String) -> EventReport {
        let lines = sessions
            .filter { $0.eventID == event.id && $0.finishedAt != nil }
            .sorted { $0.startedAt < $1.startedAt }
            .map { s in
                Line(time: s.startedAt, layout: layoutName(s), photos: s.photos.count,
                     copies: max(1, s.copies), status: s.printStatus)
            }
        return EventReport(event: event, lines: lines,
                           costPerSheet: costPerSheet, currency: currency)
    }

    // MARK: - The PDF

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMMM yyyy"; return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy 'at' HH:mm"; return f
    }()

    /// Draws the report onto A4 and writes it out.
    ///
    /// Plain CoreGraphics rather than a view rendered to PDF: this has to come
    /// out identically whether it is made from the console, from a script, or on
    /// a Mac whose display scale is anybody's guess, and a page of text and rules
    /// is not worth a view hierarchy.
    @discardableResult
    func writePDF(to url: URL) throws -> URL {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)   // A4 at 72dpi
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw ReportError.couldNotWrite(url.lastPathComponent)
        }
        var box = page
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw ReportError.couldNotWrite(url.lastPathComponent)
        }

        let margin: CGFloat = 48
        let right = page.width - margin
        var y = page.height - margin
        var pageNumber = 1

        func beginPage() {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(page)
            y = page.height - margin
        }
        func endPage() {
            text("\(event.name) · page \(pageNumber)", at: CGPoint(x: margin, y: 28),
                 size: 8, weight: .regular, grey: 0.55, in: ctx)
            text("Photobooth", at: CGPoint(x: right, y: 28),
                 size: 8, weight: .regular, grey: 0.55, in: ctx, alignRight: true)
            ctx.endPDFPage()
            pageNumber += 1
        }
        /// Starts a fresh page when the next row would fall off this one.
        func room(for height: CGFloat) {
            guard y - height < margin + 40 else { return }
            endPage()
            beginPage()
            columnHeads(in: ctx, y: &y, margin: margin, right: right)
        }

        beginPage()

        // Title block
        text(event.name, at: CGPoint(x: margin, y: y - 26), size: 24, weight: .bold, grey: 0, in: ctx)
        y -= 44
        var subtitle = Self.dayFormatter.string(from: event.date)
        if !event.client.isEmpty { subtitle += " · \(event.client)" }
        if !event.venue.isEmpty { subtitle += " · \(event.venue)" }
        text(subtitle, at: CGPoint(x: margin, y: y), size: 10, weight: .regular, grey: 0.35, in: ctx)
        y -= 28

        // What it came to
        rule(in: ctx, y: y, from: margin, to: right, grey: 0.85)
        y -= 22
        let figures: [(String, String)] = [
            ("Clients photographed", "\(clients)"),
            ("Photographs taken", "\(photographs)"),
            ("Sheets printed", "\(printed)"),
            ("Cost of paper and ink", money(cost))
        ]
        for (label, value) in figures {
            text(label, at: CGPoint(x: margin, y: y), size: 11, weight: .regular, grey: 0.3, in: ctx)
            text(value, at: CGPoint(x: right, y: y), size: 13, weight: .semibold, grey: 0, in: ctx,
                 alignRight: true)
            y -= 20
        }
        if pending > 0 || failed > 0 {
            var note = ""
            if pending > 0 { note += "\(pending) sheet(s) still queued" }
            if failed > 0 { note += note.isEmpty ? "" : " · "; note += "\(failed) failed" }
            text(note + " — not counted above", at: CGPoint(x: margin, y: y),
                 size: 9, weight: .regular, grey: 0.45, in: ctx)
            y -= 18
        }
        if costPerSheet > 0 {
            text("At \(money(costPerSheet)) a sheet.", at: CGPoint(x: margin, y: y),
                 size: 9, weight: .regular, grey: 0.45, in: ctx)
            y -= 18
        }
        y -= 8

        // Which sheets people took away
        if !layoutCounts.isEmpty {
            rule(in: ctx, y: y, from: margin, to: right, grey: 0.85)
            y -= 20
            text("Layouts used", at: CGPoint(x: margin, y: y), size: 11, weight: .semibold, grey: 0, in: ctx)
            y -= 18
            for entry in layoutCounts {
                text(entry.name, at: CGPoint(x: margin + 10, y: y), size: 10, weight: .regular, grey: 0.25, in: ctx)
                text("\(entry.count) client\(entry.count == 1 ? "" : "s")",
                     at: CGPoint(x: right, y: y), size: 10, weight: .regular, grey: 0.25, in: ctx,
                     alignRight: true)
                y -= 16
            }
            y -= 10
        }

        // Every session, in order
        columnHeads(in: ctx, y: &y, margin: margin, right: right)
        for (i, line) in lines.enumerated() {
            room(for: 18)
            if i % 2 == 1 {
                ctx.setFillColor(CGColor(gray: 0.97, alpha: 1))
                ctx.fill(CGRect(x: margin - 6, y: y - 5, width: right - margin + 12, height: 17))
            }
            text(Self.timeFormatter.string(from: line.time), at: CGPoint(x: margin, y: y),
                 size: 10, weight: .regular, grey: 0.2, in: ctx)
            text(line.layout, at: CGPoint(x: margin + 70, y: y), size: 10, weight: .regular, grey: 0.2,
                 in: ctx, maxWidth: 210)
            text("\(line.photos)", at: CGPoint(x: margin + 320, y: y), size: 10, weight: .regular,
                 grey: 0.2, in: ctx, alignRight: true)
            text("\(line.copies)", at: CGPoint(x: margin + 380, y: y), size: 10, weight: .regular,
                 grey: 0.2, in: ctx, alignRight: true)
            text(line.status.label, at: CGPoint(x: right, y: y), size: 10, weight: .regular,
                 grey: line.status == .printed ? 0.2 : 0.5, in: ctx, alignRight: true)
            y -= 17
        }

        y -= 14
        rule(in: ctx, y: y, from: margin, to: right, grey: 0.85)
        y -= 18
        text("Made \(Self.stampFormatter.string(from: Date())). A sheet counts once the printer says it finished.",
             at: CGPoint(x: margin, y: y), size: 8.5, weight: .regular, grey: 0.5, in: ctx)

        endPage()
        ctx.closePDF()
        return url
    }

    private func columnHeads(in ctx: CGContext, y: inout CGFloat, margin: CGFloat, right: CGFloat) {
        rule(in: ctx, y: y, from: margin, to: right, grey: 0.85)
        y -= 18
        text("Time", at: CGPoint(x: margin, y: y), size: 8.5, weight: .semibold, grey: 0.45, in: ctx)
        text("Layout", at: CGPoint(x: margin + 70, y: y), size: 8.5, weight: .semibold, grey: 0.45, in: ctx)
        text("Photos", at: CGPoint(x: margin + 320, y: y), size: 8.5, weight: .semibold, grey: 0.45,
             in: ctx, alignRight: true)
        text("Copies", at: CGPoint(x: margin + 380, y: y), size: 8.5, weight: .semibold, grey: 0.45,
             in: ctx, alignRight: true)
        text("Print", at: CGPoint(x: right, y: y), size: 8.5, weight: .semibold, grey: 0.45,
             in: ctx, alignRight: true)
        y -= 6
        rule(in: ctx, y: y, from: margin, to: right, grey: 0.85)
        y -= 18
    }

    private func rule(in ctx: CGContext, y: CGFloat, from x0: CGFloat, to x1: CGFloat, grey: CGFloat) {
        ctx.setStrokeColor(CGColor(gray: grey, alpha: 1))
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: x0, y: y + 10))
        ctx.addLine(to: CGPoint(x: x1, y: y + 10))
        ctx.strokePath()
    }

    private func text(_ string: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight,
                      grey: CGFloat, in ctx: CGContext, alignRight: Bool = false,
                      maxWidth: CGFloat? = nil) {
        Self.text(string, at: point, size: size, weight: weight, grey: grey, in: ctx,
                  alignRight: alignRight, maxWidth: maxWidth)
    }

    /// One line of text, truncated rather than allowed to run into the next
    /// column — a layout somebody called "Anna and Ben's Wedding Strip v3" must
    /// not walk across the page.
    private static func text(_ string: String, at point: CGPoint, size: CGFloat,
                             weight: NSFont.Weight, grey: CGFloat, in ctx: CGContext,
                             alignRight: Bool = false, maxWidth: CGFloat? = nil) {
        guard !string.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        var attributed = NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: NSColor(white: grey, alpha: 1)
        ])
        if let maxWidth {
            var shown = string
            while attributed.size().width > maxWidth, shown.count > 4 {
                shown = String(shown.dropLast(2))
                attributed = NSAttributedString(string: shown + "…", attributes: [
                    .font: font,
                    .foregroundColor: NSColor(white: grey, alpha: 1)
                ])
            }
        }
        let line = CTLineCreateWithAttributedString(attributed)
        let width = attributed.size().width
        ctx.textPosition = CGPoint(x: alignRight ? point.x - width : point.x, y: point.y)
        CTLineDraw(line, ctx)
    }

    enum ReportError: LocalizedError {
        case couldNotWrite(String)
        var errorDescription: String? {
            switch self {
            case .couldNotWrite(let name): return "Could not write \(name)."
            }
        }
    }
}
