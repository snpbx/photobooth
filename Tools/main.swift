import AppKit
import SwiftUI

// Offscreen UI harness: renders the real SwiftUI screens at given sizes to PNG,
// so layout can be checked at every responsive breakpoint without a display.

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])

/// Runs one async check to completion from the harness's synchronous flow.
func await_check(_ cloud: CloudinaryService) throws -> String {
    var result: Result<String, Error>?
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        do { result = .success(try await cloud.check()) } catch { result = .failure(error) }
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 30)
    switch result {
    case .success(let s): return s
    case .failure(let e): throw e
    case nil: throw CloudinaryError.badResponse
    }
}
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// MARK: - Layout proofs
//
// Renders each 4×6 layout from synthetic 3:2 frames that mimic what the 6D
// delivers, so slot geometry and centre-cropping can be checked without a camera.

func makeTestPhoto(number: Int, size: CGSize) -> Data? {
    let hues: [CGFloat] = [0.02, 0.09, 0.15, 0.33, 0.48, 0.55, 0.72, 0.85]
    let hue = hues[(number - 1) % hues.count]
    guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    let base = NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1)
    ctx.setFillColor(base.cgColor)
    ctx.fill(CGRect(origin: .zero, size: size))

    // Edge band: whatever the crop trims will be visibly missing from the proof.
    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.55).cgColor)
    ctx.setLineWidth(size.height * 0.035)
    ctx.stroke(CGRect(origin: .zero, size: size).insetBy(dx: size.height * 0.02, dy: size.height * 0.02))

    // Centre circle: must stay centred and perfectly round in every layout.
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
    let r = size.height * 0.30
    ctx.fillEllipse(in: CGRect(x: size.width / 2 - r, y: size.height / 2 - r, width: r * 2, height: r * 2))

    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size.height * 0.30, weight: .black),
        .foregroundColor: NSColor.black
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\(number)", attributes: attrs))
    let b = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    ctx.textPosition = CGPoint(x: size.width / 2 - b.width / 2 - b.minX,
                               y: size.height / 2 - b.height / 2 - b.minY)
    CTLineDraw(line, ctx)

    guard let img = ctx.makeImage() else { return nil }
    return LayoutRenderer.jpegData(from: img, dpi: 300)
}

func renderLayoutProofs() {
    let tmp = outDir.appendingPathComponent("_frames")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

    var urls: [URL] = []
    for i in 1...8 {
        guard let d = makeTestPhoto(number: i, size: CGSize(width: 1800, height: 1200)) else { continue }
        let u = tmp.appendingPathComponent(String(format: "frame-%02d.jpg", i))
        try? d.write(to: u)
        urls.append(u)
    }

    for mode in CropMode.allCases {
        for layout in PrintLayout.allCases {
            // Both footer shapes: plain, and the taller one with the QR code —
            // the duplicate-strip sheet has to hold two of either.
            for withQR in [false, true] where mode == .fill || !withQR {
                var s = AppSettings()
                s.cropMode = mode
                s.eventTitle = "MIXEL PHOTOBOOTH"
                if let bg = ProcessInfo.processInfo.environment["PB_BG"] { s.backgroundHex = bg }
                s.printQRCode = withQR
                s.qrCaption = "SCAN TO GET YOUR PHOTOS"
                let take = Array(urls.prefix(layout.photoCount))
                guard let data = try? LayoutRenderer.renderPrint(
                    photos: take, layout: layout, settings: s,
                    qrPayload: withQR ? "https://res.cloudinary.com/wdhofaeh/image/upload/booth/abcd123456/print.jpg" : nil)
                else { print("render failed: \(layout.rawValue)"); continue }
                let name = "layout-\(layout.rawValue)-\(mode.rawValue)\(withQR ? "-qr" : "").jpg"
                try? data.write(to: outDir.appendingPathComponent(name))
                print("wrote \(name) (\(data.count / 1024) KB)")
            }
        }
    }
    try? FileManager.default.removeItem(at: tmp)
}

