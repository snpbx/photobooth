import Foundation
import AppKit
import SwiftUI
import Combine

/// The live camera picture, published on its own so that a preview frame does
/// not invalidate every view that happens to observe `BoothController`.
@MainActor
final class LivePreviewSource: ObservableObject {
    @Published private(set) var frame: NSImage?
    func set(_ image: NSImage?) { frame = image }
}

/// Owns the session state machine and wires the services together.
/// Every transition happens here so the UI only ever renders `state`.
///
/// The guest booth and the operator console are two independent windows driven by
/// this one controller, so the operator can watch the booth on a second display
/// while working in Admin.
@MainActor
final class BoothController: ObservableObject {

    // MARK: Published surface

    @Published private(set) var state: BoothState = .idle
    @Published private(set) var boothWindowOpen = false
    @Published private(set) var adminWindowVisible = true
    @Published private(set) var cameraState: CameraState = .disconnected
    /// The camera's live frames, deliberately kept off this object.
    ///
    /// `BoothController` is observed by the whole Admin console, and `@Published`
    /// invalidates every observer for *any* property that changes. With the
    /// preview living here, a frame arriving fifteen times a second re-evaluated
    /// the entire console — including the minimal one, which shows no camera at
    /// all. On a screen carried over USB that meant the whole display being
    /// re-encoded and shipped fifteen times a second while nothing on it had
    /// visibly changed, which is what made taps feel late.
    ///
    /// Held separately, only the views that actually draw the picture observe it.
    let livePreview = LivePreviewSource()

    /// Reading convenience for the controller's own logic and the offscreen
    /// harness. Not published: views must observe `livePreview` instead, which
    /// is the entire point of the split.
    var liveFrame: NSImage? { livePreview.frame }
    @Published private(set) var shotPreview: NSImage?
    @Published private(set) var currentSession: SessionRecord?
    @Published private(set) var sessionPrintImage: NSImage?
    /// The finished loop, held for the guest screen. NSImage animates a GIF on
    /// its own once it is in an NSImageView, which is what the finish screen uses.
    @Published private(set) var sessionGIF: NSImage?

    // MARK: - Motion capture for the GIF

    /// Preview frames from the run-up to each shot, keyed by shot number.
    ///
    /// The GIF animates the seconds *before* each shutter, and nothing else in
    /// the app has them: a capture yields one still. So the countdown's live
    /// view is recorded as it goes past.
    ///
    /// Frames are scaled down to the size they will occupy in the finished GIF
    /// the moment they arrive. Holding three seconds of 960px preview for eight
    /// shots would be hundreds of megabytes of pixels that are about to be
    /// thrown away; at cell size the same buffer is a few tens.
    @Published var banner: BannerMessage?
    @Published private(set) var detectedCameras: [String] = []
    /// What the camera body currently reports — ISO, aperture and the rest.
    /// Empty until something asks for it: reading them costs a USB round trip
    /// per setting, which is not worth paying on every console redraw.
    @Published private(set) var cameraSettings: [CameraSetting] = []
    @Published private(set) var cameraSettingsLoading = false
    /// The setting being written, so its own control can show the wait rather
    /// than freezing the whole card.
    @Published private(set) var cameraSettingBusy: String?
    @Published private(set) var cameraSettingsError: String?
    @Published private(set) var isPrintBusy = false
    /// Shot numbers the operator has marked for a retake, by clicking their
    /// number in Admin. Drained after the run, before the print is built.
    @Published private(set) var retakeQueue: Set<Int> = []
    /// QR code for the finished session's album page, built once per session.
    @Published private(set) var sessionQRImage: NSImage?
    /// QR code for the operator's own link — Instagram, a website — when the
    /// finish screen is set to show one.
    @Published private(set) var brandQRImage: NSImage?
    /// True while the finish screen is waiting for somebody to press the button.
    @Published private(set) var awaitingContinue = false
    /// True when the print for the finished session is built but deliberately
    /// not sent yet: with the finish screen holding, the same press that starts
    /// the next group is what releases their sheet to the printer.
    @Published private(set) var pendingPrint = false
    /// The shot number currently being re-taken, so the booth can say so for the
    /// whole cycle rather than only during the "RETAKE" card.
    @Published private(set) var retakingShot: Int?

    struct BannerMessage: Identifiable, Equatable {
        enum Kind { case info, warning, error }
        let id = UUID()
        let kind: Kind
        let text: String
        var tint: Color {
            switch kind {
            case .info: return VHS.amber
            case .warning: return .orange
            case .error: return .red
            }
        }
    }

    // MARK: Services

    let settingsService: SettingsService
    let templates = TemplateStore()

    /// The template every sheet is composed against, or nil for the built-in
    /// layouts.
    ///
    /// The event wins, then the booth's default. Resolved each time rather than
    /// cached, so deleting a template while it is in use falls back to the
    /// layouts instead of failing — a booth that prints the wrong arrangement is
    /// recoverable, one that prints nothing is not.
    var activeTemplate: PrintTemplate? {
        if let e = activeEvent, let t = templates.template(e.templateID) { return t }
        return templates.template(settings.activeTemplateID)
    }

    /// Whether the three arrangements the booth ships with are offered at all.
    ///
    /// They are there so a booth nobody has set up yet can still print
    /// something. The moment the operator has designed a layout of their own,
    /// the built-ins stop being a fallback and become three wrong answers
    /// sitting above the right one — so they go away, everywhere a layout is
    /// chosen.
    var showsBuiltInLayouts: Bool { templates.templates.isEmpty }

    /// Chooses a saved layout at whichever level applies: the booking being shot
    /// if there is one, otherwise the booth's own default.
    func useTemplate(_ id: String) {
        if let e = activeEvent {
            setTemplate(id, forEvent: e.id)
        } else {
            settingsService.settings.activeTemplateID = id
        }
    }

    /// Moves the booth off a built-in arrangement once the operator has layouts
    /// of their own, so the chooser never shows a list with nothing selected in
    /// it while the sheet quietly comes out in some older shape.
    func adoptOwnLayoutIfNeeded() {
        guard !showsBuiltInLayouts, activeTemplate == nil,
              let first = templates.templates.first else { return }
        useTemplate(first.id)
    }

    /// Goes back to one of the three built-in arrangements. Clears the template
    /// at both levels, because leaving one attached to the event would quietly
    /// override the choice just made.
    func useBuiltInLayout(_ layout: PrintLayout) {
        settingsService.settings.layout = layout
        settingsService.settings.activeTemplateID = ""
        if let e = activeEvent, !e.templateID.isEmpty { setTemplate("", forEvent: e.id) }
    }

    /// Reorders the operator's own layouts, one place at a time.
    ///
    /// The one they reach for most belongs at the top, where it can be hit
    /// without reading the others — on a phone or an arm's length away through
    /// the booth's own screen that is the whole difference.
    func moveTemplate(_ id: String, by offset: Int) {
        templates.move(id, by: offset)
        objectWillChange.send()
    }

    /// Removes a layout and detaches it from anything still pointing at it, so
    /// no booking is left referring to a template that is gone.
    func deleteTemplate(_ id: String) {
        let name = templates.template(id)?.name ?? id
        templates.delete(id)
        if settings.activeTemplateID == id { settingsService.settings.activeTemplateID = "" }
        for e in storage.events where e.templateID == id { setTemplate("", forEvent: e.id) }
        objectWillChange.send()
        log.info("Deleted print layout \(name)")
    }

    /// Attaches a layout to one booking, or clears it with an empty id.
    func setTemplate(_ id: String, forEvent eventID: String) {
        guard var e = storage.event(eventID) else { return }
        e.templateID = id
        storage.persist(event: e)
        objectWillChange.send()
        log.info(id.isEmpty ? "Cleared the print layout for \(e.name)"
                            : "Print layout \(templates.template(id)?.name ?? id) set for \(e.name)")
    }

    /// How many photographs the run in progress was started with. A session
    /// keeps the count it began with even if the layout is changed underneath
    /// it, because a guest halfway through four shots should not suddenly be
    /// asked for eight.
    private(set) var plannedShots: Int = 0

    /// What an event produced and what it cost, ready to show or export.
    ///
    /// Built from the session records every time rather than tallied as the
    /// night goes on: a second set of books can disagree with the first, and
    /// the records are what the operator would check anyway.
    func report(for event: EventRecord) -> EventReport {
        EventReport.build(event: event,
                          sessions: storage.sessions,
                          costPerSheet: max(0, settings.costPerSheet),
                          currency: settings.currencySymbol) { [weak self] session in
            self?.layoutName(for: session) ?? session.layout.title
        }
    }

    /// What the operator calls the sheet a session was printed on. A session
    /// records the built-in layout it started from, so a saved layout has to be
    /// resolved through the event it belonged to.
    func layoutName(for session: SessionRecord) -> String {
        // What was recorded at the time wins. Older sessions fall back to the
        // event's layout as it stands now, which is a guess, and then to the
        // built-in they were shot with, which is not.
        if let recorded = session.layoutName, !recorded.isEmpty { return recorded }
        if let event = storage.event(session.eventID),
           let t = templates.template(event.templateID) {
            return t.name
        }
        return session.layout.title
    }

    /// Writes one event's report as a PDF and hands back where it landed.
    @discardableResult
    func exportReport(for event: EventRecord, to url: URL) -> URL? {
        do {
            let out = try report(for: event).writePDF(to: url)
            log.info("Event report written to \(out.path)")
            show(.info, "Report saved — \(out.lastPathComponent)")
            return out
        } catch {
            show(.error, error.localizedDescription)
            return nil
        }
    }

    /// Sheets this event has actually printed, and how many are still in the
    /// printer's queue.
    ///
    /// Counted in sheets rather than sessions, because copies are what empties a
    /// paper cartridge: a session set to two copies takes two out of the pack of
    /// fifty-four the operator has to get through the night on.
    func printCounts(forEvent eventID: String) -> (printed: Int, pending: Int, failed: Int) {
        var printed = 0, pending = 0, failed = 0
        for s in storage.sessions where s.eventID == eventID {
            let sheets = max(1, s.copies)
            switch s.printStatus {
            case .printed:            printed += sheets
            case .queued, .printing:  pending += sheets
            case .failed:             failed += sheets
            case .notPrinted:         break
            }
        }
        return (printed, pending, failed)
    }

    /// Photographs a session needs — the template's, when one is in use.
    var templateShotCount: Int? {
        guard let t = activeTemplate, !t.slots.isEmpty else { return nil }
        return max(1, t.photoCount)
    }
    let storage: PhotoStorageService
    let printer: PrinterService
    let uploader: UploadService
    let trigger: TriggerService
    let log = Log.shared

    private var camera: CameraBackendService?
    private var activeBackend: CameraBackend?
    private var sessionTask: Task<Void, Never>?
    private var finishHoldTask: Task<Void, Never>?
    private var retakeCurrentRequested = false
    private var cancels = Set<AnyCancellable>()
    /// The session's film, recorded as it happens. One recorder for the booth's
    /// whole life: a session that ends badly cancels it rather than leaving a
    /// writer behind.
    private let videoRecorder = SessionVideoRecorder()
    private var videoWanted = false
    private var videoLastFrame = Date.distantPast
    private var detectTimer: Timer?

    var settings: AppSettings { settingsService.settings }

    // MARK: Init

