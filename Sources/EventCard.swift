import SwiftUI
import AppKit

/// Admin › Event — picks which client the next session belongs to, and creates
/// new bookings. Sessions cannot start without one, which is what keeps each
/// client's photographs in their own folder and their own album on the site.
struct EventCard: View {
    @ObservedObject var c: BoothController
    @State private var showingNew = false
    @State private var showingEdit = false
    @State private var confirmDelete = false

    var body: some View {
        let accent = Palette.ink
        let active = c.activeEvent

        SectionCard(title: "Event",
                    accessory: AnyView(
                        HStack(spacing: 6) {
                            StatusDot(tint: active == nil ? Palette.statusWarn : Palette.statusOK,
                                      pulsing: active == nil)
                            Text(active == nil ? "None selected" : "Active".uppercased())
                                .font(VHS.mono(10, .semibold))
                                .tracking(0.8)
                                .foregroundStyle(active == nil ? Palette.statusWarn : Palette.statusOK)
                        })) {

            if let e = active {
                VStack(alignment: .leading, spacing: 3) {
                    Text(e.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(e.displayDate)
                        if !e.client.isEmpty { Text("·"); Text(e.client) }
                        if !e.venue.isEmpty { Text("·"); Text(e.venue) }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textDim)
                    .lineLimit(1)
                    Text(e.id)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.textDim.opacity(0.65))
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

                let count = c.storage.sessions(inEvent: e.id).count
                let photos = c.storage.sessions(inEvent: e.id).reduce(0) { $0 + $1.photos.count }
                let prints = c.printCounts(forEvent: e.id)
                HStack {
                    Text("\(count) session\(count == 1 ? "" : "s") · \(photos) photo\(photos == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textDim)
                    Spacer()
                }

                // Sheets, not sessions: copies are what empties a paper
                // cartridge, and the number the operator is really watching is
                // how many are left in the pack.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(prints.printed)")
                        .font(.system(size: 26, weight: .semibold))
                        .monospacedDigit()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(prints.printed == 1 ? "print out" : "prints out")
                            .font(.system(size: 11, weight: .medium))
                        if prints.pending > 0 || prints.failed > 0 {
                            HStack(spacing: 6) {
                                if prints.pending > 0 {
                                    Text("\(prints.pending) in the queue")
                                        .foregroundStyle(Palette.statusWarn)
                                }
                                if prints.failed > 0 {
                                    Text("\(prints.failed) failed")
                                        .foregroundStyle(Palette.statusBad)
                                }
                            }
                            .font(.system(size: 10))
                        } else {
                            Text("this event")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.textDim)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "calendar.badge.plus")
                        .foregroundStyle(Palette.statusWarn)
                    Text("No event yet. Create one so this booking's photographs stay separate from the last client's.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !c.storage.events.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Switch event").font(.system(size: 12, weight: .medium))
                    Picker("", selection: Binding(
                        get: { c.activeEvent?.id ?? "" },
                        set: { c.setActiveEvent($0) })) {
                            ForEach(c.storage.events) { e in
                                Text("\(e.name) — \(e.displayDate)").tag(e.id)
                            }
                    }
                    .labelsHidden()
                }
            }

            Button {
                showingNew = true
            } label: {
                Label("New Event", systemImage: "plus.circle.fill")
            }
            .buttonStyle(PrimaryButtonStyle(tint: accent))

            if active != nil {
                HStack(spacing: 8) {
                    Button("Edit Details") { showingEdit = true }
                        .buttonStyle(QuietButtonStyle())
                    Button("Open Folder") {
                        if let e = c.activeEvent {
                            NSWorkspace.shared.open(c.storage.eventDirectory(e.id))
                        }
                    }
                    .buttonStyle(QuietButtonStyle())
                }
                Button("Delete Event…") { confirmDelete = true }
                    .buttonStyle(QuietButtonStyle(destructive: true))
            }
        }
        .sheet(isPresented: $showingNew) {
            EventForm(title: "New Event", initial: nil) { name, client, venue, date, notes in
                c.createEvent(name: name, client: client, venue: venue, date: date, notes: notes)
                showingNew = false
            } onCancel: { showingNew = false }
        }
        .sheet(isPresented: $showingEdit) {
            if let e = c.activeEvent {
                EventForm(title: "Edit Event", initial: e) { name, client, venue, date, notes in
                    var updated = e
                    updated.name = name
                    updated.client = client
                    updated.venue = venue
                    updated.date = date
                    updated.notes = notes
                    c.updateEvent(updated)
                    showingEdit = false
                } onCancel: { showingEdit = false }
            }
        }
        .alert("Delete this event?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) {
                if let e = c.activeEvent { c.deleteEvent(e) }
            }
        } message: {
            if let e = c.activeEvent {
                let n = c.storage.sessions(inEvent: e.id).count
                Text("“\(e.name)” and its \(n) session\(n == 1 ? "" : "s") will be moved to the Trash. Anything already uploaded stays on the site.")
            }
        }
    }
}

