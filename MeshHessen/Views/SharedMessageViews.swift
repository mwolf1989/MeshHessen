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

/// Unified message bubble used in both channel chat and DM conversations.
struct MessageBubbleView: View {
    let message: MessageItem
    let isMine: Bool
    var protocolReady: Bool = true
    var showColorDot: Bool = false
    var showMqttIndicator: Bool = false

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

            // Message body
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
                } else {
                    Text(message.message)
                        .textSelection(.enabled)
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

            if isMine {
                DeliveryStateLabel(state: message.deliveryState)
            }
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
    }
}
