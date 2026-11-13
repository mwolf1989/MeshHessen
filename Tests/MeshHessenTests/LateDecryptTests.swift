import CryptoKit
import Foundation
import Testing

@testable import MeshHessen

// MARK: - Buffer

@Suite("LateDecrypt buffer")
struct LateDecryptBufferTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ packetId: UInt32, from: UInt32 = 0xA1, at date: Date) -> PendingPkiEntry {
        PendingPkiEntry(
            packetId: packetId,
            from: from,
            to: 0xB2,
            channel: 0,
            blob: Data([0x01, 0x02, UInt8(truncatingIfNeeded: packetId)]),
            receivedAt: date,
            messageId: nil
        )
    }

    @Test("Keeps at most 20 entries per node and drops the oldest")
    func capPerNode() {
        var buffer = PendingPkiMessageBuffer()
        for id in UInt32(1)...25 {
            buffer.add(entry(id, at: start), now: start)
        }
        buffer.add(entry(99, from: 0xC3, at: start), now: start)

        #expect(buffer.count(for: 0xA1) == PendingPkiMessageBuffer.maxEntriesPerNode)
        #expect(buffer.count(for: 0xC3) == 1)
        let taken = buffer.take(for: 0xA1, now: start)
        #expect(taken.map(\.packetId) == Array(UInt32(6)...25))
    }

    @Test("Entries older than 30 minutes expire")
    func timeToLive() {
        var buffer = PendingPkiMessageBuffer()
        buffer.add(entry(1, at: start), now: start)
        buffer.add(entry(2, at: start.addingTimeInterval(20 * 60)), now: start.addingTimeInterval(20 * 60))

        let later = start.addingTimeInterval(31 * 60)
        do { let result = buffer.take(for: 0xA1, now: later).map(\.packetId) == [2]; #expect(result) }

        // Adding purges expired entries of every sender.
        buffer.add(entry(3, from: 0xC3, at: start), now: start)
        buffer.add(entry(4, at: later), now: later)
        #expect(buffer.count(for: 0xC3) == 0)
        #expect(buffer.count(for: 0xA1) == 1)
    }

    @Test("take empties the node's entries; duplicates are ignored")
    func takeEmptiesAndDeduplicates() {
        var buffer = PendingPkiMessageBuffer()
        buffer.add(entry(7, at: start), now: start)
        buffer.add(entry(7, at: start), now: start)
        #expect(buffer.count(for: 0xA1) == 1)
        #expect(buffer.contains(packetId: 7, for: 0xA1))

        do { let result = buffer.take(for: 0xA1, now: start).count == 1; #expect(result) }
        do { let result = buffer.take(for: 0xA1, now: start).isEmpty; #expect(result) }
        #expect(buffer.isEmpty)
    }

    @Test("resolve returns successes and keeps failures buffered")
    func resolveKeepsFailures() {
        var buffer = PendingPkiMessageBuffer()
        buffer.add(entry(1, at: start), now: start)
        buffer.add(entry(2, at: start), now: start)

        let resolved = buffer.resolve(for: 0xA1, now: start) { $0.packetId == 2 ? "ok" : nil }
        #expect(resolved.map(\.entry.packetId) == [2])
        #expect(resolved.first?.plaintext == "ok")
        #expect(buffer.count(for: 0xA1) == 1)
        #expect(buffer.contains(packetId: 1, for: 0xA1))
    }
}

// MARK: - Throttle and routing

@Suite("LateDecrypt throttle and routing")
struct LateDecryptThrottleTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Same node within 2 minutes is denied, later allowed")
    func perNodeInterval() {
        var throttle = NodeInfoRequestThrottle()
        do { let result = throttle.shouldRequest(node: 1, now: start); #expect(result) }
        do { let result = !throttle.shouldRequest(node: 1, now: start.addingTimeInterval(119)); #expect(result) }
        do { let result = throttle.shouldRequest(node: 1, now: start.addingTimeInterval(121)); #expect(result) }
    }

    @Test("A different node within 8 seconds is denied by the burst guard")
    func globalGap() {
        var throttle = NodeInfoRequestThrottle()
        do { let result = throttle.shouldRequest(node: 1, now: start); #expect(result) }
        do { let result = !throttle.shouldRequest(node: 2, now: start.addingTimeInterval(7)); #expect(result) }
        do { let result = throttle.shouldRequest(node: 2, now: start.addingTimeInterval(9)); #expect(result) }
        // Without the burst guard (DM to us) only the per-node rule applies.
        do { let result = throttle.shouldRequest(node: 3, now: start.addingTimeInterval(10), burstGuard: false); #expect(result) }
    }

    @Test("force bypasses both rules")
    func forceBypasses() {
        var throttle = NodeInfoRequestThrottle()
        do { let result = throttle.shouldRequest(node: 1, now: start); #expect(result) }
        do { let result = throttle.shouldRequest(node: 1, now: start.addingTimeInterval(1), force: true); #expect(result) }
        do { let result = throttle.shouldRequest(node: 2, now: start.addingTimeInterval(2), force: true); #expect(result) }
    }

    @Test("Explicit info requests are remembered for 30 seconds")
    func recentInfoRequests() {
        var tracker = RecentInfoRequestTracker()
        tracker.note(node: 5, now: start)
        #expect(tracker.hasRecentRequest(to: 5, now: start.addingTimeInterval(29)))
        #expect(!tracker.hasRecentRequest(to: 5, now: start.addingTimeInterval(31)))
        #expect(!tracker.hasRecentRequest(to: 6, now: start))
    }

    @Test("Encrypted unicasts to other nodes never become chat items")
    func routingDecision() {
        let me: UInt32 = 0x1000
        #expect(EncryptedPacketRoute.route(from: 0x2000, to: 0x3000, myNodeId: me, hasRecentInfoRequest: false)
            == .ignoreForeignUnicast)
        #expect(EncryptedPacketRoute.route(from: 0x2000, to: 0x3000, myNodeId: 0, hasRecentInfoRequest: false)
            == .ignoreForeignUnicast)
        #expect(EncryptedPacketRoute.route(from: 0x2000, to: 0xFFFF_FFFF, myNodeId: me, hasRecentInfoRequest: false)
            == .channelFeed)
        #expect(EncryptedPacketRoute.route(from: 0x2000, to: 0, myNodeId: me, hasRecentInfoRequest: false)
            == .channelFeed)
        #expect(EncryptedPacketRoute.route(from: 0x2000, to: me, myNodeId: me, hasRecentInfoRequest: false)
            == .directMessageToUs(showPlaceholder: true))
        #expect(EncryptedPacketRoute.route(from: 0x2000, to: me, myNodeId: me, hasRecentInfoRequest: true)
            == .directMessageToUs(showPlaceholder: false))
        #expect(EncryptedPacketRoute.route(from: me, to: 0x2000, myNodeId: me, hasRecentInfoRequest: false)
            == .directMessageFromUs)
    }

    @Test("NodeInfo requests use a valid channel index")
    func requestChannel() {
        #expect(EncryptedPacketRoute.nodeInfoRequestChannel(requested: 2, lastGoodChannel: 5) == 2)
        #expect(EncryptedPacketRoute.nodeInfoRequestChannel(requested: 117, lastGoodChannel: 3) == 3)
        #expect(EncryptedPacketRoute.nodeInfoRequestChannel(requested: 117, lastGoodChannel: nil) == 0)
        #expect(EncryptedPacketRoute.nodeInfoRequestChannel(requested: nil, lastGoodChannel: 1) == 1)
    }
}

// MARK: - Decryption, own user, models

@Suite("LateDecrypt end to end")
struct LateDecryptEndToEndTests {
    @Test("A blob buffered while the sender key is unknown decrypts once the key is supplied")
    func bufferedBlobDecryptsLater() throws {
        let senderKey = Curve25519.KeyAgreement.PrivateKey()
        let recipientKey = Curve25519.KeyAgreement.PrivateKey()
        let senderNode: UInt32 = 0xA1B2_C3D4
        let recipientNode: UInt32 = 0x0102_0304
        let packetId: UInt32 = 0x1234_5678

        var original = Meshtastic_Data()
        original.portnum = .textMessageApp
        original.payload = Data("Hallo aus Hessen".utf8)

        // Isolated instances: `PkiDecryptionService.shared` is used by other suites.
        let senderService = PkiDecryptionService()
        senderService.setPrivateKey(senderKey.rawRepresentation)
        let blob = try #require(senderService.encryptForTesting(
            plaintext: try original.serializedData(),
            recipientPublicKey: recipientKey.publicKey.rawRepresentation,
            fromNode: senderNode,
            packetId: packetId,
            extraNonce: 0xCAFE_BABE
        ))

        let recipientService = PkiDecryptionService()
        recipientService.setPrivateKey(recipientKey.rawRepresentation)

        var buffer = PendingPkiMessageBuffer()
        buffer.add(PendingPkiEntry(
            packetId: packetId,
            from: senderNode,
            to: recipientNode,
            channel: 117,
            blob: blob,
            receivedAt: Date(),
            messageId: UUID()
        ))

        // Sender key still unknown: nothing resolves, the entry stays buffered.
        var knownSenderKey: Data?
        let early = buffer.resolve(for: senderNode) { entry -> Meshtastic_Data? in
            guard let knownSenderKey else { return nil }
            return MeshtasticProtocolService.decryptPendingEntry(
                entry, senderPublicKey: knownSenderKey, using: recipientService
            )
        }
        #expect(early.isEmpty)
        #expect(buffer.count(for: senderNode) == 1)

        // NodeInfo arrives with the sender key.
        knownSenderKey = senderKey.publicKey.rawRepresentation
        let late = buffer.resolve(for: senderNode) { entry -> Meshtastic_Data? in
            guard let knownSenderKey else { return nil }
            return MeshtasticProtocolService.decryptPendingEntry(
                entry, senderPublicKey: knownSenderKey, using: recipientService
            )
        }
        #expect(late.count == 1)
        #expect(late.first?.plaintext == original)
        #expect(buffer.isEmpty)
    }

    @Test("A wrong sender key keeps the entry undecrypted")
    func wrongKeyFails() throws {
        let recipientService = PkiDecryptionService()
        recipientService.setPrivateKey(Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
        let entry = PendingPkiEntry(
            packetId: 1, from: 2, to: 3, channel: 0,
            blob: Data(repeating: 0xAB, count: 40),
            receivedAt: Date(), messageId: nil
        )
        #expect(MeshtasticProtocolService.decryptPendingEntry(
            entry,
            senderPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
            using: recipientService
        ) == nil)
    }

    @Test("Own user carries id, names and our public key")
    func ownUser() {
        let key = Data(repeating: 0x42, count: 32)
        let user = MeshtasticProtocolService.makeOwnUser(
            base: nil,
            myNodeId: 0x0000_beef,
            longName: "",
            shortName: "",
            hardwareModelRaw: 0,
            fallbackPublicKey: key
        )
        #expect(user.id == "!0000beef")
        #expect(user.longName == "!0000beef")
        #expect(user.shortName == "beef")
        #expect(user.publicKey == key)

        var owner = Meshtastic_User()
        owner.longName = "Hessen Base"
        owner.shortName = "HB"
        owner.isLicensed = true
        owner.publicKey = key
        let licensed = MeshtasticProtocolService.makeOwnUser(
            base: owner,
            myNodeId: 1,
            longName: "Other",
            shortName: "O",
            hardwareModelRaw: 0,
            fallbackPublicKey: key
        )
        #expect(licensed.longName == "Hessen Base")
        #expect(licensed.publicKey.isEmpty)
    }

    @Test("User-info request payload is our own User")
    func requestPayload() throws {
        var user = Meshtastic_User()
        user.id = "!00000001"
        user.publicKey = Data(repeating: 0x07, count: 32)
        let data = try MeshtasticProtocolService.makeNodeInfoRequestData(
            .userInfo, destinationId: 2, timestamp: 0, ownUser: user
        )
        #expect(data.portnum == .nodeinfoApp)
        #expect(data.wantResponse)
        #expect(try Meshtastic_User(serializedBytes: data.payload) == user)
    }

    @Test("Placeholder names follow the Meshtastic default")
    func placeholderName() {
        #expect(NodeInfo.placeholderName(for: 0x1234_abcd) == "Meshtastic abcd")
        #expect(NodeInfo.isPlaceholderName("Meshtastic abcd", for: 0x1234_abcd))
        #expect(NodeInfo.isPlaceholderName("!1234abcd", for: 0x1234_abcd))
        #expect(!NodeInfo.isPlaceholderName("Alice", for: 0x1234_abcd))
        #expect(NodeInfo(id: 0x1234_abcd, nodeId: "", shortName: "", longName: "").name == "Meshtastic abcd")
    }

    @Test("Late decryption keeps the placeholder identity")
    func applyingLateDecryption() {
        var placeholder = MessageItem(
            packetId: 9, time: "10:00:00", from: "Meshtastic abcd", fromId: 0xABCD, toId: 1,
            message: "", channelIndex: -1, channelName: "", isEncrypted: true
        )
        placeholder.cipher = Data([1, 2, 3])
        #expect(placeholder.canRetryDecrypt)

        let decrypted = placeholder.applyingLateDecryption(text: "Hi", hasAlertBell: false, replyToPacketId: nil)
        #expect(decrypted.id == placeholder.id)
        #expect(decrypted.createdAt == placeholder.createdAt)
        #expect(decrypted.message == "Hi")
        #expect(!decrypted.isEncrypted)
        #expect(decrypted.cipher == nil)
        #expect(!decrypted.canRetryDecrypt)
    }
}

// MARK: - State and persistence

@Suite("LateDecrypt state")
@MainActor
struct LateDecryptStateTests {
    private let senderId: UInt32 = 0x0000_abcd
    private let myId: UInt32 = 0x0000_0001

    private func placeholder() -> MessageItem {
        var message = MessageItem(
            packetId: 77, time: "10:00:00", from: NodeInfo.placeholderName(for: senderId),
            fromId: senderId, toId: myId, message: "", channelIndex: -1, channelName: "",
            isEncrypted: true
        )
        message.cipher = Data(repeating: 0x5A, count: 24)
        return message
    }

    @Test("The decrypted text replaces the placeholder in place")
    func inPlaceUpdate() {
        let state = AppState()
        let original = placeholder()
        state.addOrUpdateDM(original, myNodeId: myId, partnerNodeId: senderId)

        let decrypted = original.applyingLateDecryption(text: "Servus", hasAlertBell: false, replyToPacketId: nil)
        state.addOrUpdateDM(decrypted, myNodeId: myId, partnerNodeId: senderId)

        let messages = state.dmConversations[senderId]?.messages ?? []
        #expect(messages.count == 1)
        #expect(messages.first?.message == "Servus")
        #expect(messages.first?.cipher == nil)
        #expect(messages.first?.isEncrypted == false)

        // A late encrypted copy must not turn it back into a placeholder.
        state.addOrUpdateDM(original, myNodeId: myId, partnerNodeId: senderId)
        #expect(state.dmConversations[senderId]?.messages.first?.message == "Servus")
    }

    @Test("Messages and the DM title are renamed once the name is known")
    func retroactiveNames() {
        let state = AppState()
        state.addOrUpdateDM(placeholder(), myNodeId: myId, partnerNodeId: senderId)
        state.appendMessage(MessageItem(
            packetId: 5, time: "10:00:00", from: String(format: "!%08x", senderId),
            fromId: senderId, toId: 0xFFFF_FFFF, message: "Hallo", channelIndex: 0, channelName: "Primary"
        ))
        state.appendMessage(MessageItem(
            packetId: 6, time: "10:00:00", from: "Bob", fromId: 0x0000_beef,
            toId: 0xFFFF_FFFF, message: "Moin", channelIndex: 0, channelName: "Primary"
        ))
        #expect(state.dmConversations[senderId]?.nodeName == NodeInfo.placeholderName(for: senderId))

        state.upsertNode(NodeInfo(id: senderId, nodeId: "!0000abcd", shortName: "AL", longName: "Alice"))

        #expect(state.dmConversations[senderId]?.nodeName == "Alice")
        #expect(state.dmConversations[senderId]?.messages.first?.from == "Alice")
        #expect(state.allMessages.first(where: { $0.fromId == senderId })?.from == "Alice")
        #expect(state.channelMessages[0]?.first(where: { $0.fromId == senderId })?.from == "Alice")
        #expect(state.allMessages.first(where: { $0.fromId == 0x0000_beef })?.from == "Bob")
    }

    @Test("cipher survives a Core Data round trip and is cleared by the decrypted update")
    func persistenceRoundTrip() {
        let controller = PersistenceController(
            managedObjectModel: TestModelFactory.makeModel(),
            inMemory: true
        )
        let store = MeshCoreDataStore(persistenceController: controller)
        let original = placeholder()

        store.upsertMessage(original, isDirect: true, partnerNodeId: senderId)
        let stored = store.fetchDirectMessages(partnerNodeId: senderId)
        #expect(stored.count == 1)
        #expect(stored.first?.cipher == original.cipher)
        #expect(stored.first?.canRetryDecrypt == true)

        let decrypted = original.applyingLateDecryption(text: "Servus", hasAlertBell: false, replyToPacketId: nil)
        store.upsertMessage(decrypted, isDirect: true, partnerNodeId: senderId)
        // The view context merges background saves asynchronously; refetch fresh values.
        controller.container.viewContext.refreshAllObjects()
        let updated = store.fetchDirectMessages(partnerNodeId: senderId)
        #expect(updated.count == 1)
        #expect(updated.first?.message == "Servus")
        #expect(updated.first?.cipher == nil)
        #expect(updated.first?.isEncrypted == false)

        // A later encrypted duplicate leaves the readable row alone.
        store.upsertMessage(original, isDirect: true, partnerNodeId: senderId)
        controller.container.viewContext.refreshAllObjects()
        #expect(store.fetchDirectMessages(partnerNodeId: senderId).first?.message == "Servus")
    }
}
