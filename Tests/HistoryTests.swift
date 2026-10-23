import Foundation
import Testing
@testable import SiriPlusCore

@Suite
struct MeetingSummaryTests {
    @Test func parsesSections() {
        let summary = MeetingSummary(parsing: """
        **TITLE:** «Перенос сервиса в облако»
        PARTICIPANTS: Анна, Олег, —
        SUMMARY:
        - Решили переезжать в ноябре
        - Олег готовит план
        """)
        #expect(summary.title == "Перенос сервиса в облако")
        #expect(summary.participants == ["Анна", "Олег"])
        #expect(summary.summary == "- Решили переезжать в ноябре\n- Олег готовит план")
    }

    @Test func parsesTasks() {
        let summary = MeetingSummary(parsing: """
        TITLE: Планёрка
        SUMMARY:
        - Обсудили переезд
        TASKS:
        - Олег | прислать план | до пятницы
        - — | согласовать бюджет | —
        - написать в чат
        """)
        #expect(summary.summary == "- Обсудили переезд")
        #expect(summary.tasks.map(\.owner) == ["Олег", "", ""])
        #expect(summary.tasks.map(\.text) == ["прислать план", "согласовать бюджет", "написать в чат"])
        #expect(summary.tasks.map(\.due) == ["до пятницы", "", ""])
        #expect(summary.tasks[0].line == "Олег: прислать план · до пятницы")
        #expect(MeetingSummary(parsing: "SUMMARY:\n- Итог\nTASKS:\n—").tasks.isEmpty)
    }

    @Test func freeTextBecomesSummary() {
        let summary = MeetingSummary(parsing: "Обсудили сроки.\nPARTICIPANTS: —")
        #expect(summary.title.isEmpty)
        #expect(summary.participants.isEmpty)
        #expect(summary.summary == "Обсудили сроки.")
    }
}

@Suite @MainActor
struct MeetingHistoryTests {
    private let reply = "TITLE: Миграция\nPARTICIPANTS: Анна\nSUMMARY:\n- Переезд в ноябре"

    @Test func finishedMeetingIsSavedAndSummarized() async throws {
        let (meeting, service, hints) = makeMeeting()
        let store = temporaryStore()
        let history = MeetingHistory(store: store, summaries: hints) { AssistantPreferences() }
        meeting.onFinish = { history.add($0) }
        hints.summaryReply = reply

        meeting.notes = "Проект: миграция"
        await meeting.start()
        service.send(.segment(.init(speaker: .them, text: "мы переезжаем в ноябре", isFinal: true, timestamp: Date())))
        service.send(.segment(.init(speaker: .me, text: "отлично", isFinal: false, timestamp: Date())))
        await meeting.stop()
        try await eventually { history.records.first?.summary.isEmpty == false }

        let record = try #require(history.records.first)
        #expect(record.title == "Миграция")
        #expect(record.participants == ["Анна"])
        #expect(record.turns.map(\.text) == ["мы переезжаем в ноябре", "отлично"])
        #expect(record.turns.allSatisfy { $0.volatileText.isEmpty })
        #expect(hints.summaryRequests.first?.transcript == "Them: мы переезжаем в ноябре\nMe: отлично")
        #expect(hints.summaryRequests.first?.notes == "Проект: миграция")
        #expect(try store.load() == history.records)
    }

    @Test func silentMeetingIsNotSaved() async throws {
        let (meeting, _, hints) = makeMeeting()
        let history = MeetingHistory(store: temporaryStore(), summaries: hints) { AssistantPreferences() }
        meeting.onFinish = { history.add($0) }
        await meeting.start()
        await meeting.stop()
        try await Task.sleep(for: .milliseconds(50))
        #expect(history.records.isEmpty)
    }

    @Test func titleSetByUserSurvivesNewSummary() async throws {
        let hints = ScriptedHints()
        hints.summaryReply = reply
        let store = temporaryStore()
        let history = MeetingHistory(store: store, summaries: hints) { AssistantPreferences() }
        history.add(record())
        try await eventually { history.records[0].summary == "- Переезд в ноябре" && history.summarizing.isEmpty }

        let id = history.records[0].id
        history.rename(id, to: "  Планёрка  ")
        hints.summaryReply = "TITLE: Другое\nSUMMARY:\n- Новое"
        history.summarize(id)
        try await eventually { history.records[0].summary == "- Новое" }

        #expect(history.records[0].title == "Планёрка")
        #expect(try store.load()[0].title == "Планёрка")
    }

