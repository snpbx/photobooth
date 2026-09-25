import Foundation
import AppKit
import AVFoundation
import Combine

enum CameraError: LocalizedError {
    case notConnected
    case captureFailed(String)
    case downloadFailed(String)
    case busy

    var errorDescription: String? {
        switch self {
        case .notConnected:        return "The camera is not connected."
        case .captureFailed(let m): return "Capture failed: \(m)"
        case .downloadFailed(let m): return "Could not download the photograph: \(m)"
        case .busy:                return "The camera is busy."
        }
    }
}

/// One setting on the camera body, as libgphoto2 sees it.
///
/// `name` is gphoto2's own name (`iso`, `shutterspeed`) rather than anything of
/// ours: it is what a setting is written back under, it is stable across
/// firmware, and it is what a search for a stuck setting will turn up.
struct CameraSetting: Identifiable, Hashable {
    let name: String
    /// The camera's own label — "ISO Speed", not our translation of it.
    let label: String
    let value: String
    /// Empty when the camera offers free text or a number rather than a list.
    let choices: [String]
    /// True for settings the body decides itself — with the mode dial on Av the
    /// 6D reports shutter speed this way, and refuses to be told otherwise.
    let readOnly: Bool

    var id: String { name }
}

/// Everything the rest of the app is allowed to know about a camera.
/// Both the Canon USB backend and the webcam backend implement this, so the
/// hardware layer can be swapped without touching the workflow or the UI.
protocol CameraBackendService: AnyObject {
    var onState: ((CameraState) -> Void)? { get set }
    var onFrame: ((NSImage) -> Void)? { get set }

    func connect()
    func disconnect()
    func startLiveView()
    func stopLiveView()
    /// Returns full-resolution JPEG data. Never returns partial data.
    func capturePhoto() async throws -> Data
    /// Called once the JPEG is safely on disk, so the backend can clean up the card.
    func didPersistLastCapture()

    /// The settings the body will talk about, in the order they should be shown.
    func readSettings(completion: @escaping ([CameraSetting]) -> Void)
    /// Changes one setting. The completion carries nil on success, or the reason.
    func writeSetting(_ name: String, to value: String, completion: @escaping (String?) -> Void)
}

/// Only the DSLR has settings worth editing: a webcam's exposure belongs to
/// macOS, and the demo backend has no hardware at all. They inherit these.
extension CameraBackendService {
    func readSettings(completion: @escaping ([CameraSetting]) -> Void) {
        DispatchQueue.main.async { completion([]) }
    }
    func writeSetting(_ name: String, to value: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.main.async { completion("This camera's settings cannot be changed from here.") }
    }
}

// MARK: - Canon DSLR over USB (libgphoto2)

final class DSLRCameraService: CameraBackendService, @unchecked Sendable {
    var onState: ((CameraState) -> Void)?
    var onFrame: ((NSImage) -> Void)?

    private let queue = DispatchQueue(label: "photobooth.camera.dslr")
    private var liveViewRunning = false
    private var wantsLiveView = false
    private var connected = false
    private var capturing = false
    private var fps: Int = 15
    private var watchdog: DispatchSourceTimer?

    init(fps: Int) { self.fps = fps }

    func setFPS(_ v: Int) { fps = max(1, min(30, v)) }

