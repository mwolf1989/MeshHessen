import Foundation

/// Manages a persistent CSV database of node public keys (Curve25519) for PKI encryption.
/// Keys are extracted from `User.public_key` (field 8) in NodeInfo packets.
final class NodeKeyService: @unchecked Sendable {
    static let shared = NodeKeyService()

    private let lock = NSLock()
    private var entries: [UInt32: NodeKeyEntry] = [:]
    private let csvURL: URL

    struct NodeKeyEntry {
        let nodeId: UInt32
        var shortName: String
        var longName: String
        var publicKeyBase64: String
        var firstSeen: Date
        var lastSeen: Date
    }

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MeshHessen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        csvURL = dir.appendingPathComponent("node_keys.csv")
        loadAll()
    }

    // MARK: - Public API

    /// Returns the stored public key for a node, or nil if unknown.
    func publicKey(for nodeId: UInt32) -> Data? {
        lock.withLock {
            guard let entry = entries[nodeId],
                  let data = Data(base64Encoded: entry.publicKeyBase64),
                  !data.isEmpty else { return nil }
            return data
        }
    }

    /// Checks an incoming public key against the database and updates/inserts as needed.
    /// Returns the action taken.
    @discardableResult
    func checkAndUpdate(nodeId: UInt32, shortName: String, longName: String, publicKey: Data) -> KeyUpdateResult {
        guard !publicKey.isEmpty else { return .ignored }
        let base64 = publicKey.base64EncodedString()
        let now = Date()

        return lock.withLock {
            if var existing = entries[nodeId] {
                if existing.publicKeyBase64 == base64 {
                    // Same key — update metadata
                    existing.shortName = shortName
                    existing.longName = longName
                    existing.lastSeen = now
                    entries[nodeId] = existing
                    saveAllLocked()
                    return .known
                } else {
                    // Key changed
                    let action = SettingsService.shared.nodeKeyMismatchAction
                    switch action {
                    case .warn:
                        AppLogger.shared.log("[NodeKey] Key CHANGED for \(String(format: "!%08x", nodeId)) (\(shortName)) — keeping old key (warn mode)")
                        return .mismatchWarned
                    case .overwrite:
                        AppLogger.shared.log("[NodeKey] Key CHANGED for \(String(format: "!%08x", nodeId)) (\(shortName)) — overwriting")
                        existing.publicKeyBase64 = base64
                        existing.shortName = shortName
                        existing.longName = longName
                        existing.lastSeen = now
                        entries[nodeId] = existing
                        saveAllLocked()
                        return .mismatchOverwritten
                    }
                }
            } else {
                // New node
                entries[nodeId] = NodeKeyEntry(
                    nodeId: nodeId,
                    shortName: shortName,
                    longName: longName,
                    publicKeyBase64: base64,
                    firstSeen: now,
                    lastSeen: now
                )
                saveAllLocked()
                AppLogger.shared.log("[NodeKey] New key stored for \(String(format: "!%08x", nodeId)) (\(shortName))", debug: true)
                return .newEntry
            }
        }
    }

    /// Whether a public key is known for the given node.
    func hasKey(for nodeId: UInt32) -> Bool {
        lock.withLock { entries[nodeId] != nil }
    }

    /// Number of stored keys.
    var count: Int {
        lock.withLock { entries.count }
    }

    enum KeyUpdateResult {
        case ignored, known, newEntry, mismatchWarned, mismatchOverwritten
    }

    // MARK: - CSV Persistence

    private func loadAll() {
        guard FileManager.default.fileExists(atPath: csvURL.path) else { return }
        guard let content = try? String(contentsOf: csvURL, encoding: .utf8) else { return }

        let lines = content.components(separatedBy: .newlines)
        let iso = ISO8601DateFormatter()

        for line in lines.dropFirst() { // skip header
            let fields = line.components(separatedBy: ";")
            guard fields.count >= 6 else { continue }
            guard let nodeId = UInt32(fields[0]) else { continue }

            entries[nodeId] = NodeKeyEntry(
                nodeId: nodeId,
                shortName: fields[1],
                longName: fields[2],
                publicKeyBase64: fields[3],
                firstSeen: iso.date(from: fields[4]) ?? Date(),
                lastSeen: iso.date(from: fields[5]) ?? Date()
            )
        }
        AppLogger.shared.log("[NodeKey] Loaded \(entries.count) keys from CSV", debug: true)
    }

    /// Saves all entries to CSV. Must be called with lock held.
    private func saveAllLocked() {
        let iso = ISO8601DateFormatter()
        var csv = "NodeId;ShortName;LongName;PublicKeyBase64;FirstSeen;LastSeen\n"
        for entry in entries.values.sorted(by: { $0.nodeId < $1.nodeId }) {
            // Escape semicolons in names
            let short = entry.shortName.replacingOccurrences(of: ";", with: ",")
            let long = entry.longName.replacingOccurrences(of: ";", with: ",")
            csv += "\(entry.nodeId);\(short);\(long);\(entry.publicKeyBase64);\(iso.string(from: entry.firstSeen));\(iso.string(from: entry.lastSeen))\n"
        }
        try? csv.write(to: csvURL, atomically: true, encoding: .utf8)
    }
}
