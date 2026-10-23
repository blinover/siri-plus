import Foundation

/// A finished meeting kept in the history.
struct MeetingRecord: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    let startedAt: Date
    let endedAt: Date
    /// Empty until the model or the user names the meeting.
    var title = ""
    var summary = ""
    var participants: [String] = []
    var tasks: [MeetingTask] = []
    let turns: [TranscriptTurn]
    let notes: String

    init(startedAt: Date, endedAt: Date, turns: [TranscriptTurn], notes: String) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.turns = turns
        self.notes = notes
    }

    // Meetings saved by older versions lack the newer keys.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decode(Date.self, forKey: .endedAt)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decode(String.self, forKey: .summary)
        participants = try container.decode([String].self, forKey: .participants)
        tasks = try container.decodeIfPresent([MeetingTask].self, forKey: .tasks) ?? []
        turns = try container.decode([TranscriptTurn].self, forKey: .turns)
        notes = try container.decode(String.self, forKey: .notes)
    }

    var displayTitle: String {
        title.isEmpty
            ? String(localized: "Meeting on \(startedAt.formatted(date: .abbreviated, time: .shortened))")
            : title
    }

    /// Transcript for the summary prompt.
    var promptTranscript: String {
        let text = turns.map { "\($0.speaker.promptLabel): \($0.text)" }.joined(separator: "\n")
        // shortcut: very long meetings send only their last ~100k characters; summarise in chunks if that becomes a problem.
        return String(text.suffix(100_000))
    }

    /// Case- and diacritic-insensitive search over the title, summary, participants, tasks and transcript.
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        let fields = [displayTitle, summary] + participants + tasks.map(\.line) + turns.map(\.text)
        return fields.contains { $0.localizedStandardContains(query) }
    }

    /// The meeting as Markdown, for the clipboard or a file.
    func markdown(includingTranscript: Bool) -> String {
        let duration = Duration.seconds(endedAt.timeIntervalSince(startedAt))
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        var lines = ["# \(displayTitle)", "", "\(startedAt.formatted(date: .long, time: .shortened)) · \(duration)"]
        if !participants.isEmpty {
            lines += ["", "**\(String(localized: "Participants")):** \(participants.joined(separator: ", "))"]
        }
        if !summary.isEmpty {
            lines += ["", "## \(String(localized: "Summary"))", "", summary]
        }
        if !tasks.isEmpty {
            lines += ["", "## \(String(localized: "Tasks"))", ""]
            lines += tasks.map { "- [\($0.isDone ? "x" : " ")] \($0.line)" }
        }
        if includingTranscript {
            lines += ["", "## \(String(localized: "Transcript"))", ""]
            lines += turns.map { "**\($0.speaker.title)** (\($0.startedAt.formatted(date: .omitted, time: .shortened))): \($0.text)\n" }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}

/// An action item from the meeting: who does what by when. Empty owner or due date means unknown.
struct MeetingTask: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var owner = ""
    var text: String
    var due = ""
    var isDone = false

    /// "Owner: text · due" with the unknown parts left out.
    var line: String {
        let head = owner.isEmpty ? text : "\(owner): \(text)"
        return due.isEmpty ? head : "\(head) · \(due)"
    }
}

/// The model's reply to a summary request: "TITLE:", "PARTICIPANTS:", "SUMMARY:" and "TASKS:" sections.
struct MeetingSummary: Equatable, Sendable {
    var title = ""
    var participants: [String] = []
    var summary = ""
    var tasks: [MeetingTask] = []

    /// Text without the expected sections becomes the summary.
    init(parsing reply: String) {
        var summaryLines: [String] = []
        var inTasks = false
        for line in reply.components(separatedBy: .newlines) {
            if let value = Self.value(of: line, after: "TITLE:") {
                title = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"«»“”"))
            } else if let value = Self.value(of: line, after: "PARTICIPANTS:") {
                participants = Self.names(in: value)
            } else if let value = Self.value(of: line, after: "SUMMARY:") {
                inTasks = false
                if !value.isEmpty { summaryLines.append(value) }
            } else if Self.value(of: line, after: "TASKS:") != nil {
                inTasks = true
            } else if inTasks {
                if let task = Self.task(in: line) { tasks.append(task) }
            } else {
                summaryLines.append(line)
            }
        }
        summary = summaryLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Comma-separated names; "—" means none.
    static func names(in text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !Self.isNone($0) }
    }

    /// "- owner | what | due"; a line without the separators is the task text alone.
    private static func task(in line: String) -> MeetingTask? {
        var text = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "• "] where text.hasPrefix(marker) {
            text = String(text.dropFirst(marker.count))
        }
        guard !isNone(text) else { return nil }
        let parts = text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3 else { return MeetingTask(text: text) }
        guard !isNone(parts[1]) else { return nil }
        return MeetingTask(owner: isNone(parts[0]) ? "" : parts[0], text: parts[1], due: isNone(parts[2]) ? "" : parts[2])
    }

    private static func isNone(_ text: String) -> Bool {
        text.isEmpty || text == "—" || text == "-"
    }

    /// Tolerates Markdown emphasis models sometimes add, such as "**TITLE:** …".
    private static func value(of line: String, after key: String) -> String? {
        let cleaned = line.trimmingCharacters(in: CharacterSet(charactersIn: "*#_ \t"))
        guard cleaned.uppercased().hasPrefix(key) else { return nil }
        return cleaned.dropFirst(key.count).trimmingCharacters(in: CharacterSet(charactersIn: "*_ \t"))
    }
}