    /// macOS grabs PTP cameras with its own daemon; libgphoto2 cannot claim the
    /// interface until it lets go. Harmless when the daemon is not running.
    private func releaseSystemPTPDaemon() {
        for name in ["PTPCamera", "ptpcamerad"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            p.arguments = ["-9", name]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }

    /// libgphoto2's raw strings are useless to an operator mid-event.
    static func friendlyError(_ raw: String) -> String {
        if raw.isEmpty { return "No camera found on USB." }
        if raw.contains("Unknown model") || raw.contains("Could not find") {
            return "No camera found on USB."
        }
        if raw.contains("Could not claim") || raw.localizedCaseInsensitiveContains("busy") {
            return "Camera is in use — quit Image Capture and Photos, then retry."
        }
        if raw.contains("Could not lock") || raw.contains("PTP") {
            return "Camera did not respond. Switch it off and on, then reconnect."
        }
        return raw
    }

    /// Enumerates the USB bus on the camera's own serial queue — never on the main
    /// thread, and never concurrently with live view or a capture.
    func detectedCameras(completion: @escaping ([String]) -> Void) {
        queue.async {
            var buf = [CChar](repeating: 0, count: 4096)
            let n = gpshim_detect_summary(&buf, Int32(buf.count))
            let list = n > 0
                ? String(cString: buf).split(separator: "\n")
                    .map { $0.replacingOccurrences(of: "\t", with: "  ·  ") }
                : []
            DispatchQueue.main.async { completion(list) }
        }
    }

    func connect() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.connected else { return }
            self.emit(.connecting)
            self.releaseSystemPTPDaemon()
            Thread.sleep(forTimeInterval: 0.35)

            let r = gpshim_connect()
            if r < 0 {
                let msg = String(cString: gpshim_last_error())
                self.emit(.error(Self.friendlyError(msg)))
                Log.shared.error("Camera connect failed: \(msg)")
                return
            }
            self.connected = true
            let raw = String(cString: gpshim_camera_name())
            let name = raw.isEmpty ? "DSLR" : raw
            self.emit(.connected(name))
            Log.shared.info("Camera connected: \(name)")
            self.startWatchdog()
            if self.wantsLiveView { self.beginLiveViewLoop() }
        }
    }

    func disconnect() {
        wantsLiveView = false
        stopWatchdog()
        queue.async { [weak self] in
            guard let self else { return }
            guard self.connected else { return }
            gpshim_disconnect()
            self.connected = false
            self.liveViewRunning = false
            self.emit(.disconnected)
            Log.shared.info("Camera disconnected")
        }
    }

    func startLiveView() {
        wantsLiveView = true
        queue.async { [weak self] in
            guard let self, self.connected, !self.liveViewRunning else { return }
            self.beginLiveViewLoop()
        }
    }

    func stopLiveView() { wantsLiveView = false }

    private func beginLiveViewLoop() {
        liveViewRunning = true
        queue.async { [weak self] in self?.liveViewTick() }
    }

    private func liveViewTick() {
        guard liveViewRunning, wantsLiveView, connected else {
            liveViewRunning = false
            return
        }
        if capturing {
            queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.liveViewTick() }
            return
        }

        var ptr: UnsafeMutablePointer<UInt8>?
        var len: UInt = 0
        let r = gpshim_liveview_frame(&ptr, &len)

        if r == 0, let p = ptr, len > 0 {
            let data = Data(bytes: p, count: Int(len))
            gpshim_free(p)
            if let img = NSImage(data: data) {
                DispatchQueue.main.async { [weak self] in self?.onFrame?(img) }
            }
            let delay = 1.0 / Double(max(1, fps))
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.liveViewTick() }
        } else {
            if let p = ptr { gpshim_free(p) }
            let msg = String(cString: gpshim_last_error())
            Log.shared.warn("Live view frame failed: \(msg)")
            // A failed preview usually means the cable was pulled; let the watchdog confirm.
            queue.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.liveViewTick() }
        }
    }

    func capturePhoto() async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [weak self] in
                guard let self else { return cont.resume(throwing: CameraError.notConnected) }
                guard self.connected else { return cont.resume(throwing: CameraError.notConnected) }
                guard !self.capturing else { return cont.resume(throwing: CameraError.busy) }

                self.capturing = true
                defer { self.capturing = false }
                self.emit(.busy("Capturing…"))

                var ptr: UnsafeMutablePointer<UInt8>?
                var len: UInt = 0
                let r = gpshim_capture(&ptr, &len)

                if r < 0 || ptr == nil || len == 0 {
                    if let p = ptr { gpshim_free(p) }
                    let msg = String(cString: gpshim_last_error())
                    let name = String(cString: gpshim_camera_name())
                    self.emit(name.isEmpty ? .error(msg) : .connected(name))
                    Log.shared.error("Capture failed: \(msg)")
                    return cont.resume(throwing: CameraError.captureFailed(msg))
                }

                let data = Data(bytes: ptr!, count: Int(len))
                gpshim_free(ptr!)
                let name = String(cString: gpshim_camera_name())
                self.emit(.connected(name.isEmpty ? "DSLR" : name))
                cont.resume(returning: data)
            }
        }
    }

    private var deleteAfterPersist = true
    func setKeepOnCard(_ keep: Bool) { deleteAfterPersist = !keep }

    func didPersistLastCapture() {
        guard deleteAfterPersist else { return }
        queue.async { _ = gpshim_delete_last() }
    }

    // MARK: Settings on the body

    /// What the card offers, in the order an operator reaches for them: the
    /// exposure triangle first, then the things set once at the start of a
    /// night. Anything the body does not have is skipped, so this same list
    /// works on a 6D, a 5D or a Rebel.
    static let settingNames = [
        "iso", "aperture", "shutterspeed", "exposurecompensation",
        "whitebalance", "colortemperature", "imageformat", "picturestyle",
        "autoexposuremode", "focusmode", "drivemode", "colorspace",
        "meteringmode", "capturetarget"
    ]

    func readSettings(completion: @escaping ([CameraSetting]) -> Void) {
        queue.async { [weak self] in
            guard let self, self.connected else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            // Room for every choice the longest list can hold — a Canon's
            // shutter speeds alone run to sixty-odd entries.
            var buf = [CChar](repeating: 0, count: 65536)
            let rows = gpshim_config_read(Self.settingNames.joined(separator: "\n"),
                                          &buf, Int32(buf.count))
            guard rows > 0 else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let found = String(cString: buf).split(separator: "\n").compactMap { line -> CameraSetting? in
                let f = line.components(separatedBy: "\t")
                guard f.count >= 5 else { return nil }
                let choices = f[4].isEmpty ? [] : f[4].components(separatedBy: "|")
                return CameraSetting(name: f[0], label: f[1], value: f[2],
                                     choices: choices, readOnly: f[3] == "1")
            }
            // Back into our own order: the camera answers in whatever order it
            // was asked, but a body that lacks one leaves a gap.
            let order = Dictionary(uniqueKeysWithValues: Self.settingNames.enumerated().map { ($1, $0) })
            let sorted = found.sorted { (order[$0.name] ?? 99) < (order[$1.name] ?? 99) }
            DispatchQueue.main.async { completion(sorted) }
        }
    }

    func writeSetting(_ name: String, to value: String, completion: @escaping (String?) -> Void) {
        queue.async { [weak self] in
            guard let self, self.connected else {
                DispatchQueue.main.async { completion("The camera is not connected.") }
                return
            }
            guard !self.capturing else {
                DispatchQueue.main.async { completion("The camera is taking a photograph.") }
                return
            }
            let r = gpshim_config_write(name, value)
            if r < 0 {
                let msg = String(cString: gpshim_last_error())
                Log.shared.warn("Could not set \(name) to \(value): \(msg)")
                DispatchQueue.main.async { completion(Self.friendlyError(msg)) }
            } else {
                Log.shared.info("Camera \(name) set to \(value)")
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    // MARK: Watchdog — notices an unplugged cable within a couple of seconds

    private func startWatchdog() {
        stopWatchdog()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3, repeating: 3)
        t.setEventHandler { [weak self] in
            guard let self, self.connected, !self.capturing else { return }
            // Skip the USB probe while live view is feeding us frames — that is proof enough.
            if self.liveViewRunning && self.wantsLiveView { return }
            var buf = [CChar](repeating: 0, count: 2048)
            let n = gpshim_detect_summary(&buf, Int32(buf.count))
            if n <= 0 {
                gpshim_disconnect()
                self.connected = false
                self.liveViewRunning = false
                self.emit(.disconnected)
                Log.shared.warn("Camera disappeared from USB")
            }
        }
        t.resume()
        watchdog = t
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func emit(_ s: CameraState) {
        DispatchQueue.main.async { [weak self] in self?.onState?(s) }
    }
}

// MARK: - Webcam / UVC (AVFoundation) — rehearsal backend

final class WebcamCameraService: NSObject, CameraBackendService, @unchecked Sendable {
    var onState: ((CameraState) -> Void)?
    var onFrame: ((NSImage) -> Void)?

    private let session = AVCaptureSession()
    private let videoOut = AVCaptureVideoDataOutput()
    private let photoOut = AVCapturePhotoOutput()
    private let sampleQueue = DispatchQueue(label: "photobooth.camera.webcam")
    private var device: AVCaptureDevice?
    private var preferredUniqueID: String
    private var emittingFrames = false
    private var previewFPS: Int = 15
    private var lastFrameAt: CFTimeInterval = 0
    private var captureCont: CheckedContinuation<Data, Error>?
    private var lastFrame: CIImage?
    private let ciContext = CIContext()

    init(uniqueID: String) {
        preferredUniqueID = uniqueID
        super.init()
    }

    func setPreferredDevice(_ id: String) { preferredUniqueID = id }
    func setFPS(_ v: Int) { previewFPS = max(1, min(30, v)) }

    /// Device discovery pulls in AVFoundation's analysis stack, which is far too
    /// costly to run on a repeating poll. Cached for a few seconds; the picker and
    /// the status list do not need to be more current than that.
    private static var deviceCache: (at: CFTimeInterval, devices: [AVCaptureDevice]) = (0, [])
    private static let deviceCacheTTL: CFTimeInterval = 8

    static func availableDevices() -> [AVCaptureDevice] {
        let now = CACurrentMediaTime()
        if now - deviceCache.at < deviceCacheTTL, !deviceCache.devices.isEmpty {
            return deviceCache.devices
        }
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) { types.append(.external) }
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                     mediaType: .video,
                                                     position: .unspecified).devices
        deviceCache = (now, found)
        return found
    }

    func connect() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.emit(.error("Camera permission denied — enable it in System Settings › Privacy."))
                Log.shared.error("Webcam permission denied")
                return
            }
            self.sampleQueue.async { self.buildSession() }
        }
    }

    private func buildSession() {
        emit(.connecting)
        let devices = Self.availableDevices()
        let chosen = devices.first { $0.uniqueID == preferredUniqueID } ?? devices.first
        guard let dev = chosen, let input = try? AVCaptureDeviceInput(device: dev) else {
            emit(.error("No webcam found."))
            return
        }
        device = dev

        // macOS bolts Center Stage, Reactions and face/hand detection onto any
        // capture session on a built-in camera — ten Neural Engine threads for a
        // booth preview. Opt out of what is opt-out-able and ask for a modest
        // format; this backend is the rehearsal path, the 6D is the event path.
        if AVCaptureDevice.isCenterStageEnabled {
            AVCaptureDevice.centerStageControlMode = .app
            AVCaptureDevice.isCenterStageEnabled = false
        }

        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        for i in session.inputs { session.removeInput(i) }
        for o in session.outputs { session.removeOutput(o) }
        if session.canAddInput(input) { session.addInput(input) }

        videoOut.alwaysDiscardsLateVideoFrames = true
        videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOut.setSampleBufferDelegate(self, queue: sampleQueue)
        if session.canAddOutput(videoOut) { session.addOutput(videoOut) }
        if session.canAddOutput(photoOut) { session.addOutput(photoOut) }
        session.commitConfiguration()

        session.startRunning()
        emit(.connected(dev.localizedName))
        Log.shared.info("Webcam connected: \(dev.localizedName)")
    }

    func disconnect() {
        sampleQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            self.emit(.disconnected)
        }
    }

    func startLiveView() { emittingFrames = true }
    func stopLiveView()  { emittingFrames = false }

    func capturePhoto() async throws -> Data {
        guard session.isRunning else { throw CameraError.notConnected }
        // AVCapturePhotoOutput is preferred, but some UVC cameras refuse it; fall back to the live frame.
        if photoOut.availablePhotoCodecTypes.contains(.jpeg) {
            return try await withCheckedThrowingContinuation { cont in
                sampleQueue.async { [weak self] in
                    guard let self else { return cont.resume(throwing: CameraError.notConnected) }
                    self.captureCont = cont
                    let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                    self.photoOut.capturePhoto(with: settings, delegate: self)
                }
            }
        }
        guard let frame = lastFrame,
              let data = jpegData(from: frame) else {
            throw CameraError.captureFailed("No frame available from the webcam.")
        }
        return data
    }

    func didPersistLastCapture() {}

    private func jpegData(from ci: CIImage) -> Data? {
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.95])
    }

    private func emit(_ s: CameraState) {
        DispatchQueue.main.async { [weak self] in self?.onState?(s) }
    }
}

