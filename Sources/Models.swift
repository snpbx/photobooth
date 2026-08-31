import Foundation
import SwiftUI

// MARK: - Print layout

enum PrintLayout: String, Codable, CaseIterable, Identifiable {
    case duplicateStrips   // A — 4 photos, strip duplicated side by side
    case eightUnique       // B — 8 unique photos in a 2x4 grid
    case fourFullPage      // C — 4 photos, hero / pair / hero

    var id: String { rawValue }

    var title: String {
        switch self {
        case .duplicateStrips: return "4 Duplicate Strips"
        case .eightUnique:     return "8 Unique Shots"
        case .fourFullPage:    return "4 Photos — 2×2 Grid"
        }
    }

    var subtitle: String {
        switch self {
        case .duplicateStrips: return "Classic strip, printed twice — one for each guest"
        case .eightUnique:     return "Eight different shots across the whole print"
        case .fourFullPage:    return "Four portrait frames on a wide mat"
        }
    }

    var photoCount: Int {
        switch self {
        case .duplicateStrips: return 4
        case .eightUnique:     return 8
        case .fourFullPage:    return 4
        }
    }

}

// MARK: - Event

/// A client booking. Every session belongs to exactly one event, so a night's
/// photographs stay segregated per client rather than piling into one folder.
struct EventRecord: Codable, Identifiable, Hashable {
    var id: String                 // slug — also the folder name
    var name: String
    var client: String = ""
    var venue: String = ""
    var date: Date = Date()
    var notes: String = ""
    var createdAt: Date = Date()
    var archived: Bool = false
    var coverSessionID: String?
    /// Set once the gallery site has an album for this event.
    var publishedSlug: String?
    /// Password for this event's album page. Kept on the Mac only — the page
    /// itself never contains it, just what it unlocks.
    var albumPassword: String = ""

    /// "Cruz & Santos Wedding" -> "2026-08-21-cruz-santos-wedding"
    static func makeSlug(name: String, date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let cleaned = name
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let words = String(cleaned).split(separator: "-", omittingEmptySubsequences: true)
        let body = words.joined(separator: "-")
        let stem = body.isEmpty ? "event" : String(body.prefix(48))
        return "\(f.string(from: date))-\(stem)"
    }

    var displayDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: date)
    }

    /// Sessions saved before events existed are surfaced under this pseudo-event
    /// rather than being moved on disk.
    static let unfiledID = "__unfiled__"
    static var unfiled: EventRecord {
        EventRecord(id: unfiledID, name: "Unfiled", client: "",
                    notes: "Sessions recorded before events were introduced.")
    }
    var isUnfiled: Bool { id == Self.unfiledID }
}

// MARK: - Photo

struct Photo: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var index: Int              // 1-based position within the session
    var fileName: String
    var capturedAt: Date
    var width: Int
    var height: Int

    func url(in sessionDir: URL) -> URL { sessionDir.appendingPathComponent(fileName) }
}

// MARK: - Session

enum PrintStatus: String, Codable {
    case notPrinted
    case queued
    case printing
    case printed
    case failed

    var label: String {
        switch self {
        case .notPrinted: return "Not printed"
        case .queued:     return "Queued"
        case .printing:   return "Printing"
        case .printed:    return "Printed"
        case .failed:     return "Print failed"
        }
    }

    var tint: Color {
        switch self {
        case .notPrinted: return VHS.dim
        case .queued, .printing: return VHS.amber
        case .printed:    return VHS.ok
        case .failed:     return VHS.rec
        }
    }
}

struct SessionRecord: Codable, Identifiable, Hashable {
    var id: String              // also the folder name: 2026-08-21_23-45-12
    var eventID: String = EventRecord.unfiledID
    var startedAt: Date
    var finishedAt: Date?
    var layout: PrintLayout
    var photos: [Photo] = []
    var printFileName: String?
    /// Set once the animated GIF has been written into the session folder.
    var gifFileName: String?
    var printStatus: PrintStatus = .notPrinted
    var printJobID: String?
    var copies: Int = 1
    var lastError: String?
    var uploadState: UploadState = .notUploaded
    var uploadedAt: Date?
    /// Shot numbers that were re-taken at least once, newest count last.
    var retakenShots: [Int] = []
    /// Unguessable slug used in the public gallery address. Assigned when the
    /// session is created so the QR code can be built before anything uploads.
    var publicToken: String = ""
}

