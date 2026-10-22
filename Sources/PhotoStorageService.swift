import Foundation
import AppKit

enum StorageError: LocalizedError {
    case lowDiskSpace(freeMB: Int)
    case notWritable(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .lowDiskSpace(let mb): return "Only \(mb) MB free — free up disk space before continuing."
        case .notWritable(let p):   return "Cannot write to \(p). Check folder permissions."
        case .writeFailed(let m):   return "Could not save the photograph: \(m)"
        }
    }
}

/// Owns the on-disk tree, one folder per client event:
///
///   <root>/Events/<eventID>/event.json
///   <root>/Events/<eventID>/Sessions/<sessionID>/photo-01.jpg … print.jpg, session.json
///
/// Sessions recorded before events existed still live at <root>/Sessions/. They
/// are read in place and shown under a pseudo-event called "Unfiled" — nothing on
/// disk is moved behind the operator's back.
@MainActor
final class PhotoStorageService: ObservableObject {
    @Published private(set) var sessions: [SessionRecord] = []
    @Published private(set) var events: [EventRecord] = []
    @Published private(set) var freeSpaceMB: Int = 0

    private var rootOverride: String = ""

    var root: URL {
        if !rootOverride.isEmpty {
            return URL(fileURLWithPath: (rootOverride as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photobooth", isDirectory: true)
    }

    var eventsRoot: URL { root.appendingPathComponent("Events", isDirectory: true) }

    /// Pre-events layout, still read (never written) so old work stays reachable.
    var legacySessionsRoot: URL { root.appendingPathComponent("Sessions", isDirectory: true) }

    func configure(rootOverride: String) {
        guard rootOverride != self.rootOverride else { return }
        self.rootOverride = rootOverride
        ensureTree()
        reload()
    }

    func ensureTree() {
        try? FileManager.default.createDirectory(at: eventsRoot, withIntermediateDirectories: true)
        refreshFreeSpace()
    }

    func eventDirectory(_ eventID: String) -> URL {
        eventsRoot.appendingPathComponent(eventID, isDirectory: true)
    }

    func sessionsDirectory(for eventID: String) -> URL {
        eventID == EventRecord.unfiledID
            ? legacySessionsRoot
            : eventDirectory(eventID).appendingPathComponent("Sessions", isDirectory: true)
    }

    func directory(for rec: SessionRecord) -> URL {
        sessionsDirectory(for: rec.eventID).appendingPathComponent(rec.id, isDirectory: true)
    }

    /// Looks a session's folder up by id when only the id is to hand.
    func directory(for id: String) -> URL {
        if let rec = sessions.first(where: { $0.id == id }) { return directory(for: rec) }
        return legacySessionsRoot.appendingPathComponent(id, isDirectory: true)
    }

    // MARK: - Events

    func event(_ id: String) -> EventRecord? {
        if id == EventRecord.unfiledID { return EventRecord.unfiled }
        return events.first { $0.id == id }
    }

    func sessions(inEvent id: String) -> [SessionRecord] {
        sessions.filter { $0.eventID == id }
    }

    @discardableResult
    func createEvent(name: String, client: String, venue: String, date: Date, notes: String) throws -> EventRecord {
        ensureTree()
        var id = EventRecord.makeSlug(name: name, date: date)
        var suffix = 2
        while FileManager.default.fileExists(atPath: eventDirectory(id).path) {
            id = "\(EventRecord.makeSlug(name: name, date: date))-\(suffix)"
            suffix += 1
        }
        let dir = eventDirectory(id)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sessions"),
                                                withIntermediateDirectories: true)
        let rec = EventRecord(id: id, name: name, client: client, venue: venue,
                              date: date, notes: notes, createdAt: Date())
        persist(event: rec)
        Log.shared.info("Event created: \(id) — \(name)")
        return rec
    }

    func persist(event rec: EventRecord) {
        guard !rec.isUnfiled else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(rec) else { return }
        try? FileManager.default.createDirectory(at: eventDirectory(rec.id), withIntermediateDirectories: true)
        try? data.write(to: eventDirectory(rec.id).appendingPathComponent("event.json"), options: .atomic)

        if let i = events.firstIndex(where: { $0.id == rec.id }) {
            events[i] = rec
        } else {
            events.insert(rec, at: 0)
            events.sort { $0.date > $1.date }
        }
    }

    func deleteEvent(_ rec: EventRecord) {
        guard !rec.isUnfiled else { return }
        do {
            try FileManager.default.trashItem(at: eventDirectory(rec.id), resultingItemURL: nil)
            events.removeAll { $0.id == rec.id }
            sessions.removeAll { $0.eventID == rec.id }
            Log.shared.warn("Event \(rec.id) and its sessions moved to Trash")
        } catch {
            Log.shared.error("Delete failed for event \(rec.id): \(error.localizedDescription)")
        }
    }

    /// Files an existing session under a different event, moving its folder.
    func move(_ rec: SessionRecord, toEvent eventID: String) {
        guard rec.eventID != eventID, eventID != EventRecord.unfiledID else { return }
        let from = directory(for: rec)
        let destParent = sessionsDirectory(for: eventID)
        try? FileManager.default.createDirectory(at: destParent, withIntermediateDirectories: true)

        var moved = rec
        moved.eventID = eventID
        var targetID = rec.id
        var suffix = 2
        while FileManager.default.fileExists(atPath: destParent.appendingPathComponent(targetID).path) {
            targetID = "\(rec.id)-\(suffix)"
            suffix += 1
        }
        moved.id = targetID
        let to = destParent.appendingPathComponent(targetID, isDirectory: true)

        do {
            try FileManager.default.moveItem(at: from, to: to)
        } catch {
            Log.shared.error("Could not move \(rec.id) to \(eventID): \(error.localizedDescription)")
            return
        }
        sessions.removeAll { $0.id == rec.id && $0.eventID == rec.eventID }
        persist(moved)
        Log.shared.info("Session \(rec.id) filed under event \(eventID)")
    }

    // MARK: - Preflight

    func refreshFreeSpace() {
        let vals = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let bytes = vals?.volumeAvailableCapacityForImportantUsage {
            freeSpaceMB = Int(bytes / 1_048_576)
        }
    }

    /// Throws before a session starts rather than midway through it.
    func preflight(eventID: String = EventRecord.unfiledID) throws {
        ensureTree()
        let dir = sessionsDirectory(for: eventID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: dir.path) else {
            throw StorageError.notWritable(dir.path)
        }
        refreshFreeSpace()
        if freeSpaceMB > 0 && freeSpaceMB < 300 {
            throw StorageError.lowDiskSpace(freeMB: freeSpaceMB)
        }
    }

    // MARK: - Session lifecycle

    /// Unique even if two sessions start inside the same second.
    func createSession(eventID: String, layout: PrintLayout, copies: Int) throws -> SessionRecord {
        try preflight(eventID: eventID)
        let parent = sessionsDirectory(for: eventID)
        let now = Date()
        var id = now.sessionFolderName
        var suffix = 2
        while FileManager.default.fileExists(atPath: parent.appendingPathComponent(id).path) {
            id = "\(now.sessionFolderName)-\(suffix)"
            suffix += 1
        }
        try FileManager.default.createDirectory(at: parent.appendingPathComponent(id),
                                                withIntermediateDirectories: true)
        // The public token is assigned here, not at upload time: the QR code is
        // built when the session finishes, which may be days before anything
        // reaches the internet.
        var rec = SessionRecord(id: id, eventID: eventID, startedAt: now, layout: layout, copies: copies)
        rec.publicToken = PagesPublisher.makeToken()
        persist(rec)
        Log.shared.info("Session \(id) started in event \(eventID) — \(layout.title), \(layout.photoCount) shots")
        return rec
    }

    /// Writes the JPEG immediately; nothing else in the workflow runs until this returns.
    func savePhoto(jpeg: Data, index: Int, in session: SessionRecord,
                   named: String? = nil) throws -> Photo {
        let name = named ?? String(format: "photo-%02d.jpg", index)
        let dest = directory(for: session).appendingPathComponent(name)
        do {
            try jpeg.write(to: dest, options: .atomic)
        } catch {
            Log.shared.error("Save failed for \(session.id)/\(name): \(error.localizedDescription)")
            throw StorageError.writeFailed(error.localizedDescription)
        }
        var w = 0, h = 0
        if let img = NSImage(data: jpeg), let rep = img.representations.first {
            w = rep.pixelsWide; h = rep.pixelsHigh
        }
        Log.shared.info("Saved \(session.id)/\(name) (\(jpeg.count / 1024) KB, \(w)×\(h))")
        return Photo(index: index, fileName: name, capturedAt: Date(), width: w, height: h)
    }

    /// Keeps the colour frame beside a photograph that was saved in black and
    /// white.
    ///
    /// The same reasoning as a retake: the booth converting a frame is not a
    /// reason to destroy the only copy of it. Nothing reads these — every
    /// output, page and upload works from the session's own list of
    /// photographs — so they simply sit in the folder for the operator who is
    /// asked for them the next day.
    func archiveColour(jpeg: Data, named photo: String, in session: SessionRecord) {
        let name = (photo as NSString).deletingPathExtension + ".colour.jpg"
        let dest = directory(for: session).appendingPathComponent(name)
        do {
            try jpeg.write(to: dest, options: .atomic)
        } catch {
            Log.shared.warn("Could not keep the colour frame \(session.id)/\(name): \(error.localizedDescription)")
        }
    }

    /// The photograph as it was saved, before any brightening.
    ///
    /// Written once, the first time a session is adjusted, and read every time
    /// after: every adjustment is made from the original rather than on top of
    /// the last one, so dragging a slider up and back down lands exactly where
    /// it started instead of somewhere paler.
    func asShotURL(for photo: Photo, in session: SessionRecord) -> URL {
        let dir = directory(for: session)
        let stem = (photo.fileName as NSString).deletingPathExtension
        let base = stem.range(of: "-ev[0-9]+$", options: .regularExpression)
            .map { String(stem[stem.startIndex..<$0.lowerBound]) } ?? stem
        return dir.appendingPathComponent(base + ".asshot.jpg")
    }

    /// Replaces the photo at `index` with a fresh capture.
    ///
    /// **Under a new name.** The obvious thing is to write over the old file,
    /// and it is what this used to do — but the photographs are delivered from a
    /// CDN keyed by file name, and a name that has already been published is a
    /// name that already has a picture behind it. Whether the second upload
    /// replaces the first depends on settings in somebody's Cloudinary account,
    /// and when it does not, the guests' page keeps showing the frame they asked
    /// to do again. A name that has never been published cannot have that
    /// problem.
    ///
    /// The superseded frame is kept, renamed out of the way — a guest asking for
    /// a retake is not a reason to destroy a photograph the client might still
    /// want.
    func replacePhoto(jpeg: Data, index: Int, in session: SessionRecord) throws -> Photo {
        let dir = directory(for: session)
        if let existing = session.photos.first(where: { $0.index == index }) {
            let url = existing.url(in: dir)
            if FileManager.default.fileExists(atPath: url.path) {
                let stamp = Int(Date().timeIntervalSince1970)
                let archived = dir.appendingPathComponent(
                    "\(url.deletingPathExtension().lastPathComponent).retake-\(stamp).jpg")
                try? FileManager.default.moveItem(at: url, to: archived)
                Log.shared.info("Retake — \(existing.fileName) kept as \(archived.lastPathComponent)")
            }
        }
        return try savePhoto(jpeg: jpeg, index: index, in: session,
                             named: Self.retakeName(index: index, in: dir))
    }

    /// The frame's own name with any adjustment suffix taken off — what it is
    /// called when the exposure is put back to as-shot.
    static func originalName(for photo: Photo) -> String {
        let stem = (photo.fileName as NSString).deletingPathExtension
        let base = stem.range(of: "-ev[0-9]+$", options: .regularExpression)
            .map { String(stem[stem.startIndex..<$0.lowerBound]) } ?? stem
        return base + ".jpg"
    }

    /// Keeps the name while nothing has been published under it, and takes the
    /// next one along once something has.
    ///
    /// Normal sessions — the overwhelming majority, shot once and never
    /// touched — therefore keep a folder with one `print.jpg` in it. Only a
    /// session whose sheet is rebuilt *after* it went up collects a second.
    static func freshName(for current: String?, stem: String, ext: String,
                          published: Bool, in dir: URL) -> String {
        let first = "\(stem).\(ext)"
        guard published, current != nil else { return current ?? first }
        var n = 2
        while n < 60 {
            let name = "\(stem)-\(n).\(ext)"
            if !FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
                return name
            }
            n += 1
        }
        return "\(stem)-\(Int(Date().timeIntervalSince1970)).\(ext)"
    }

    /// The name an adjusted frame is written under.
    ///
    /// For the same reason a retake gets one: the photographs are delivered
    /// from a CDN keyed by file name, and a name that has already been
    /// published may go on serving the picture it was first given. An exposure
    /// the operator can see on the print but not on the guests' page would be
    /// worse than no exposure control at all.
    ///
    /// The as-shot original keeps its own name throughout, so the chain never
    /// grows: every adjustment is `name-ev<n>` derived from the same source.
    static func adjustedName(for photo: Photo, step: Int) -> String {
        let stem = (photo.fileName as NSString).deletingPathExtension
        let base = stem.range(of: "-ev[0-9]+$", options: .regularExpression)
            .map { String(stem[stem.startIndex..<$0.lowerBound]) } ?? stem
        return "\(base)-ev\(step).jpg"
    }

    /// `photo-01-take2.jpg`, then `-take3`, and so on: the first name that is
    /// not already taken in the folder, so every take has one of its own.
    static func retakeName(index: Int, in dir: URL) -> String {
        var take = 2
        while take < 40 {
            let name = String(format: "photo-%02d-take%d.jpg", index, take)
            if !FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
                return name
            }
            take += 1
        }
        return String(format: "photo-%02d-take%d.jpg", index, Int(Date().timeIntervalSince1970))
    }

