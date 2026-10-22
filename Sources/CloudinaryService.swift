import Foundation

/// Publishes the gallery to Cloudinary.
///
/// Cloudinary is a media store with a CDN in front of it, not a web host: it has
/// no directory index and no notion of a site. So a "page" here is an HTML file
/// uploaded as a *raw* asset and delivered from res.cloudinary.com alongside the
/// photographs it points at. That works because everything lands on one origin —
/// same-origin is what makes the Save links and the in-browser zip work at all.
///
/// Uploads are **unsigned**: the booth sends a cloud name and an upload preset
/// and nothing else. No API secret is ever stored on the Mac, so a stolen laptop
/// leaks nothing that can delete or re-key an account.
///
/// The addresses are deterministic — `booth/<token>/index.html` — because the QR
/// code is generated when the session finishes, which can be days before the Mac
/// is online. A guest scans a code for a page that does not exist yet, and it
/// starts working when the queue drains.
struct CloudinaryService {

    struct Config: Equatable {
        var cloudName: String
        var preset: String

        var isComplete: Bool {
            !cloudName.trimmingCharacters(in: .whitespaces).isEmpty
                && !preset.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    enum ResourceType: String {
        case image
        case raw
        /// Cloudinary keeps video on its own endpoint and its own delivery path;
        /// an MP4 posted to the image endpoint is refused outright.
        case video
    }

    let config: Config

    // MARK: - Addresses

    /// `booth/<token>` — one folder per session, and the token is the only thing
    /// standing between a stranger and somebody's photographs.
    static func sessionFolder(token: String) -> String { "booth/\(token)" }
    static func eventFolder(token: String) -> String { "booth/album-\(token)" }

    /// Images carry no extension in their public ID; raw files must.
    static func photoPublicID(token: String, fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        return "\(sessionFolder(token: token))/\(stem)"
    }
    static func pagePublicID(token: String) -> String { "\(sessionFolder(token: token))/index.html" }
    static func albumPublicID(token: String) -> String { "\(eventFolder(token: token))/index.html" }

    /// Cloudinary's two hosts. Overridable only through the environment, which
    /// the offline test harness uses to point at a stand-in server — the app
    /// itself never sets these.
    static var apiBase: String {
        ProcessInfo.processInfo.environment["PHOTOBOOTH_CLOUDINARY_API"] ?? "https://api.cloudinary.com"
    }
    static var deliveryBase: String {
        ProcessInfo.processInfo.environment["PHOTOBOOTH_CLOUDINARY_CDN"] ?? "https://res.cloudinary.com"
    }

    /// Delivery is version-less on purpose: the address has to be predictable
    /// before the asset exists. The cost is that a replaced file can sit in the
    /// CDN cache, which is why the upload preset must have Invalidate switched on.
    static func deliveryURL(cloudName: String, type: ResourceType, publicID: String) -> URL? {
        let cloud = cloudName.trimmingCharacters(in: .whitespaces)
        guard !cloud.isEmpty else { return nil }
        let escaped = publicID
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? publicID
        return URL(string: "\(deliveryBase)/\(cloud)/\(type.rawValue)/upload/\(escaped)")
    }

    /// A delivery address that saves rather than opens, with a sensible filename.
    /// `fl_attachment` is Cloudinary's own way of doing it and, unlike the HTML
    /// download attribute, it keeps working however the page is served.
    static func attachmentURL(cloudName: String, publicID: String, saveAs: String) -> URL? {
        let cloud = cloudName.trimmingCharacters(in: .whitespaces)
        guard !cloud.isEmpty else { return nil }
        let stem = (saveAs as NSString).deletingPathExtension
        let ext = (saveAs as NSString).pathExtension.lowercased()
        // The delivery extension has to match what was uploaded: asking for the
        // GIF as .jpg hands the guest a still frame, which is exactly the thing
        // they were trying to save.
        let suffix = ext.isEmpty ? "jpg" : ext
        return URL(string: "\(deliveryBase)/\(cloud)/image/upload/fl_attachment:\(stem)/\(publicID).\(suffix)")
    }

    func url(for type: ResourceType, publicID: String) -> URL? {
        Self.deliveryURL(cloudName: config.cloudName, type: type, publicID: publicID)
    }

    /// The address a photograph is shown from. The `.jpg` is appended rather
    /// than stored in the public ID: Cloudinary wants images addressed by
    /// extension, and without one a phone saves a file it cannot open.
    func photoURL(token: String, fileName: String) -> URL? {
        guard let base = url(for: .image, publicID: Self.photoPublicID(token: token, fileName: fileName))
        else { return nil }
        return URL(string: base.absoluteString + ".jpg")
    }

    func photoSaveURL(token: String, fileName: String) -> URL? {
        Self.attachmentURL(cloudName: config.cloudName,
                           publicID: Self.photoPublicID(token: token, fileName: fileName),
                           saveAs: fileName)
    }

    /// GIFs are uploaded as images, so they share the photograph's addressing —
    /// only the delivery extension differs, and it has to be `.gif` or the CDN
    /// returns a single flattened frame.
    /// - Parameter fileName: the loop's own name in the session folder. A loop
    ///   rebuilt after a retake carries a new one, and the address has to
    ///   follow it or the page keeps pointing at the first version.
    func gifURL(token: String, fileName: String = GIFRenderer.fileName) -> URL? {
        guard let base = url(for: .image,
                             publicID: Self.photoPublicID(token: token, fileName: fileName))
        else { return nil }
        return URL(string: base.absoluteString + ".gif")
    }

    func gifSaveURL(token: String, fileName: String = GIFRenderer.fileName) -> URL? {
        Self.attachmentURL(cloudName: config.cloudName,
                           publicID: Self.photoPublicID(token: token, fileName: fileName),
                           saveAs: GIFRenderer.fileName)
    }

    /// The session's film. Video carries its extension in the delivery address
    /// the same way an image does.
    func videoURL(token: String) -> URL? {
        guard let base = url(for: .video,
                             publicID: Self.photoPublicID(token: token, fileName: SessionVideoRecorder.fileName))
        else { return nil }
        return URL(string: base.absoluteString + ".mp4")
    }

    func videoSaveURL(token: String) -> URL? {
        let stem = (SessionVideoRecorder.fileName as NSString).deletingPathExtension
        let cloud = config.cloudName.trimmingCharacters(in: .whitespaces)
        guard !cloud.isEmpty else { return nil }
        return URL(string: "\(Self.deliveryBase)/\(cloud)/video/upload/fl_attachment:\(stem)/"
                   + "\(Self.photoPublicID(token: token, fileName: SessionVideoRecorder.fileName)).mp4")
    }

    func pageURL(token: String) -> URL? { url(for: .raw, publicID: Self.pagePublicID(token: token)) }
    func albumURL(token: String) -> URL? { url(for: .raw, publicID: Self.albumPublicID(token: token)) }

    // MARK: - Uploading

    private var endpoint: URL? {
        let cloud = config.cloudName.trimmingCharacters(in: .whitespaces)
        guard !cloud.isEmpty else { return nil }
        return URL(string: "\(Self.apiBase)/v1_1/\(cloud)")
    }

    @discardableResult
    func upload(fileURL: URL, publicID: String, type: ResourceType,
                session: URLSession = .shared) async throws -> URL {
        let data = try Data(contentsOf: fileURL)
        return try await upload(data: data, filename: fileURL.lastPathComponent,
                                publicID: publicID, type: type, session: session)
    }

    @discardableResult
    func upload(data: Data, filename: String, publicID: String, type: ResourceType,
                session: URLSession = .shared) async throws -> URL {
        guard config.isComplete, let endpoint else { throw CloudinaryError.notConfigured }
        let url = endpoint.appendingPathComponent("\(type.rawValue)/upload")

        let boundary = "pb-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }
        // Only parameters Cloudinary accepts on an unsigned call: everything else
        // — overwrite, invalidate, access mode — belongs in the preset itself.
        field("upload_preset", config.preset.trimmingCharacters(in: .whitespaces))
        field("public_id", publicID)
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(Self.mimeType(for: filename))\r\n\r\n")
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 180

        let (responseData, response) = try await session.upload(for: req, from: body)
        guard let http = response as? HTTPURLResponse else { throw CloudinaryError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudinaryError.http(http.statusCode, Self.message(from: responseData))
        }
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let secure = json["secure_url"] as? String,
              let out = URL(string: secure) else {
            throw CloudinaryError.badResponse
        }
        return out
    }

    /// Proves the cloud name, the preset and raw uploads all work, by doing the
    /// smallest real upload there is. Reading a delivery URL alone would only
    /// prove the cloud name exists.
    func check(session: URLSession = .shared) async throws -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let body = "photobooth connection test \(stamp)\n"
        _ = try await upload(data: Data(body.utf8), filename: "connection-test.txt",
                             publicID: "booth/connection-test.txt", type: .raw, session: session)
        return config.cloudName
    }

    // MARK: - Helpers

    private static func mimeType(for filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "mp4":         return "video/mp4"
        case "jpg", "jpeg": return "image/jpeg"
        case "png":         return "image/png"
        case "gif":         return "image/gif"
        case "html":        return "text/html"
        case "txt":         return "text/plain"
        default:            return "application/octet-stream"
        }
    }

    /// Cloudinary puts the useful part in {"error":{"message":"…"}}.
    private static func message(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = json["error"] as? [String: Any],
           let m = err["message"] as? String {
            return m
        }
        return String(data: data.prefix(300), encoding: .utf8) ?? "no detail"
    }
}

enum CloudinaryError: LocalizedError {
    case notConfigured
    case nothingToUpload
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Set the Cloudinary cloud name and upload preset in Admin › Gallery Site."
        case .nothingToUpload:
            return "Nothing was uploaded — switch Originals or Prints back on."
        case .http(401, let m), .http(403, let m):
            return "Cloudinary refused the upload — check the preset is Unsigned. (\(m))"
        case .http(let code, let m):
            return "Cloudinary returned HTTP \(code) — \(m)"
        case .badResponse:
            return "Cloudinary sent a reply the app could not read."
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let d = string.data(using: .utf8) { append(d) }
    }
}
