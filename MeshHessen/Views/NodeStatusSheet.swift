import SwiftUI

/// Edits the free-text status (port 36) the own node broadcasts.
struct NodeStatusSheet: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let maxBytes = MeshtasticProtocolService.nodeStatusMaxBytes

    init(initialStatus: String) {
        _text = State(initialValue: initialStatus)
    }

    private var byteCount: Int {
        text.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Node Status", systemImage: "text.bubble")
                .font(.title2.bold())

            Text("Other nodes show this text next to your node. Leave it empty to clear the status.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .trailing, spacing: 4) {
                TextField("Status", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save(text) }
                    .onChange(of: text) { _, newValue in
                        let clamped = UTF8Limits.clamp(newValue, maxBytes: maxBytes)
                        if clamped != newValue { text = clamped }
                    }
                Text("\(byteCount)/\(maxBytes) bytes")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(byteCount >= maxBytes ? .orange : .secondary)
            }

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Clear") { save("") }
                    .disabled(isSaving)
                Button("Save") { save(text) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
        }
        .padding(24)
        .frame(width: 440)
        .alert(
            "Status could not be saved",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save(_ status: String) {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await coordinator.protocol_.setOwnNodeStatus(status)
                dismiss()
            } catch {
                AppLogger.shared.log("[NodeStatus] Saving own status failed: \(error)")
                errorMessage = error.localizedDescription
            }
        }
    }
}
