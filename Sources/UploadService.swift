import Foundation
import Combine

/// Pushes finished sessions to the gallery site.
///
/// Built for venues with no internet: a finished session is added to a queue that
/// is written to disk immediately, and the queue drains whenever the site becomes
/// reachable — this launch or three days later. Nothing is ever lost by being
/// offline, and the operator can also drag the session folder into the site's
/// upload page by hand if the Mac never gets online.
@MainActor
final class UploadService: ObservableObject {

    struct QueueItem: Codable, Identifiable, Hashable {
        var id: String { "\(eventID)/\(sessionID)" }
        let eventID: String
        let sessionID: String
        var attempts: Int = 0
        var lastError: String?
        var queuedAt: Date = Date()
        var nextAttemptAt: Date = Date()
    }

    enum Reachability: Equatable {
        case unknown
        case offline(String)
        case online(String)      // site name / version

        var label: String {
            switch self {
            case .unknown:        return "Not checked"
            case .offline(let m): return m
            case .online(let n):  return "Connected to \(n)"
            }
        }
    }

    @Published private(set) var queue: [QueueItem] = []
    @Published private(set) var reachability: Reachability = .unknown
    @Published private(set) var isDraining = false
    @Published private(set) var currentUpload: String?
    @Published private(set) var lastSuccessAt: Date?

    /// Set by BoothController for GitHub Pages mode. There is no server to POST
    /// to, so publishing is a git push done by the controller, which owns the
    /// storage the pages are built from.
    var publishToPages: ((String, String) async throws -> Void)?
    /// Read-only reachability probe for the same mode.
    var pagesReachable: (() async -> Result<String, Error>)?

    /// Set by BoothController so a completed upload can update the session record.
    var onSessionUploaded: ((String, String) -> Void)?
    var onSessionFailed: ((String, String, String) -> Void)?
    var resolveFiles: ((String, String) -> (event: EventRecord, session: SessionRecord, dir: URL)?)?

    private var settings = AppSettings()
    private var queueURL: URL
    private var timer: Timer?
    private let session: URLSession

    init() {
        let env = ProcessInfo.processInfo.environment["PHOTOBOOTH_SUPPORT_DIR"]
        let base = (env?.isEmpty == false)
            ? URL(fileURLWithPath: env!, isDirectory: true)
            : FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Photobooth", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        queueURL = base.appendingPathComponent("upload-queue.json")

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 600
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)

