import Foundation
import MapKit
import os

struct MapTileOverlayConfiguration: Sendable {
    var descriptor: MapTileSourceDescriptor
    var liveCacheDirectory: URL
    var offlinePackageDirectories: [URL]
    var offlineOnly: Bool

    init(
        descriptor: MapTileSourceDescriptor,
        liveCacheDirectory: URL,
        offlinePackageDirectories: [URL] = [],
        offlineOnly: Bool = false
    ) {
        self.descriptor = descriptor
        self.liveCacheDirectory = liveCacheDirectory
        self.offlinePackageDirectories = offlinePackageDirectories
        self.offlineOnly = offlineOnly
    }
}

/// XYZ raster tile overlay with a persistent cache and an explicit offline mode.
/// Public OSM tiles use conditional requests and a minimum seven-day lifetime;
/// Mesh Hessen/custom-server tiles remain cached until the user clears them.
final class CachingTileOverlay: MKTileOverlay {
    private static let logger = Logger(subsystem: "de.meshhessen.app", category: "TileCache")

    private struct TileMetadata: Codable {
        var eTag: String?
        var lastModified: String?
        var expiresAt: Date
    }

    private let configuration: MapTileOverlayConfiguration
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    convenience override init(urlTemplate URLTemplate: String?) {
        let fileManager = FileManager.default
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let descriptor = MapTileSourceDescriptor(
            source: .osm,
            urlTemplate: URLTemplate ?? "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
        )
        self.init(
            configuration: .init(
                descriptor: descriptor,
                liveCacheDirectory: caches.appendingPathComponent("MeshHessen/TileCache", isDirectory: true)
            )
        )
    }

    init(configuration: MapTileOverlayConfiguration) {
        self.configuration = configuration
        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = configuration.descriptor.followsPublicOSMPolicy ? 20 : 30
        sessionConfiguration.timeoutIntervalForResource = 60
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: sessionConfiguration)
        super.init(urlTemplate: configuration.descriptor.urlTemplate)
        minimumZ = configuration.descriptor.minimumZoom
        maximumZ = configuration.descriptor.maximumZoom
    }

    override func loadTile(
        at path: MKTileOverlayPath,
        result: @escaping (Data?, (any Error)?) -> Void
    ) {
        let coordinate = MapTileCoordinate(x: path.x, y: path.y, zoom: path.z)
        let cacheURL = liveCacheURL(for: coordinate)

        if let offlineData = firstOfflineTile(for: coordinate) {
            result(offlineData, nil)
            return
        }

        if configuration.offlineOnly {
            result(nil, nil)
            return
        }

        if !configuration.descriptor.followsPublicOSMPolicy,
           let data = try? Data(contentsOf: cacheURL) {
            result(data, nil)
            return
        }

        let metadataURL = cacheURL.appendingPathExtension("meta")
        let metadata = loadMetadata(at: metadataURL)
        if configuration.descriptor.followsPublicOSMPolicy,
           let metadata,
           metadata.expiresAt > Date(),
           let data = try? Data(contentsOf: cacheURL) {
            result(data, nil)
            return
        }

        let url: URL
        do {
            url = try MapTilePolicy.resolvedURL(
                template: configuration.descriptor.urlTemplate,
                coordinate: coordinate
            )
        } catch {
            result(nil, error)
            return
        }

        var request = URLRequest(url: url)
        request.setValue(MapTilePolicy.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("image/avif,image/webp,image/png,image/*;q=0.8", forHTTPHeaderField: "Accept")
        if configuration.descriptor.followsPublicOSMPolicy,
           FileManager.default.fileExists(atPath: cacheURL.path) {
            if let eTag = metadata?.eTag {
                request.setValue(eTag, forHTTPHeaderField: "If-None-Match")
            } else if let lastModified = metadata?.lastModified {
                request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
            }
        }

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else {
                result(nil, error)
                return
            }
            if let response = response as? HTTPURLResponse,
               response.statusCode == 304,
               let cached = try? Data(contentsOf: cacheURL) {
                self.saveMetadata(self.metadata(from: response), to: metadataURL)
                result(cached, nil)
                return
            }

            if let response = response as? HTTPURLResponse,
               (200...299).contains(response.statusCode),
               let data,
               !data.isEmpty {
                self.saveTile(data, to: cacheURL)
                if self.configuration.descriptor.followsPublicOSMPolicy {
                    self.saveMetadata(self.metadata(from: response), to: metadataURL)
                }
                result(data, nil)
                return
            }

            // Stale-on-error avoids a blank map while disconnected.
            if let stale = try? Data(contentsOf: cacheURL) {
                result(stale, nil)
            } else {
                result(nil, error ?? URLError(.badServerResponse))
            }
        }.resume()
    }

    // MARK: - Paths

    private func firstOfflineTile(for coordinate: MapTileCoordinate) -> Data? {
        for packageDirectory in configuration.offlinePackageDirectories {
            let file = packageDirectory
                .appendingPathComponent("tiles", isDirectory: true)
                .appendingPathComponent(configuration.descriptor.source.rawValue, isDirectory: true)
                .appendingPathComponent(String(coordinate.zoom), isDirectory: true)
                .appendingPathComponent(String(coordinate.x), isDirectory: true)
                .appendingPathComponent("\(coordinate.y).\(configuration.descriptor.source.fileExtension)")
            if let data = try? Data(contentsOf: file) { return data }
        }
        return nil
    }

    private func liveCacheURL(for coordinate: MapTileCoordinate) -> URL {
        configuration.liveCacheDirectory
            .appendingPathComponent(configuration.descriptor.source.rawValue, isDirectory: true)
            .appendingPathComponent(String(coordinate.zoom), isDirectory: true)
            .appendingPathComponent(String(coordinate.x), isDirectory: true)
            .appendingPathComponent("\(coordinate.y).\(configuration.descriptor.source.fileExtension)")
    }

    // MARK: - Persistence

    private func saveTile(_ data: Data, to fileURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.warning("Failed to cache tile: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadMetadata(at url: URL) -> TileMetadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(TileMetadata.self, from: data)
    }

    private func saveMetadata(_ metadata: TileMetadata, to url: URL) {
        do {
            let data = try encoder.encode(metadata)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.warning("Failed to cache tile metadata: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func metadata(from response: HTTPURLResponse) -> TileMetadata {
        TileMetadata(
            eTag: response.value(forHTTPHeaderField: "ETag"),
            lastModified: response.value(forHTTPHeaderField: "Last-Modified"),
            expiresAt: MapTilePolicy.cacheExpiry(
                cacheControl: response.value(forHTTPHeaderField: "Cache-Control"),
                expires: Self.httpDate(response.value(forHTTPHeaderField: "Expires"))
            )
        )
    }

    private static func httpDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value)
    }
}