extension WebcamCameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: pb)
        lastFrame = ci                     // kept full-size: this is what a capture uses
        guard emittingFrames else { return }

        // The camera pushes ~30fps; the preview only needs the configured rate.
        let now = CACurrentMediaTime()
        let minGap = 1.0 / Double(previewFPS)
        guard now - lastFrameAt >= minGap else { return }
        lastFrameAt = now

        // Convert at preview size, not sensor size. A 1080p frame scaled to 960
        // is a quarter of the pixels through CoreImage, every single frame.
        let maxWidth: CGFloat = 960
        var source = ci
        if ci.extent.width > maxWidth {
            let scale = maxWidth / ci.extent.width
            source = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cg = ciContext.createCGImage(source, from: source.extent) else { return }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        DispatchQueue.main.async { [weak self] in self?.onFrame?(img) }
    }
}

extension WebcamCameraService: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        let cont = captureCont
        captureCont = nil
        if let error {
            cont?.resume(throwing: CameraError.captureFailed(error.localizedDescription))
        } else if let data = photo.fileDataRepresentation() {
            cont?.resume(returning: data)
        } else {
            cont?.resume(throwing: CameraError.captureFailed("Empty photo buffer."))
        }
    }
}

// MARK: - Demo source (no hardware)

/// Generates an animated test frame instead of reading a camera. Lets the operator
/// rehearse timings, train a helper, or demo the booth to a client with no DSLR
/// attached. Never selected automatically, and the guest screen shows a DEMO badge
/// while it is active so it cannot be mistaken for a live camera at an event.
final class DemoCameraService: CameraBackendService, @unchecked Sendable {
    var onState: ((CameraState) -> Void)?
    var onFrame: ((NSImage) -> Void)?

