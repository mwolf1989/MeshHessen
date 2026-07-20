import Foundation
import Observation

actor OfflineMapService {
    typealias ProgressHandler = @Sendable (OfflineMapProgress) async -> Void

    private let fileManager: FileManager
    private let packagesDirectory: URL
    private let liveCacheDirectory: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default,
        session: URLSession? = nil
    ) {
        self.fileManager = fileManager
        let base: URL
        if let rootDirectory {
            base = rootDirectory
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            base = applicationSupport
                .appendingPathComponent("MeshHessen", isDirectory: true)
                .appendingPathComponent("Maps", isDirectory: true)
        }
        packagesDirectory = base.appendingPathComponent("OfflinePackages", isDirectory: true)
        liveCacheDirectory = base.appendingPathComponent("TileCache", isDirectory: true)

        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Catalog

    func packages() throws -> [OfflineMapPackage] {
        try ensureDirectories()
        let directories = try fileManager.contentsOfDirectory(
            at: packagesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return directories.compactMap { directory in
            let manifest = directory.appendingPathComponent(OfflineMapPackage.manifestFilename)
            guard let data = try? Data(contentsOf: manifest),
                  let package = try? decoder.decode(OfflineMapPackage.self, from: data),
                  package.formatVersion <= OfflineMapPackage.formatVersion else {
                return nil
            }
            return package
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func packageDirectories() throws -> [URL] {
        try packages().map(packageDirectory(for:))
    }

    func liveTileCacheDirectory() throws -> URL {
        try ensureDirectories()
        return liveCacheDirectory
    }

    func totalSizeBytes() throws -> Int64 {
        try ensureDirectories()
        return try directorySize(packagesDirectory) + directorySize(liveCacheDirectory)
    }

    // MARK: - Download

    func download(
        _ request: OfflineMapDownloadRequest,
        progress: @escaping ProgressHandler
    ) async throws -> OfflineMapPackage {
        guard request.bounds.isValid else { throw OfflineMapError.invalidBounds }
        guard request.minimumZoom >= request.descriptor.minimumZoom,
              request.maximumZoom <= request.descriptor.maximumZoom,
              request.minimumZoom <= request.maximumZoom else {
            throw OfflineMapError.invalidZoomRange
        }
        try MapTilePolicy.ensureBulkDownloadAllowed(for: request.descriptor)

        let coordinates = TileCoordinateCalculator.coordinates(
            bounds: request.bounds,
            minimumZoom: request.minimumZoom,
            maximumZoom: request.maximumZoom
        )
        guard !coordinates.isEmpty else { throw OfflineMapError.invalidBounds }
        guard coordinates.count <= TileCoordinateCalculator.maximumOfflineTileCount else {
            throw OfflineMapError.packageTooLarge(coordinates.count)
        }

        try ensureDirectories()
        let identifier = UUID()
        let stagingDirectory = packagesDirectory
            .appendingPathComponent(".\(identifier.uuidString).download", isDirectory: true)
        let finalDirectory = packagesDirectory
            .appendingPathComponent(identifier.uuidString, isDirectory: true)
        let tilesDirectory = stagingDirectory
            .appendingPathComponent("tiles", isDirectory: true)
            .appendingPathComponent(request.descriptor.source.rawValue, isDirectory: true)

        do {
            try fileManager.createDirectory(at: tilesDirectory, withIntermediateDirectories: true)
            await progress(.init(phase: .preparing, completed: 0, total: coordinates.count, status: request.name))

            var downloaded = 0
            var failures = 0
            var bytes: Int64 = 0
            let batchSize = 6

            for batchStart in stride(from: 0, to: coordinates.count, by: batchSize) {
                try Task.checkCancellation()
                let batchEnd = min(batchStart + batchSize, coordinates.count)
                let batch = coordinates[batchStart..<batchEnd]
                let descriptor = request.descriptor
                let userAgent = MapTilePolicy.userAgent
                let session = session

                let results = await withTaskGroup(of: TileDownloadResult.self) { group in
                    for coordinate in batch {
                        let destination = tilesDirectory
                            .appendingPathComponent(String(coordinate.zoom), isDirectory: true)
                            .appendingPathComponent(String(coordinate.x), isDirectory: true)
                            .appendingPathComponent("\(coordinate.y).\(descriptor.source.fileExtension)")
                        group.addTask {
                            await Self.fetchTile(
                                coordinate: coordinate,
                                descriptor: descriptor,
                                destination: destination,
                                userAgent: userAgent,
                                session: session
                            )
                        }
                    }
                    var values: [TileDownloadResult] = []
                    for await result in group { values.append(result) }
                    return values
                }

                for result in results {
                    if result.succeeded {
                        downloaded += 1
                        bytes += result.byteCount
                    } else {
                        failures += 1
                    }
                }
                let completed = min(batchEnd, coordinates.count)
                await progress(
                    .init(
                        phase: .downloading,
                        completed: completed,
                        total: coordinates.count,
                        status: failures == 0
                            ? "\(completed) / \(coordinates.count)"
                            : "\(completed) / \(coordinates.count) · \(failures) errors"
                    )
                )
            }

            guard downloaded > 0 else {
                throw OfflineMapError.network(String(localized: "No map tile could be downloaded."))
            }

            let package = OfflineMapPackage(
                id: identifier,
                name: request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? request.descriptor.source.localizedName
                    : request.name.trimmingCharacters(in: .whitespacesAndNewlines),
                source: request.descriptor.source,
                bounds: request.bounds,
                minimumZoom: request.minimumZoom,
                maximumZoom: request.maximumZoom,
                tileCount: downloaded,
                byteCount: bytes,
                attribution: request.descriptor.attribution
            )
            _ = try writeManifest(package, in: stagingDirectory)
            try fileManager.moveItem(at: stagingDirectory, to: finalDirectory)
            await progress(.init(phase: .finished, completed: downloaded, total: downloaded, status: package.name))
            return package
        } catch {
            if fileManager.fileExists(atPath: stagingDirectory.path) {
                try? fileManager.removeItem(at: stagingDirectory)
            }
            throw error
        }
    }

    // MARK: - Import / export

    func importPackage(
        from sourceURL: URL,
        progress: @escaping ProgressHandler
    ) async throws -> OfflineMapPackage {
        try ensureDirectories()
        let identifier = UUID()
        let staging = packagesDirectory.appendingPathComponent(".\(identifier.uuidString).import", isDirectory: true)
        let finalDirectory = packagesDirectory.appendingPathComponent(identifier.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            await progress(.init(phase: .importing, completed: 0, total: 1, status: sourceURL.lastPathComponent))
            let values = try sourceURL.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try copyContents(of: sourceURL, to: staging)
            } else {
                _ = try MapZIPArchive.extract(from: sourceURL, to: staging)
            }

            var package = try importedMetadata(in: staging, fallbackName: sourceURL.deletingPathExtension().lastPathComponent)
            package.id = identifier
            package.createdAt = Date()
            package.byteCount = try directorySize(staging)
            try normalizeImportedTiles(in: staging, source: package.source)
            package.tileCount = try countTiles(in: staging, source: package.source)
            guard package.tileCount > 0 else { throw OfflineMapError.noTiles }
            package.byteCount = try directorySize(staging)
            _ = try writeManifest(package, in: staging)
            try fileManager.moveItem(at: staging, to: finalDirectory)
            await progress(.init(phase: .finished, completed: 1, total: 1, status: package.name))
            return package
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    func exportPackage(
        _ package: OfflineMapPackage,
        to destination: URL,
        progress: @escaping ProgressHandler
    ) async throws {
        let source = packageDirectory(for: package)
        guard fileManager.fileExists(atPath: source.path) else {
            throw OfflineMapError.packageNotFound
        }
        await progress(.init(phase: .exporting, completed: 0, total: 1, status: package.name))
        try MapZIPArchive.create(from: source, at: destination)
        await progress(.init(phase: .finished, completed: 1, total: 1, status: destination.lastPathComponent))
    }

    func deletePackage(_ package: OfflineMapPackage) throws {
        let directory = packageDirectory(for: package)
        guard directory.deletingLastPathComponent().standardizedFileURL == packagesDirectory.standardizedFileURL,
              fileManager.fileExists(atPath: directory.path) else {
            throw OfflineMapError.packageNotFound
        }
        try fileManager.removeItem(at: directory)
    }

    func clearLiveCache() throws {
        try ensureDirectories()
        if fileManager.fileExists(atPath: liveCacheDirectory.path) {
            try fileManager.removeItem(at: liveCacheDirectory)
        }
        try fileManager.createDirectory(at: liveCacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Private

    private struct TileDownloadResult: Sendable {
        let succeeded: Bool
        let byteCount: Int64
    }

    private nonisolated static func fetchTile(
        coordinate: MapTileCoordinate,
        descriptor: MapTileSourceDescriptor,
        destination: URL,
        userAgent: String,
        session: URLSession
    ) async -> TileDownloadResult {
        do {
            try Task.checkCancellation()
            let url = try MapTilePolicy.resolvedURL(template: descriptor.urlTemplate, coordinate: coordinate)
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("image/avif,image/webp,image/png,image/*;q=0.8", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  !data.isEmpty else {
                return .init(succeeded: false, byteCount: 0)
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            return .init(succeeded: true, byteCount: Int64(data.count))
        } catch {
            return .init(succeeded: false, byteCount: 0)
        }
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: packagesDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: liveCacheDirectory, withIntermediateDirectories: true)
    }

    private func packageDirectory(for package: OfflineMapPackage) -> URL {
        packagesDirectory.appendingPathComponent(package.id.uuidString, isDirectory: true)
    }

    @discardableResult
    private func writeManifest(_ package: OfflineMapPackage, in directory: URL) throws -> Int {
        let data = try encoder.encode(package)
        try data.write(
            to: directory.appendingPathComponent(OfflineMapPackage.manifestFilename),
            options: .atomic
        )
        return data.count
    }

    private func directorySize(_ directory: URL) throws -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var result: Int64 = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                result += Int64(values.fileSize ?? 0)
            }
        }
        return result
    }

    private func copyContents(of source: URL, to destination: URL) throws {
        for item in try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            try fileManager.copyItem(at: item, to: destination.appendingPathComponent(item.lastPathComponent))
        }
    }

    private func importedMetadata(in directory: URL, fallbackName: String) throws -> OfflineMapPackage {
        let manifestURLs = try recursiveFiles(in: directory).filter {
            $0.lastPathComponent == OfflineMapPackage.manifestFilename
        }
        if let manifest = manifestURLs.first,
           let package = try? decoder.decode(OfflineMapPackage.self, from: Data(contentsOf: manifest)) {
            if manifest.deletingLastPathComponent() != directory {
                let nestedRoot = manifest.deletingLastPathComponent()
                let temporary = directory.appendingPathComponent(".flatten", isDirectory: true)
                try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
                try copyContents(of: nestedRoot, to: temporary)
                for item in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                    if item != temporary { try fileManager.removeItem(at: item) }
                }
                try copyContents(of: temporary, to: directory)
                try fileManager.removeItem(at: temporary)
            }
            return package
        }

        let tileFiles = try recursiveFiles(in: directory).filter { $0.pathExtension.lowercased() == "png" }
        guard !tileFiles.isEmpty else { throw OfflineMapError.noTiles }
        let detectedSource = try detectSource(in: tileFiles)
        let coordinates = tileFiles.compactMap(parseTileCoordinate)
        guard let bounds = TileCoordinateCalculator.bounds(containing: coordinates),
              let minimumZoom = coordinates.map(\.zoom).min(),
              let maximumZoom = coordinates.map(\.zoom).max() else {
            throw OfflineMapError.invalidPackage
        }
        return OfflineMapPackage(
            name: fallbackName.isEmpty ? detectedSource.localizedName : fallbackName,
            source: detectedSource,
            bounds: bounds,
            minimumZoom: minimumZoom,
            maximumZoom: maximumZoom,
            tileCount: tileFiles.count,
            attribution: MapTileSourceDescriptor.defaultAttribution(for: detectedSource)
        )
    }

    private func normalizeImportedTiles(in directory: URL, source: MapTileSource) throws {
        let expected = directory
            .appendingPathComponent("tiles", isDirectory: true)
            .appendingPathComponent(source.rawValue, isDirectory: true)
        if fileManager.fileExists(atPath: expected.path) { return }

        let candidates = [
            directory.appendingPathComponent(source.rawValue, isDirectory: true),
            directory.appendingPathComponent("maptiles", isDirectory: true)
                .appendingPathComponent(source.rawValue, isDirectory: true),
        ]
        guard let existing = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            throw OfflineMapError.invalidPackage
        }
        try fileManager.createDirectory(at: expected.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: existing, to: expected)
    }

    private func countTiles(in directory: URL, source: MapTileSource) throws -> Int {
        let tileDirectory = directory
            .appendingPathComponent("tiles", isDirectory: true)
            .appendingPathComponent(source.rawValue, isDirectory: true)
        return try recursiveFiles(in: tileDirectory).filter {
            $0.pathExtension.lowercased() == source.fileExtension
        }.count
    }

    private func recursiveFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [URL] = []
        for case let file as URL in enumerator {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result.append(file)
            }
        }
        return result
    }

    private func detectSource(in files: [URL]) throws -> MapTileSource {
        for file in files {
            let components = Set(file.pathComponents.map { $0.lowercased() })
            if components.contains(MapTileSource.osm.rawValue) { return .osm }
            if components.contains(MapTileSource.topographic.rawValue) { return .topographic }
            if components.contains(MapTileSource.dark.rawValue) { return .dark }
        }
        throw OfflineMapError.invalidPackage
    }

    private func parseTileCoordinate(from file: URL) -> MapTileCoordinate? {
        let components = file.deletingPathExtension().pathComponents
        guard components.count >= 3,
              let y = Int(components[components.count - 1]),
              let x = Int(components[components.count - 2]),
              let zoom = Int(components[components.count - 3]) else { return nil }
        return .init(x: x, y: y, zoom: zoom)
    }
}

