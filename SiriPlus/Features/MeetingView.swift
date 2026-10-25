import AppKit
import SwiftUI

struct MeetingView: View {
    @ObservedObject var meeting: MeetingModel
    @ObservedObject var permissions: PermissionCenter
    let isModelReady: Bool
    let showPanel: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            transcriptColumn
                .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            hintsColumn
                .frame(minWidth: 200, idealWidth: 280, maxWidth: 340, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .top) { statusBar }
        .navigationTitle("Meeting")
        .navigationSubtitle("On-device speech recognition")
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
                .frame(minWidth: 150)
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
        let needsAccess = !permissions.allGranted && meeting.phase == .idle
        if meeting.phase != .idle || showsSignIn || needsAccess {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    switch meeting.phase {
                    case .starting:
                        Label("Preparing speech recognition…", systemImage: "waveform")
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .glassEffect()
                    case .running:
                        HStack(spacing: 12) {
                            Label("Meeting in progress", systemImage: "record.circle")
                                .foregroundStyle(.red)
                            LevelView(title: Speaker.them.title, level: meeting.levels[.them] ?? 0)
                            LevelView(title: Speaker.me.title, level: meeting.levels[.me] ?? 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .glassEffect()
                        .help("Let the participants know you use an assistant.")
                    case .idle:
                        EmptyView()
                    }
                    if needsAccess, let missing = permissions.missingSummary {
                        HStack(spacing: 8) {
                            Label(missing, systemImage: "lock.shield")
                                .lineLimit(1)
                                .help("If Siri+ is already switched on in System Settings, switch it off and on again: macOS treats every new build as a new app.")
                            Button("Allow") { Task { await permissions.requestMissing() } }
                                .buttonStyle(.glassProminent)
                                .controlSize(.small)
                        }
                        .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 4)
                        .glassEffect(.regular.tint(.orange.opacity(0.2)))
                    }
                    Spacer(minLength: 0)
                    if showsSignIn {
                        HStack(spacing: 8) {
                            Label("Without a signed-in model the transcript works, but hints don’t.", systemImage: "person.badge.key")
                                .lineLimit(1)
                            Button("Sign In", action: openSettings)
                                .buttonStyle(.glassProminent)
                                .controlSize(.small)
                        }
                        .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 4)
                        .glassEffect(.regular.tint(.orange.opacity(0.2)))
                    }
                }
                .font(.caption)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
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
                    .padding(.top, 40)
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(meeting.transcript.turns) { turn in
                            TurnRow(turn: turn).id(turn.id)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
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
                .help("Copy the transcript")
                .padding(14)
            }
        }
    }

    // MARK: Hints

    private var hintsColumn: some View {
        ScrollView {
            GlassEffectContainer(spacing: 10) {
                VStack(alignment: .leading, spacing: 10) {
                    notesEditor
                    if meeting.hints.contains(where: { !$0.isEmptyAnswer || $0.failure != nil }) {
                        Text("Hints")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                    ForEach(meeting.hints.reversed()) { hint in
                        if !hint.isEmptyAnswer || hint.failure != nil {
                            HintCard(hint: hint)
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Meeting notes", systemImage: "note.text")
                .font(.subheadline.weight(.semibold))
                .help("Agenda, project facts, numbers, things not to forget. They make hints more accurate; names and terms from here also help speech recognition when the meeting starts.")
            TextEditor(text: $meeting.notes)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 60, maxHeight: 140)
                .overlay(alignment: .topLeading) {
                    if meeting.notes.isEmpty {
                        Text("Agenda, project facts, numbers, things not to forget. They make hints more accurate.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// One speaker turn; also used for saved meetings in History.
struct TurnRow: View {
    let turn: TranscriptTurn

    /// Volatile text is still being recognized and may change, so it is dimmed.
    private var styledText: AttributedString {
        let separator = turn.finalText.isEmpty || turn.volatileText.isEmpty ? "" : " "
        var volatile = AttributedString(turn.volatileText)
        volatile.foregroundColor = .secondary
        return AttributedString(turn.finalText + separator) + volatile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
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
                .lineSpacing(2)
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
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                .frame(width: 56, height: 5)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(level > 0.05 ? Color.green : Color.secondary)
                        .frame(width: 56 * CGFloat(level), height: 5)
                        .animation(.smooth(duration: 0.15), value: level)
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio level: \(title)")
        .accessibilityValue(Text(Double(level), format: .percent.precision(.fractionLength(0))))
    }
}
