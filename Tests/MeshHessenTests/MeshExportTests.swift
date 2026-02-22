import Testing
import Foundation
@testable import MeshHessen

// MARK: - MeshExport CSV Tests

@Suite("MeshExport CSV Generation")
struct MeshExportTests {

    // MARK: - Nodes CSV

    @Test("nodesToCsv generates correct header")
    func nodesHeader() {
        let csv = MeshExport.nodesToCsv([])
        let firstLine = csv.components(separatedBy: "\n").first ?? ""
        #expect(firstLine.contains("NodeID"))
        #expect(firstLine.contains("ShortName"))
        #expect(firstLine.contains("Latitude"))
        #expect(firstLine.contains("Longitude"))
        #expect(firstLine.contains("Battery%"))
    }

    @Test("nodesToCsv includes node data")
    func nodesData() {
        let node = NodeInfo(id: 0xABCD1234, nodeId: "!abcd1234", shortName: "TST", longName: "Test Node")
        node.latitude = 50.12345
        node.longitude = 8.67890
        node.batteryLevel = 85
        node.snrFloat = 6.5
        node.viaMqtt = true

        let csv = MeshExport.nodesToCsv([node])
        let lines = csv.components(separatedBy: "\n").filter { !$0.isEmpty }

        #expect(lines.count == 2) // header + 1 data row
        #expect(lines[1].contains("!abcd1234"))
        #expect(lines[1].contains("TST"))
        #expect(lines[1].contains("Test Node"))
        #expect(lines[1].contains("50.1234500"))
        #expect(lines[1].contains("8.6789000"))
        #expect(lines[1].contains("true")) // viaMqtt
    }

    @Test("nodesToCsv escapes commas in names")
    func nodesEscapeComma() {
        let node = NodeInfo(id: 1, nodeId: "!00000001", shortName: "A,B", longName: "Test, Node")

        let csv = MeshExport.nodesToCsv([node])
        // Comma-containing fields should be quoted
        #expect(csv.contains("\"A,B\""))
        #expect(csv.contains("\"Test, Node\""))
    }

    // MARK: - Messages CSV

    @Test("messagesToCsv generates correct header")
    func messagesHeader() {
        let csv = MeshExport.messagesToCsv([])
        let firstLine = csv.components(separatedBy: "\n").first ?? ""
        #expect(firstLine.contains("PacketID"))
        #expect(firstLine.contains("Time"))
        #expect(firstLine.contains("Message"))
        #expect(firstLine.contains("DeliveryState"))
    }

    @Test("messagesToCsv includes message data")
    func messagesData() {
        let msg = MessageItem(
            packetId: 12345,
            time: "10:30:00",
            from: "TestNode",
            fromId: 100,
            toId: 0xFFFFFFFF,
            message: "Hello Mesh!",
            channelIndex: 0,
            channelName: "Mesh Hessen",
            isViaMqtt: false,
            senderShortName: "TST"
        )

        let csv = MeshExport.messagesToCsv([msg])
        let lines = csv.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 2)
        #expect(lines[1].contains("12345"))
        #expect(lines[1].contains("Hello Mesh!"))
        #expect(lines[1].contains("Mesh Hessen"))
    }

    @Test("messagesToCsv escapes message text with commas")
    func messagesEscapeComma() {
        let msg = MessageItem(
            packetId: 1, time: "12:00", from: "A", fromId: 1, toId: 2,
            message: "Hello, World", channelIndex: 0, channelName: "ch0"
        )

        let csv = MeshExport.messagesToCsv([msg])
        #expect(csv.contains("\"Hello, World\""))
    }

    // MARK: - Channels CSV

    @Test("channelsToCsv generates correct header")
    func channelsHeader() {
        let csv = MeshExport.channelsToCsv([])
        let firstLine = csv.components(separatedBy: "\n").first ?? ""
        #expect(firstLine.contains("Index"))
        #expect(firstLine.contains("Name"))
        #expect(firstLine.contains("Role"))
        #expect(firstLine.contains("PSK"))
    }

    @Test("channelsToCsv includes channel data")
    func channelsData() {
        let ch = ChannelInfo(id: 0, name: "Mesh Hessen", psk: "abc123==", role: "PRIMARY",
                             uplinkEnabled: true, downlinkEnabled: false)

        let csv = MeshExport.channelsToCsv([ch])
        let lines = csv.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 2)
        #expect(lines[1].contains("Mesh Hessen"))
        #expect(lines[1].contains("PRIMARY"))
        #expect(lines[1].contains("abc123=="))
        #expect(lines[1].contains("true"))
    }

    // MARK: - Positions CSV

    @Test("positionsToCsv skips nodes without GPS")
    func positionsSkipNoGps() {
        let nodeNoGps = NodeInfo(id: 1, nodeId: "!00000001", shortName: "A", longName: "No GPS")
        // no latitude/longitude set

        let csv = MeshExport.positionsToCsv([nodeNoGps])
        let lines = csv.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 1) // header only
    }

    @Test("positionsToCsv includes nodes with GPS")
    func positionsWithGps() {
        let node = NodeInfo(id: 2, nodeId: "!00000002", shortName: "B", longName: "Has GPS")
        node.latitude = 50.0
        node.longitude = 8.5
        node.altitude = 200

        let csv = MeshExport.positionsToCsv([node])
        let lines = csv.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 2)
        #expect(lines[1].contains("50.0000000"))
        #expect(lines[1].contains("8.5000000"))
        #expect(lines[1].contains("200"))
    }
}
