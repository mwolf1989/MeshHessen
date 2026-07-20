import SwiftUI

/// Shared delivery state label used in both channel and DM message bubbles.
struct DeliveryStateLabel: View {
    let state: MessageDeliveryState

    var body: some View {
        switch state {
        case .none:
            EmptyView()
        case .pending:
            Text("Warte auf ACK…")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .acknowledged:
            Text("Zugestellt")
                .font(.caption2)
                .foregroundStyle(.green)
        case .failed(let reason):
            Text(reason)
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }
}

/// Emoji picker popover — 4×8 grid of 32 emojis
struct EmojiPickerView: View {
    let onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<EmojiReaction.rows, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<EmojiReaction.columns, id: \.self) { col in
                        let idx = row * EmojiReaction.columns + col
                        if idx < EmojiReaction.allEmojis.count {
                            let emoji = EmojiReaction.allEmojis[idx]
                            Button(emoji) { onSelect(emoji) }
                                .buttonStyle(.plain)
                                .font(.title3)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                    }
                }
            }
        }
        .padding(8)
    }
}

/// Shows reaction pills below a message bubble
struct ReactionPillsView: View {
    let reactions: [String: [UInt32]]

    var body: some View {
        if !reactions.isEmpty {
            HStack(spacing: 4) {
                ForEach(reactions.sorted(by: { $0.key < $1.key }), id: \.key) { emoji, senders in
                    HStack(spacing: 2) {
                        Text(emoji).font(.caption)
                        if senders.count > 1 {
                            Text("\(senders.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
                }
            }
        }
    }
}

/// Compact context shown while composing a reply.
struct ReplyComposerBanner: View {
    let message: MessageItem
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text("Antwort an \(message.from)")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(message.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Antwort abbrechen")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

/// A quoted message preview displayed inside a reply bubble.
private struct ReplyContextView: View {
    let target: MessageItem?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.7))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text(target?.from ?? String(localized: "Ursprüngliche Nachricht"))
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text(target?.message ?? String(localized: "Nicht mehr verfügbar"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }
}

/// Unified message bubble used in both channel chat and DM conversations.
struct MessageBubbleView: View {
    let message: MessageItem
    let isMine: Bool
    var protocolReady: Bool = true
    var showColorDot: Bool = false
    var showMqttIndicator: Bool = false
    var replyTarget: MessageItem?
    var onReply: (() -> Void)?
    var onReaction: ((String) -> Void)?

    @State private var pendingURL: URL?
    @State private var showLinkConfirmation = false
    @State private var showEmojiPicker = false

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
            // Header: sender name, optional color dot, optional MQTT indicator, timestamp
            HStack(spacing: 6) {
                if !isMine {
                    if showColorDot,
                       !message.senderColorHex.isEmpty,
                       let color = Color(hex: message.senderColorHex) {
                        Circle().fill(color).frame(width: 8, height: 8)
                    }
                    Text(message.from)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
                if showMqttIndicator && message.isViaMqtt {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("Via MQTT")
                }
                Spacer(minLength: 0)
                Text(message.time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Reply context and message body share one bubble.
            VStack(alignment: .leading, spacing: 5) {
                if message.replyToPacketId != nil {
                    ReplyContextView(target: replyTarget)
                }

                HStack(spacing: 4) {
                    if message.hasAlertBell {
                        Image(systemName: "bell.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                    if message.isEncrypted {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .help("Verschlüsselt — Kanalschlüssel (PSK) nicht konfiguriert")
                        Text(message.isEncrypted && !protocolReady
                             ? "Kanal wird noch geladen…"
                             : message.message)
                            .italic()
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else if let attributed = Self.detectLinks(in: message.message) {
                        Text(attributed)
                            .textSelection(.enabled)
                    } else {
                        Text(message.message)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                message.isEncrypted
                    ? Color.secondary.opacity(0.08)
                    : (isMine ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12))
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contextMenu {
                if message.routablePacketId != nil {
                    if let onReply {
                        Button {
                            onReply()
                        } label: {
                            Label("Antworten", systemImage: "arrowshape.turn.up.left")
                        }
                    }

                    if let onReaction {
                        if onReply != nil {
                            Divider()
                        }
                        // Quick reactions
                        ForEach(["👍", "❤️", "😂", "👎"], id: \.self) { emoji in
                            Button(emoji) { onReaction(emoji) }
                        }
                        Divider()
                        Button("More Reactions…") { showEmojiPicker = true }
                    }
                }
            }
            .popover(isPresented: $showEmojiPicker) {
                EmojiPickerView { emoji in
                    showEmojiPicker = false
                    onReaction?(emoji)
                }
            }

            // Reaction pills
            ReactionPillsView(reactions: message.reactionsByEmoji)

            if isMine {
                DeliveryStateLabel(state: message.deliveryState)
            }
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
        .environment(\.openURL, OpenURLAction { url in
            pendingURL = url
            showLinkConfirmation = true
            return .handled
        })
        .alert("Link öffnen?", isPresented: $showLinkConfirmation, presenting: pendingURL) { url in
            Button("Öffnen") {
                NSWorkspace.shared.open(url)
            }
            Button("Link kopieren") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { url in
            Text(url.absoluteString)
        }
    }

    /// Detect URLs in the given string and return an AttributedString with `.link` attributes.
    /// Returns `nil` if no links are found.
    private static let linkDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    private static func detectLinks(in text: String) -> AttributedString? {
        guard let detector = linkDetector else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, range: range)
        guard !matches.isEmpty else { return nil }

        var attributed = AttributedString(text)
        for match in matches {
            guard let matchRange = Range(match.range, in: text),
                  let url = match.url else { continue }
            let attrRange = AttributedString.Index(matchRange.lowerBound, within: attributed)
                .flatMap { lower in
                    AttributedString.Index(matchRange.upperBound, within: attributed)
                        .map { upper in lower..<upper }
                }
            guard let attrRange else { continue }
            attributed[attrRange].link = url
        }
        return attributed
    }
}
