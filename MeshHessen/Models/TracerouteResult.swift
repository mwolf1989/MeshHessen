import Foundation
import Observation

func localizedHopCount(_ count: Int) -> String {
    if count == 1 {
        return String(localized: "1 hop")
    }
    return String(localized: "\(count) hops")
}

// MARK: - Result Models

/// Represents the result of a traceroute operation.
struct TracerouteResult: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let requestId: UInt32?
    let requestTime: Date
    let sourceNodeId: UInt32?
    let sourceLatitude: Double?
    let sourceLongitude: Double?
    let targetNodeId: UInt32
    let targetName: String
    let hops: [TracerouteHop]
    var responseTime: Date?

    /// The best available timestamp for history filtering and presentation.
    var receivedAt: Date {
        responseTime ?? requestTime
    }

    /// Total round-trip time in milliseconds.
    var roundTripMs: Int? {
        guard let responseTime else { return nil }
        return max(0, Int(responseTime.timeIntervalSince(requestTime) * 1_000))
    }

    /// A direction-independent key matching the Windows client's node-pair deduplication.
    var nodePair: TracerouteNodePair {
        TracerouteNodePair(sourceNodeId ?? 0, targetNodeId)
    }

    var containsMqttHop: Bool {
        hops.contains(where: \.viaMqtt)
    }

    var routeDescription: String {
        guard !hops.isEmpty else { return String(localized: "Direct") }
        return hops.map(\.nodeName).joined(separator: " → ")
    }

    init(
        id: UUID = UUID(),
        requestId: UInt32? = nil,
        requestTime: Date = Date(),
        sourceNodeId: UInt32? = nil,
        sourceLatitude: Double? = nil,
        sourceLongitude: Double? = nil,
        targetNodeId: UInt32,
        targetName: String,
        hops: [TracerouteHop] = [],
        responseTime: Date? = nil
    ) {
        self.id = id
        self.requestId = requestId
        self.requestTime = requestTime
        self.sourceNodeId = sourceNodeId
        self.sourceLatitude = sourceLatitude
        self.sourceLongitude = sourceLongitude
        self.targetNodeId = targetNodeId
        self.targetName = targetName
        self.hops = hops
        self.responseTime = responseTime
    }

    /// Returns the distance from this hop to the following hop, if both positions are known.
    func distanceToNextHop(after index: Int) -> Double? {
        guard hops.indices.contains(index) else { return nil }
        if let storedDistance = hops[index].distanceToNext {
            return storedDistance
        }
        let nextIndex = index + 1
        guard hops.indices.contains(nextIndex) else { return nil }
        return hops[index].distance(to: hops[nextIndex])
    }
}

/// A single hop in a traceroute.
struct TracerouteHop: Identifiable, Codable, Equatable, Sendable {
    /// Firmware sentinel used when the hop count is known but the relaying node is not.
    static let unknownNodeId = UInt32.max

    let id: UUID
    let nodeId: UInt32
    let nodeName: String
    let snr: Float?
    let latitude: Double?
    let longitude: Double?
    let viaMqtt: Bool

    /// Optional persisted distance to the next hop in metres.
    var distanceToNext: Double?

    var isUnknown: Bool {
        nodeId == Self.unknownNodeId
    }

    init(
        id: UUID = UUID(),
        nodeId: UInt32,
        nodeName: String,
        snr: Float? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        viaMqtt: Bool = false,
        distanceToNext: Double? = nil
    ) {
        self.id = id
        self.nodeId = nodeId
        self.nodeName = nodeName
        self.snr = snr
        self.latitude = latitude
        self.longitude = longitude
        self.viaMqtt = viaMqtt
        self.distanceToNext = distanceToNext
    }

    /// Decodes the firmware's quarter-dB SNR representation while preserving its unknown sentinel.
    static func decodedSNR(_ encodedSNR: Int32?) -> Float? {
        guard let encodedSNR, encodedSNR != Int32(Int8.min) else { return nil }
        return Float(encodedSNR) / 4.0
    }

    /// Uses the position captured with the trace, then falls back to a more recently resolved position.
    func resolvedPosition(
        fallbackLatitude: Double?,
        fallbackLongitude: Double?
    ) -> (latitude: Double, longitude: Double)? {
        guard !isUnknown else { return nil }
        if let latitude, let longitude {
            return (latitude, longitude)
        }
        guard let fallbackLatitude, let fallbackLongitude else { return nil }
        return (fallbackLatitude, fallbackLongitude)
    }

