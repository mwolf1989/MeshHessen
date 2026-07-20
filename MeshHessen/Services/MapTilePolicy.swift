import Foundation

enum MapTilePolicy {
    static let minimumPublicCacheLifetime: TimeInterval = 7 * 24 * 60 * 60

    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        // The community raster/vector ACL uses the historical Windows client
        // product token. Keep it identical across platforms so requests are
        // accepted outside the server IP allow-list.
        return "MeshhessenClient/\(version) (+https://meshhessenclient.de; contact: admin@meshhessenclient.de)"
    }

    static func isPublicTileServer(_ template: String) -> Bool {
        guard let host = URLComponents(string: template)?.host?.lowercased() else {
            return false
        }
        return host == "tile.openstreetmap.org"
            || host.hasSuffix(".tile.openstreetmap.org")
            || host == "opentopomap.org"
            || host.hasSuffix(".opentopomap.org")
    }

    static func validateTemplate(_ template: String) throws {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("{z}"), trimmed.contains("{x}"), trimmed.contains("{y}"),
              let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false else {
            throw OfflineMapError.invalidURLTemplate
        }
    }

    static func ensureBulkDownloadAllowed(for descriptor: MapTileSourceDescriptor) throws {
        try validateTemplate(descriptor.urlTemplate)
        if descriptor.followsPublicOSMPolicy || isPublicTileServer(descriptor.urlTemplate) {
            throw OfflineMapError.publicBulkDownloadForbidden
        }
    }

    static func resolvedURL(
        template: String,
        coordinate: MapTileCoordinate
    ) throws -> URL {
        try validateTemplate(template)
        let value = template
            .replacingOccurrences(of: "{z}", with: String(coordinate.zoom))
            .replacingOccurrences(of: "{x}", with: String(coordinate.x))
            .replacingOccurrences(of: "{y}", with: String(coordinate.y))
        guard let url = URL(string: value) else {
            throw OfflineMapError.invalidURLTemplate
        }
        return url
    }

    static func cacheExpiry(
        cacheControl: String?,
        expires: Date?,
        now: Date = Date()
    ) -> Date {
        var candidates = [now.addingTimeInterval(minimumPublicCacheLifetime)]

        if let expires {
            candidates.append(expires)
        }

        if let cacheControl,
           let maxAge = cacheControl
            .split(separator: ",")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.lowercased().hasPrefix("max-age=") })?
            .split(separator: "=", maxSplits: 1)
            .last,
           let seconds = TimeInterval(maxAge) {
            candidates.append(now.addingTimeInterval(seconds))
        }

        return candidates.max() ?? now.addingTimeInterval(minimumPublicCacheLifetime)
    }
}
