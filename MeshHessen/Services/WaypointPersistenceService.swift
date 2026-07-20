import Foundation

actor WaypointPersistenceService {
    static let shared = WaypointPersistenceService()

    private let fileManager: FileManager
    private let fileURL: URL

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            self.fileURL = applicationSupport
                .appendingPathComponent("MeshHessen", isDirectory: true)
                .appendingPathComponent("waypoints.json")
        }
    }

    func loadAll(excludingExpired: Bool = true, now: Date = Date()) throws -> [UInt32: MeshWaypoint] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        let waypoints = try JSONDecoder().decode([MeshWaypoint].self, from: data)
        let filtered = excludingExpired
            ? waypoints.filter { $0.expiration.map { $0 > now } ?? true }
            : waypoints
        return Dictionary(uniqueKeysWithValues: filtered.map { ($0.id, $0) })
    }

    func replace(with waypoints: [UInt32: MeshWaypoint]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let values = waypoints.values.sorted { $0.id < $1.id }
        let data = try JSONEncoder().encode(values)
        try data.write(to: fileURL, options: .atomic)
    }

    func upsert(_ waypoint: MeshWaypoint) throws {
        var waypoints = try loadAll(excludingExpired: false)
        waypoints[waypoint.id] = waypoint
        try replace(with: waypoints)
    }

    func delete(id: UInt32) throws {
        var waypoints = try loadAll(excludingExpired: false)
        waypoints.removeValue(forKey: id)
        try replace(with: waypoints)
    }
}
