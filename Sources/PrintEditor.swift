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
struct PrintEditorView: View {
    @ObservedObject var c: BoothController
    @ObservedObject var store: TemplateStore

    @State private var draft: PrintTemplate
    @State private var selection: String?
    @State private var dragOrigin: NormRect?
    @State private var proof: NSImage?
    @State private var dirty = false

    init(c: BoothController, store: TemplateStore) {
        self.c = c
        self.store = store
        let existing = c.activeTemplate
        _draft = State(initialValue: existing
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
                    .frame(width: 330)
            }
        }
        .background(Palette.canvas)
        .environment(\.colorScheme, .light)
        .environment(\.touchControls, c.settings.touchControls)
        .controlSize(c.settings.touchControls ? .extraLarge : .regular)
        .modifier(TouchToggleStyling(enabled: c.settings.touchControls))
        .tint(Palette.ink)
        .foregroundStyle(Palette.ink)
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
                .frame(width: 130)
            Button("Save") { save() }
                .buttonStyle(PrimaryButtonStyle())
                .frame(width: 120)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Palette.surfaceAlt)
    }

    // MARK: - Canvas

    private var canvasPane: some View {
        GeometryReader { geo in
            // The sheet keeps the printer's own proportions whatever the window
            // does, so nothing is arranged against a shape that will not print.
            let sheet = fit(CGSize(width: 4, height: 6), in: CGSize(width: geo.size.width - 48,
                                                                   height: geo.size.height - 48))
            ZStack {
                Color.clear
                sheetView(sheet)
                    .frame(width: sheet.width, height: sheet.height)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onTapGesture { selection = nil }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sheetView(_ sheet: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Color(hex: draft.backgroundHex)

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
        .overlay(Rectangle().stroke(Palette.hairline, lineWidth: 1).allowsHitTesting(false))
        .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
    }

    private func slotView(_ s: TemplateSlot, sheet: CGSize) -> some View {
        box(s.rect, sheet: sheet, id: s.id) {
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
        box(o.rect, sheet: sheet, id: o.id) {
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
            .offset(x: r.minX, y: r.minY)
    }

    private func moveGesture(id: String, sheet: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                selection = id
                if dragOrigin == nil { dragOrigin = rect(of: id) }
                guard var r = dragOrigin else { return }
                r.x += v.translation.width / sheet.width
                r.y += v.translation.height / sheet.height
                r.clamp()
                setRect(r, of: id)
            }
            .onEnded { _ in dragOrigin = nil; dirty = true }
    }

    private func resizeGesture(id: String, sheet: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if dragOrigin == nil { dragOrigin = rect(of: id) }
                guard var r = dragOrigin else { return }
                r.w += v.translation.width / sheet.width
                r.h += v.translation.height / sheet.height
                r.clamp()
                setRect(r, of: id)
            }
            .onEnded { _ in dragOrigin = nil; dirty = true }
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
                }

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

    /// Exact placement, for when a drag is not precise enough — or not possible.
    private func rectControls(_ id: String) -> some View {
        let binding: (WritableKeyPath<NormRect, Double>) -> Binding<Double> = { key in
            Binding(
                get: { self.rect(of: id)?[keyPath: key] ?? 0 },
                set: { v in
                    guard var r = self.rect(of: id) else { return }
                    r[keyPath: key] = v
                    r.clamp()
                    self.setRect(r, of: id)
                    self.dirty = true
                })
        }
        return Group {
            percentRow("Across", binding(\.x), range: 0...1)
            percentRow("Down", binding(\.y), range: 0...1)
            percentRow("Width", binding(\.w), range: 0.04...1)
            percentRow("Height", binding(\.h), range: 0.04...1)
        }
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
