import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Publishes finished sessions to a GitHub Pages site.
///
/// GitHub Pages serves static files and nothing else — there is no endpoint to
/// POST to, no database and no server-side zip. So the "site" is a git
/// repository: this writes web-sized photographs and a plain HTML page for each
/// session into a local clone, commits, and pushes. GitHub then serves it.
///
/// Two consequences shape everything here:
///
/// * **Everything published is public.** A free GitHub account cannot serve
///   Pages from a private repository, so both the site and the repository are
///   world-readable. Session addresses therefore use an unguessable token and
///   every page carries a noindex header, but that is obscurity, not privacy.
/// * **Repositories are not photo archives.** Originals stay on the Mac; only a
///   resized web copy is published, and git history keeps whatever is committed
///   forever. The size readout in Admin exists for exactly that reason.
enum PagesError: LocalizedError {
    case noRepo
    case notARepo(String)
    case gitMissing
    case gitFailed(String, String)
    case noRemote
    case resizeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noRepo:               return "No site folder chosen — Admin › Gallery Site › Choose Folder."
        case .notARepo(let p):      return "\(p) is not a git repository. Use Set Up Site first."
        case .gitMissing:           return "git is not installed. Run: xcode-select --install"
        case .gitFailed(let c, let m): return "git \(c) failed — \(m)"
        case .noRemote:             return "The site folder has no GitHub remote yet."
        case .resizeFailed(let f):  return "Could not make a web copy of \(f)."
        }
    }
}

struct PagesPublisher {

    let repo: URL
    var branch: String = "main"
    var longEdge: Int = 1600
    var siteTitle: String = "Photobooth"
    /// Optional "follow us" line in the page footer — the same address the booth
    /// puts on its QR card, so the page carries it home too.
    var brandLink: String?
    var brandLabel: String = ""

    private static let gitPath = "/usr/bin/git"

    // MARK: - Addresses