    @Test func deletedMeetingIsRemovedFromDisk() throws {
        let store = temporaryStore()
        let history = MeetingHistory(store: store, summaries: ScriptedHints()) { AssistantPreferences() }
        history.add(record())
        history.delete(history.records[0].id)
        #expect(try store.load().isEmpty)
    }

    @Test func unreadableFileIsSetAsideNotOverwritten() throws {
        let store = temporaryStore()
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url)

        let history = MeetingHistory(store: store, summaries: ScriptedHints()) { AssistantPreferences() }
        #expect(history.records.isEmpty)
        #expect(history.errorMessage != nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path)
        #expect(files.contains { $0.hasPrefix("meetings-unreadable-") })
    }

    @Test func toggledTaskIsSaved() async throws {
        let hints = ScriptedHints()
        hints.summaryReply = "SUMMARY:\n- Итог\nTASKS:\n- Олег | план | пятница"
        let store = temporaryStore()
        let history = MeetingHistory(store: store, summaries: hints) { AssistantPreferences() }
        history.add(record())
        try await eventually { history.records[0].tasks.count == 1 }

        history.toggleTask(history.records[0].tasks[0].id, in: history.records[0].id)
        #expect(try store.load()[0].tasks[0].isDone)
    }

    @Test func oldMeetingsKeepThemselvesAndExpiredOnesAreDeleted() throws {
        let store = temporaryStore()
        var old = record(endedDaysAgo: 40)
        old.title = "Старый"
        try store.save([record(endedDaysAgo: 2), old])

        var preferences = AssistantPreferences()
        let history = MeetingHistory(store: store, summaries: ScriptedHints()) { preferences }
        #expect(history.records.count == 2)

        preferences.historyRetentionDays = 30
        history.removeExpired()
        #expect(history.records.count == 1)
        #expect(try store.load().map(\.title) == [""])
    }

    @Test func meetingsSavedWithoutTasksStillLoad() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","startedAt":0,"endedAt":60,"title":"Созвон","summary":"","participants":[],
          "turns":[],"notes":""}]
        """
        let records = try JSONDecoder().decode([MeetingRecord].self, from: Data(json.utf8))
        #expect(records.first?.title == "Созвон")
        #expect(records.first?.tasks == [])
    }

    @Test func searchLooksEverywhereIgnoringCase() {
        var meeting = record()
        meeting.title = "Планёрка"
        meeting.participants = ["Анна"]
        meeting.tasks = [MeetingTask(owner: "Олег", text: "бюджет")]
        for query in ["планерка", "АННА", "бюджет", "ПРИВЕТ", ""] {
            #expect(meeting.matches(query), "\(query)")
        }
        #expect(!meeting.matches("kubernetes"))
    }

    @Test func markdownHasSectionsAndOptionalTranscript() {
        var meeting = record()
        meeting.title = "Планёрка"
        meeting.summary = "- Итог"
        meeting.tasks = [MeetingTask(owner: "Олег", text: "план", isDone: true)]
        let short = meeting.markdown(includingTranscript: false)
        #expect(short.hasPrefix("# Планёрка\n"))
        #expect(short.contains("- Итог"))
        #expect(short.contains("- [x] Олег: план"))
        #expect(!short.contains("привет"))
        #expect(meeting.markdown(includingTranscript: true).contains("привет"))
    }

    private func record(endedDaysAgo days: Double = 0) -> MeetingRecord {
        let end = Date().addingTimeInterval(-days * 86_400)
        return MeetingRecord(
            startedAt: end.addingTimeInterval(-600),
            endedAt: end,
            turns: [TranscriptTurn(id: UUID(), speaker: .them, startedAt: end, updatedAt: end, finalText: "привет", volatileText: "")],
            notes: ""
        )
    }

    private func temporaryStore() -> MeetingHistoryStore {
        MeetingHistoryStore(url: FileManager.default.temporaryDirectory.appending(path: "siriplus-\(UUID().uuidString)/meetings.json"))
    }

    private func makeMeeting() -> (MeetingModel, FakeMeetingService, ScriptedHints) {
        let service = FakeMeetingService()
        let hints = ScriptedHints()
        let meeting = MeetingModel(service: service, hintService: hints, timing: .init(questionDelay: .milliseconds(10))) {
            AssistantPreferences(hintMode: .manual)
        }
        return (meeting, service, hints)
    }
}
