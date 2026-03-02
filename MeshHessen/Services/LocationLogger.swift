import Foundation

/// Logs node positions to CSV files for location history and path tracking.
/// Each node gets its own CSV: `~/Library/Application Support/MeshHessen/locationlogs/NODE_{id}.csv`
/// Format: `Timestamp;NodeId;Name;Latitude;Longitude;Altitude`
final class LocationLogger {
    static let shared = LocationLogger()

    private let fileManager = FileManager.default
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private var logDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MeshHessen/locationlogs", isDirectory: true)
    }

    private init() {
        ensureDirectoryExists()
    }

    private func ensureDirectoryExists() {
        try? fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    }

    /// Log a position update for a node. Only logs if location logging is enabled.
    func logPosition(nodeId: UInt32, name: String, latitude: Double, longitude: Double, altitude: Int) {
        guard SettingsService.shared.locationLoggingEnabled else { return }

        let timestamp = dateFormatter.string(from: Date())
        let nodeIdHex = String(format: "%08x", nodeId)
        let line = "\(timestamp);\(nodeIdHex);\(name);\(String(format: "%.7f", latitude));\(String(format: "%.7f", longitude));\(altitude)\n"

        let fileURL = logFileURL(for: nodeId)

        // Create file with header if it doesn't exist
        if !fileManager.fileExists(atPath: fileURL.path) {
            let header = "Timestamp;NodeId;Name;Latitude;Longitude;Altitude\n"
            fileManager.createFile(atPath: fileURL.path, contents: header.data(using: .utf8))
        }

        // Append the line
        guard let data = line.data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }

    /// Read all logged positions for a node, returning them in chronological order.
    func readPositions(for nodeId: UInt32) -> [LocationEntry] {
        let fileURL = logFileURL(for: nodeId)
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }

        var entries: [LocationEntry] = []
        let lines = contents.components(separatedBy: .newlines)

        for line in lines.dropFirst() { // skip header
            let parts = line.components(separatedBy: ";")
            guard parts.count >= 6 else { continue }
            guard let lat = Double(parts[3]),
                  let lon = Double(parts[4]),
                  let alt = Int(parts[5]) else { continue }

            let timestamp = dateFormatter.date(from: parts[0]) ?? Date()
            entries.append(LocationEntry(
                timestamp: timestamp,
                nodeId: parts[1],
                name: parts[2],
                latitude: lat,
                longitude: lon,
                altitude: alt
            ))
        }
        return entries
    }

    /// Returns the CSV file URL for a given node.
    func logFileURL(for nodeId: UInt32) -> URL {
        logDirectory.appendingPathComponent("NODE_\(String(format: "%08x", nodeId)).csv")
    }

    /// Check if a node has any logged positions.
    func hasPositionLog(for nodeId: UInt32) -> Bool {
        fileManager.fileExists(atPath: logFileURL(for: nodeId).path)
    }

    /// Returns all node IDs that have log files.
    func allLoggedNodeIds() -> [UInt32] {
        guard let files = try? fileManager.contentsOfDirectory(atPath: logDirectory.path) else { return [] }
        return files.compactMap { filename -> UInt32? in
            guard filename.hasPrefix("NODE_") && filename.hasSuffix(".csv") else { return nil }
            let hex = String(filename.dropFirst(5).dropLast(4))
            return UInt32(hex, radix: 16)
        }
    }

    /// Export a node's location log as CSV data.
    func exportCSV(for nodeId: UInt32) -> Data? {
        let fileURL = logFileURL(for: nodeId)
        return try? Data(contentsOf: fileURL)
    }

    /// Delete a node's location log.
    func deleteLog(for nodeId: UInt32) {
        let fileURL = logFileURL(for: nodeId)
        try? fileManager.removeItem(at: fileURL)
    }
}

/// A single location log entry parsed from CSV.
struct LocationEntry {
    let timestamp: Date
    let nodeId: String
    let name: String
    let latitude: Double
    let longitude: Double
    let altitude: Int
}
