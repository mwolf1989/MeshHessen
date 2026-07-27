import CoreData
import Foundation
import Testing

@testable import MeshHessen

@Suite("Message Persistence Parity")
struct MessagePersistenceParityTests {
    private func makeStore() -> (MeshCoreDataStore, PersistenceController) {
        let controller = PersistenceController(
            managedObjectModel: TestModelFactory.makeModel(),
            inMemory: true
        )
        return (MeshCoreDataStore(persistenceController: controller), controller)
    }

    private func message(
        id: UUID = UUID(),
        packetId: UInt32? = 42,
        senderId: UInt32 = 100,
        channelIndex: Int = 0,
        createdAt: Date = Date(),
        text: String = "Test"
    ) -> MessageItem {
        MessageItem(
            id: id,
            createdAt: createdAt,
            packetId: packetId,
            time: "12:00:00",
            from: "Node \(senderId)",
            fromId: senderId,
            toId: 0xFFFFFFFF,
            message: text,
            channelIndex: channelIndex,
            channelName: "Channel \(channelIndex)"
        )
    }

    @Test("Durable identity includes sender and channel context")
    func durableIdentityIncludesSenderAndContext() {
        let first = message(packetId: 7, senderId: 1, channelIndex: 0)
        let same = message(packetId: 7, senderId: 1, channelIndex: 0)
        let otherSender = message(packetId: 7, senderId: 2, channelIndex: 0)

        #expect(first.persistenceKey(in: .channel(0)) == same.persistenceKey(in: .channel(0)))
        #expect(first.persistenceKey(in: .channel(0)) != otherSender.persistenceKey(in: .channel(0)))
        #expect(first.persistenceKey(in: .channel(0)) != first.persistenceKey(in: .channel(1)))
    }

    @Test("Packetless messages use their stable UUID")
    func packetlessIdentityUsesUUID() {
        let id = UUID()
        let first = message(id: id, packetId: nil, senderId: 0)
        let same = message(id: id, packetId: nil, senderId: 0)
        let other = message(packetId: nil, senderId: 0)

        #expect(first.persistenceKey(in: .channel(0)) == same.persistenceKey(in: .channel(0)))
        #expect(first.persistenceKey(in: .channel(0)) != other.persistenceKey(in: .channel(0)))
    }

    @Test("UTF-8 payload truncation preserves character boundaries")
    func payloadLimitPreservesCharacters() {
        let text = String(repeating: "🙂", count: 51)
        let limited = MessageItem.truncatingToPayloadLimit(text)

        #expect(MessageItem.payloadByteCount(limited) == 200)
        #expect(limited.count == 50)
        #expect(String(decoding: limited.utf8, as: UTF8.self) == limited)
    }

    @Test("Equal packet IDs from different senders remain separate")
    func packetIdCollisionAcrossSenders() {
        let (store, _) = makeStore()
        store.upsertMessage(message(packetId: 99, senderId: 1), isDirect: false, partnerNodeId: nil)
        store.upsertMessage(message(packetId: 99, senderId: 2), isDirect: false, partnerNodeId: nil)

        let persisted = store.fetchChannelMessages(channelIndex: 0)
        #expect(persisted.count == 2)
        #expect(Set(persisted.map(\.fromId)) == Set([1, 2]))
    }

    @Test("Disabled history stops new writes without deleting existing data")
    func disabledHistoryPreservesExistingData() throws {
        let controller = PersistenceController(
            managedObjectModel: TestModelFactory.makeModel(),
            inMemory: true
        )
        let enabledStore = MeshCoreDataStore(persistenceController: controller)
        enabledStore.upsertMessage(
            message(packetId: 1, text: "Existing"),
            isDirect: false,
            partnerNodeId: nil
        )

        let disabledStore = MeshCoreDataStore(
            persistenceController: controller,
            isMessageHistoryEnabled: { false }
        )
        disabledStore.upsertMessage(
            message(packetId: 2, text: "Must not persist"),
            isDirect: false,
            partnerNodeId: nil
        )

        let request = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
        #expect(try controller.container.viewContext.count(for: request) == 1)
        #expect(enabledStore.fetchChannelMessages(channelIndex: 0).map(\.message) == ["Existing"])
    }

    @Test("Equal sender and packet IDs remain separate across channels")
    func packetIdCollisionAcrossChannels() {
        let (store, _) = makeStore()
        store.upsertMessage(
            message(packetId: 99, senderId: 1, channelIndex: 0),
            isDirect: false,
            partnerNodeId: nil
        )
        store.upsertMessage(
            message(packetId: 99, senderId: 1, channelIndex: 1),
            isDirect: false,
            partnerNodeId: nil
        )

        #expect(store.fetchChannelMessages(channelIndex: 0).count == 1)
        #expect(store.fetchChannelMessages(channelIndex: 1).count == 1)
    }

