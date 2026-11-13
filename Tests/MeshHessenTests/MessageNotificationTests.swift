import Foundation
import Testing
@testable import MeshHessen

@Suite("Message notifications")
struct MessageNotificationTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Input {
        var isOwn = false
        var isEncryptedPlaceholder = false
        var text = "Hallo"
        var age: TimeInterval = 10
        var appIsActive = false
        var enabled = true
        var isInitializing = false

        func evaluate() -> Bool {
            MessageNotificationService.shouldNotify(
                isOwn: isOwn,
                isEncryptedPlaceholder: isEncryptedPlaceholder,
                text: text,
                messageDate: MessageNotificationTests.now.addingTimeInterval(-age),
                now: MessageNotificationTests.now,
                appIsActive: appIsActive,
                enabled: enabled,
                isInitializing: isInitializing
            )
        }
    }

    @Test("A live message from someone else notifies while the app is in the background")
    func baseline() {
        #expect(Input().evaluate())
    }

    @Test("Each condition suppresses the notification", arguments: [
        "own", "placeholder", "empty", "whitespace", "old", "active", "disabled", "initializing",
    ])
    func eachConditionFlips(_ condition: String) {
        var input = Input()
        switch condition {
        case "own": input.isOwn = true
        case "placeholder": input.isEncryptedPlaceholder = true
        case "empty": input.text = ""
        case "whitespace": input.text = "  \n"
        case "old": input.age = 181
        case "active": input.appIsActive = true
        case "disabled": input.enabled = false
        case "initializing": input.isInitializing = true
        default: Issue.record("unknown condition \(condition)")
        }
        #expect(!input.evaluate())
    }

    @Test("Exactly 180 s old still counts as live")
    func ageBoundary() {
        var input = Input()
        input.age = 180
        #expect(input.evaluate())
    }

    @Test("Backlog guard for sound, bounce and window")
    func isLive() {
        let now = Self.now
        #expect(MessageNotificationService.isLive(messageDate: now, now: now, isInitializing: false))
        #expect(!MessageNotificationService.isLive(messageDate: now, now: now, isInitializing: true))
        #expect(!MessageNotificationService.isLive(
            messageDate: now.addingTimeInterval(-600), now: now, isInitializing: false
        ))
    }

    @Test("rx_time without a valid clock falls back to now")
    func messageDate() {
        let now = Self.now
        #expect(MessageNotificationService.messageDate(rxTime: 0, now: now) == now)
        #expect(MessageNotificationService.messageDate(rxTime: 3_600, now: now) == now)
        #expect(
            MessageNotificationService.messageDate(rxTime: 1_799_999_000, now: now)
                == Date(timeIntervalSince1970: 1_799_999_000)
        )
    }

    // MARK: - Summary

    private func event(_ sender: String, _ conversation: String, _ text: String) -> MessageNotificationEvent {
        MessageNotificationEvent(sender: sender, conversation: conversation, text: text, target: .channel(0))
    }

    @Test("No events, no summary")
    func emptySummary() {
        #expect(MessageNotificationService.summary(for: []) == nil)
    }

    @Test("One event: title is sender · channel, body is the text")
    func singleSummary() {
        let summary = MessageNotificationService.summary(for: [event("Anna", "MeshHessen", "Hallo")])
        #expect(summary == MessageNotificationSummary(title: "Anna · MeshHessen", subtitle: "", body: "Hallo"))
    }

    @Test("Several events: count title, latest sender · channel as subtitle")
    func batchSummary() {
        let summary = MessageNotificationService.summary(for: [
            event("Anna", "MeshHessen", "1"),
            event("Bernd", "Lokal", "2"),
            event("Carla", "MeshHessen", "3"),
        ])
        #expect(summary?.title.contains("3") == true)
        #expect(summary?.subtitle == "Carla · MeshHessen")
        #expect(summary?.body == "3")
    }
}

@Suite("Messages sidebar")
struct MessagesSidebarModelTests {
    @Test("Selection round-trips through its storage value", arguments: [
        MessagesSidebarSelection.allChannels, .channel(0), .channel(7), .directMessage(0xDEADBEEF),
    ])
    func storageRoundTrip(_ selection: MessagesSidebarSelection) {
        #expect(MessagesSidebarSelection(storageValue: selection.storageValue) == selection)
    }

