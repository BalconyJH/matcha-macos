import CryptoKit
import Foundation

/// Content-addressed storage for media.
///
/// Files are named by the SHA-256 of their contents, so the same image sent twice
/// is stored once and a peer that re-sends a file it already uploaded costs nothing.
/// Ingestion accepts every form the supported protocols use: a filesystem path, an
/// HTTP URL, a `base64://` payload, or raw bytes.
public actor AssetStore {
    private let directory: URL
    private let session: URLSession

    public init(directory: URL, session: URLSession = .shared) throws {
        self.directory = directory
        self.session = session
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The store under the app's cache directory.
    public static func defaultLocation() throws -> AssetStore {
        let base = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Rei/assets", isDirectory: true)
        return try AssetStore(directory: base)
    }

    /// Where a stored asset lives on disk.
    public func location(of id: String) -> URL {
        directory.appendingPathComponent(id, isDirectory: false)
    }

    public func exists(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: location(of: id).path)
    }

    public func data(for id: String) throws -> Data {
        try Data(contentsOf: location(of: id))
    }

    /// Stores bytes and returns the asset describing them.
    public func store(_ data: Data, name: String, mimeType: String? = nil) throws -> Asset {
        let digest = SHA256.hash(data: data)
        let id = digest.map { String(format: "%02x", $0) }.joined()
        let destination = location(of: id)

        // Content-addressed, so an existing file with this name is byte-identical.
        if !FileManager.default.fileExists(atPath: destination.path) {
            try data.write(to: destination, options: .atomic)
        }

        return Asset(
            id: id,
            name: name.isEmpty ? id : name,
            mimeType: mimeType ?? Self.mimeType(forFileName: name),
            byteCount: data.count,
            source: .inline
        )
    }

    /// Ingests whatever a peer supplied as a file reference.
    ///
    /// Returns `nil` when the reference has no resolvable resource, such as a missing
    /// path or malformed inline value. Recognized resources throw on read, download,
    /// or storage failures so application callers can diagnose real I/O errors;
    /// protocol resolvers deliberately convert those errors back to `nil`.
    public func ingest(
        reference: String,
        fallbackURL: String? = nil,
        suggestedName: String? = nil
    ) async throws -> Asset? {
        // base64:// inline payload
        if let payload = Self.base64Payload(in: reference) {
            guard let data = Data(base64Encoded: payload) else { return nil }
            return try store(data, name: suggestedName ?? "inline")
        }

        // file:// URL or a bare filesystem path
        if let path = Self.filePath(in: reference) {
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            var asset = try store(
                data,
                name: suggestedName ?? (path as NSString).lastPathComponent
            )
            asset.source = .local(path: path)
            return asset
        }

        // http(s):// — download so the file is available locally afterwards.
        var lastDownloadError: (any Error)?
        for candidate in [reference, fallbackURL].compacted() {
            guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https"
            else { continue }
            do {
                let (data, response) = try await session.data(from: url)
                let name = suggestedName ?? url.lastPathComponent
                var asset = try store(data, name: name, mimeType: response.mimeType)
                asset.source = .remote(url: candidate)
                return asset
            } catch {
                lastDownloadError = error
            }
        }

        if let lastDownloadError { throw lastDownloadError }
        return nil
    }

    // MARK: - Reference parsing

    private static func base64Payload(in reference: String) -> String? {
        for prefix in ["base64://", "data:"] where reference.hasPrefix(prefix) {
            if prefix == "base64://" {
                return String(reference.dropFirst(prefix.count))
            }
            // data:<mime>;base64,<payload>
            guard let comma = reference.firstIndex(of: ",") else { return nil }
            return String(reference[reference.index(after: comma)...])
        }
        return nil
    }

    private static func filePath(in reference: String) -> String? {
        if reference.hasPrefix("file://") {
            return URL(string: reference)?.path
        }
        if reference.hasPrefix("/") {
            return reference
        }
        return nil
    }

    /// Best-effort MIME type from a file extension.
    ///
    /// UniformTypeIdentifiers would be more thorough, but the handful of types that
    /// cross a chat protocol are worth spelling out — it avoids a framework import
    /// for a lookup this small.
    public static func mimeType(forFileName name: String) -> String? {
        switch (name as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "heic": return "image/heic"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "amr": return "audio/amr"
        case "silk": return "audio/silk"
        case "m4a": return "audio/mp4"
        case "ogg": return "audio/ogg"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "txt": return "text/plain"
        case "json": return "application/json"
        case "pdf": return "application/pdf"
        case "zip": return "application/zip"
        default: return nil
        }
    }
}

extension Sequence {
    /// Non-nil elements, in order.
    func compacted<Wrapped>() -> [Wrapped] where Element == Wrapped? {
        compactMap { $0 }
    }
}
