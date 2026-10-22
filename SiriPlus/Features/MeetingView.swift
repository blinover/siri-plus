import AppKit
import SwiftUI

struct MeetingView: View {
    @ObservedObject var meeting: MeetingModel
    let hasAPIKey: Bool
    let showPanel: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                transcriptColumn
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                hintsColumn
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 460, maxHeight: .infinity)
            }
        }
        .onAppear { meeting.refreshSources() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Созвон").font(.title2.bold())
                    Text("Речь распознаётся на этом Mac. В Claude уходит только последний фрагмент расшифровки, когда нужна подсказка.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                controls
            }

            if meeting.phase == .idle {
                HStack(spacing: 12) {
                    Picker("Звук собеседника", selection: $meeting.selectedSourceID) {
                        ForEach(meeting.sources) { source in
                            Text(source.name).tag(source.id)
                        }
                    }
                    .frame(maxWidth: 320)
                    Button("Обновить", systemImage: "arrow.clockwise") { meeting.refreshSources() }
                        .labelStyle(.iconOnly)
                        .help("Обновить список запущенных приложений")
                    Spacer()
                }
            } else {
                HStack(spacing: 18) {
                    LevelView(title: Speaker.them.title, level: meeting.levels[.them] ?? 0)
                    LevelView(title: Speaker.me.title, level: meeting.levels[.me] ?? 0)
                    Spacer()
                    Text("Предупредите участников, что используете помощника.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !hasAPIKey {
                HStack {
                    Label("Без ключа Claude API расшифровка работает, а подсказки — нет.", systemImage: "key")
                    Button("Добавить ключ", action: openSettings)
                }
                .font(.callout)
            }
        }
        .padding(24)
    }

    @ViewBuilder
    private var controls: some View {
        HStack {
            switch meeting.phase {
            case .idle:
                if !meeting.transcript.isEmpty {
                    Button("Очистить", systemImage: "trash") { meeting.clear() }
                }
                Button("Начать", systemImage: "record.circle") { Task { await meeting.start() } }
                    .buttonStyle(.borderedProminent)
            case .starting:
                ProgressView().controlSize(.small)
                Text("Готовлю распознавание…").foregroundStyle(.secondary)
            case .running:
                Button("Панель", systemImage: "macwindow.on.rectangle", action: showPanel)
                Button("Подсказать", systemImage: "sparkles") { meeting.askNow() }
                    .keyboardShortcut(.space, modifiers: [.control, .option])
                    .disabled(meeting.transcript.isEmpty)
                Button("Остановить", systemImage: "stop.fill") { Task { await meeting.stop() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
    }

    private var transcriptColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Расшифровка").font(.headline)
                Spacer()
                if !meeting.transcript.isEmpty {
                    Button("Скопировать", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(meeting.transcriptText, forType: .string)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Скопировать расшифровку")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    if meeting.transcript.isEmpty {
                        Text(meeting.isRunning
                             ? "Слушаю… Текст появится, когда кто-нибудь заговорит."
                             : "Выберите приложение созвона и нажмите «Начать». Лучше в наушниках: так ваш микрофон не повторяет собеседника.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(meeting.transcript.turns) { turn in
                                TurnRow(turn: turn).id(turn.id)
                            }
                        }
                        .padding(20)
                    }
                }
                .onChange(of: meeting.transcript.turns.last?.text) {
                    if let id = meeting.transcript.turns.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    private var hintsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Подсказки").font(.headline)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    notesEditor
                    ForEach(meeting.hints.reversed()) { hint in
                        if !hint.isEmptyAnswer || hint.failure != nil {
                            HintCard(hint: hint)
                        }
                    }
                }
                .padding(16)
            }
        }
        .background(.quaternary.opacity(0.25))
    }

    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Материалы к встрече").font(.subheadline.weight(.semibold))
            TextEditor(text: $meeting.notes)
                .font(.callout)
                .frame(minHeight: 70, maxHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            Text("Повестка, факты о проекте, цифры, о чём не забыть. Помогают подсказкам быть точнее.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct TurnRow: View {
    let turn: TranscriptTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(turn.speaker.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(turn.speaker == .them ? Color.indigo : Color.secondary)
                Text(turn.startedAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            // Volatile text is still being recognised and may change, so it is dimmed.
            Text("\(turn.finalText)\(turn.finalText.isEmpty || turn.volatileText.isEmpty ? "" : " ")\(Text(turn.volatileText).foregroundStyle(.secondary))")
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct HintCard: View {
    let hint: MeetingHint

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(hint.kind.title, systemImage: hint.kind == .question ? "questionmark.bubble" : "lightbulb")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.indigo)
                Spacer()
                if hint.isStreaming { ProgressView().controlSize(.mini) }
                Text(hint.createdAt, style: .time).font(.caption2).foregroundStyle(.tertiary)
            }
            if let question = hint.question {
                Text("«\(question)»").font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            if let failure = hint.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else {
                Text(hint.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct LevelView: View {
    let title: String
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ProgressView(value: Double(level))
                .progressViewStyle(.linear)
                .frame(width: 90)
                .tint(level > 0.05 ? .green : .secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Уровень звука: \(title)")
    }
}