    @Test("Garbage storage values are rejected")
    func invalidStorage() {
        #expect(MessagesSidebarSelection(storageValue: "") == nil)
        #expect(MessagesSidebarSelection(storageValue: "ch:x") == nil)
        #expect(MessagesSidebarSelection(storageValue: "dm:-1") == nil)
    }

    @Test("Badge text caps at 99+")
    func badgeText() {
        #expect(MessagesSidebarModel.badgeText(count: nil) == nil)
        #expect(MessagesSidebarModel.badgeText(count: 0) == nil)
        #expect(MessagesSidebarModel.badgeText(count: 5) == "5")
        #expect(MessagesSidebarModel.badgeText(count: 99) == "99")
        #expect(MessagesSidebarModel.badgeText(count: 100) == "99+")
        #expect(MessagesSidebarModel.dmBadgeText(count: nil) == nil)
        #expect(MessagesSidebarModel.dmBadgeText(count: 0) == "•")
        #expect(MessagesSidebarModel.dmBadgeText(count: 250) == "99+")
    }

    @Test("Conversations sort by most recent message, then name")
    func sorting() {
        let old = DirectMessageConversation(nodeId: 1, nodeName: "Old")
        old.messages = [TestMessage.make(createdAt: Date(timeIntervalSince1970: 100))]
        let recent = DirectMessageConversation(nodeId: 2, nodeName: "Recent")
        recent.messages = [TestMessage.make(createdAt: Date(timeIntervalSince1970: 200))]
        let emptyB = DirectMessageConversation(nodeId: 3, nodeName: "b")
        let emptyA = DirectMessageConversation(nodeId: 4, nodeName: "A")

        let sorted = MessagesSidebarModel.sortedConversations([emptyB, old, emptyA, recent]) { $0.nodeName }
        #expect(sorted.map(\.id) == [2, 1, 4, 3])
    }
}

@MainActor
@Suite("Inline DM unread tracking")
struct InlineDMUnreadTests {
    private func incoming(from nodeId: UInt32, packetId: UInt32) -> MessageItem {
        var message = TestMessage.make(createdAt: Date())
        message.fromId = nodeId
        message.toId = 1
        message.packetId = packetId
        return message
    }

    @Test("Incoming DMs count up while the conversation is not shown")
    func countsUnread() {
        let state = AppState()
        state.addOrUpdateDM(incoming(from: 42, packetId: 1), myNodeId: 1)
        state.addOrUpdateDM(incoming(from: 42, packetId: 2), myNodeId: 1)
        state.addOrUpdateDM(incoming(from: 42, packetId: 2), myNodeId: 1) // duplicate
        #expect(state.dmUnreadBadgeCount(for: 42) == 2)
    }

    @Test("A conversation shown inline stays read")
    func inlineStaysRead() {
        let state = AppState()
        state.selectedTab = .messages
        state.activeInlineDMNodeId = 42
        state.addOrUpdateDM(incoming(from: 42, packetId: 1), myNodeId: 1)
        #expect(state.dmConversations[42]?.hasUnread == false)
        #expect(state.dmUnreadBadgeCount(for: 42) == nil)
    }

    @Test("The count restarts after the conversation was read")
    func countRestarts() {
        let state = AppState()
        state.addOrUpdateDM(incoming(from: 42, packetId: 1), myNodeId: 1)
        state.addOrUpdateDM(incoming(from: 42, packetId: 2), myNodeId: 1)
        state.dmConversations[42]?.hasUnread = false
        state.addOrUpdateDM(incoming(from: 42, packetId: 3), myNodeId: 1)
        #expect(state.dmUnreadBadgeCount(for: 42) == 1)
    }

    @Test("Channel messages count as unread while an inline DM is shown")
    func channelUnreadWhileInlineDM() {
        let state = AppState()
        state.selectedTab = .messages
        state.selectedChannelIndex = 0
        state.activeInlineDMNodeId = 42
        var message = incoming(from: 42, packetId: 9)
        message.toId = 0xFFFFFFFF
        message.channelIndex = 0
        state.appendMessage(message)
        #expect(state.channelUnreadCounts[0] == 1)
    }
}

private enum TestMessage {
    static func make(createdAt: Date) -> MessageItem {
        var message = MessageItem(
            time: "12:00:00",
            from: "Tester",
            fromId: 2,
            toId: 1,
            message: "Hallo",
            channelIndex: 0,
            channelName: "Primary"
        )
        message.createdAt = createdAt
        return message
    }
}
