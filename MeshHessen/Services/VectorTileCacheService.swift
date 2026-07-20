import Foundation

/// MapLibre resource categories. `Style` and `Source` are refreshed from the
/// network while all large immutable resources prefer the persistent cache.
enum VectorResourceType: String, CaseIterable, Sendable {
    case style = "Style"
    case source = "Source"
    case tile = "Tile"
    case glyphs = "Glyphs"
    case spriteImage = "SpriteImage"
    case spriteJSON = "SpriteJSON"
    case image = "Image"
    case unknown = "Unknown"

    init(mapLibreValue: String?) {
        guard let value = mapLibreValue?.lowercased() else {
            self = .unknown
            return
        }
        self = Self.allCases.first { $0.rawValue.lowercased() == value } ?? .unknown
    }
}

struct VectorResourceResponse: Sendable, Equatable {
    let statusCode: Int
    let reasonPhrase: String
    let headers: [String: String]
    let body: Data?

    var mimeType: String? {
        headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
    }
}

struct VectorHTTPClientResponse: Sendable {
    let data: Data
    let statusCode: Int
    let reasonPhrase: String
    let headers: [String: String]

    func value(forHTTPHeaderField name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

protocol VectorTileHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> VectorHTTPClientResponse
}

private struct URLSessionVectorTileHTTPClient: VectorTileHTTPClient {
    let session: URLSession

    func data(for request: URLRequest) async throws -> VectorHTTPClientResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let key = key as? String else { continue }
            headers[key] = String(describing: value)
        }
        return VectorHTTPClientResponse(
            data: data,
            statusCode: http.statusCode,
            reasonPhrase: HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
            headers: headers
        )
    }
}

enum VectorTileCacheError: LocalizedError, Equatable {
    case unsupportedRemoteURL

    var errorDescription: String? {
        switch self {
        case .unsupportedRemoteURL:
            return String(localized: "Only HTTP and HTTPS vector-map resources are supported.")
        }
    }
}

