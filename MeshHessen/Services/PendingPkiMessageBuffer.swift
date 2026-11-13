import Foundation

// MARK: - Pending PKI entry

/// An encrypted direct message addressed to us that could not be decrypted when
/// it arrived (sender public key unknown, or private key not loaded yet).
struct PendingPkiEntry: Equatable, Sendable {
    let packetId: UInt32
    let from: UInt32
    let to: UInt32
    /// Raw `MeshPacket.channel` value (an undecryptable packet carries the channel hash).
    let channel: UInt32
    /// On-wire PKC blob: ciphertext ‖ tag ‖ extraNonce.
    let blob: Data
    let receivedAt: Date
    /// Local id of the placeholder bubble, `nil` when the packet was buffered silently.
    let messageId: UUID?
}

// MARK: - Buffer

/// Per-sender buffer of undecryptable PKI direct messages, drained once the
/// sender's public key becomes known (Windows `BufferPendingPkiDm`).
struct PendingPkiMessageBuffer: Sendable {
    static let maxEntriesPerNode = 20
    static let entryLifetime: TimeInterval = 30 * 60

    private(set) var entriesByNode: [UInt32: [PendingPkiEntry]] = [:]

    var isEmpty: Bool { entriesByNode.isEmpty }
    var nodeIds: [UInt32] { Array(entriesByNode.keys) }

    func count(for node: UInt32) -> Int {
        entriesByNode[node]?.count ?? 0
    }

    func contains(packetId: UInt32, for node: UInt32) -> Bool {
        entriesByNode[node]?.contains { $0.packetId == packetId } ?? false
    }

    /// Adds an entry, dropping expired entries of every sender first. Entries are
    /// de-duplicated by packet id; the oldest entry is dropped beyond the per-node cap.
    mutating func add(_ entry: PendingPkiEntry, now: Date = Date()) {
        guard !entry.blob.isEmpty else { return }
        purgeExpired(now: now)

        var list = entriesByNode[entry.from] ?? []
        if entry.packetId != 0, list.contains(where: { $0.packetId == entry.packetId }) {
            return
        }
        list.append(entry)
        if list.count > Self.maxEntriesPerNode {
            list.removeFirst(list.count - Self.maxEntriesPerNode)
        }
        entriesByNode[entry.from] = list
    }

    /// Removes and returns every still-valid entry for `node`.
    mutating func take(for node: UInt32, now: Date = Date()) -> [PendingPkiEntry] {
        guard let list = entriesByNode.removeValue(forKey: node) else { return [] }
        return list.filter { !Self.isExpired($0, now: now) }
    }

    /// Takes the node's entries, decrypts each with `decrypt` and puts the
    /// failures back. Returns the successfully decrypted entries with their plaintext.
    mutating func resolve<Plaintext>(
        for node: UInt32,
        now: Date = Date(),
        decrypt: (PendingPkiEntry) -> Plaintext?
    ) -> [(entry: PendingPkiEntry, plaintext: Plaintext)] {
        var resolved: [(entry: PendingPkiEntry, plaintext: Plaintext)] = []
        for entry in take(for: node, now: now) {
            if let plaintext = decrypt(entry) {
                resolved.append((entry, plaintext))
            } else {
                add(entry, now: now)
            }
        }
        return resolved
    }

    mutating func removeAll() {
        entriesByNode.removeAll()
    }

    private mutating func purgeExpired(now: Date) {
        for (node, list) in entriesByNode {
            let kept = list.filter { !Self.isExpired($0, now: now) }
            entriesByNode[node] = kept.isEmpty ? nil : kept
        }
    }

    private static func isExpired(_ entry: PendingPkiEntry, now: Date) -> Bool {
        now.timeIntervalSince(entry.receivedAt) > entryLifetime
    }
}

// MARK: - NodeInfo request throttle