    init() {
        let s = SettingsService()
        settingsService = s
        storage = PhotoStorageService()
        printer = PrinterService()
        uploader = UploadService()
        trigger = TriggerService()

        storage.configure(rootOverride: s.settings.rootPathOverride)
        storage.reload()
        printer.configure(printerName: s.settings.printerName, borderless: s.settings.borderless)
        printer.shouldPoll = { [weak self] in
            guard let self else { return false }
            return self.adminWindowVisible || self.state.isSessionActive
        }
        printer.startMonitoring()
        uploader.configure(s.settings)

        log.info("Photobooth launched — root \(storage.root.path)")
        healEmptyVideos()

        // dropFirst: the initial value is already applied above, and letting it
        // through would race a second camera connect against the one below.
        s.$settings
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] new in
                // Republish. Every card in the console observes this controller
                // and reads settings through it, but the settings live on their
                // own object — so without this a tapped layout tile or copies
                // number changed the stored value and no highlight moved.
                //
                // `@Published` fires on willSet, which is exactly when SwiftUI
                // wants to be told, so the re-read afterwards sees the new value.
                self?.objectWillChange.send()
                self?.applySettings(new)
            }
            .store(in: &cancels)

        // A sheet is only counted once it has actually come out. CUPS is the
        // only thing that knows: the session is marked queued when `lp` takes
        // it, and stays that way for ever unless somebody watches the job.
        printer.$jobs
            .removeDuplicates()
            .sink { [weak self] jobs in self?.reconcilePrintJobs(jobs) }
            .store(in: &cancels)

        wireUploader()
        uploader.start()

        // The physical button. Deliberately wired last: nothing it can fire is
        // meaningful until the services above are up.
        trigger.onPress = { [weak self] in self?.triggerPressed() }
        trigger.configure(s.settings)

        rebuildCamera(for: s.settings.cameraBackend)
        startDetectPolling()
        applyLocalServing(s.settings)
    }

    // MARK: Events

    /// The event new sessions are filed under. Falls back to the most recent
    /// event so a booth that was set up yesterday still works today.
    var activeEvent: EventRecord? {
        let wanted = settings.activeEventID
        if !wanted.isEmpty, let e = storage.event(wanted) { return e }
        return storage.events.first { !$0.archived }
    }

    var canStartSession: Bool { cameraState.isReady && activeEvent != nil }

    func setActiveEvent(_ id: String) {
        settingsService.settings.activeEventID = id
        if let e = storage.event(id) {
            log.info("Active event set to \(e.id) — \(e.name)")
        }
    }

    @discardableResult
    func createEvent(name: String, client: String, venue: String, date: Date, notes: String) -> EventRecord? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            show(.warning, "Give the event a name first.")
            return nil
        }
        do {
            let e = try storage.createEvent(name: trimmed, client: client, venue: venue, date: date, notes: notes)
            setActiveEvent(e.id)
            show(.info, "Event “\(e.name)” created and made active.")
            return e
        } catch {
            show(.error, error.localizedDescription)
            return nil
        }
    }

    func updateEvent(_ e: EventRecord) {
        storage.persist(event: e)
    }

    func deleteEvent(_ e: EventRecord) {
        storage.deleteEvent(e)
        if settings.activeEventID == e.id {
            settingsService.settings.activeEventID = storage.events.first?.id ?? ""
        }
    }

    // MARK: Uploads

    private func wireUploader() {
        uploader.resolveFiles = { [weak self] eventID, sessionID in
            guard let self else { return nil }
            guard let rec = self.storage.sessions.first(where: { $0.id == sessionID && $0.eventID == eventID })
            else { return nil }
            let event = self.storage.event(eventID) ?? EventRecord.unfiled
            return (event, rec, self.storage.directory(for: rec))
        }
        uploader.onSessionUploaded = { [weak self] eventID, sessionID in
            guard let self else { return }
            guard var rec = self.storage.sessions.first(where: { $0.id == sessionID && $0.eventID == eventID })
            else { return }
            rec.uploadState = .uploaded
            rec.uploadedAt = Date()
            self.storage.persist(rec)
            if self.currentSession?.id == rec.id {
                self.currentSession = rec
                // The guests may still be standing at the booth: the moment the
                // photographs are online, the code they can scan appears.
                if case .complete = self.state, self.sessionQRImage == nil {
                    self.sessionQRImage = self.makeQR(for: rec)
                }
                if case .complete = self.state, self.photoQRs.isEmpty {
                    self.photoQRs = self.makePhotoQRs(for: rec)
                }
                if case .complete = self.state, self.gifQRImage == nil {
                    self.gifQRImage = self.makeGIFQR(for: rec)
                }
                if case .complete = self.state, self.videoQRImage == nil {
                    self.videoQRImage = self.makeVideoQR(for: rec)
                }
            }
        }
        uploader.publishToPages = { [weak self] eventID, sessionID in
            guard let self else { throw PagesError.noRepo }
            if self.settings.galleryHost == .cloudinary {
                try await self.publishToCloudinary(eventID: eventID, sessionID: sessionID)
                // A failure here is thrown rather than logged: the guest's code
                // points at this page, so a session whose page never landed has
                // a QR that goes nowhere, and the queue should keep trying.
                if self.pagesPublisher() != nil {
                    try await self.publishCloudinaryPage(eventID: eventID, sessionID: sessionID)
                }
            } else {
                try await self.publishToPages(eventID: eventID, sessionID: sessionID)
            }
        }
        uploader.pagesReachable = { [weak self] in
            guard let self else { return .failure(PagesError.noRepo) }
            if self.settings.galleryHost == .cloudinary {
                guard let cloud = self.cloudinary else { return .failure(CloudinaryError.notConfigured) }
                do { return .success("Cloudinary (\(try await cloud.check()))") }
                catch { return .failure(error) }
            }
            guard let pub = self.pagesPublisher() else {
                return .failure(PagesError.noRepo)
            }
            return await Task.detached(priority: .utility) { () -> Result<String, Error> in
                do {
                    _ = try pub.canReachRemote()
                    return .success("GitHub Pages")
                } catch { return .failure(error) }
            }.value
        }
        uploader.onSessionFailed = { [weak self] eventID, sessionID, message in
            guard let self else { return }
            guard var rec = self.storage.sessions.first(where: { $0.id == sessionID && $0.eventID == eventID })
            else { return }
            rec.uploadState = .failed
            rec.lastError = message
            self.storage.persist(rec)
        }
    }

    /// Adds a session to the upload queue. Safe with no internet: the queue is on
    /// disk and drains whenever the site is next reachable.
    func queueUpload(_ rec: SessionRecord) {
        guard settings.uploadEnabled else { return }
        var s = rec
        s.uploadState = .queued
        storage.persist(s)
        if currentSession?.id == s.id { currentSession = s }
        uploader.enqueue(eventID: rec.eventID, sessionID: rec.id)
    }

    func retryUploads() {
        uploader.uploadNow()
        show(.info, uploader.pendingCount == 0
             ? "Nothing waiting to upload."
             : "Retrying \(uploader.pendingCount) session(s).")
    }

    func checkGallerySite() {
        Task { @MainActor in
            let ok = await self.uploader.checkReachability()
            self.show(ok ? .info : .warning, self.uploader.reachability.label)
        }
    }

    private func applySettings(_ new: AppSettings) {
        storage.configure(rootOverride: new.rootPathOverride)
        printer.configure(printerName: new.printerName, borderless: new.borderless)
        uploader.configure(new)
        trigger.configure(new)
        if new.cameraBackend != activeBackend {
            rebuildCamera(for: new.cameraBackend)
        }
        if let dslr = camera as? DSLRCameraService {
            dslr.setFPS(new.liveViewFPS)
            dslr.setKeepOnCard(new.keepOriginalsOnCard)
        }
        if let cam = camera as? WebcamCameraService {
            cam.setPreferredDevice(new.webcamUniqueID)
            cam.setFPS(new.liveViewFPS)
        }
        if let demo = camera as? DemoCameraService {
            demo.setFPS(new.liveViewFPS)
            demo.setLogo(new.idleLogoFile)
        }
        updateLiveViewDesire(using: new)
        applyLocalServing(new)
    }

    // MARK: Camera wiring

    private func rebuildCamera(for backend: CameraBackend) {
        // Detach first: the outgoing backend has work in flight on its own queue,
        // and a late callback would otherwise report its status as the new one's.
        camera?.onState = nil
        camera?.onFrame = nil
        camera?.stopLiveView()
        camera?.disconnect()
        livePreview.set(nil)
        cameraState = .connecting

        let made: CameraBackendService
        switch backend {
        case .dslr:
            let d = DSLRCameraService(fps: settings.liveViewFPS)
            d.setKeepOnCard(settings.keepOriginalsOnCard)
            made = d
        case .webcam:
            let w = WebcamCameraService(uniqueID: settings.webcamUniqueID)
            w.setFPS(settings.liveViewFPS)
            made = w
        case .demo:
            let d = DemoCameraService(fps: settings.liveViewFPS)
            d.setLogo(settings.idleLogoFile)
            made = d
        }
        made.onState = { [weak self] s in
            guard let self else { return }
            self.cameraState = s
            if case .disconnected = s { self.cameraSettings = [] }
            if case .disconnected = s, self.state.isSessionActive {
                self.abortSession(reason: "The camera was disconnected.")
            }
            if case .error(let m) = s, self.state.isSessionActive {
                self.abortSession(reason: m)
            }
        }
        made.onFrame = { [weak self] img in
            guard let self, self.wantsLiveView else { return }
            self.livePreview.set(img)
            self.recordVideoFrame(img)
        }
        camera = made
        activeBackend = backend
        detectedCameras = []
        cameraSettings = []
        cameraSettingsError = nil
        log.info("Camera backend set to \(backend.title)")
        made.connect()
        refreshDetectedCameras()
    }

    func connectCamera() {
        guard let camera else { return }
        camera.connect()
        updateLiveViewDesire()
    }

    func disconnectCamera() {
        camera?.stopLiveView()
        camera?.disconnect()
        livePreview.set(nil)
    }

    private func startDetectPolling() {
        refreshDetectedCameras()
        detectTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.detectTick() }
        }
    }

    /// A USB bus scan is not free, so it only runs when it could change something:
    /// the camera is missing, and somebody is looking at the console. Once
    /// connected, the backend's own watchdog notices an unplugged cable.
    private func detectTick() {
        // A booth carried into another room lands on another network, and the
        // address in every code on screen would quietly stop working. Cheap to
        // check — it reads the interfaces, it does not touch the network.
        if settings.localServeEnabled {
            let before = localAddress
            refreshLocalAddress()
            if before != localAddress, before != nil {
                log.info("Local address changed to \(localAddress ?? "none")")
                if let s = currentSession, case .complete = state {
                    sessionQRImage = makeQR(for: s)
                    photoQRs = makePhotoQRs(for: s)
                    gifQRImage = makeGIFQR(for: s)
                }
            }
        }
        guard !cameraState.isReady else { return }
        guard adminWindowVisible || state.isSessionActive else { return }
        refreshDetectedCameras()
    }

    func refreshDetectedCameras() {
        switch activeBackend {
        case .dslr:
            (camera as? DSLRCameraService)?.detectedCameras { [weak self] cams in
                guard let self else { return }
                self.detectedCameras = cams
                // Auto-reconnect when the cable comes back and we are not mid-session.
                if !cams.isEmpty, !self.cameraState.isReady, !self.state.isSessionActive {
                    if case .connecting = self.cameraState {} else { self.camera?.connect() }
                }
            }
        case .webcam:
            detectedCameras = WebcamCameraService.availableDevices().map(\.localizedName)
        case .demo:
            detectedCameras = ["Generated test pattern"]
        case .none:
            detectedCameras = []
        }
    }

    // MARK: Settings on the camera body

    /// Asks the camera what it is set to. Safe to call when there is no camera:
    /// the backends that have nothing to say answer with an empty list.
    func refreshCameraSettings() {
        guard !cameraSettingsLoading else { return }
        guard let camera, cameraState.isReady else {
            cameraSettings = []
            cameraSettingsError = activeBackend == .dslr
                ? "Connect the camera to see its settings."
                : nil
            return
        }
        cameraSettingsLoading = true
        camera.readSettings { [weak self] found in
            guard let self else { return }
            self.cameraSettingsLoading = false
            self.cameraSettings = found
            self.cameraSettingsError = found.isEmpty && self.activeBackend == .dslr
                ? "The camera did not offer any settings. Take it off a fully automatic mode and try again."
                : nil
        }
    }

    /// Writes one setting to the body, then re-reads everything: on a Canon the
    /// settings move together — drop to f/1.8 in Av and the shutter speed the
    /// camera reports changes with it — so showing only the edited one would be
    /// showing a lie.
    func setCameraSetting(_ name: String, to value: String) {
        guard let camera else { return }
        guard !state.isSessionActive else {
            show(.warning, "Wait until the session has finished.")
            return
        }
        cameraSettingBusy = name
        camera.writeSetting(name, to: value) { [weak self] error in
            guard let self else { return }
            self.cameraSettingBusy = nil
            if let error {
                self.cameraSettingsError = error
                self.show(.warning, error)
                // Put the control back to what the body actually holds.
                self.refreshCameraSettings()
            } else {
                self.cameraSettingsError = nil
                self.refreshCameraSettings()
            }
        }
    }

    /// Live view runs while the operator is watching Admin, or while a session is
    /// in flight — never on an unattended idle screen, so the camera stays cool
    /// between guests.
    /// Whether live frames are wanted at all. Frames already in flight land a
    /// moment after the camera is told to stop, and one of those arriving late
    /// is exactly how a stopped preview leaves somebody's face frozen on screen.
    private var wantsLiveView = false

    /// `using:` matters more than it looks. Settings arrive through a @Published
    /// publisher, which fires on *will*Set — during that call `settings` still
    /// reads the previous value, so deciding from it would act on the setting the
    /// operator just changed away from and not act again until something else
    /// happened to re-evaluate.
    private func updateLiveViewDesire(using incoming: AppSettings? = nil) {
        guard let camera else { return }
        let cfg = incoming ?? settings
        // Idle preview only while the booth window is actually open: a DSLR held
        // in live view is burning its battery and warming its sensor, and there
        // is no reason to pay that while the guest screen is closed.
        let idlePreview = cfg.idleLiveView && boothWindowOpen && !state.isSessionActive
        let want = cfg.liveViewEnabled && (adminWindowVisible || state.isSessionActive || idlePreview)
        wantsLiveView = want
        if want {
            camera.startLiveView()
        } else {
            camera.stopLiveView()
            // Without this the last frame stays on screen: a guest frozen on the
            // idle display long after the camera stopped.
            livePreview.set(nil)
        }
    }

    // MARK: Window coordination
    //
    // AppDelegate owns the NSWindows and installs these hooks at launch; the UI
    // calls them without needing to know about AppKit.

    var openBoothWindow: ((Bool) -> Void)?     // Bool = also enter full screen
    var closeBoothWindow: (() -> Void)?
    var focusAdminWindow: (() -> Void)?
    /// Opens the editor, on a named template or on a fresh one when nil.
    var openPrintEditor: ((String?) -> Void)?

    func noteBoothWindow(open: Bool) {
        guard boothWindowOpen != open else { return }
        boothWindowOpen = open
        log.info(open ? "Booth window opened" : "Booth window closed")
        updateLiveViewDesire()
    }

    func noteAdminWindow(visible: Bool) {
        guard adminWindowVisible != visible else { return }
        adminWindowVisible = visible
        updateLiveViewDesire()
    }

    func showBooth(fullScreen: Bool? = nil) {
        openBoothWindow?(fullScreen ?? settings.fullScreenOnLaunch)
    }

    func hideBooth() { closeBoothWindow?() }
    func showAdmin() { focusAdminWindow?() }

    // MARK: - Session state machine

    func startSession() {
        guard !state.isSessionActive else { return }
        guard cameraState.isReady else {
            show(.error, "Camera is not ready — \(cameraState.label)")
            return
        }
        // Every session belongs to a client event, so photographs never pile into
        // one undifferentiated folder.
        guard let event = activeEvent else {
            show(.warning, "Create an event first — Admin › Event › New Event.")
            return
        }
        do { try storage.preflight(eventID: event.id) }
        catch {
            show(.error, error.localizedDescription)
            log.error("Preflight failed: \(error.localizedDescription)")
            return
        }

        let layout = settings.layout
        // A saved layout decides how many photographs it needs — six slots
        // showing three photographs want three shots, not the eight the
        // built-in layout behind them would have asked for.
        let total = templateShotCount ?? layout.photoCount
        var rec: SessionRecord
        do {
            rec = try storage.createSession(eventID: event.id, layout: layout, copies: settings.copies)
        } catch {
            show(.error, error.localizedDescription)
            return
        }

        // Stamped now, while it is true.
        rec.layoutName = activeTemplate?.name ?? layout.title
        storage.persist(rec)

        currentSession = rec
        sessionPrintImage = nil
        sessionGIF = nil
        sessionQRImage = nil
        photoQRs = []
        gifQRImage = nil
        videoQRImage = nil
        shotPreview = nil
        retakeCurrentRequested = false
        retakeQueue = []
        awaitingContinue = false
        retakingShot = nil
        finishHoldTask?.cancel()
        state = .starting
        updateLiveViewDesire()

        plannedShots = total
        videoWanted = settings.makeVideo
        videoLastFrame = .distantPast
        reserveSessionPage(rec)
        sessionTask = Task { [weak self] in await self?.runSession(total: total) }
    }

    private func runSession(total: Int) async {
        // Give live view a beat to spin up (the 6D lifts its mirror on the first frame).
        try? await Task.sleep(nanoseconds: 900_000_000)
        if Task.isCancelled { return }

        var shot = 1
        while shot <= total {
            if Task.isCancelled { return }

            switch await performShot(shot, of: total, replacing: false) {
            case .failed:      return
            case .retakeAgain: continue        // same shot number, round again
            case .done:        break
            }

            // NEXT_PHOTO
            if shot < total {
                state = .interval(shot: shot, of: total)
                try? await Task.sleep(nanoseconds: UInt64(max(0, settings.shotIntervalSeconds) * 1_000_000_000))
            }
            shot += 1
        }

        if Task.isCancelled { return }
        // Anything the operator picked out by number while the run was going on.
        guard await runRetakePass(total: total) else { return }
        if Task.isCancelled { return }
        await finishSession()
    }

    private enum ShotOutcome { case done, retakeAgain, failed }

    /// One countdown → capture → save → review cycle.
    ///
    /// `replacing` re-shoots a photo that already exists at this number: the old
    /// frame is kept on disk under a `.retake-` name and the new one takes its
    /// place, so the print is rebuilt from the shot the guests actually wanted.
    private func performShot(_ shot: Int, of total: Int, replacing: Bool) async -> ShotOutcome {
        retakingShot = replacing ? shot : nil
        defer { retakingShot = nil }

        if replacing {
            state = .retaking(shot: shot, of: total)
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if Task.isCancelled { return .failed }
        }

        // COUNTDOWN
        var remaining = max(1, settings.countdownSeconds)
        while remaining > 0 {
            if Task.isCancelled { return .failed }
            state = .countdown(shot: shot, of: total, remaining: remaining)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            remaining -= 1
        }

        // CAPTURING
        if Task.isCancelled { return .failed }
        state = .capturing(shot: shot, of: total)
        var captured: Data
        do {
            guard let camera else { throw CameraError.notConnected }
            captured = try await camera.capturePhoto()
        } catch {
            log.error("Shot \(shot) failed: \(error.localizedDescription)")
            finishFailed(error.localizedDescription)
            return .failed
        }

        // Mirror before saving, so the file, the on-screen review and the print
        // all match the mirrored preview the guest just posed against.
        if settings.mirrorImages {
            let dpi = settings.dpi
            let source = captured
            if let flipped = await Task.detached(priority: .userInitiated, operation: {
                LayoutRenderer.mirroredJPEG(source, dpi: dpi)
            }).value {
                captured = flipped
            }
        }

        // Black and white, applied to the frame itself rather than to each
        // output in turn: the print, the strip on the web page, the loop, the
        // clip and the review screen are then all the same photograph, where
        // five conversions could only ever end up disagreeing. The colour
        // original is carried along to be kept beside it — an evening shot in
        // black and white is a choice, not a reason to destroy the only copy.
        var colourOriginal: Data?
        if settings.monochrome {
            let dpi = settings.dpi
            let source = captured
            if let mono = await Task.detached(priority: .userInitiated, operation: {
                LayoutRenderer.monochromeJPEG(source, dpi: dpi)
            }).value {
                colourOriginal = captured
                captured = mono
            } else {
                log.warn("Shot \(shot) could not be converted to black and white — kept in colour.")
            }
        }

        // The flash and the photograph go into the film while they are the
        // thing on screen, so the clip plays back the session rather than
        // summarising it.
        recordVideoShot(captured)

        // SAVE — before anything else touches the workflow.
        guard var session = currentSession else { return .failed }
        do {
            let photo = replacing
                ? try storage.replacePhoto(jpeg: captured, index: shot, in: session)
                : try storage.savePhoto(jpeg: captured, index: shot, in: session)
            if let i = session.photos.firstIndex(where: { $0.index == shot }) {
                session.photos[i] = photo
            } else {
                session.photos.append(photo)
            }
            session.photos.sort { $0.index < $1.index }
            if replacing { session.retakenShots.append(shot) }
            currentSession = session
            storage.persist(session)
            if let colourOriginal {
                storage.archiveColour(jpeg: colourOriginal, index: shot, in: session)
            }
            camera?.didPersistLastCapture()
        } catch {
            log.error("Could not save shot \(shot): \(error.localizedDescription)")
            finishFailed(error.localizedDescription)
            return .failed
        }

        shotPreview = NSImage(data: captured)

        // PHOTO_PREVIEW
        state = .photoPreview(shot: shot, of: total)
        try? await Task.sleep(nanoseconds: UInt64(max(0, settings.previewSeconds) * 1_000_000_000))
        if Task.isCancelled { return .failed }
        shotPreview = nil

        // A retake asked for while this very photo was on screen is honoured now
        // rather than being deferred to the end — the guests are still posed.
        if retakeCurrentRequested {
            retakeCurrentRequested = false
            retakeQueue.remove(shot)
            return .retakeAgain
        }
        retakeQueue.remove(shot)
        return .done
    }

    /// Re-shoots every number still sitting in the retake queue.
    /// Returns false if a shot failed and the session has already been ended.
    @discardableResult
    private func runRetakePass(total: Int) async -> Bool {
        while let next = retakeQueue.sorted().first {
            if Task.isCancelled { return false }
            retakeQueue.remove(next)
            // Only re-shoot numbers that were actually taken; a queued number for a
            // shot the run never reached is simply dropped.
            guard currentSession?.photos.contains(where: { $0.index == next }) == true else { continue }
            switch await performShot(next, of: total, replacing: true) {
            case .failed:      return false
            case .retakeAgain: retakeQueue.insert(next)
            case .done:        break
            }
        }
        return true
    }

    private func finishSession() async {
        guard var session = currentSession else { return }
        state = .generatingPrint
        camera?.stopLiveView()

        // Closed before the print is composed: the live view has stopped, so
        // nothing more is coming, and the file wants finishing while the guests
        // are watching the sheet being made rather than after.
        await finishVideo(for: &session)
        if session.videoFileName != nil {
            storage.persist(session)
            currentSession = session
        }

        let dir = storage.directory(for: session)
        let urls = session.photos.sorted { $0.index < $1.index }.map { $0.url(in: dir) }
        let layout = session.layout
        let snapshot = settings
        let payload = printQRPayload(for: session)
        let sheet = activeTemplate

        let result: Result<Data, Error> = await Task.detached(priority: .userInitiated) {
            do {
                return .success(try LayoutRenderer.renderPrint(photos: urls, layout: layout,
                                                               settings: snapshot, qrPayload: payload,
                                                               template: sheet))
            } catch { return .failure(error) }
        }.value

        switch result {
        case .failure(let e):
            log.error("Layout render failed for \(session.id): \(e.localizedDescription)")
            session.lastError = e.localizedDescription
            session.finishedAt = Date()
            storage.persist(session)
            currentSession = session
            finishFailed("Could not build the print. Your photographs are saved.")
            return
        case .success(let data):
            do {
                session.printFileName = try storage.savePrint(data, in: session)
            } catch {
                log.error("Could not save print for \(session.id): \(error.localizedDescription)")
            }
            sessionPrintImage = NSImage(data: data)
            session.finishedAt = Date()
            storage.persist(session)
            currentSession = session
        }

        // The GIF is built after the print, never before: the sheet is what the
        // guests are waiting on, and a failure here must not cost them one.
        if GIFRenderer.enabled, settings.makeGIF {
            let gifResult: Result<Data, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try GIFRenderer.renderSlideshow(stills: urls, layout: layout,
                                                                    settings: snapshot, template: sheet))
                } catch { return .failure(error) }
            }.value
            switch gifResult {
            case .success(let gif):
                do {
                    session.gifFileName = try storage.saveGIF(gif, in: session)
                    sessionGIF = NSImage(data: gif)
                    storage.persist(session)
                    currentSession = session
                } catch {
                    log.error("Could not save GIF for \(session.id): \(error.localizedDescription)")
                }
            case .failure(let e):
                // Not fatal, and deliberately not shown to the guests: they have
                // their photographs and their print either way.
                log.warn("GIF render failed for \(session.id): \(e.localizedDescription)")
            }
            }

        // With the finish screen holding for a press, the print holds with it.
        // The guests look at the QR card, press once when they are done, and the
        // sheet starts coming out as they walk away — one press, print and reset.
        // Nothing is printed for a group that never presses.
        let deferPrint = settings.autoPrint && settings.holdFinishUntilPress
        if settings.autoPrint && !deferPrint {
            state = .printing
            sendToPrinter(session: session, allowRepeat: false)
        }

        queueUpload(session)
        // Before the codes: the server has to know about this session, or the
        // first guest to scan gets a 404 from a booth holding their photographs.
        publishLocalSessions()
        sessionQRImage = makeQR(for: session)
        photoQRs = makePhotoQRs(for: session)
        gifQRImage = makeGIFQR(for: session)
        videoQRImage = makeVideoQR(for: session)
        brandQRImage = settings.showQRCode && qrPayloads(for: session).brand != nil ? makeBrandQR() : nil
        let waitingOnUpload = settings.qrRequiresUpload && session.uploadState != .uploaded
        if settings.showQRCode, sessionQRImage == nil, brandQRImage == nil, !waitingOnUpload {
            // Asked for a code and got none: better a warning on the console than
            // a finish screen that quietly drops the handout.
            show(.warning, qrTargetProblem ?? "No QR code could be built for this session.")
        }
        pendingPrint = deferPrint

        state = .complete
        let retaken = session.retakenShots.isEmpty
            ? ""
            : " (retook \(session.retakenShots.map(String.init).joined(separator: ", ")))"
        log.info("Session \(session.id) complete — \(session.photos.count) photos\(retaken)")

        holdFinishScreen()
    }

    /// The finish screen either times out on its own or waits for the button.
    ///
    /// Waiting is the default: guests need a moment to read the QR code, and the
    /// next group should start when they are ready rather than when a timer says
    /// so. A jam-guard still exists — an unattended booth left showing somebody
    /// else's photographs is worse than a booth that resets itself.
    private func holdFinishScreen() {
        finishHoldTask?.cancel()
        let hold = settings.holdFinishUntilPress
        awaitingContinue = hold
        let seconds = hold
            ? max(0, settings.finishHoldTimeoutSeconds)
            : max(1, settings.completeScreenSeconds)
        guard seconds > 0 else { return }        // 0 with hold on = wait forever

        finishHoldTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            guard case .complete = self.state else { return }
            if hold {
                self.log.info("Finish screen timed out after \(Int(seconds))s — returning to idle")
                if self.pendingPrint {
                    // Nobody pressed, so nobody is there to take the sheet.
                    // The print image is saved — Admin › Gallery can send it.
                    let id = self.currentSession?.id ?? "session"
                    self.log.warn("Print held back for \(id) — no button press")
                    self.show(.warning, "Nobody pressed — \(id) was not printed.")
                }
            }
            self.returnToIdle()
        }
    }

    /// Carries finished and failed print jobs back onto the sessions that
    /// started them, so "printed" on a record means a sheet came out rather than
    /// a file was handed to CUPS.
    private func reconcilePrintJobs(_ jobs: [PrintJob]) {
        for job in jobs {
            guard let i = storage.sessions.firstIndex(where: { $0.id == job.sessionID }) else { continue }
            var rec = storage.sessions[i]
            guard rec.printJobID == job.id else { continue }
            let wanted: PrintStatus = job.failed ? .failed : (job.done ? .printed : .printing)
            guard rec.printStatus != wanted, rec.printStatus != .printed else { continue }
            rec.printStatus = wanted
            storage.persist(rec)
            if currentSession?.id == rec.id { currentSession = rec }
        }
    }

    private func sendToPrinter(session: SessionRecord, allowRepeat: Bool) {
        guard let name = session.printFileName else { return }
        if currentSession?.id == session.id { pendingPrint = false }
        // A rehearsal composes the sheet, saves it and uploads it, and stops
        // one step short of the paper. The print counter is left alone too: a
        // sheet that never came out is not a sheet.
        if fakePrinting {
            log.info("Dry run — would have printed \(session.id) (\(max(1, session.copies)) copy/copies)")
            return
        }
        var s = session
        let url = storage.directory(for: session).appendingPathComponent(name)
        do {
            let job = try printer.submit(fileURL: url,
                                         sessionID: session.id,
                                         copies: max(1, session.copies),
                                         allowRepeat: allowRepeat)
            s.printStatus = .queued
            s.printJobID = job.id
            s.lastError = nil
        } catch {
            s.printStatus = .failed
            s.lastError = error.localizedDescription
            show(.error, error.localizedDescription)
            log.error("Print failed for \(session.id): \(error.localizedDescription)")
        }
        storage.persist(s)
        if currentSession?.id == s.id { currentSession = s }
    }

    // MARK: Operator actions

    func cancelSession() {
        guard state.isSessionActive else { return }
        videoWanted = false
        videoRecorder.cancel()
        sessionTask?.cancel()
        sessionTask = nil
        if let s = currentSession {
            var rec = s
            rec.finishedAt = Date()
            rec.lastError = "Cancelled by operator"
            storage.persist(rec)
            log.warn("Session \(s.id) cancelled — \(s.photos.count) photo(s) kept on disk")
        }
        returnToIdle()
    }

    private func abortSession(reason: String) {
        sessionTask?.cancel()
        sessionTask = nil
        finishFailed(reason)
    }

    private func finishFailed(_ reason: String) {
        videoWanted = false
        videoRecorder.cancel()
        if let s = currentSession {
            var rec = s
            rec.finishedAt = Date()
            rec.lastError = reason
            storage.persist(rec)
        }
        state = .failed(reason)
        show(.error, reason)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, case .failed = self.state else { return }
            self.returnToIdle()
        }
    }

    func restartSession() {
        cancelSession()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.startSession()
        }
    }

    // MARK: Retakes
    //
    // Every photograph in a session carries a number, and Admin shows those
    // numbers as buttons. Clicking one marks that shot to be taken again — while
    // the run is going on, or afterwards from the finish screen, which is when
    // guests usually notice somebody blinked.

    /// The number of shots this session is meant to end up with.
    var shotCount: Int {
        // A run in flight keeps the count it started with; otherwise the layout
        // about to be used decides — the saved one if there is one, else the
        // built-in behind it.
        if currentSession != nil, plannedShots > 0 { return plannedShots }
        return templateShotCount ?? settings.layout.photoCount
    }

    /// True when clicking a number would do something useful right now.
    var canRetake: Bool {
        guard let s = currentSession, !s.photos.isEmpty else { return state.isSessionActive }
        return state.isSessionActive || isFinished
    }

    private var isFinished: Bool {
        if case .complete = state { return true }
        if case .failed = state { return true }
        return false
    }

    /// What clicking a number in Admin does.
    ///
    /// During a run it is a toggle: mark a number, change your mind, unmark it.
    /// On the finish screen there is nothing to queue behind, so the click
    /// re-shoots straight away — which is the case that matters, because that is
    /// when a guest says somebody blinked.
    func toggleRetake(shot number: Int) {
        if retakeQueue.contains(number) {
            retakeQueue.remove(number)
            if case .photoPreview(let s, _) = state, s == number { retakeCurrentRequested = false }
            show(.info, "Photo \(number) will be kept.")
            return
        }
        requestRetake(shot: number)
    }

    func requestRetake(shot number: Int) {
        guard number >= 1, number <= shotCount else { return }

        if state.isSessionActive {
            // Already being re-shot: adding it again would put the booth into a
            // loop of retaking the same photograph.
            if retakingShot == number {
                show(.info, "Photo \(number) is being taken again right now.")
                return
            }
            // If this is the photo on screen, do it immediately — the guests have
            // not moved yet.
            if case .photoPreview(let s, _) = state, s == number {
                retakeQueue.insert(number)
                retakeCurrentRequested = true
                show(.info, "Retaking photo \(number) now…")
                return
            }
            guard currentSession?.photos.contains(where: { $0.index == number }) == true else {
                show(.info, "Photo \(number) has not been taken yet.")
                return
            }
            retakeQueue.insert(number)
            show(.info, "Photo \(number) queued — it is taken again after the last shot.")
            return
        }

        guard isFinished, let session = currentSession else {
            show(.warning, "No session to retake. Start one first.")
            return
        }
        guard session.photos.contains(where: { $0.index == number }) else {
            show(.warning, "This session has no photo \(number).")
            return
        }
        guard cameraState.isReady else {
            show(.error, "Camera is not ready — \(cameraState.label)")
            return
        }
        retakeQueue.insert(number)
        resumeForRetakes()
    }

    /// Reopens a finished session to re-shoot the queued numbers, then rebuilds
    /// the print and sends it again.
    func resumeForRetakes() {
        guard !state.isSessionActive, !retakeQueue.isEmpty else { return }
        guard let session = currentSession else { return }
        guard cameraState.isReady else {
            show(.error, "Camera is not ready — \(cameraState.label)")
            return
        }
        finishHoldTask?.cancel()
        awaitingContinue = false
        pendingPrint = false
        sessionPrintImage = nil
        sessionGIF = nil
        sessionQRImage = nil
        photoQRs = []
        gifQRImage = nil
        videoQRImage = nil
        brandQRImage = nil
        let total = plannedShots > 0 ? plannedShots
                                     : (templateShotCount ?? session.layout.photoCount)
        plannedShots = total
        let numbers = retakeQueue.sorted().map(String.init).joined(separator: ", ")
        log.info("Session \(session.id) reopened to retake photo(s) \(numbers)")
        state = .starting
        updateLiveViewDesire()

        sessionTask = Task { [weak self] in
            guard let self else { return }
            guard await self.runRetakePass(total: total) else { return }
            if Task.isCancelled { return }
            await self.finishSession()
        }
    }

    /// Kept for the menu bar and the older keyboard shortcut: retakes whichever
    /// photo is on screen.
    func retakeCurrentPhoto() {
        guard let p = progress else {
            show(.warning, "No photo on screen to retake.")
            return
        }
        requestRetake(shot: p.shot)
    }

    func returnToIdle() {
        sessionTask?.cancel()
        sessionTask = nil
        finishHoldTask?.cancel()
        finishHoldTask = nil
        plannedShots = 0
        state = .idle
        shotPreview = nil
        retakeCurrentRequested = false
        retakeQueue = []
        awaitingContinue = false
        pendingPrint = false
        retakingShot = nil
        sessionQRImage = nil
        photoQRs = []
        gifQRImage = nil
        videoQRImage = nil
        brandQRImage = nil
        storage.refreshFreeSpace()
        updateLiveViewDesire()
    }

    // MARK: Printing actions

    func reprint(_ rec: SessionRecord) {
        guard !isPrintBusy else { return }
        guard rec.printFileName != nil else {
            show(.warning, "That session has no print image. Rebuild it first.")
            return
        }
        isPrintBusy = true
        sendToPrinter(session: rec, allowRepeat: true)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            self.isPrintBusy = false
        }
    }

    func printCurrentSession() {
        guard let s = currentSession else { return }
        reprint(s)
    }

    /// Rebuilds print.jpg from the originals — used after a layout change or a failed render.
    func rebuildPrint(for rec: SessionRecord) {
        let dir = storage.directory(for: rec)
        let urls = rec.photos.sorted { $0.index < $1.index }.map { $0.url(in: dir) }
        let layout = rec.layout
        let snapshot = settings
        let payload = printQRPayload(for: rec)
        let sheet = activeTemplate
        Task { @MainActor in
            let result: Result<Data, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try LayoutRenderer.renderPrint(photos: urls, layout: layout,
                                                                   settings: snapshot, qrPayload: payload,
                                                                   template: sheet))
                } catch { return .failure(error) }
            }.value
            switch result {
            case .success(let data):
                var s = rec
                s.printFileName = try? self.storage.savePrint(data, in: rec)
                self.storage.persist(s)
                self.show(.info, "Print image rebuilt for \(rec.id)")
            case .failure(let e):
                self.show(.error, e.localizedDescription)
            }
        }
    }

    func testPrint() {
        guard !isPrintBusy else { return }
        guard let data = printer.testPrintImage(settings: settings) else {
            show(.error, "Could not build the test sheet.")
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("photobooth-test-\(Int(Date().timeIntervalSince1970)).jpg")
        do {
            try data.write(to: url)
            isPrintBusy = true
            _ = try printer.submit(fileURL: url, sessionID: "TEST", copies: 1, allowRepeat: true)
            show(.info, "Test sheet sent to \(printer.selectedPrinter.isEmpty ? printer.systemDefault : printer.selectedPrinter)")
        } catch {
            show(.error, error.localizedDescription)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.isPrintBusy = false
        }
    }

    // MARK: Test capture (Admin)

    func testCapture() {
        guard cameraState.isReady else {
            show(.error, "Camera is not ready — \(cameraState.label)")
            return
        }
        guard !state.isSessionActive else { return }
        Task { @MainActor in
            do {
                guard let camera else { return }
                var data = try await camera.capturePhoto()
                if self.settings.mirrorImages,
                   let flipped = LayoutRenderer.mirroredJPEG(data, dpi: self.settings.dpi) {
                    data = flipped
                }
                let dir = self.storage.root.appendingPathComponent("TestShots", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent("test-\(Date().sessionFolderName).jpg")
                try data.write(to: url, options: .atomic)
                camera.didPersistLastCapture()
                self.shotPreview = NSImage(data: data)
                self.show(.info, "Test shot saved to \(url.lastPathComponent)")
                self.log.info("Test capture saved: \(url.path)")
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if !self.state.isSessionActive { self.shotPreview = nil }
                }
            } catch {
                self.show(.error, error.localizedDescription)
            }
        }
    }

    // MARK: - The physical button

    /// One press of the booth button. What it does depends on where the session
    /// is, and it deliberately does nothing at all mid-capture: a guest leaning on
    /// the button during a countdown must not be able to derail the run.
    func triggerPressed() {
        switch state {
        case .idle:
            guard canStartSession else {
                if activeEvent == nil {
                    show(.warning, "Create an event first — Admin › Event › New Event.")
                } else {
                    show(.error, "Camera is not ready — \(cameraState.label)")
                }
                return
            }
            startSession()

        case .complete, .failed:
            // Releases the print if one is waiting, then clears the finish screen
            // so the next group gets a fresh idle screen; their own press starts
            // the session.
            if pendingPrint, let s = currentSession {
                sendToPrinter(session: s, allowRepeat: false)
            }
            returnToIdle()

        case .starting, .countdown, .capturing, .photoPreview, .interval,
             .retaking, .generatingPrint, .printing:
            break
        }
    }

    // MARK: - GitHub Pages

    /// The local clone that *is* the website.
    var pagesRepoURL: URL? {
        let p = settings.pagesRepoPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return nil }
        return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
    }

    func pagesPublisher() -> PagesPublisher? {
        guard let repo = pagesRepoURL else { return nil }
        var p = PagesPublisher(repo: repo)
        p.branch = settings.pagesBranch.isEmpty ? "main" : settings.pagesBranch
        p.longEdge = max(600, settings.pagesLongEdge)
        p.siteTitle = settings.eventTitle
        p.brandLink = customQRURL?.absoluteString
        p.brandLabel = settings.customQRCaption
        p.linksAlbum = settings.linkAlbumFromSessions
        p.logoFile = settings.idleLogoFile.isEmpty ? nil : settings.idleLogoFile
        p.retentionDays = max(0, settings.photoRetentionDays)
        return p
    }

    /// Creates the site folder, its git repository and the landing page.
    func setUpPagesSite(remote: String) {
        guard let repo = pagesRepoURL else {
            show(.warning, "Choose a folder for the site first.")
            return
        }
        let title = settings.eventTitle
        let branch = settings.pagesBranch.isEmpty ? "main" : settings.pagesBranch
        Task { @MainActor in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try PagesPublisher.setUp(at: repo, remote: remote, branch: branch,
                                             siteTitle: title,
                                             authorName: "Photobooth",
                                             authorEmail: "mixel.org@gmail.com")
                }.value
                self.log.info("Gallery site ready at \(repo.path)")
                self.show(.info, "Site folder ready. Push it once by hand to finish the connection.")
                _ = await self.uploader.checkReachability()
            } catch {
                self.log.error("Site set-up failed: \(error.localizedDescription)")
                self.show(.error, error.localizedDescription)
            }
        }
    }

    /// Publishes one finished session: web copies, its page, the album page, and
    /// a push. Every step runs off the main actor — a slow push must not freeze
    /// the booth between guests.
    func publishToPages(eventID: String, sessionID: String) async throws {
        guard let publisher = pagesPublisher() else { throw PagesError.noRepo }
        guard let rec = storage.sessions.first(where: { $0.id == sessionID && $0.eventID == eventID })
        else { throw UploadError.missingFiles(sessionID) }
        var event = storage.event(eventID) ?? EventRecord.unfiled

        // Tokens are assigned once and kept: the QR code a guest already scanned
        // must keep working after the next publish.
        var session = rec
        if session.publicToken.isEmpty {
            session.publicToken = PagesPublisher.makeToken()
            storage.persist(session)
        }
        if (event.publishedSlug ?? "").isEmpty {
            event.publishedSlug = PagesPublisher.makeToken()
            storage.persist(event: event)
        }
        let eventToken = event.publishedSlug ?? PagesPublisher.makeToken()
        let dir = storage.directory(for: session)
        let siblings = storage.sessions
            .filter { $0.eventID == eventID && $0.finishedAt != nil }
            .map { $0.id == session.id ? session : $0 }
        let originals = settings.uploadOriginals
        let prints = settings.uploadPrints
        let gifs = GIFRenderer.enabled && settings.uploadGIFs
        let message = "\(event.name) — \(session.id)"

        try await Task.detached(priority: .utility) {
            try publisher.write(session: session, event: event, token: session.publicToken,
                                eventToken: eventToken, from: dir, siblings: siblings,
                                includeOriginals: originals, includePrint: prints,
                                includeGIF: gifs)
            try publisher.commitAndPush(message: message)
        }.value

        log.info("Published \(session.id) to \(publisher.remoteURL() ?? "the site")")
    }

    /// Rebuilds and pushes every finished session — for a new site, or one that
    /// was set up after the event.
    func republishAllToPages() {
        guard pagesPublisher() != nil else {
            show(.warning, "Choose a folder for the site first.")
            return
        }
        let all = storage.sessions.filter { $0.finishedAt != nil }
        guard !all.isEmpty else {
            show(.info, "Nothing to publish yet.")
            return
        }
        for s in all { queueUpload(s) }
        show(.info, "Queued \(all.count) session(s) for the site.")
        retryUploads()
    }

    // MARK: - Album pages

    var albumOutputURL: URL? {
        let p = settings.albumOutputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return nil }
        return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The album's file name — the event's own token, so an address cannot be
    /// guessed from the client's name.
    func albumFileName(for event: EventRecord) -> String {
        let token = (event.publishedSlug ?? "").isEmpty ? event.id : (event.publishedSlug ?? "")
        return "album-\(token).html"
    }

    func albumFileURL(for event: EventRecord) -> URL? {
        albumOutputURL?.appendingPathComponent(albumFileName(for: event))
    }

    /// Where that album page lives once it has been put online. The app cannot
    /// know it — nothing here uploads the page — so the operator types the folder
    /// it is served from and this appends the file's own unguessable name.
    func albumWebURL(for event: EventRecord) -> URL? {
        var text = settings.albumBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: "\(text)/\(albumFileName(for: event))")
    }

    /// The album QR: the page where every session from the event can be seen.
    func makeAlbumQR(for event: EventRecord, side: CGFloat = 600) -> NSImage? {
        guard let url = albumWebURL(for: event) else { return nil }
        return QRCode.image(for: url.absoluteString, minimumSide: side)
    }

    /// Gives an event a password if it has none, and hands it back.
    @discardableResult
    func ensureAlbumPassword(for event: EventRecord) -> String {
        var e = event
        if e.albumPassword.trimmingCharacters(in: .whitespaces).isEmpty {
            e.albumPassword = AlbumCrypto.suggestPassword()
        }
        if (e.publishedSlug ?? "").isEmpty { e.publishedSlug = PagesPublisher.makeToken() }
        if e.albumPassword != event.albumPassword || e.publishedSlug != event.publishedSlug {
            storage.persist(event: e)
        }
        return e.albumPassword
    }

    func setAlbumPassword(_ password: String, for event: EventRecord) {
        var e = event
        e.albumPassword = password
        storage.persist(event: e)
    }

    /// Builds one album page from what is already on Cloudinary.
    ///
    /// Only sessions that have actually been uploaded are included — a page that
    /// listed photographs still sitting on the Mac would be a page of broken
    /// images at the exact moment a client first opens it.
    @discardableResult
    func buildAlbum(for event: EventRecord) -> URL? {
        guard let outDir = albumOutputURL else {
            show(.warning, "Choose a folder for album pages first.")
            return nil
        }
        guard let cloud = cloudinary else {
            show(.warning, "Set the Cloudinary cloud name and preset first.")
            return nil
        }
        let password = ensureAlbumPassword(for: event)
        let fresh = storage.event(event.id) ?? event

        let sessions = storage.sessions
            .filter { $0.eventID == event.id && $0.uploadState == .uploaded && !$0.publicToken.isEmpty }
            .sorted { $0.startedAt < $1.startedAt }
            .map { s -> AlbumSite.Session in
                let shots = s.photos.sorted { $0.index < $1.index }.compactMap { p -> AlbumSite.Shot? in
                    guard let src = cloud.photoURL(token: s.publicToken, fileName: p.fileName),
                          let save = cloud.photoSaveURL(token: s.publicToken, fileName: p.fileName)
                    else { return nil }
                    return AlbumSite.Shot(src: src.absoluteString, save: save.absoluteString, index: p.index)
                }
                var printShot: AlbumSite.Shot?
                if s.printFileName != nil,
                   let src = cloud.photoURL(token: s.publicToken, fileName: "print.jpg"),
                   let save = cloud.photoSaveURL(token: s.publicToken, fileName: "print.jpg") {
                    printShot = AlbumSite.Shot(src: src.absoluteString, save: save.absoluteString, index: 0)
                }
                var gifShot: AlbumSite.Shot?
                if GIFRenderer.enabled, s.gifFileName != nil,
                   let src = cloud.gifURL(token: s.publicToken),
                   let save = cloud.gifSaveURL(token: s.publicToken) {
                    gifShot = AlbumSite.Shot(src: src.absoluteString, save: save.absoluteString, index: 0)
                }
                return AlbumSite.Session(id: s.id, time: s.startedAt.clockStamp,
                                         shots: shots, print: printShot, gif: gifShot)
            }
            .filter { !$0.shots.isEmpty || $0.print != nil || $0.gif != nil }

        guard !sessions.isEmpty else {
            show(.warning, "No uploaded sessions in \(event.name) yet — nothing to put in an album.")
            return nil
        }

        let album = AlbumSite.Album(eventName: fresh.name,
                                    date: fresh.displayDate,
                                    venue: fresh.venue,
                                    boothName: settings.eventTitle,
                                    brandLink: customQRURL?.absoluteString,
                                    brandLabel: settings.customQRCaption,
                                    sessions: sessions)
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let html = try AlbumSite.page(for: album, password: password)
            let dest = outDir.appendingPathComponent(albumFileName(for: fresh))
            try html.data(using: .utf8)!.write(to: dest, options: .atomic)
            log.info("Album built for \(fresh.name) — \(sessions.count) session(s), \(album.photoCount) photo(s)")
            show(.info, "Album built — \(album.photoCount) photographs in \(sessions.count) session(s).")
            return dest
        } catch {
            log.error("Album build failed for \(fresh.id): \(error.localizedDescription)")
            show(.error, error.localizedDescription)
            return nil
        }
    }

    /// Rebuilds every event that has anything published.
    func buildAllAlbums() {
        let events = storage.events.filter { e in
            storage.sessions.contains { $0.eventID == e.id && $0.uploadState == .uploaded }
        }
        guard !events.isEmpty else {
            show(.info, "Nothing has been uploaded yet.")
            return
        }
        var built = 0
        for e in events where buildAlbum(for: e) != nil { built += 1 }
        show(.info, "Built \(built) album page(s).")
    }

    /// Builds the album and opens it through the local preview server, because a
    /// page opened as a file cannot unlock itself.
    func previewAlbum(for event: EventRecord) {
        guard let file = buildAlbum(for: event) else { return }
        do {
            _ = try AlbumPreviewServer.shared.start(root: file.deletingLastPathComponent())
            guard let url = AlbumPreviewServer.shared.url(for: file.lastPathComponent) else {
                throw AlbumServerError.didNotStart
            }
            NSWorkspace.shared.open(url)
            log.info("Album preview at \(url.absoluteString)")
        } catch {
            show(.error, error.localizedDescription)
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }

    func copyAlbumDetails(for event: EventRecord) {
        let password = ensureAlbumPassword(for: event)
        let where_ = albumWebURL(for: event)?.absoluteString ?? albumFileName(for: event)
        let text = "\(event.name) — private album\n\(where_)\nPassword: \(password)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show(.info, "Album name and password copied.")
    }

    // MARK: - Cloudinary

    var cloudinary: CloudinaryService? {
        let config = CloudinaryService.Config(cloudName: settings.cloudinaryCloudName,
                                              preset: settings.cloudinaryPreset)
        return config.isComplete ? CloudinaryService(config: config) : nil
    }

    /// Uploads one finished session: every photograph, the print, then the page
    /// that points at them. The page goes last on purpose — a guest who scans
    /// early gets nothing rather than a page of broken images.
    /// A session's webpage on GitHub Pages, with its photographs on Cloudinary.
    ///
    /// The split exists because of what each host will do. Cloudinary serves
    /// images happily but hands uploaded HTML over with
    /// `Content-Disposition: attachment` — tested against a live account — so a
    /// page there downloads instead of opening. GitHub Pages serves HTML and
    /// nothing else. So the page goes to one and the pictures stay on the other,
    /// and the repository holds a few kilobytes of HTML per session rather than
    /// every photograph ever taken.
    ///
    /// Cross-origin is not a problem: Cloudinary answers with
    /// `Access-Control-Allow-Origin: *`, so the page's download-all can still
    /// fetch the images it zips.
    func publishCloudinaryPage(eventID: String, sessionID: String) async throws {
        guard let publisher = pagesPublisher() else { throw PagesError.noRepo }
        guard let cloud = cloudinary else { throw CloudinaryError.notConfigured }
        guard let session = storage.sessions.first(where: { $0.id == sessionID && $0.eventID == eventID }),
              !session.publicToken.isEmpty
        else { throw UploadError.missingFiles(sessionID) }

        var event = storage.event(eventID) ?? EventRecord.unfiled
        if (event.publishedSlug ?? "").isEmpty {
            event.publishedSlug = PagesPublisher.makeToken()
            storage.persist(event: event)
        }
        let token = session.publicToken
        let eventToken = event.publishedSlug ?? token

        func ref(_ fileName: String) -> PagesTemplate.PhotoRef? {
            guard let src = cloud.photoURL(token: token, fileName: fileName),
                  let save = cloud.photoSaveURL(token: token, fileName: fileName) else { return nil }
            return PagesTemplate.PhotoRef(src: src.absoluteString, save: save.absoluteString)
        }

        let photos: [PagesTemplate.PhotoRef] = settings.uploadOriginals
            ? session.photos.sorted { $0.index < $1.index }.compactMap { ref($0.fileName) }
            : []
        let printRef = (settings.uploadPrints && session.printFileName != nil) ? ref("print.jpg") : nil
        // The loop is addressed as a GIF rather than through `ref`, whose `.jpg`
        // would hand the guest one flattened frame of it.
        let gifRef: PagesTemplate.PhotoRef? = {
            guard GIFRenderer.enabled, settings.uploadGIFs, session.gifFileName != nil,
                  let src = cloud.gifURL(token: token), let save = cloud.gifSaveURL(token: token)
            else { return nil }
            return PagesTemplate.PhotoRef(src: src.absoluteString, save: save.absoluteString)
        }()

        let videoRef: PagesTemplate.PhotoRef? = {
            guard settings.uploadVideos, session.videoFileName != nil,
                  let src = cloud.videoURL(token: token), let save = cloud.videoSaveURL(token: token)
            else { return nil }
            return PagesTemplate.PhotoRef(src: src.absoluteString, save: save.absoluteString)
        }()

        let entries: [PagesTemplate.AlbumEntry] = storage.sessions
            .filter { $0.eventID == eventID && $0.finishedAt != nil && !$0.publicToken.isEmpty }
            .sorted { $0.startedAt < $1.startedAt }
            .map { s in
                let cover = s.printFileName != nil
                    ? cloud.photoURL(token: s.publicToken, fileName: "print.jpg")
                    : s.photos.sorted { $0.index < $1.index }.first
                        .flatMap { cloud.photoURL(token: s.publicToken, fileName: $0.fileName) }
                return PagesTemplate.AlbumEntry(
                    href: "../../\(PagesPublisher.sessionPath(token: s.publicToken))/",
                    cover: cover?.absoluteString ?? "",
                    stamp: s.startedAt,
                    count: s.photos.count)
            }
        let message = "\(event.name) — \(session.id)"

        try await Task.detached(priority: .utility) {
            publisher.writeLogo()
            try publisher.writeSessionPage(session: session, event: event, token: token,
                                           eventToken: eventToken,
                                           photos: photos, print: printRef, gif: gifRef,
                                           video: videoRef)
            try publisher.writeAlbumPage(event: event, eventToken: eventToken, entries: entries)
            try publisher.commitAndPush(message: message)
        }.value
        log.info("Published the page for \(session.id) to GitHub Pages, photographs on Cloudinary")
    }

    func publishToCloudinary(eventID: String, sessionID: String) async throws {
        guard let cloud = cloudinary else { throw CloudinaryError.notConfigured }
        guard let rec = storage.sessions.first(where: { $0.id == sessionID && $0.eventID == eventID })
        else { throw UploadError.missingFiles(sessionID) }
        var event = storage.event(eventID) ?? EventRecord.unfiled

        var session = rec
        if session.publicToken.isEmpty {
            session.publicToken = PagesPublisher.makeToken()
            storage.persist(session)
        }
        if (event.publishedSlug ?? "").isEmpty {
            event.publishedSlug = PagesPublisher.makeToken()
            storage.persist(event: event)
        }
        let token = session.publicToken
        let dir = storage.directory(for: session)
        let longEdge = max(600, settings.pagesLongEdge)

        // Web copies are made in a scratch folder: the originals are the client's
        // and never leave the Mac.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("pb-cloudinary-\(token)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var uploaded = 0
        if settings.uploadOriginals {
            for photo in session.photos.sorted(by: { $0.index < $1.index }) {
                let src = dir.appendingPathComponent(photo.fileName)
                guard FileManager.default.fileExists(atPath: src.path) else { continue }
                let web = scratch.appendingPathComponent(photo.fileName)
                try await Task.detached(priority: .utility) {
                    try PagesPublisher.webCopy(from: src, to: web, longEdge: longEdge)
                }.value
                _ = try await cloud.upload(fileURL: web,
                                           publicID: CloudinaryService.photoPublicID(token: token,
                                                                                     fileName: photo.fileName),
                                           type: .image)
                uploaded += 1
            }
        }

        if settings.uploadPrints, let name = session.printFileName {
            let src = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: src.path) {
                let web = scratch.appendingPathComponent("print.jpg")
                try await Task.detached(priority: .utility) {
                    try PagesPublisher.webCopy(from: src, to: web, longEdge: max(longEdge, 1800))
                }.value
                _ = try await cloud.upload(fileURL: web,
                                           publicID: CloudinaryService.photoPublicID(token: token,
                                                                                     fileName: "print.jpg"),
                                           type: .image)
                uploaded += 1
            }
        }

        // Sent as-is. Cloudinary re-encodes a GIF it is asked to transform, and
        // the loop was already built at its delivery size.
        // Video has its own endpoint on Cloudinary; posting an MP4 to the image
        // one is refused outright.
        if settings.uploadVideos, let name = session.videoFileName {
            let src = dir.appendingPathComponent(name)
            if hasBytes(src) {
                _ = try await cloud.upload(fileURL: src,
                                           publicID: CloudinaryService.photoPublicID(token: token,
                                                                                     fileName: name),
                                           type: .video)
                uploaded += 1
            }
        }

        if GIFRenderer.enabled, settings.uploadGIFs, let name = session.gifFileName {
            let src = dir.appendingPathComponent(name)
            if hasBytes(src) {
                _ = try await cloud.upload(fileURL: src,
                                           publicID: CloudinaryService.photoPublicID(token: token,
                                                                                     fileName: GIFRenderer.fileName),
                                           type: .image)
                uploaded += 1
            }
        }

        guard uploaded > 0 else { throw CloudinaryError.nothingToUpload }
        log.info("Published \(session.id) to Cloudinary — \(uploaded) file(s)")
    }

    /// Forgets a film that is not there, once, at launch.
    ///
    /// A session recorded as having a clip that is missing or empty could never
    /// publish: the upload was refused, and the refusal took the photographs,
    /// the print and the page down with it, every quarter of an hour, for ever.
    /// Clearing the name is the whole repair — the guests lose a clip that was
    /// never written, and get the page they have been waiting for.
    private func healEmptyVideos() {
        var healed = 0
        for rec in storage.sessions {
            guard let name = rec.videoFileName else { continue }
            let url = storage.directory(for: rec).appendingPathComponent(name)
            let size = ((try? FileManager.default
                .attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
            guard size <= 0 else { continue }
            try? FileManager.default.removeItem(at: url)
            var fixed = rec
            fixed.videoFileName = nil
            storage.persist(fixed)
            healed += 1
            log.warn("Session \(rec.id) had an empty film — dropped, so the rest can publish.")
        }
        // The queue has been backing off for hours on a refusal that is now
        // gone; without this the repaired sessions would sit there for another
        // quarter of an hour saying nothing.
        if healed > 0 { uploader.clearFailures() }
    }

    /// Whether a file is there *and* has something in it.
    ///
    /// Existence alone was the old test, and an empty file passed it. Cloudinary
    /// refuses one with a 400, the refusal threw, and the throw took the whole
    /// session with it — photographs, print, loop and page — over a clip nobody
    /// had asked for. A file with nothing in it is simply not a file to send.
    private func hasBytes(_ url: URL) -> Bool {
        guard let size = (try? FileManager.default
            .attributesOfItem(atPath: url.path))?[.size] as? Int else { return false }
        return size > 0
    }

    // MARK: - QR handout

    // MARK: - Per-photo links

    /// One photograph's own address, and the code that opens it.
    struct PhotoQR: Identifiable {
        let id: Int            // the photograph's 1-based position in the session
        let url: URL
        let image: NSImage
    }

    /// Codes for each photograph of the session on the finish screen.
    @Published private(set) var photoQRs: [PhotoQR] = []
    /// The loop's own code, pointing straight at the GIF file rather than at the
    /// page around it: a guest who wants the moving one wants it in their camera
    /// roll before they walk away, not after two more taps.
    @Published private(set) var gifQRImage: NSImage?
    /// The film's own code — the thing most guests actually want to post.
    @Published private(set) var videoQRImage: NSImage?
    /// A rehearsal in progress, or nil. Watched by the console's own card.
    @Published private(set) var dryRun: DryRunProgress?
    /// Suppresses the printer for the length of a rehearsal. Everything else —
    /// the capture, the sheet, the loop, the film, the upload — is real.
    private(set) var fakePrinting = false
    private var dryRunTask: Task<Void, Never>?
    /// Where this Mac can be reached on the venue's network, and whether the
    /// server is up. Published so the console can show the operator the address
    /// they are about to ask fifty people to scan.
    @Published private(set) var localAddress: String?
    @Published private(set) var localServing = false
    @Published private(set) var localServeError: String?
    /// The code that joins the booth's wifi, built from the network's name and
    /// password rather than from anything a session knows.
    @Published private(set) var wifiQRImage: NSImage?

    /// Where one photograph opens directly, on whichever host the session goes to.
    ///
    /// On Cloudinary this is the image itself, which a phone renders and saves
    /// like any picture. That matters more than it sounds: Cloudinary delivers
    /// uploaded HTML with `Content-Disposition: attachment` — tested against a
    /// live account — so a page there downloads instead of opening. An image
    /// address is the one thing it will reliably show.
    func photoURL(for rec: SessionRecord, photo: Photo) -> URL? {
        guard !rec.publicToken.isEmpty else { return nil }
        // The local server carries every photograph a session has, whether or
        // not the originals were ever meant to be uploaded — they are on this
        // disk either way.
        if let local = localURL(for: rec) {
            return URL(string: local.absoluteString + photo.fileName)
        }
        switch settings.galleryHost {
        case .cloudinary:
            return cloudinary?.photoURL(token: rec.publicToken, fileName: photo.fileName)
        case .githubPages:
            guard let base = normalisedSiteBase else { return nil }
            return URL(string: "\(base)/\(PagesPublisher.sessionPath(token: rec.publicToken))/\(photo.fileName)")
        case .server:
            return nil
        }
    }

    func photoLinks(for rec: SessionRecord) -> [(number: Int, url: URL)] {
        // Only when the photographs are actually at the other end. Served from
        // this Mac they always are; online, only if originals are uploaded —
        // with originals off, a link to one is a perfectly formed address for an
        // image that does not exist, and a guest who gets a 404 concludes the
        // booth is broken.
        guard localURL(for: rec) != nil || settings.uploadOriginals else { return [] }
        return rec.photos.sorted { $0.index < $1.index }.compactMap { p in
            photoURL(for: rec, photo: p).map { (p.index, $0) }
        }
    }

    /// The address of the session's GIF, once it is online. Local files are no
    /// use here — a phone cannot open a path on the booth Mac.
    func gifURL(for rec: SessionRecord) -> URL? {
        guard GIFRenderer.enabled, let gif = rec.gifFileName, !rec.publicToken.isEmpty else { return nil }
        if let local = localURL(for: rec) {
            return URL(string: local.absoluteString + gif)
        }
        guard settings.uploadGIFs else { return nil }
        switch settings.galleryHost {
        case .cloudinary:
            return cloudinary?.gifURL(token: rec.publicToken)
        case .githubPages:
            guard let base = normalisedSiteBase else { return nil }
            return URL(string: "\(base)/\(PagesPublisher.sessionPath(token: rec.publicToken))/\(GIFRenderer.fileName)")
        case .server:
            return nil
        }
    }

    /// Where the session's film can be watched — this Mac at the venue, the CDN
    /// afterwards.
    func videoURL(for rec: SessionRecord) -> URL? {
        guard let name = rec.videoFileName, !rec.publicToken.isEmpty else { return nil }
        if let local = localURL(for: rec) {
            return URL(string: local.absoluteString + name)
        }
        guard settings.uploadVideos else { return nil }
        switch settings.galleryHost {
        case .cloudinary:
            return cloudinary?.videoURL(token: rec.publicToken)
        case .githubPages:
            guard let base = normalisedSiteBase else { return nil }
            return URL(string: "\(base)/\(PagesPublisher.sessionPath(token: rec.publicToken))/\(name)")
        case .server:
            return nil
        }
    }

    private func makeVideoQR(for rec: SessionRecord) -> NSImage? {
        guard settings.showQRCode else { return nil }
        if settings.qrRequiresUpload && rec.uploadState != .uploaded && localURL(for: rec) == nil {
            return nil
        }
        guard let url = videoURL(for: rec) else { return nil }
        return QRCode.image(for: url.absoluteString, minimumSide: 360)
    }

    private func makeGIFQR(for rec: SessionRecord) -> NSImage? {
        guard settings.showQRCode else { return nil }
        // Same rule as every other code here: nothing is offered before it is
        // actually online, or the guest meets an error page and assumes the
        // booth is broken.
        if settings.qrRequiresUpload && rec.uploadState != .uploaded { return nil }
        guard let url = gifURL(for: rec) else { return nil }
        return QRCode.image(for: url.absoluteString, minimumSide: 360)
    }

    private func makePhotoQRs(for rec: SessionRecord) -> [PhotoQR] {
        guard settings.showQRCode, settings.qrPerPhoto else { return [] }
        // Same rule as the session code: a guest who scans before the photograph
        // is online gets an error page and assumes the booth is broken.
        if settings.qrRequiresUpload && rec.uploadState != .uploaded { return [] }
        return photoLinks(for: rec).compactMap { link in
            // Large enough to stay crisp when the finish screen scales it up; a
            // QR is drawn without interpolation, so the source size is the ceiling.
            guard let img = QRCode.image(for: link.url.absoluteString, minimumSide: 360) else { return nil }
            return PhotoQR(id: link.number, url: link.url, image: img)
        }
    }

    func copyLink(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        show(.info, "Link copied.")
    }

    /// Address of the album page for one session on the gallery site.
    ///
    /// Built even when the Mac is offline: the session is already in the upload
    /// queue, so the link a guest scans at the venue works once the queue drains.
    func galleryURL(for rec: SessionRecord) -> URL? {
        // Cloudinary sends every HTML and SVG file as a download, so there is no
        // page to point at — only images render in a browser. The code therefore
        // opens the session's print, which is the one image that holds every
        // photograph from that session.
        if settings.galleryHost == .cloudinary {
            guard !rec.publicToken.isEmpty, let cloud = cloudinary else { return nil }
            // With a GitHub Pages site alongside, the session has a real page:
            // photographs from Cloudinary, served by a host that will render it.
            if pagesPublisher() != nil, let base = normalisedSiteBase {
                return URL(string: "\(base)/\(PagesPublisher.sessionPath(token: rec.publicToken))/")
            }
            let name = rec.printFileName != nil
                ? "print.jpg"
                : (rec.photos.sorted { $0.index < $1.index }.first?.fileName ?? "")
            guard !name.isEmpty else { return nil }
            return cloud.photoURL(token: rec.publicToken, fileName: name)
        }
        guard let text = normalisedSiteBase else { return nil }
        switch settings.galleryHost {
        case .githubPages:
            // Static hosting: one directory per session, no query string, and an
            // unguessable token instead of the date-stamped folder name.
            guard !rec.publicToken.isEmpty else { return nil }
            return URL(string: "\(text)/\(PagesPublisher.sessionPath(token: rec.publicToken))/")
        case .server:
            guard var comps = URLComponents(string: text + "/event") else { return nil }
            comps.queryItems = [
                URLQueryItem(name: "e", value: rec.eventID),
                URLQueryItem(name: "s", value: rec.id)
            ]
            return comps.url
        case .cloudinary:
            return nil          // handled above, before the site-address guard
        }
    }

    /// The site address with a scheme and no trailing slash, or nil if unset.
    var normalisedSiteBase: String? {
        var text = settings.uploadBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// The operator's own address, typed in Settings › Guest QR Code.
    ///
    /// Accepts what somebody actually types — "instagram.com/mixelbooth" as
    /// readily as the full address — but refuses anything that is not a usable
    /// URL rather than printing a code that leads nowhere.
    var customQRURL: URL? {
        var text = settings.customQRLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let host = url.host, host.contains(".") else { return nil }
        return url
    }

    /// What each of the two cards points at, for one finished session.
    ///
    /// Deliberately literal: whatever cannot be built is simply not shown. A
    /// silent substitution would put a code on the screen that sends guests
    /// somewhere the operator never chose.
    // MARK: - Rehearsal

    /// Every arrangement the booth could print, in the order the rota uses them.
    var dryRunLayouts: [DryRunLayout] {
        let builtIns: [DryRunLayout] = showsBuiltInLayouts
            ? PrintLayout.allCases.map { .builtIn($0) } : []
        return builtIns + templates.templates.map { .template(id: $0.id, name: $0.name) }
    }

    var isDryRunning: Bool { dryRunTask != nil }

    /// Photographs `plan.customers` imaginary groups, one after another.
    ///
    /// Deliberately the booth's own session machinery rather than a copy of it:
    /// a rehearsal that exercised a parallel code path would prove nothing about
    /// the one an event uses. The only things changed for the duration are the
    /// printer (suppressed), the event (its own, so a client's album is not
    /// filled with test shots) and the finish screen's wait for a press.
    func startDryRun(_ plan: DryRunPlan) {
        guard !isDryRunning else { return }
        guard !state.isSessionActive else {
            show(.warning, "Finish the session that is running first.")
            return
        }
        guard cameraState.isReady else {
            show(.error, "The camera is not ready — \(cameraState.label)")
            return
        }
        let rota = dryRunLayouts
        guard !rota.isEmpty else { return }

        // Its own event, created once and reused, so a rehearsal never lands in
        // a client's folder or their album.
        let name = "Dry run"
        let event = storage.events.first { $0.name == name }
            ?? createEvent(name: name, client: "", venue: "", date: Date(),
                           notes: "Rehearsals. Safe to delete.")
        guard let event else { return }

        let previousEvent = settings.activeEventID
        let previousHold = settings.holdFinishUntilPress
        let previousLayout = settings.layout
        let previousTemplate = settings.activeTemplateID
        let previousUploads = settings.uploadEnabled

        setActiveEvent(event.id)
        settingsService.settings.holdFinishUntilPress = false
        if !plan.uploads { settingsService.settings.uploadEnabled = false }
        fakePrinting = true
        dryRun = DryRunProgress(customer: 1, total: plan.customers,
                                layout: rota[0].name, note: "Starting")
        log.info("Dry run started — \(plan.customers) customer(s), printing suppressed")

        dryRunTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.fakePrinting = false
                self.settingsService.settings.holdFinishUntilPress = previousHold
                self.settingsService.settings.uploadEnabled = previousUploads
                self.settingsService.settings.layout = previousLayout
                self.settingsService.settings.activeTemplateID = previousTemplate
                self.setActiveEvent(previousEvent)
                self.dryRunTask = nil
                self.log.info("Dry run finished")
            }

            for customer in 1...max(1, plan.customers) {
                if Task.isCancelled { self.dryRun = nil; return }
                let choice = plan.cycleLayouts
                    ? rota[(customer - 1) % rota.count]
                    : (previousTemplate.isEmpty ? DryRunLayout.builtIn(previousLayout)
                                                : rota.first { $0.id == "tpl-\(previousTemplate)" } ?? rota[0])
                switch choice {
                case .builtIn(let l):        self.useBuiltInLayout(l)
                case .template(let id, _):   self.useTemplate(id)
                }
                self.dryRun = DryRunProgress(customer: customer, total: plan.customers,
                                             layout: choice.name, note: "Photographing")

                self.startSession()
                guard self.state.isSessionActive || self.sessionTask != nil else {
                    self.dryRun?.failure = "The booth would not start a session."
                    return
                }
                await self.sessionTask?.value

                if case .failed(let why) = self.state {
                    self.dryRun?.failure = why
                    self.log.warn("Dry run stopped at customer \(customer): \(why)")
                    return
                }
                if Task.isCancelled { self.dryRun = nil; return }

                self.dryRun = DryRunProgress(customer: customer, total: plan.customers,
                                             layout: choice.name, note: "Published")
                // Long enough to see the finish screen land, short enough that a
                // rehearsal of ten does not become a coffee break.
                try? await Task.sleep(nanoseconds: UInt64(max(0.5, plan.gap) * 1_000_000_000))
                self.returnToIdle()
            }
            self.dryRun = DryRunProgress(customer: plan.customers + 1, total: plan.customers,
                                         layout: "", note: "Done")
        }
    }

    func stopDryRun() {
        dryRunTask?.cancel()
        dryRunTask = nil
        fakePrinting = false
        cancelSession()
        dryRun = nil
        log.info("Dry run stopped by the operator")
    }

    /// Clears a finished rehearsal's summary off the card.
    func clearDryRun() { if dryRunTask == nil { dryRun = nil } }

    // MARK: - The session's film

    /// One live-view frame into the clip.
    ///
    /// Started on the first frame rather than when the session does: the frame
    /// is what says how big the clip should be, and a booth whose camera is
    /// warming up would otherwise fix the shape from a guess.
    private func recordVideoFrame(_ img: NSImage) {
        guard videoWanted, state.isSessionActive else { return }
        if !videoRecorder.isRecording {
            guard let rec = currentSession else { return }
            let long = CGFloat(max(360, min(settings.videoLongEdge, 1080)))
            let w = img.size.width, h = img.size.height
            guard w > 0, h > 0 else { return }
            let scale = min(long / max(w, h), 1)
            let size = CGSize(width: w * scale, height: h * scale)
            let url = storage.directory(for: rec).appendingPathComponent(SessionVideoRecorder.fileName)
            do {
                try videoRecorder.start(url: url, size: size, fps: settings.liveViewFPS)
                log.info("Recording the session film at \(Int(size.width))×\(Int(size.height))")
            } catch {
                videoWanted = false
                log.warn("Could not start the session film: \(error.localizedDescription)")
                return
            }
        }
        // The preview can arrive faster than the clip needs; sampling here keeps
        // the encoder off the main thread's back during a countdown.
        let gap = 1.0 / Double(max(8, min(settings.liveViewFPS, 30)))
        guard Date().timeIntervalSince(videoLastFrame) >= gap else { return }
        videoLastFrame = Date()
        videoRecorder.append(img)
    }

    /// The shutter and the photograph it took, held the way the guests saw them.
    private func recordVideoShot(_ jpeg: Data) {
        guard videoWanted, videoRecorder.isRecording else { return }
        let size = CGSize(width: 1280, height: 720)
        if let flash = SessionVideoRecorder.flash(size: size) {
            videoRecorder.hold(flash, seconds: 0.12)
        }
        if let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
           let shot = CGImageSourceCreateThumbnailAtIndex(src, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: max(360, min(settings.videoLongEdge, 1080))
           ] as CFDictionary) {
            videoRecorder.hold(shot, seconds: max(0.3, min(settings.videoHoldSeconds, 4)))
        }
    }

    /// Closes the film: a branded card on the end, then the file.
    private func finishVideo(for session: inout SessionRecord) async {
        guard videoWanted, videoRecorder.isRecording else { return }
        // Before anything is awaited. Closing the file takes a moment, the live
        // view goes on delivering frames while it does, and a frame arriving
        // with this still set is all it takes to start a second film writing
        // over the one being finished.
        videoWanted = false
        if settings.videoEndCard {
            let size = CGSize(width: 1280, height: 720)
            let logo = BrandingAssets.url(for: settings.idleLogoFile)
                .flatMap { NSImage(contentsOf: $0) }
                .flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
            if let card = SessionVideoRecorder.card(size: size,
                                                    backgroundHex: "#000000",
                                                    logo: logo,
                                                    title: settings.eventTitle,
                                                    subtitle: activeEvent?.name ?? "") {
                videoRecorder.hold(card, seconds: 1.6)
            }
        }
        do {
            let url = try await videoRecorder.finish()
            session.videoFileName = url.lastPathComponent
            let mb = Double((try? Data(contentsOf: url).count) ?? 0) / 1_048_576
            log.info("Session film saved — \(String(format: "%.1f", mb)) MB")
        } catch {
            // Never fatal. The guests have their photographs, their print and
            // their loop; the film is the one thing here nobody waits for.
            log.warn("No film for \(session.id): \(error.localizedDescription)")
        }
    }

    /// Pushes an empty page at this session's address as it starts.
    ///
    /// GitHub Pages takes twenty-odd seconds to build a push, so a code printed
    /// on a strip leads nowhere for the first half-minute of its life — which is
    /// exactly when a guest scans it. The token is assigned when the session is
    /// created, so the address is known before the first shot: pushing a holding
    /// page now means the build happens while the guests are still posing, and
    /// the real page replaces it when the photographs land.
    ///
    /// Deliberately best-effort and off the main actor. A booth with no
    /// connection carries on exactly as before; it simply has nothing to reserve.
    private func reserveSessionPage(_ rec: SessionRecord) {
        guard settings.uploadEnabled, !rec.publicToken.isEmpty else { return }
        guard settings.galleryHost == .githubPages || settings.galleryHost == .cloudinary else { return }
        guard let publisher = pagesPublisher() else { return }
        guard let event = activeEvent else { return }
        let token = rec.publicToken
        Task.detached(priority: .utility) {
            do {
                try publisher.writeHoldingPage(session: rec, event: event, token: token)
                try publisher.commitAndPush(message: "\(event.name) — \(rec.id) starting")
                Log.shared.info("Reserved the page for \(rec.id) while the session runs")
            } catch {
                // Nothing is broken by this failing: the page is published again
                // when the session finishes, as it always was.
                Log.shared.warn("Could not reserve the page for \(rec.id): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Serving from this Mac

    /// Starts, stops or re-points the local gallery to match the settings.
    ///
    /// Everything about it is recoverable: a port already taken, a network that
    /// has not come up, a booth carried between rooms. The operator is told
    /// once, the codes fall back to the online address, and the next session
    /// tries again.
    func applyLocalServing(_ s: AppSettings) {
        guard s.localServeEnabled else {
            if LocalGalleryServer.shared.isRunning { LocalGalleryServer.shared.stop() }
            localServing = false
            localServeError = nil
            localAddress = nil
            wifiQRImage = nil
            return
        }
        do {
            _ = try LocalGalleryServer.shared.start(port: UInt16(max(1024, min(s.localServePort, 65535))))
            localServing = true
            localServeError = nil
        } catch {
            localServing = false
            localServeError = error.localizedDescription
            log.warn("Local gallery: \(error.localizedDescription)")
        }
        refreshLocalAddress()
        publishLocalSessions()
        // Nothing is put on the guest screen when the operator has asked for no
        // codes there — a booth whose whole point is the printed code should not
        // sprout a wifi card.
        wifiQRImage = s.showQRCode
            ? WiFiQR.payload(ssid: s.localWiFiSSID, password: s.localWiFiPassword)
                .flatMap { QRCode.image(for: $0, minimumSide: 360) }
            : nil
    }

    /// Re-reads this Mac's address. DHCP hands out a different one at every
    /// venue — and sometimes at the same venue after a router reboot — so this
    /// is checked rather than remembered.
    func refreshLocalAddress() {
        let found = LocalGalleryServer.host(override: settings.localServeHost)
        if found != localAddress { localAddress = found }
    }

    /// Hands the server a fresh snapshot of every finished session, so a booth
    /// restarted in the middle of an event still answers the codes already in
    /// people's pockets.
    func publishLocalSessions() {
        guard settings.localServeEnabled else { return }
        let events = Dictionary(uniqueKeysWithValues: storage.events.map { ($0.id, $0.name) })
        let list: [LocalGalleryServer.Session] = storage.sessions
            .filter { $0.finishedAt != nil && !$0.publicToken.isEmpty }
            .map { rec in
                LocalGalleryServer.Session(
                    token: rec.publicToken,
                    eventName: events[rec.eventID] ?? settings.eventTitle,
                    startedAt: rec.startedAt,
                    directory: storage.directory(for: rec),
                    photoFiles: rec.photos.sorted { $0.index < $1.index }.map(\.fileName),
                    printFile: rec.printFileName,
                    gifFile: GIFRenderer.enabled ? rec.gifFileName : nil,
                    videoFile: rec.videoFileName)
            }
        LocalGalleryServer.shared.publish(sessions: list,
                                          siteTitle: settings.eventTitle,
                                          brandLink: customQRURL?.absoluteString,
                                          brandLabel: settings.customQRCaption,
                                          logoFile: settings.idleLogoFile.isEmpty ? nil : settings.idleLogoFile,
                                          retentionDays: max(0, settings.photoRetentionDays))
    }

    /// This session's address on the venue's own network — nil when serving is
    /// off, the Mac is on no network, or the session has no token yet.
    func localURL(for rec: SessionRecord) -> URL? {
        guard settings.localServeEnabled, localServing, !rec.publicToken.isEmpty,
              let host = localAddress
        else { return nil }
        return LocalGalleryServer.sessionURL(token: rec.publicToken, host: host,
                                             port: LocalGalleryServer.shared.port)
    }

    func qrPayloads(for rec: SessionRecord) -> (album: String?, brand: String?) {
        let album = galleryURL(for: rec)?.absoluteString
        let brand = customQRURL?.absoluteString
        switch settings.qrTarget {
        case .sessionAlbum: return (album, nil)
        case .customLink:   return (nil, brand)
        case .eventAlbum:
            // The whole event, on the web. Needs an event to belong to — a
            // session with none has nothing to point at.
            let page = activeEvent.flatMap { albumWebURL(for: $0)?.absoluteString }
            return (page, nil)
        case .both:         return (album, brand)
        }
    }

    /// The single code that fits in the 4×6 footer. With both cards on screen the
    /// sheet carries the photo link — the print is theirs, and the screen they
    /// scanned the other code from is gone by then.
    func printQRPayload(for rec: SessionRecord) -> String? {
        let p = qrPayloads(for: rec)
        return p.album ?? p.brand
    }

    /// The photos code — but only once there are photographs at the other end of
    /// it. A code scanned at a venue with no internet leads to nothing yet, and a
    /// guest who gets a "not found" assumes their photographs are lost rather
    /// than still in a queue. The printed sheet keeps its code either way: paper
    /// is scanned at home, by which time the upload has long since caught up.
    func makeQR(for rec: SessionRecord, side: CGFloat = 600) -> NSImage? {
        guard settings.showQRCode || settings.printQRCode else { return nil }
        // Served from this Mac when it can be: the photographs are already here,
        // so there is nothing to wait for and no internet to depend on. The
        // sheet's own code is built separately and keeps the lasting address.
        if let local = localURL(for: rec) {
            return QRCode.image(for: local.absoluteString, minimumSide: side)
        }
        if settings.qrRequiresUpload && rec.uploadState != .uploaded { return nil }
        guard let payload = qrPayloads(for: rec).album else { return nil }
        return QRCode.image(for: payload, minimumSide: side)
    }

    /// The operator's own code. Built from settings alone, so Admin can preview
    /// it without a session in hand.
    /// Why no code can be built, in the operator's words — nil when all is well.
    var qrTargetProblem: String? {
        if settings.qrTarget == .eventAlbum {
            if settings.albumBaseURL.trimmingCharacters(in: .whitespaces).isEmpty {
                return "Set the album web address under Control › Album Page before the code can point at it."
            }
            if activeEvent == nil { return "No event chosen, so there is no album to point at." }
            return nil
        }
        let needsAlbum = settings.qrTarget != .customLink
        let needsLink  = settings.qrTarget != .sessionAlbum
        let haveAlbum  = settings.galleryHost == .cloudinary
            ? cloudinary != nil
            : !settings.uploadBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
        let haveLink   = customQRURL != nil
        if needsAlbum && !haveAlbum && needsLink && !haveLink {
            return "Set the gallery address or type a link — the QR code has nowhere to point."
        }
        if needsAlbum && !haveAlbum {
            if settings.qrTarget == .both { return "No gallery set up, so only your own link is shown." }
            return settings.galleryHost == .cloudinary
                ? "Set the Cloudinary cloud name and upload preset under Control › Gallery Site."
                : "Set the gallery site address under Control › Gallery Site."
        }
        if needsLink && !haveLink {
            return settings.customQRLink.trimmingCharacters(in: .whitespaces).isEmpty
                ? "Type the link the QR code should open."
                : "That link does not look like a web address — check it in Settings › Guest QR Code."
        }
        return nil
    }

    func makeBrandQR(side: CGFloat = 600) -> NSImage? {
        guard let url = customQRURL else { return nil }
        return QRCode.image(for: url.absoluteString, minimumSide: side)
    }

    func copyGalleryLink(for rec: SessionRecord) {
        guard let url = galleryURL(for: rec) else {
            show(.warning, "Set the gallery site address in Settings first.")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        show(.info, "Album link copied.")
    }

    // MARK: Banner

    func show(_ kind: BannerMessage.Kind, _ text: String) {
        banner = BannerMessage(kind: kind, text: text)
        let token = banner?.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if self.banner?.id == token { self.banner = nil }
        }
    }

    /// Seconds since the running session started — drives the viewfinder timecode.
    var sessionElapsed: TimeInterval {
        guard let s = currentSession else { return 0 }
        return Date().timeIntervalSince(s.startedAt)
    }

    // MARK: Guest-facing progress

    var progress: (shot: Int, total: Int)? {
        switch state {
        case .countdown(let s, let t, _), .capturing(let s, let t),
             .photoPreview(let s, let t), .interval(let s, let t),
             .retaking(let s, let t):
            return (s, t)
        default: return nil
        }
    }
}