    /// Great-circle distance to another positioned hop in metres.
    func distance(to other: TracerouteHop) -> Double? {
        guard let latitude,
              let longitude,
              let otherLatitude = other.latitude,
              let otherLongitude = other.longitude
        else { return nil }

        let earthRadius = 6_371_000.0
        let latitude1 = latitude * .pi / 180
        let latitude2 = otherLatitude * .pi / 180
        let latitudeDelta = (otherLatitude - latitude) * .pi / 180
        let longitudeDelta = (otherLongitude - longitude) * .pi / 180
        let a = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(latitude1) * cos(latitude2)
            * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

// MARK: - History Query

/// Supported traceroute-history periods, matching the Windows client.
enum TracerouteHistoryPeriod: String, CaseIterable, Codable, Identifiable, Sendable {
    case last3Days
    case last7Days
    case last14Days
    case last30Days
    case last90Days
    case all

    var id: String { rawValue }

    var dayCount: Int? {
        switch self {
        case .last3Days: 3
        case .last7Days: 7
        case .last14Days: 14
        case .last30Days: 30
        case .last90Days: 90
        case .all: nil
        }
    }

    var title: String {
        switch self {
        case .last3Days: String(localized: "3 days")
        case .last7Days: String(localized: "7 days")
        case .last14Days: String(localized: "14 days")
        case .last30Days: String(localized: "30 days")
        case .last90Days: String(localized: "90 days")
        case .all: String(localized: "All")
        }
    }
}

/// A direction-independent source/destination pair.
struct TracerouteNodePair: Hashable, Codable, Sendable {
    let lowerNodeId: UInt32
    let upperNodeId: UInt32

    init(_ firstNodeId: UInt32, _ secondNodeId: UInt32) {
        lowerNodeId = min(firstNodeId, secondNodeId)
        upperNodeId = max(firstNodeId, secondNodeId)
    }
}

/// Applies period and optional newest-per-node-pair filtering in a deterministic order.
struct TracerouteHistoryQuery: Equatable, Sendable {
    var period: TracerouteHistoryPeriod = .last7Days
    var newestPerNodePair = false

    func apply(to results: [TracerouteResult], now: Date = Date()) -> [TracerouteResult] {
        let cutoff = period.dayCount.map { days in
            now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
        }
        let sorted = results
            .filter { result in
                guard let cutoff else { return true }
                return result.receivedAt >= cutoff
            }
            .sorted {
                if $0.receivedAt != $1.receivedAt {
                    return $0.receivedAt > $1.receivedAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }

        guard newestPerNodePair else { return sorted }
        var seenPairs = Set<TracerouteNodePair>()
        return sorted.filter { seenPairs.insert($0.nodePair).inserted }
    }
}

/// Value-type selection that can be resolved against live or persisted results.
struct TracerouteSelection: Equatable, Sendable {
    private(set) var resultIDs: Set<UUID> = []

    var isEmpty: Bool { resultIDs.isEmpty }
    var count: Int { resultIDs.count }

    func contains(_ result: TracerouteResult) -> Bool {
        resultIDs.contains(result.id)
    }

    mutating func setSelected(_ selected: Bool, result: TracerouteResult) {
        if selected {
            resultIDs.insert(result.id)
        } else {
            resultIDs.remove(result.id)
        }
    }

    mutating func removeAll() {
        resultIDs.removeAll()
    }

    mutating func remove(ids: some Sequence<UUID>) {
        resultIDs.subtract(ids)
    }

    func resolve(in results: [TracerouteResult]) -> [TracerouteResult] {
        results.filter { resultIDs.contains($0.id) }
    }
}

/// Shared in-memory selection prepared for map integration without coupling history UI to MapView.
@Observable
@MainActor
final class TracerouteMapSelectionStore {
    static let shared = TracerouteMapSelectionStore()

    private(set) var results: [TracerouteResult] = []

    private init() {}

    func replace(with results: [TracerouteResult]) {
        self.results = results
    }

    func remove(ids: some Sequence<UUID>) {
        let ids = Set(ids)
        results.removeAll { ids.contains($0.id) }
    }

    func clear() {
        results.removeAll()
    }
}

// MARK: - Persistence

struct TracerouteLoadFailure: Equatable, Sendable {
    let fileURL: URL
    let message: String
}

struct TracerouteLoadReport: Equatable, Sendable {
    let results: [TracerouteResult]
    let failures: [TracerouteLoadFailure]
}

enum TracerouteStoreError: LocalizedError {
    case directoryUnavailable(URL, String)
    case readFailed(URL, String)
    case invalidDocument(URL?, String)
    case writeFailed(URL, String)
    case deleteFailed(URL, String)
    case emptyExport

    var errorDescription: String? {
        switch self {
        case .directoryUnavailable(let url, let message):
            String(localized: "Traceroute storage is unavailable at \(url.path): \(message)")
        case .readFailed(let url, let message):
            String(localized: "Could not read \(url.lastPathComponent): \(message)")
        case .invalidDocument(let url, let message):
            String(localized: "Invalid traceroute file \(url?.lastPathComponent ?? "JSON"): \(message)")
        case .writeFailed(let url, let message):
            String(localized: "Could not save \(url.lastPathComponent): \(message)")
        case .deleteFailed(let url, let message):
            String(localized: "Could not delete \(url.lastPathComponent): \(message)")
        case .emptyExport:
            String(localized: "Select at least one traceroute to export.")
        }
    }
}

/// Manages traceroute-result persistence and JSON interoperability.
final class TracerouteStore: @unchecked Sendable {
    static let shared = TracerouteStore()

    let storageDirectory: URL

    private let fileManager: FileManager
    private let lock = NSLock()

    init(storageDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let storageDirectory {
            self.storageDirectory = storageDirectory
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.storageDirectory = appSupport
                .appendingPathComponent("MeshHessen", isDirectory: true)
                .appendingPathComponent("traceroutes", isDirectory: true)
        }

        do {
            try ensureStorageDirectory()
        } catch {
            AppLogger.shared.log("[TracerouteStore] \(error.localizedDescription)")
        }
    }

    /// Compatibility API for protocol callers. Errors are logged and remain available through `persist`.
    func save(_ result: TracerouteResult) {
        do {
            try persist(result)
        } catch {
            AppLogger.shared.log("[TracerouteStore] Save failed: \(error.localizedDescription)")
        }
    }

    func persist(_ result: TracerouteResult) throws {
        let fileURL = storageURL(for: result.id)
        let data: Data
        do {
            data = try Self.makeEncoder(prettyPrinted: true).encode(result)
        } catch {
            throw TracerouteStoreError.writeFailed(fileURL, error.localizedDescription)
        }

        do {
            try withLock {
                try ensureStorageDirectory()
                try data.write(to: fileURL, options: .atomic)
            }
        } catch let error as TracerouteStoreError {
            throw error
        } catch {
            throw TracerouteStoreError.writeFailed(fileURL, error.localizedDescription)
        }
        NotificationCenter.default.post(name: .tracerouteStoreDidChange, object: self)
    }

    func persist(_ results: [TracerouteResult]) throws {
        let encoded = try results.map { result -> (URL, Data) in
            let url = storageURL(for: result.id)
            do {
                return (url, try Self.makeEncoder(prettyPrinted: true).encode(result))
            } catch {
                throw TracerouteStoreError.writeFailed(url, error.localizedDescription)
            }
        }

        do {
            try withLock {
                try ensureStorageDirectory()
                for (url, data) in encoded {
                    try data.write(to: url, options: .atomic)
                }
            }
        } catch let error as TracerouteStoreError {
            throw error
        } catch {
            throw TracerouteStoreError.writeFailed(storageDirectory, error.localizedDescription)
        }
        NotificationCenter.default.post(name: .tracerouteStoreDidChange, object: self)
    }

    /// Compatibility API returning all valid results while isolating malformed files.
    func loadAll() -> [TracerouteResult] {
        loadReport().results
    }

    /// Loads every supported JSON file and reports corrupt files without discarding valid history.
    func loadReport() -> TracerouteLoadReport {
        do {
            return try withLock {
                try ensureStorageDirectory()
                let urls = try fileManager.contentsOfDirectory(
                    at: storageDirectory,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
                var resultsByID: [UUID: TracerouteResult] = [:]
                var failures: [TracerouteLoadFailure] = []

                for url in urls where url.pathExtension.lowercased() == "json" {
                    do {
                        let data = try Data(contentsOf: url)
                        let decoded = try Self.decodeResults(from: data, sourceURL: url)
                        for result in decoded {
                            if let existing = resultsByID[result.id], existing.receivedAt > result.receivedAt {
                                continue
                            }
                            resultsByID[result.id] = result
                        }
                    } catch {
                        failures.append(.init(fileURL: url, message: error.localizedDescription))
                    }
                }

                let results = resultsByID.values.sorted {
                    if $0.receivedAt != $1.receivedAt { return $0.receivedAt > $1.receivedAt }
                    return $0.id.uuidString < $1.id.uuidString
                }
                return TracerouteLoadReport(results: results, failures: failures)
            }
        } catch {
            return TracerouteLoadReport(
                results: [],
                failures: [.init(fileURL: storageDirectory, message: error.localizedDescription)]
            )
        }
    }

    func delete(_ result: TracerouteResult) {
        do {
            try delete(ids: [result.id])
        } catch {
            AppLogger.shared.log("[TracerouteStore] Delete failed: \(error.localizedDescription)")
        }
    }

    func delete(ids: some Sequence<UUID>) throws {
        let urls = ids.map(storageURL(for:))
        do {
            try withLock {
                for url in urls where fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
            }
        } catch {
            let failedURL = urls.first ?? storageDirectory
            throw TracerouteStoreError.deleteFailed(failedURL, error.localizedDescription)
        }
        NotificationCenter.default.post(name: .tracerouteStoreDidChange, object: self)
    }

    /// Creates a portable versioned JSON document containing one or more selected results.
    func exportData(for results: [TracerouteResult]) throws -> Data {
        guard !results.isEmpty else { throw TracerouteStoreError.emptyExport }
        let envelope = TracerouteExportEnvelope(version: 1, results: results)
        do {
            return try Self.makeEncoder(prettyPrinted: true).encode(envelope)
        } catch {
            throw TracerouteStoreError.writeFailed(storageDirectory, error.localizedDescription)
        }
    }

    /// Imports the native envelope, native arrays/single files, or Windows TracerouteSaveData JSON.
    @discardableResult
    func importData(_ data: Data, sourceURL: URL? = nil) throws -> [TracerouteResult] {
        let decoded = try Self.decodeResults(from: data, sourceURL: sourceURL)
        try persist(decoded)
        return decoded
    }

    @discardableResult
    func importFile(at url: URL) throws -> [TracerouteResult] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TracerouteStoreError.readFailed(url, error.localizedDescription)
        }
        return try importData(data, sourceURL: url)
    }

    private func storageURL(for id: UUID) -> URL {
        storageDirectory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func ensureStorageDirectory() throws {
        do {
            try fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        } catch {
            throw TracerouteStoreError.directoryUnavailable(storageDirectory, error.localizedDescription)
        }
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private static func makeEncoder(prettyPrinted: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        return encoder
    }

    private static func decodeResults(from data: Data, sourceURL: URL?) throws -> [TracerouteResult] {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(TracerouteExportEnvelope.self, from: data),
           !envelope.results.isEmpty {
            return envelope.results
        }
        if let results = try? decoder.decode([TracerouteResult].self, from: data), !results.isEmpty {
            return results
        }
        if let result = try? decoder.decode(TracerouteResult.self, from: data) {
            return [result]
        }
        if let windowsResult = try? decodeWindowsSaveData(from: data) {
            return [windowsResult]
        }
        throw TracerouteStoreError.invalidDocument(
            sourceURL,
            String(localized: "The JSON does not contain a supported traceroute document.")
        )
    }

    private static func decodeWindowsSaveData(from data: Data) throws -> TracerouteResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported Windows timestamp \(value)"
            )
        }
        let saveData = try decoder.decode(WindowsTracerouteSaveData.self, from: data)
        let result = saveData.result
        var route = result.routeForward
        if route.isEmpty {
            route = result.routeBack.reversed()
        }
        if route.last != result.destinationNodeId {
            route.append(result.destinationNodeId)
        }
        let nodes = saveData.nodes.reduce(into: [UInt32: WindowsTracerouteNode]()) { result, node in
            result[node.nodeId] = node
        }
        let hops = route.enumerated().map { index, nodeId in
            let node = nodes[nodeId]
            let encodedSnr = result.snrTowards.indices.contains(index) ? result.snrTowards[index] : Int.min
            let snr: Float?
            if encodedSnr < Int(Int32.min) || encodedSnr > Int(Int32.max) {
                snr = nil
            } else {
                snr = TracerouteHop.decodedSNR(Int32(encodedSnr))
            }
            return TracerouteHop(
                id: stableUUID("windows-hop-\(result.requestId)-\(nodeId)-\(index)-\(result.receivedAt.timeIntervalSince1970)"),
                nodeId: nodeId,
                nodeName: nodeId == TracerouteHop.unknownNodeId
                    ? String(localized: "Unknown intermediate hop")
                    : node?.name.nonEmpty ?? String(format: "!%08x", nodeId),
                snr: snr,
                latitude: node?.latitude,
                longitude: node?.longitude,
                viaMqtt: result.isViaMqtt
            )
        }
        let id = stableUUID(
            "windows-result-\(result.requestId)-\(result.sourceNodeId)-\(result.destinationNodeId)-\(result.receivedAt.timeIntervalSince1970)"
        )
        let sourceNode = nodes[result.sourceNodeId]
        return TracerouteResult(
            id: id,
            requestId: result.requestId,
            requestTime: result.receivedAt,
            sourceNodeId: result.sourceNodeId == 0 ? nil : result.sourceNodeId,
            sourceLatitude: sourceNode?.latitude,
            sourceLongitude: sourceNode?.longitude,
            targetNodeId: result.destinationNodeId,
            targetName: saveData.destinationName.nonEmpty
                ?? nodes[result.destinationNodeId]?.name.nonEmpty
                ?? String(format: "!%08x", result.destinationNodeId),
            hops: hops,
            responseTime: nil
        )
    }

    private static func stableUUID(_ value: String) -> UUID {
        func fnv1a(seed: UInt64) -> UInt64 {
            value.utf8.reduce(seed) { hash, byte in
                (hash ^ UInt64(byte)) &* 1_099_511_628_211
            }
        }
        let first = fnv1a(seed: 14_695_981_039_346_656_037)
        let second = fnv1a(seed: 7_805_201_434_977_854_211)
        let hex = String(format: "%016llx%016llx", first, second)
        let uuidString = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: uuidString) ?? UUID()
    }
}

