import SwiftUI

struct ChatView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Assistant").font(.title2.bold())
                    Text("Your context. One conversation.").foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.newConversation()
                } label: {
                    Label("New Conversation", systemImage: "square.and.pencil")
                }
                // The app has no main menu (menu bar only), so the shortcut lives on the button.
                .keyboardShortcut("n", modifiers: .command)
            }
            .padding(24)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    if model.messages.isEmpty {
                        welcome
                    } else {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            ForEach(model.messages) { message in
                                MessageRow(message: message, showTimestamp: model.preferences.showTimestamps)
                                    .id(message.id)
                            }
                            if model.isReplying {
                                if model.partialReply.isEmpty {
                                    ProgressView("Preparing an answer…").controlSize(.small)
                                } else {
                                    MessageRow(
                                        message: ChatMessage(role: .assistant, text: model.partialReply),
                                        showTimestamp: false
                                    )
                                }
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(28)
                    }
                }
                .onChange(of: model.messages.count) {
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: model.partialReply) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }

            if let snapshot = model.snapshot {
                HStack(spacing: 14) {
                    Image(nsImage: snapshot.image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 112, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Screenshot of the main display")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Screenshot · \(snapshot.createdAt.formatted(date: .omitted, time: .shortened))")
                            .font(.callout.weight(.medium))
                        Text("It will be sent with your next message.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { model.clearSnapshot() }
                }
                .padding(16)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 24)
            }

            composer
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.indigo)
            Text("Where shall we start?").font(.system(size: 32, weight: .semibold))
            Group {
                if model.isModelReady {
                    Text("Ask anything, or take a screenshot and I’ll look at it.")
                } else {
                    Text("To get answers, sign in to Claude or ChatGPT in Settings.")
                }
            }
            .font(.title3)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                suggestion(String(localized: "Explain what’s on the screen"), symbol: "rectangle.dashed")
                suggestion(String(localized: "Help me with a question"), symbol: "text.bubble")
            }
            Label("Screenshots are taken only when you click the button", systemImage: "hand.raised")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 660, alignment: .leading)
        .padding(36)
        .padding(.top, 30)
    }

    private func suggestion(_ title: String, symbol: String) -> some View {
        Button { model.draft = title } label: {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Type a request…", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...6)
                .font(.body)
                .accessibilityLabel("Request text")

            HStack {
                Button {
                    Task { await model.captureScreen() }
                } label: {
                    if model.isCapturing {
                        Label("Capturing…", systemImage: "camera.viewfinder")
                    } else {
                        Label("Screenshot", systemImage: "camera.viewfinder")
                    }
                }
                .disabled(model.isCapturing)
                .help("Capture the main display without the Siri+ window. macOS will ask for permission.")
                Spacer()
                if model.isReplying {
                    Button("Stop", systemImage: "stop.fill") { model.stopReply() }
                } else {
                    Button("Send", systemImage: "arrow.up") {
                        model.send(model.draft)
                        model.draft = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Text("⌘↩ send · ⌘N new conversation · history is kept until the app quits")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
        .padding(24)
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let showTimestamp: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: message.role == .user ? "person.crop.circle" : "sparkles")
                .font(.title3)
                .foregroundStyle(message.role == .user ? Color.secondary : Color.indigo)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Group {
                        if message.role == .user {
                            Text("You")
                        } else {
                            Text(verbatim: "Siri+")
                        }
                    }
                    .font(.callout.weight(.semibold))
                    if showTimestamp {
                        Text(message.createdAt, style: .time)
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                if message.imageJPEG != nil {
                    Label("Screenshot", systemImage: "photo")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(message.text)
                    .textSelection(.enabled)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