    /// Ten characters from an alphabet with no look-alikes, so a token can be
    /// read off a screen and typed by hand if a phone camera refuses the code.
    static func makeToken() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<10).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }

    /// `/s/<token>/` — one directory per session, so the address needs no query
    /// string and works on plain static hosting.
    static func sessionPath(token: String) -> String { "s/\(token)" }
    static func eventPath(token: String) -> String { "e/\(token)" }

    // MARK: - Repository

    static func isRepo(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let git = url.appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: git.path, isDirectory: &isDir)
    }

    /// Creates the site from nothing: a git repository, the landing page, and the
    /// files GitHub Pages needs. Safe to run on an existing folder — it only adds
    /// what is missing, and never touches published sessions.
    static func setUp(at url: URL, remote: String, branch: String,
                      siteTitle: String, authorName: String, authorEmail: String) throws {
        guard FileManager.default.fileExists(atPath: gitPath) else { throw PagesError.gitMissing }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        if !isRepo(url) {
            try git(["init", "-b", branch], in: url)
        }
        _ = try? git(["config", "user.name", authorName], in: url)
        _ = try? git(["config", "user.email", authorEmail], in: url)

        // Jekyll would otherwise ignore any directory beginning with an
        // underscore and rewrite the pages it does process.
        let nojekyll = url.appendingPathComponent(".nojekyll")
        if !FileManager.default.fileExists(atPath: nojekyll.path) {
            try Data().write(to: nojekyll)
        }
        // Keeps the albums out of search results. Not a lock — the site is public.
        let robots = url.appendingPathComponent("robots.txt")
        if !FileManager.default.fileExists(atPath: robots.path) {
            try "User-agent: *\nDisallow: /\n".data(using: .utf8)!.write(to: robots)
        }
        let index = url.appendingPathComponent("index.html")
        if !FileManager.default.fileExists(atPath: index.path) {
            try PagesTemplate.landing(siteTitle: siteTitle).data(using: .utf8)!.write(to: index)
        }
        let readme = url.appendingPathComponent("README.md")
        if !FileManager.default.fileExists(atPath: readme.path) {
            try PagesTemplate.readme(siteTitle: siteTitle).data(using: .utf8)!.write(to: readme)
        }

        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if (try? git(["remote", "get-url", "origin"], in: url)) != nil {
                try git(["remote", "set-url", "origin", trimmed], in: url)
            } else {
                try git(["remote", "add", "origin", trimmed], in: url)
            }
        }
        _ = try? git(["add", "-A"], in: url)
        // Nothing to commit is a perfectly good outcome on a re-run.
        _ = try? git(["commit", "-m", "Set up photobooth gallery"], in: url)
    }

    func remoteURL() -> String? {
        guard let out = try? Self.git(["remote", "get-url", "origin"], in: repo) else { return nil }
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Whether GitHub can be reached with the credentials already on this Mac.
    /// Deliberately read-only: it proves the push will work without writing.
    func canReachRemote() throws -> Bool {
        guard remoteURL() != nil else { throw PagesError.noRemote }
        // No --exit-code: a brand new GitHub repository has no refs yet, and
        // "reachable but empty" is exactly the state the first push starts from.
        _ = try Self.git(["ls-remote", "origin"], in: repo, timeout: 45)
        return true
    }

    /// Published size, so the operator sees the repository growing before GitHub
    /// complains about it. Counts the working tree, not git's history.
    func siteSize() -> (files: Int, bytes: Int64) {
        var files = 0
        var bytes: Int64 = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: repo, includingPropertiesForKeys: keys) else {
            return (0, 0)
        }
        for case let url as URL in e {
            if url.pathComponents.contains(".git") { continue }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            files += 1
            bytes += Int64(v.fileSize ?? 0)
        }
        return (files, bytes)
    }

    // MARK: - Publishing

    struct Published {
        let sessionPath: String
        let eventPath: String
        let photoCount: Int
        let bytes: Int64
    }

    /// Writes one session into the site. Does not push — the caller decides when
    /// to spend the network, so a venue with no wifi still builds the pages.
    @discardableResult
    func write(session rec: SessionRecord,
               event: EventRecord,
               token: String,
               eventToken: String,
               from dir: URL,
               siblings: [SessionRecord],
               includeOriginals: Bool,
               includePrint: Bool,
               includeGIF: Bool) throws -> Published {
        guard Self.isRepo(repo) else { throw PagesError.notARepo(repo.path) }

        let sessionDir = repo.appendingPathComponent(Self.sessionPath(token: token), isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        var names: [String] = []
        var bytes: Int64 = 0

        if includeOriginals {
            for photo in rec.photos.sorted(by: { $0.index < $1.index }) {
                let src = dir.appendingPathComponent(photo.fileName)
                guard FileManager.default.fileExists(atPath: src.path) else { continue }
                let dest = sessionDir.appendingPathComponent(photo.fileName)
                try Self.webCopy(from: src, to: dest, longEdge: longEdge)
                names.append(photo.fileName)
                bytes += Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }

        var printName: String?
        if includePrint, let p = rec.printFileName {
            let src = dir.appendingPathComponent(p)
            if FileManager.default.fileExists(atPath: src.path) {
                let dest = sessionDir.appendingPathComponent("print.jpg")
                try Self.webCopy(from: src, to: dest, longEdge: max(longEdge, 1800))
                printName = "print.jpg"
                bytes += Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }

        // Copied, not re-encoded: `webCopy` makes JPEGs, and the GIF was already
        // built at its delivery size.
        var gifName: String?
        if GIFRenderer.enabled, includeGIF, let g = rec.gifFileName {
            let src = dir.appendingPathComponent(g)
            if FileManager.default.fileExists(atPath: src.path) {
                let dest = sessionDir.appendingPathComponent(GIFRenderer.fileName)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: src, to: dest)
                gifName = GIFRenderer.fileName
                bytes += Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }

        try writeSessionPage(session: rec, event: event, token: token, eventToken: eventToken,
                             photos: names.map { PagesTemplate.PhotoRef(src: $0) },
                             print: printName.map { PagesTemplate.PhotoRef(src: $0) },
                             gif: gifName.map { PagesTemplate.PhotoRef(src: $0) })

        let entries: [PagesTemplate.AlbumEntry] = siblings
            .filter { !$0.publicToken.isEmpty }
            .sorted { $0.startedAt < $1.startedAt }
            .map { s in
                PagesTemplate.AlbumEntry(
                    href: "../../\(Self.sessionPath(token: s.publicToken))/",
                    cover: coverName(for: s),
                    stamp: s.startedAt,
                    count: s.photos.count)
            }
        try writeAlbumPage(event: event, eventToken: eventToken, entries: entries)

        return Published(sessionPath: Self.sessionPath(token: token),
                         eventPath: Self.eventPath(token: eventToken),
                         photoCount: names.count,
                         bytes: bytes)
    }

    /// Puts an empty page at the session's address before the photographs exist,
    /// so the code printed on the strip is live by the time the strip is.
    func writeHoldingPage(session rec: SessionRecord, event: EventRecord, token: String) throws {
        guard Self.isRepo(repo) else { throw PagesError.notARepo(repo.path) }
        let dir = repo.appendingPathComponent(Self.sessionPath(token: token), isDirectory: true)
        // Never over a page that already has photographs on it: a retake
        // republishes, and a holding page landing on top of a finished one would
        // take a guest's pictures away again.
        let index = dir.appendingPathComponent("index.html")
        if let existing = try? String(contentsOf: index, encoding: .utf8),
           !existing.contains("Nearly<br>there") {
            return
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let page = PagesTemplate.holdingPage(siteTitle: siteTitle,
                                             eventName: event.name,
                                             startedAt: rec.startedAt,
                                             brandLink: brandLink,
                                             brandLabel: brandLabel)
        try page.data(using: .utf8)!.write(to: index)
    }

    /// Writes one session's page. Split out so the Cloudinary hybrid can put the
    /// page here while the photographs live on a CDN — the page is only ever a
    /// few kilobytes, which is what keeps the repository small.
    func writeSessionPage(session rec: SessionRecord,
                          event: EventRecord,
                          token: String,
                          eventToken: String,
                          photos: [PagesTemplate.PhotoRef],
                          print printRef: PagesTemplate.PhotoRef?,
                          gif gifRef: PagesTemplate.PhotoRef? = nil) throws {
        guard Self.isRepo(repo) else { throw PagesError.notARepo(repo.path) }
        let dir = repo.appendingPathComponent(Self.sessionPath(token: token), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let page = PagesTemplate.sessionPage(siteTitle: siteTitle,
                                             event: event,
                                             session: rec,
                                             photos: photos,
                                             print: printRef,
                                             gif: gifRef,
                                             albumHref: "../../\(Self.eventPath(token: eventToken))/",
                                             brandLink: brandLink,
                                             brandLabel: brandLabel)
        try page.data(using: .utf8)!.write(to: dir.appendingPathComponent("index.html"))
    }

    /// Rewritten from scratch every time, so the album always matches what has
    /// actually been published — including sessions from an older build.
    func writeAlbumPage(event: EventRecord,
                        eventToken: String,
                        entries: [PagesTemplate.AlbumEntry]) throws {
        guard Self.isRepo(repo) else { throw PagesError.notARepo(repo.path) }
        let dir = repo.appendingPathComponent(Self.eventPath(token: eventToken), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let album = PagesTemplate.albumPage(siteTitle: siteTitle, event: event, entries: entries,
                                            brandLink: brandLink, brandLabel: brandLabel)
        try album.data(using: .utf8)!.write(to: dir.appendingPathComponent("index.html"))
    }

    private func coverName(for s: SessionRecord) -> String {
        let base = "../../\(Self.sessionPath(token: s.publicToken))/"
        if s.printFileName != nil { return base + "print.jpg" }
        if let first = s.photos.sorted(by: { $0.index < $1.index }).first { return base + first.fileName }
        return ""
    }

    /// Commits everything written so far and pushes it. One commit per session
    /// keeps the history readable when something has to be traced back.
    /// One git at a time, whatever is asking.
    ///
    /// Two pushes now overlap by design — the holding page as a session starts,
    /// the real one as it finishes — and git in one repository from two threads
    /// is how index.lock errors and half-made commits happen.
    private static let gitLock = NSLock()

    func commitAndPush(message: String) throws {
        guard Self.isRepo(repo) else { throw PagesError.notARepo(repo.path) }
        Self.gitLock.lock()
        defer { Self.gitLock.unlock() }
        try Self.git(["add", "-A"], in: repo)
        // An empty commit means the session was already published — not an error.
        _ = try? Self.git(["commit", "-m", message], in: repo)
        guard remoteURL() != nil else { throw PagesError.noRemote }
        try Self.git(["push", "-u", "origin", branch], in: repo, timeout: 600)
    }

    // MARK: - Images

    /// A web copy: long edge capped, EXIF orientation applied, metadata dropped.
    ///
    /// Uses ImageIO's thumbnail path rather than decoding the full frame, so a
    /// 20 MP original never lands in memory whole.
    static func webCopy(from src: URL, to dest: URL, longEdge: Int, quality: CGFloat = 0.82) throws {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil) else {
            throw PagesError.resizeFailed(src.lastPathComponent)
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
            throw PagesError.resizeFailed(src.lastPathComponent)
        }
        guard let out = CGImageDestinationCreateWithURL(dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PagesError.resizeFailed(dest.lastPathComponent)
        }
        CGImageDestinationAddImage(out, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(out) else { throw PagesError.resizeFailed(dest.lastPathComponent) }
    }

    // MARK: - git

    @discardableResult
    static func git(_ args: [String], in dir: URL, timeout: TimeInterval = 60) throws -> String {
        guard FileManager.default.fileExists(atPath: gitPath) else { throw PagesError.gitMissing }
        // Never let git stop for a password prompt: with no credentials on the
        // Mac it must fail with a message the operator can act on, not hang the
        // upload queue behind an invisible dialog.
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = "/usr/bin/true"
        let r = Shell.run(gitPath, ["-C", dir.path] + args, timeout: timeout, environment: env)
        guard r.status == 0 else {
            let msg = (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines)
            throw PagesError.gitFailed(args.first ?? "?", msg.isEmpty ? "exit \(r.status)" : msg)
        }
        return r.out
    }
}
