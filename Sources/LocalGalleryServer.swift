import Foundation
import Network

/// Hands guests their photographs over the venue's own wifi, with no internet
/// anywhere in the picture.
///
/// A booth is very often somewhere with a network and no usable connection —
/// a marquee, a basement, a hotel ballroom whose wifi is three bars of nothing.
/// The photographs are already on this Mac the moment the shutter closes, so the
/// only thing between a guest and their pictures is a web server, and that is
/// four hundred lines. The code on the finish screen points here; the code
/// printed on the strip keeps pointing at the permanent address, because this
/// one dies the moment the booth is packed away.
///
/// Deliberately not actor-isolated: a phone's request has to be answered from
/// the network queue while the main actor is busy drawing a countdown, so the
/// little state it has sits behind a lock instead.
final class LocalGalleryServer: @unchecked Sendable {

    /// What the server needs to answer one request. A snapshot rather than a
    /// reference to the booth: the main actor owns the session records, and the
    /// network queue must never reach into them.
    struct Session {
        let token: String
        let eventName: String
        let startedAt: Date
        let directory: URL
        let photoFiles: [String]
        let printFile: String?
        let gifFile: String?
        let videoFile: String?
    }

    static let shared = LocalGalleryServer()

    private let lock = NSLock()
    private var listener: NWListener?
    private var _port: UInt16 = 0
    private var _sessions: [String: Session] = [:]
    private var _siteTitle = "Photobooth"
    private var _brandLink: String?
    private var _brandLabel = ""

