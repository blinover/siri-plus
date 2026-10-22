import AppKit
import SwiftUI

struct MeetingView: View {
    @ObservedObject var meeting: MeetingModel
    let isModelReady: Bool
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
                    Text("Meeting").font(.title2.bold())
                    Text("Speech is recognized on this Mac. Only the latest part of the transcript goes to the model, when a hint is needed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                controls
            }

            if meeting.phase == .idle {
                HStack(spacing: 12) {
                    Picker("Their audio", selection: $meeting.selectedSourceID) {
                        ForEach(meeting.sources) { source in
                            Text(source.name).tag(source.id)
                        }
                    }
                    .frame(maxWidth: 320)
                    Button("Refresh", systemImage: "arrow.clockwise") { meeting.refreshSources() }
                        .labelStyle(.iconOnly)
                        .help("Refresh the list of running apps")
                    Spacer()
                }
            } else {
                HStack(spacing: 18) {
                    LevelView(title: Speaker.them.title, level: meeting.levels[.them] ?? 0)
                    LevelView(title: Speaker.me.title, level: meeting.levels[.me] ?? 0)
                    Spacer()
                    Text("Let the participants know you use an assistant.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !isModelReady {
                HStack {
                    Label("Without a signed-in model the transcript works, but hints don’t.", systemImage: "person.badge.key")
                    Button("Sign In", action: openSettings)
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
                    Button("Clear", systemImage: "trash") { meeting.clear() }
                }
                Button("Start", systemImage: "record.circle") { Task { await meeting.start() } }
                    .buttonStyle(.borderedProminent)
            case .starting:
                ProgressView().controlSize(.small)
                Text("Preparing speech recognition…").foregroundStyle(.secondary)
            case .running:
                Button("Panel", systemImage: "macwindow.on.rectangle", action: showPanel)
                Button("Hint Now", systemImage: "sparkles") { meeting.askNow() }
                    .keyboardShortcut(.space, modifiers: [.control, .option])
                    .disabled(meeting.transcript.isEmpty)
                Button("Stop", systemImage: "stop.fill") { Task { await meeting.stop() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
    }

    private var transcriptColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transcript").font(.headline)
                Spacer()
                if !meeting.transcript.isEmpty {
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(meeting.transcriptText, forType: .string)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Copy the transcript")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    if meeting.transcript.isEmpty {
                        Group {
                            if meeting.isRunning {
                                Text("Listening… Text appears when someone speaks.")
                            } else {
                                Text("Choose the call app and click Start. Headphones work best: then your microphone doesn’t repeat the other side.")
                            }
                        }
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
            Text("Hints").font(.headline)
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
            Text("Meeting notes").font(.subheadline.weight(.semibold))
            TextEditor(text: $meeting.notes)
                .font(.callout)
                .frame(minHeight: 70, maxHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            Text("Agenda, project facts, numbers, things not to forget. They make hints more accurate.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct TurnRow: View {
    let turn: TranscriptTurn

    /// Volatile text is still being recognized and may change, so it is dimmed.
    private var styledText: AttributedString {
        let separator = turn.finalText.isEmpty || turn.volatileText.isEmpty ? "" : " "
        var volatile = AttributedString(turn.volatileText)
        volatile.foregroundColor = .secondary
        return AttributedString(turn.finalText + separator) + volatile
    }

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
            Text(styledText)
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
                Text(verbatim: "“\(question)”").font(.caption).foregroundStyle(.secondary).lineLimit(3)
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
        .accessibilityLabel("Audio level: \(title)")
    }
}
