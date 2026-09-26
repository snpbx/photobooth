import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Arranges a print sheet: where the photographs sit, what is laid over them,
/// and what frames the lot.
///
/// A window of its own rather than another Admin tab. Laying out a sheet is not
/// something done between groups — it is done once, carefully, before the event,
/// and it wants the whole screen while it happens.
///
/// The canvas draws plain SwiftUI shapes rather than the real composite, because
/// it redraws on every frame of a drag. **Proof sheet** renders the genuine
/// article through `LayoutRenderer`, which is the only thing that can be trusted
/// about what comes out of the printer.
/// What a measurement is shown in. The sheet is always stored as fractions;
/// this only decides how those fractions are written down and nudged.
enum PlacementUnit: String, CaseIterable, Identifiable {
    case percent = "%"
    case pixels = "px"
    case inches = "in"

    var id: String { rawValue }

    var decimals: Int {
        switch self {
        case .percent: return 1
        case .pixels:  return 0
        case .inches:  return 2
        }
    }

    /// A nudge worth making in this unit: a percent, ten pixels, a twentieth of
    /// an inch. One pixel at 300 DPI is a third of a millimetre — a step nobody
    /// would notice and everybody would have to press forty times.
    func step(_ axis: Axis, settings: AppSettings) -> Double {
        switch self {
        case .percent: return 1
        case .pixels:  return 10
        case .inches:  return 0.05
        }
    }
}

/// The state of a turn in progress.
private struct TurnDrag {
    let angle: Double
    let grab: Double
}

struct PrintEditorView: View {
    @ObservedObject var c: BoothController
    @ObservedObject var store: TemplateStore

    @State private var draft: PrintTemplate
    @State private var selection: String?
    @State private var dragOrigin: NormRect?
    /// Where a turn started: the item's angle, and the angle of the grab itself,
    /// so the handle stays under the pointer instead of jumping to it.
    @State private var turnOrigin: TurnDrag?
    @State private var proof: NSImage?
    @State private var dirty = false
    @State private var unit: PlacementUnit = .percent
    @State private var showGrid = true
    @State private var showRulers = true
    @State private var snapping = true
    /// Divisions across the sheet's short edge. Twelve is an inch of a 4in sheet
    /// cut into thirds — the spacing most of these layouts already fall on.
    @State private var gridDivisions = 12

    /// - Parameter templateID: which layout to open. Nil starts a new one seeded
    ///   from the selected built-in, so the editor never opens on a blank sheet.
    init(c: BoothController, store: TemplateStore, templateID: String? = nil) {
        self.c = c
        self.store = store
        let chosen = templateID.flatMap { store.template($0) }
        _draft = State(initialValue: chosen
                       ?? TemplateStore.seeded(from: c.settings.layout, settings: c.settings))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(spacing: 0) {
                canvasPane
                Rectangle().fill(Palette.hairline).frame(width: 1)
                inspector
                    .frame(width: 376)
            }
        }
        .background(Palette.canvas)
        .environment(\.colorScheme, .light)
        .environment(\.touchControls, c.settings.touchControls)
        .controlSize(c.settings.touchControls ? .extraLarge : .regular)
        .modifier(TouchToggleStyling(enabled: c.settings.touchControls))
        .tint(Palette.ink)
        .foregroundStyle(Palette.ink)
        // Opens with something selected, so the placement controls are visible
        // rather than waiting behind a tap nobody knows to make.
        .onAppear { if selection == nil { selection = draft.slots.first?.id } }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            OSDLabel(text: "Print Layout", size: 11, weight: .bold, color: Palette.ink, tracking: 0.22)