    private let queue = DispatchQueue(label: "photobooth.camera.demo")
    private var running = false
    private var connected = false
    private var frameIndex = 0
    private var fps: Int

    init(fps: Int) { self.fps = max(1, min(30, fps)) }
    func setFPS(_ v: Int) { fps = max(1, min(30, v)) }

    func connect() {
        connected = true
        emit(.connected("Demo source (no camera)"))
        Log.shared.warn("Demo camera source active — no real camera is attached")
    }

    func disconnect() {
        connected = false
        running = false
        emit(.disconnected)
    }

    func startLiveView() {
        guard connected, !running else { return }
        running = true
        queue.async { [weak self] in self?.tick() }
    }

    func stopLiveView() { running = false }

    private func tick() {
        guard running, connected else { running = false; return }
        frameIndex += 1
        if let img = Self.frame(index: frameIndex, size: CGSize(width: 960, height: 640)) {
            DispatchQueue.main.async { [weak self] in self?.onFrame?(img) }
        }
        queue.asyncAfter(deadline: .now() + 1.0 / Double(fps)) { [weak self] in self?.tick() }
    }

    func capturePhoto() async throws -> Data {
        guard connected else { throw CameraError.notConnected }
        try await Task.sleep(nanoseconds: 350_000_000)   // mimic shutter latency
        frameIndex += 37
        guard let img = Self.frame(index: frameIndex, size: CGSize(width: 3648, height: 2432)),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
        else { throw CameraError.captureFailed("Could not build a demo frame.") }
        return jpeg
    }

    func didPersistLastCapture() {}

    private static func frame(index: Int, size: CGSize) -> NSImage? {
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let hue = CGFloat((index % 120)) / 120.0
        ctx.setFillColor(NSColor(hue: hue, saturation: 0.35, brightness: 0.55, alpha: 1).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(size.height * 0.006)
        let step = size.height / 12
        var y = step
        while y < size.height { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: size.width, y: y)); y += step }
        var x = step
        while x < size.width { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: size.height)); x += step }
        ctx.strokePath()

        // A marker that visibly moves, so a frozen preview is obvious.
        let t = CGFloat(index % 60) / 60.0
        let r = size.height * 0.10
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.fillEllipse(in: CGRect(x: size.width * t - r, y: size.height / 2 - r, width: r * 2, height: r * 2))

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size.height * 0.09, weight: .heavy),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "DEMO", attributes: attrs))
        let b = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        ctx.textPosition = CGPoint(x: size.width / 2 - b.width / 2 - b.minX, y: size.height * 0.16)
        CTLineDraw(line, ctx)

        guard let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: size.width, height: size.height))
    }

    private func emit(_ s: CameraState) {
        DispatchQueue.main.async { [weak self] in self?.onState?(s) }
    }
}
