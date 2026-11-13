import SwiftUI

/// "Aa" button in the composer row that shows or hides `MessageFormatToolbar`.
struct MessageFormatToggleButton: View {
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Text("Aa")
                .fontWeight(isExpanded ? .bold : .regular)
        }
        .buttonStyle(.borderless)
        .help(isExpanded ? "Hide formatting" : "Show formatting")
        .accessibilityLabel("Formatting")
        .accessibilityValue(isExpanded ? Text("Shown") : Text("Hidden"))
    }
}

/// Compact row of format buttons above the message input. `TextField` exposes
/// no selection on macOS 14, so markers and links are appended at the end.
struct MessageFormatToolbar: View {
    @Binding var text: String

    @State private var showLinkPopover = false
    @State private var linkURL = ""
    @State private var linkLabel = ""

    var body: some View {
        HStack(spacing: 2) {
            formatButton("**", help: "Bold") { Text("B").bold() }
            formatButton("*", help: "Italic") { Text("I").italic() }
            formatButton("~~", help: "Strikethrough") { Text("S").strikethrough() }
            formatButton("`", help: "Code") { Text("</>").font(.system(.body, design: .monospaced)) }

            Button {
                linkURL = ""
                linkLabel = ""
                showLinkPopover = true
            } label: {
                Image(systemName: "link")
                    .frame(minWidth: 22)
            }
            .help("Insert Link")
            .accessibilityLabel("Insert Link")
            .popover(isPresented: $showLinkPopover, arrowEdge: .bottom) {
                linkPopover
            }

            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
    }

    private func formatButton(
        _ marker: String,
        help: LocalizedStringKey,
        @ViewBuilder label: () -> some View
    ) -> some View {
        Button {
            apply(MessageFormatting.wrap(text, selection: nil, marker: marker).text)
        } label: {
            label().frame(minWidth: 22)
        }
        .help(help)
        .accessibilityLabel(help)
    }

    private var normalizedURL: String? {
        MessageFormatting.normalizedLinkURL(linkURL)
    }

    private var linkPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Insert Link")
                .font(.headline)
            TextField("https://…", text: $linkURL)
                .textFieldStyle(.roundedBorder)
                .onSubmit(insertLink)
            TextField("Link text (optional)", text: $linkLabel)
                .textFieldStyle(.roundedBorder)
                .onSubmit(insertLink)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { showLinkPopover = false }
                    .keyboardShortcut(.cancelAction)
                Button("Insert", action: insertLink)
                    .keyboardShortcut(.defaultAction)
                    .disabled(normalizedURL == nil)
            }
            .buttonStyle(.automatic)
        }
        .padding(12)
        .frame(width: 280)
    }

    private func insertLink() {
        guard let url = normalizedURL else { return }
        apply(MessageFormatting.insertLink(text, selection: nil, url: url, label: linkLabel))
        showLinkPopover = false
    }

    private func apply(_ newText: String) {
        text = MessageItem.truncatingToPayloadLimit(newText)
    }
}
