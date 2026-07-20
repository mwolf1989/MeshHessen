import SwiftUI

/// Floating DM window — one tab per active DM conversation.
struct DMWindowView: View {
    @Environment(\.appState) private var appState
    @Environment(AppCoordinator.self) private var coordinator
    @State private var selectedNodeId: UInt32?
    @State private var messageText = ""
    @FocusState private var inputFocused: Bool

    private var conversations: [DirectMessageConversation] {
        Array(appState.dmConversations.values).sorted { $0.nodeName < $1.nodeName }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedNodeId) {
                ForEach(conversations) { conv in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(conv.nodeName)
                                    .fontWeight(conv.hasUnread ? .bold : .medium)
                                    .foregroundStyle(conv.hasUnread ? Color.orange : Color.primary)
                                if conv.hasUnread {
                                    Circle()
                                        .fill(Color.orange)
                                        .frame(width: 8, height: 8)
                                }
                            }
                            if let last = conv.messages.last {
                                Text(last.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .tag(conv.id)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Direct Messages")
        } detail: {
            if let nodeId = selectedNodeId,
               let conv = appState.dmConversations[nodeId] {
                DMConversationView(conversation: conv, coordinator: coordinator)
                    .id(conv.id)
            } else {                ContentUnavailableView(
                    "No Conversation Selected",
                    systemImage: "message",
                    description: Text("Select a conversation from the sidebar.")
                )
            }
        }
        .onAppear(perform: consumeTargetNode)
        .onChange(of: appState.dmTargetNodeId) { _, _ in consumeTargetNode() }
        .onChange(of: selectedNodeId) { _, newId in
            markConversationRead(newId)
        }
    }

    /// If a target node was set (e.g. from a context menu), select it and clear the flag.
    private func consumeTargetNode() {
        guard let targetId = appState.dmTargetNodeId else { return }
        appState.dmTargetNodeId = nil
        selectedNodeId = targetId
        markConversationRead(targetId)
    }

    /// Clears the unread flag on the selected conversation.
    private func markConversationRead(_ nodeId: UInt32?) {
        guard let nodeId, let conv = appState.dmConversations[nodeId] else { return }
        conv.hasUnread = false
        // Persist unread state to CoreData
        coordinator.coreDataStore.setConversationUnread(partnerNodeId: nodeId, hasUnread: false)
    }
}

private struct DMConversationView: View {
    let conversation: DirectMessageConversation
    let coordinator: AppCoordinator
    @Environment(\.appState) private var appState
    @State private var messageText = ""
    @State private var isSending = false
    @State private var isLoadingOlder = false
    @State private var hasMoreHistory = true
    @State private var suppressNextAutoScroll = false
    @State private var showDeleteConfirmation = false
    @State private var deletionScope: MessageHistoryDeletionScope = .all
    @State private var showSOSConfirmation = false
    @State private var kioskState = KioskState.shared
    @State private var replyingTo: MessageItem?
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Menu {
                    deletionButton("Alle Nachrichten", scope: .all)
                    Divider()
                    deletionButton("Älter als 30 Tage", scope: .olderThanThirtyDays)
                    deletionButton("Älter als 90 Tage", scope: .olderThanNinetyDays)
                    deletionButton("Älter als ein Jahr", scope: .olderThanOneYear)
                } label: {
                    Label("Nachrichten löschen", systemImage: "trash")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(.secondary)
                .disabled(conversation.messages.isEmpty)
                .help("Nachrichtenverlauf dieser Konversation bereinigen")
                .padding(.trailing, 12)
                .padding(.top, 4)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if hasMoreHistory {
                            Button {
                                loadOlderHistory(using: proxy)
                            } label: {
                                if isLoadingOlder {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Label("Ältere Nachrichten laden", systemImage: "clock.arrow.circlepath")
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(isLoadingOlder)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 4)
                        }

                        ForEach(conversation.messages) { msg in
                            MessageBubbleView(
                                message: msg,
                                isMine: msg.fromId == appState.myNodeInfo?.nodeId,
                                replyTarget: replyTarget(for: msg),
                                onReply: msg.routablePacketId == nil ? nil : {
                                    beginReply(to: msg)
                                },
                                onReaction: reactionHandler(for: msg),
                                onRetry: retryHandler(for: msg)
                            )
                            .id(msg.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: conversation.messages.count) { _, _ in
                    if suppressNextAutoScroll {
                        suppressNextAutoScroll = false
                    } else if let last = conversation.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            VStack(spacing: 6) {
                if let replyingTo {
                    ReplyComposerBanner(message: replyingTo) {
                        self.replyingTo = nil
                        inputFocused = true
                    }
                }

                HStack(spacing: 8) {
                    if !kioskState.isFeatureLocked(.sos) {
                        Button {
                            showSOSConfirmation = true
                        } label: {
                            Text("SOS")
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.red)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .help("Send SOS directly to \(conversation.nodeName)")
                        .disabled(!appState.protocolReady || isSending)
                    }

                    TextField("Message to \(conversation.nodeName)…", text: $messageText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .frame(maxWidth: .infinity)
                        .focused($inputFocused)
                        .onChange(of: messageText) { _, newValue in
                            let limited = MessageItem.truncatingToPayloadLimit(newValue)
                            if limited != newValue {
                                messageText = limited
                            }
                        }

                    Button(action: sendMessage) {
                        Image(systemName: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || MessageItem.payloadByteCount(messageText) > MessageItem.maximumPayloadBytes
                            || isSending
                    )
                    .keyboardShortcut(.return, modifiers: .command)
                }

                Text("\(MessageItem.payloadByteCount(messageText))/\(MessageItem.maximumPayloadBytes) Bytes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(10)
        }
        .navigationTitle("DM: \(conversation.nodeName)")
        .onAppear {
            conversation.hasUnread = false
            coordinator.coreDataStore.setConversationUnread(partnerNodeId: conversation.id, hasUnread: false)
        }
        .alert("Nachrichten löschen?", isPresented: $showDeleteConfirmation) {
            Button("Löschen", role: .destructive) {
                replyingTo = nil
                coordinator.clearDirectMessages(for: conversation.id, scope: deletionScope)
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(deletionConfirmationText)
        }
        .confirmationDialog("SOS-Alarm senden?", isPresented: $showSOSConfirmation) {
            Button("SOS senden", role: .destructive) {
                sendSOSAlert()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Der Notruf wird als Direktnachricht an \(conversation.nodeName) gesendet. Text im Eingabefeld wird als Zusatztext übernommen.")
        }
    }

    @ViewBuilder
    private func deletionButton(_ title: LocalizedStringKey, scope: MessageHistoryDeletionScope) -> some View {
        Button(title, role: .destructive) {
            deletionScope = scope
            showDeleteConfirmation = true
        }
    }

    private var deletionConfirmationText: String {
        switch deletionScope {
        case .all:
            return String(localized: "Alle Nachrichten in dieser Konversation werden unwiderruflich gelöscht.")
        case .olderThanThirtyDays:
            return String(localized: "Alle Direktnachrichten, die älter als 30 Tage sind, werden gelöscht.")
        case .olderThanNinetyDays:
            return String(localized: "Alle Direktnachrichten, die älter als 90 Tage sind, werden gelöscht.")
        case .olderThanOneYear:
            return String(localized: "Alle Direktnachrichten, die älter als ein Jahr sind, werden gelöscht.")
        }
    }

    private func loadOlderHistory(using proxy: ScrollViewProxy) {
        guard !isLoadingOlder else { return }
        let previousFirstID = conversation.messages.first?.id
        isLoadingOlder = true
        suppressNextAutoScroll = true
        let page = coordinator.loadOlderDirectMessages(for: conversation.id)
        hasMoreHistory = page.hasMore
        isLoadingOlder = false
        if page.messages.isEmpty {
            suppressNextAutoScroll = false
        }
        guard let previousFirstID, !page.messages.isEmpty else { return }
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(previousFirstID, anchor: .top)
        }
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              MessageItem.payloadByteCount(text) <= MessageItem.maximumPayloadBytes else { return }
        let replyToPacketId = replyingTo?.packetId
        messageText = ""
        replyingTo = nil
        isSending = true
        Task {
            await coordinator.sendDirectMessage(
                text,
                toNodeId: conversation.id,
                replyToPacketId: replyToPacketId
            )
            isSending = false
        }
    }

    private func sendSOSAlert() {
        let additionalText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let alertText = MessageItem.truncatingToPayloadLimit(
            additionalText.isEmpty ? "🔔 Alert Bell Character!" : "🔔 \(additionalText)"
        )
        messageText = ""
        replyingTo = nil
        isSending = true
        AppLogger.shared.log(
            "[UI] User triggered direct SOS alert to \(String(format: "!%08x", conversation.id))",
            debug: true
        )
        Task {
            await coordinator.sendDirectMessage(alertText, toNodeId: conversation.id)
            isSending = false
        }
    }

    private func beginReply(to message: MessageItem) {
        guard message.routablePacketId != nil else { return }
        replyingTo = message
        inputFocused = true
    }

    private func replyTarget(for message: MessageItem) -> MessageItem? {
        guard let targetPacketId = message.replyToPacketId else { return nil }
        return conversation.messages.first { $0.packetId == targetPacketId }
    }

    private func reactionHandler(for message: MessageItem) -> ((String) -> Void)? {
        guard let packetId = message.routablePacketId else { return nil }
        return { emoji in
            Task {
                await coordinator.sendEmojiReaction(
                    emoji,
                    toPacketId: packetId,
                    toNodeId: conversation.id,
                    channelIndex: 0
                )
            }
        }
    }

    private func retryHandler(for message: MessageItem) -> (() -> Void)? {
        guard case .failed = message.deliveryState,
              message.fromId == appState.myNodeInfo?.nodeId else { return nil }
        return {
            Task {
                await coordinator.sendDirectMessage(
                    message.message,
                    toNodeId: conversation.id,
                    replyToPacketId: message.replyToPacketId
                )
            }
        }
    }
}