@Observable
@MainActor
final class OfflineMapManager {
    private let service: OfflineMapService
    private let vectorDownloader: VectorOfflinePackageDownloaderService
    private var activeTask: Task<Void, Never>?

    private(set) var packages: [OfflineMapPackage] = []
    private(set) var packageDirectories: [URL] = []
    private(set) var liveCacheDirectory: URL?
    private(set) var totalSizeBytes: Int64 = 0
    private(set) var progress: OfflineMapProgress?
    private(set) var isWorking = false
    var errorMessage: String?

    init(
        service: OfflineMapService = OfflineMapService(),
        vectorDownloader: VectorOfflinePackageDownloaderService = VectorOfflinePackageDownloaderService()
    ) {
        self.service = service
        self.vectorDownloader = vectorDownloader
    }

    var totalSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: totalSizeBytes, countStyle: .file)
    }

    func refresh() async {
        do {
            async let packages = service.packages()
            async let directories = service.packageDirectories()
            async let cache = service.liveTileCacheDirectory()
            async let size = service.totalSizeBytes()
            async let vectorSize = vectorDownloader.storageSizeBytes()
            let values = try await (packages, directories, cache, size, vectorSize)
            self.packages = values.0
            packageDirectories = values.1
            liveCacheDirectory = values.2
            totalSizeBytes = values.3 + values.4
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func beginDownload(_ request: OfflineMapDownloadRequest) {
        guard !isWorking else { return }
        startOperation {
            _ = try await self.service.download(request) { update in
                await self.setProgress(update)
            }
        }
    }

    func beginVectorDownload(_ request: VectorOfflineDownloadRequest) {
        guard !isWorking else { return }
        startOperation {
            _ = try await self.vectorDownloader.download(request) { update in
                await self.setProgress(update)
            }
        }
    }

    func beginImport(from url: URL) {
        guard !isWorking else { return }
        startOperation {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            _ = try await self.service.importPackage(from: url) { update in
                await self.setProgress(update)
            }
        }
    }

    func beginExport(_ package: OfflineMapPackage, to url: URL) {
        guard !isWorking else { return }
        startOperation {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            try await self.service.exportPackage(package, to: url) { update in
                await self.setProgress(update)
            }
        }
    }

    func delete(_ package: OfflineMapPackage) async {
        do {
            try await service.deletePackage(package)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearLiveCache() async {
        do {
            try await service.clearLiveCache()
            try await vectorDownloader.clearCache()
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancel() {
        activeTask?.cancel()
    }

    private func startOperation(_ operation: @escaping @MainActor () async throws -> Void) {
        errorMessage = nil
        isWorking = true
        activeTask = Task {
            defer {
                isWorking = false
                activeTask = nil
            }
            do {
                try await operation()
                await refresh()
            } catch is CancellationError {
                progress = .init(phase: .finished, completed: 0, total: 1, status: String(localized: "Cancelled"))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func setProgress(_ update: OfflineMapProgress) {
        progress = update
    }
}