    var port: UInt16 { lock.lock(); defer { lock.unlock() }; return _port }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return listener != nil }

    // MARK: - Lifecycle

    /// Starts listening on every interface, so a phone on the same wifi can
    /// reach it. Loopback would serve the operator and nobody else.
    ///
    /// The port is asked for rather than chosen: a guest may end up typing this
    /// address off the screen, and `:8080` is short enough to type where a
    /// random high port is not.
    @discardableResult
    func start(port wanted: UInt16) throws -> UInt16 {
        if let listener, listener.state == .ready, port == wanted { return port }
        stop()

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let endpointPort = NWEndpoint.Port(rawValue: wanted) else {
            throw LocalServerError.badPort
        }
        let l = try NWListener(using: params, on: endpointPort)
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?

        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global(qos: .userInitiated))
            self?.receive(on: conn)
        }
        l.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let e), .waiting(let e):
                // `waiting` is what a port already in use looks like, and it
                // never resolves on its own — treat it as the failure it is.
                failure = e
                ready.signal()
            default: break
            }
        }
        l.start(queue: .global(qos: .userInitiated))
        lock.lock(); listener = l; lock.unlock()

        guard ready.wait(timeout: .now() + 3) == .success, failure == nil else {
            stop()
            throw LocalServerError.inUse(wanted, failure?.localizedDescription ?? "timed out")
        }
        lock.lock(); _port = wanted; lock.unlock()
        Log.shared.info("Local gallery serving on port \(wanted)")
        return wanted
    }

    func stop() {
        lock.lock()
        let was = listener != nil
        listener?.cancel()
        listener = nil
        _port = 0
        lock.unlock()
        if was { Log.shared.info("Local gallery stopped") }
    }

    /// Replaces what the server knows about. Called whenever a session finishes
    /// and once at launch, so a booth restarted mid-event still answers for
    /// every code already in somebody's pocket.
    func publish(sessions: [Session], siteTitle: String, brandLink: String?, brandLabel: String) {
        lock.lock()
        _sessions = Dictionary(uniqueKeysWithValues: sessions.map { ($0.token, $0) })
        _siteTitle = siteTitle
        _brandLink = brandLink
        _brandLabel = brandLabel
        lock.unlock()
    }

    // MARK: - Addresses

    /// This Mac's address on the local network, or nil when it is on no network
    /// at all.
    ///
    /// Wired first, then wifi, then anything else: a booth plugged into a
    /// router by cable while also on a phone's hotspot would otherwise publish
    /// the address guests cannot reach. Link-local (169.254) is skipped — it
    /// means the network never came up.
    static func localAddress() -> String? {
        var best: (rank: Int, address: String)?
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let text = String(cString: host)
            guard !text.hasPrefix("169.254"), !text.isEmpty else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            let rank: Int
            switch true {
            case name.hasPrefix("en0"):    rank = 0        // usually the cable, or wifi on a laptop
            case name.hasPrefix("en"):     rank = 1
            case name.hasPrefix("bridge"): rank = 2        // the Mac's own hotspot
            default:                       rank = 3
            }
            if best == nil || rank < best!.rank { best = (rank, text) }
        }
        return best?.address
    }

    /// The address a guest's phone should be sent to: the operator's own if they
    /// pinned one, otherwise whatever this Mac answers to right now.
    static func host(override: String) -> String? {
        let pinned = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pinned.isEmpty { return pinned }
        return localAddress()
    }

    static func sessionURL(token: String, host: String, port: UInt16) -> URL? {
        URL(string: "http://\(host):\(port)/s/\(token)/")
    }

    // MARK: - Requests

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, _ in
            guard let self, let data, !data.isEmpty else {
                if done { conn.cancel() }
                return
            }
            let head = String(decoding: data.prefix(4096), as: UTF8.self)
            let request = head.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = request.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else {
                self.send(status: "405 Method Not Allowed", body: Data(), type: "text/plain", on: conn)
                return
            }
            // iOS will not play a video from a server that cannot serve part of
            // a file: Safari asks for a range first and gives up on a 200.
            var range: (Int, Int?)?
            for line in head.split(separator: "\r\n").dropFirst()
            where line.lowercased().hasPrefix("range:") {
                let spec = line.split(separator: "=").last.map(String.init) ?? ""
                let ends = spec.split(separator: "-", omittingEmptySubsequences: false)
                if let start = ends.first.flatMap({ Int($0) }) {
                    let end = ends.count > 1 ? Int(ends[1]) : nil
                    range = (start, end)
                }
            }
            self.respond(to: String(parts[1]), headOnly: parts[0] == "HEAD",
                         range: range, on: conn)
        }
    }

    private func respond(to rawPath: String, headOnly: Bool,
                         range: (Int, Int?)? = nil, on conn: NWConnection) {
        let path = (rawPath.split(separator: "?").first.map(String.init) ?? "/")
            .removingPercentEncoding ?? "/"
        let parts = path.split(separator: "/").map(String.init)

        // `/` — nothing to list. Sessions are unguessable on purpose, and a
        // booth that hands a stranger on the venue wifi everyone's photographs
        // is worse than one that hands them nothing.
        guard !parts.isEmpty else {
            sendHTML(PagesTemplate.landing(siteTitle: siteTitle), headOnly: headOnly, on: conn)
            return
        }
        guard parts[0] == "s", parts.count >= 2 else {
            sendNotFound(on: conn)
            return
        }
        let token = parts[1]
        guard token.range(of: "^[A-Za-z0-9_-]{4,64}$", options: .regularExpression) != nil,
              let session = self.session(token) else {
            sendNotFound(on: conn)
            return
        }

        // /s/<token>/ — the page itself.
        if parts.count == 2 {
            sendHTML(page(for: session), headOnly: headOnly, on: conn)
            return
        }

        // /s/<token>/<file> — one photograph, the print, or the GIF. Only files
        // this session actually has: the name is matched against its own list
        // rather than looked up on disk, so no path can be talked into leaving
        // the folder.
        let name = parts[2]
        let allowed = session.photoFiles
            + [session.printFile, session.gifFile, session.videoFile].compactMap { $0 }
        guard parts.count == 3, allowed.contains(name) else {
            sendNotFound(on: conn)
            return
        }
        let file = session.directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            sendNotFound(on: conn)
            return
        }
        let type: String
        if name.hasSuffix(".gif") { type = "image/gif" }
        else if name.hasSuffix(".mp4") { type = "video/mp4" }
        else { type = "image/jpeg" }

        // A range request gets the slice it asked for, and the 206 that goes
        // with it; anything else gets the file and a note that ranges are
        // welcome, which is what makes a phone willing to start a video at all.
        if let (start, wantedEnd) = range, start < data.count {
            let end = min(wantedEnd ?? (data.count - 1), data.count - 1)
            let slice = Data(data[start...end])
            send(status: "206 Partial Content", body: headOnly ? Data() : slice, type: type,
                 length: slice.count,
                 extra: ["Content-Range": "bytes \(start)-\(end)/\(data.count)",
                         "Accept-Ranges": "bytes"],
                 on: conn)
            return
        }
        send(status: "200 OK", body: headOnly ? Data() : Data(data),
             type: type, length: data.count,
             extra: ["Accept-Ranges": "bytes"], on: conn)
    }

    // MARK: - The page

    private func session(_ token: String) -> Session? {
        lock.lock(); defer { lock.unlock() }
        return _sessions[token]
    }

    private var siteTitle: String { lock.lock(); defer { lock.unlock() }; return _siteTitle }

    /// The same page the web gets, with every address pointing back at this Mac.
    ///
    /// `download` on a same-origin link is honoured by every phone browser, so
    /// Save really saves here — no `fl_attachment` equivalent is needed, and the
    /// page's own zip works because nothing it fetches is cross-origin.
    private func page(for s: Session) -> String {
        lock.lock()
        let title = _siteTitle
        let link = _brandLink
        let label = _brandLabel
        lock.unlock()

        let photos = s.photoFiles.map { PagesTemplate.PhotoRef(src: $0) }
        let printRef = s.printFile.map { PagesTemplate.PhotoRef(src: $0) }
        let gifRef = s.gifFile.map { PagesTemplate.PhotoRef(src: $0) }
        let videoRef = s.videoFile.map { PagesTemplate.PhotoRef(src: $0) }

        var event = EventRecord(id: "local", name: s.eventName, createdAt: s.startedAt)
        event.date = s.startedAt
        var rec = SessionRecord(id: s.token, startedAt: s.startedAt, layout: .fourFullPage)
        rec.publicToken = s.token

        return PagesTemplate.sessionPage(siteTitle: title,
                                         event: event,
                                         session: rec,
                                         photos: photos,
                                         print: printRef,
                                         gif: gifRef,
                                         video: videoRef,
                                         // No album over the local link: the
                                         // rest of the night belongs to other
                                         // people, and this address has no way
                                         // of asking who is scanning.
                                         albumHref: "",
                                         brandLink: link,
                                         brandLabel: label)
    }

    // MARK: - Writing

    private func sendHTML(_ html: String, headOnly: Bool, on conn: NWConnection) {
        let body = Data(html.utf8)
        send(status: "200 OK", body: headOnly ? Data() : body,
             type: "text/html; charset=utf-8", length: body.count, on: conn)
    }

    private func sendNotFound(on conn: NWConnection) {
        let body = Data("Not found".utf8)
        send(status: "404 Not Found", body: body, type: "text/plain", length: body.count, on: conn)
    }

    private func send(status: String, body: Data, type: String, length: Int? = nil,
                      extra: [String: String] = [:], on conn: NWConnection) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(length ?? body.count)\r\n"
        for (k, v) in extra.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

enum LocalServerError: LocalizedError {
    case badPort
    case inUse(UInt16, String)

    var errorDescription: String? {
        switch self {
        case .badPort:
            return "That is not a usable port number."
        case .inUse(let p, let why):
            return "Could not serve on port \(p) — \(why). Try another port."
        }
    }
}

/// The wifi network guests have to join, as a code their camera understands.
///
/// Both iOS and Android read this format straight from the camera app and offer
/// to join — which matters, because a guest who cannot get onto the network
/// cannot get their photographs, and reading a password off a screen and typing
/// it in is where most of them give up.
enum WiFiQR {
    /// `WIFI:T:WPA;S:<name>;P:<password>;;` — the semicolons and backslashes in
    /// a name have to be escaped or the rest of the string is read as fields.
    static func payload(ssid: String, password: String, hidden: Bool = false) -> String? {
        let name = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let type = password.isEmpty ? "nopass" : "WPA"
        var out = "WIFI:T:\(type);S:\(escape(name));"
        if !password.isEmpty { out += "P:\(escape(password));" }
        if hidden { out += "H:true;" }
        return out + ";"
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\;,\":".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}
