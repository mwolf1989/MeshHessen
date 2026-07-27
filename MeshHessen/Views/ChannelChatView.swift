import SwiftUI

/// Per-channel chat message list with send bar and SOS button.
struct ChannelChatView: View {
    @Environment(\.appState) private var appState
    @Environment(AppCoordinator.self) private var coordinator
    @State private var kioskState = KioskState.shared

    let channelIndex: Int
    @State private var messageText = ""
    @State private var isSending = false
    @State private var isLoadingOlder = false
    @State private var hasMoreHistory = true
    @State private var suppressNextAutoScroll = false
    @State private var showDeleteConfirmation = false
    @State private var deletionScope: MessageHistoryDeletionScope = .all
    @State private var showSOSConfirmation = false
    @State private var replyingTo: MessageItem?
    @FocusState private var inputFocused: Bool

    private var messages: [MessageItem] {
        (appState.channelMessages[channelIndex] ?? []).filter {
            $0.hasKnownChannel && $0.channelIndex == channelIndex
        }
    }

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
                .disabled(messages.isEmpty)
                .help("Nachrichtenverlauf dieses Kanals bereinigen")
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

                        ForEach(messages) { msg in
                            MessageBubbleView(
                                message: msg,
                                isMine: msg.fromId == appState.myNodeInfo?.nodeId,
                                protocolReady: appState.protocolReady,
                                showColorDot: true,
                                showMqttIndicator: true,
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
                .onChange(of: messages.count) { _, _ in
                    if suppressNextAutoScroll {
                        suppressNextAutoScroll = false
                    } else if let last = messages.last {
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
                        .help("Send SOS broadcast on this channel")
                        .disabled(!appState.protocolReady || isSending)
                    }

                    TextField("Message…", text: $messageText, axis: .vertical)
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
        .onAppear {
            appState.clearChannelUnread(channelIndex)
            appState.selectedChannelIndex = channelIndex
        }
        .onChange(of: channelIndex) { _, new in
            replyingTo = nil
            hasMoreHistory = true
            appState.clearChannelUnread(new)
        }
        .alert("Nachrichten löschen?", isPresented: $showDeleteConfirmation) {
            Button("Löschen", role: .destructive) {
                replyingTo = nil
                coordinator.clearChannelMessages(channelIndex, scope: deletionScope)
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(deletionConfirmationText)
        }
        .confirmationDialog("SOS-Alarm senden?", isPresented: $showSOSConfirmation) {
            Button("SOS senden", role: .destructive) {
                AppLogger.shared.log("[UI] User triggered SOS alert on channel \(channelIndex)", debug: true)
                sendSOSAlert()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Der Notruf wird auf Kanal \(channelIndex) gesendet. Text im Eingabefeld wird als Zusatztext übernommen.")
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
            return String(localized: "Alle Nachrichten in diesem Kanal werden unwiderruflich gelöscht.")
        case .olderThanThirtyDays:
            return String(localized: "Alle Nachrichten dieses Kanals, die älter als 30 Tage sind, werden gelöscht.")
        case .olderThanNinetyDays:
            return String(localized: "Alle Nachrichten dieses Kanals, die älter als 90 Tage sind, werden gelöscht.")
        case .olderThanOneYear:
            return String(localized: "Alle Nachrichten dieses Kanals, die älter als ein Jahr sind, werden gelöscht.")
        }
    }

    private func loadOlderHistory(using proxy: ScrollViewProxy) {
        guard !isLoadingOlder else { return }
        let previousFirstID = messages.first?.id
        isLoadingOlder = true
        suppressNextAutoScroll = true
        let page = coordinator.loadOlderChannelMessages(channelIndex)
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
        AppLogger.shared.log("[UI] Sending message to channel \(channelIndex): \(text.prefix(50))\(text.count > 50 ? "..." : "")", debug: SettingsService.shared.debugMessages)
        Task {
            await coordinator.sendMessage(
                text,
                toChannelIndex: channelIndex,
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
        Task {
            await coordinator.sendMessage(alertText, toChannelIndex: channelIndex)
            isSending = false
        }
    }

    private func beginReply(to message: MessageItem) {
        guard message.hasKnownChannel, message.routablePacketId != nil else { return }
        replyingTo = message
        inputFocused = true
    }

    private func replyTarget(for message: MessageItem) -> MessageItem? {
        guard message.hasKnownChannel,
              let targetPacketId = message.replyToPacketId
        else {
            return nil
        }
        return messages.first { $0.packetId == targetPacketId }
    }

    private func reactionHandler(for message: MessageItem) -> ((String) -> Void)? {
        guard message.hasKnownChannel,
              let packetId = message.routablePacketId
        else {
            return nil
        }
        return { emoji in
            Task {
                await coordinator.sendEmojiReaction(
                    emoji,
                    toPacketId: packetId,
                    toNodeId: 0xFFFFFFFF,
                    channelIndex: channelIndex
                )
            }
        }
    }

    private func retryHandler(for message: MessageItem) -> (() -> Void)? {
        guard message.hasKnownChannel,
              case .failed = message.deliveryState,
              message.fromId == appState.myNodeInfo?.nodeId else { return nil }
        return {
            Task {
                await coordinator.sendMessage(
                    message.message,
                    toChannelIndex: channelIndex,
                    replyToPacketId: message.replyToPacketId
                )
            }
        }
    }
}
