import Foundation

/// Represents the result of a traceroute operation
struct TracerouteResult: Identifiable, Codable {
    let id: UUID
    let requestTime: Date
    let targetNodeId: UInt32
    let targetName: String
    let hops: [TracerouteHop]
    var responseTime: Date?

    /// Total round-trip time in milliseconds
    var roundTripMs: Int? {
        guard let response = responseTime else { return nil }
        return Int(response.timeIntervalSince(requestTime) * 1000)
    }

    init(targetNodeId: UInt32, targetName: String, hops: [TracerouteHop] = [], responseTime: Date? = nil) {
        self.id = UUID()
        self.requestTime = Date()
        self.targetNodeId = targetNodeId
        self.targetName = targetName
        self.hops = hops
        self.responseTime = responseTime
    }
}

/// A single hop in a traceroute
struct TracerouteHop: Identifiable, Codable {
    let id: UUID
    let nodeId: UInt32
    let nodeName: String
    let snr: Float?
    let latitude: Double?
    let longitude: Double?
    let viaMqtt: Bool

    init(nodeId: UInt32, nodeName: String, snr: Float? = nil,
         latitude: Double? = nil, longitude: Double? = nil, viaMqtt: Bool = false) {
        self.id = UUID()
        self.nodeId = nodeId
        self.nodeName = nodeName
        self.snr = snr
        self.latitude = latitude
        self.longitude = longitude
        self.viaMqtt = viaMqtt
    }

    /// Distance to the next hop (set externally)
    var distanceToNext: Double?
}

/// Manages traceroute results persistence
final class TracerouteStore {
    static let shared = TracerouteStore()

    private let fileManager = FileManager.default

    private var storageDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MeshHessen/traceroutes", isDirectory: true)
    }

    private init() {
        try? fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
    }

    func save(_ result: TracerouteResult) {
        let fileURL = storageDirectory.appendingPathComponent("\(result.id.uuidString).json")
        guard let data = try? JSONEncoder().encode(result) else { return }
        try? data.write(to: fileURL)
    }

    func loadAll() -> [TracerouteResult] {
        guard let files = try? fileManager.contentsOfDirectory(atPath: storageDirectory.path) else { return [] }
        return files.compactMap { filename -> TracerouteResult? in
            guard filename.hasSuffix(".json") else { return nil }
            let fileURL = storageDirectory.appendingPathComponent(filename)
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return try? JSONDecoder().decode(TracerouteResult.self, from: data)
        }.sorted { $0.requestTime > $1.requestTime }
    }

    func delete(_ result: TracerouteResult) {
        let fileURL = storageDirectory.appendingPathComponent("\(result.id.uuidString).json")
        try? fileManager.removeItem(at: fileURL)
    }
}