            TextField("Layout name", text: Binding(
                get: { draft.name },
                set: { draft.name = $0; dirty = true }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)

            Menu("Open…") {
                ForEach(store.templates) { t in
                    Button(t.name) { load(t) }
                }
                if store.templates.isEmpty {
                    Text("Nothing saved yet").foregroundStyle(Palette.midGray)
                }
                Divider()
                ForEach(PrintLayout.allCases) { l in
                    Button("Start from \(l.title)") {
                        load(TemplateStore.seeded(from: l, settings: c.settings))
                        draft.id = UUID().uuidString
                        dirty = true
                    }
                }
            }
            .frame(width: 130)

            Spacer(minLength: 8)

            if dirty {
                Text("Unsaved")
                    .font(.system(size: 11)).foregroundStyle(Palette.midGray)
            }
            Button("Proof sheet") { makeProof() }
                .buttonStyle(QuietButtonStyle())
                .frame(width: 120)
            // Keeps the original and adds a variant, which is the usual way a
            // second layout comes about: someone opens the one that works and
            // changes two things about it.
            Button("Save as new") { saveAsNew() }
                .buttonStyle(QuietButtonStyle())
                .frame(width: 130)
            Button("Save") { save() }
                .buttonStyle(PrimaryButtonStyle())
                .frame(width: 110)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Palette.surfaceAlt)
    }

    // MARK: - Canvas

    /// Width of the ruler gutters. Wide enough for a two-digit label at the size
    /// the rest of the console uses, and no wider: every point here is a point
    /// the sheet does not get.
    private static let rulerGutter: CGFloat = 22

    private var canvasPane: some View {
        GeometryReader { geo in
            // The sheet keeps the printer's own proportions whatever the window
            // does, so nothing is arranged against a shape that will not print.
            let gutter = showRulers ? Self.rulerGutter : 0
            let sheet = fit(CGSize(width: 4, height: 6),
                            in: CGSize(width: geo.size.width - 48 - gutter,
                                       height: geo.size.height - 48 - gutter))
            ZStack {
                Color.clear
                VStack(spacing: 0) {
                    if showRulers {
                        HStack(spacing: 0) {
                            Color.clear.frame(width: gutter, height: gutter)
                            Ruler(axis: .horizontal, length: sheet.width, divisions: gridDivisions,
                                  unit: unit, settings: c.settings, highlight: highlight(.horizontal))
                                .frame(width: sheet.width, height: gutter)
                        }
                    }
                    HStack(spacing: 0) {
                        if showRulers {
                            Ruler(axis: .vertical, length: sheet.height, divisions: gridDivisions,
                                  unit: unit, settings: c.settings, highlight: highlight(.vertical))
                                .frame(width: gutter, height: sheet.height)
                        }
                        sheetView(sheet)
                            .frame(width: sheet.width, height: sheet.height)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onTapGesture { selection = nil }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The selected item's extent, for the ruler to mark off — a ruler with
    /// nothing on it only tells you how long the paper is.
    private func highlight(_ axis: Axis) -> ClosedRange<Double>? {
        guard let id = selection, let r = rect(of: id) else { return nil }
        return axis == .horizontal ? r.x...(r.x + r.w) : r.y...(r.y + r.h)
    }

    private func sheetView(_ sheet: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Color(hex: draft.backgroundHex)

            if showGrid {
                GridLines(divisions: gridDivisions, sheet: sheet)
            }

            ForEach(draft.overlays.filter(\.behindPhotos)) { o in
                overlayView(o, sheet: sheet)
            }
            ForEach(draft.slots) { s in
                slotView(s, sheet: sheet)
            }
            ForEach(draft.overlays.filter { !$0.behindPhotos }) { o in
                overlayView(o, sheet: sheet)
            }

            if draft.border.enabled {
                let inset = draft.border.inset * sheet.width
                RoundedRectangle(cornerRadius: draft.border.cornerRadius * sheet.width)
                    .strokeBorder(Color(hex: draft.border.colorHex),
                                  lineWidth: max(1, draft.border.width * sheet.width))
                    .padding(inset)
                    .allowsHitTesting(false)
            }

            // Shown exactly as it prints — faint, dotted, and in its place —
            // because the question being answered is whether it lands where the
            // scissors go, not whether it is visible on a screen.
            if let cut = draft.cutGuide {
                CutGuideLine(cut: cut, sheet: sheet)
            }

            if let q = draft.qr {
                box(q, sheet: sheet, id: "qr") {
                    ZStack {
                        Rectangle().fill(Color.white)
                        Image(systemName: "qrcode")
                            .resizable().scaledToFit().padding(6)
                            .foregroundStyle(Palette.ink)
                    }
                }
            }
        }
        .clipped()
        // Drags are measured here rather than inside each item: a turned item
        // has turned axes of its own, and a drag read in those would send it off
        // at the angle it was pinned at.
        .coordinateSpace(name: Self.sheetSpace)
        .overlay(Rectangle().stroke(Palette.hairline, lineWidth: 1).allowsHitTesting(false))
        .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
    }

    private func slotView(_ s: TemplateSlot, sheet: CGSize) -> some View {
        box(s.rect, sheet: sheet, id: s.id, rotation: s.rotation) {
            ZStack {
                RoundedRectangle(cornerRadius: s.cornerRadius * min(s.rect.w * sheet.width,
                                                                   s.rect.h * sheet.height))
                    .fill(Palette.canvas)
                RoundedRectangle(cornerRadius: s.cornerRadius * min(s.rect.w * sheet.width,
                                                                   s.rect.h * sheet.height))
                    .strokeBorder(Palette.hairline, lineWidth: 1)
                Text("\(s.photoIndex + 1)")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Palette.midGray)
            }
        }
    }

    private func overlayView(_ o: TemplateOverlay, sheet: CGSize) -> some View {
        box(o.rect, sheet: sheet, id: o.id, rotation: o.rotation) {
            Group {
                if let u = BrandingAssets.url(for: o.file), let img = NSImage(contentsOf: u) {
                    Image(nsImage: img).resizable().scaledToFit().opacity(o.opacity)
                } else {
                    ZStack {
                        Rectangle().fill(Palette.canvas)
                        Image(systemName: "photo").foregroundStyle(Palette.midGray)
                    }
                }
            }
        }
    }

    /// One positioned, draggable, resizable thing on the sheet.
    private func box<V: View>(_ rect: NormRect, sheet: CGSize, id: String,
                              rotation: Double = 0,
                              @ViewBuilder content: () -> V) -> some View {
        let r = rect.rect(in: sheet)
        let selected = selection == id
        return content()
            .frame(width: r.width, height: r.height)
            .contentShape(Rectangle())
            .overlay {
                if selected {
                    Rectangle().stroke(Palette.ink, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                if selected && id != "qr" {
                    ZStack {
                        Rectangle().fill(Palette.ink)
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Palette.paper)
                    }
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
                    .gesture(turnGesture(id: id, sheet: sheet))
                    .help("Drag to turn. It settles on multiples of 15°.")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if selected {
                    // Sits inside the corner rather than straddling it: an
                    // overlay hanging outside its parent is clipped for hit
                    // testing even where it still draws, and a handle you can
                    // see but not grab is worse than no handle.
                    ZStack {
                        Rectangle().fill(Palette.ink)
                        Image(systemName: "arrow.down.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Palette.paper)
                    }
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
                    .gesture(resizeGesture(id: id, sheet: sheet))
                }
            }
            .onTapGesture { selection = id }
            .gesture(moveGesture(id: id, sheet: sheet))
            // Placed with `offset`, and last.
            //
            // `position` makes the modified view fill its parent, so anything
            // attached after it — the content shape and both gestures — covered
            // the whole sheet rather than this one item. Every slot then had a
            // hit area the size of the page and whichever drew last swallowed
            // every drag, which is why individual shots could not be moved.
            // `offset` carries the frame and its hit testing together.
            //
            // The turn goes on before the offset so it happens about the item's
            // own centre; SwiftUI turns hit testing with it, so a sticker pinned
            // at an angle is grabbed where it is drawn.
            .rotationEffect(.degrees(rotation))
            .offset(x: r.minX, y: r.minY)
    }

    private static let sheetSpace = "sheet"

    private func moveGesture(id: String, sheet: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.sheetSpace))
            .onChanged { v in
                selection = id
                if dragOrigin == nil { dragOrigin = rect(of: id) }
                guard var r = dragOrigin else { return }
                r.x += v.translation.width / sheet.width
                r.y += v.translation.height / sheet.height
                r.clamp()
                r = snapMoved(r, id: id)
                setRect(r, of: id)
            }
            .onEnded { _ in dragOrigin = nil; dirty = true }
    }

    private func resizeGesture(id: String, sheet: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.sheetSpace))
            .onChanged { v in
                if dragOrigin == nil { dragOrigin = rect(of: id) }
                guard var r = dragOrigin else { return }
                // The handle is dragged across the sheet, but width and height
                // belong to the item, so the movement is read back onto the
                // item's own axes before it counts as a size.
                let d = unturn(v.translation, by: rotation(of: id))
                r.w += d.width / sheet.width
                r.h += d.height / sheet.height
                r.clamp()
                r = snapResized(r, id: id)
                setRect(r, of: id)
            }
            .onEnded { _ in dragOrigin = nil; dirty = true }
    }

    /// Turning by hand: the angle is taken from the line between the item's
    /// centre and the pointer, which is how a turn handle is expected to
    /// behave — the handle follows the hand rather than leading it.
    private func turnGesture(id: String, sheet: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.sheetSpace))
            .onChanged { v in
                selection = id
                guard let r = rect(of: id) else { return }
                let centre = CGPoint(x: (r.x + r.w / 2) * sheet.width,
                                     y: (r.y + r.h / 2) * sheet.height)
                func angle(_ p: CGPoint) -> Double {
                    Double(atan2(p.y - centre.y, p.x - centre.x)) * 180 / .pi
                }
                if turnOrigin == nil {
                    turnOrigin = TurnDrag(angle: rotation(of: id), grab: angle(v.startLocation))
                }
                guard let o = turnOrigin else { return }
                var a = o.angle + (angle(v.location) - o.grab)
                // Settles on the angles somebody actually wants — square, or a
                // deliberate tilt — without stopping them choosing 7°.
                let step = 15.0
                let nearest = (a / step).rounded() * step
                if abs(a - nearest) < 3 { a = nearest }
                setRotation(a, of: id)
            }
            .onEnded { _ in turnOrigin = nil; dirty = true }
    }

    // MARK: - Inspector

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionCard(title: "Add") {
                    Button("Photo slot") { addSlot() }
                        .buttonStyle(QuietButtonStyle())
                    Button("Image or sticker…") { addOverlay() }
                        .buttonStyle(QuietButtonStyle())
                    Button(draft.qr == nil ? "QR code box" : "Remove QR box") {
                        draft.qr = draft.qr == nil ? NormRect(x: 0.72, y: 0.84, w: 0.2, h: 0.13) : nil
                        dirty = true
                    }
                    .buttonStyle(QuietButtonStyle())
                    Button(draft.cutGuide == nil ? "Cutting line" : "Remove cutting line") {
                        draft.cutGuide = draft.cutGuide == nil ? CutGuide() : nil
                        dirty = true
                    }
                    .buttonStyle(QuietButtonStyle())
                }

                canvasCard
                if draft.cutGuide != nil { cutCard }

                photosCard

                if let id = selection { selectedCard(id) }

                SectionCard(title: "Sheet") {
                    LabeledRow(label: "Background") {
                        HexColorField(hex: Binding(
                            get: { draft.backgroundHex },
                            set: { draft.backgroundHex = $0; dirty = true }))
                    }
                    Toggle("Border", isOn: Binding(
                        get: { draft.border.enabled },
                        set: { draft.border.enabled = $0; dirty = true }))
                        .font(.system(size: 12))
                    if draft.border.enabled {
                        LabeledRow(label: "Colour") {
                            HexColorField(hex: Binding(
                                get: { draft.border.colorHex },
                                set: { draft.border.colorHex = $0; dirty = true }))
                        }
                        percentRow("Thickness", Binding(
                            get: { draft.border.width },
                            set: { draft.border.width = $0; dirty = true }), range: 0.002...0.08)
                        percentRow("Inset", Binding(
                            get: { draft.border.inset },
                            set: { draft.border.inset = $0; dirty = true }), range: 0...0.15)
                        percentRow("Corners", Binding(
                            get: { draft.border.cornerRadius },
                            set: { draft.border.cornerRadius = $0; dirty = true }), range: 0...0.12)
                    }
                }

                SectionCard(title: "Use this layout") {
                    Text("\(draft.slots.count) slot(s) · \(draft.photoCount) photo(s) per session")
                        .font(.system(size: 11)).foregroundStyle(Palette.midGray)

                    if let e = c.activeEvent {
                        Button(e.templateID == draft.id ? "In use for \(e.name)" : "Use for \(e.name)") {
                            save()
                            c.setTemplate(draft.id, forEvent: e.id)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(e.templateID == draft.id)
                    }

                    Button(c.settings.activeTemplateID == draft.id
                           ? "Is the booth default" : "Use as booth default") {
                        save()
                        c.settingsService.settings.activeTemplateID = draft.id
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(c.settings.activeTemplateID == draft.id)

                    Button("Back to the built-in layouts") {
                        c.settingsService.settings.activeTemplateID = ""
                        if let e = c.activeEvent { c.setTemplate("", forEvent: e.id) }
                    }
                    .buttonStyle(QuietButtonStyle())

                    Text("An event's own layout wins; otherwise the booth default; otherwise the built-in layouts.")
                        .font(.system(size: 11)).foregroundStyle(Palette.midGray)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let proof {
                    SectionCard(title: "Proof") {
                        Image(nsImage: proof)
                            .resizable().scaledToFit()
                            .frame(maxWidth: .infinity)
                            .overlay(Rectangle().stroke(Palette.hairline))
                        Text("Rendered through the printer's own path, not the editor's.")
                            .font(.system(size: 11)).foregroundStyle(Palette.midGray)
                    }
                }
            }
            .padding(18)
        }
        .background(Palette.surfaceAlt)
    }

    /// Every photograph on the sheet, as a list.
    ///
    /// The canvas is the quick way to work and a list is the certain one: it can
    /// select, reorder and remove a slot that is behind something else, off the
    /// edge, or too small to hit — none of which a drag can reach.
    private var photosCard: some View {
        SectionCard(title: "Photos on the sheet") {
            if draft.slots.isEmpty {
                Text("No photographs placed yet. Add one, or open a layout to start from.")
                    .font(.system(size: 11)).foregroundStyle(Palette.midGray)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Array(draft.slots.enumerated()), id: \.element.id) { pair in
                let i = pair.offset
                let slot = pair.element
                HStack(spacing: 8) {
                    Button {
                        selection = slot.id
                    } label: {
                        HStack(spacing: 8) {
                            Text("\(slot.photoIndex + 1)")
                                .font(VHS.mono(13, .bold))
                                .frame(width: 30, height: 30)
                                .background(selection == slot.id ? Palette.ink : Palette.canvas,
                                            in: RoundedRectangle(cornerRadius: 7))
                                .foregroundStyle(selection == slot.id ? Palette.paper : Palette.ink)
                            Text(String(format: "%.0f%% × %.0f%%  at  %.0f, %.0f",
                                        slot.rect.w * 100, slot.rect.h * 100,
                                        slot.rect.x * 100, slot.rect.y * 100))
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.midGray)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        if selection == slot.id { selection = nil }
                        draft.slots.remove(at: i)
                        dirty = true
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 15))
                            .foregroundStyle(Palette.ember)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Remove this photograph from the sheet")
                }
            }

            Button("Add photo slot") { addSlot() }
                .buttonStyle(QuietButtonStyle())
        }
    }

    /// The aids: on screen only, and remembered for as long as the window is
    /// open rather than saved with the layout — a grid is how somebody works,
    /// not part of what they made.
    private var canvasCard: some View {
        SectionCard(title: "Guides") {
            Toggle("Grid", isOn: $showGrid).font(.system(size: 12))
            Toggle("Rulers", isOn: $showRulers).font(.system(size: 12))
            Toggle("Snap to grid and edges", isOn: $snapping).font(.system(size: 12))

            LabeledRow(label: "Grid",
                       help: "Squares across the short edge. Things snap to these, to the sheet's middle, and to the edges and centres of everything already on it.") {
                Picker("", selection: $gridDivisions) {
                    Text("8").tag(8)
                    Text("12").tag(12)
                    Text("16").tag(16)
                    Text("24").tag(24)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                .disabled(!showGrid && !snapping)
            }
        }
    }

    /// The one thing here that is printed rather than drawn for the operator.
    private var cutCard: some View {
        SectionCard(title: "Cutting line") {
            Text("Printed faintly on the sheet so two strips can be cut apart cleanly. It is drawn over everything except the guest code.")
                .font(.system(size: 11)).foregroundStyle(Palette.midGray)
                .fixedSize(horizontal: false, vertical: true)

            LabeledRow(label: "Direction") {
                Picker("", selection: Binding(
                    get: { draft.cutGuide?.orientation ?? .vertical },
                    set: { draft.cutGuide?.orientation = $0; dirty = true })) {
                        ForEach(CutGuide.Orientation.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 180)
            }

            percentRow("Position", Binding(
                get: { draft.cutGuide?.position ?? 0.5 },
                set: { draft.cutGuide?.position = $0; dirty = true }), range: 0.05...0.95)

            percentRow("Opacity", Binding(
                get: { draft.cutGuide?.opacity ?? 0.25 },
                set: { draft.cutGuide?.opacity = $0; dirty = true }), range: 0.05...1)

            LabeledRow(label: "Back to the middle") {
                Button("Centre") { draft.cutGuide?.position = 0.5; dirty = true }
                    .buttonStyle(QuietButtonStyle())
            }

            Button("Remove") { draft.cutGuide = nil; dirty = true }
                .buttonStyle(QuietButtonStyle(destructive: true))
        }
    }

    /// Exact placement, for when a drag is not precise enough — or not possible.
    ///
    /// The guest code is placed but never turned: it is drawn square inside its
    /// box, and a turned code would only make it harder for a phone to read.
    @ViewBuilder
    private func rectControls(_ id: String) -> some View {
        Group {
            LabeledRow(label: "Measure in",
                       help: "Everything is stored as a fraction of the sheet whichever unit is shown, so a layout keeps its proportions at any DPI or paper size.") {
                Picker("", selection: $unit) {
                    ForEach(PlacementUnit.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }

            placementRow("Across", id: id, key: \.x, axis: .horizontal)
            placementRow("Down",   id: id, key: \.y, axis: .vertical)
            placementRow("Width",  id: id, key: \.w, axis: .horizontal)
            placementRow("Height", id: id, key: \.h, axis: .vertical)

            if id != "qr" {
            LabeledRow(label: "Turn",
                       help: "Degrees clockwise about the middle. The measurements above stay with the upright rectangle, so turning something never moves it — and a turned corner can hang past the paper's edge, which the proof sheet will show.") {
                HStack(spacing: 6) {
                    TextField("", value: Binding<Double>(
                        get: { self.rotation(of: id) },
                        set: { self.setRotation($0, of: id) }),
                        format: .number.precision(.fractionLength(0...1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                    Text("°")
                        .font(.system(size: 11)).foregroundStyle(Palette.midGray)
                        .frame(width: 20, alignment: .leading)
                    StepPad(symbol: "minus", side: 40) {
                        self.setRotation(self.rotation(of: id) - 5, of: id)
                    }
                    StepPad(symbol: "plus", side: 40) {
                        self.setRotation(self.rotation(of: id) + 5, of: id)
                    }
                }
            }

            LabeledRow(label: "Quarter turns") {
                HStack(spacing: 8) {
                    Button("Left") { setRotation(rotation(of: id) - 90, of: id) }
                        .buttonStyle(QuietButtonStyle())
                    Button("Right") { setRotation(rotation(of: id) + 90, of: id) }
                        .buttonStyle(QuietButtonStyle())
                    Button("Straight") { setRotation(0, of: id) }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(rotation(of: id) == 0)
                }
            }

            }

            LabeledRow(label: "Centre") {
                HStack(spacing: 8) {
                    Button("Across") { centre(id, horizontally: true) }
                        .buttonStyle(QuietButtonStyle())
                    Button("Down") { centre(id, horizontally: false) }
                        .buttonStyle(QuietButtonStyle())
                }
            }
        }
    }

    /// One measurement, typed or nudged, in whichever unit is showing.
    ///
    /// The field edits a real number rather than a slider position, because
    /// "37%" and "440 px" are the kinds of things somebody matching one slot to
    /// another actually knows, and a slider cannot be told them.
    private func placementRow(_ label: String, id: String,
                              key: WritableKeyPath<NormRect, Double>,
                              axis: Axis) -> some View {
        let span = self.span(axis)
        let bound = Binding<Double>(
            get: { (self.rect(of: id)?[keyPath: key] ?? 0) * span },
            set: { v in
                guard var r = self.rect(of: id) else { return }
                r[keyPath: key] = span > 0 ? v / span : 0
                r.clamp()
                self.setRect(r, of: id)
                self.dirty = true
            })

        return LabeledRow(label: label) {
            HStack(spacing: 6) {
                TextField("", value: bound, format: .number.precision(.fractionLength(0...unit.decimals)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                Text(unit.rawValue)
                    .font(.system(size: 11)).foregroundStyle(Palette.midGray)
                    .frame(width: 20, alignment: .leading)
                StepPad(symbol: "minus", side: 40) {
                    bound.wrappedValue -= unit.step(axis, settings: c.settings)
                }
                StepPad(symbol: "plus", side: 40) {
                    bound.wrappedValue += unit.step(axis, settings: c.settings)
                }
            }
        }
    }

    /// How much of the sheet one unit covers on this axis.
    private func span(_ axis: Axis) -> Double {
        switch unit {
        case .percent: return 100
        case .pixels:  return axis == .horizontal
                            ? Double(c.settings.pixelSize.width) : Double(c.settings.pixelSize.height)
        case .inches:  return axis == .horizontal ? 4 : 6
        }
    }

    private func centre(_ id: String, horizontally: Bool) {
        guard var r = rect(of: id) else { return }
        if horizontally { r.x = (1 - r.w) / 2 } else { r.y = (1 - r.h) / 2 }
        r.clamp()
        setRect(r, of: id)
        dirty = true
    }

    @ViewBuilder
    private func selectedCard(_ id: String) -> some View {
        if let i = draft.slots.firstIndex(where: { $0.id == id }) {
            SectionCard(title: "Photo slot") {
                rectControls(id)
                LabeledRow(label: "Shows photo", help: "Two slots may show the same photograph — that is how a strip gets printed twice.") {
                    IntStepper(value: Binding(
                        get: { draft.slots[i].photoIndex + 1 },
                        set: { draft.slots[i].photoIndex = max(0, $0 - 1); dirty = true }),
                        range: 1...12)
                }
                LabeledRow(label: "Fitting") {
                    Picker("", selection: Binding(
                        get: { draft.slots[i].cropMode },
                        set: { draft.slots[i].cropMode = $0; dirty = true })) {
                            ForEach(CropMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: 150)
                }
                percentRow("Corners", Binding(
                    get: { draft.slots[i].cornerRadius },
                    set: { draft.slots[i].cornerRadius = $0; dirty = true }), range: 0...0.5)

                Button("Duplicate slot") {
                    var copy = draft.slots[i]
                    copy.id = UUID().uuidString
                    copy.rect.x += 0.04
                    copy.rect.y += 0.04
                    copy.rect.clamp()
                    draft.slots.append(copy)
                    selection = copy.id
                    dirty = true
                }
                .buttonStyle(QuietButtonStyle())

                removeRow { draft.slots.remove(at: i) }
            }
        } else if let i = draft.overlays.firstIndex(where: { $0.id == id }) {
            SectionCard(title: "Image") {
                rectControls(id)
                percentRow("Opacity", Binding(
                    get: { draft.overlays[i].opacity },
                    set: { draft.overlays[i].opacity = $0; dirty = true }), range: 0.05...1)
                Toggle("Behind the photographs", isOn: Binding(
                    get: { draft.overlays[i].behindPhotos },
                    set: { draft.overlays[i].behindPhotos = $0; dirty = true }))
                    .font(.system(size: 12))
                HStack(spacing: 8) {
                    Button("Bring forward") {
                        guard i < draft.overlays.count - 1 else { return }
                        draft.overlays.swapAt(i, i + 1); dirty = true
                    }
                    .buttonStyle(QuietButtonStyle())
                    Button("Send back") {
                        guard i > 0 else { return }
                        draft.overlays.swapAt(i, i - 1); dirty = true
                    }
                    .buttonStyle(QuietButtonStyle())
                }
                Button("Replace image…") { replaceOverlay(at: i) }
                    .buttonStyle(QuietButtonStyle())
                removeRow { draft.overlays.remove(at: i) }
            }
        } else if id == "qr" {
            SectionCard(title: "QR code") {
                rectControls(id)
                Text("Drag to place the guest code. It is drawn square inside whatever box you give it.")
                    .font(.system(size: 11)).foregroundStyle(Palette.midGray)
                    .fixedSize(horizontal: false, vertical: true)
                removeRow { draft.qr = nil }
            }
        }
    }

    private func removeRow(_ action: @escaping () -> Void) -> some View {
        Button("Remove") {
            action()
            selection = nil
            dirty = true
        }
        .buttonStyle(QuietButtonStyle(destructive: true))
    }

    private func percentRow(_ label: String, _ value: Binding<Double>,
                            range: ClosedRange<Double>) -> some View {
        LabeledRow(label: label) {
            HStack(spacing: 8) {
                Slider(value: value, in: range).frame(width: 120)
                Text("\(Int(value.wrappedValue * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.midGray)
                    .frame(width: 38, alignment: .trailing)
            }
        }
    }

    // MARK: - Actions

    private func rect(of id: String) -> NormRect? {
        if let s = draft.slots.first(where: { $0.id == id }) { return s.rect }
        if let o = draft.overlays.first(where: { $0.id == id }) { return o.rect }
        if id == "qr" { return draft.qr }
        return nil
    }

    // MARK: - Snapping
    //
    // Within a hair of a line, take the line. The tolerance is in fractions of
    // the sheet rather than screen points on purpose: what counts as "near
    // enough" should not change because somebody resized the window.

    private static let snapTolerance = 0.006

    /// Every line worth landing on, on one axis: the grid, the sheet's own edges
    /// and middle, and the edges and centres of everything else on the page —
    /// which is what makes two slots line up without either one being typed.
    private func snapLines(_ axis: Axis, excluding id: String) -> [Double] {
        var out: [Double] = [0, 0.5, 1]
        let steps = max(2, gridDivisions)
        // The grid is square, so the long axis carries more divisions than the
        // short one — otherwise the cells would be rectangles and lining
        // anything up across the two would be guesswork.
        let count = axis == .horizontal ? steps : Int((Double(steps) * 1.5).rounded())
        for i in 0...count { out.append(Double(i) / Double(count)) }

        func add(_ r: NormRect) {
            if axis == .horizontal { out += [r.x, r.x + r.w / 2, r.x + r.w] }
            else { out += [r.y, r.y + r.h / 2, r.y + r.h] }
        }
        for s in draft.slots where s.id != id { add(s.rect) }
        for o in draft.overlays where o.id != id { add(o.rect) }
        if id != "qr", let q = draft.qr { add(q) }
        if let cut = draft.cutGuide,
           (cut.orientation == .vertical) == (axis == .horizontal) {
            out.append(cut.position)
        }
        return out
    }

    /// The nearest line, and how far it is — nil when nothing is close enough.
    private func nearest(_ value: Double, _ lines: [Double]) -> Double? {
        var best: Double?
        var bestGap = Self.snapTolerance
        for line in lines {
            let gap = abs(line - value)
            if gap <= bestGap { bestGap = gap; best = line }
        }
        return best
    }

    /// Moving snaps by whichever of the three edges is closest, so a box can be
    /// aligned by its left, its middle or its right without being told which.
    private func snapMoved(_ rect: NormRect, id: String) -> NormRect {
        guard snapping else { return rect }
        var r = rect
        let xs = snapLines(.horizontal, excluding: id)
        let ys = snapLines(.vertical, excluding: id)
        var bestX: (delta: Double, gap: Double)?
        for edge in [r.x, r.x + r.w / 2, r.x + r.w] {
            if let line = nearest(edge, xs) {
                let gap = abs(line - edge)
                if bestX == nil || gap < bestX!.gap { bestX = (line - edge, gap) }
            }
        }
        var bestY: (delta: Double, gap: Double)?
        for edge in [r.y, r.y + r.h / 2, r.y + r.h] {
            if let line = nearest(edge, ys) {
                let gap = abs(line - edge)
                if bestY == nil || gap < bestY!.gap { bestY = (line - edge, gap) }
            }
        }
        r.x += bestX?.delta ?? 0
        r.y += bestY?.delta ?? 0
        r.clamp()
        return r
    }

    /// Resizing moves one corner, so only the far edges snap — pulling the
    /// bottom-right corner must never shift the top-left one.
    private func snapResized(_ rect: NormRect, id: String) -> NormRect {
        guard snapping else { return rect }
        var r = rect
        if let line = nearest(r.x + r.w, snapLines(.horizontal, excluding: id)) {
            r.w = max(0.04, line - r.x)
        }
        if let line = nearest(r.y + r.h, snapLines(.vertical, excluding: id)) {
            r.h = max(0.04, line - r.y)
        }
        r.clamp()
        return r
    }

    private func rotation(of id: String) -> Double {
        if let s = draft.slots.first(where: { $0.id == id }) { return s.rotation }
        if let o = draft.overlays.first(where: { $0.id == id }) { return o.rotation }
        return 0
    }

    private func setRotation(_ degrees: Double, of id: String) {
        let d = normalisedAngle(degrees)
        if let i = draft.slots.firstIndex(where: { $0.id == id }) { draft.slots[i].rotation = d }
        if let i = draft.overlays.firstIndex(where: { $0.id == id }) { draft.overlays[i].rotation = d }
        dirty = true
    }

    /// A movement across the sheet, expressed in the axes of something turned
    /// by `degrees` — the inverse turn.
    private func unturn(_ t: CGSize, by degrees: Double) -> CGSize {
        guard degrees != 0 else { return t }
        let a = -degrees * .pi / 180
        return CGSize(width:  t.width * cos(a) - t.height * sin(a),
                      height: t.width * sin(a) + t.height * cos(a))
    }

    private func setRect(_ r: NormRect, of id: String) {
        if let i = draft.slots.firstIndex(where: { $0.id == id }) { draft.slots[i].rect = r; return }
        if let i = draft.overlays.firstIndex(where: { $0.id == id }) { draft.overlays[i].rect = r; return }
        if id == "qr" { draft.qr = r }
    }

    private func addSlot() {
        // Numbered after what is already there, so slots arrive in shot order
        // rather than all showing photograph one.
        let next = (draft.slots.map(\.photoIndex).max() ?? -1) + 1
        var s = TemplateSlot(rect: .centred(w: 0.34, h: 0.22), photoIndex: next)
        s.cropMode = c.settings.cropMode
        draft.slots.append(s)
        selection = s.id
        dirty = true
    }

    private func addOverlay() {
        guard let name = pickImage() else { return }
        let o = TemplateOverlay(file: name, rect: .centred(w: 0.4, h: 0.16))
        draft.overlays.append(o)
        selection = o.id
        dirty = true
    }

    private func replaceOverlay(at i: Int) {
        guard let name = pickImage() else { return }
        draft.overlays[i].file = name
        dirty = true
    }

    private func pickImage() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .image]
        panel.prompt = "Use Image"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            return try BrandingAssets.importImage(from: url)
        } catch {
            c.show(.warning, error.localizedDescription)
            return nil
        }
    }

    private func load(_ t: PrintTemplate) {
        draft = t
        selection = nil
        proof = nil
        dirty = false
    }

    private func save() {
        store.save(draft)
        dirty = false
    }

    private func saveAsNew() {
        var copy = draft
        copy.id = UUID().uuidString
        if store.template(draft.id) != nil { copy.name = "\(draft.name) copy" }
        store.save(copy)
        draft = copy
        dirty = false
    }

    /// Renders the sheet the way the printer will, with numbered stand-ins for
    /// the photographs. The editor's canvas is an approximation; this is not.
    private func makeProof() {
        let canvas = c.settings.pixelSize
        let count = max(1, (draft.slots.map(\.photoIndex).max() ?? 0) + 1)
        let stand = (0..<count).map { LayoutRenderer.placeholderImage(number: $0 + 1) }
        guard let cg = try? LayoutRenderer.composite(images: stand, template: draft,
                                                     canvas: canvas, settings: c.settings,
                                                     qrPayload: "https://example.invalid/proof")
        else { return }
        proof = NSImage(cgImage: cg, size: NSSize(width: canvas.width, height: canvas.height))
    }

    private func fit(_ ratio: CGSize, in bounds: CGSize) -> CGSize {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / ratio.width, bounds.height / ratio.height)
        return CGSize(width: ratio.width * scale, height: ratio.height * scale)
    }
}

// MARK: - Canvas furniture

/// The grid the sheet is arranged against.
///
/// Drawn from the short edge so the cells are square: a grid whose divisions
/// count differently across than down is no use for lining two things up, which
/// is the only thing a grid is for.
private struct GridLines: View {
    let divisions: Int
    let sheet: CGSize

    var body: some View {
        Canvas { ctx, size in
            let step = size.width / CGFloat(max(2, divisions))
            var x = step
            while x < size.width - 0.5 {
                ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                           with: .color(.black.opacity(0.07)), lineWidth: 1)
                x += step
            }
            var y = step
            while y < size.height - 0.5 {
                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                           with: .color(.black.opacity(0.07)), lineWidth: 1)
                y += step
            }
            // The halves, heavier: centring something by eye is the commonest
            // thing done here and the middle is where it is done against.
            ctx.stroke(Path { $0.move(to: CGPoint(x: size.width / 2, y: 0))
                              $0.addLine(to: CGPoint(x: size.width / 2, y: size.height)) },
                       with: .color(.black.opacity(0.16)), lineWidth: 1)
            ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: size.height / 2))
                              $0.addLine(to: CGPoint(x: size.width, y: size.height / 2)) },
                       with: .color(.black.opacity(0.16)), lineWidth: 1)
        }
        .frame(width: sheet.width, height: sheet.height)
        .allowsHitTesting(false)
    }
}

