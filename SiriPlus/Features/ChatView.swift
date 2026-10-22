import SwiftUI

struct ChatView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Помощник").font(.title2.bold())
                    Text("Твой контекст. Один диалог.").foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.newConversation()
                } label: {
                    Label("Новый диалог", systemImage: "square.and.pencil")
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
                                    ProgressView("Готовлю ответ…").controlSize(.small)
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
                        .accessibilityLabel("Снимок основного экрана")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Снимок экрана · \(snapshot.createdAt.formatted(date: .omitted, time: .shortened))")
                            .font(.callout.weight(.medium))
                        Text("Уйдёт в Claude вместе со следующим сообщением.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Удалить", role: .destructive) { model.clearSnapshot() }
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
            Text("С чего начнём?").font(.system(size: 32, weight: .semibold))
            Text(model.hasAPIKey ? "Спроси что угодно или сделай снимок экрана — я посмотрю, что на нём." : "Чтобы я отвечал, добавь ключ Claude API в Настройках.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                suggestion("Объясни, что на экране", symbol: "rectangle.dashed")
                suggestion("Помоги с вопросом", symbol: "text.bubble")
            }
            Label("Снимки делаются только по кнопке", systemImage: "hand.raised")
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
            TextField("Напиши запрос…", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...6)
                .font(.body)
                .accessibilityLabel("Текст запроса")

            HStack {
                Button {
                    Task { await model.captureScreen() }
                } label: {
                    Label(model.isCapturing ? "Снимаю…" : "Снимок экрана", systemImage: "camera.viewfinder")
                }
                .disabled(model.isCapturing)
                .help("Снять основной экран без окна Siri+. macOS запросит разрешение.")
                Spacer()
                if model.isReplying {
                    Button("Остановить", systemImage: "stop.fill") { model.stopReply() }
                } else {
                    Button("Отправить", systemImage: "arrow.up") {
                        model.send(model.draft)
                        model.draft = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Text("⌘↩ отправить · ⌘N новый диалог · история хранится до закрытия приложения")
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
                    Text(message.role == .user ? "Ты" : "Siri+")
                        .font(.callout.weight(.semibold))
                    if showTimestamp {
                        Text(message.createdAt, style: .time)
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                if message.imageJPEG != nil {
                    Label("Снимок экрана", systemImage: "photo")
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
