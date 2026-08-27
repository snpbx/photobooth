import Foundation
import AppKit
import Combine

enum PrintError: LocalizedError {
    case noPrinter
    case printerUnavailable(String)
    case submitFailed(String)
    case duplicateSuppressed

    var errorDescription: String? {
        switch self {
        case .noPrinter:                 return "No printer selected. Choose the SELPHY in Admin › Printer."
        case .printerUnavailable(let n): return "\(n) is not available. Check that it is powered on and connected."
        case .submitFailed(let m):       return "The print job was rejected: \(m)"
        case .duplicateSuppressed:       return "That print was already sent a moment ago."
        }
    }
}

struct PrintJob: Identifiable, Equatable {
    let id: String          // CUPS job id, e.g. Canon_SELPHY_CP1500-42
    let sessionID: String
    let submittedAt: Date
    var done: Bool = false
    var failed: Bool = false
}

/// Printing goes through the macOS print system (CUPS) rather than the SELPHY's
/// own protocol: `lp` gives us a job id we can track, and lets us ask for the
/// borderless Postcard media the CP1500 exposes.
@MainActor
final class PrinterService: ObservableObject {
    @Published private(set) var state: PrinterState = .unknown
    @Published private(set) var availablePrinters: [String] = []
    @Published private(set) var systemDefault: String = ""
    @Published private(set) var jobs: [PrintJob] = []
    @Published private(set) var queueDepth: Int = 0

    private var selected: String = ""
    private var borderless = true
    private var poller: Timer?
    private var lastSubmit: (session: String, at: Date)?

    /// Set by the controller: polling `lpstat` spawns processes, so it only runs
    /// while somebody can see the result or a job is actually moving.
    var shouldPoll: () -> Bool = { true }
    private var tick = 0

    // MARK: - Configuration

    func configure(printerName: String, borderless: Bool) {
        self.borderless = borderless
        if printerName != selected {
            selected = printerName
            refresh()
        }
    }

    var selectedPrinter: String { selected }

