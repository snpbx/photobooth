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
    func savePhoto(jpeg: Data, index: Int, in session: SessionRecord) throws -> Photo {
        let name = String(format: "photo-%02d.jpg", index)
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
    func archiveColour(jpeg: Data, index: Int, in session: SessionRecord) {
        let name = String(format: "photo-%02d.colour.jpg", index)
        let dest = directory(for: session).appendingPathComponent(name)
        do {
            try jpeg.write(to: dest, options: .atomic)
        } catch {
            Log.shared.warn("Could not keep the colour frame \(session.id)/\(name): \(error.localizedDescription)")
        }
    }

    /// Replaces the photo at `index` with a fresh capture.
    ///
    /// The superseded frame is renamed rather than deleted — a guest asking for a
    /// retake is not a reason to destroy a photograph the client might still want,
    /// and the operator can always fish it back out of the session folder.
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
        return try savePhoto(jpeg: jpeg, index: index, in: session)
    }

    func savePrint(_ jpeg: Data, in session: SessionRecord) throws -> String {
        let name = "print.jpg"
        let dest = directory(for: session).appendingPathComponent(name)
        do {
            try jpeg.write(to: dest, options: .atomic)
        } catch {
            throw StorageError.writeFailed(error.localizedDescription)
        }
        Log.shared.info("Saved \(session.id)/print.jpg (\(jpeg.count / 1024) KB)")
        return name
    }

    func saveGIF(_ gif: Data, in session: SessionRecord) throws -> String {
        let name = GIFRenderer.fileName
        let dest = directory(for: session).appendingPathComponent(name)
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
