import Foundation

struct VectorOfflineDownloadRequest: Equatable, Sendable {
    var bounds: MapBounds
    var maximumDetailZoom: Int
    var includeTopography: Bool
    var includeEmergencyFeatures: Bool
}

struct VectorOfflineSourcePlan: Equatable, Sendable {
    var source: String
    var minimumZoom: Int
    var maximumZoom: Int
}

struct VectorOfflineDownloadResult: Equatable, Sendable {
    var downloadedOrCached: Int
    var errors: Int
}

/// Preloads all resources required by the three MapLibre styles into the same
/// persistent cache used by the live vector renderer. Re-running a region is
/// incremental because immutable resources are cache-first.
actor VectorOfflinePackageDownloaderService {
    typealias ProgressHandler = @Sendable (OfflineMapProgress) async -> Void

    static let defaultHost = "vectortile.meshhessenclient.de"
    static let basemapMaximumZoom = 14
    static let maximumVectorZoom = 17

    private static let fontStacks = ["Noto Sans Regular", "Noto Sans Bold", "Noto Sans Italic"]
    private static let fontRangeCount = 8

    private let cacheDirectory: URL
    private let cache: VectorTileCacheService

    init(cacheDirectory: URL? = nil) {
        let directory = cacheDirectory ?? Self.defaultCacheDirectory
        self.cacheDirectory = directory
        cache = VectorTileCacheService(cacheBaseDirectory: directory, offlineOnly: false)
    }

    nonisolated static func plans(for request: VectorOfflineDownloadRequest) -> [VectorOfflineSourcePlan] {
        let maximumZoom = max(1, min(maximumVectorZoom, request.maximumDetailZoom))
        var result = [
            VectorOfflineSourcePlan(
                source: "basemap",
                minimumZoom: 1,
                maximumZoom: min(maximumZoom, basemapMaximumZoom)
            ),
        ]
        if request.includeTopography {
            if maximumZoom >= 11 {
                result.append(.init(source: "contours", minimumZoom: 11, maximumZoom: maximumZoom))
            }
            result.append(
                .init(
                    source: "hillshade",
                    minimumZoom: 1,
                    maximumZoom: min(maximumZoom, basemapMaximumZoom)
                )
            )
        }
        if request.includeEmergencyFeatures, maximumZoom >= 13 {
            result.append(.init(source: "emergency", minimumZoom: 13, maximumZoom: maximumZoom))
        }
        return result.filter { $0.maximumZoom >= $0.minimumZoom }
    }

    nonisolated static func estimatedResourceCount(for request: VectorOfflineDownloadRequest) -> Int {
        let plans = plans(for: request)
        let tiles = plans.reduce(0) { result, plan in
            let count = TileCoordinateCalculator.estimatedTileCount(
                bounds: request.bounds,
                minimumZoom: plan.minimumZoom,
                maximumZoom: plan.maximumZoom
            )
            if count == Int.max || result > Int.max - count { return Int.max }
            return result + count
        }
        let staticResources = 3 + plans.count + fontStacks.count * fontRangeCount + 8
        return tiles == Int.max || tiles > Int.max - staticResources ? Int.max : tiles + staticResources
    }

    func download(
        _ request: VectorOfflineDownloadRequest,
        progress: @escaping ProgressHandler
    ) async throws -> VectorOfflineDownloadResult {
        guard request.bounds.isValid else { throw OfflineMapError.invalidBounds }
        guard request.maximumDetailZoom >= 1,
              request.maximumDetailZoom <= Self.maximumVectorZoom else {
            throw OfflineMapError.invalidZoomRange
        }
        let estimate = Self.estimatedResourceCount(for: request)
        guard estimate > 0, estimate <= TileCoordinateCalculator.maximumOfflineTileCount else {
            throw OfflineMapError.packageTooLarge(estimate)
        }

        let jobs = try Self.jobs(for: request)
        await progress(.init(phase: .preparing, completed: 0, total: jobs.count, status: String(localized: "Vector resources")))

        var successful = 0
        var errors = 0
        let batchSize = 6
        for batchStart in stride(from: 0, to: jobs.count, by: batchSize) {
            try Task.checkCancellation()
            let batchEnd = min(batchStart + batchSize, jobs.count)
            let batch = Array(jobs[batchStart..<batchEnd])
            let cache = cache
            let results = await withTaskGroup(of: Bool.self) { group in
                for job in batch {
                    group.addTask {
                        do {
                            let response = try await cache.response(for: job.url, resourceType: job.resourceType)
                            return response.statusCode == 200 || response.statusCode == 204
                        } catch {
                            return false
                        }
                    }
                }
                var values: [Bool] = []
                for await value in group { values.append(value) }
                return values
            }
            successful += results.filter { $0 }.count
            errors += results.filter { !$0 }.count
            let lastStatus = batch.last?.status ?? String(localized: "Vector resources")
            await progress(
                .init(
                    phase: .downloading,
                    completed: batchEnd,
                    total: jobs.count,
                    status: errors == 0
                        ? "\(batchEnd) / \(jobs.count) · \(lastStatus)"
                        : "\(batchEnd) / \(jobs.count) · \(errors) \(String(localized: "errors"))"
                )
            )
        }

        guard successful > 0 else {
            throw OfflineMapError.network(String(localized: "No vector-map resource could be downloaded."))
        }
        await progress(
            .init(
                phase: .finished,
                completed: jobs.count,
                total: jobs.count,
                status: String(localized: "Vector offline area ready")
            )
        )
        return .init(downloadedOrCached: successful, errors: errors)
    }

    func storageSizeBytes() throws -> Int64 {
        guard FileManager.default.fileExists(atPath: cacheDirectory.path) else { return 0 }
        guard let enumerator = FileManager.default.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }

    func clearCache() throws {
        guard FileManager.default.fileExists(atPath: cacheDirectory.path) else { return }
        try FileManager.default.removeItem(at: cacheDirectory)
    }

    // MARK: - Resource plan

    private nonisolated static func jobs(for request: VectorOfflineDownloadRequest) throws -> [ResourceJob] {
        let root = "https://\(defaultHost)"
        var jobs: [ResourceJob] = [
            try job("\(root)/styles/osm.json", type: .style, status: "OSM style"),
            try job("\(root)/styles/opentopo.json", type: .style, status: "OpenTopo style"),
            try job("\(root)/styles/dark.json", type: .style, status: "Dark style"),
        ]
        let plans = plans(for: request)
        for plan in plans {
            jobs.append(try job("\(root)/\(plan.source)", type: .source, status: plan.source))
        }

        for stack in fontStacks {
            guard let encodedStack = stack.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                continue
            }
            for range in 0..<fontRangeCount {
                let lower = range * 256
                jobs.append(
                    try job(
                        "\(root)/fonts/\(encodedStack)/\(lower)-\(lower + 255).pbf",
                        type: .glyphs,
                        status: stack
                    )
                )
            }
        }

        for variant in ["bright", "dark"] {
            for filename in ["sprite.json", "sprite.png", "sprite@2x.json", "sprite@2x.png"] {
                let type: VectorResourceType = filename.hasSuffix(".json") ? .spriteJSON : .spriteImage
                jobs.append(try job("\(root)/sprites/\(variant)/\(filename)", type: type, status: "sprites/\(variant)"))
            }
        }

        for plan in plans {
            for coordinate in TileCoordinateCalculator.coordinates(
                bounds: request.bounds,
                minimumZoom: plan.minimumZoom,
                maximumZoom: plan.maximumZoom
            ) {
                jobs.append(
                    try job(
                        "\(root)/\(plan.source)/\(coordinate.zoom)/\(coordinate.x)/\(coordinate.y)",
                        type: .tile,
                        status: "\(plan.source) Z\(coordinate.zoom)"
                    )
                )
            }
        }
        return jobs
    }

    private nonisolated static func job(
        _ value: String,
        type: VectorResourceType,
        status: String
    ) throws -> ResourceJob {
        guard let url = URL(string: value) else { throw OfflineMapError.invalidURLTemplate }
        return .init(url: url, resourceType: type, status: status)
    }

    private nonisolated static var defaultCacheDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("MeshHessen", isDirectory: true)
            .appendingPathComponent("VectorTiles", isDirectory: true)
    }

    private struct ResourceJob: Sendable {
        let url: URL
        let resourceType: VectorResourceType
        let status: String
    }
}
