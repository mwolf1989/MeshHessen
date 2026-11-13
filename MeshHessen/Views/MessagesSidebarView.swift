import SwiftUI

/// "Messages" tab — sidebar listing channels (and, in inline DM style, direct
/// message conversations) with unread badges; the selected entry's chat on the right.
struct MessagesSidebarView: View {
    @Environment(\.appState) private var appState
    @Environment(AppCoordinator.self) private var coordinator
    @State private var settings = SettingsService.shared
    @SceneStorage("messagesSidebarSelection") private var storedSelection = MessagesSidebarSelection.allChannels.storageValue
    @State private var selection: MessagesSidebarSelection?

    private var showsDirectMessages: Bool { settings.dmStyleIsInline }

    private var conversations: [DirectMessageConversation] {
        MessagesSidebarModel.sortedConversations(
            Array(appState.dmConversations.values),
            name: { $0.displayName(in: appState) }
        )
    }

    var body: some View {
        if appState.channels.isEmpty && (!showsDirectMessages || appState.dmConversations.isEmpty) {
            emptyState
        } else {
            HSplitView {
                sidebar
                    .frame(minWidth: 170, idealWidth: 210, maxWidth: 320)
                detail
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
            .onAppear {
                if selection == nil {
                    selection = validated(MessagesSidebarSelection(storageValue: storedSelection))
                }
                consumeRequest()
                apply(selection)
            }
            .onDisappear { appState.activeInlineDMNodeId = nil }
            .onChange(of: appState.messagesSidebarRequest) { _, _ in consumeRequest() }
            .onChange(of: selection) { _, newValue in apply(newValue) }
            .onChange(of: appState.channels) { _, _ in revalidateSelection() }
            .onChange(of: settings.dmStyle) { _, _ in revalidateSelection() }
            .onChange(of: selectedConversation?.messages.count) { _, _ in
                // The store marks incoming DMs unread; keep the open conversation read.
                markSelectedConversationRead()
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Channels") {
                Label("All Channels", systemImage: "text.bubble.fill")
                    .tag(MessagesSidebarSelection.allChannels)

                ForEach(appState.channels) { channel in
                    Label(channel.displayName, systemImage: channel.id == 0 ? "star.fill" : "bubble.left")
                        .badge(MessagesSidebarModel.badgeLabel(count: appState.channelUnreadCounts[channel.id]))
                        .tag(MessagesSidebarSelection.channel(channel.id))
                }
            }

            if showsDirectMessages {
                Section("Direct Messages") {
                    if conversations.isEmpty {
                        Text("No conversations yet")
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                    ForEach(conversations) { conversation in
                        DirectMessageRow(
                            name: conversation.displayName(in: appState),
                            hasUnread: conversation.hasUnread
                        )
                        .badge(MessagesSidebarModel.dmBadgeLabel(
                            count: appState.dmUnreadBadgeCount(for: conversation.id)
                        ))
                        .tag(MessagesSidebarSelection.directMessage(conversation.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .allChannels {
        case .allChannels:
            AllChannelsChatView()
        case .channel(let index):
            ChannelChatView(channelIndex: index)
                .id(index)
        case .directMessage(let nodeId):
            if let conversation = appState.dmConversations[nodeId] {
                DMConversationView(conversation: conversation, coordinator: coordinator)
                    .id(conversation.id)
            } else {
                ContentUnavailableView(
                    "No Conversation Selected",
                    systemImage: "message",
                    description: Text("Select a conversation from the sidebar.")
                )
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if appState.connectionState.isConnected && !appState.protocolReady {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.large)
                Text(appState.protocolStatusMessage ?? String(localized: "Loading mesh data…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No Channels",
                systemImage: "antenna.radiowaves.left.and.right",
                description: Text("Connect to a node to load channels.")
            )
        }
    }

    // MARK: - Selection

    private var selectedConversation: DirectMessageConversation? {
        guard case .directMessage(let nodeId) = selection else { return nil }
        return appState.dmConversations[nodeId]
    }

    private func consumeRequest() {
        guard let request = appState.messagesSidebarRequest else { return }
        appState.messagesSidebarRequest = nil
        if case .directMessage(let nodeId) = request {
            appState.ensureDMConversation(for: nodeId)
        }
        selection = validated(request)
    }

    private func revalidateSelection() {
        let valid = validated(selection)
        if valid != selection { selection = valid }
    }

    /// Falls back to "All channels" for entries that no longer exist or are hidden.
    private func validated(_ candidate: MessagesSidebarSelection?) -> MessagesSidebarSelection {
        switch candidate {
        case .channel(let index) where appState.channels.contains(where: { $0.id == index }):
            return .channel(index)
        case .directMessage(let nodeId) where showsDirectMessages && appState.dmConversations[nodeId] != nil:
            return .directMessage(nodeId)
        default:
            return .allChannels
        }
    }

    private func apply(_ newSelection: MessagesSidebarSelection?) {
        let current = newSelection ?? .allChannels
        storedSelection = current.storageValue
        switch current {
        case .allChannels:
            appState.activeInlineDMNodeId = nil
        case .channel(let index):
            appState.activeInlineDMNodeId = nil
            appState.selectedChannelIndex = index
            appState.clearChannelUnread(index)
        case .directMessage(let nodeId):
            appState.activeInlineDMNodeId = nodeId
            markSelectedConversationRead()
        }
    }

    private func markSelectedConversationRead() {
        guard appState.selectedTab == .messages, let conversation = selectedConversation else { return }
        if conversation.hasUnread { conversation.hasUnread = false }
        appState.dmUnreadCounts[conversation.id] = nil
        coordinator.coreDataStore.setConversationUnread(partnerNodeId: conversation.id, hasUnread: false)
    }
}

// MARK: - Rows

private struct DirectMessageRow: View {
    let name: String
    let hasUnread: Bool

    var body: some View {
        Label {
            Text(name)
                .fontWeight(hasUnread ? .bold : .regular)
                .lineLimit(1)
        } icon: {
            Image(systemName: "person.crop.circle")
        }
    }
}

// MARK: - Model

/// Pure helpers behind the sidebar (kept separate for tests).
enum MessagesSidebarModel {
    static func badgeLabel(count: Int?) -> Text? {
        badgeText(count: count).map { Text(verbatim: $0) }
    }

    static func dmBadgeLabel(count: Int?) -> Text? {
        dmBadgeText(count: count).map { Text(verbatim: $0) }
    }

    /// Badge text for an unread count: nil when nothing is unread, "99+" above 99.
    static func badgeText(count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        return count > 99 ? "99+" : "\(count)"
    }

    /// Like `badgeText`, but an unread conversation whose count is unknown
    /// (`0`, e.g. unread state restored from storage) shows "•".
    static func dmBadgeText(count: Int?) -> String? {
        guard let count else { return nil }
        return count == 0 ? "•" : badgeText(count: count)
    }

    /// Most recent conversation first; ties (and empty conversations) by name.
    static func sortedConversations(
        _ conversations: [DirectMessageConversation],
        name: (DirectMessageConversation) -> String
    ) -> [DirectMessageConversation] {
        conversations
            .map { (conversation: $0, last: $0.messages.last?.createdAt ?? .distantPast, name: name($0)) }
            .sorted {
                if $0.last != $1.last { return $0.last > $1.last }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            .map(\.conversation)
    }
}