renderLayoutProofs()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let controller = BoothController()

    struct Shot { let name: String; let size: CGSize; let make: (BoothController) -> AnyView }

    // The harness shares the real settings file; keep it on the DSLR + local site
    // so a screenshot run never leaves the app pointed somewhere odd.
    controller.settingsService.settings.cameraBackend = .dslr

    var shots: [Shot] = []
    for (label, w, h) in [("admin-1440x900", 1440.0, 900.0),
                          ("admin-1180x760", 1180.0, 760.0),
                          ("admin-780x900",  780.0,  900.0)] {
        shots.append(Shot(name: label, size: CGSize(width: w, height: h)) { c in
            c.settingsService.settings.lastAdminTab = "Control"
            return AnyView(AdminRootView(c: c))
        })
    }
    for (label, tabName, w, h) in [("gallery-1440x900", "Sessions", 1440.0, 900.0),
                                   ("gallery-820x900",  "Sessions", 820.0, 900.0),
                                   ("settings-1440x900", "Settings", 1440.0, 900.0)] {
        shots.append(Shot(name: label, size: CGSize(width: w, height: h)) { c in
            c.settingsService.settings.lastAdminTab = tabName
            return AnyView(AdminRootView(c: c))
        })
    }
    shots.append(Shot(name: "booth-idle-1024x768", size: CGSize(width: 1024, height: 768)) {
        AnyView(BoothRootView(c: $0))
    })
    shots.append(Shot(name: "booth-idle-1600x900", size: CGSize(width: 1600, height: 900)) {
        AnyView(BoothRootView(c: $0))
    })

    // Walk a real session with the built-in camera so the countdown, capture,
    // preview and finish screens are captured from live state, not mock-ups.
    if CommandLine.arguments.contains("--session") {
        controller.settingsService.settings.cameraBackend = .demo
        controller.settingsService.settings.countdownSeconds = 3
        controller.settingsService.settings.previewSeconds = 2
        controller.settingsService.settings.shotIntervalSeconds = 1
        controller.settingsService.settings.autoPrint = false   // never queue a demo print
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        print("camera: \(controller.cameraState.label)")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: BoothRootView(c: controller))
        host.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        window.contentView = host
        window.orderBack(nil)

        @MainActor func grab(_ name: String) {
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let d = rep.representation(using: .png, properties: [:]) {
                try? d.write(to: outDir.appendingPathComponent("\(name).png"))
                print("wrote \(name).png — state \(controller.state.name)")
            }
        }

        grab("session-00-idle-ready")
        controller.startSession()

        // Sample across the session; each grab is labelled with the live state.
        for i in 0..<30 {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            grab(String(format: "session-%02d", i + 1))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        grab("session-99-final")
        window.orderOut(nil)
        exit(0)
    }

    // The album code: a QR for the page where the whole event can be seen online.
    if CommandLine.arguments.contains("--albumqr") {
        controller.settingsService.settings.cameraBackend = .demo
        controller.settingsService.settings.countdownSeconds = 1
        controller.settingsService.settings.previewSeconds = 0.3
        controller.settingsService.settings.shotIntervalSeconds = 0.3
        controller.settingsService.settings.layout = .fourFullPage
        controller.settingsService.settings.autoPrint = false
        controller.settingsService.settings.holdFinishUntilPress = true
        controller.settingsService.settings.finishHoldTimeoutSeconds = 0
        controller.settingsService.settings.eventTitle = "MIXEL PHOTOBOOTH"
        controller.settingsService.settings.galleryHost = .cloudinary
        controller.settingsService.settings.cloudinaryCloudName =
            ProcessInfo.processInfo.environment["PB_CLOUD"] ?? "mixeltest"
        controller.settingsService.settings.cloudinaryPreset =
            ProcessInfo.processInfo.environment["PB_PRESET"] ?? "photobooth"
        controller.settingsService.settings.uploadEnabled = true
        controller.settingsService.settings.showQRCode = true
        controller.settingsService.settings.printQRCode = true
        controller.settingsService.settings.qrRequiresUpload = true
        controller.settingsService.settings.qrTarget = .eventAlbum
        controller.settingsService.settings.qrCaption = "SCAN FOR THE WHOLE ALBUM"
        controller.settingsService.settings.albumOutputPath = outDir.path
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: BoothRootView(c: controller))
        host.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        window.contentView = host
        window.orderBack(nil)
        @MainActor func settle(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        @MainActor func grab(_ name: String) {
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let d = rep.representation(using: .png, properties: [:]) {
                try? d.write(to: outDir.appendingPathComponent("\(name).png"))
            }
        }

        guard let ev = controller.createEvent(name: "Album Code Rehearsal", client: "Bench",
                                              venue: "Studio", date: Date(), notes: "") else { exit(1) }

        // No address yet: the booth must say so rather than show a dead code.
        print("ALBUMQR problem with no address: \(controller.qrTargetProblem ?? "none")")
        controller.settingsService.settings.albumBaseURL = "https://photos.mixel.ph/albums"
        settle(0.5)
        let fresh = controller.storage.event(ev.id) ?? ev
        _ = controller.ensureAlbumPassword(for: fresh)
        let refreshed = controller.storage.event(ev.id) ?? fresh
        print("ALBUMQR web url: \(controller.albumWebURL(for: refreshed)?.absoluteString ?? "none")")
        print("ALBUMQR problem now: \(controller.qrTargetProblem ?? "none")")

        controller.startSession()
        for _ in 0..<60 {
            settle(0.5)
            if case .complete = controller.state { break }
            if case .failed(let m) = controller.state { print("ALBUMQR failed: \(m)"); exit(1) }
        }
        for _ in 0..<30 {
            settle(1)
            if controller.currentSession?.uploadState == .uploaded { break }
        }
        settle(1.5)
        print("ALBUMQR state: \(controller.state.name) code shown: \(controller.sessionQRImage != nil)")
        grab("albumqr-finish")

        if let rec = controller.currentSession {
            print("ALBUMQR printed payload: \(controller.printQRPayload(for: rec) ?? "none")")
            let dir = controller.storage.directory(for: rec)
            if let n = rec.printFileName {
                try? FileManager.default.copyItem(at: dir.appendingPathComponent(n),
                                                  to: outDir.appendingPathComponent("albumqr-print.jpg"))
            }
        }
        controller.deleteEvent(ev)
        window.orderOut(nil)
        exit(0)
    }

    // The idle screen showing the camera.
    if CommandLine.arguments.contains("--idlelive") {
        controller.settingsService.settings.cameraBackend = .demo
        controller.settingsService.settings.eventTitle = "MIXEL PHOTOBOOTH"
        controller.settingsService.settings.idleHeadline = "PRESS BUTTON TO START"
        controller.settingsService.settings.idleSubhead = "Say cheese"
        controller.settingsService.settings.liveViewEnabled = true
        controller.settingsService.settings.idleLiveView = true
        controller.settingsService.settings.uploadEnabled = false
        RunLoop.main.run(until: Date().addingTimeInterval(2))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: BoothRootView(c: controller))
        host.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        window.contentView = host
        window.orderBack(nil)
        @MainActor func settle(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        @MainActor func grab(_ name: String) {
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let d = rep.representation(using: .png, properties: [:]) {
                try? d.write(to: outDir.appendingPathComponent("\(name).png"))
            }
        }

        guard let ev = controller.createEvent(name: "Idle Rehearsal", client: "Bench",
                                              venue: "Studio", date: Date(), notes: "") else { exit(1) }

        // The console counts as a reason to run the camera, so it has to be out
        // of the way before the idle path can be judged on its own.
        controller.noteAdminWindow(visible: false)

        // Closed booth window: nothing should be running the camera.
        controller.noteBoothWindow(open: false)
        settle(2)
        print("IDLE window closed — live frame: \(controller.liveFrame != nil)  (expect false)")

        // Opened: the preview starts without a session.
        controller.noteBoothWindow(open: true)
        for _ in 0..<20 {
            settle(0.5)
            if controller.liveFrame != nil { break }
        }
        print("IDLE window open — state \(controller.state.name), live frame: \(controller.liveFrame != nil)  (expect true)")
        settle(1.5)
        grab("idle-live-on")

        // Switched off: back to the empty field, camera released.
        controller.settingsService.settings.idleLiveView = false
        settle(2.5)
        print("IDLE preview off — live frame: \(controller.liveFrame != nil)  (expect false)")
        print("IDLE   idleLiveView=\(controller.settings.idleLiveView) liveViewEnabled=\(controller.settings.liveViewEnabled) boothOpen=\(controller.boothWindowOpen) adminVisible=\(controller.adminWindowVisible) state=\(controller.state.name)")
        settle(1)
        grab("idle-live-off")

        controller.deleteEvent(ev)
        window.orderOut(nil)
        exit(0)
    }

    // The photos code must not appear while the photographs are still on the Mac.
    if CommandLine.arguments.contains("--offlineqr") {
        let cdnRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PB_CDN_ROOT"] ?? "/tmp/pb-cdn")
        let marker = cdnRoot.appendingPathComponent(".offline")
        try? FileManager.default.createDirectory(at: cdnRoot, withIntermediateDirectories: true)
        try? Data().write(to: marker)                       // the venue has no internet

        controller.settingsService.settings.cameraBackend = .demo
        controller.settingsService.settings.countdownSeconds = 1
        controller.settingsService.settings.previewSeconds = 0.3
        controller.settingsService.settings.shotIntervalSeconds = 0.3
        controller.settingsService.settings.layout = .fourFullPage
        controller.settingsService.settings.autoPrint = false
        controller.settingsService.settings.holdFinishUntilPress = true
        controller.settingsService.settings.finishHoldTimeoutSeconds = 0
        controller.settingsService.settings.eventTitle = "MIXEL PHOTOBOOTH"
        controller.settingsService.settings.galleryHost = .cloudinary
        controller.settingsService.settings.cloudinaryCloudName = "mixeltest"
        controller.settingsService.settings.cloudinaryPreset = "photobooth"
        controller.settingsService.settings.uploadEnabled = true
        controller.settingsService.settings.showQRCode = true
        controller.settingsService.settings.printQRCode = true
        controller.settingsService.settings.qrRequiresUpload = true
        controller.settingsService.settings.qrTarget = .both
        controller.settingsService.settings.customQRLink = "instagram.com/mixel_ph"
        controller.settingsService.settings.customQRCaption = "FOLLOW US"
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: BoothRootView(c: controller))
        host.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        window.contentView = host
        window.orderBack(nil)
        @MainActor func settle(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        @MainActor func grab(_ name: String) {
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let d = rep.representation(using: .png, properties: [:]) {
                try? d.write(to: outDir.appendingPathComponent("\(name).png"))
            }
        }

        guard let ev = controller.createEvent(name: "Barn Party", client: "Bench",
                                              venue: "Tagaytay", date: Date(), notes: "") else { exit(1) }
        controller.startSession()
        for _ in 0..<60 {
            settle(0.5)
            if case .complete = controller.state { break }
            if case .failed(let m) = controller.state { print("OFFQR failed: \(m)"); exit(1) }
        }
        settle(4)     // give the uploader its failing attempt
        print("OFFQR state: \(controller.state.name)")
        print("OFFQR upload: \(controller.currentSession?.uploadState.rawValue ?? "?")")
        print("OFFQR photos code shown: \(controller.sessionQRImage != nil)  (expect false)")
        print("OFFQR own code shown: \(controller.brandQRImage != nil)  (expect true)")
        settle(1.2)
        grab("offqr-1-no-internet")

        // The van gets signal, or the venue's wifi comes back.
        try? FileManager.default.removeItem(at: marker)
        controller.retryUploads()
        for _ in 0..<30 {
            settle(1)
            if controller.currentSession?.uploadState == .uploaded { break }
        }
        settle(1)
        print("OFFQR after reconnect — state: \(controller.state.name)")
        print("OFFQR upload: \(controller.currentSession?.uploadState.rawValue ?? "?")")
        print("OFFQR photos code shown: \(controller.sessionQRImage != nil)  (expect true)")
        settle(1.2)
        grab("offqr-2-back-online")

        controller.deleteEvent(ev)
        window.orderOut(nil)
        exit(0)
    }

    // The private album page, built from sessions actually on Cloudinary.
    if CommandLine.arguments.contains("--album") {
        controller.settingsService.settings.cameraBackend = .demo
        controller.settingsService.settings.countdownSeconds = 1
        controller.settingsService.settings.previewSeconds = 0.3
        controller.settingsService.settings.shotIntervalSeconds = 0.3
        controller.settingsService.settings.layout = .fourFullPage
        controller.settingsService.settings.autoPrint = false
        controller.settingsService.settings.holdFinishUntilPress = false
        controller.settingsService.settings.completeScreenSeconds = 1
        controller.settingsService.settings.eventTitle = "MIXEL PHOTOBOOTH"
        controller.settingsService.settings.galleryHost = .cloudinary
        controller.settingsService.settings.cloudinaryCloudName =
            ProcessInfo.processInfo.environment["PB_CLOUD"] ?? "mixeltest"
        controller.settingsService.settings.cloudinaryPreset =
            ProcessInfo.processInfo.environment["PB_PRESET"] ?? "photobooth"
        controller.settingsService.settings.uploadEnabled = true
        controller.settingsService.settings.customQRLink = "instagram.com/mixel_ph"
        controller.settingsService.settings.customQRCaption = "Follow us"
        controller.settingsService.settings.albumOutputPath = outDir.path
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))

        @MainActor func settle(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

        guard let ev = controller.createEvent(name: "Cruz & Santos Wedding", client: "Ana Cruz",
                                              venue: "Manila Hotel", date: Date(), notes: "") else { exit(1) }
        for _ in 1...2 {
            controller.startSession()
            for _ in 0..<60 {
                settle(0.5)
                if case .complete = controller.state { break }
                if case .idle = controller.state { break }
                if case .failed(let m) = controller.state { print("ALBUM session failed: \(m)"); exit(1) }
            }
            settle(2)
        }
        for _ in 0..<40 {
            settle(1)
            if controller.uploader.pendingCount == 0 { break }
        }
        print("ALBUM uploads pending: \(controller.uploader.pendingCount)")

        let fresh = controller.storage.event(ev.id) ?? ev
        let password = controller.ensureAlbumPassword(for: fresh)
        print("ALBUM password: \(password)")
        guard let file = controller.buildAlbum(for: controller.storage.event(ev.id) ?? fresh) else {
            print("ALBUM build failed"); exit(1)
        }
        print("ALBUM file: \(file.lastPathComponent)")
        let html = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        print("ALBUM bytes: \(html.count)")
        // The page must not leak what it is protecting.
        for secret in ["Cruz & Santos", "Manila Hotel", "res.cloudinary.com/", password] {
            print("ALBUM leaks \"\(secret)\": \(html.contains(secret))")
        }

        // The preview server: the only way to open one of these pages locally.
        do {
            let port = try AlbumPreviewServer.shared.start(root: outDir)
            let url = AlbumPreviewServer.shared.url(for: file.lastPathComponent)!
            print("ALBUM preview: \(url.absoluteString)")
            var served: String?
            var status: Int = 0
            let sem = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: url) { d, r, _ in
                status = (r as? HTTPURLResponse)?.statusCode ?? 0
                served = d.map { String(decoding: $0.prefix(80), as: UTF8.self) }
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 10)
            print("ALBUM preview port: \(port) http=\(status) starts=\(served?.hasPrefix("<!doctype html") == true)")
            // and it must refuse anything that is not an album page
            var traversal = 0
            if let bad = URL(string: "http://127.0.0.1:\(port)/../../../etc/passwd") {
                let s2 = DispatchSemaphore(value: 0)
                URLSession.shared.dataTask(with: bad) { _, r, _ in
                    traversal = (r as? HTTPURLResponse)?.statusCode ?? 0
                    s2.signal()
                }.resume()
                _ = s2.wait(timeout: .now() + 10)
            }
            print("ALBUM traversal blocked: \(traversal == 404)")
            AlbumPreviewServer.shared.stop()
        } catch {
            print("ALBUM preview failed: \(error.localizedDescription)")
        }

        // The console, with the album card.
        controller.settingsService.settings.lastAdminTab = "Control"
        let admin = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 1200),
                             styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let adminHost = NSHostingView(rootView: AdminRootView(c: controller))
        adminHost.frame = NSRect(x: 0, y: 0, width: 1440, height: 1200)
        admin.contentView = adminHost
        admin.orderBack(nil)
        adminHost.layoutSubtreeIfNeeded()
        settle(1.2)
        if let rep = adminHost.bitmapImageRepForCachingDisplay(in: adminHost.bounds) {
            adminHost.cacheDisplay(in: adminHost.bounds, to: rep)
            if let d = rep.representation(using: .png, properties: [:]) {
                try? d.write(to: outDir.appendingPathComponent("album-admin.png"))
            }
        }
        admin.orderOut(nil)
        controller.deleteEvent(ev)
        exit(0)
    }

    // Cloudinary publishing, against the stand-in server in the scratchpad.
    if CommandLine.arguments.contains("--cloudinary") {
        controller.settingsService.settings.cameraBackend = .demo
        controller.settingsService.settings.countdownSeconds = 1
        controller.settingsService.settings.previewSeconds = 0.3
        controller.settingsService.settings.shotIntervalSeconds = 0.3
        controller.settingsService.settings.layout = .fourFullPage
        controller.settingsService.settings.autoPrint = false
        controller.settingsService.settings.holdFinishUntilPress = false
        controller.settingsService.settings.completeScreenSeconds = 1
        controller.settingsService.settings.eventTitle = "MIXEL PHOTOBOOTH"
        controller.settingsService.settings.galleryHost = .cloudinary
        controller.settingsService.settings.cloudinaryCloudName =
            ProcessInfo.processInfo.environment["PB_CLOUD"] ?? "mixeltest"
        controller.settingsService.settings.cloudinaryPreset =
            ProcessInfo.processInfo.environment["PB_PRESET"] ?? "photobooth"
        controller.settingsService.settings.uploadEnabled = true
        controller.settingsService.settings.pagesRepoPath = ""
        controller.settingsService.settings.pagesRemote = ""
        controller.settingsService.settings.uploadBaseURL = ""
        controller.settingsService.settings.customQRLink = "instagram.com/mixel_ph"
        controller.settingsService.settings.customQRCaption = "Follow us"
        controller.settingsService.settings.qrTarget = .both
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))

        @MainActor func settle(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

        print("CLOUD api base: \(CloudinaryService.apiBase)")
        print("CLOUD photo url: \(controller.cloudinary?.photoURL(token: "abcd123456", fileName: "photo-01.jpg")?.absoluteString ?? "none")")

        // A wrong preset must be refused, and say so in words the operator can use.
        controller.settingsService.settings.cloudinaryPreset = "wrong-preset"
        settle(0.3)
        if let bad = controller.cloudinary {
            do { _ = try await_check(bad); print("CLOUD wrong preset: accepted (WRONG)") }
            catch { print("CLOUD wrong preset rejected: \(error.localizedDescription)") }
        }
        controller.settingsService.settings.cloudinaryPreset = "photobooth"
        settle(0.3)

        guard let ev = controller.createEvent(name: "Cloudinary Rehearsal", client: "Bench",
                                              venue: "Studio", date: Date(), notes: "") else { exit(1) }
        for n in 1...1 {
            controller.startSession()
            for _ in 0..<60 {
                settle(0.5)
                if case .complete = controller.state { break }
                if case .idle = controller.state { break }
                if case .failed(let m) = controller.state { print("CLOUD session failed: \(m)"); exit(1) }
            }
            if let cur = controller.currentSession {
                print("CLOUD session \(n) token=\(cur.publicToken) host=\(controller.settings.galleryHost.rawValue) cloud=\(controller.cloudinary != nil)")
                print("CLOUD session \(n) QR: \(controller.galleryURL(for: cur)?.absoluteString ?? "none")")
            } else {
                print("CLOUD session \(n): no current session")
            }
            settle(2)
        }
        for _ in 0..<40 {
            settle(1)
            if controller.uploader.pendingCount == 0 { break }
        }
        print("CLOUD queue: \(controller.uploader.pendingCount) reach=\(controller.uploader.reachability.label)")
        for q in controller.uploader.queue {
            print("CLOUD stuck \(q.sessionID): \(q.lastError ?? "?")")
        }
        for s in controller.storage.sessions where s.eventID == ev.id {
            print("CLOUD \(s.id) state=\(s.uploadState.rawValue) token=\(s.publicToken)")
        }

        controller.settingsService.settings.lastAdminTab = "Control"
        let admin = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 980),
                             styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let adminHost = NSHostingView(rootView: AdminRootView(c: controller))
        adminHost.frame = NSRect(x: 0, y: 0, width: 1440, height: 980)
        admin.contentView = adminHost
        admin.orderBack(nil)
        adminHost.layoutSubtreeIfNeeded()
        settle(1.2)
        if let rep = adminHost.bitmapImageRepForCachingDisplay(in: adminHost.bounds) {
            adminHost.cacheDisplay(in: adminHost.bounds, to: rep)
            if let d = rep.representation(using: .png, properties: [:]) {
                try? d.write(to: outDir.appendingPathComponent("cloudinary-admin.png"))
            }
        }
        admin.orderOut(nil)
        controller.deleteEvent(ev)
        exit(0)
    }

    // Sets a real site folder up with the shipped templates:
    //   uishot <out> --pages-setup <folder> <remote> <title>
    if let i = CommandLine.arguments.firstIndex(of: "--pages-setup") {
        let folder = URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
        let remote = CommandLine.arguments[i + 2]
        let title = CommandLine.arguments.count > i + 3 ? CommandLine.arguments[i + 3] : "Photobooth"
        do {
            try PagesPublisher.setUp(at: folder, remote: remote, branch: "main",
                                     siteTitle: title,
                                     authorName: "Photobooth",
                                     authorEmail: "mixel.org@gmail.com")
            let pub = PagesPublisher(repo: folder, branch: "main", siteTitle: title)
            print("SETUP repo: \(PagesPublisher.isRepo(folder))")
            print("SETUP remote: \(pub.remoteURL() ?? "none")")
            let size = pub.siteSize()
            print("SETUP files: \(size.files), bytes: \(size.bytes)")
        } catch {
            print("SETUP failed: \(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    // GitHub Pages publishing, walked end to end against a bare repository on
    // this Mac standing in for GitHub: everything is exercised — resize, page
    // generation, commit, push — without touching anybody's account.
    if CommandLine.arguments.contains("--pages") {
        let scratch = outDir.appendingPathComponent("site")
        let bare = outDir.appendingPathComponent("origin.git")
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.removeItem(at: bare)
        _ = Shell.run("/usr/bin/git", ["init", "--bare", bare.path], timeout: 30)

        controller.settingsService.settings.cameraBackend = .demo
        controller.settingsService.settings.countdownSeconds = 1
        controller.settingsService.settings.previewSeconds = 0.3
        controller.settingsService.settings.shotIntervalSeconds = 0.3
        controller.settingsService.settings.layout = .fourFullPage
        controller.settingsService.settings.autoPrint = false
        controller.settingsService.settings.holdFinishUntilPress = false
        controller.settingsService.settings.completeScreenSeconds = 1
        controller.settingsService.settings.eventTitle = "MIXEL PHOTOBOOTH"
        controller.settingsService.settings.galleryHost = .githubPages
        controller.settingsService.settings.uploadEnabled = true
        controller.settingsService.settings.uploadBaseURL = "https://mixel.github.io/photos"
        controller.settingsService.settings.pagesRepoPath = scratch.path
        controller.settingsService.settings.pagesRemote = bare.path
        controller.settingsService.settings.customQRLink = "instagram.com/mixelbooth"
        controller.settingsService.settings.customQRCaption = "Follow us"
        controller.settingsService.settings.qrTarget = .sessionAlbum
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))

        @MainActor func settle(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

        controller.setUpPagesSite(remote: bare.path)
        settle(3)
        print("PAGES repo made: \(PagesPublisher.isRepo(scratch))")
        print("PAGES remote: \(controller.pagesPublisher()?.remoteURL() ?? "none")")

        guard let ev = controller.createEvent(name: "Pages Rehearsal", client: "Bench",
                                              venue: "Studio", date: Date(), notes: "") else { exit(1) }

        for n in 1...2 {
            controller.startSession()
            for _ in 0..<60 {
                settle(0.5)
                if case .complete = controller.state { break }
                if case .idle = controller.state { break }
                if case .failed(let m) = controller.state { print("PAGES session failed: \(m)"); exit(1) }
            }
            print("PAGES session \(n): \(controller.currentSession?.id ?? "?") token=\(controller.currentSession?.publicToken ?? "?")")
            print("PAGES QR url: \(controller.currentSession.flatMap { controller.galleryURL(for: $0) }?.absoluteString ?? "none")")
            settle(2)
        }

        // Let the queue drain to the bare "GitHub".
        for _ in 0..<40 {
            settle(1)
            if controller.uploader.pendingCount == 0 { break }
        }
        print("PAGES queue: \(controller.uploader.pendingCount) reach=\(controller.uploader.reachability.label)")
        for q in controller.uploader.queue {
            print("PAGES queued \(q.sessionID) attempts=\(q.attempts) err=\(q.lastError ?? "none")")
        }
        for s in controller.storage.sessions where s.eventID == ev.id {
            print("PAGES session \(s.id) state=\(s.uploadState.rawValue)")
        }

        // The console, with the site connected and the queue drained.
        controller.settingsService.settings.lastAdminTab = "Control"
        let admin = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 980),
                             styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let adminHost = NSHostingView(rootView: AdminRootView(c: controller))
        adminHost.frame = NSRect(x: 0, y: 0, width: 1440, height: 980)
        admin.contentView = adminHost
        admin.orderBack(nil)
        adminHost.layoutSubtreeIfNeeded()
        settle(1.2)
        if let rep = adminHost.bitmapImageRepForCachingDisplay(in: adminHost.bounds) {
            adminHost.cacheDisplay(in: adminHost.bounds, to: rep)
            if let d = rep.representation(using: .png, properties: [:]) {
                try? d.write(to: outDir.appendingPathComponent("pages-admin.png"))
            }
        }
        admin.orderOut(nil)

        let log = Shell.run("/usr/bin/git", ["-C", bare.path, "log", "--oneline", "main"], timeout: 30)
        print("PAGES commits on the remote:\n\(log.out.trimmingCharacters(in: .whitespacesAndNewlines))")
        let tree = Shell.run("/usr/bin/git", ["-C", bare.path, "ls-tree", "-r", "--name-only", "main"], timeout: 30)
        print("PAGES files on the remote:\n\(tree.out.trimmingCharacters(in: .whitespacesAndNewlines))")

        controller.deleteEvent(ev)
        exit(0)
    }

    // The guest QR cards: their photos, the operator's own link, or both —
    // walked end to end so the codes on screen and on the sheet can be decoded.
    if CommandLine.arguments.contains("--brandqr") {
        controller.settingsService.settings.cameraBackend = .demo
        controller.settingsService.settings.countdownSeconds = 1
        controller.settingsService.settings.previewSeconds = 0.3
        controller.settingsService.settings.shotIntervalSeconds = 0.3
        controller.settingsService.settings.layout = .fourFullPage
        controller.settingsService.settings.autoPrint = false
        controller.settingsService.settings.holdFinishUntilPress = true
        controller.settingsService.settings.finishHoldTimeoutSeconds = 0
        controller.settingsService.settings.showQRCode = true
        controller.settingsService.settings.printQRCode = true
        controller.settingsService.settings.uploadEnabled = false
        controller.settingsService.settings.uploadBaseURL = "http://localhost:4321"
        controller.settingsService.settings.customQRLink = "instagram.com/mixelbooth"
        controller.settingsService.settings.customQRCaption = "FOLLOW US FOR YOUR PHOTOS"
        controller.settingsService.settings.qrTarget = .both
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: BoothRootView(c: controller))
        host.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        window.contentView = host
        window.orderBack(nil)

        @MainActor func grab(_ name: String) {
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let d = rep.representation(using: .png, properties: [:]) {
                try? d.write(to: outDir.appendingPathComponent("\(name).png"))
            }
            print("grab \(name) — state \(controller.state.name)")
        }
        @MainActor func settle(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        @MainActor func run(_ label: String) -> Bool {
            controller.triggerPressed()
            for _ in 0..<60 {
                settle(0.5)
                if case .complete = controller.state { return true }
                if case .failed(let m) = controller.state { print("QR \(label) failed: \(m)"); return false }
            }
            print("QR \(label) stuck in \(controller.state.name)"); return false
        }

        print("QR link parsed: \(controller.customQRURL?.absoluteString ?? "INVALID")")
        for bad in ["", "not a url", "instagram .com/x"] {
            controller.settingsService.settings.customQRLink = bad
            print("QR rejects \(bad.isEmpty ? "<empty>" : bad): \(controller.customQRURL == nil)")
        }
        controller.settingsService.settings.customQRLink = "instagram.com/mixelbooth"

        guard let ev = controller.createEvent(name: "QR Rehearsal", client: "Bench",
                                              venue: "Studio", date: Date(), notes: "") else { exit(1) }

        // Both: two cards on screen, the photo link on the sheet.
        guard run("both") else { exit(1) }
        settle(1.5)
        guard let rec = controller.currentSession else { exit(1) }
        print("QR both — screen album=\(controller.sessionQRImage != nil) brand=\(controller.brandQRImage != nil)")
        print("QR both — print payload: \(controller.printQRPayload(for: rec) ?? "none")")
        grab("qr-01-both")
        let dir = controller.storage.directory(for: rec)
        if let n = rec.printFileName {
            try? FileManager.default.copyItem(at: dir.appendingPathComponent(n),
                                              to: outDir.appendingPathComponent("qr-both-print.jpg"))
        }
        controller.returnToIdle()
        settle(0.5)

        // My link only: one card, and the sheet carries the operator's address.
        controller.settingsService.settings.qrTarget = .customLink
        settle(0.3)
        guard run("custom") else { exit(1) }
        settle(1.5)
        guard let rec2 = controller.currentSession else { exit(1) }
        print("QR custom — screen album=\(controller.sessionQRImage != nil) brand=\(controller.brandQRImage != nil)")
        print("QR custom — print payload: \(controller.printQRPayload(for: rec2) ?? "none")")
        grab("qr-02-custom")
        let dir2 = controller.storage.directory(for: rec2)
        if let n = rec2.printFileName {
            try? FileManager.default.copyItem(at: dir2.appendingPathComponent(n),
                                              to: outDir.appendingPathComponent("qr-custom-print.jpg"))
        }

        // The settings card, with the live preview of the code.
        controller.settingsService.settings.lastAdminTab = "Settings"
        let admin = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                             styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let adminHost = NSHostingView(rootView: AdminRootView(c: controller))
        adminHost.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        admin.contentView = adminHost
        admin.orderBack(nil)
        adminHost.layoutSubtreeIfNeeded()
        settle(0.6)
        if let rep = adminHost.bitmapImageRepForCachingDisplay(in: adminHost.bounds) {
            adminHost.cacheDisplay(in: adminHost.bounds, to: rep)
            if let d = rep.representation(using: .png, properties: [:]) {
                try? d.write(to: outDir.appendingPathComponent("qr-03-settings.png"))
            }
        }
        admin.orderOut(nil)

        controller.storage.delete(rec)
        controller.storage.delete(rec2)
        controller.deleteEvent(ev)
        window.orderOut(nil)
        exit(0)
    }

    // One press = print + reset. Walked against the demo camera with a printer
    // name that does not exist, so the whole submit path runs but nothing can
    // reach CUPS and no dye-sub sheet is burned.
    if CommandLine.arguments.contains("--printhold") {
        controller.settingsService.settings.cameraBackend = .demo
        controller.settingsService.settings.countdownSeconds = 1
        controller.settingsService.settings.previewSeconds = 0.3
        controller.settingsService.settings.shotIntervalSeconds = 0.3
        controller.settingsService.settings.layout = .fourFullPage
        controller.settingsService.settings.autoPrint = true
        controller.settingsService.settings.printerName = "PHOTOBOOTH_TEST_NO_SUCH_PRINTER"
        controller.settingsService.settings.holdFinishUntilPress = true
        controller.settingsService.settings.finishHoldTimeoutSeconds = 0     // wait forever
        controller.settingsService.settings.showQRCode = true
        controller.settingsService.settings.printQRCode = true
        controller.settingsService.settings.uploadEnabled = false
        controller.settingsService.settings.uploadBaseURL = "http://localhost:4321"
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: BoothRootView(c: controller))
        host.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        window.contentView = host
        window.orderBack(nil)

        @MainActor func grab(_ name: String) {
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let d = rep.representation(using: .png, properties: [:]) {
                try? d.write(to: outDir.appendingPathComponent("\(name).png"))
            }
            print("grab \(name) — state \(controller.state.name)")
        }
        @MainActor func settle(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        @MainActor func runToComplete(_ label: String) -> Bool {
            for _ in 0..<60 {
                settle(0.5)
                if case .complete = controller.state { return true }
                if case .failed(let m) = controller.state { print("HOLD \(label) failed: \(m)"); return false }
            }
            print("HOLD \(label) stuck in \(controller.state.name)"); return false
        }

        guard let ev = controller.createEvent(name: "Print Hold Rehearsal", client: "Bench",
                                              venue: "Studio", date: Date(), notes: "") else { exit(1) }
        print("HOLD event: \(ev.id)")

        // 1. Button starts the session; the print must NOT go out at the end.
        controller.triggerPressed()
        settle(0.6)
        guard controller.state.isSessionActive else { print("HOLD button did not start"); exit(1) }
        guard runToComplete("first run") else { exit(1) }
        guard let done = controller.currentSession else { exit(1) }
        print("HOLD state: \(controller.state.name) pendingPrint=\(controller.pendingPrint) awaiting=\(controller.awaitingContinue)")
        print("HOLD print built: \(done.printFileName ?? "none") status=\(done.printStatus.rawValue) (expect notPrinted)")
        settle(1.5)          // let the finish screen finish fading in
        grab("hold-01-finish")

        // The console must warn the operator that the sheet has not gone yet.
        let admin = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                             styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        controller.settingsService.settings.lastAdminTab = "Control"
        let adminHost = NSHostingView(rootView: AdminRootView(c: controller))
        adminHost.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        admin.contentView = adminHost
        admin.orderBack(nil)
        adminHost.layoutSubtreeIfNeeded()
        settle(0.5)
        if let rep = adminHost.bitmapImageRepForCachingDisplay(in: adminHost.bounds) {
            adminHost.cacheDisplay(in: adminHost.bounds, to: rep)
            if let d = rep.representation(using: .png, properties: [:]) {
                try? d.write(to: outDir.appendingPathComponent("hold-02-admin.png"))
            }
        }
        admin.orderOut(nil)

        // 2. One press: the print goes, and the booth resets itself.
        controller.triggerPressed()
        settle(1.0)
        let after = controller.currentSession
        print("HOLD after press: state=\(controller.state.name) pendingPrint=\(controller.pendingPrint)")
        print("HOLD print submitted: status=\(after?.printStatus.rawValue ?? "?") err=\(after?.lastError ?? "none")")
        grab("hold-03-idle")

        // 3. Nobody presses: the jam-guard resets the booth and holds the print back.
        controller.settingsService.settings.finishHoldTimeoutSeconds = 4
        settle(0.4)
        controller.triggerPressed()
        settle(0.6)
        guard runToComplete("second run") else { exit(1) }
        let unattended = controller.currentSession
        print("HOLD second run pendingPrint=\(controller.pendingPrint)")
        settle(7)
        print("HOLD timed out to: \(controller.state.name) pendingPrint=\(controller.pendingPrint)")
        if let u = unattended {
            let fresh = controller.storage.sessions.first { $0.id == u.id } ?? u
            print("HOLD unattended print status: \(fresh.printStatus.rawValue) (expect notPrinted — nothing sent)")
            controller.storage.delete(fresh)
        }
        controller.storage.delete(done)
        controller.deleteEvent(ev)
        window.orderOut(nil)
        exit(0)
    }

    // Booth button, hold-to-continue, QR and numbered retakes, walked end to end
    // against the demo camera.
    if CommandLine.arguments.contains("--retake") {
        controller.settingsService.settings.cameraBackend = .demo
        controller.settingsService.settings.countdownSeconds = 1
        controller.settingsService.settings.previewSeconds = 0.3
        controller.settingsService.settings.shotIntervalSeconds = 0.3
        controller.settingsService.settings.layout = .fourFullPage
        controller.settingsService.settings.autoPrint = false
        controller.settingsService.settings.holdFinishUntilPress = true
        controller.settingsService.settings.finishHoldTimeoutSeconds = 0     // wait forever
        controller.settingsService.settings.showQRCode = true
        controller.settingsService.settings.printQRCode = true
        controller.settingsService.settings.uploadEnabled = false
        controller.settingsService.settings.uploadBaseURL = "http://localhost:4321"
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: BoothRootView(c: controller))
        host.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        window.contentView = host
        window.orderBack(nil)

        @MainActor func grab(_ name: String) {
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let d = rep.representation(using: .png, properties: [:]) {
                try? d.write(to: outDir.appendingPathComponent("\(name).png"))
            }
            print("grab \(name) — state \(controller.state.name)")
        }

        @MainActor func settle(_ seconds: Double) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }

        @MainActor func waitForComplete(_ label: String) -> Bool {
            for _ in 0..<60 {
                settle(0.5)
                if case .complete = controller.state { return true }
                if case .failed(let m) = controller.state { print("RETAKE \(label) failed: \(m)"); return false }
            }
            print("RETAKE \(label) never completed — stuck in \(controller.state.name)")
            return false
        }

        guard let ev = controller.createEvent(name: "Retake Rehearsal", client: "Bench",
                                              venue: "Studio", date: Date(), notes: "") else { exit(1) }
        print("RETAKE event: \(ev.id)")

        // 1. The button starts the session from idle.
        controller.triggerPressed()
        settle(0.6)
        print("RETAKE after press: \(controller.state.name)")
        guard controller.state.isSessionActive else { print("RETAKE button did not start a session"); exit(1) }

        // Mid-run: mark photo 1 from the console so the numbered strip is
        // captured with a live queue, and the retake pass has work to do.
        settle(3.5)
        controller.toggleRetake(shot: 1)
        controller.settingsService.settings.lastAdminTab = "Control"
        settle(0.3)
        print("RETAKE mid-run queue: \(controller.retakeQueue.sorted()) state=\(controller.state.name)")
        let admin = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                             styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let adminHost = NSHostingView(rootView: AdminRootView(c: controller))
        adminHost.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        admin.contentView = adminHost
        admin.orderBack(nil)
        adminHost.layoutSubtreeIfNeeded()
        settle(0.4)
        if let rep = adminHost.bitmapImageRepForCachingDisplay(in: adminHost.bounds) {
            adminHost.cacheDisplay(in: adminHost.bounds, to: rep)
            if let d = rep.representation(using: .png, properties: [:]) {
                try? d.write(to: outDir.appendingPathComponent("retake-admin-queued.png"))
            }
        }
        admin.orderOut(nil)

        guard waitForComplete("first run") else { exit(1) }
        guard let first = controller.currentSession else { exit(1) }
        let dir = controller.storage.directory(for: first)
        let before = try? Data(contentsOf: dir.appendingPathComponent("photo-02.jpg"))
        print("RETAKE after first run, retakenShots: \(first.retakenShots) (expect [1])")
        print("RETAKE photos: \(first.photos.count), print: \(first.printFileName ?? "none")")
        print("RETAKE holding: awaitingContinue=\(controller.awaitingContinue) qr=\(controller.sessionQRImage != nil)")
        grab("retake-01-finish-with-qr")

        // 2. The finish screen must still be there after the old auto-return delay.
        settle(8)
        guard case .complete = controller.state else {
            print("RETAKE finish screen did not hold — now \(controller.state.name)"); exit(1)
        }
        print("RETAKE still holding after 8s: \(controller.state.name)")

        // 3. Retake photo 2 by number, from the finished session.
        controller.requestRetake(shot: 2)
        settle(0.8)
        print("RETAKE reopened: \(controller.state.name)")
        settle(0.9)
        grab("retake-02-card")
        settle(1.4)
        grab("retake-03-countdown")

        guard waitForComplete("retake pass") else { exit(1) }
        guard let after = controller.currentSession else { exit(1) }
        let now = try? Data(contentsOf: dir.appendingPathComponent("photo-02.jpg"))
        let archived = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { $0.contains(".retake-") } ?? []
        print("RETAKE retakenShots: \(after.retakenShots)")
        print("RETAKE photo count unchanged: \(after.photos.count)")
        print("RETAKE photo-02 replaced: \(before != nil && now != nil && before != now)")
        print("RETAKE archived originals: \(archived)")
        grab("retake-04-finish-again")

        // 4. The button clears the finish screen.
        controller.triggerPressed()
        settle(0.6)
        print("RETAKE after second press: \(controller.state.name)")
        grab("retake-05-idle")

        // Keep the real 300-DPI sheet so the printed QR can be checked at size.
        if let name = after.printFileName {
            try? FileManager.default.copyItem(at: dir.appendingPathComponent(name),
                                              to: outDir.appendingPathComponent("retake-print-300dpi.jpg"))
        }
        controller.storage.delete(after)
        controller.deleteEvent(ev)
        window.orderOut(nil)
        exit(0)
    }

    if CommandLine.arguments.contains("--offline") {
        let key = CommandLine.arguments.last ?? ""
        let live = "http://localhost:4321"
        let dead = "http://localhost:4399"        // nothing listening: a venue with no wifi
        controller.settingsService.settings.cameraBackend = .demo
        controller.settingsService.settings.countdownSeconds = 1
        controller.settingsService.settings.previewSeconds = 0.2
        controller.settingsService.settings.shotIntervalSeconds = 0.2
        controller.settingsService.settings.completeScreenSeconds = 1
        controller.settingsService.settings.layout = .fourFullPage
        controller.settingsService.settings.autoPrint = false
        controller.settingsService.settings.uploadEnabled = true
        controller.settingsService.settings.uploadAPIKey = key

        let phase = CommandLine.arguments.contains("--phase2") ? 2 : 1
        controller.settingsService.settings.uploadBaseURL = phase == 1 ? dead : live
        RunLoop.main.run(until: Date().addingTimeInterval(2))

        if phase == 1 {
            guard let ev = controller.createEvent(name: "Offline Barn Party", client: "Dela Cruz",
                                                  venue: "Tagaytay", date: Date(), notes: "") else { exit(1) }
            print("OFFLINE event: \(ev.id)")
            controller.startSession()
            for _ in 0..<40 {
                RunLoop.main.run(until: Date().addingTimeInterval(1))
                if case .complete = controller.state { break }
                if case .failed(let m) = controller.state { print("OFFLINE session failed: \(m)"); exit(1) }
            }
            print("OFFLINE session: \(controller.currentSession?.id ?? "?") state=\(controller.state.name)")
            print("OFFLINE photos on disk: \(controller.currentSession?.photos.count ?? 0)")
            // Give the uploader a couple of failed attempts against the dead host.
            for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(1)) }
            print("OFFLINE reach: \(controller.uploader.reachability.label)")
            print("OFFLINE queued: \(controller.uploader.pendingCount)")
            print("OFFLINE upload state: \(controller.currentSession?.uploadState.rawValue ?? "?")")
            controller.settingsService.saveNow()
            exit(0)
        } else {
            print("RESUME queued at launch: \(controller.uploader.pendingCount)")
            controller.retryUploads()
            for _ in 0..<25 {
                RunLoop.main.run(until: Date().addingTimeInterval(1))
                if controller.uploader.pendingCount == 0 { break }
            }
            print("RESUME reach: \(controller.uploader.reachability.label)")
            print("RESUME remaining: \(controller.uploader.pendingCount)")
            exit(0)
        }
    }

    if CommandLine.arguments.contains("--e2e") {
        let key = CommandLine.arguments.last ?? ""
        controller.settingsService.settings.cameraBackend = .demo
        controller.settingsService.settings.countdownSeconds = 1
        controller.settingsService.settings.previewSeconds = 0.2
        controller.settingsService.settings.shotIntervalSeconds = 0.2
        controller.settingsService.settings.completeScreenSeconds = 1
        controller.settingsService.settings.layout = .fourFullPage
        controller.settingsService.settings.autoPrint = false
        controller.settingsService.settings.uploadEnabled = true
        controller.settingsService.settings.uploadBaseURL = "http://localhost:4321"
        controller.settingsService.settings.uploadAPIKey = key
        RunLoop.main.run(until: Date().addingTimeInterval(2))

        guard let ev = controller.createEvent(name: "Reyes Debut",
                                              client: "Ana Reyes",
                                              venue: "Manila Hotel",
                                              date: Date(),
                                              notes: "End-to-end check") else {
            print("E2E: could not create event"); exit(1)
        }
        print("E2E event: \(ev.id)")
        print("E2E camera: \(controller.cameraState.label)")

        controller.startSession()
        for _ in 0..<40 {
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            if case .complete = controller.state { break }
            if case .failed(let m) = controller.state { print("E2E failed: \(m)"); exit(1) }
        }
        print("E2E session: \(controller.currentSession?.id ?? "none") state=\(controller.state.name)")
        print("E2E queue: \(controller.uploader.pendingCount) reach=\(controller.uploader.reachability.label)")

        for _ in 0..<20 {
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            if controller.uploader.pendingCount == 0 { break }
        }
        let s = controller.currentSession
        print("E2E upload: pending=\(controller.uploader.pendingCount) state=\(s?.uploadState.rawValue ?? "?")")
        exit(0)
    }

    for shot in shots {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: shot.size),
                              styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        let host = NSHostingView(rootView: shot.make(controller))
        host.frame = NSRect(origin: .zero, size: shot.size)
        window.contentView = host
        window.orderBack(nil)

        // Let SwiftUI settle (async image loads, printer poll, layout passes).
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            let url = outDir.appendingPathComponent("\(shot.name).png")
            try? data.write(to: url)
            print("wrote \(url.lastPathComponent) \(rep.pixelsWide)x\(rep.pixelsHigh)")
        }
        window.orderOut(nil)
    }
    exit(0)
}
