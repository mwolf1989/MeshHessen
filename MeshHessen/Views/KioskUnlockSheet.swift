import SwiftUI

struct KioskUnlockSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var kioskState = KioskState.shared
    @State private var password = ""
    @State private var isChecking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Unlock Kiosk Mode", systemImage: "lock.open")
                .font(.title2.bold())

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(unlock)

            if let error = kioskState.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Unlock", action: unlock)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty || isChecking)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func unlock() {
        guard !password.isEmpty, !isChecking else { return }
        isChecking = true
        Task {
            let succeeded = await kioskState.unlock(with: password)
            isChecking = false
            if succeeded { dismiss() }
        }
    }
}
