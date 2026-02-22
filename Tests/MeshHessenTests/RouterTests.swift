import Testing
import Foundation
@testable import MeshHessen

// MARK: - Router URL Parsing Tests

@MainActor
@Suite("Router URL Routing")
struct RouterTests {

    // MARK: - Helpers

    private func makeRouter() -> Router {
        Router()
    }

    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    // MARK: - Basic Tab Navigation

    @Test("Route to messages tab")
    func routeMessages() {
        let router = makeRouter()
        let handled = router.route(url: url("meshhessen:///messages"))
        #expect(handled)
        #expect(router.navigationState.selectedTab == .messages)
    }

    @Test("Route to nodes tab")
    func routeNodes() {
        let router = makeRouter()
        let handled = router.route(url: url("meshhessen:///nodes"))
        #expect(handled)
        #expect(router.navigationState.selectedTab == .nodes)
    }

    @Test("Route to map tab")
    func routeMap() {
        let router = makeRouter()
        let handled = router.route(url: url("meshhessen:///map"))
        #expect(handled)
        #expect(router.navigationState.selectedTab == .map)
    }

    @Test("Route to channels tab")
    func routeChannels() {
        let router = makeRouter()
        let handled = router.route(url: url("meshhessen:///channels"))
        #expect(handled)
        #expect(router.navigationState.selectedTab == .channels)
    }

    @Test("Route to debug tab")
    func routeDebug() {
        let router = makeRouter()
        let handled = router.route(url: url("meshhessen:///debug"))
        #expect(handled)
        #expect(router.navigationState.selectedTab == .debug)
    }

    @Test("Route to info tab")
    func routeInfo() {
        let router = makeRouter()
        let handled = router.route(url: url("meshhessen:///info"))
        #expect(handled)
        #expect(router.navigationState.selectedTab == .info)
    }

    // MARK: - URL Parameters

    @Test("Route to messages with channelId parameter")
    func routeMessagesWithChannelId() {
        let router = makeRouter()
        let handled = router.route(url: url("meshhessen:///messages?channelId=3"))
        #expect(handled)
        #expect(router.navigationState.selectedTab == .messages)
        if case .channels(channelId: let id) = router.navigationState.messages {
            #expect(id == 3)
        } else {
            Issue.record("Expected .channels navigation state")
        }
    }

    @Test("Route to messages with userNum for DM")
    func routeMessagesWithUserNum() {
        let router = makeRouter()
        let handled = router.route(url: url("meshhessen:///messages?userNum=12345"))
        #expect(handled)
        #expect(router.navigationState.selectedTab == .messages)
        if case .directMessages(userNum: let num) = router.navigationState.messages {
            #expect(num == 12345)
        } else {
            Issue.record("Expected .directMessages navigation state")
        }
    }

    @Test("Route to nodes with nodenum parameter")
    func routeNodesWithNodenum() {
        let router = makeRouter()
        let handled = router.route(url: url("meshhessen:///nodes?nodenum=99887766"))
        #expect(handled)
        #expect(router.navigationState.selectedTab == .nodes)
        #expect(router.navigationState.nodeListSelectedNodeNum == 99887766)
    }

    @Test("Route to map with nodenum parameter")
    func routeMapWithNodenum() {
        let router = makeRouter()
        let handled = router.route(url: url("meshhessen:///map?nodenum=55443322"))
        #expect(handled)
        #expect(router.navigationState.selectedTab == .map)
        if case .selectedNode(let num) = router.navigationState.map {
            #expect(num == 55443322)
        } else {
            Issue.record("Expected .selectedNode map state")
        }
    }

    // MARK: - Settings Sub-Paths

    @Test("Route to settings/lora")
    func routeSettingsLora() {
        let router = makeRouter()
        let handled = router.route(url: url("meshhessen:///settings/lora"))
        #expect(handled)
        #expect(router.navigationState.selectedTab == .settings)
        #expect(router.navigationState.settings == .lora)
    }

    @Test("Route to settings/bluetooth")
    func routeSettingsBluetooth() {
        let router = makeRouter()
        let handled = router.route(url: url("meshhessen:///settings/bluetooth"))
        #expect(handled)
        #expect(router.navigationState.selectedTab == .settings)
        #expect(router.navigationState.settings == .bluetooth)
    }

    @Test("Route to settings base path")
    func routeSettingsBase() {
        let router = makeRouter()
        let handled = router.route(url: url("meshhessen:///settings"))
        #expect(handled)
        #expect(router.navigationState.selectedTab == .settings)
    }

    // MARK: - Invalid URLs

    @Test("Unknown path returns false")
    func unknownPath() {
        let router = makeRouter()
        let handled = router.route(url: url("meshhessen:///nonexistent"))
        #expect(!handled)
    }

    @Test("Empty path returns false")
    func emptyPath() {
        let router = makeRouter()
        let handled = router.route(url: url("meshhessen:///"))
        #expect(!handled)
    }

    // MARK: - Programmatic Navigation

    @Test("navigateToChannel sets correct state")
    func navigateToChannel() {
        let router = makeRouter()
        router.navigateToChannel(2)
        #expect(router.navigationState.selectedTab == .messages)
        if case .channels(channelId: let id) = router.navigationState.messages {
            #expect(id == 2)
        } else {
            Issue.record("Expected .channels state")
        }
    }

    @Test("navigateToDirectMessage sets correct state")
    func navigateToDirectMessage() {
        let router = makeRouter()
        router.navigateToDirectMessage(nodeNum: 42)
        #expect(router.navigationState.selectedTab == .messages)
        if case .directMessages(userNum: let num) = router.navigationState.messages {
            #expect(num == 42)
        } else {
            Issue.record("Expected .directMessages state")
        }
    }

    @Test("navigateToNodeDetail sets correct state")
    func navigateToNodeDetail() {
        let router = makeRouter()
        router.navigateToNodeDetail(nodeNum: 777)
        #expect(router.navigationState.selectedTab == .nodes)
        #expect(router.navigationState.nodeListSelectedNodeNum == 777)
    }

    @Test("navigateToNodeOnMap sets correct state")
    func navigateToNodeOnMap() {
        let router = makeRouter()
        router.navigateToNodeOnMap(nodeNum: 888)
        #expect(router.navigationState.selectedTab == .map)
        if case .selectedNode(let num) = router.navigationState.map {
            #expect(num == 888)
        } else {
            Issue.record("Expected .selectedNode map state")
        }
    }

    @Test("navigateToSettings sets settings page")
    func navigateToSettings() {
        let router = makeRouter()
        router.navigateToSettings(.mqtt)
        #expect(router.navigationState.selectedTab == .settings)
        #expect(router.navigationState.settings == .mqtt)
    }
}
