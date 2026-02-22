import Testing
import Foundation
import CoreData
@testable import MeshHessen

// MARK: - CoreData Persistence Tests

@Suite("CoreData Persistence")
struct PersistenceTests {

    // MARK: - Helpers

    /// Creates an in-memory PersistenceController + MeshCoreDataStore for testing.
    private func makeStore() -> (MeshCoreDataStore, PersistenceController) {
        let pc = PersistenceController(inMemory: true)
        let store = MeshCoreDataStore(persistenceController: pc)
        return (store, pc)
    }

    private func sampleNode(id: UInt32 = 0xABCD0001) -> NodeInfo {
        let node = NodeInfo(id: id, nodeId: String(format: "!%08x", id), shortName: "TST", longName: "Test Node")
        node.latitude = 50.1
        node.longitude = 8.7
        node.batteryLevel = 80
        node.snrFloat = 5.5
        node.colorHex = "#FF0000"
        node.note = "A test note"
        return node
    }

    private func sampleMessage(packetId: UInt32 = 42, channelIndex: Int = 0) -> MessageItem {
        MessageItem(
            packetId: packetId,
            time: "12:00:00",
            from: "TestNode",
            fromId: 100,
            toId: 0xFFFFFFFF,
            message: "Hello from tests",
            channelIndex: channelIndex,
            channelName: "TestChannel",
            senderShortName: "TST"
        )
    }

    // MARK: - Node CRUD

    @Test("upsertNode persists a node")
    func upsertNode() async throws {
        let (store, pc) = makeStore()
        let node = sampleNode()

        store.upsertNode(node)

        // Give background context time to complete
        try await Task.sleep(for: .milliseconds(200))

        let context = pc.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "MHNodeEntity")
        request.predicate = NSPredicate(format: "nodeNum == %lld", Int64(node.id))
        let results = try context.fetch(request)
        #expect(results.count == 1)