/// A ruler down one edge of the sheet, marked in whichever unit the inspector is
/// showing, with the selected item's extent picked out on it.
private struct Ruler: View {
    let axis: Axis
    let length: CGFloat
    let divisions: Int
    let unit: PlacementUnit
    let settings: AppSettings
    var highlight: ClosedRange<Double>?

    var body: some View {
        Canvas { ctx, size in
            let along = axis == .horizontal ? size.width : size.height
            let thick = axis == .horizontal ? size.height : size.width

            if let h = highlight {
                let a = CGFloat(min(max(h.lowerBound, 0), 1)) * along
                let b = CGFloat(min(max(h.upperBound, 0), 1)) * along
                let band = axis == .horizontal
                    ? CGRect(x: a, y: 0, width: max(1, b - a), height: thick)
                    : CGRect(x: 0, y: a, width: thick, height: max(1, b - a))
                ctx.fill(Path(band), with: .color(.black.opacity(0.10)))
            }

            // The grid's squares come from the short edge, so the long edge
            // carries proportionally more of them. A ruler whose ticks fall
            // between the grid lines is worse than no ruler.
            let steps = axis == .horizontal
                ? max(2, divisions)
                : max(2, Int((Double(divisions) * 1.5).rounded()))
            for i in 0...steps {
                let f = CGFloat(i) / CGFloat(steps)
                // Every step is ticked; every third is ticked long and labelled,
                // so the numbers do not run into each other on a small window.
                let major = i % 3 == 0
                let p = f * along
                let len = major ? thick * 0.55 : thick * 0.3
                let tick = axis == .horizontal
                    ? Path { $0.move(to: CGPoint(x: p, y: thick - len)); $0.addLine(to: CGPoint(x: p, y: thick)) }
                    : Path { $0.move(to: CGPoint(x: thick - len, y: p)); $0.addLine(to: CGPoint(x: thick, y: p)) }
                ctx.stroke(tick, with: .color(.black.opacity(major ? 0.45 : 0.25)), lineWidth: 1)

                guard major, i < steps else { continue }
                let value = Double(f) * span
                let text = Text(label(value))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(Palette.midGray)
                let at = axis == .horizontal
                    ? CGPoint(x: p + 9, y: thick * 0.32)
                    : CGPoint(x: thick * 0.40, y: p + 9)
                ctx.draw(text, at: at, anchor: .center)
            }
        }
        .background(Palette.surfaceAlt)
        .allowsHitTesting(false)
    }

