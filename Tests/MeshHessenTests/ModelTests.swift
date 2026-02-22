import Testing
import Foundation
@testable import MeshHessen

// MARK: - NavigationState Model Tests

@Suite("NavigationState")
struct NavigationStateTests {

    @Test("Default selectedTab is messages")
    func defaultTab() {
        let state = NavigationState()
        #expect(state.selectedTab == .messages)
    }

    @Test("Tab enum has correct rawValues")
    func tabRawValues() {
        #expect(NavigationState.Tab.messages.rawValue == "messages")
        #expect(NavigationState.Tab.nodes.rawValue == "nodes")
        #expect(NavigationState.Tab.channels.rawValue == "channels")
        #expect(NavigationState.Tab.map.rawValue == "map")
        #expect(NavigationState.Tab.settings.rawValue == "settings")
        #expect(NavigationState.Tab.debug.rawValue == "debug")
        #expect(NavigationState.Tab.info.rawValue == "info")
    }

    @Test("Tab CaseIterable contains all 7 tabs")
    func tabCaseIterable() {
        #expect(NavigationState.Tab.allCases.count == 7)
    }

    @Test("NavigationState conforms to Hashable")
    func hashable() {
        var state1 = NavigationState()
        state1.selectedTab = .messages
        var state2 = NavigationState()
        state2.selectedTab = .messages
        #expect(state1 == state2)

        state2.selectedTab = .nodes
        #expect(state1 != state2)
    }

    @Test("MessagesNavigationState channel with id")
    func messagesChannelNav() {
        let nav = MessagesNavigationState.channels(channelId: 3, messageId: 42)
        if case .channels(channelId: let ch, messageId: let msg) = nav {
            #expect(ch == 3 as Int?)
            #expect(msg == 42 as UInt32?)
        } else {
            Issue.record("Expected .channels case")
        }
    }

    @Test("MessagesNavigationState directMessages with userId")
    func messagesDMNav() {
        let nav = MessagesNavigationState.directMessages(userNum: 12345)
        if case .directMessages(userNum: let num, messageId: _) = nav {
            #expect(num == 12345)
        } else {
            Issue.record("Expected .directMessages case")
        }
    }

    @Test("SettingsNavigationState has expected rawValues")
    func settingsRawValues() {
        #expect(SettingsNavigationState.lora.rawValue == "lora")
        #expect(SettingsNavigationState.bluetooth.rawValue == "bluetooth")
        #expect(SettingsNavigationState.mqtt.rawValue == "mqtt")
        #expect(SettingsNavigationState.security.rawValue == "security")
    }

    @Test("SettingsNavigationState allCases covers all pages")
    func settingsAllCases() {
        #expect(SettingsNavigationState.allCases.count == 17)
    }

    @Test("SettingsNavigationState label is non-empty")
    func settingsLabels() {
        for setting in SettingsNavigationState.allCases {
            #expect(!setting.label.isEmpty, "Label should not be empty for \(setting)")
        }
    }

    @Test("SettingsNavigationState systemImage is non-empty")
    func settingsSystemImages() {
        for setting in SettingsNavigationState.allCases {
            #expect(!setting.systemImage.isEmpty, "systemImage should not be empty for \(setting)")
        }
    }
}

// MARK: - Model Value Tests

@Suite("Model Types")
struct ModelTests {

    @Test("NodeInfo initializer sets name from longName")
    func nodeInfoName() {
        let node = NodeInfo(id: 1, nodeId: "!00000001", shortName: "SH", longName: "Long Name")
        #expect(node.name == "Long Name")
        #expect(node.shortName == "SH")
    }

    @Test("NodeInfo name falls back to shortName when longName is empty")
    func nodeInfoNameFallback() {
        let node = NodeInfo(id: 1, nodeId: "!00000001", shortName: "SH", longName: "")
        #expect(node.name == "SH")
    }

    @Test("NodeInfo color returns nil when colorHex is empty")
    func nodeInfoColorNil() {
        let node = NodeInfo(id: 1, nodeId: "!00000001", shortName: "A", longName: "B")
        #expect(node.color == nil)
    }

