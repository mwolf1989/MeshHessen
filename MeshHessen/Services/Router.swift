import Foundation
import SwiftUI

/// Manages app-wide navigation state and deep-link URL routing.
///
/// URL Schema: `meshhessen:///messages?channelId=X`
///             `meshhessen:///nodes?nodenum=X`
///             `meshhessen:///map?nodenum=X`
///             `meshhessen:///settings/lora`
@Observable
@MainActor
final class Router {

    // MARK: - State

    var navigationState = NavigationState()

    /// Weak reference to AppState for applying tab changes.
    weak var appState: AppState?

    // MARK: - Tab shortcuts

    var selectedTab: NavigationState.Tab {
        get { navigationState.selectedTab }
        set { navigationState.selectedTab = newValue }
    }

    /// Maps NavigationState.Tab → MainTab for AppState.selectedTab synchronization.
    private func syncTabToAppState() {
        guard let appState else { return }
        switch navigationState.selectedTab {
        case .messages:  appState.selectedTab = .messages
        case .nodes:     appState.selectedTab = .nodes
        case .channels:  appState.selectedTab = .channels
        case .map:       appState.selectedTab = .map
        case .settings:  break // Settings is a separate window, no tab in MainView
        case .debug:     appState.selectedTab = .debug
        case .info:      appState.selectedTab = .info
        }
    }

    // MARK: - URL Routing

    /// Routes a `meshhessen://` URL into the appropriate navigation state.
    /// Returns `true` if the URL was handled.
    @discardableResult
    func route(url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }

        let pathComponent = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Accept both meshhessen:///messages and the more common
        // meshhessen://messages spelling, where URLComponents exposes the route as host.
        let path = [components.host, pathComponent]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "/")
        let params = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        switch path {
        case "messages":
            navigationState.selectedTab = .messages
            if let channelIdStr = params["channelId"], let channelId = Int(channelIdStr) {
                navigationState.messages = .channels(channelId: channelId)
            } else if let userNumStr = params["userNum"], let userNum = Self.parseNodeNumber(userNumStr) {
                navigationState.messages = .directMessages(userNum: userNum)
            }
            syncTabToAppState()
            return true

        case "nodes":
            navigationState.selectedTab = .nodes
            if let nodenumStr = params["nodenum"], let nodenum = Self.parseNodeNumber(nodenumStr) {
                navigationState.nodeListSelectedNodeNum = nodenum
            }
            syncTabToAppState()
            return true

        case "map":
            navigationState.selectedTab = .map
            if let nodenumStr = params["nodenum"], let nodenum = Self.parseNodeNumber(nodenumStr) {
                navigationState.map = .selectedNode(nodenum)
            }
            syncTabToAppState()
            return true

        case "channels":
            navigationState.selectedTab = .channels
            syncTabToAppState()
            return true

        case "debug":
            navigationState.selectedTab = .debug
            syncTabToAppState()
            return true

        case "info":
            navigationState.selectedTab = .info
            syncTabToAppState()
            return true

        default:
            // Try settings sub-paths: "settings/lora"
            if path.hasPrefix("settings") {
                navigationState.selectedTab = .settings
                let subPath = path.replacingOccurrences(of: "settings/", with: "")
                    .replacingOccurrences(of: "settings", with: "")
                if !subPath.isEmpty, let settingsNav = SettingsNavigationState(rawValue: subPath) {
                    navigationState.settings = settingsNav
                }
                return true
            }
            return false
        }
    }

    nonisolated static func parseNodeNumber(_ value: String) -> UInt32? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("!") {
            return UInt32(trimmed.dropFirst(), radix: 16)
        }
        if trimmed.lowercased().hasPrefix("0x") {
            return UInt32(trimmed.dropFirst(2), radix: 16)
        }
        return UInt32(trimmed) ?? UInt32(trimmed, radix: 16)
    }

    // MARK: - Programmatic Navigation

    func navigateToChannel(_ channelId: Int) {
        navigationState.selectedTab = .messages
        navigationState.messages = .channels(channelId: channelId)
        syncTabToAppState()
    }

    func navigateToDirectMessage(nodeNum: UInt32) {
        navigationState.selectedTab = .messages
        navigationState.messages = .directMessages(userNum: nodeNum)
        syncTabToAppState()
    }

    func navigateToNodeDetail(nodeNum: UInt32) {
        navigationState.selectedTab = .nodes
        navigationState.nodeListSelectedNodeNum = nodeNum
        syncTabToAppState()
    }

    func navigateToNodeOnMap(nodeNum: UInt32) {
        navigationState.selectedTab = .map
        navigationState.map = .selectedNode(nodeNum)
        syncTabToAppState()
    }

    func navigateToSettings(_ page: SettingsNavigationState) {
        navigationState.selectedTab = .settings
        navigationState.settings = page
        // Settings is a separate window — no MainTab sync needed
    }
}