extension Notification.Name {
    static let tracerouteStoreDidChange = Notification.Name("MeshHessen.tracerouteStoreDidChange")
}

private struct TracerouteExportEnvelope: Codable {
    let format = "MeshHessen.TracerouteHistory"
    let version: Int
    let results: [TracerouteResult]

    private enum CodingKeys: String, CodingKey {
        case format
        case version
        case results
    }

    init(version: Int, results: [TracerouteResult]) {
        self.version = version
        self.results = results
    }
}

private struct WindowsTracerouteSaveData: Decodable {
    let result: WindowsTracerouteResult
    let destinationName: String
    let nodes: [WindowsTracerouteNode]

    private enum CodingKeys: String, CodingKey {
        case result = "Result"
        case destinationName = "DestinationName"
        case nodes = "Nodes"
    }
}

private struct WindowsTracerouteResult: Decodable {
    let requestId: UInt32
    let destinationNodeId: UInt32
    let sourceNodeId: UInt32
    let isViaMqtt: Bool
    let receivedAt: Date
    let routeForward: [UInt32]
    let snrTowards: [Int]
    let routeBack: [UInt32]

    private enum CodingKeys: String, CodingKey {
        case requestId = "RequestId"
        case destinationNodeId = "DestinationNodeId"
        case sourceNodeId = "SourceNodeId"
        case isViaMqtt = "IsViaMqtt"
        case receivedAt = "ReceivedAt"
        case routeForward = "RouteForward"
        case snrTowards = "SnrTowards"
        case routeBack = "RouteBack"
    }
}

private struct WindowsTracerouteNode: Decodable {
    let nodeId: UInt32
    let name: String
    let latitude: Double?
    let longitude: Double?

    private enum CodingKeys: String, CodingKey {
        case nodeId = "NodeId"
        case name = "Name"
        case latitude = "Lat"
        case longitude = "Lon"
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