    @Test("NodeInfo color returns hex when set")
    func nodeInfoColorSet() {
        let node = NodeInfo(id: 1, nodeId: "!00000001", shortName: "A", longName: "B")
        node.colorHex = "#FF0000"
        #expect(node.color == "#FF0000")
    }

    @Test("NodeInfo defaults have expected values")
    func nodeInfoDefaults() {
        let node = NodeInfo(id: 42, nodeId: "!0000002a", shortName: "T", longName: "Test")
        #expect(node.distance == "-")
        #expect(node.snr == "-")
        #expect(node.rssi == "-")
        #expect(node.battery == "-")
        #expect(node.lastSeen == "-")
        #expect(node.latitude == nil)
        #expect(node.longitude == nil)
        #expect(node.altitude == nil)
        #expect(node.viaMqtt == false)
        #expect(node.lastHeard == 0)
    }

    @Test("MessageItem isDirect for broadcast is false")
    func messageIsDirect() {
        let broadcast = MessageItem(
            time: "12:00", from: "A", fromId: 1, toId: 0xFFFFFFFF,
            message: "test", channelIndex: 0, channelName: "ch0"
        )
        #expect(!broadcast.isDirect)
    }

    @Test("MessageItem isDirect for unicast is true")
    func messageIsDirectUnicast() {
        let dm = MessageItem(
            time: "12:00", from: "A", fromId: 1, toId: 42,
            message: "test", channelIndex: 0, channelName: "ch0"
        )
        #expect(dm.isDirect)
    }

    @Test("ChannelInfo displayName uses name when set")
    func channelDisplayName() {
        let ch = ChannelInfo(id: 0, name: "Mesh Hessen", psk: "", role: "PRIMARY",
                            uplinkEnabled: false, downlinkEnabled: false)
        #expect(ch.displayName == "Mesh Hessen")
    }

    @Test("ChannelInfo displayName falls back to 'Channel N'")
    func channelDisplayNameFallback() {
        let ch = ChannelInfo(id: 3, name: "", psk: "", role: "SECONDARY",
                            uplinkEnabled: false, downlinkEnabled: false)
        #expect(ch.displayName == "Channel 3")
    }

    @Test("ChannelInfo displayName adds MQTT indicator")
    func channelDisplayNameMqtt() {
        let ch = ChannelInfo(id: 0, name: "Mesh Hessen", psk: "", role: "PRIMARY",
                            uplinkEnabled: true, downlinkEnabled: false)
        #expect(ch.displayName.contains("📡"))
    }
}

// MARK: - MeshEnums Tests

@Suite("Routing Error")
struct RoutingErrorTests {

    @Test("RoutingError none is delivered")
    func routingNone() {
        let err = RoutingError.none
        #expect(err.rawValue == 0)
        #expect(!err.display.isEmpty)
    }

    @Test("RoutingError canRetry for retriable errors")
    func retriableErrors() {
        #expect(RoutingError.noRoute.canRetry)
        #expect(RoutingError.timeout.canRetry)
        #expect(RoutingError.noResponse.canRetry)
        #expect(RoutingError.maxRetransmit.canRetry)
    }

    @Test("RoutingError canRetry is false for permanent errors")
    func permanentErrors() {
        #expect(!RoutingError.none.canRetry)
        #expect(!RoutingError.noChannel.canRetry)
        #expect(!RoutingError.tooLarge.canRetry)
        #expect(!RoutingError.notAuthorized.canRetry)
        #expect(!RoutingError.pkiFailed.canRetry)
    }

    @Test("RoutingError all cases have non-empty display")
    func allDisplayStrings() {
        for error in RoutingError.allCases {
            #expect(!error.display.isEmpty, "Display should not be empty for \(error)")
        }
    }

    @Test("MessageDeliveryState equality")
    func deliveryStateEquality() {
        #expect(MessageDeliveryState.none == MessageDeliveryState.none)
        #expect(MessageDeliveryState.pending == MessageDeliveryState.pending)
        #expect(MessageDeliveryState.acknowledged == MessageDeliveryState.acknowledged)
        #expect(MessageDeliveryState.failed("x") == MessageDeliveryState.failed("x"))
        #expect(MessageDeliveryState.failed("x") != MessageDeliveryState.failed("y"))
        #expect(MessageDeliveryState.pending != MessageDeliveryState.acknowledged)
    }
}