/// Persistent MapLibre resource cache shared by the vector renderer and future
/// offline-package downloads.
actor VectorTileCacheService {
    static let shared = VectorTileCacheService()
    static let attribution = "© OpenMapTiles © OpenStreetMap contributors"

    private let cacheBaseDirectory: URL
    private let httpClient: any VectorTileHTTPClient
    private let userAgent: String
    private var offlineOnly: Bool

    init(
        cacheBaseDirectory: URL? = nil,
        offlineOnly: Bool = false,
        userAgent: String = MapTilePolicy.userAgent
    ) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.init(
            cacheBaseDirectory: cacheBaseDirectory ?? Self.defaultCacheBaseDirectory,
            offlineOnly: offlineOnly,
            userAgent: userAgent,
            httpClient: URLSessionVectorTileHTTPClient(session: URLSession(configuration: configuration))
        )
    }

    init(
        cacheBaseDirectory: URL,
        offlineOnly: Bool = false,
        userAgent: String = MapTilePolicy.userAgent,
        httpClient: any VectorTileHTTPClient
    ) {
        self.cacheBaseDirectory = cacheBaseDirectory
        self.offlineOnly = offlineOnly
        self.userAgent = userAgent
        self.httpClient = httpClient
    }

    func setOfflineOnly(_ value: Bool) {
        offlineOnly = value
    }

    func response(
        for remoteURL: URL,
        resourceType: VectorResourceType = .unknown
    ) async throws -> VectorResourceResponse {
        try Task.checkCancellation()
        let cacheURL = try Self.cacheFileURL(for: remoteURL, in: cacheBaseDirectory)
        let missingURL = cacheURL.appendingPathExtension("missing")
        let networkFirst = Self.isNetworkFirst(remoteURL, resourceType: resourceType)

        if offlineOnly {
            return cachedResponse(for: remoteURL, cacheURL: cacheURL, missingURL: missingURL)
                ?? Self.response(statusCode: 404, reasonPhrase: "Not Found (offline)")
        }

        if !networkFirst,
           let cached = cachedResponse(for: remoteURL, cacheURL: cacheURL, missingURL: missingURL) {
            return cached
        }

        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 30
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        do {
            let result = try await httpClient.data(for: request)
            try Task.checkCancellation()

            if result.statusCode == 204 || result.statusCode == 404 {
                markMissing(at: missingURL)
                return Self.response(statusCode: 204, reasonPhrase: "No Content")
            }

            guard (200...299).contains(result.statusCode), !result.data.isEmpty else {
                return cachedResponse(for: remoteURL, cacheURL: cacheURL, missingURL: missingURL)
                    ?? Self.response(
                        statusCode: result.statusCode,
                        reasonPhrase: result.reasonPhrase.isEmpty ? "Upstream Error" : result.reasonPhrase
                    )
            }

            persist(result.data, at: cacheURL)
            try? FileManager.default.removeItem(at: missingURL)
            let contentType = Self.contentType(
                for: remoteURL,
                data: result.data,
                upstreamValue: result.value(forHTTPHeaderField: "Content-Type")
            )
            return Self.response(
                statusCode: 200,
                reasonPhrase: "OK",
                body: result.data,
                contentType: contentType
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            return cachedResponse(for: remoteURL, cacheURL: cacheURL, missingURL: missingURL)
                ?? Self.response(statusCode: 504, reasonPhrase: "Gateway Timeout")
        }
    }

    // MARK: - Cache policy

    nonisolated static func isNetworkFirst(
        _ remoteURL: URL,
        resourceType: VectorResourceType
    ) -> Bool {
        switch resourceType {
        case .style, .source:
            return true
        case .tile, .glyphs, .spriteImage, .spriteJSON, .image:
            return false
        case .unknown:
            break
        }

        let path = remoteURL.path.lowercased()
        if path.hasPrefix("/styles/") { return true }

        // The MeshHessen server exposes TileJSON as one extensionless path
        // component (`/basemap`, `/contours`, ...). Tiles live below it.
        let components = path.split(separator: "/")
        return components.count == 1
            && !(components.first?.contains(".") ?? false)
    }

    nonisolated static func cacheFileURL(for remoteURL: URL, in baseDirectory: URL) throws -> URL {
        guard let components = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            throw VectorTileCacheError.unsupportedRemoteURL
        }

        let hostComponent = safePathComponent(
            components.port.map { "\(host)_\($0)" } ?? host
        )
        var pathComponents = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { safePathComponent(String($0).removingPercentEncoding ?? String($0)) }
        if pathComponents.isEmpty { pathComponents = ["index"] }

        var leaf = pathComponents.removeLast()
        if URL(fileURLWithPath: leaf).pathExtension.isEmpty {
            leaf += ".bin"
        }
        if let query = components.percentEncodedQuery, !query.isEmpty {
            leaf = addingQueryDigest(Self.stableDigest(query), to: leaf)
        }

        var result = baseDirectory.appendingPathComponent(hostComponent, isDirectory: true)
        for component in pathComponents {
            result.appendPathComponent(component, isDirectory: true)
        }
        result.appendPathComponent(leaf, isDirectory: false)
        return result
    }

    nonisolated static func contentType(
        for remoteURL: URL,
        data: Data,
        upstreamValue: String? = nil
    ) -> String {
        if let upstreamValue {
            let trimmedValue = upstreamValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let mediaType = trimmedValue
                .split(separator: ";", maxSplits: 1)
                .first?
                .lowercased()

            if mediaType == "application/x-protobuf" || mediaType == "application/vnd.mapbox-vector-tile" {
                return remoteURL.pathExtension.lowercased() == "pbf"
                    ? "application/x-protobuf"
                    : "application/vnd.mapbox-vector-tile"
            }
            if !trimmedValue.isEmpty, mediaType != "application/octet-stream" {
                return trimmedValue
            }
        }

        switch remoteURL.pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "pbf": return "application/x-protobuf"
        case "mvt": return "application/vnd.mapbox-vector-tile"
        default: break
        }

        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.count >= 12,
           bytes[0...3] == [0x52, 0x49, 0x46, 0x46],
           bytes[8...11] == [0x57, 0x45, 0x42, 0x50] {
            return "image/webp"
        }
        if let first = data.first(where: { ![0x09, 0x0A, 0x0D, 0x20].contains($0) }),
           first == 0x7B || first == 0x5B {
            return "application/json"
        }
        return "application/vnd.mapbox-vector-tile"
    }

    // MARK: - Persistence

    private func cachedResponse(
        for remoteURL: URL,
        cacheURL: URL,
        missingURL: URL
    ) -> VectorResourceResponse? {
        if FileManager.default.fileExists(atPath: missingURL.path) {
            return Self.response(statusCode: 204, reasonPhrase: "No Content")
        }
        guard let data = try? Data(contentsOf: cacheURL, options: .mappedIfSafe) else {
            return nil
        }
        return Self.response(
            statusCode: 200,
            reasonPhrase: "OK",
            body: data,
            contentType: Self.contentType(for: remoteURL, data: data)
        )
    }

    private func persist(_ data: Data, at url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            AppLogger.shared.log("Vector tile cache write failed for \(url.lastPathComponent): \(error)")
        }
    }

    private func markMissing(at url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: url, options: .atomic)
        } catch {
            AppLogger.shared.log("Vector tile missing marker write failed for \(url.lastPathComponent): \(error)")
        }
    }

    private nonisolated static func response(
        statusCode: Int,
        reasonPhrase: String,
        body: Data? = nil,
        contentType: String? = nil
    ) -> VectorResourceResponse {
        var headers = [
            "Access-Control-Allow-Origin": "*",
            "Cross-Origin-Resource-Policy": "cross-origin",
        ]
        if let contentType { headers["Content-Type"] = contentType }
        return VectorResourceResponse(
            statusCode: statusCode,
            reasonPhrase: reasonPhrase,
            headers: headers,
            body: body
        )
    }

    private nonisolated static var defaultCacheBaseDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("MeshHessen", isDirectory: true)
            .appendingPathComponent("VectorTiles", isDirectory: true)
    }

    private nonisolated static func safePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        var scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        if scalars.count > 160 {
            scalars = Array(scalars.prefix(140)) + Array("_\(stableDigest(value))")
        }
        let result = String(scalars)
        return result.isEmpty || result == "." || result == ".." ? "_" : result
    }

    private nonisolated static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private nonisolated static func addingQueryDigest(_ digest: String, to filename: String) -> String {
        let url = URL(fileURLWithPath: filename)
        let fileExtension = url.pathExtension
        guard !fileExtension.isEmpty else { return "\(filename)__q_\(digest)" }
        let stem = filename.dropLast(fileExtension.count + 1)
        return "\(stem)__q_\(digest).\(fileExtension)"
    }
}
