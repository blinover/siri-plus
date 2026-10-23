import Combine
import Foundation

/// Finished meetings, stored on this Mac, each with a model-written title and summary.
@MainActor
final class MeetingHistory: ObservableObject {
    /// Newest first.
    @Published private(set) var records: [MeetingRecord] = []
    @Published private(set) var summarizing: Set<UUID> = []
    @Published private(set) var summaryFailures: [UUID: String] = [:]
    @Published var errorMessage: String?

    private let store: MeetingHistoryStore
    private let summaries: any SummaryService
    private let preferences: () -> AssistantPreferences
    /// False when an unreadable file could not be set aside: saving would overwrite it.
    private var canSave = true

    init(store: MeetingHistoryStore, summaries: any SummaryService, preferences: @escaping () -> AssistantPreferences) {
        self.store = store
        self.summaries = summaries
        self.preferences = preferences
        do {
            records = try store.load()
        } catch {
            do {
                let backup = try store.setAside()
                errorMessage = String(localized: "The meeting history could not be read. The file was moved to \(backup.path).")
            } catch {
                canSave = false
                errorMessage = String(localized: "The meeting history could not be read, so new meetings are not saved. File: \(store.url.path)")
            }
        }
        removeExpired()
    }

    func add(_ record: MeetingRecord) {
        records.insert(record, at: 0)
        removeExpired()
        save()
        summarize(record.id)
    }

    /// Deletes meetings older than the retention period set in Settings.
    func removeExpired(now: Date = Date()) {
        let days = preferences().historyRetentionDays
        guard days > 0, let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else { return }
        let expired = records.filter { $0.endedAt < cutoff }.map(\.id)
        guard !expired.isEmpty else { return }
        records.removeAll { expired.contains($0.id) }
        for id in expired { summaryFailures[id] = nil }
        save()
    }

    func rename(_ id: UUID, to title: String) {
        update(id) { $0.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func setParticipants(_ id: UUID, from text: String) {
        update(id) { $0.participants = MeetingSummary.names(in: text) }
    }

    func toggleTask(_ taskID: UUID, in id: UUID) {
        update(id) { record in
            guard let index = record.tasks.firstIndex(where: { $0.id == taskID }) else { return }
            record.tasks[index].isDone.toggle()
        }
    }

    func delete(_ id: UUID) {
        records.removeAll { $0.id == id }
        summaryFailures[id] = nil
        save()
    }

    /// Asks the model for a title, participants, summary and tasks. A title or names the user set are kept;
    /// tasks are replaced, along with their checkmarks.
    func summarize(_ id: UUID) {
        guard let record = records.first(where: { $0.id == id }), !summarizing.contains(id) else { return }
        summarizing.insert(id)
        summaryFailures[id] = nil
        let request = SummaryRequest(transcript: record.promptTranscript, notes: record.notes, selection: preferences().selection)
        Task { [weak self, summaries] in
            var reply = ""
            do {
                for try await text in summaries.summary(for: request) { reply += text }
                let summary = MeetingSummary(parsing: reply)
                self?.update(id) {
                    $0.summary = summary.summary
                    $0.tasks = summary.tasks
                    if $0.title.isEmpty { $0.title = summary.title }
                    if $0.participants.isEmpty { $0.participants = summary.participants }
                }
            } catch {
                self?.summaryFailures[id] = error.localizedDescription
            }
            self?.summarizing.remove(id)
        }
    }

    private func update(_ id: UUID, _ change: (inout MeetingRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        save()
    }

    private func save() {
        guard canSave else { return }
        do {
            try store.save(records)
        } catch {
            errorMessage = String(localized: "The meeting history was not saved. \(error.localizedDescription)")
        }
    }
}