        loadQueue()
    }

    var pendingCount: Int { queue.count }
    var failedCount: Int { queue.filter { $0.attempts > 0 && $0.lastError != nil }.count }

    func configure(_ s: AppSettings) {
        let wasEnabled = settings.uploadEnabled
        let hadURL = settings.uploadBaseURL
        settings = s
        if s.uploadEnabled && (!wasEnabled || hadURL != s.uploadBaseURL) {
            Task { await checkReachability() }
        }
        if !s.uploadEnabled { reachability = .unknown }
    }

    func start() {
        timer?.invalidate()
        // Slow poll: at a venue this is usually failing, and hammering a dead
        // network wastes battery. A manual "Upload Now" is always available.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.drain() }
        }
        Task { await drain() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Queue

    private func loadQueue() {
        guard let data = try? Data(contentsOf: queueURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        queue = (try? dec.decode([QueueItem].self, from: data)) ?? []
        if !queue.isEmpty {
            Log.shared.info("Upload queue restored — \(queue.count) session(s) pending")
        }
    }

    private func saveQueue() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(queue) {
            try? data.write(to: queueURL, options: .atomic)
        }
    }

    func enqueue(eventID: String, sessionID: String) {
        guard !queue.contains(where: { $0.eventID == eventID && $0.sessionID == sessionID }) else { return }
        queue.append(QueueItem(eventID: eventID, sessionID: sessionID))
        saveQueue()
        Log.shared.info("Queued for upload: \(eventID)/\(sessionID)")
        Task { await drain() }
    }

    func remove(eventID: String, sessionID: String) {
        queue.removeAll { $0.eventID == eventID && $0.sessionID == sessionID }
        saveQueue()
    }

    func clearFailures() {
        for i in queue.indices {
            queue[i].attempts = 0
            queue[i].lastError = nil
            queue[i].nextAttemptAt = Date()
        }
        saveQueue()
        Task { await drain() }
    }

    // MARK: - Networking

    private var baseURL: URL? {
        var text = settings.uploadBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text)
    }

    @discardableResult
    func checkReachability() async -> Bool {
        guard settings.uploadEnabled else {
            reachability = .unknown
            return false
        }
        if settings.galleryHost != .server {
            guard let probe = pagesReachable else {
                reachability = .unknown
                return false
            }
            switch await probe() {
            case .success(let name):
                reachability = .online(name)
                return true
            case .failure(let e):
                reachability = .offline(e.localizedDescription)
                return false
            }
        }
        guard let base = baseURL else {
            reachability = .unknown
            return false
        }
        var req = URLRequest(url: base.appendingPathComponent("api/ping"))
        req.timeoutInterval = 8
        req.setValue(settings.uploadAPIKey, forHTTPHeaderField: "X-Booth-Key")
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                reachability = .offline("No response from the site")
                return false
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                reachability = .offline("Site rejected the API key")
                return false
            }
            guard http.statusCode == 200 else {
                reachability = .offline("Site returned HTTP \(http.statusCode)")
                return false
            }
            let name = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["name"] as? String
            reachability = .online(name ?? base.host ?? "gallery")
            return true
        } catch {
            reachability = .offline(friendly(error))
            return false
        }
    }

    private func friendly(_ error: Error) -> String {
        let ns = error as NSError
        switch ns.code {
        case NSURLErrorNotConnectedToInternet: return "No internet connection"
        case NSURLErrorCannotFindHost:         return "Cannot find the site's address"
        case NSURLErrorCannotConnectToHost:    return "Site is not answering"
        case NSURLErrorTimedOut:               return "Connection timed out"
        case NSURLErrorNetworkConnectionLost:  return "Connection dropped"
        default:                               return ns.localizedDescription
        }
    }

    // MARK: - Draining

    func uploadNow() {
        clearFailures()
    }

    func drain() async {
        let configured = settings.galleryHost == .server ? baseURL != nil : publishToPages != nil
        guard settings.uploadEnabled, configured, !isDraining else { return }
        let due = queue.filter { $0.nextAttemptAt <= Date() }
        guard !due.isEmpty else { return }
        guard await checkReachability() else { return }

        isDraining = true
        defer { isDraining = false; currentUpload = nil }

        for item in due {
            guard queue.contains(where: { $0.id == item.id }) else { continue }
            currentUpload = item.sessionID
            do {
                try await upload(item)
                remove(eventID: item.eventID, sessionID: item.sessionID)
                lastSuccessAt = Date()
                onSessionUploaded?(item.eventID, item.sessionID)
                Log.shared.info("Uploaded \(item.eventID)/\(item.sessionID)")
            } catch UploadError.missingFiles(let id) {
                // The session was deleted after being queued. Retrying can never
                // fix that, and one dead entry must not block everything behind
                // it — drop it and carry on with the rest.
                remove(eventID: item.eventID, sessionID: item.sessionID)
                Log.shared.warn("Dropped \(id) from the upload queue — its files are gone")
                continue
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? friendly(error)
                if let i = queue.firstIndex(where: { $0.id == item.id }) {
                    queue[i].attempts += 1
                    queue[i].lastError = message
                    // Back off 30s, 1m, 2m, 4m … capped at 15 minutes.
                    let delay = min(900.0, 30.0 * pow(2, Double(queue[i].attempts - 1)))
                    queue[i].nextAttemptAt = Date().addingTimeInterval(delay)
                    saveQueue()
                }
                onSessionFailed?(item.eventID, item.sessionID, message)
                Log.shared.error("Upload failed for \(item.sessionID): \(message)")
                // One bad network means the rest will fail too; stop and retry later.
                break
            }
        }
    }

    private func upload(_ item: QueueItem) async throws {
        if settings.galleryHost != .server {
            guard let publish = publishToPages else { throw UploadError.notConfigured }
            try await publish(item.eventID, item.sessionID)
            return
        }
        guard let base = baseURL else { throw UploadError.notConfigured }
        guard let resolved = resolveFiles?(item.eventID, item.sessionID) else {
            throw UploadError.missingFiles(item.sessionID)
        }
        let (event, rec, dir) = resolved

        var files: [(name: String, url: URL, role: String)] = []
        if settings.uploadOriginals {
            for photo in rec.photos.sorted(by: { $0.index < $1.index }) {
                let u = dir.appendingPathComponent(photo.fileName)
                if FileManager.default.fileExists(atPath: u.path) {
                    files.append((photo.fileName, u, "photo"))
                }
            }
        }
        if settings.uploadPrints, let printName = rec.printFileName {
            let u = dir.appendingPathComponent(printName)
            if FileManager.default.fileExists(atPath: u.path) {
                files.append((printName, u, "print"))
            }
        }
        guard !files.isEmpty else { throw UploadError.missingFiles(item.sessionID) }

        let meta: [String: Any] = [
            "event": [
                "id": event.id,
                "name": event.name,
                "client": event.client,
                "venue": event.venue,
                "date": ISO8601DateFormatter().string(from: event.date),
                "notes": event.notes
            ],
            "session": [
                "id": rec.id,
                "startedAt": ISO8601DateFormatter().string(from: rec.startedAt),
                "layout": rec.layout.rawValue,
                "layoutTitle": rec.layout.title,
                "photoCount": rec.photos.count
            ]
        ]

        let boundary = "PhotoboothBoundary-\(UUID().uuidString)"
        let body = try multipartBody(boundary: boundary, meta: meta, files: files)

        var req = URLRequest(url: base.appendingPathComponent("api/upload"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue(settings.uploadAPIKey, forHTTPHeaderField: "X-Booth-Key")
        req.timeoutInterval = 300

        let (data, response) = try await session.upload(for: req, fromFile: body)
        try? FileManager.default.removeItem(at: body)

        guard let http = response as? HTTPURLResponse else { throw UploadError.badResponse("No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw UploadError.badResponse(detail ?? "HTTP \(http.statusCode) \(text.prefix(120))")
        }
    }

    /// Streams the multipart body to a temp file so a 40-photo session is never
    /// held in memory twice.
    private func multipartBody(boundary: String,
                               meta: [String: Any],
                               files: [(name: String, url: URL, role: String)]) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pb-upload-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: tmp) else {
            throw UploadError.badResponse("Could not stage the upload")
        }
        defer { try? handle.close() }

        func write(_ s: String) { if let d = s.data(using: .utf8) { handle.write(d) } }

        let metaJSON = try JSONSerialization.data(withJSONObject: meta)
        write("--\(boundary)\r\n")
        write("Content-Disposition: form-data; name=\"meta\"\r\n")
        write("Content-Type: application/json\r\n\r\n")
        handle.write(metaJSON)
        write("\r\n")

        for f in files {
            write("--\(boundary)\r\n")
            write("Content-Disposition: form-data; name=\"\(f.role)\"; filename=\"\(f.name)\"\r\n")
            write("Content-Type: image/jpeg\r\n\r\n")
            guard let reader = try? FileHandle(forReadingFrom: f.url) else {
                throw UploadError.missingFiles(f.name)
            }
            while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
                handle.write(chunk)
            }
            try? reader.close()
            write("\r\n")
        }
        write("--\(boundary)--\r\n")
        return tmp
    }
}

enum UploadError: LocalizedError {
    case notConfigured
    case missingFiles(String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:      return "The gallery site address is not set."
        case .missingFiles(let s): return "Files for \(s) are missing on disk."
        case .badResponse(let m): return m
        }
    }
}