// MARK: - Gallery upload

enum UploadState: String, Codable {
    case notUploaded
    case queued
    case uploading
    case uploaded
    case failed

    var label: String {
        switch self {
        case .notUploaded: return "Not uploaded"
        case .queued:      return "Waiting to upload"
        case .uploading:   return "Uploading"
        case .uploaded:    return "On the site"
        case .failed:      return "Upload failed"
        }
    }

    var tint: Color {
        switch self {
        case .notUploaded: return VHS.dim
        case .queued, .uploading: return VHS.amber
        case .uploaded:    return VHS.ok
        case .failed:      return VHS.rec
        }
    }

    var glyph: String {
        switch self {
        case .notUploaded: return "icloud.slash"
        case .queued:      return "clock"
        case .uploading:   return "arrow.up.circle"
        case .uploaded:    return "checkmark.icloud"
        case .failed:      return "exclamationmark.icloud"
        }
    }
}

// MARK: - Hardware status

enum CameraState: Equatable {
    case disconnected
    case connecting
    case connected(String)
    case busy(String)
    case error(String)

    var isReady: Bool { if case .connected = self { return true }; return false }

    var label: String {
        switch self {
        case .disconnected:      return "No camera"
        case .connecting:        return "Connecting…"
        case .connected(let m):  return m
        case .busy(let m):       return m
        case .error(let e):      return e
        }
    }

    var tint: Color {
        switch self {
        case .connected:   return VHS.ok
        case .connecting, .busy: return VHS.amber
        case .error:       return VHS.rec
        case .disconnected: return VHS.dim
        }
    }
}

enum PrinterState: Equatable {
    case unknown
    case notSelected
    case idle(String)
    case printing(String)
    case stopped(String)
    case error(String)

    var isReady: Bool {
        switch self {
        case .idle, .printing: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .unknown:         return "Checking…"
        case .notSelected:     return "No printer selected"
        case .idle(let n):     return "\(n) — idle"
        case .printing(let n): return "\(n) — printing"
        case .stopped(let n):  return "\(n) — paused"
        case .error(let e):    return e
        }
    }

    var tint: Color {
        switch self {
        case .idle:      return VHS.ok
        case .printing:  return VHS.amber
        case .stopped:   return VHS.amber
        case .error:     return VHS.rec
        case .unknown, .notSelected: return VHS.dim
        }
    }
}

// MARK: - Session state machine

enum BoothState: Equatable {
    case idle
    case starting
    case countdown(shot: Int, of: Int, remaining: Int)
    case capturing(shot: Int, of: Int)
    case photoPreview(shot: Int, of: Int)
    case interval(shot: Int, of: Int)
    /// Re-shooting a photo the operator picked out by number after the run.
    case retaking(shot: Int, of: Int)
    case generatingPrint
    case printing
    case complete
    case failed(String)

    var isSessionActive: Bool {
        switch self {
        case .idle, .complete, .failed: return false
        default: return true
        }
    }

    var name: String {
        switch self {
        case .idle:            return "IDLE"
        case .starting:        return "STARTING"
        case .countdown:       return "COUNTDOWN"
        case .capturing:       return "CAPTURING"
        case .photoPreview:    return "PHOTO_PREVIEW"
        case .interval:        return "NEXT_PHOTO"
        case .retaking:        return "RETAKING"
        case .generatingPrint: return "GENERATING_PRINT"
        case .printing:        return "PRINTING"
        case .complete:        return "COMPLETE"
        case .failed:          return "FAILED"
        }
    }
}

// MARK: - Camera backend selection

enum CameraBackend: String, Codable, CaseIterable, Identifiable {
    case dslr    // libgphoto2 — Canon EOS 6D over USB
    case webcam  // AVFoundation — any UVC camera
    case demo    // generated test pattern, for rehearsal with no hardware attached

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dslr:   return "Canon DSLR (USB)"
        case .webcam: return "Webcam / UVC"
        case .demo:   return "Demo"
        }
    }

    /// True when no real photographs are being taken.
    var isSimulated: Bool { self == .demo }
}

enum CropMode: String, Codable, CaseIterable, Identifiable {
    case fill   // centre-crop to fill the cell — no bars, no distortion
    case fit    // letterbox inside the cell — nothing cropped

