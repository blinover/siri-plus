import AppKit
import SwiftUI

struct MeetingView: View {
    @ObservedObject var meeting: MeetingModel
    let isModelReady: Bool
    let showPanel: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            transcriptColumn
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            hintsColumn
                .frame(minWidth: 300, idealWidth: 360, maxWidth: 420, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .top) { statusBar }
        .navigationTitle("Meeting")
        .navigationSubtitle("Speech is recognized on this Mac. Only the latest part of the transcript goes to the model, when a hint is needed.")
        .toolbar { toolbarContent }
        .onAppear { meeting.refreshSources() }
    }

    // MARK: Toolbar and status

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        switch meeting.phase {
        case .idle:
            ToolbarItem {
                Picker("Their audio", selection: $meeting.selectedSourceID) {
                    ForEach(meeting.sources) { source in
                        Text(verbatim: source.name).tag(source.id)
                    }
                }
                .frame(minWidth: 180)
                .help("Their audio")
            }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { meeting.refreshSources() }
                    .help("Refresh the list of running apps")
            }
            ToolbarSpacer(.fixed)
            if !meeting.transcript.isEmpty {
                ToolbarItem {
                    Button("Clear", systemImage: "trash") { meeting.clear() }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Start", systemImage: "record.circle") { Task { await meeting.start() } }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
            }
        case .starting:
            ToolbarItem(placement: .primaryAction) {
                ProgressView().controlSize(.small)
            }
        case .running:
            ToolbarItem {
                Button("Panel", systemImage: "macwindow.on.rectangle", action: showPanel)
            }
            ToolbarItem {
                Button("Hint Now", systemImage: "sparkles") { meeting.askNow() }
                    .keyboardShortcut(.space, modifiers: [.control, .option])
                    .disabled(meeting.transcript.isEmpty)
            }
            ToolbarSpacer(.fixed)
            ToolbarItem(placement: .primaryAction) {
                Button("Stop", systemImage: "stop.fill") { Task { await meeting.stop() } }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
            }
        }
    }

    /// A floating glass strip: what is happening now, and what is missing.
    @ViewBuilder
    private var statusBar: some View {
        let showsSignIn = !isModelReady
        if meeting.phase != .idle || showsSignIn {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    switch meeting.phase {
                    case .starting:
                        Label("Preparing speech recognition…", systemImage: "waveform")
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .glassEffect()
                    case .running:
                        HStack(spacing: 16) {
                            Label("Meeting in progress", systemImage: "record.circle")
                                .foregroundStyle(.red)
                            LevelView(title: Speaker.them.title, level: meeting.levels[.them] ?? 0)
                            LevelView(title: Speaker.me.title, level: meeting.levels[.me] ?? 0)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .glassEffect()
                        Text("Let the participants know you use an assistant.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .idle:
                        EmptyView()
                    }
                    Spacer(minLength: 0)
                    if showsSignIn {
                        HStack(spacing: 8) {
                            Label("Without a signed-in model the transcript works, but hints don’t.", systemImage: "person.badge.key")
                            Button("Sign In", action: openSettings)
                                .buttonStyle(.glassProminent)
                                .controlSize(.small)
                        }
                        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
                        .glassEffect(.regular.tint(.orange.opacity(0.2)))
                    }
                }
                .font(.callout)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }

    // MARK: Transcript

    private var transcriptColumn: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if meeting.transcript.isEmpty {
                    ContentUnavailableView {
                        Label("Transcript", systemImage: meeting.isRunning ? "waveform" : "waveform.badge.mic")
                    } description: {
                        if meeting.isRunning {
                            Text("Listening… Text appears when someone speaks.")
                        } else {
                            Text("Choose the call app and click Start. Headphones work best: then your microphone doesn’t repeat the other side.")
                        }
                    }
                    .padding(.top, 60)
                } else {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(meeting.transcript.turns) { turn in
                            TurnRow(turn: turn).id(turn.id)
                        }
                    }
                    .padding(24)
                }
            }
            .onChange(of: meeting.transcript.turns.last?.text) {
                if let id = meeting.transcript.turns.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !meeting.transcript.isEmpty {
                Button("Copy the transcript", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(meeting.transcriptText, forType: .string)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .help("Copy the transcript")
                .padding(20)
            }
        }
    }

    // MARK: Hints

    private var hintsColumn: some View {
        ScrollView {
            GlassEffectContainer(spacing: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    notesEditor
                    if meeting.hints.contains(where: { !$0.isEmptyAnswer || $0.failure != nil }) {
                        Text("Hints")
                            .font(.headline)
                            .padding(.top, 6)
                    }
                    ForEach(meeting.hints.reversed()) { hint in
                        if !hint.isEmptyAnswer || hint.failure != nil {
                            HintCard(hint: hint)
                        }
                    }
                }
                .padding(18)
            }
        }
    }

    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Meeting notes", systemImage: "note.text")
                .font(.headline)
            TextEditor(text: $meeting.notes)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 80, maxHeight: 160)
            Text("Agenda, project facts, numbers, things not to forget. They make hints more accurate.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
        VStack(alignment: .leading, spacing: 4) {
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
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct HintCard: View {
    let hint: MeetingHint

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct LevelView: View {
    let title: String
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Capsule()
                .fill(.quaternary)
                .frame(width: 80, height: 6)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(level > 0.05 ? Color.green : Color.secondary)
                        .frame(width: 80 * CGFloat(level), height: 6)
                        .animation(.smooth(duration: 0.15), value: level)
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio level: \(title)")
        .accessibilityValue(Text(Double(level), format: .percent.precision(.fractionLength(0))))
    }
}