    /// How much of the sheet one unit covers on this axis — the ruler and the
    /// placement fields have to agree or one of them is lying.
    private var span: Double {
        switch unit {
        case .percent: return 100
        case .pixels:  return axis == .horizontal
                            ? Double(settings.pixelSize.width) : Double(settings.pixelSize.height)
        case .inches:  return axis == .horizontal ? 4 : 6
        }
    }

    private func label(_ v: Double) -> String {
        switch unit {
        case .percent: return String(Int(v.rounded()))
        case .pixels:  return String(Int(v.rounded()))
        case .inches:  return String(format: "%.1f", v)
        }
    }
}

/// The cutting line as it will print: position, dash and opacity all real.
private struct CutGuideLine: View {
    let cut: CutGuide
    let sheet: CGSize

    var body: some View {
        Canvas { ctx, size in
            let long = max(size.width, size.height)
            let p = CGFloat(min(max(cut.position, 0.02), 0.98))
            let inset = CGFloat(max(0, cut.inset)) * long
            let path = Path { path in
                switch cut.orientation {
                case .vertical:
                    path.move(to: CGPoint(x: size.width * p, y: inset))
                    path.addLine(to: CGPoint(x: size.width * p, y: size.height - inset))
                case .horizontal:
                    path.move(to: CGPoint(x: inset, y: size.height * p))
                    path.addLine(to: CGPoint(x: size.width - inset, y: size.height * p))
                }
            }
            let style = StrokeStyle(lineWidth: max(1, CGFloat(cut.width) * size.width),
                                    dash: [max(2, CGFloat(cut.dash) * long),
                                           max(2, CGFloat(cut.gap) * long)])
            ctx.stroke(path, with: .color(Color(hex: cut.colorHex).opacity(cut.opacity)), style: style)
        }
        .frame(width: sheet.width, height: sheet.height)
        .allowsHitTesting(false)
    }
}