// MARK: - Form

struct EventForm: View {
    let title: String
    let initial: EventRecord?
    let onSave: (String, String, String, Date, String) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var client = ""
    @State private var venue = ""
    @State private var date = Date()
    @State private var notes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))

            field("Event name", "Cruz & Santos Wedding", $name)
            field("Client", "Maria Cruz", $client)
            field("Venue", "Blue Leaf Filipinas", $venue)

            VStack(alignment: .leading, spacing: 4) {
                Text("Date").font(.system(size: 12, weight: .medium))
                DatePicker("", selection: $date, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.field)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Notes").font(.system(size: 12, weight: .medium))
                TextEditor(text: $notes)
                    .font(.system(size: 12))
                    .frame(height: 56)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.hairline)
                        .allowsHitTesting(false))
            }

            if initial == nil, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Folder: \(EventRecord.makeSlug(name: name, date: date))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.textDim)
                    .lineLimit(1).truncationMode(.middle)
            }

            HStack(spacing: 8) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(QuietButtonStyle())
                Button(initial == nil ? "Create" : "Save") {
                    onSave(name, client, venue, date, notes)
                }
                .buttonStyle(PrimaryButtonStyle(tint: .accentColor))
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            if let e = initial {
                name = e.name; client = e.client; venue = e.venue; date = e.date; notes = e.notes
            }
        }
    }

    private func field(_ label: String, _ placeholder: String, _ binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .medium))
            TextField(placeholder, text: binding).textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Event tracker

/// What this event has produced and what it has cost, with the report that goes
/// to the client — or to the accounts — one press away.
struct EventTrackerCard: View {
    @ObservedObject var c: BoothController
    @State private var exporting = false