        let obj = results[0]
        #expect(obj.value(forKey: "shortName") as? String == "TST")
        #expect(obj.value(forKey: "longName") as? String == "Test Node")
        #expect(obj.value(forKey: "colorHex") as? String == "#FF0000")
        #expect(obj.value(forKey: "note") as? String == "A test note")
    }

    @Test("upsertNode updates existing node")
    func upsertNodeUpdate() async throws {
        let (store, pc) = makeStore()
        let node = sampleNode()

        store.upsertNode(node)
        try await Task.sleep(for: .milliseconds(200))

        // Update values
        node.longName = "Updated Name"
        node.note = "Updated note"
        store.upsertNode(node)
        try await Task.sleep(for: .milliseconds(200))

        let context = pc.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "MHNodeEntity")
        request.predicate = NSPredicate(format: "nodeNum == %lld", Int64(node.id))
        let results = try context.fetch(request)
        #expect(results.count == 1)
        #expect(results[0].value(forKey: "longName") as? String == "Updated Name")
        #expect(results[0].value(forKey: "note") as? String == "Updated note")
    }

    // MARK: - Channel CRUD

    @Test("upsertChannel persists a channel")
    func upsertChannel() async throws {
        let (store, pc) = makeStore()
        let ch = ChannelInfo(id: 0, name: "Mesh Hessen", psk: "abc==", role: "PRIMARY",
                            uplinkEnabled: true, downlinkEnabled: false)

        store.upsertChannel(ch)
        try await Task.sleep(for: .milliseconds(200))

        let context = pc.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "MHChannelEntity")
        let results = try context.fetch(request)
        #expect(results.count == 1)
        #expect(results[0].value(forKey: "name") as? String == "Mesh Hessen")
        #expect(results[0].value(forKey: "role") as? String == "PRIMARY")
        #expect(results[0].value(forKey: "uplinkEnabled") as? Bool == true)
    }

    // MARK: - Message CRUD

    @Test("upsertMessage persists a channel message")
    func upsertMessage() async throws {
        let (store, pc) = makeStore()
        let msg = sampleMessage()

        store.upsertMessage(msg, isDirect: false, partnerNodeId: nil)
        try await Task.sleep(for: .milliseconds(200))

        let context = pc.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
        request.predicate = NSPredicate(format: "packetId == %lld", Int64(42))
        let results = try context.fetch(request)
        #expect(results.count == 1)
        #expect(results[0].value(forKey: "messageText") as? String == "Hello from tests")
        #expect(results[0].value(forKey: "isDirect") as? Bool == false)
    }

    @Test("messageExists returns true for existing packetId")
    func messageExistsTrue() async throws {
        let (store, _) = makeStore()
        let msg = sampleMessage(packetId: 999)

        store.upsertMessage(msg, isDirect: false, partnerNodeId: nil)
        try await Task.sleep(for: .milliseconds(200))

        #expect(store.messageExists(packetId: 999))
    }

    @Test("messageExists returns false for unknown packetId")
    func messageExistsFalse() {
        let (store, _) = makeStore()
        #expect(!store.messageExists(packetId: 12345))
    }

    @Test("messageExists returns false for packetId 0")
    func messageExistsZero() {
        let (store, _) = makeStore()
        #expect(!store.messageExists(packetId: 0))
    }

    // MARK: - Delivery State

    @Test("updateDeliveryState updates to acknowledged")
    func updateDeliveryState() async throws {
        let (store, pc) = makeStore()
        let msg = sampleMessage(packetId: 500)
        store.upsertMessage(msg, isDirect: false, partnerNodeId: nil)
        try await Task.sleep(for: .milliseconds(200))

        store.updateDeliveryState(requestId: 500, state: .acknowledged)
        try await Task.sleep(for: .milliseconds(200))

        let context = pc.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
        request.predicate = NSPredicate(format: "packetId == %lld", Int64(500))
        let results = try context.fetch(request)
        #expect(results.count == 1)
        #expect(results[0].value(forKey: "deliveryState") as? String == "acknowledged")
    }

    @Test("updateDeliveryState updates to failed with reason")
    func updateDeliveryStateFailed() async throws {
        let (store, pc) = makeStore()
        let msg = sampleMessage(packetId: 501)
        store.upsertMessage(msg, isDirect: false, partnerNodeId: nil)
        try await Task.sleep(for: .milliseconds(200))

        store.updateDeliveryState(requestId: 501, state: .failed("Timeout"))
        try await Task.sleep(for: .milliseconds(200))

        let context = pc.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
        request.predicate = NSPredicate(format: "packetId == %lld", Int64(501))
        let results = try context.fetch(request)
        #expect(results.count == 1)
        #expect(results[0].value(forKey: "deliveryState") as? String == "failed")
        #expect(results[0].value(forKey: "deliveryError") as? String == "Timeout")
    }

    // MARK: - Node Customization

    @Test("updateNodeCustomization creates/updates node color and note")
    func updateNodeCustomization() async throws {
        let (store, pc) = makeStore()

        store.updateNodeCustomization(nodeId: 0x1234, colorHex: "#00FF00", note: "Green node")
        try await Task.sleep(for: .milliseconds(200))

        let context = pc.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "MHNodeEntity")
        request.predicate = NSPredicate(format: "nodeNum == %lld", Int64(0x1234))
        let results = try context.fetch(request)
        #expect(results.count == 1)
        #expect(results[0].value(forKey: "colorHex") as? String == "#00FF00")
        #expect(results[0].value(forKey: "note") as? String == "Green node")
    }

    // MARK: - Conversation Unread

    @Test("upsertMessage with isDirect creates conversation entity")
    func dmCreatesConversation() async throws {
        let (store, pc) = makeStore()
        let msg = MessageItem(
            packetId: 700, time: "12:00", from: "Node42", fromId: 42, toId: 1,
            message: "DM test", channelIndex: 0, channelName: "ch0"
        )

        store.upsertMessage(msg, isDirect: true, partnerNodeId: 42, partnerName: "Node42")
        try await Task.sleep(for: .milliseconds(200))

        let context = pc.container.viewContext
        let convRequest = NSFetchRequest<NSManagedObject>(entityName: "MHConversationEntity")
        convRequest.predicate = NSPredicate(format: "partnerNodeId == %lld", Int64(42))
        let results = try context.fetch(convRequest)
        #expect(results.count == 1)
        #expect(results[0].value(forKey: "nodeName") as? String == "Node42")
    }

    @Test("setConversationUnread updates hasUnread flag")
    func setConversationUnread() async throws {
        let (store, pc) = makeStore()
        // First create a DM so conversation entity exists
        let msg = MessageItem(
            packetId: 800, time: "12:00", from: "Peer", fromId: 55, toId: 1,
            message: "Hello", channelIndex: 0, channelName: "ch0"
        )
        store.upsertMessage(msg, isDirect: true, partnerNodeId: 55, partnerName: "Peer")
        try await Task.sleep(for: .milliseconds(200))

        store.setConversationUnread(partnerNodeId: 55, hasUnread: true)
        try await Task.sleep(for: .milliseconds(200))

        let context = pc.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "MHConversationEntity")
        request.predicate = NSPredicate(format: "partnerNodeId == %lld", Int64(55))
        let results = try context.fetch(request)
        #expect(results.count == 1)
        #expect(results[0].value(forKey: "hasUnread") as? Bool == true)
    }

    // MARK: - Batch Operations

    @Test("clearAllData removes all entities")
    func clearAllData() async throws {
        let (store, pc) = makeStore()

        // Seed some data
        store.upsertNode(sampleNode())
        store.upsertChannel(ChannelInfo(id: 0, name: "Ch", psk: "", role: "PRIMARY",
                                        uplinkEnabled: false, downlinkEnabled: false))
        store.upsertMessage(sampleMessage(), isDirect: false, partnerNodeId: nil)
        try await Task.sleep(for: .milliseconds(300))

        store.clearAllData()
        try await Task.sleep(for: .milliseconds(300))

        let context = pc.container.viewContext
        for entity in ["MHNodeEntity", "MHChannelEntity", "MHMessageEntity"] {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            let count = try context.count(for: request)
            #expect(count == 0, "Expected 0 \(entity) objects after clearAllData")
        }
    }

    @Test("deleteChannelMessages removes only targeted channel")
    func deleteChannelMessages() async throws {
        let (store, pc) = makeStore()

        // Create messages on different channels
        store.upsertMessage(sampleMessage(packetId: 1, channelIndex: 0), isDirect: false, partnerNodeId: nil)
        store.upsertMessage(sampleMessage(packetId: 2, channelIndex: 0), isDirect: false, partnerNodeId: nil)
        store.upsertMessage(sampleMessage(packetId: 3, channelIndex: 1), isDirect: false, partnerNodeId: nil)
        try await Task.sleep(for: .milliseconds(300))

        store.deleteChannelMessages(channelIndex: 0)
        try await Task.sleep(for: .milliseconds(300))

        let context = pc.container.viewContext

        // Channel 0 should be empty
        let req0 = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
        req0.predicate = NSPredicate(format: "channelIndex == 0 AND isDirect == NO")
        let count0 = try context.count(for: req0)
        #expect(count0 == 0)

        // Channel 1 should still have its message
        let req1 = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
        req1.predicate = NSPredicate(format: "channelIndex == 1 AND isDirect == NO")
        let count1 = try context.count(for: req1)
        #expect(count1 == 1)
    }

    // MARK: - Paged Fetch

    @Test("fetchChannelMessages returns messages for specific channel")
    func fetchChannelMessages() async throws {
        let (store, _) = makeStore()

        for i: UInt32 in 1...5 {
            var msg = sampleMessage(packetId: i, channelIndex: 0)
            msg.message = "Msg \(i)"
            store.upsertMessage(msg, isDirect: false, partnerNodeId: nil)
        }
        try await Task.sleep(for: .milliseconds(300))

        let messages = store.fetchChannelMessages(channelIndex: 0, limit: 3)
        #expect(messages.count == 3)
    }
}