    /// Saves the composed sheet, under a new name if the old one has been
    /// published.
    ///
    /// A retake rebuilds the sheet, and the rebuilt sheet used to be written
    /// over `print.jpg` — the same name it was published under. The
    /// photographs are delivered from a CDN keyed by that name, and a name
    /// that already has a picture behind it keeps the picture it already has:
    /// the guests' page went on showing the sheet made from the shot they
    /// asked to do again. A name that has never been published cannot.
    func savePrint(_ jpeg: Data, in session: SessionRecord) throws -> String {
        let dir = directory(for: session)
        let name = Self.freshName(for: session.printFileName, stem: "print", ext: "jpg",
                                  published: session.uploadState == .uploaded, in: dir)
        let dest = dir.appendingPathComponent(name)
        do {
            try jpeg.write(to: dest, options: .atomic)
        } catch {
            throw StorageError.writeFailed(error.localizedDescription)
        }
        Log.shared.info("Saved \(session.id)/print.jpg (\(jpeg.count / 1024) KB)")
        return name
    }

    /// The loop, under the same rule as the sheet: a rebuild after publishing
    /// needs a name of its own.
    func saveGIF(_ gif: Data, in session: SessionRecord) throws -> String {
        let dir = directory(for: session)
        let stem = (GIFRenderer.fileName as NSString).deletingPathExtension
        let name = Self.freshName(for: session.gifFileName, stem: stem, ext: "gif",
                                  published: session.uploadState == .uploaded, in: dir)
        let dest = dir.appendingPathComponent(name)
        do {
            try gif.write(to: dest, options: .atomic)
        } catch {
            throw StorageError.writeFailed(error.localizedDescription)
        }
        Log.shared.info("Saved \(session.id)/\(name) (\(gif.count / 1024) KB)")
        return name
    }

