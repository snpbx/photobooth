import AppKit
import AVFoundation
import CoreGraphics
import CoreImage

/// Records the whole session as a short film: the live view as it ran, the
/// shutter as a white flash, and each photograph held on screen the way the
/// guests saw it.
///
/// **Encoded as it happens, not afterwards.** A two-minute session at fifteen
/// frames a second is eighteen hundred frames; holding them to encode at the end
/// would be gigabytes of pixels and a wait the next group would feel. Frames go
/// into an `AVAssetWriter` as they arrive and the file is finished moments after
/// the last shot.
///
/// **H.264 in an MP4**, because the point of this clip is that a guest can post
/// it: Instagram, TikTok, WhatsApp and Messages all take that and nothing is
/// asked of the phone. A GIF is for the loop; this is for the story.
///
/// Timestamps come from the wall clock rather than from a frame counter. The
/// camera's preview stutters — it stops dead during each capture while the
/// mirror is up — and counting frames would quietly speed those gaps up until
/// the clip no longer matched what happened in the booth.
final class SessionVideoRecorder: @unchecked Sendable {

    enum VideoError: LocalizedError {
        case noFrames
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .noFrames:           return "Nothing was recorded — live view was not running."
            case .writerFailed(let m): return "Could not write the video: \(m)"
            }
        }
    }

    /// Everything touching the writer runs here. Frames arrive on the main actor
    /// while the booth is drawing a countdown; encoding one must never be the
    /// reason a digit stutters.
    private let queue = DispatchQueue(label: "photobooth.video", qos: .userInitiated)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var size = CGSize(width: 1280, height: 720)
    private var fps: Int32 = 15
    private var startedAt: Date?
    private var lastPresented: CMTime = .zero
    private var frameCount = 0
    /// Set while `finish()` is closing the file.
    ///
    /// The writer is still the live one during that stretch, but a clip being
    /// written is not a clip that can take frames — and a booth that started a
    /// second film here would point it at the path the first is still finishing
    /// into, leaving an empty file where the session's film should be.
    private var finishing = false
    private var ownerID: String?
    private(set) var url: URL?

    /// Which session this film belongs to.
    ///
    /// A recorder outlives any one session, and a film left open by a session
    /// that ended badly used to go on taking frames — from the next group, into
    /// the previous group's file. The owner is how the booth can tell that the
    /// thing still recording is not its own.
    var owner: String? { queue.sync { ownerID } }

    var isRecording: Bool { queue.sync { writer != nil || finishing } }

    // MARK: - Starting

    /// - Parameters:
    ///   - size: the clip's own frame. Taken from the camera's first preview so
    ///     nothing is stretched, rounded to even numbers because H.264 cannot
    ///     encode an odd dimension.
    func start(url target: URL, size wanted: CGSize, fps wantedFPS: Int, owner: String) throws {
        try queue.sync {
            guard !finishing else {
                throw VideoError.writerFailed("the previous film is still being written")
            }
            try? FileManager.default.removeItem(at: target)
            let w = max(160, Int(wanted.width.rounded()) & ~1)
            let h = max(160, Int(wanted.height.rounded()) & ~1)
            size = CGSize(width: w, height: h)
            fps = Int32(max(8, min(wantedFPS, 30)))

            let writer = try AVAssetWriter(outputURL: target, fileType: .mp4)
            // A middling bitrate on purpose: this is watched on a phone and sent
            // over venue wifi, and nobody has ever wished a photobooth clip were
            // larger. Baseline profile for the oldest phone in the room.
            let bitrate = Int(Double(w * h) * 4.0)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: w,
                AVVideoHeightKey: h,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2
                ]
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: w,
                    kCVPixelBufferHeightKey as String: h
                ])
            guard writer.canAdd(input) else { throw VideoError.writerFailed("the writer refused the video track") }
            writer.add(input)
            guard writer.startWriting() else {
                throw VideoError.writerFailed(writer.error?.localizedDescription ?? "unknown")
            }
            writer.startSession(atSourceTime: .zero)

            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.startedAt = Date()
            self.lastPresented = .zero
            self.frameCount = 0
            self.url = target
            self.ownerID = owner
        }
    }

    // MARK: - Frames

    /// One live-view frame, placed at the moment it actually arrived.
    func append(_ image: NSImage) {
        guard isRecording else { return }
        queue.async { [weak self] in
            guard let self, let started = self.startedAt else { return }
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            self.write(cg, at: Date().timeIntervalSince(started))
        }
    }

    /// A photograph, or a flash, held for a moment.
    ///
    /// Held by writing one frame at the start and one at the end rather than
    /// sixty in between: every frame in that span is identical, and the encoder
    /// only has to be told where it stops.
    func hold(_ image: CGImage, seconds: Double) {
        guard isRecording else { return }
        queue.async { [weak self] in
            guard let self, let started = self.startedAt else { return }
            let now = Date().timeIntervalSince(started)
            self.write(image, at: now)
            self.write(image, at: now + max(0.1, seconds))
            // The clock keeps running while a still is held, so the next live
            // frame lands after it rather than underneath it.
            self.startedAt = started.addingTimeInterval(-max(0.1, seconds))
        }
    }

    /// Must be called on the queue.
    private func write(_ image: CGImage, at seconds: Double) {
        guard let adaptor, let input, input.isReadyForMoreMediaData else { return }
        var time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        // Never backwards, and never twice on the same tick: the writer rejects
        // both outright and one rejection kills the whole file.
        if time <= lastPresented {
            time = CMTimeAdd(lastPresented, CMTime(value: 1, timescale: 600))
        }
        guard let buffer = pixelBuffer(from: image) else { return }
        if adaptor.append(buffer, withPresentationTime: time) {
            lastPresented = time
            frameCount += 1
        }
    }

    /// Scales and letterboxes a frame into the clip's own shape. A booth that
    /// changes camera mid-event would otherwise end the session with a writer
    /// rejecting every frame.
    private func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        guard let pool = adaptor?.pixelBufferPool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess,
              let buffer = out else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let ctx = CGContext(data: base,
                                  width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        guard iw > 0, ih > 0 else { return nil }
        let scale = min(size.width / iw, size.height / ih)
        let w = iw * scale, h = ih * scale
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
        return buffer
    }

    // MARK: - Finishing

    /// Closes the file and hands back where it landed. Throws rather than
    /// returning nil when there is nothing in it: a zero-frame MP4 plays as a
    /// black rectangle, which looks like a broken booth rather than a quiet one.
    func finish() async throws -> URL {
        let (writer, input, frames, target): (AVAssetWriter?, AVAssetWriterInput?, Int, URL?) =
            queue.sync {
                self.finishing = true
                return (self.writer, self.input, self.frameCount, self.url)
            }
        defer {
            queue.sync {
                self.writer = nil; self.input = nil; self.adaptor = nil
                self.startedAt = nil; self.frameCount = 0; self.finishing = false
                self.ownerID = nil
            }
        }
        guard let writer, let input, let target else { throw VideoError.noFrames }
        guard frames > 1 else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: target)
            throw VideoError.noFrames
        }

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw VideoError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
        // The writer can report itself content and still leave nothing on disk —
        // it did, when a second recording replaced this file while this one was
        // closing. An empty MP4 is worse than no MP4: it plays as a black
        // rectangle, and an upload of it is refused outright, which used to take
        // the session's photographs down with it.
        let bytes = (try? FileManager.default.attributesOfItem(atPath: target.path))
            .flatMap { $0[.size] as? Int } ?? 0
        guard bytes > 0 else {
            try? FileManager.default.removeItem(at: target)
            throw VideoError.noFrames
        }
        return target
    }

    /// Throws the recording away — a cancelled session, or one that failed
    /// before anybody was photographed.
    func cancel() {
        queue.sync {
            writer?.cancelWriting()
            if let url { try? FileManager.default.removeItem(at: url) }
            writer = nil; input = nil; adaptor = nil; startedAt = nil; frameCount = 0
            ownerID = nil
        }
    }

    // MARK: - Cards

    /// The still the clip opens and closes on: the booth's own branding, so a
    /// clip posted by a guest says whose booth it was.
    static func card(size: CGSize, backgroundHex: String, logo: CGImage?,
                     title: String, subtitle: String) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(LayoutRenderer.cgColor(backgroundHex))
        ctx.fill(CGRect(origin: .zero, size: size))

        var y = size.height * 0.56
        if let logo, logo.width > 0, logo.height > 0 {
            let maxW = size.width * 0.5, maxH = size.height * 0.26
            let scale = min(maxW / CGFloat(logo.width), maxH / CGFloat(logo.height))
            let w = CGFloat(logo.width) * scale, h = CGFloat(logo.height) * scale
            ctx.draw(logo, in: CGRect(x: size.width / 2 - w / 2, y: y, width: w, height: h))
        } else if !title.isEmpty {
            LayoutRenderer.drawText(ctx, title,
                                    centeredIn: CGRect(x: 0, y: y, width: size.width, height: size.height * 0.2),
                                    fontSize: size.height * 0.10, weight: .bold,
                                    color: CGColor(gray: 1, alpha: 0.92))
        }
        y = size.height * 0.36
        if !subtitle.isEmpty {
            LayoutRenderer.drawText(ctx, subtitle,
                                    centeredIn: CGRect(x: 0, y: y, width: size.width, height: size.height * 0.12),
                                    fontSize: size.height * 0.045, weight: .medium,
                                    color: CGColor(gray: 1, alpha: 0.65))
        }
        return ctx.makeImage()
    }

    /// The shutter, as the guests saw it.
    static func flash(size: CGSize) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }

    static let fileName = "session.mp4"
}
