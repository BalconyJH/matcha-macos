import CoreGraphics
import Foundation
import ImageIO
import MatchaCore

/// The media brain both protocol adapters delegate to.
///
/// OneBot and Milky disagree on how a file is named on the wire (a path, an ID, a
/// `resource_id` with dimensions attached), but every one of those forms is a view
/// of the same stored bytes. This actor owns that single view: ingesting whatever a
/// peer sent, resolving an ID back to an `Asset`, and answering the two questions
/// the wire formats ask about it (where can it be fetched, how big is the picture).
/// The per-protocol shaping stays in the resolvers.
///
/// The HTTP base address is settable rather than fixed because the listening port is
/// only known once a session has started. URLs produced here point at
/// `/assets/<id>`, which whichever server the app runs for media is expected to
/// serve.
public actor MediaService {
    /// Pixel dimensions, as Milky's `width`/`height` fields want them.
    public struct PixelSize: Sendable, Hashable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    private let assetStore: AssetStore
    private let store: MatchaStore
    private var host: String = "127.0.0.1"
    private var port: UInt16 = ConnectionSettings.defaultPort

    /// Measured dimensions, keyed by asset ID. Safe to cache for the life of the
    /// process because the asset store is content-addressed: an ID names one exact
    /// byte sequence forever. `nil` is cached too, since "not an image" costs the
    /// same file probe to rediscover.
    private var pixelSizes: [String: PixelSize?] = [:]

    public init(assetStore: AssetStore, store: MatchaStore) {
        self.assetStore = assetStore
        self.store = store
    }

    // MARK: - Addressing

    /// Points generated URLs at the address a session is actually reachable on.
    public func setBaseURL(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public var baseURL: String { "http://\(host):\(port)" }

    /// An HTTP URL for a stored asset.
    public func url(for id: String) -> String { "\(baseURL)/assets/\(id)" }

    public func url(for asset: Asset) -> String { url(for: asset.id) }

    /// The asset's path on disk. OneBot v11 hands this to the framework directly so
    /// it can read the file without an HTTP round trip.
    public func path(for id: String) async -> String {
        await assetStore.location(of: id).path
    }

    // MARK: - Ingesting

    /// Takes an inbound reference in any form a peer might use and returns the stored
    /// asset.
    ///
    /// Parsing `base64://`, `data:`, `file://`, bare paths, and http(s) downloads is
    /// `AssetStore`'s job; what this adds is the database row, without which a later
    /// lookup by ID would find bytes but no name or MIME type.
    public func ingest(
        reference: String,
        fallbackURL: String? = nil,
        suggestedName: String? = nil
    ) async throws -> Asset? {
        guard let asset = try await assetStore.ingest(
            reference: reference,
            fallbackURL: fallbackURL,
            suggestedName: suggestedName
        ) else { return nil }
        try await store.save(asset)
        return asset
    }

    /// Stores raw bytes a peer uploaded inline.
    public func store(data: Data, name: String, mimeType: String? = nil) async -> Asset? {
        guard let asset = try? await assetStore.store(data, name: name, mimeType: mimeType) else {
            return nil
        }
        try? await store.save(asset)
        return asset
    }

    // MARK: - Resolving

    /// Resolves an asset ID a peer quoted back at us.
    public func asset(id: String) async -> Asset? {
        if let stored = (try? await store.asset(id: id)) ?? nil { return stored }

        // A file can outlive its row: the cache directory survives a store rebuild.
        // Reconstructing a minimal asset serves the bytes rather than reporting a
        // file the peer can plainly see is there as missing.
        guard await assetStore.exists(id) else { return nil }
        let location = await assetStore.location(of: id)
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size]) as? Int
        return Asset(
            id: id,
            name: id,
            mimeType: AssetStore.mimeType(forFileName: location.lastPathComponent),
            byteCount: byteCount ?? 0,
            source: .local(path: location.path)
        )
    }

    public func data(for id: String) async -> Data? {
        try? await assetStore.data(for: id)
    }

    public func exists(_ id: String) async -> Bool {
        await assetStore.exists(id)
    }

    // MARK: - Image dimensions

    public func pixelSize(of asset: Asset) async -> PixelSize? {
        await pixelSize(ofAssetID: asset.id, mimeType: asset.mimeType)
    }

    public func pixelSize(ofAssetID id: String, mimeType: String? = nil) async -> PixelSize? {
        if let cached = pixelSizes[id] { return cached }
        let measured = await measure(id: id, mimeType: mimeType)
        pixelSizes[id] = measured
        return measured
    }

    /// Reads dimensions out of the file header.
    ///
    /// ImageIO rather than a full decode: dimensions are metadata, and measuring a
    /// large photo should not cost the memory of decompressing it.
    private func measure(id: String, mimeType: String?) async -> PixelSize? {
        if let mimeType, !mimeType.hasPrefix("image/") { return nil }

        let location = await assetStore.location(of: id)
        guard FileManager.default.fileExists(atPath: location.path),
              let source = CGImageSourceCreateWithURL(location as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }

        return PixelSize(width: width, height: height)
    }
}
