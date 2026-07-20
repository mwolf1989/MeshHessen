import SwiftUI

/// Combined channel feed with a send-channel picker. Selecting a concrete
/// destination also updates the regular channel selection, matching Windows.
struct AllChannelsChatView: View {
    @Environment(\.appState) private var appState
    @Environment(AppCoordinator.self) private var coordinator
    @State private var kioskState = KioskState.shared
    @State private var sendChannelIndex = 0
    @State private var messageText = ""
    @State private var isSending = false
    @State private var showSOSConfirmation = false
    @State private var replyingTo: MessageItem?
    @FocusState private var inputFocused: Bool

    private var messages: [MessageItem] {
        appState.allMessages.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(messages) { message in
                            VStack(alignment: .leading, spacing: 3) {
                                Label(
                                    message.channelName.isEmpty
                                        ? String(localized: "Channel \(message.channelIndex)")
                                        : message.channelName,
                                    systemImage: "number"
                                )
                                .font(.caption2.bold())
                                .foregroundStyle(.tint)

                                MessageBubbleView(
                                    message: message,
                                    isMine: message.fromId == appState.myNodeInfo?.nodeId,
                                    protocolReady: appState.protocolReady,
                                    showColorDot: true,
                                    showMqttIndicator: true,
                                    replyTarget: replyTarget(for: message),
                                    onReply: message.routablePacketId == nil ? nil : {
                                        sendChannelIndex = message.channelIndex
                                        replyingTo = message
                                        inputFocused = true
                                    },
                                    onReaction: reactionHandler(for: message),
                                    onRetry: retryHandler(for: message)
                                )
                            }
                            .id(message.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            VStack(spacing: 6) {
                if let replyingTo {
                    ReplyComposerBanner(message: replyingTo) {
                        self.replyingTo = nil
                    }
                }

                HStack(spacing: 8) {
                    Picker("Send on", selection: $sendChannelIndex) {
                        ForEach(appState.channels) { channel in
                            Text(channel.displayName).tag(channel.id)
                        }
                    }
                    .frame(width: 180)

                    if !kioskState.isFeatureLocked(.sos) {
                        Button("SOS") { showSOSConfirmation = true }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .disabled(!appState.protocolReady || isSending)
                    }

                    TextField("Message…", text: $messageText, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($inputFocused)
                        .onChange(of: messageText) { _, value in
                            let limited = MessageItem.truncatingToPayloadLimit(value)
                            if limited != value { messageText = limited }
                        }

                    Button("Send", systemImage: "paperplane.fill", action: send)
                        .buttonStyle(.borderedProminent)
                        .disabled(trimmedMessage.isEmpty || isSending || !appState.protocolReady)
                }

                Text("\(MessageItem.payloadByteCount(messageText))/\(MessageItem.maximumPayloadBytes) Bytes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(10)
        }
        .onAppear {
            if appState.channels.contains(where: { $0.id == appState.selectedChannelIndex }) {
                sendChannelIndex = appState.selectedChannelIndex
            } else {
                sendChannelIndex = appState.channels.first?.id ?? 0
            }
            for channelIndex in Array(appState.channelUnreadCounts.keys) {
                appState.clearChannelUnread(channelIndex)
            }
        }
        .onChange(of: sendChannelIndex) { _, newValue in
            appState.selectedChannelIndex = newValue
        }
        .confirmationDialog("SOS-Alarm senden?", isPresented: $showSOSConfirmation) {
            Button("SOS senden", role: .destructive) { sendSOS() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Der Notruf wird auf dem ausgewählten Sendekanal übertragen.")
        }
    }

    private var trimmedMessage: String {
        messageText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send() {
        guard !trimmedMessage.isEmpty else { return }
        let text = trimmedMessage
        let replyPacketID = replyingTo?.packetId
        messageText = ""
        replyingTo = nil
        isSending = true
        Task {
            await coordinator.sendMessage(
                text,
                toChannelIndex: sendChannelIndex,
                replyToPacketId: replyPacketID
            )
            isSending = false
        }
    }

    private func sendSOS() {
        let extra = trimmedMessage
        let text = MessageItem.truncatingToPayloadLimit(
            extra.isEmpty ? "🔔 Alert Bell Character!" : "🔔 \(extra)"
        )
        messageText = ""
        replyingTo = nil
        isSending = true
        Task {
            await coordinator.sendMessage(text, toChannelIndex: sendChannelIndex)
            isSending = false
        }
    }

    private func replyTarget(for message: MessageItem) -> MessageItem? {
        guard let packetID = message.replyToPacketId else { return nil }
        return messages.first {
            $0.channelIndex == message.channelIndex && $0.packetId == packetID
        }
    }

    private func reactionHandler(for message: MessageItem) -> ((String) -> Void)? {
        guard let packetID = message.routablePacketId else { return nil }
        return { emoji in
            Task {
                await coordinator.sendEmojiReaction(
                    emoji,
                    toPacketId: packetID,
                    toNodeId: UInt32.max,
                    channelIndex: message.channelIndex
                )
            }
        }
    }

    private func retryHandler(for message: MessageItem) -> (() -> Void)? {
        guard case .failed = message.deliveryState,
              message.fromId == appState.myNodeInfo?.nodeId
        else { return nil }
        return {
            Task {
                await coordinator.sendMessage(
                    message.message,
                    toChannelIndex: message.channelIndex,
                    replyToPacketId: message.replyToPacketId
                )
            }
        }
    }
}