    func startMonitoring() {
        refresh()
        poller?.invalidate()
        // 3s base tick, but a quiet idle printer is only checked every fifth one.
        poller = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollTick() }
        }
    }

    private func pollTick() {
        tick &+= 1
        guard shouldPoll() else { return }
        let busy = queueDepth > 0 || jobs.contains { !$0.done && !$0.failed }
        if busy || tick % 5 == 0 { refresh() }
    }

    func stopMonitoring() {
        poller?.invalidate()
        poller = nil
    }

    // MARK: - Discovery & status

    func refresh() {
        Task.detached(priority: .utility) {
            let listing = Shell.run("/usr/bin/lpstat", ["-p", "-d"])
            await MainActor.run { self.applyListing(listing.out) }
        }
    }

    private func applyListing(_ text: String) {
        var names: [String] = []
        var statusLine: [String: String] = [:]
        var def = ""

        for line in text.split(separator: "\n").map(String.init) {
            if line.hasPrefix("printer ") {
                let rest = line.dropFirst("printer ".count)
                if let name = rest.split(separator: " ").first.map(String.init) {
                    names.append(name)
                    statusLine[name] = String(rest.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
                }
            } else if line.hasPrefix("system default destination:") {
                def = line.replacingOccurrences(of: "system default destination:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        availablePrinters = names
        systemDefault = def

        // An empty selection quietly falls back to the system default (the SELPHY, on this Mac).
        let target = selected.isEmpty ? def : selected
        guard !target.isEmpty else {
            state = .notSelected
            queueDepth = 0
            return
        }
        guard names.contains(target) else {
            state = .error("\(target) is not installed on this Mac")
            queueDepth = 0
            return
        }

        let s = statusLine[target] ?? ""
        if s.contains("disabled") {
            state = .stopped(target)
        } else if s.contains("printing") {
            state = .printing(target)
        } else if s.contains("idle") {
            state = .idle(target)
        } else {
            state = .idle(target)
        }

        Task.detached(priority: .utility) {
            let q = Shell.run("/usr/bin/lpstat", ["-o", target])
            await MainActor.run { self.applyQueue(q.out) }
        }
    }

    private func applyQueue(_ text: String) {
        let active = Set(text.split(separator: "\n").compactMap { line -> String? in
            line.split(separator: " ").first.map(String.init)
        })
        queueDepth = active.count

        for i in jobs.indices where !jobs[i].done && !jobs[i].failed {
            if !active.contains(jobs[i].id) {
                jobs[i].done = true
                Log.shared.info("Print job \(jobs[i].id) completed (session \(jobs[i].sessionID))")
            }
        }
        if jobs.count > 40 { jobs.removeFirst(jobs.count - 40) }
    }

    // MARK: - Printing

    /// Submits a 4×6 image. `allowRepeat` is set for an explicit reprint so the
    /// double-tap guard does not swallow it.
    @discardableResult
    func submit(fileURL: URL,
                sessionID: String,
                copies: Int,
                allowRepeat: Bool = false) throws -> PrintJob {
        if !allowRepeat, let last = lastSubmit,
           last.session == sessionID, Date().timeIntervalSince(last.at) < 8 {
            Log.shared.warn("Duplicate print suppressed for session \(sessionID)")
            throw PrintError.duplicateSuppressed
        }

        let target = selected.isEmpty ? systemDefault : selected
        guard !target.isEmpty else { throw PrintError.noPrinter }
        guard availablePrinters.contains(target) else { throw PrintError.printerUnavailable(target) }
        if case .error(let m) = state { throw PrintError.printerUnavailable(m) }

        var args = ["-d", target, "-n", String(max(1, copies))]
        args += ["-t", "Photobooth \(sessionID)"]
        args += ["-o", borderless ? "media=Postcard.Fullbleed" : "media=Postcard"]
        args += ["-o", "MediaType=photographic"]
        args += ["-o", "ColorModel=RGB"]
        args += ["-o", "fit-to-page"]
        args += ["-o", "orientation-requested=3"]   // portrait, no auto-rotation
        args.append(fileURL.path)

        let r = Shell.run("/usr/bin/lp", args)
        guard r.status == 0 else {
            let msg = (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines)
            Log.shared.error("lp failed for \(sessionID): \(msg)")
            throw PrintError.submitFailed(msg.isEmpty ? "exit \(r.status)" : msg)
        }

        // "request id is Canon_SELPHY_CP1500-42 (1 file(s))"
        let jobID = r.out
            .replacingOccurrences(of: "request id is ", with: "")
            .split(separator: " ").first.map(String.init) ?? "\(target)-?"

        lastSubmit = (sessionID, Date())
        let job = PrintJob(id: jobID, sessionID: sessionID, submittedAt: Date())
        jobs.append(job)
        Log.shared.info("Print submitted: \(jobID) — \(copies) copy/copies of session \(sessionID)")
        refresh()
        return job
    }

    func cancelAll() {
        let target = selected.isEmpty ? systemDefault : selected
        guard !target.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            _ = Shell.run("/usr/bin/cancel", ["-a", target])
            Log.shared.warn("All queued print jobs cancelled on \(target)")
            await MainActor.run { self.refresh() }
        }
    }

    /// A single-page 4×6 test sheet so the operator can confirm alignment and colour before guests arrive.
    func testPrintImage(settings: AppSettings) -> Data? {
        let canvas = settings.pixelSize
        guard let cg = try? renderTestSheet(canvas: canvas, settings: settings) else { return nil }
        return LayoutRenderer.jpegData(from: cg, dpi: settings.dpi)
    }

    private func renderTestSheet(canvas: CGSize, settings: AppSettings) throws -> CGImage {
        guard let ctx = CGContext(data: nil,
                                  width: Int(canvas.width), height: Int(canvas.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw RenderError.noContext }

        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: canvas))

        // Colour bars across the top half.
        let bars: [CGColor] = [
            CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            CGColor(red: 0, green: 1, blue: 0, alpha: 1),
            CGColor(red: 0, green: 0, blue: 1, alpha: 1),
            CGColor(red: 0, green: 1, blue: 1, alpha: 1),
            CGColor(red: 1, green: 0, blue: 1, alpha: 1),
            CGColor(red: 1, green: 1, blue: 0, alpha: 1),
            CGColor(gray: 0.5, alpha: 1)
        ]
        let barW = canvas.width / CGFloat(bars.count)
        for (i, c) in bars.enumerated() {
            ctx.setFillColor(c)
            ctx.fill(CGRect(x: CGFloat(i) * barW, y: canvas.height * 0.55,
                            width: barW, height: canvas.height * 0.30))
        }

        // Grey ramp.
        let steps = 11
        let rampW = canvas.width / CGFloat(steps)
        for i in 0..<steps {
            ctx.setFillColor(CGColor(gray: CGFloat(i) / CGFloat(steps - 1), alpha: 1))
            ctx.fill(CGRect(x: CGFloat(i) * rampW, y: canvas.height * 0.42,
                            width: rampW, height: canvas.height * 0.12))
        }

        // Edge frame — if any side is missing on the print, the media size is wrong.
        let inset: CGFloat = 6
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(4)
        ctx.stroke(CGRect(origin: CGPoint(x: inset, y: inset),
                          size: CGSize(width: canvas.width - inset * 2,
                                       height: canvas.height - inset * 2)))

        guard let img = ctx.makeImage() else { throw RenderError.noContext }
        return img
    }
}

// MARK: - Process helper

enum Shell {
    struct Result { let status: Int32; let out: String; let err: String }

    /// Arguments are passed as an argv array — never through a shell — so printer
    /// names and paths cannot be interpreted as commands.
    ///
    /// The timeout is real: a wedged `lp` talking to a powered-off SELPHY must not
    /// be able to hang the booth, so output is drained on background queues and the
    /// child is killed if it overruns.
    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 10,
                    environment: [String: String]? = nil) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let environment { p.environment = environment }
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        do { try p.run() } catch {
            return Result(status: -1, out: "", err: error.localizedDescription)
        }

        let lock = NSLock()
        var outData = Data(), errData = Data()
        let drain = DispatchGroup()

        for (pipe, isOut) in [(o, true), (e, false)] {
            drain.enter()
            DispatchQueue.global(qos: .utility).async {
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock()
                if isOut { outData = d } else { errData = d }
                lock.unlock()
                drain.leave()
            }
        }

        let exited = DispatchGroup()
        exited.enter()
        DispatchQueue.global(qos: .utility).async {
            p.waitUntilExit()
            exited.leave()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        _ = drain.wait(timeout: .now() + 2)

        lock.lock()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        lock.unlock()

        if timedOut {
            return Result(status: -2, out: out, err: "\(path) timed out after \(Int(timeout))s")
        }
        return Result(status: p.terminationStatus, out: out, err: err)
    }
}