    @Test("Unknown channel hashes remain distinct during Core Data upsert")
    func unknownHashCollisionDuringUpsert() {
        let (store, _) = makeStore()
        var hashFive = message(
            packetId: 99,
            senderId: 1,
            channelIndex: MessageItem.unknownChannelIndex,
            text: "Hash 5"
        )
        hashFive.channelName = MessageItem.unknownChannelName(hash: 5)
        hashFive.isEncrypted = true
        var hashSixtySeven = hashFive
        hashSixtySeven.id = UUID()
        hashSixtySeven.channelName = MessageItem.unknownChannelName(hash: 67)
        hashSixtySeven.message = "Hash 67"

        store.upsertMessage(hashFive, isDirect: false, partnerNodeId: nil)
        store.upsertMessage(hashSixtySeven, isDirect: false, partnerNodeId: nil)

        let persisted = store.fetchChannelMessages(
            channelIndex: MessageItem.unknownChannelIndex
        )
        #expect(persisted.count == 2)
        #expect(Set(persisted.map(\.message)) == Set(["Hash 5", "Hash 67"]))
        #expect(
            Set(persisted.map(\.channelName))
                == Set([
                    MessageItem.unknownChannelName(hash: 5),
                    MessageItem.unknownChannelName(hash: 67),
                ])
        )
    }

    @Test("Packetless message updates and hydrates with the same UUID")
    @MainActor
    func packetlessMessageRoundTrip() throws {
        let (store, controller) = makeStore()
        let id = UUID()
        let original = message(id: id, packetId: nil, senderId: 0, text: "Imported")
        var updated = original
        updated.message = "Updated import"

        store.upsertMessage(original, isDirect: false, partnerNodeId: nil)
        store.upsertMessage(updated, isDirect: false, partnerNodeId: nil)

        let request = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
        #expect(try controller.container.viewContext.count(for: request) == 1)

        let restartedState = AppState()
        _ = store.hydrate(appState: restartedState)
        let hydrated = try #require(restartedState.channelMessages[0]?.first)
        #expect(hydrated.id == id)
        #expect(hydrated.packetId == nil)
        #expect(hydrated.message == "Updated import")
    }

    @Test("Reaction mutations survive hydration")
    @MainActor
    func reactionsSurviveHydration() throws {
        let (store, _) = makeStore()
        let original = message(packetId: 123, senderId: 5)
        store.upsertMessage(original, isDirect: false, partnerNodeId: nil)

        let liveState = AppState()
        liveState.onMessageMutation = { message, context in
            store.replaceReactions(for: message, context: context)
        }
        liveState.appendMessage(original, markUnread: false)
        liveState.addReaction(
            emoji: "👍",
            from: 77,
            toPacketId: 123,
            context: .channel(0)
        )

        let restartedState = AppState()
        _ = store.hydrate(appState: restartedState)
        let hydrated = try #require(restartedState.channelMessages[0]?.first)
        #expect(hydrated.reactionsByEmoji["👍"] == [77])
    }

    @Test("Read DM remains read after message hydration")
    @MainActor
    func readConversationRemainsRead() throws {
        let (store, _) = makeStore()
        var directMessage = message(packetId: 700, senderId: 42)
        directMessage.toId = 1
        store.upsertMessage(
            directMessage,
            isDirect: true,
            partnerNodeId: 42,
            partnerName: "Peer"
        )
        store.setConversationUnread(partnerNodeId: 42, hasUnread: false)

        let restartedState = AppState()
        _ = store.hydrate(appState: restartedState)
        let conversation = try #require(restartedState.dmConversations[42])
        #expect(!conversation.hasUnread)
        #expect(conversation.messages.count == 1)
    }

    @Test("Cursor paging returns every message once in chronological pages")
    func cursorPaging() {
        let (store, _) = makeStore()
        let base = Date(timeIntervalSince1970: 2_000_000_000)
        for index in 1...5 {
            store.upsertMessage(
                message(
                    packetId: UInt32(index),
                    createdAt: base.addingTimeInterval(Double(index)),
                    text: "Message \(index)"
                ),
                isDirect: false,
                partnerNodeId: nil
            )
        }

        let first = store.fetchChannelMessagePage(channelIndex: 0, limit: 2)
        let second = store.fetchChannelMessagePage(channelIndex: 0, limit: 2, before: first.nextCursor)
        let third = store.fetchChannelMessagePage(channelIndex: 0, limit: 2, before: second.nextCursor)

        #expect(first.messages.map(\.message) == ["Message 4", "Message 5"])
        #expect(second.messages.map(\.message) == ["Message 2", "Message 3"])
        #expect(third.messages.map(\.message) == ["Message 1"])
        #expect(first.hasMore)
        #expect(second.hasMore)
        #expect(!third.hasMore)
        #expect(Set((first.messages + second.messages + third.messages).map(\.id)).count == 5)
    }

    @Test("Retention and range deletion use message creation dates")
    func retentionAndDeletionScopes() {
        let (store, _) = makeStore()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        for (packetId, age) in [(UInt32(1), 10), (UInt32(2), 40), (UInt32(3), 100)] {
            store.upsertMessage(
                message(
                    packetId: packetId,
                    createdAt: Calendar.current.date(byAdding: .day, value: -age, to: now) ?? now
                ),
                isDirect: false,
                partnerNodeId: nil
            )
        }

        let deleted = store.deleteChannelMessages(
            channelIndex: 0,
            scope: .olderThanThirtyDays,
            relativeTo: now
        )
        #expect(deleted == 2)
        #expect(store.fetchChannelMessages(channelIndex: 0).count == 1)
        #expect(store.enforceMessageRetention(.unlimited, relativeTo: now) == 0)
    }

    @Test("Legacy encrypted broadcasts are normalized idempotently")
    @MainActor
    func legacyEncryptedBroadcastNormalization() throws {
        let (store, controller) = makeStore()
        let viewContext = controller.container.viewContext

        func insertLegacy(channelIndex: Int32, channelName: String) {
            let object = NSEntityDescription.insertNewObject(
                forEntityName: "MHMessageEntity",
                into: viewContext
            )
            object.setValue(UUID(), forKey: "messageUUID")
            object.setValue("packet:7:81:channel:\(channelIndex)", forKey: "persistenceKey")
            object.setValue(Int64(81), forKey: "packetId")
            object.setValue(Date(), forKey: "createdAt")
            object.setValue("12:00:00", forKey: "timeText")
            object.setValue("Node 7", forKey: "fromName")
            object.setValue(Int64(7), forKey: "fromId")
            object.setValue(Int64(UInt32.max), forKey: "toId")
            object.setValue("", forKey: "messageText")
            object.setValue(channelIndex, forKey: "channelIndex")
            object.setValue(true, forKey: "isEncrypted")
            object.setValue(channelName, forKey: "channelName")
            object.setValue(false, forKey: "isDirect")
        }

        insertLegacy(channelIndex: 5, channelName: "Secondary")
        insertLegacy(
            channelIndex: 0,
            channelName: MessageItem.unknownChannelName(hash: 67)
        )
        try viewContext.save()

        let firstState = AppState()
        _ = store.hydrate(appState: firstState)

        #expect(firstState.allMessages.count == 2)
        #expect(firstState.allMessages.allSatisfy {
            $0.channelIndex == MessageItem.unknownChannelIndex
        })
        #expect(Set(firstState.allMessages.map(\.channelName)) == Set([
            MessageItem.unknownChannelName(hash: 5),
            MessageItem.unknownChannelName(hash: 67),
        ]))
        #expect(firstState.channelMessages[5] == nil)
        #expect(firstState.channelMessages[MessageItem.unknownChannelIndex] == nil)
        #expect(store.fetchChannelMessages(channelIndex: 5).isEmpty)
        #expect(
            store.fetchChannelMessages(channelIndex: MessageItem.unknownChannelIndex).count == 2
        )

        let secondState = AppState()
        _ = store.hydrate(appState: secondState)
        #expect(secondState.allMessages.count == 2)
        #expect(secondState.allMessages.allSatisfy {
            $0.channelIndex == MessageItem.unknownChannelIndex
        })

        let verificationContext = controller.newBackgroundContext()
        var storedIndices: Set<Int> = []
        var storedNames: Set<String> = []
        var storedKeys: Set<String> = []
        verificationContext.performAndWait {
            let verificationRequest = NSFetchRequest<NSManagedObject>(
                entityName: "MHMessageEntity"
            )
            let storedObjects = (try? verificationContext.fetch(verificationRequest)) ?? []
            storedIndices = Set(storedObjects.compactMap {
                ($0.value(forKey: "channelIndex") as? NSNumber)?.intValue
            })
            storedNames = Set(storedObjects.compactMap {
                $0.value(forKey: "channelName") as? String
            })
            storedKeys = Set(storedObjects.compactMap {
                $0.value(forKey: "persistenceKey") as? String
            })
        }
        #expect(storedIndices == [MessageItem.unknownChannelIndex])
        #expect(storedNames == Set([
            MessageItem.unknownChannelName(hash: 5),
            MessageItem.unknownChannelName(hash: 67),
        ]))
        #expect(storedKeys == Set([
            "packet:7:81:channel:\(MessageItem.unknownChannelIndex):hash:5",
            "packet:7:81:channel:\(MessageItem.unknownChannelIndex):hash:67",
        ]))
    }

    @Test("Encrypted direct messages retain their conversation channel context")
    func encryptedDirectMessageRetainsChannel() throws {
        let (store, _) = makeStore()
        var directMessage = message(packetId: 82, senderId: 8, channelIndex: 5)
        directMessage.toId = 1
        directMessage.isEncrypted = true

        store.upsertMessage(
            directMessage,
            isDirect: true,
            partnerNodeId: 8,
            partnerName: "Peer"
        )

        let persisted = try #require(store.fetchDirectMessages(partnerNodeId: 8).first)
        #expect(persisted.channelIndex == 5)
        #expect(persisted.channelName == "Channel 5")
    }
}