    var body: some View {
        SectionCard(title: "Event Tracker") {
            if let event = c.activeEvent {
                let r = c.report(for: event)

                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    figure("\(r.clients)", "clients")
                    Spacer(minLength: 8)
                    figure("\(r.photographs)", "photos")
                    Spacer(minLength: 8)
                    figure("\(r.printed)", r.printed == 1 ? "sheet" : "sheets")
                    Spacer(minLength: 8)
                    figure(r.money(r.cost), "in paper")
                }
                .padding(.vertical, 2)

                if r.pending > 0 || r.failed > 0 {
                    HStack(spacing: 10) {
                        if r.pending > 0 {
                            Text("\(r.pending) queued")
                                .foregroundStyle(Palette.statusWarn)
                        }
                        if r.failed > 0 {
                            Text("\(r.failed) failed")
                                .foregroundStyle(Palette.statusBad)
                        }
                        Text("— not counted").foregroundStyle(Palette.textDim)
                    }
                    .font(.system(size: 11))
                }

                if !r.layoutCounts.isEmpty {
                    Divider().opacity(0.4)
                    OSDLabel(text: "Layouts used", size: 10, color: Palette.textDim, tracking: 0.22)
                    ForEach(r.layoutCounts, id: \.name) { entry in
                        HStack {
                            Text(entry.name).font(.system(size: 12))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(entry.count)")
                                .font(.system(size: 12, weight: .semibold))
                                .monospacedDigit()
                        }
                    }
                }

                Divider().opacity(0.4)

                LabeledRow(label: "Cost a sheet",
                           help: "Paper and ink together, which is how SELPHY packs are sold. The running total and the report both use it.") {
                    HStack(spacing: 6) {
                        TextField("", text: Binding(
                            get: { c.settingsService.settings.currencySymbol },
                            set: { c.settingsService.settings.currencySymbol = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 44)
                        TextField("", value: Binding(
                            get: { c.settingsService.settings.costPerSheet },
                            set: { c.settingsService.settings.costPerSheet = max(0, $0) }),
                            format: .number.precision(.fractionLength(0...2)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Button {
                    export(event)
                } label: {
                    Label("Export Report (PDF)…", systemImage: "doc.richtext")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(r.clients == 0)

                Text(r.clients == 0
                     ? "Nothing to report yet — the first finished session starts the tally."
                     : "One page: who was photographed, which layout they had, what printed, and what it cost.")
                    .font(.system(size: 11)).foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Choose an event and its tally appears here.")
                    .font(.system(size: 11)).foregroundStyle(Palette.textDim)
            }
        }
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Palette.textDim)
        }
    }

    private func export(_ event: EventRecord) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(event.id)-report.pdf"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if c.exportReport(for: event, to: url) != nil {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

// MARK: - Rehearsal

/// Runs a whole evening against the real camera and the real site, with the
/// printer switched off.
struct DryRunCard: View {
    @ObservedObject var c: BoothController
    @State private var customers = 3
    @State private var cycle = true
    @State private var uploads = true

    var body: some View {
        let running = c.isDryRunning
        SectionCard(title: "Dry Run",
                    accessory: AnyView(
                        HStack(spacing: 6) {
                            StatusDot(tint: running ? Palette.statusWarn : Palette.textDim,
                                      pulsing: running)
                            Text((running ? "Running" : "Idle").uppercased())
                                .font(VHS.mono(10, .semibold))
                                .tracking(0.8)
                                .foregroundStyle(running ? Palette.statusWarn : Palette.textDim)
                        })) {

            Text("Photographs imaginary guests with the camera that is connected, composes every layout, builds the loop and the film, and publishes for real — but prints nothing. Everything lands in its own “Dry run” event, so no client's folder or album is touched.")
                .font(.system(size: 11)).foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)

            LabeledRow(label: "Customers",
                       help: "How many groups to photograph, one after another.") {
                IntStepper(value: $customers, range: 1...20)
            }

            LabeledRow(label: "Every layout in turn",
                       help: "Each guest gets the next arrangement — \(c.dryRunLayouts.count) to work through, the three built-ins and your own. Off uses whichever layout is selected now.") {
                Toggle("", isOn: $cycle).labelsHidden()
            }

            LabeledRow(label: "Upload for real",
                       help: "Publishes each session to the gallery exactly as an event would, so the queue, the pages and the codes are all exercised. Switch it off to rehearse somewhere with no signal.") {
                Toggle("", isOn: $uploads).labelsHidden()
            }

            if c.settings.cameraBackend != .dslr {
                Label("The camera is set to \(c.settings.cameraBackend.title), so this will not test the USB link.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.statusWarn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let p = c.dryRun {
                Divider().opacity(0.4)
                if let failure = p.failure {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Stopped at customer \(p.customer) of \(p.total)")
                            .font(.system(size: 12, weight: .semibold))
                        Text(failure)
                            .font(.system(size: 11)).foregroundStyle(Palette.statusBad)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if p.isFinished {
                    Text("Finished — \(p.total) customer\(p.total == 1 ? "" : "s"), nothing printed.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.statusOK)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Customer \(p.customer) of \(p.total) · \(p.layout)")
                            .font(.system(size: 12, weight: .semibold))
                        Text(p.note)
                            .font(.system(size: 11)).foregroundStyle(Palette.textDim)
                        ProgressView(value: Double(p.customer - 1), total: Double(max(1, p.total)))
                            .progressViewStyle(.linear)
                    }
                }
            }

            if running {
                Button("Stop") { c.stopDryRun() }
                    .buttonStyle(QuietButtonStyle(destructive: true))
            } else {
                Button("Start Dry Run") {
                    c.clearDryRun()
                    c.startDryRun(DryRunPlan(customers: customers, cycleLayouts: cycle,
                                             uploads: uploads))
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!c.cameraState.isReady || c.state.isSessionActive)
            }
        }
    }
}

// MARK: - Serving from this Mac

/// Handing photographs out over the venue's own wifi, with no internet at all.
///
/// The address is the whole card: it is what fifty people are about to scan,
/// and it changes with the network, so it is shown plainly and re-read rather
/// than remembered.
struct LocalGalleryCard: View {
    @ObservedObject var c: BoothController

    var body: some View {
        let on = c.settings.localServeEnabled
        let ready = on && c.localServing && c.localAddress != nil
        SectionCard(title: "Photos Over Local Wifi",
                    accessory: AnyView(
                        HStack(spacing: 6) {
                            StatusDot(tint: !on ? Palette.textDim
                                             : (ready ? Palette.statusOK : Palette.statusWarn),
                                      pulsing: on && !ready)
                            Text((!on ? "Off" : (ready ? "Serving" : "Not reachable")).uppercased())
                                .font(VHS.mono(10, .semibold))
                                .tracking(0.8)
                                .foregroundStyle(!on ? Palette.textDim
                                                     : (ready ? Palette.statusOK : Palette.statusWarn))
                        })) {

            LabeledRow(label: "Serve from this Mac",
                       help: "Guests scan the code on the screen and get their photographs straight off this Mac, over whatever wifi the booth is on. No internet is needed — the network just has to exist, and their phones have to be on it.") {
                Toggle("", isOn: Binding(
                    get: { c.settingsService.settings.localServeEnabled },
                    set: { c.settingsService.settings.localServeEnabled = $0 }))
                    .labelsHidden()
            }

            if on {
                VStack(alignment: .leading, spacing: 4) {
                    OSDLabel(text: "Address guests reach", size: 10, color: Palette.textDim, tracking: 0.22)
                    Text(c.localAddress.map { "http://\($0):\(c.settings.localServePort)" }
                         ?? "This Mac is on no network — connect it to the booth's wifi.")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(c.localAddress == nil ? Palette.statusWarn : Palette.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let err = c.localServeError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.statusBad)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LabeledRow(label: "Port",
                           help: "Change it only if something else on this Mac already answers on 8080.") {
                    IntStepper(value: Binding(
                        get: { c.settingsService.settings.localServePort },
                        set: { c.settingsService.settings.localServePort = $0 }),
                        range: 1024...65535)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Fixed address (optional)").font(.system(size: 12, weight: .medium))
                    TextField("e.g. 192.168.8.10 or photobooth.local", text: Binding(
                        get: { c.settingsService.settings.localServeHost },
                        set: { c.settingsService.settings.localServeHost = $0 }))
                        .textFieldStyle(.roundedBorder)
                    Text("Leave empty and the booth uses whatever address it has right now. Fill it in if you always bring the same router and gave this Mac a fixed address.")
                        .font(.system(size: 11)).foregroundStyle(Palette.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().opacity(0.4)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Wifi guests join").font(.system(size: 12, weight: .medium))
                    TextField("Network name", text: Binding(
                        get: { c.settingsService.settings.localWiFiSSID },
                        set: { c.settingsService.settings.localWiFiSSID = $0 }))
                        .textFieldStyle(.roundedBorder)
                    TextField("Password (leave empty if open)", text: Binding(
                        get: { c.settingsService.settings.localWiFiPassword },
                        set: { c.settingsService.settings.localWiFiPassword = $0 }))
                        .textFieldStyle(.roundedBorder)
                    Text("Puts a “join wifi” code on the finish screen. Phones read it from the camera and offer to join, which is the step most guests give up on.")
                        .font(.system(size: 11)).foregroundStyle(Palette.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let wifi = c.wifiQRImage {
                    HStack(spacing: 10) {
                        Image(nsImage: wifi)
                            .resizable().interpolation(.none)
                            .frame(width: 64, height: 64)
                            .padding(4)
                            .background(Color.white)
                        Text("This is the code guests see. Scan it yourself to check it joins.")
                            .font(.system(size: 11)).foregroundStyle(Palette.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider().opacity(0.4)

                Text("The code on the screen points here. The code printed on the strip keeps pointing at the online page, because this address stops working when the booth is packed away — the upload queue publishes it when you next have internet.")
                    .font(.system(size: 11)).foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Gallery site card

struct GallerySiteCard: View {
    @ObservedObject var c: BoothController
    @ObservedObject var uploader: UploadService

    var body: some View {
        let accent = Palette.ink
        let tint: Color = {
            switch uploader.reachability {
            case .online: return Palette.statusOK
            case .offline: return Palette.statusWarn
            case .unknown: return Palette.textDim
            }
        }()

        SectionCard(title: "Gallery Site",
                    accessory: AnyView(
                        HStack(spacing: 6) {
                            StatusDot(tint: tint, pulsing: uploader.isDraining)
                            Text(c.settings.uploadEnabled ? uploader.reachability.label : "Off".uppercased())
                                .font(VHS.mono(10, .semibold))
                                .tracking(0.8)
                                .foregroundStyle(tint)
                                .lineLimit(1)
                        })) {

            Toggle("Upload finished sessions automatically", isOn: Binding(
                get: { c.settingsService.settings.uploadEnabled },
                set: { c.settingsService.settings.uploadEnabled = $0 }))
                .font(.system(size: 12))

            Picker("", selection: Binding(
                get: { c.settingsService.settings.galleryHost },
                set: { c.settingsService.settings.galleryHost = $0 })) {
                    ForEach(GalleryHost.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

            if c.settings.galleryHost != .cloudinary {
            VStack(alignment: .leading, spacing: 4) {
                Text("Site address").font(.system(size: 12, weight: .medium))
                TextField(c.settings.galleryHost
                          != .server ? "https://yourname.github.io/photos"
                          : "https://gallery.example.com", text: Binding(
                    get: { c.settingsService.settings.uploadBaseURL },
                    set: { c.settingsService.settings.uploadBaseURL = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            }

            if c.settings.galleryHost == .cloudinary {
                CloudinaryRows(c: c)

                Divider().opacity(0.4)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Session webpages").font(.system(size: 12, weight: .semibold))
                    Text("Cloudinary will not show a webpage — it hands HTML over as a download. Each session's page is published to GitHub Pages instead, with its photographs still loading from Cloudinary. Leave this empty and guests get the print image, as before.")
                        .font(.system(size: 11)).foregroundStyle(Palette.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Page site address").font(.system(size: 12, weight: .medium))
                    TextField("https://yourname.github.io/photos", text: Binding(
                        get: { c.settingsService.settings.uploadBaseURL },
                        set: { c.settingsService.settings.uploadBaseURL = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                GitHubPagesRows(c: c)
            } else if c.settings.galleryHost == .githubPages {
                GitHubPagesRows(c: c)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Upload key").font(.system(size: 12, weight: .medium))
                    SecureField("From the site's BOOTH_KEY", text: Binding(
                        get: { c.settingsService.settings.uploadAPIKey },
                        set: { c.settingsService.settings.uploadAPIKey = $0 }))
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: 12) {
                Toggle("Originals", isOn: Binding(
                    get: { c.settingsService.settings.uploadOriginals },
                    set: { c.settingsService.settings.uploadOriginals = $0 }))
                Toggle("Prints", isOn: Binding(
                    get: { c.settingsService.settings.uploadPrints },
                    set: { c.settingsService.settings.uploadPrints = $0 }))
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))

            VStack(alignment: .leading, spacing: 4) {
                LabeledRow(label: "Ask guests to follow",
                           help: "Shown before the photographs, once per phone. Leave it empty and nobody is asked anything.") {
                    HStack(spacing: 4) {
                        Text("@").font(.system(size: 12)).foregroundStyle(Palette.textDim)
                        TextField("yourbooth", text: Binding(
                            get: { c.settingsService.settings.instagramHandle },
                            set: { c.settingsService.settings.instagramHandle =
                                    $0.trimmingCharacters(in: CharacterSet(charactersIn: " @/")) }))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                    }
                }
                if !c.settings.instagramHandle.isEmpty {
                    Text("A door with a sign on it, not a lock: the page shows the handle and opens Instagram, then lets them through. Whether somebody actually follows is between them and Instagram — checking would mean every guest signing into Instagram through the booth.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            LabeledRow(label: "Tell guests they have",
                       help: "Printed on every page as “save them now”. Nothing is deleted automatically — this is a promise you keep, not a timer. Set it to 0 to say nothing.") {
                Picker("", selection: Binding(
                    get: { c.settingsService.settings.photoRetentionDays },
                    set: { c.settingsService.settings.photoRetentionDays = $0 })) {
                        Text("No notice").tag(0)
                        Text("24 hours").tag(1)
                        Text("One week").tag(7)
                        Text("Two weeks").tag(14)
                        Text("Three weeks").tag(21)
                        Text("A month").tag(30)
                }
                .labelsHidden().frame(width: 150)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Link the whole album from each session page", isOn: Binding(
                    get: { c.settingsService.settings.linkAlbumFromSessions },
                    set: { c.settingsService.settings.linkAlbumFromSessions = $0 }))
                    .font(.system(size: 12))
                Text(c.settings.linkAlbumFromSessions
                     ? "Every guest's page opens onto the album, so anyone who scans a strip can see every other group's photographs from this event."
                     : "Each guest sees their own session and nothing else. The album link stays here in the admin, to send to whoever booked the booth.")
                    .font(.system(size: 11))
                    .foregroundStyle(c.settings.linkAlbumFromSessions ? Palette.statusWarn : Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().opacity(0.4)

            HStack {
                Label("\(uploader.pendingCount) waiting", systemImage: "tray.full")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(uploader.pendingCount > 0 ? Palette.statusWarn : .secondary)
                Spacer()
                if let s = uploader.lastSuccessAt {
                    Text("last \(s.clockStamp)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.textDim.opacity(0.65))
                }
            }

            if let current = uploader.currentUpload {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Uploading \(current)…")
                        .font(.system(size: 11)).foregroundStyle(Palette.textDim)
                }
            }

            if let firstError = uploader.queue.compactMap(\.lastError).first {
                Text(firstError)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.statusWarn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(c.settings.galleryHost != .server
                 ? "No internet at the venue is fine — sessions wait on disk and go up when the Mac is next online."
                 : "No internet at the venue is fine — sessions stay queued on disk and upload when the Mac is next online. You can also drag a session folder into the site's Upload page.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Test Connection") { c.checkGallerySite() }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(c.settings.galleryHost == .server
                              ? c.settings.uploadBaseURL.isEmpty
                              : (c.settings.galleryHost == .cloudinary && c.cloudinary == nil))
                Button("Upload Now") { c.retryUploads() }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(uploader.pendingCount == 0)
            }

            if !c.settings.uploadBaseURL.isEmpty, c.settings.galleryHost != .cloudinary {
                Button {
                    if let u = URL(string: c.settings.uploadBaseURL) { NSWorkspace.shared.open(u) }
                } label: {
                    Label("Open Gallery", systemImage: "safari")
                }
                .buttonStyle(PrimaryButtonStyle(tint: accent))
            }
        }
    }
}

/// The GitHub Pages half of the Gallery Site card.
///
/// The site is a git repository, so this is mostly about pointing the app at a
/// folder and telling the operator the two things only they can do: make the
/// repository on github.com, and authorise this Mac to push to it once.
private struct GitHubPagesRows: View {
    @ObservedObject var c: BoothController
    @State private var size: (files: Int, bytes: Int64) = (0, 0)
    @State private var busy = false

    private var repoReady: Bool {
        guard let url = c.pagesRepoURL else { return false }
        return PagesPublisher.isRepo(url)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Site folder").font(.system(size: 12, weight: .medium))
                HStack(spacing: 8) {
                    Text(c.settings.pagesRepoPath.isEmpty ? "Not chosen" : c.settings.pagesRepoPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(c.settings.pagesRepoPath.isEmpty ? Palette.statusWarn : Palette.textDim)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 0)
                    Button("Choose…") { chooseFolder() }
                        .buttonStyle(QuietButtonStyle())
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("GitHub repository").font(.system(size: 12, weight: .medium))
                TextField("https://github.com/yourname/photos.git", text: Binding(
                    get: { c.settingsService.settings.pagesRemote },
                    set: { c.settingsService.settings.pagesRemote = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }

            HStack(spacing: 8) {
                Button(repoReady ? "Update Site Files" : "Set Up Site") {
                    c.setUpPagesSite(remote: c.settings.pagesRemote)
                    refresh()
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(c.settings.pagesRepoPath.isEmpty)

                Button("Publish Everything") { c.republishAllToPages() }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(!repoReady)

                if repoReady {
                    Button("Open Folder") {
                        if let u = c.pagesRepoURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            }

            if repoReady {
                HStack(spacing: 6) {
                    Image(systemName: "shippingbox").font(.system(size: 10))
                    Text("\(size.files) files · \(ByteCountFormatter.string(fromByteCount: size.bytes, countStyle: .file)) published")
                    Spacer(minLength: 0)
                    Button("Refresh") { refresh() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.textDim)
                }
                .font(.system(size: 11))
                .foregroundStyle(size.bytes > 900_000_000 ? Palette.statusWarn : Palette.textDim)

                if size.bytes > 900_000_000 {
                    Text("GitHub asks that repositories stay under 1 GB. Start a fresh repository for the next event.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.statusWarn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // The steps the app cannot do for the operator: it has no GitHub
            // account, and it must never be handed a password or a token.
            if !repoReady || c.settings.pagesRemote.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("ONE-TIME SET-UP").font(VHS.mono(9, .semibold)).tracking(0.8).foregroundStyle(Palette.textDim)
                    Text("1. On github.com, create a public repository — call it photos.")
                    Text("2. Paste its address above and press Set Up Site.")
                    Text("3. In Terminal, run: git -C <site folder> push -u origin main")
                    Text("   GitHub asks for your username and a personal access token, once.")
                    Text("4. On github.com: Settings › Pages › deploy from branch main.")
                    Text("5. Put the address GitHub gives you in Site address above.")
                }
                .font(.system(size: 11))
                .foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text("A free GitHub account cannot serve a private site: everything published here is public to anyone with the address, and the repository is browsable. Addresses are unguessable and search engines are asked to stay away — that is obscurity, not privacy.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.statusWarn)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { refresh() }
    }

    private func refresh() {
        guard let pub = c.pagesPublisher(), repoReady else { size = (0, 0); return }
        Task.detached(priority: .utility) {
            let s = pub.siteSize()
            await MainActor.run { size = s }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose an empty folder for the website."
        if panel.runModal() == .OK, let url = panel.url {
            c.settingsService.settings.pagesRepoPath = url.path
            refresh()
        }
    }
}

/// The Cloudinary half of the Gallery Site card.
///
/// Two fields and nothing secret: an unsigned preset is the whole credential, so
/// there is no API secret to store, leak or rotate.
private struct CloudinaryRows: View {
    @ObservedObject var c: BoothController

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Cloud name").font(.system(size: 12, weight: .medium))
                TextField("dxyz123ab", text: Binding(
                    get: { c.settingsService.settings.cloudinaryCloudName },
                    set: { c.settingsService.settings.cloudinaryCloudName = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Unsigned upload preset").font(.system(size: 12, weight: .medium))
                TextField("photobooth", text: Binding(
                    get: { c.settingsService.settings.cloudinaryPreset },
                    set: { c.settingsService.settings.cloudinaryPreset = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

            if let cloud = c.cloudinary {
                VStack(alignment: .leading, spacing: 2) {
                    Text("A guest's code opens").font(.system(size: 11)).foregroundStyle(Palette.textDim)
                    Text(cloud.photoURL(token: "abcd123456", fileName: "print.jpg")?.absoluteString ?? "")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.textDim.opacity(0.8))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("The QR code opens the session's print — one image holding every photograph from that session, which guests save with a long press. Cloudinary sends HTML and SVG as downloads rather than pages, so an image is the only thing a scanned code can usefully open here.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 3) {
                Text("THE PRESET NEEDS").font(VHS.mono(9, .semibold)).tracking(0.8).foregroundStyle(Palette.textDim)
                Text("Signing mode: Unsigned")
                Text("Resource type: Image — only photographs go to Cloudinary")
                Text("Unique filename: OFF — the address must stay predictable")
                Text("Overwrite: ON and Invalidate: ON — so a retake replaces the old photo")
            }
            .font(.system(size: 11))
            .foregroundStyle(Palette.textDim)
            .fixedSize(horizontal: false, vertical: true)

            Text("Anyone with the address can open a session. Cloudinary serves it publicly and the app cannot make it private — the token in the address is all that keeps it obscure.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.statusWarn)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Album pages: one private page per event, for the client rather than the guests.
struct AlbumCard: View {
    @ObservedObject var c: BoothController
    @State private var revealPassword = false

    private var event: EventRecord? { c.activeEvent }

    var body: some View {
        let accent = Palette.ink

        SectionCard(title: "Album Page",
                    accessory: AnyView(
                        Text(c.settings.albumOutputPath.isEmpty ? "NO FOLDER" : "READY")
                            .font(VHS.mono(10, .semibold))
                            .tracking(0.8)
                            .foregroundStyle(c.settings.albumOutputPath.isEmpty ? Palette.statusWarn : Palette.statusOK)
                    )) {

            Text("A private page for the whole event — every session, in order, behind a password you hand to the client.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Save pages to").font(.system(size: 12, weight: .medium))
                HStack(spacing: 8) {
                    Text(c.settings.albumOutputPath.isEmpty ? "Not chosen" : c.settings.albumOutputPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(c.settings.albumOutputPath.isEmpty ? Palette.statusWarn : Palette.textDim)
                        .lineLimit(1).truncationMode(.head)
                    Spacer(minLength: 0)
                    Button("Choose…") { chooseFolder() }
                        .buttonStyle(QuietButtonStyle())
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Album web address").font(.system(size: 12, weight: .medium))
                TextField("https://photos.example.com/albums", text: Binding(
                    get: { c.settingsService.settings.albumBaseURL },
                    set: { c.settingsService.settings.albumBaseURL = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Text("The folder you upload the album pages to. Nothing here uploads them — this is only how the app works out the address for the link and its QR code.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let event {
                Divider().opacity(0.4)

                // The code for the page itself — what a client scans to see the
                // whole event online.
                if let url = c.albumWebURL(for: event) {
                    HStack(alignment: .top, spacing: 12) {
                        if let qr = c.makeAlbumQR(for: event, side: 220) {
                            Image(nsImage: qr)
                                .resizable()
                                .interpolation(.none)
                                .frame(width: 92, height: 92)
                                .padding(5)
                                .background(Color.white)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text("ALBUM CODE").font(VHS.mono(9, .semibold)).tracking(0.8)
                                .foregroundStyle(Palette.textDim)
                            Text(url.absoluteString)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Palette.textDim)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Open") { NSWorkspace.shared.open(url) }
                                .buttonStyle(QuietButtonStyle())
                        }
                        Spacer(minLength: 0)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Password for \(event.name)").font(.system(size: 12, weight: .medium))
                    HStack(spacing: 8) {
                        // Shown in the clear on purpose: this is the operator's
                        // own console, and a password they cannot read is a
                        // password they cannot give to the client.
                        Group {
                            if revealPassword {
                                TextField("", text: passwordBinding(event))
                            } else {
                                SecureField("", text: passwordBinding(event))
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                        Button(revealPassword ? "Hide" : "Show") { revealPassword.toggle() }
                            .buttonStyle(QuietButtonStyle())
                    }
                }

                HStack(spacing: 8) {
                    Button("New Password") {
                        c.setAlbumPassword(AlbumCrypto.suggestPassword(), for: event)
                        revealPassword = true
                    }
                    .buttonStyle(QuietButtonStyle())
                    Button("Copy Name & Password") { c.copyAlbumDetails(for: event) }
                        .buttonStyle(QuietButtonStyle())
                }

                Button {
                    c.previewAlbum(for: event)
                } label: {
                    Label("Build & Preview Album", systemImage: "rectangle.stack")
                }
                .buttonStyle(PrimaryButtonStyle(tint: accent))
                .disabled(c.settings.albumOutputPath.isEmpty || c.cloudinary == nil)

                HStack(spacing: 8) {
                    Button("Build All Events") { c.buildAllAlbums() }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(c.settings.albumOutputPath.isEmpty || c.cloudinary == nil)
                    if let url = c.albumFileURL(for: event),
                       FileManager.default.fileExists(atPath: url.path) {
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            .buttonStyle(QuietButtonStyle())
                    }
                }

                Text("Preview opens through a small server on this Mac only — a page opened straight from a file cannot unlock, because browsers withhold the decryption tools from file addresses. Put the page on any https address to send it to a client.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Only sessions already on Cloudinary go into the page — anything still queued is left out rather than shown as a broken picture. Rebuild after the queue drains.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Pick an event above to give it an album.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.statusWarn)
            }

            Text("The page holds nothing readable without the password — not the photographs, not even the client's name. Anyone who is given a direct photo address keeps it, so treat the password as the lock on the front door, not on every window.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func passwordBinding(_ event: EventRecord) -> Binding<String> {
        Binding(get: { c.storage.event(event.id)?.albumPassword ?? event.albumPassword },
                set: { c.setAlbumPassword($0, for: event) })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Where should album pages be saved?"
        if panel.runModal() == .OK, let url = panel.url {
            c.settingsService.settings.albumOutputPath = url.path
        }
    }
}
