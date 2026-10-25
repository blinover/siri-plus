import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Meeting tab: the current meeting first, then past meetings with their summaries.
struct HistoryView<Live: View>: View {
    enum Selection: Hashable {
        case live
        case record(UUID)
    }

    @ObservedObject var history: MeetingHistory
    @ObservedObject var meeting: MeetingModel
    let askAbout: (MeetingRecord) -> Void
    @ViewBuilder let live: () -> Live
    @State private var selection: Selection = .live
    @State private var pendingDeletion: MeetingRecord?
    @State private var query = ""

    private var visibleRecords: [MeetingRecord] { history.records.filter { $0.matches(query) } }

    var body: some View {
        HStack(spacing: 0) {
            meetingList
                .frame(minWidth: 170, idealWidth: 210, maxWidth: 260, maxHeight: .infinity)
            Divider()
            Group {
                switch selection {
                case .live:
                    live()
                case .record(let id):
                    if let record = history.records.first(where: { $0.id == id }) {
                        MeetingDetail(record: record, history: history, askAbout: askAbout).id(record.id)
                    } else {
                        live()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Meeting")
        // A meeting that just ended opens with its summary; a starting one shows the live view.
        .onChange(of: history.records.first?.id) { _, id in if let id { selection = .record(id) } }
        .onChange(of: meeting.phase) { _, phase in if phase != .idle { selection = .live } }
        .searchable(text: $query, placement: .toolbar, prompt: Text("Search meetings"))
        .confirmationDialog(
            "Delete the meeting?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { record in
            Button("Delete", role: .destructive) {
                if selection == .record(record.id) { selection = .live }
                history.delete(record.id)
            }
        } message: { _ in
            Text("The transcript and summary are removed from this Mac.")
        }
    }

    private var meetingList: some View {
        List(selection: Binding(get: { selection }, set: { if let value = $0 { selection = value } })) {
            liveRow.tag(Selection.live)
            Section("Past meetings") {
                if history.records.isEmpty {
                    Text("Finished meetings appear here with a title and a summary.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if visibleRecords.isEmpty {
                    Text("Nothing found.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(visibleRecords) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.displayTitle)
                            .font(.callout)
                            .lineLimit(2)
                        Text(record.startedAt, format: .dateTime.day().month().year().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(Selection.record(record.id))
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) { pendingDeletion = record }
                    }
                }
            }
        }
    }

    private var liveRow: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Current meeting").font(.callout.weight(.medium))
                Group {
                    switch meeting.phase {
                    case .running: Text("Listening")
                    case .starting: Text("Starting…")
                    case .idle: Text("Not started")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: meeting.isRunning ? "record.circle.fill" : "waveform")
                .foregroundStyle(meeting.isRunning ? Color.red : Color.accentColor)
        }
        .padding(.vertical, 2)
    }
}

private struct MeetingDetail: View {
    let record: MeetingRecord
    @ObservedObject var history: MeetingHistory
    let askAbout: (MeetingRecord) -> Void
    @State private var title = ""
    @State private var participants = ""
    @FocusState private var focusedField: Field?

    private enum Field { case title, participants }

    private var isSummarizing: Bool { history.summarizing.contains(record.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Meeting title", text: $title, prompt: Text(record.displayTitle))
                        .textFieldStyle(.plain)
                        .font(.title3.bold())
                        .focused($focusedField, equals: .title)
                        .onSubmit(commitTitle)
                    Text(dateline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                summaryCard
                if !record.tasks.isEmpty { tasksCard }
                participantsField
                Text("Transcript")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(record.turns) { TurnRow(turn: $0) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .toolbar {
            ToolbarItem {
                Button("Ask About the Meeting", systemImage: "bubble.left.and.text.bubble.right") { askAbout(record) }
                    .help("Ask questions about this meeting in the Assistant")
            }
            ToolbarItem {
                Button("Copy the summary", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.markdown(includingTranscript: false), forType: .string)
                }
                .help("Copy the title, participants, summary and tasks as Markdown")
            }
            ToolbarItem {
                Button("Save as Markdown", systemImage: "square.and.arrow.down", action: saveMarkdown)
                    .help("Save the meeting with its transcript as a Markdown file")
            }
        }
        .onAppear {
            title = record.title
            participants = record.participants.joined(separator: ", ")
        }
        // The model fills an empty title and empty names when the summary arrives.
        .onChange(of: record.title) { title = record.title }
        .onChange(of: record.participants) { participants = record.participants.joined(separator: ", ") }
        .onChange(of: focusedField) { old, _ in
            if old == .title { commitTitle() }
            if old == .participants { commitParticipants() }
        }
        .onDisappear {
            commitTitle()
            commitParticipants()
        }
    }

    private var dateline: String {
        let date = record.startedAt.formatted(date: .complete, time: .shortened)
        let duration = Duration.seconds(record.endedAt.timeIntervalSince(record.startedAt))
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return "\(date) · \(duration)"
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Summary", systemImage: "text.alignleft")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if isSummarizing {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Write the summary again", systemImage: "arrow.clockwise") { history.summarize(record.id) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .controlSize(.small)
                        .help("Write the summary again")
                }
            }
            if let failure = history.summaryFailures[record.id] {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if record.summary.isEmpty {
                Text(isSummarizing ? "Writing the summary…" : "No summary yet.")
                    .foregroundStyle(.secondary)
            } else {
                Text(record.summary)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var tasksCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Tasks", systemImage: "checklist")
                .font(.subheadline.weight(.semibold))
            ForEach(record.tasks) { task in
                Toggle(isOn: Binding(get: { task.isDone }, set: { _ in history.toggleTask(task.id, in: record.id) })) {
                    Text(task.line)
                        .strikethrough(task.isDone)
                        .foregroundStyle(task.isDone ? .secondary : .primary)
                        .textSelection(.enabled)
                }
                .toggleStyle(.checkbox)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var participantsField: some View {
        HStack(spacing: 8) {
            Label("Participants", systemImage: "person.2")
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
            TextField("Names, separated by commas", text: $participants)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .participants)
                .onSubmit(commitParticipants)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
        .help("Names are taken from the conversation. In the transcript, “Me” is your microphone and “Them” is everyone in the call.")
    }

    private func saveMarkdown() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = record.displayTitle.replacingOccurrences(of: "/", with: "-") + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try record.markdown(includingTranscript: true).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            history.errorMessage = String(localized: "The file was not saved. \(error.localizedDescription)")
        }
    }

    private func commitTitle() {
        guard title.trimmingCharacters(in: .whitespacesAndNewlines) != record.title else { return }
        history.rename(record.id, to: title)
    }

    private func commitParticipants() {
        guard MeetingSummary.names(in: participants) != record.participants else { return }
        history.setParticipants(record.id, from: participants)
    }
}
