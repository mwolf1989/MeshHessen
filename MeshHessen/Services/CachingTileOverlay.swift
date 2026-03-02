import MapKit
import os

/// A tile overlay that caches downloaded tiles to disk for offline use.
///
/// On first request the tile is fetched from the network and stored locally.
/// Subsequent requests for the same tile are served from the file cache.
final class CachingTileOverlay: MKTileOverlay {

    private static let logger = Logger(subsystem: "de.meshhessen.app", category: "TileCache")

    /// Root directory for all cached tiles.
    private let cacheDirectory: URL

    /// Shared URLSession with a generous disk-cache as fallback.
    private let session: URLSession

    override init(urlTemplate URLTemplate: String?) {
        // ~/Library/Caches/<bundle>/TileCache
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDirectory = caches.appendingPathComponent("TileCache", isDirectory: true)

        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = URLCache(
            memoryCapacity: 32 * 1024 * 1024,  // 32 MB RAM
            diskCapacity: 512 * 1024 * 1024     // 512 MB disk
        )
        self.session = URLSession(configuration: config)

        super.init(urlTemplate: URLTemplate)
    }

    // MARK: - MKTileOverlay

    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, Error?) -> Void) {
        let fileURL = localURL(for: path)

        // 1. Check local file cache
        if let data = try? Data(contentsOf: fileURL) {
            result(data, nil)
            return
        }

        // 2. Fetch from network
        let url = self.url(forTilePath: path)
        let task = session.dataTask(with: url) { [weak self] data, response, error in
            guard let data, error == nil else {
                result(nil, error)
                return
            }

            // Verify we got a valid image response
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                result(nil, URLError(.badServerResponse))
                return
            }

            // 3. Write to disk cache (fire-and-forget)
            self?.saveTile(data, to: fileURL)

            result(data, nil)
        }
        task.resume()
    }

    // MARK: - File cache helpers

    /// Build a file path like `TileCache/{z}/{x}/{y}.png`.
    private func localURL(for path: MKTileOverlayPath) -> URL {
        cacheDirectory
            .appendingPathComponent("\(path.z)", isDirectory: true)
            .appendingPathComponent("\(path.x)", isDirectory: true)
            .appendingPathComponent("\(path.y).png")
    }

    private func saveTile(_ data: Data, to fileURL: URL) {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.warning("Failed to cache tile: \(error.localizedDescription)")
        }
    }

    // MARK: - Cache management

    /// Total size of the tile cache in bytes.
    var cacheSizeBytes: Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: cacheDirectory,
                                             includingPropertiesForKeys: [.fileSizeKey],
                                             options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Human-readable cache size string.
    var cacheSizeFormatted: String {
        let bytes = cacheSizeBytes
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Remove all cached tiles.
    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        Self.logger.info("Tile cache cleared")
    }
}
