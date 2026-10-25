import SwiftUI

struct ChatView: View {
    @ObservedObject var model: AppModel
    @FocusState private var isComposerFocused: Bool
    @State private var isDropTargeted = false
    @State private var query = ""

    var body: some View {
        HStack(spacing: 0) {
            ChatList(model: model, chats: model.chats, query: query)
                .frame(minWidth: 170, idealWidth: 210, maxWidth: 260, maxHeight: .infinity)
            Divider()
            conversation
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Chat")
        .searchable(text: $query, placement: .toolbar, prompt: Text("Search chats"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Chat", systemImage: "square.and.pencil") { model.newConversation() }
                    // The app has no main menu (menu bar only), so the shortcut lives on the button.
                    .keyboardShortcut("n", modifiers: .command)
                    .help("New Chat (⌘N)")
            }
        }
        .onAppear { isComposerFocused = true }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if model.messages.isEmpty {
                    welcome
                } else {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(model.messages) { message in
                            MessageRow(message: message, showTimestamp: model.preferences.showTimestamps)
                                .id(message.id)
                        }
                        if model.isReplying {
                            if model.partialReply.isEmpty {
                                ProgressView().controlSize(.small).padding(.leading, 30)
                            } else {
                                MessageRow(
                                    message: ChatMessage(role: .assistant, text: model.partialReply),
                                    showTimestamp: false
                                )
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }
            .onChange(of: model.messages.count) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: model.partialReply) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        // Messages scroll under the floating glass composer.
        .safeAreaInset(edge: .bottom) {
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 8) {
                    if let meeting = model.chatMeeting {
                        meetingCard(meeting)
                    }
                    if let snapshot = model.snapshot {
                        snapshotCard(snapshot)
                    }
                    if !model.pendingAttachments.isEmpty || !model.processingAttachments.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(model.pendingAttachments) { attachment in
                                    AttachmentChip(attachment: attachment) { model.removeAttachment(attachment.id) }
                                }
                                ForEach(model.processingAttachments, id: \.self) { ProcessingChip(name: $0) }
                            }
                        }
                    }
                    composer
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        // Files dropped anywhere on the chat go with the next message.
        .dropDestination(for: URL.self) { urls, _ in
            model.attach(urls)
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Cards above the composer

    private func meetingCard(_ meeting: MeetingRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.displayTitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text("Questions are answered from this meeting’s transcript. For example: “What did we decide?” or “Write a follow-up email”.")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("New Chat", systemImage: "xmark") { model.newConversation() }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .help("New Chat (⌘N)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func snapshotCard(_ snapshot: ScreenSnapshot) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: snapshot.image)
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Screenshot of the main display")
            VStack(alignment: .leading, spacing: 1) {
                Text("Screenshot · \(snapshot.createdAt.formatted(date: .omitted, time: .shortened))")
                    .font(.callout.weight(.medium))
                Text("It will be sent with your next message.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Remove", systemImage: "xmark", role: .destructive) { model.clearSnapshot() }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .help("Remove")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Empty state

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.linearGradient(colors: [.blue, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text("Where shall we start?").font(.title2.weight(.semibold))
            Group {
                if model.isModelReady {
                    Text("Ask anything, or take a screenshot and I’ll look at it.")
                } else {
                    Text("To get answers, sign in to Claude or ChatGPT in Settings.")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    suggestion(String(localized: "Explain what’s on the screen"), symbol: "rectangle.dashed")
                    suggestion(String(localized: "Help me with a question"), symbol: "text.bubble")
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 70)
    }

    private func suggestion(_ title: String, symbol: String) -> some View {
        Button {
            model.draft = title
            isComposerFocused = true
        } label: {
            Label(title, systemImage: symbol)
                .font(.callout)
        }
        .buttonStyle(.glass)
    }

    // MARK: Composer

    /// One glass capsule: screenshot, text, send.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                Task { await model.captureScreen() }
            } label: {
                if model.isCapturing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Screenshot", systemImage: "camera.viewfinder")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(model.isCapturing)
            .help("Capture the main display without the Siri+ window. macOS will ask for permission.")

            Button(action: chooseFiles) {
                Label("Attach Files", systemImage: "paperclip")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Attach Files")

            if model.voice.isListening {
                Group {
                    if model.voice.dictation.isEmpty {
                        Text("Listening…").foregroundStyle(.secondary)
                    } else {
                        Text(model.voice.dictation.text)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                // Clicking the text stops listening and leaves the words to edit.
                .onTapGesture { Task { await model.keepDictationAsDraft() } }
            } else {
                GrowingTextEditor(text: $model.draft, placeholder: "Type a request…", onSubmit: send)
                    .focused($isComposerFocused)
                    .padding(.vertical, 3)
                    .accessibilityLabel("Request text")
            }

            Button {
                Task { await model.toggleDictation() }
            } label: {
                Label("Dictate (⌃⌥Space)", systemImage: model.voice.isListening ? "waveform" : "mic.fill")
                    .symbolEffect(.variableColor.iterative, isActive: model.voice.isListening)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(model.voice.isListening ? .red : nil)
            .disabled(model.isReplying)
            .help(model.voice.isListening ? String(localized: "Stop and send") : String(localized: "Dictate (⌃⌥Space)"))

            if model.isReplying {
                Button("Stop", systemImage: "stop.fill") { model.stopReply() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("Stop")
            } else {
                Button("Send", systemImage: "arrow.up", action: send)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled((model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.pendingAttachments.isEmpty) || !model.processingAttachments.isEmpty)
                    .help("Send (Return)")
            }
        }
        .padding(6)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func send() {
        let typed = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Attached files alone are a request too.
        let text = typed.isEmpty && !model.pendingAttachments.isEmpty ? String(localized: "Analyze the attached files.") : typed
        guard model.send(text) != nil else { return }
        model.draft = ""
    }

    private func chooseFiles() {
        let picker = NSOpenPanel()
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = false
        picker.message = String(localized: "Choose images, PDFs, text, audio or video files for Siri+ to analyze.")
        if picker.runModal() == .OK { model.attach(picker.urls) }
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let showTimestamp: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.role == .user ? "person.crop.circle.fill" : "sparkles")
                .font(.body)
                .foregroundStyle(message.role == .user ? Color.secondary : Color.indigo)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Group {
                        if message.role == .user {
                            Text("You")
                        } else {
                            Text(verbatim: "Siri+")
                        }
                    }
                    .font(.caption.weight(.semibold))
                    if showTimestamp {
                        Text(message.createdAt, style: .time)
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    if message.imageJPEG != nil {
                        Label("Screenshot", systemImage: "photo")
                            .labelStyle(.iconOnly)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ForEach(message.attachments) { attachment in
                    Label(attachment.name, systemImage: attachment.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(message.text)
                    .textSelection(.enabled)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Saved chats, newest first; choosing one continues it.
private struct ChatList: View {
    @ObservedObject var model: AppModel
    @ObservedObject var chats: ChatHistory
    let query: String

    private var visible: [ChatConversation] { chats.conversations.filter { $0.matches(query) } }

    var body: some View {
        List(selection: Binding(get: { model.currentChatID }, set: { if let id = $0 { model.openChat(id) } })) {
            ForEach(visible) { conversation in
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title)
                        .font(.callout)
                        .lineLimit(2)
                    HStack(spacing: 4) {
                        if conversation.meetingID != nil {
                            Image(systemName: "waveform")
                        }
                        Text(conversation.updatedAt, format: .relative(presentation: .named))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(conversation.id)
                .contextMenu {
                    Button("Delete", systemImage: "trash", role: .destructive) { model.deleteChat(conversation.id) }
                }
            }
        }
        .overlay {
            if chats.conversations.isEmpty {
                ContentUnavailableView {
                    Label("No chats yet", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Your chats are saved on this Mac.")
                }
            } else if visible.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}
