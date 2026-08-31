import SwiftUI
import AppKit
import QuickLook

struct GalleryTab: View {
    @ObservedObject var c: BoothController
    @State private var selection: SessionRecord?
    @State private var pendingDelete: SessionRecord?
    @State private var search = ""
    @State private var eventFilter: String = ""      // "" = every event

    var body: some View {
        GeometryReader { geo in
            // Below ~900pt the detail pane is stacked under the grid instead of beside it.
            if geo.size.width < 900 {
                VStack(spacing: 0) {
                    header
                    Divider()
                    eventChips
                    Divider()
                    grid
                    if let sel = boundSelection {
                        Divider()
                        SessionDetail(c: c, rec: sel, onDelete: { pendingDelete = sel })
                            .frame(height: min(360, geo.size.height * 0.45))
                    }
                }
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    HStack(spacing: 0) {
                        eventSidebar
                        Divider()
                        grid
                        if let sel = boundSelection {
                            Divider()
                            SessionDetail(c: c, rec: sel, onDelete: { pendingDelete = sel })
                                .frame(width: min(400, max(300, geo.size.width * 0.30)))
                        }
                    }
                }
            }
        }
        .confirmDeleteAlert(item: $pendingDelete) { rec in
            c.storage.delete(rec)
            if selection?.id == rec.id { selection = nil }
        }
    }

    /// Re-reads the record from storage so the pane reflects live print status.
    private var boundSelection: SessionRecord? {
        guard let id = selection?.id else { return nil }
        return c.storage.sessions.first { $0.id == id }
    }

    private var header: some View {
        HStack(spacing: 10) {
            TextField("Search by date or session ID…", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            Spacer()
            Text("\(filtered.count) session(s)")
                .font(.system(size: 11)).foregroundStyle(VHS.dim)
            Button("Reload") { c.storage.reload() }.buttonStyle(.bordered)
            Button("Open Folder") { NSWorkspace.shared.open(c.storage.eventsRoot) }.buttonStyle(.bordered)
        }
        .padding(12)
    }

    private var filtered: [SessionRecord] {
        var out = c.storage.sessions
        if !eventFilter.isEmpty { out = out.filter { $0.eventID == eventFilter } }
        if !search.isEmpty {
            out = out.filter {
                $0.id.localizedCaseInsensitiveContains(search)
                || (c.storage.event($0.eventID)?.name.localizedCaseInsensitiveContains(search) ?? false)
                || (c.storage.event($0.eventID)?.client.localizedCaseInsensitiveContains(search) ?? false)
            }
        }
        return out
    }

    /// Events that actually have sessions, plus the pre-events folder when it is
    /// not empty — an operator should never see an empty bucket they cannot explain.
    private var eventBuckets: [(id: String, name: String, count: Int)] {
        var out: [(String, String, Int)] = []
        for e in c.storage.events {
            out.append((e.id, e.name, c.storage.sessions(inEvent: e.id).count))
        }
        let unfiled = c.storage.sessions(inEvent: EventRecord.unfiledID).count
        if unfiled > 0 { out.append((EventRecord.unfiledID, "Unfiled", unfiled)) }
        return out
    }

    private var eventSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                bucketRow(id: "", name: "All events", count: c.storage.sessions.count)
                ForEach(eventBuckets, id: \.id) { b in
                    bucketRow(id: b.id, name: b.name, count: b.count)
                }
            }
            .padding(10)
        }
        .frame(width: 210)
    }

    private func bucketRow(id: String, name: String, count: Int) -> some View {
        let selected = eventFilter == id
        let accent = Color(hex: c.settings.accentHex)
        return Button {
            eventFilter = id
            selection = nil
        } label: {
            HStack(spacing: 7) {
                Image(systemName: id.isEmpty ? "square.grid.2x2"
                      : (id == EventRecord.unfiledID ? "tray" : "calendar"))
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? accent : .secondary)
                Text(name)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("\(count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(VHS.dim.opacity(0.65))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(selected ? accent.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var eventChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(id: "", name: "All")
                ForEach(eventBuckets, id: \.id) { b in chip(id: b.id, name: b.name) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func chip(id: String, name: String) -> some View {
        let selected = eventFilter == id
        let accent = Color(hex: c.settings.accentHex)
        return Button { eventFilter = id; selection = nil } label: {
            Text(name)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(selected ? accent.opacity(0.16) : Color.white.opacity(0.05), in: Capsule())
                .foregroundStyle(selected ? accent : .secondary)
        }
        .buttonStyle(.plain)
    }

    private var grid: some View {
        ScrollView {
            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(VHS.dim.opacity(0.65))
                    Text("No sessions yet")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(VHS.dim)
                    Text("Finished sessions appear here with their prints.")
                        .font(.system(size: 11)).foregroundStyle(VHS.dim.opacity(0.65))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 70)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 14)],
                          spacing: 14) {
                    ForEach(filtered) { rec in
                        SessionTile(c: c, rec: rec, selected: selection?.id == rec.id)
                            .onTapGesture { selection = rec }
                    }
                }
                .padding(14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SessionTile: View {
    @ObservedObject var c: BoothController
    let rec: SessionRecord
    let selected: Bool

    var body: some View {
        let accent = Color(hex: c.settings.accentHex)

        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                Rectangle().fill(Color.white.opacity(0.06))
                if let img = c.storage.thumbnail(for: rec) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(5)
                } else {
                    Image(systemName: "photo").font(.system(size: 22)).foregroundStyle(VHS.dim.opacity(0.65))
                }
            }
            .aspectRatio(2.0/3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(rec.startedAt.displayStamp)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                if let e = c.storage.event(rec.eventID) {
                    Text(e.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(hex: c.settings.accentHex))
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    Text("\(rec.photos.count) photo\(rec.photos.count == 1 ? "" : "s")")
                    Text("·")
                    Circle().fill(rec.printStatus.tint).frame(width: 6, height: 6)
                    Text(rec.printStatus.label).lineLimit(1)
                    if rec.uploadState != .notUploaded {
                        Image(systemName: rec.uploadState.glyph)
                            .font(.system(size: 9))
                            .foregroundStyle(rec.uploadState.tint)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(VHS.dim)
            }
        }
        .padding(8)
        .background(selected ? accent.opacity(0.12) : Color.white.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(selected ? accent : Palette.hairline, lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
    }
}

private struct SessionDetail: View {
    @ObservedObject var c: BoothController
    let rec: SessionRecord
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(rec.id)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Text(rec.startedAt.displayStamp)
                        .font(.system(size: 11)).foregroundStyle(VHS.dim)
                }

                infoGrid

                if let p = rec.printFileName {
                    let url = c.storage.directory(for: rec.id).appendingPathComponent(p)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("FINAL PRINT")
                            .font(.system(size: 10, weight: .semibold)).tracking(1)
                            .foregroundStyle(VHS.dim)
                        if let img = NSImage(contentsOf: url) {
                            Image(nsImage: img)
                                .resizable().aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.hairline))
                                .onTapGesture { NSWorkspace.shared.open(url) }
                        }
                    }
                }

                if GIFRenderer.enabled, let g = rec.gifFileName {
                    let url = c.storage.directory(for: rec.id).appendingPathComponent(g)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ANIMATED GIF")
                            .font(.system(size: 10, weight: .semibold)).tracking(1)
                            .foregroundStyle(VHS.dim)
                        if let img = NSImage(contentsOf: url) {
                            // Animating here, unlike on the guest screen: the
                            // console is a place the operator is looking, and
                            // a still GIF tells them nothing about the loop.
                            AnimatedImage(image: img)
                                .aspectRatio(img.size.width / max(1, img.size.height),
                                             contentMode: .fit)
                                .frame(maxWidth: 260)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.hairline))
                                .onTapGesture { NSWorkspace.shared.open(url) }
                        }
                    }
                }

                if !rec.photos.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ORIGINALS")
                            .font(.system(size: 10, weight: .semibold)).tracking(1)
                            .foregroundStyle(VHS.dim)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 74, maximum: 120), spacing: 6)],
                                  spacing: 6) {
                            ForEach(rec.photos) { p in
                                let url = p.url(in: c.storage.directory(for: rec.id))
                                ZStack(alignment: .bottomLeading) {
                                    if let img = NSImage(contentsOf: url) {
                                        Image(nsImage: img)
                                            .resizable().aspectRatio(contentMode: .fill)
                                            .frame(height: 62).clipped()
                                    } else {
                                        Color.white.opacity(0.08).frame(height: 62)
                                    }
                                    Text("\(p.index)")
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(.black.opacity(0.55), in: Capsule())
                                        .foregroundStyle(.white)
                                        .padding(3)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .onTapGesture { NSWorkspace.shared.open(url) }
                            }
                        }
                    }
                }

                if let err = rec.lastError {
                    Text(err)
                        .font(.system(size: 11)).foregroundStyle(VHS.rec)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 7) {
                    Button {
                        c.reprint(rec)
                    } label: {
                        Label("Reprint", systemImage: "printer.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle(tint: Color(hex: c.settings.accentHex)))
                    .disabled(rec.printFileName == nil || c.isPrintBusy || !c.printer.state.isReady)

                    HStack(spacing: 7) {
                        Button("Rebuild Print") { c.rebuildPrint(for: rec) }
                            .buttonStyle(QuietButtonStyle())
                            .disabled(rec.photos.isEmpty)
                        Button("Show in Finder") { c.storage.revealInFinder(rec) }
                            .buttonStyle(QuietButtonStyle())
                    }

                    if c.settings.uploadEnabled {
                        Button(rec.uploadState == .uploaded ? "Upload Again" : "Upload to Gallery") {
                            c.queueUpload(rec)
                        }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(rec.photos.isEmpty)
                    }

                    if !c.storage.events.isEmpty {
                        Menu("File under event…") {
                            ForEach(c.storage.events) { e in
                                if e.id != rec.eventID {
                                    Button(e.name) { c.storage.move(rec, toEvent: e.id) }
                                }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.vertical, 4)
                    }

                    Button("Delete Session…", action: onDelete)
                        .buttonStyle(QuietButtonStyle(destructive: true))
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.white.opacity(0.02))
    }

    private var infoGrid: some View {
        VStack(spacing: 5) {
            row("Event", c.storage.event(rec.eventID)?.name ?? rec.eventID)
            row("Layout", rec.layout.title)
            row("Photos", "\(rec.photos.count) of \(rec.layout.photoCount)")
            row("Copies", "\(rec.copies)")
            row("Print", rec.printStatus.label, tint: rec.printStatus.tint)
            row("Gallery", rec.uploadState.label, tint: rec.uploadState.tint)
            if let j = rec.printJobID { row("Job", j) }
            if let f = rec.finishedAt { row("Finished", f.displayStamp) }
        }
        .padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ k: String, _ v: String, tint: Color = .primary) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.system(size: 11)).foregroundStyle(VHS.dim)
            Spacer(minLength: 10)
            Text(v).font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Delete confirmation

private struct ConfirmDeleteModifier: ViewModifier {
    @Binding var item: SessionRecord?
    let onConfirm: (SessionRecord) -> Void

    func body(content: Content) -> some View {
        content.alert("Delete this session?",
                      isPresented: Binding(get: { item != nil },
                                           set: { if !$0 { item = nil } })) {
            Button("Cancel", role: .cancel) { item = nil }
            Button("Move to Trash", role: .destructive) {
                if let i = item { onConfirm(i) }
                item = nil
            }
        } message: {
            if let i = item {
                Text("\(i.photos.count) original photograph(s) and the final print for \(i.id) will be moved to the Trash.")
            }
        }
    }
}

extension View {
    func confirmDeleteAlert(item: Binding<SessionRecord?>,
                            onConfirm: @escaping (SessionRecord) -> Void) -> some View {
        modifier(ConfirmDeleteModifier(item: item, onConfirm: onConfirm))
    }
}