    var id: String { rawValue }
    var title: String { self == .fill ? "Fill (centre crop)" : "Fit (no crop)" }
}

/// Which of the two Admin consoles the operator is using.
enum AdminConsoleStyle: String, Codable, CaseIterable, Identifiable {
    /// Everything: events, camera, booth button, gallery, timing, printer,
    /// storage. What you set the booth up with.
    case full
    /// Session, retakes, layout and copies — the four things anyone touches once
    /// the booth is running and the only decisions left are per-group.
    case minimal

    var id: String { rawValue }
    var title: String { self == .full ? "Full" : "Minimal" }
}

// MARK: - Settings

/// Where the guest QR code sends people.
///
/// Two different jobs share one card: handing a guest their own photographs, and
/// sending them to a page the operator wants followed. They are separate options
/// because a booth with no gallery site still wants a code, and a booth with one
/// does not always want to give up that space.
enum QRTarget: String, Codable, CaseIterable, Identifiable {
    case sessionAlbum      // that session's own photographs
    case customLink        // an address typed in Admin
    case eventAlbum        // the whole event's album page, online
    case both              // their photographs and my link, one card each

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessionAlbum: return "Their Photos"
        case .customLink:   return "My Link"
        case .eventAlbum:   return "The Album"
        case .both:         return "Both"
        }
    }
}

/// Where finished sessions are published.
///
/// GitHub Pages is static hosting: there is no server to receive an upload, so
/// the app writes the pages and photographs into a local git repository and
/// pushes. That is the whole "upload" — the site is the repository.
enum GalleryHost: String, Codable, CaseIterable, Identifiable {
    case server         // the Node site in PhotoboothWeb
    case githubPages    // a static site pushed to GitHub Pages
    case cloudinary     // photographs on Cloudinary's CDN; the QR opens the print

    var id: String { rawValue }

    var title: String {
        switch self {
        case .server:      return "My Server"
        case .githubPages: return "GitHub"
        case .cloudinary:  return "Cloudinary"
        }
    }
}

struct AppSettings: Codable, Equatable {
    // Camera
    var cameraBackend: CameraBackend = .dslr
    var webcamUniqueID: String = ""
    var liveViewEnabled: Bool = true
    var liveViewFPS: Int = 15
    /// Show the camera on the idle screen so guests can see themselves before
    /// they press. Costs a DSLR its battery and some sensor heat all evening.
    var idleLiveView: Bool = true
    var mirrorImages: Bool = true       // preview, review and the saved file, together

    // Timing (seconds)
    var countdownSeconds: Int = 3
    var previewSeconds: Double = 2
    var shotIntervalSeconds: Double = 1
    var completeScreenSeconds: Double = 6

    // Print
    var printerName: String = ""
    var layout: PrintLayout = .duplicateStrips
    var copies: Int = 1
    var autoPrint: Bool = true
    var borderless: Bool = true
    var dpi: Int = 300
    var cropMode: CropMode = .fill
    var outerMarginInches: Double = 0.20
    var gutterInches: Double = 0.07
    var backgroundHex: String = "#FFFFFF"
    var footerText: String = ""
    /// File name of artwork imported through Admin, inside `BrandingAssets`.
    /// When set it takes the place of the footer text on the print.
    var footerImageFile: String = ""
    var footerEnabled: Bool = true

    // Gallery site
    var uploadEnabled: Bool = false
    var uploadBaseURL: String = ""
    var uploadAPIKey: String = ""
    var uploadOriginals: Bool = true
    var uploadPrints: Bool = true
    var galleryHost: GalleryHost = .server
    var pagesRepoPath: String = ""           // local clone of the GitHub Pages repo
    var pagesRemote: String = ""             // git@github.com:user/repo.git or the https form
    var pagesBranch: String = "main"
    var pagesLongEdge: Int = 1600            // web copies; originals stay on the Mac

