import Foundation

actor TDeckTileService {
    enum ServiceError: LocalizedError, Equatable {
        case invalidBounds
        case invalidZoomRange
        case invalidDestination
        case publicTileServerDisallowsBulkDownload
        case invalidTileResponse(Int)
        case noCachedTiles
        case zipEntryTooLarge

        var errorDescription: String? {
            switch self {
            case .invalidBounds:
                return String(localized: "The selected map region is invalid.")
            case .invalidZoomRange:
                return String(localized: "The zoom range must be between 1 and 17.")
            case .invalidDestination:
                return String(localized: "Select a writable SD-card folder.")
            case .publicTileServerDisallowsBulkDownload:
                return String(localized: "Bulk downloading from public OSM/OpenTopoMap servers is not allowed by their tile usage policy.")
            case .invalidTileResponse(let statusCode):
                return String(localized: "The tile server returned HTTP status \(statusCode).")
            case .noCachedTiles:
                return String(localized: "No cached map tiles are available for export.")
            case .zipEntryTooLarge:
                return String(localized: "A cached tile is too large for the ZIP export.")
            }
        }
    }

    nonisolated static let shared = TDeckTileService()
    nonisolated static let averageTileSizeBytes: Int64 = 15_000

    nonisolated static func tileCoordinate(latitude: Double, longitude: Double, zoom: Int) -> TDeckTileCoordinate {
        let safeLatitude = min(85.05112878, max(-85.05112878, latitude))
        let worldSize = pow(2, Double(zoom))
        let x = Int(floor((longitude + 180) / 360 * worldSize))
        let latitudeRadians = safeLatitude * .pi / 180
        let y = Int(floor(
            (1 - log(tan(latitudeRadians) + 1 / cos(latitudeRadians)) / .pi)
                / 2 * worldSize
        ))
        let maximumIndex = max(0, Int(worldSize) - 1)
        return TDeckTileCoordinate(
            zoom: zoom,
            x: min(maximumIndex, max(0, x)),
            y: min(maximumIndex, max(0, y))
        )
    }

    nonisolated static func tileRange(bounds: TDeckBounds, zoom: Int) -> (x: ClosedRange<Int>, y: ClosedRange<Int>) {
        let northWest = tileCoordinate(latitude: bounds.north, longitude: bounds.west, zoom: zoom)
        let southEast = tileCoordinate(latitude: bounds.south, longitude: bounds.east, zoom: zoom)
        return (
            min(northWest.x, southEast.x)...max(northWest.x, southEast.x),
            min(northWest.y, southEast.y)...max(northWest.y, southEast.y)
        )
    }

    nonisolated static func estimatedTileCount(
        bounds: TDeckBounds,
        minimumZoom: Int = 1,
        maximumZoom: Int
    ) -> Int {
        guard bounds.isValid, minimumZoom >= 0, maximumZoom >= minimumZoom else { return 0 }
        var result = 0
        for zoom in minimumZoom...maximumZoom {
            let range = tileRange(bounds: bounds, zoom: zoom)
            let xCount = range.x.upperBound - range.x.lowerBound + 1
            let yCount = range.y.upperBound - range.y.lowerBound + 1
            let (tileCount, overflowed) = xCount.multipliedReportingOverflow(by: yCount)
            let (newResult, sumOverflowed) = result.addingReportingOverflow(tileCount)
            if overflowed || sumOverflowed { return Int.max }
            result = newResult
        }
        return result
    }

    nonisolated static func estimatedSizeBytes(tileCount: Int) -> Int64 {
        guard tileCount > 0 else { return 0 }
        let (bytes, overflowed) = Int64(tileCount).multipliedReportingOverflow(by: averageTileSizeBytes)
        return overflowed ? Int64.max : bytes
    }

    nonisolated static func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: bytes)
    }

    nonisolated static func isPublicTileServer(_ template: String) -> Bool {
        MapTilePolicy.isPublicTileServer(template)
    }

    nonisolated static func tileURL(template: String, tile: TDeckTileCoordinate) -> URL? {
        URL(string: template
            .replacingOccurrences(of: "{z}", with: String(tile.zoom))
            .replacingOccurrences(of: "{x}", with: String(tile.x))
            .replacingOccurrences(of: "{y}", with: String(tile.y)))
    }

    nonisolated static func sdTileURL(
        root: URL,
        source: TDeckMapSource,
        tile: TDeckTileCoordinate
    ) -> URL {
        root
            .appendingPathComponent("maps", isDirectory: true)
            .appendingPathComponent(source.sdCardFolderName, isDirectory: true)
            .appendingPathComponent(String(tile.zoom), isDirectory: true)
            .appendingPathComponent(String(tile.x), isDirectory: true)
            .appendingPathComponent("\(tile.y).png", isDirectory: false)
    }

    nonisolated static func cacheTileURL(
        root: URL,
        source: TDeckMapSource,
        tile: TDeckTileCoordinate
    ) -> URL {
        root
            .appendingPathComponent(source.cacheFolderName, isDirectory: true)
            .appendingPathComponent(String(tile.zoom), isDirectory: true)
            .appendingPathComponent(String(tile.x), isDirectory: true)
            .appendingPathComponent("\(tile.y).png", isDirectory: false)
    }

    nonisolated static func defaultCacheRoot(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("MeshHessen", isDirectory: true)
            .appendingPathComponent("maptiles", isDirectory: true)
    }

    nonisolated static func volumeInfo(
        at url: URL,
        fileManager: FileManager = .default
    ) -> TDeckVolumeInfo? {
        let resolvedURL = url.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeLocalizedFormatDescriptionKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsReadOnlyKey,
        ]
        guard let values = try? resolvedURL.resourceValues(forKeys: keys) else { return nil }

        let fallbackName = resolvedURL.lastPathComponent.isEmpty
            ? String(localized: "Selected volume")
            : resolvedURL.lastPathComponent
        let name = values.volumeName ?? fallbackName
        return TDeckVolumeInfo(
            name: name,
            formatDescription: values.volumeLocalizedFormatDescription ?? String(localized: "Unknown"),
            totalBytes: values.volumeTotalCapacity.map(Int64.init),
            availableBytes: values.volumeAvailableCapacityForImportantUsage,
            isReadOnly: values.volumeIsReadOnly ?? !fileManager.isWritableFile(atPath: resolvedURL.path)
        )
    }

    func transferTiles(
        source: TDeckMapSource,
        bounds: TDeckBounds,
        maximumZoom: Int,
        destinationRoot: URL,
        cacheRoot: URL = TDeckTileService.defaultCacheRoot(),
        urlTemplate: String? = nil,
        progress: @escaping @Sendable (TDeckTransferProgress) async -> Void
    ) async throws {
        guard bounds.isValid else { throw ServiceError.invalidBounds }
        guard (1...17).contains(maximumZoom) else { throw ServiceError.invalidZoomRange }
        try Self.validateDestination(destinationRoot)

        let template = urlTemplate ?? source.urlTemplate()
        try MapTilePolicy.validateTemplate(template)
        guard !Self.isPublicTileServer(template) else {
            throw ServiceError.publicTileServerDisallowsBulkDownload
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let total = Self.estimatedTileCount(bounds: bounds, maximumZoom: maximumZoom)
        var completed = 0

        for zoom in 1...maximumZoom {
            let ranges = Self.tileRange(bounds: bounds, zoom: zoom)
            for x in ranges.x {
                for y in ranges.y {
                    try Task.checkCancellation()
                    let tile = TDeckTileCoordinate(zoom: zoom, x: x, y: y)
                    let destination = Self.sdTileURL(root: destinationRoot, source: source, tile: tile)
                    let cache = Self.cacheTileURL(root: cacheRoot, source: source, tile: tile)
                    let transferSource: TDeckTransferProgress.Source

                    if fileManager.fileExists(atPath: destination.path) {
                        transferSource = .alreadyOnCard
                    } else if fileManager.fileExists(atPath: cache.path) {
                        try fileManager.createDirectory(
                            at: destination.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try fileManager.copyItem(at: cache, to: destination)
                        transferSource = .localCache
                    } else {
                        do {
                            guard let url = Self.tileURL(template: template, tile: tile) else {
                                throw URLError(.badURL)
                            }
                            var request = URLRequest(url: url)
                            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
                            let (data, response) = try await URLSession.shared.data(for: request)
                            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                            guard (200...299).contains(statusCode), !data.isEmpty else {
                                throw ServiceError.invalidTileResponse(statusCode)
                            }

                            try fileManager.createDirectory(
                                at: destination.deletingLastPathComponent(),
                                withIntermediateDirectories: true
                            )
                            try fileManager.createDirectory(
                                at: cache.deletingLastPathComponent(),
                                withIntermediateDirectories: true
                            )
                            try data.write(to: cache, options: .atomic)
                            try data.write(to: destination, options: .atomic)
                            transferSource = .downloaded
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            transferSource = .failed
                            AppLogger.shared.log(
                                "[TDeck] Tile Z\(zoom) X\(x) Y\(y) failed: \(error.localizedDescription)"
                            )
                        }
                    }

                    completed += 1
                    await progress(
                        TDeckTransferProgress(
                            completed: completed,
                            total: total,
                            tile: tile,
                            source: transferSource
                        )
                    )
                }
            }
        }
    }

    func exportCachedTiles(
        to outputURL: URL,
        sourceFilter: TDeckMapSource? = nil,
        cacheRoot: URL = TDeckTileService.defaultCacheRoot(),
        progress: @escaping @Sendable (_ completed: Int, _ total: Int, _ entry: String) async -> Void
    ) async throws {
        let sources = sourceFilter.map { [$0] } ?? TDeckMapSource.allCases
        let files = Self.cachedTileFiles(sources: sources, cacheRoot: cacheRoot)

        guard !files.isEmpty else { throw ServiceError.noCachedTiles }
        try await TDeckZipWriter.write(files: files, to: outputURL, progress: progress)
    }

    private nonisolated static func cachedTileFiles(
        sources: [TDeckMapSource],
        cacheRoot: URL,
        fileManager: FileManager = .default
    ) -> [(url: URL, entry: String)] {
        var files: [(url: URL, entry: String)] = []
        for source in sources {
            let directory = cacheRoot.appendingPathComponent(source.cacheFolderName, isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "png" {
                let relativePath = fileURL.path.dropFirst(cacheRoot.path.count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                files.append((fileURL, relativePath))
            }
        }
        return files
    }

    private nonisolated static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        return "MeshHessen/\(version) (T-Deck tile assistant)"
    }

    private nonisolated static func validateDestination(_ url: URL) throws {
        let standardized = url.standardizedFileURL
        guard standardized.isFileURL,
              standardized.path != "/",
              standardized.path != FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        else { throw ServiceError.invalidDestination }
    }
}

private enum TDeckZipWriter {
    private struct CentralEntry {
        let name: Data
        let crc32: UInt32
        let size: UInt32
        let localHeaderOffset: UInt32
    }

    static func write(
        files: [(url: URL, entry: String)],
        to outputURL: URL,
        progress: @escaping @Sendable (Int, Int, String) async -> Void
    ) async throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        guard fileManager.createFile(atPath: outputURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let handle = try FileHandle(forWritingTo: outputURL)
        var entries: [CentralEntry] = []
        do {
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                let contents = try Data(contentsOf: file.url, options: .mappedIfSafe)
                guard contents.count <= Int(UInt32.max) else {
                    throw TDeckTileService.ServiceError.zipEntryTooLarge
                }

                let name = Data(file.entry.utf8)
                let crc = crc32(contents)
                let offset = handle.offsetInFile
                guard offset <= UInt64(UInt32.max) else {
                    throw TDeckTileService.ServiceError.zipEntryTooLarge
                }

                var localHeader = Data()
                localHeader.appendLittleEndian(UInt32(0x04034B50))
                localHeader.appendLittleEndian(UInt16(20))
                localHeader.appendLittleEndian(UInt16(0x0800))
                localHeader.appendLittleEndian(UInt16(0))
                localHeader.appendLittleEndian(UInt16(0))
                localHeader.appendLittleEndian(UInt16(0))
                localHeader.appendLittleEndian(crc)
                localHeader.appendLittleEndian(UInt32(contents.count))
                localHeader.appendLittleEndian(UInt32(contents.count))
                localHeader.appendLittleEndian(UInt16(clamping: name.count))
                localHeader.appendLittleEndian(UInt16(0))
                localHeader.append(name)
                try handle.write(contentsOf: localHeader)
                try handle.write(contentsOf: contents)

                entries.append(
                    CentralEntry(
                        name: name,
                        crc32: crc,
                        size: UInt32(contents.count),
                        localHeaderOffset: UInt32(offset)
                    )
                )
                await progress(index + 1, files.count, file.entry)
            }

            let centralDirectoryOffset = handle.offsetInFile
            for entry in entries {
                var centralHeader = Data()
                centralHeader.appendLittleEndian(UInt32(0x02014B50))
                centralHeader.appendLittleEndian(UInt16(20))
                centralHeader.appendLittleEndian(UInt16(20))
                centralHeader.appendLittleEndian(UInt16(0x0800))
                centralHeader.appendLittleEndian(UInt16(0))
                centralHeader.appendLittleEndian(UInt16(0))
                centralHeader.appendLittleEndian(UInt16(0))
                centralHeader.appendLittleEndian(entry.crc32)
                centralHeader.appendLittleEndian(entry.size)
                centralHeader.appendLittleEndian(entry.size)
                centralHeader.appendLittleEndian(UInt16(clamping: entry.name.count))
                centralHeader.appendLittleEndian(UInt16(0))
                centralHeader.appendLittleEndian(UInt16(0))
                centralHeader.appendLittleEndian(UInt16(0))
                centralHeader.appendLittleEndian(UInt16(0))
                centralHeader.appendLittleEndian(UInt32(0))
                centralHeader.appendLittleEndian(entry.localHeaderOffset)
                centralHeader.append(entry.name)
                try handle.write(contentsOf: centralHeader)
            }

            let centralDirectoryEnd = handle.offsetInFile
            let centralSize = centralDirectoryEnd - centralDirectoryOffset
            guard centralDirectoryOffset <= UInt64(UInt32.max),
                  centralSize <= UInt64(UInt32.max),
                  entries.count <= UInt16.max else {
                throw TDeckTileService.ServiceError.zipEntryTooLarge
            }

            var endRecord = Data()
            endRecord.appendLittleEndian(UInt32(0x06054B50))
            endRecord.appendLittleEndian(UInt16(0))
            endRecord.appendLittleEndian(UInt16(0))
            endRecord.appendLittleEndian(UInt16(entries.count))
            endRecord.appendLittleEndian(UInt16(entries.count))
            endRecord.appendLittleEndian(UInt32(centralSize))
            endRecord.appendLittleEndian(UInt32(centralDirectoryOffset))
            endRecord.appendLittleEndian(UInt16(0))
            try handle.write(contentsOf: endRecord)
            try handle.close()
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: outputURL)
            throw error
        }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            var value = (crc ^ UInt32(byte)) & 0xFF
            for _ in 0..<8 {
                value = value & 1 == 1 ? (value >> 1) ^ 0xEDB88320 : value >> 1
            }
            crc = (crc >> 8) ^ value
        }
        return crc ^ UInt32.max
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
