import Foundation

struct NodeKeyMismatch: Identifiable, Equatable, Sendable {
    let id: UUID
    let nodeId: UInt32
    let shortName: String
    let longName: String
    let oldKey: Data
    let newKey: Data
    let detectedAt: Date

    init(
        id: UUID = UUID(),
        nodeId: UInt32,
        shortName: String,
        longName: String,
        oldKey: Data,
        newKey: Data,
        detectedAt: Date = Date()
    ) {
        self.id = id
        self.nodeId = nodeId
        self.shortName = shortName
        self.longName = longName
        self.oldKey = oldKey
        self.newKey = newKey
        self.detectedAt = detectedAt
    }
}

extension Notification.Name {
    static let nodeKeyMismatchDetected = Notification.Name("MeshHessen.nodeKeyMismatchDetected")
}

/// Manages a persistent CSV database of node public keys (Curve25519) for PKI encryption.
/// Keys are extracted from `User.public_key` (field 8) in NodeInfo packets.
final class NodeKeyService: @unchecked Sendable {
    static let shared = NodeKeyService(
        csvURL: NodeKeyService.defaultCSVURL(),
        policyProvider: { SettingsService.shared.nodeKeyMismatchPolicy }
    )

    private let lock = NSLock()
    private var entries: [UInt32: NodeKeyEntry] = [:]
    private let csvURL: URL
    private let policyProvider: @Sendable () -> NodeKeyMismatchPolicy

    struct NodeKeyEntry {
        let nodeId: UInt32
        var shortName: String
        var longName: String
        var publicKeyBase64: String
        var firstSeen: Date
        var lastSeen: Date
    }

    init(
        csvURL: URL,
        policyProvider: @escaping @Sendable () -> NodeKeyMismatchPolicy
    ) {
        self.csvURL = csvURL
        self.policyProvider = policyProvider
        try? FileManager.default.createDirectory(
            at: csvURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        loadAll()
    }

    private static func defaultCSVURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MeshHessen", isDirectory: true)
        return dir.appendingPathComponent("node_keys.csv")
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

        let outcome: (result: KeyUpdateResult, mismatch: NodeKeyMismatch?) = lock.withLock {
            if var existing = entries[nodeId] {
                if existing.publicKeyBase64 == base64 {
                    // Same key — update metadata
                    existing.shortName = shortName
                    existing.longName = longName
                    existing.lastSeen = now
                    entries[nodeId] = existing
                    saveAllLocked()
                    return (.known, nil)
                } else {
                    // Key changed
                    let action = policyProvider()
                    switch action {
                    case .warn:
                        AppLogger.shared.log("[NodeKey] Key CHANGED for \(String(format: "!%08x", nodeId)) (\(shortName)) — keeping old key (warn mode)")
                        existing.shortName = shortName
                        existing.longName = longName
                        existing.lastSeen = now
                        entries[nodeId] = existing
                        saveAllLocked()
                        return (.mismatchWarned, nil)
                    case .overwrite:
                        AppLogger.shared.log("[NodeKey] Key CHANGED for \(String(format: "!%08x", nodeId)) (\(shortName)) — overwriting")
                        existing.publicKeyBase64 = base64
                        existing.shortName = shortName
                        existing.longName = longName
                        existing.lastSeen = now
                        entries[nodeId] = existing
                        saveAllLocked()
                        return (.mismatchOverwritten, nil)
                    case .ask:
                        let oldKey = Data(base64Encoded: existing.publicKeyBase64) ?? Data()
                        let mismatch = NodeKeyMismatch(
                            nodeId: nodeId,
                            shortName: shortName,
                            longName: longName,
                            oldKey: oldKey,
                            newKey: publicKey,
                            detectedAt: now
                        )
                        existing.shortName = shortName
                        existing.longName = longName
                        existing.lastSeen = now
                        entries[nodeId] = existing
                        saveAllLocked()
                        AppLogger.shared.log("[NodeKey] Key CHANGED for \(String(format: "!%08x", nodeId)) (\(shortName)) — awaiting user decision")
                        return (.mismatchPending(mismatch), mismatch)
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
                return (.newEntry, nil)
            }
        }

        if let mismatch = outcome.mismatch {
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .nodeKeyMismatchDetected,
                    object: mismatch
                )
            }
        }
        return outcome.result
    }

    /// Applies the explicit user decision for a previously reported key change.
    /// The entry is updated only when both the old and proposed keys still match,
    /// preventing a stale dialog from overwriting a newer observation.
    @discardableResult
    func resolve(_ mismatch: NodeKeyMismatch, acceptNewKey: Bool) -> Bool {
        lock.withLock {
            guard var existing = entries[mismatch.nodeId],
                  existing.publicKeyBase64 == mismatch.oldKey.base64EncodedString()
            else { return false }

            if acceptNewKey {
                existing.publicKeyBase64 = mismatch.newKey.base64EncodedString()
            }
            existing.shortName = mismatch.shortName
            existing.longName = mismatch.longName
            existing.lastSeen = Date()
            entries[mismatch.nodeId] = existing
            saveAllLocked()
            AppLogger.shared.log(
                "[NodeKey] User \(acceptNewKey ? "accepted" : "rejected") changed key for \(String(format: "!%08x", mismatch.nodeId))"
            )
            return true
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

    enum KeyUpdateResult: Equatable {
        case ignored, known, newEntry, mismatchWarned, mismatchOverwritten
        case mismatchPending(NodeKeyMismatch)
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
