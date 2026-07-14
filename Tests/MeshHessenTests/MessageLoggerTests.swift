import Foundation
import Testing

@testable import MeshHessen

@Suite("Message Logger")
struct MessageLoggerTests {
    private func makeLogger() throws -> (logger: MessageLogger, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshHessen-MessageLoggerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (MessageLogger(logsDir: directory), directory)
    }

    @Test("Deleting channel messages removes logs from before and after a rename")
    func deleteChannelMessages() throws {
        let (logger, directory) = try makeLogger()
        defer { try? FileManager.default.removeItem(at: directory) }

        logger.logChannelMessage(message(channelIndex: 1, channelName: "Old Name"))
        logger.logChannelMessage(message(channelIndex: 1, channelName: "New Name"))
        logger.logChannelMessage(message(channelIndex: 2, channelName: "Other Channel"))

        #expect(logger.deleteChannelMessages(channelIndex: 1) == 2)
        #expect(logger.discoverChannelLogFiles().map(\.index) == [2])
        #expect(logger.loadChannelMessages(channelIndex: 1, channelName: "Old Name").isEmpty)
        #expect(logger.loadChannelMessages(channelIndex: 1, channelName: "New Name").isEmpty)
    }

    @Test("Deleting direct messages removes logs across partner name changes")
    func deleteDirectMessages() throws {
        let (logger, directory) = try makeLogger()
        defer { try? FileManager.default.removeItem(at: directory) }

        let partnerNodeId: UInt32 = 0x1234ABCD
        let directMessage = MessageItem(
            time: "12:00:00",
            from: "Peer",
            fromId: partnerNodeId,
            toId: 1,
            message: "Hello",
            channelIndex: 0,
            channelName: ""
        )
        logger.logDirectMessage(directMessage, partnerName: "Old Name", partnerNodeId: partnerNodeId)
        logger.logDirectMessage(directMessage, partnerName: "New Name", partnerNodeId: partnerNodeId)

        #expect(logger.deleteDirectMessages(partnerNodeId: partnerNodeId) == 2)
        #expect(logger.discoverDMLogFiles().isEmpty)
        #expect(logger.loadDirectMessages(partnerNodeId: partnerNodeId, partnerName: "Old Name").isEmpty)
        #expect(logger.loadDirectMessages(partnerNodeId: partnerNodeId, partnerName: "New Name").isEmpty)
    }

    private func message(channelIndex: Int, channelName: String) -> MessageItem {
        MessageItem(
            time: "12:00:00",
            from: "Tester",
            fromId: 1,
            toId: 0xFFFFFFFF,
            message: "Hello",
            channelIndex: channelIndex,
            channelName: channelName
        )
    }
}