    private func writeMetadata(_ rec: SessionRecord) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(rec) else { return }
        try? data.write(to: directory(for: rec).appendingPathComponent("session.json"), options: .atomic)
    }

    func persist(_ rec: SessionRecord) {
        writeMetadata(rec)

        if let i = sessions.firstIndex(where: { $0.id == rec.id && $0.eventID == rec.eventID }) {
            sessions[i] = rec
        } else {
            sessions.insert(rec, at: 0)
        }
    }

    // MARK: - Gallery

    func reload() {
        ensureTree()
        let fm = FileManager.default
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601

        // Events
        var foundEvents: [EventRecord] = []
        if let dirs = try? fm.contentsOfDirectory(at: eventsRoot,
                                                  includingPropertiesForKeys: [.isDirectoryKey],
                                                  options: [.skipsHiddenFiles]) {
            for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let meta = dir.appendingPathComponent("event.json")
                if let data = try? Data(contentsOf: meta),
                   let rec = try? dec.decode(EventRecord.self, from: data) {
                    foundEvents.append(rec)
                } else {
                    // Folder exists with no metadata — keep it visible rather than hiding photos.
                    let id = dir.lastPathComponent
                    foundEvents.append(EventRecord(id: id, name: id, createdAt: Date()))
                    Log.shared.warn("Event \(id) had no event.json; listed with its folder name")
                }
            }
        }
        events = foundEvents.sorted { $0.date > $1.date }

        // Sessions, per event plus the pre-events folder
        var found: [SessionRecord] = []
        for eventID in foundEvents.map(\.id) + [EventRecord.unfiledID] {
            found += loadSessions(in: sessionsDirectory(for: eventID), eventID: eventID, decoder: dec)
        }
        sessions = found.sorted { $0.startedAt > $1.startedAt }
    }

    private func loadSessions(in parent: URL, eventID: String, decoder dec: JSONDecoder) -> [SessionRecord] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: parent,
                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        var out: [SessionRecord] = []
        for dir in items where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let meta = dir.appendingPathComponent("session.json")
            if let data = try? Data(contentsOf: meta),
               var rec = try? dec.decode(SessionRecord.self, from: data) {
                // Trust the folder it was found in over a stale field in the file.
                if rec.eventID != eventID {
                    rec.eventID = eventID
                    writeMetadata(rec)
                }
                out.append(rec)
            } else if var rebuilt = rebuildRecord(from: dir) {
                rebuilt.eventID = eventID
                out.append(rebuilt)
                writeMetadata(rebuilt)   // so it is never rebuilt again
            }
        }
        return out
    }

    /// Recovers a session whose metadata was lost (e.g. a crash mid-session) from the files on disk.
    private func rebuildRecord(from dir: URL) -> SessionRecord? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        // Only the photographs themselves. The folder may also hold the frame a
        // retake superseded and the colour original of one shot in black and
        // white; both are kept deliberately, and neither is a photograph this
        // session took.
        let photoFiles = files.filter {
            $0.hasPrefix("photo-") && $0.hasSuffix(".jpg")
                && !$0.contains(".retake-") && !$0.contains(".colour.")
                && !$0.contains(".asshot.")
        }.sorted()
        guard !photoFiles.isEmpty else { return nil }

        let id = dir.lastPathComponent
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let started = f.date(from: String(id.prefix(19))) ?? Date()

        var photos: [Photo] = []
        for (i, name) in photoFiles.enumerated() {
            let attrs = try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
            photos.append(Photo(index: i + 1,
                                fileName: name,
                                capturedAt: (attrs?[.creationDate] as? Date) ?? started,
                                width: 0, height: 0))
        }
        let hasPrint = files.contains("print.jpg")
        let hasGIF = files.contains(GIFRenderer.fileName)
        var rec = SessionRecord(id: id, eventID: EventRecord.unfiledID,
                                startedAt: started, layout: .duplicateStrips)
        rec.photos = photos
        rec.printFileName = hasPrint ? "print.jpg" : nil
        rec.gifFileName = hasGIF ? GIFRenderer.fileName : nil
        rec.finishedAt = photos.last?.capturedAt
        Log.shared.warn("Recovered session \(id) from disk (\(photos.count) photos, metadata was missing)")
        return rec
    }

    func delete(_ rec: SessionRecord) {
        do {
            try FileManager.default.trashItem(at: directory(for: rec), resultingItemURL: nil)
            sessions.removeAll { $0.id == rec.id && $0.eventID == rec.eventID }
            Log.shared.warn("Session \(rec.id) moved to Trash")
        } catch {
            Log.shared.error("Delete failed for \(rec.id): \(error.localizedDescription)")
        }
    }

    func revealInFinder(_ rec: SessionRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([directory(for: rec)])
    }

    func thumbnail(for rec: SessionRecord) -> NSImage? {
        let dir = directory(for: rec)
        if let p = rec.printFileName {
            if let img = NSImage(contentsOf: dir.appendingPathComponent(p)) { return img }
        }
        if let first = rec.photos.first {
            return NSImage(contentsOf: dir.appendingPathComponent(first.fileName))
        }
        return nil
    }
}