/// Rate limit for automatic NodeInfo requests (Windows `RequestNodeInfoAsync` /
/// `RequestUnknownNodeInfoThrottled`). The constants are deliberately
/// conservative: every request costs airtime.
struct NodeInfoRequestThrottle: Sendable {
    static let perNodeInterval: TimeInterval = 2 * 60
    static let globalGap: TimeInterval = 8

    private var lastRequestByNode: [UInt32: Date] = [:]
    private var lastBurstGuardedRequest: Date?

    /// Returns `true` (and records the request) when a NodeInfo request to `node`
    /// may be sent now. `force` bypasses both rules. `burstGuard` additionally
    /// applies the global gap between automatic requests; Windows uses it for
    /// channel senders, not for a direct message addressed to us.
    mutating func shouldRequest(
        node: UInt32,
        now: Date = Date(),
        force: Bool = false,
        burstGuard: Bool = true
    ) -> Bool {
        if !force {
            if let last = lastRequestByNode[node], now.timeIntervalSince(last) < Self.perNodeInterval {
                return false
            }
            if burstGuard,
               let last = lastBurstGuardedRequest,
               now.timeIntervalSince(last) < Self.globalGap {
                return false
            }
        }
        lastRequestByNode[node] = now
        if burstGuard {
            lastBurstGuardedRequest = now
        }
        return true
    }

    mutating func reset() {
        lastRequestByNode.removeAll()
        lastBurstGuardedRequest = nil
    }
}

// MARK: - Recent explicit info requests

/// Remembers explicit info requests (NodeInfo, position, telemetry …) sent by the
/// user. An encrypted reply arriving shortly after is that request's response,
/// not a chat message (Windows `HasRecentInfoRequest`).
struct RecentInfoRequestTracker: Sendable {
    static let replyWindow: TimeInterval = 30

    private var sentAt: [UInt32: Date] = [:]

    mutating func note(node: UInt32, now: Date = Date()) {
        sentAt[node] = now
        if sentAt.count > 32 {
            sentAt = sentAt.filter { now.timeIntervalSince($0.value) < Self.replyWindow }
        }
    }

    func hasRecentRequest(to node: UInt32, now: Date = Date()) -> Bool {
        guard let sent = sentAt[node] else { return false }
        return now.timeIntervalSince(sent) < Self.replyWindow
    }
}

// MARK: - Routing of undecryptable packets

/// What to do with an encrypted packet the client could not decrypt.
enum EncryptedPacketRoute: Equatable, Sendable {
    /// Unicast between two other nodes (overheard traffic): never shown as chat.
    case ignoreForeignUnicast
    /// Broadcast on a channel we have no key for: shown in the channel feed.
    case channelFeed
    /// Our own unicast echoed back by the radio.
    case directMessageFromUs
    /// Unicast addressed to us: buffered for late decryption. `showPlaceholder`
    /// is `false` when it most likely answers an explicit info request.
    case directMessageToUs(showPlaceholder: Bool)

    static let broadcastAddress: UInt32 = 0xFFFF_FFFF

    static func route(
        from: UInt32,
        to: UInt32,
        myNodeId: UInt32,
        hasRecentInfoRequest: Bool
    ) -> EncryptedPacketRoute {
        if to == 0 || to == broadcastAddress {
            return .channelFeed
        }
        if myNodeId != 0, to == myNodeId {
            return .directMessageToUs(showPlaceholder: !hasRecentInfoRequest)
        }
        if myNodeId != 0, from == myNodeId {
            return .directMessageFromUs
        }
        return .ignoreForeignUnicast
    }

    /// Channel index for a NodeInfo request: indices above 7 are channel hashes of
    /// undecryptable packets, so the last channel the node was decoded on (else 0) is used.
    static func nodeInfoRequestChannel(requested: UInt32?, lastGoodChannel: UInt32?) -> UInt32 {
        if let requested, requested <= 7 { return requested }
        if let lastGoodChannel, lastGoodChannel <= 7 { return lastGoodChannel }
        return 0
    }
}
