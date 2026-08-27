import Foundation
import Network

/// Serves the album folder on 127.0.0.1 so the operator can actually look at a
/// page before sending it to a client.
///
/// This exists because of a browser rule rather than a design choice: WebCrypto
/// is withheld from pages opened straight off the disk, so an album opened by
/// double-clicking can never unlock. Localhost counts as a secure context, so a
/// four-line HTTP server is the whole fix.
///
/// Bound to loopback only — this is a preview for the person at the keyboard,
/// not a way to publish a client's photographs off a laptop at a venue.
/// Deliberately not actor-isolated: a request must be answered from the network
/// queue even while the main actor is busy rendering the booth, so state is kept
/// behind a small lock instead.
final class AlbumPreviewServer: @unchecked Sendable {

    static let shared = AlbumPreviewServer()

    private let lock = NSLock()
    private var listener: NWListener?
    private var _root: URL?
    private var _port: UInt16 = 0

    private var root: URL? {
        get { lock.lock(); defer { lock.unlock() }; return _root }
        set { lock.lock(); _root = newValue; lock.unlock() }
    }
    private(set) var port: UInt16 {
        get { lock.lock(); defer { lock.unlock() }; return _port }
        set { lock.lock(); _port = newValue; lock.unlock() }
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return listener != nil }

    /// Starts (or re-points) the server and returns the port it is on.
    @discardableResult
    func start(root: URL) throws -> UInt16 {
        self.root = root
        if let listener, listener.state == .ready { return port }
        stop()

        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: .any)
        let ready = DispatchSemaphore(value: 0)
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global(qos: .userInitiated))
            self?.receive(on: conn)
        }
        l.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let p = l.port?.rawValue {
                self?.port = p
                ready.signal()
            }
        }
        l.start(queue: .global(qos: .userInitiated))
        lock.lock(); listener = l; lock.unlock()

        // The port is only known once the listener is ready — a preview opened
        // before then would hit a dead address. Loopback binds in milliseconds.
        guard ready.wait(timeout: .now() + 3) == .success, port != 0 else {
            stop()
            throw AlbumServerError.didNotStart
        }
        return port
    }

    func stop() {
        lock.lock()
        listener?.cancel()
        listener = nil
        _port = 0
        lock.unlock()
    }

    func url(for fileName: String) -> URL? {
        guard port != 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/\(fileName)")
    }

    // MARK: - The world's smallest static server

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, _ in
            guard let self, let data, !data.isEmpty else {
                if done { conn.cancel() }
                return
            }
            let head = String(decoding: data.prefix(2048), as: UTF8.self)
            let path = head.split(separator: "\r\n").first
                .flatMap { line -> String? in
                    let parts = line.split(separator: " ")
                    guard parts.count >= 2, parts[0] == "GET" else { return nil }
                    return String(parts[1])
                } ?? "/"
            self.respond(to: path, on: conn)
        }
    }

    private func respond(to rawPath: String, on conn: NWConnection) {
        let clean = rawPath.split(separator: "?").first.map(String.init) ?? "/"
        let name = (clean.removingPercentEncoding ?? clean)
            .split(separator: "/").last.map(String.init) ?? ""

        // Only ever serves .html sitting directly in the album folder — no
        // traversal, no directory listing, nothing else on the disk.
        guard let root, !name.isEmpty, name.hasSuffix(".html"), !name.contains("..") else {
            send(status: "404 Not Found", body: Data("Not found".utf8), type: "text/plain", on: conn)
            return
        }
        let file = root.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: file) else {
            send(status: "404 Not Found", body: Data("Not found".utf8), type: "text/plain", on: conn)
            return
        }
        send(status: "200 OK", body: data, type: "text/html; charset=utf-8", on: conn)
    }

    private func send(status: String, body: Data, type: String, on conn: NWConnection) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

enum AlbumServerError: LocalizedError {
    case didNotStart
    var errorDescription: String? { "Could not start the local preview server." }
}
