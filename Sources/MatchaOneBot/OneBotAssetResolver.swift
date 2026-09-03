import Foundation
import MatchaCore
import MatchaProtocol

/// Addresses assets the way each OneBot version expects.
///
/// The two versions differ in what a "file" is on the wire, and that difference is
/// the whole reason this type exists. v11 inherited QQ's habit of naming a file by
/// where it sits, so a framework is handed a filesystem path it can open directly,
/// with an HTTP URL alongside for anything running on another machine. v12 replaced
/// that with an opaque `file_id` minted by an upload action, which maps cleanly onto
/// the asset store's content hash.
///
/// All the actual media work belongs to `MediaService`; this only picks which of its
/// answers goes on the wire.
public struct OneBotAssetResolver: AssetResolver {
    private let media: MediaService

    public init(media: MediaService) {
        self.media = media
    }

    // MARK: - Outbound

    public func reference(for asset: Asset, version: OneBotVersion) async -> AssetReference {
        let url = await media.url(for: asset)
        switch version {
        case .v11:
            return AssetReference(identifier: await media.path(for: asset.id), url: url)
        case .v12:
            // v12's `file_id` is exactly what the content hash already is.
            return AssetReference(identifier: asset.id, url: url)
        }
    }

    // MARK: - Inbound

    public func asset(forIdentifier identifier: String, kind: AssetKind) async -> Asset? {
        if let known = await media.asset(id: identifier) { return known }

        // An unknown `file_id` may still be a reference in disguise: implementations
        // sometimes put a path or URL where the spec asks for an upload ID.
        return try? await media.ingest(
            reference: identifier,
            suggestedName: Self.fallbackName(for: kind)
        )
    }

    public func asset(forReference reference: String, url: String?, kind: AssetKind) async -> Asset? {
        // v11 sends a path, an http(s) URL, or a base64 payload under `file`, and a
        // segment often carries both `file` and `url` where only one resolves.
        // `MediaService` tries them in order.
        try? await media.ingest(
            reference: reference,
            fallbackURL: url,
            suggestedName: Self.fallbackName(for: kind)
        )
    }

    // MARK: - Naming

    /// A filename for content that arrived without one, so the stored asset and its
    /// MIME guess are not both blank.
    private static func fallbackName(for kind: AssetKind) -> String {
        switch kind {
        case .image: return "image.png"
        case .record: return "record.amr"
        case .video: return "video.mp4"
        case .file: return "file.bin"
        }
    }
}