    // Animated GIF
    /// Build a looping GIF of the session's photographs and hand it over with
    /// the print. Costs about a second of CPU at the end of a session.
    var makeGIF: Bool = true
    /// How many seconds of the run-up to each shot the loop replays. The GIF is
    /// played back at real speed, so this is also the length of the loop.
    /// Clamped to `GIFRenderer.minSeconds ... maxSeconds` when it is rendered.
    var gifSeconds: Double = 3
    /// Preview frames kept per second. With `gifSeconds` this sets the frame
    /// count, and frame count is most of what a GIF weighs.
    var gifFPS: Int = 10
    /// Long edge in pixels. GIF has no real compression for photographs, so this
    /// is the single number that decides the file size.
    var gifLongEdge: Int = 480
    var uploadGIFs: Bool = true
    var cloudinaryCloudName: String = ""     // from the Cloudinary dashboard
    var cloudinaryPreset: String = ""        // an UNSIGNED upload preset — never a secret
    var albumOutputPath: String = ""         // where album pages are written
    /// The folder the album pages are uploaded to, e.g. https://photos.example.com/albums
    var albumBaseURL: String = ""

    // Booth button (USB HID trigger)
    var triggerEnabled: Bool = true
    var triggerKeyCode: Int = 76             // keypad enter — what most booth buttons send
    var triggerGlobal: Bool = true           // fire even when Photobooth is not frontmost
    var triggerDebounceMs: Int = 600
    var holdFinishUntilPress: Bool = true    // the finish screen waits for the button
    var finishHoldTimeoutSeconds: Double = 180   // 0 = wait forever

    // QR handout
    var showQRCode: Bool = true
    var printQRCode: Bool = false
    var qrCaption: String = "SCAN TO GET YOUR PHOTOS"
    var qrTarget: QRTarget = .sessionAlbum
    var customQRLink: String = ""            // Instagram, a website — typed in Admin
    var customQRCaption: String = "FOLLOW US FOR YOUR PHOTOS"
    /// Hold the photos code back until the photographs are actually online.
    var qrRequiresUpload: Bool = true

    // Storage
    var rootPathOverride: String = ""
    var keepOriginalsOnCard: Bool = false

    // Interface
    /// Strips the guest screen of everything that redraws when nothing has
    /// happened. For a booth running on a USB, wireless or streamed panel — an
    /// iPad over USB, a DisplayLink adapter, screen sharing — where the whole
    /// frame is captured, compressed and shipped every time a pixel moves, so a
    /// decorative loop costs real bandwidth all evening. Off by default: on a
    /// directly-attached monitor the full treatment is free.
    var lightRendering: Bool = false
    /// Mark off what the print will keep, on the guest screen, so people frame
    /// themselves inside it rather than against the whole picture.
    var framingGuide: Bool = true
    var fullScreenOnLaunch: Bool = true
    var boothDisplayID: String = ""          // CGDirectDisplayID as text; empty = pick automatically
    var openBoothOnLaunch: Bool = false
    var idleHeadline: String = "PRESS BUTTON TO START"
    var idleSubhead: String = "Say cheese"
    var eventTitle: String = "PHOTOBOOTH"
    var adminPasscode: String = ""
    var accentHex: String = "#E8B33C"
    var lastAdminTab: String = "Control"   // reopen where the operator left off
    var adminConsole: AdminConsoleStyle = .full
    /// Size the console's controls for a fingertip. Cannot be detected — an iPad
    /// used as a monitor delivers its touches as ordinary mouse clicks — so the
    /// operator sets it.
    var touchControls: Bool = false
    var activeEventID: String = ""         // empty = nothing selected yet

    var pixelSize: CGSize { CGSize(width: 4 * Double(dpi), height: 6 * Double(dpi)) }
}

// MARK: - Log

struct LogEntry: Identifiable {
    enum Level: String { case info = "INFO", warn = "WARN", error = "ERROR" }
    let id = UUID()
    let at: Date
    let level: Level
    let message: String

    var tint: Color {
        switch level {
        case .info:  return VHS.dim
        case .warn:  return VHS.amber
        case .error: return VHS.rec
        }
    }
}

// MARK: - Formatting helpers

extension Date {
    var sessionFolderName: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: self)
    }

    var displayStamp: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: self)
    }

    var clockStamp: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: self)
    }
}

extension Int {
    /// Megabytes as a human-sized string: "512 MB", "136 GB".
    var asDiskSize: String {
        self >= 1024 ? String(format: "%.0f GB", Double(self) / 1024) : "\(self) MB"
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { self = .white; return }
        self.init(.sRGB,
                  red:   Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue:  Double(v & 0xFF) / 255)
    }
}
