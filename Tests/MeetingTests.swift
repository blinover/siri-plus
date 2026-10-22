import Foundation
import Testing
@testable import SiriPlusCore

@Suite
struct TranscriptTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func segment(_ speaker: Speaker, _ text: String, final: Bool, at seconds: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(speaker: speaker, text: text, isFinal: final, timestamp: start.addingTimeInterval(seconds))
    }

    @Test func volatileResultsAreReplacedAndFinalisedIntoOneTurn() {
        var transcript = Transcript()
        transcript.apply(segment(.them, "добрый", final: false, at: 0))
        transcript.apply(segment(.them, "добрый день", final: false, at: 0.5))
        transcript.apply(segment(.them, "добрый день", final: true, at: 1))
        transcript.apply(segment(.them, "как дела", final: false, at: 1.5))

        #expect(transcript.turns.count == 1)
        #expect(transcript.turns[0].finalText == "добрый день")
        #expect(transcript.turns[0].text == "добрый день как дела")
        #expect(transcript.finalWordCount == 2)
    }

    @Test func speakersAndPausesStartNewTurns() {
        var transcript = Transcript()
        transcript.apply(segment(.them, "вопрос", final: true, at: 0))
        transcript.apply(segment(.me, "ответ", final: true, at: 1))
        transcript.apply(segment(.me, "после паузы", final: true, at: 30))

        #expect(transcript.turns.map(\.speaker) == [.them, .me, .me])
        #expect(transcript.recentText(characterLimit: 1_000) == "Собеседник: вопрос\nЯ: ответ\nЯ: после паузы")
        #expect(transcript.recentText(characterLimit: 20) == "Я: после паузы")
    }

    @Test func interleavedSpeechKeepsUpdatingTheOpenTurn() {
        var transcript = Transcript()
        transcript.apply(segment(.them, "мы считаем", final: false, at: 0))
        transcript.apply(segment(.me, "угу", final: true, at: 0.5))
        transcript.apply(segment(.them, "мы считаем что", final: true, at: 1))

        #expect(transcript.turns.count == 2)
        #expect(transcript.turns[0].finalText == "мы считаем что")
    }

    @Test func emptyVolatileResultRemovesEmptyTurn() {
        var transcript = Transcript()
        transcript.apply(segment(.them, "э", final: false, at: 0))
        transcript.apply(segment(.them, "", final: false, at: 0.2))
        #expect(transcript.isEmpty)
    }
}

@Suite
struct QuestionDetectorTests {
    @Test(arguments: [
        "скажите пожалуйста какой у вас опыт работы с kubernetes",
        "как вы оцениваете риски",
        "а сколько это будет стоить",
        "есть ли у вас опыт внедрения",
        "расскажите про архитектуру",
        "почему выбрали postgres",
        "Это готово?",
        "what is your timeline",
    ])
    func detectsQuestions(_ text: String) {
        #expect(QuestionDetector.isLikelyQuestion(text))
    }

    @Test(arguments: [
        "хорошо давайте дальше",
        "что касается сроков мы успеваем",
        "мы обсуждаем перенос сервиса в облако",
        "я думаю что это хорошая идея",
        "да",
    ])
    func ignoresStatements(_ text: String) {
        #expect(!QuestionDetector.isLikelyQuestion(text))
    }
}

@Suite
struct ClaudeProtocolTests {
    private func events(_ lines: [String]) throws -> [ClaudeStreamDecoder.Event] {
        var decoder = ClaudeStreamDecoder()
        var result: [ClaudeStreamDecoder.Event] = []
        for line in lines {
            if let event = try decoder.consume(line: line) { result.append(event) }
        }
        return result
    }

    @Test func decodesTextAndIgnoresOtherBlocks() throws {
        let decoded = try events([
            "event: message_start", #"data: {"type":"message_start","message":{"id":"msg_1"}}"#, "",
            "event: content_block_start", #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#, "",
            "event: content_block_delta", #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"При"}}"#, "",
            "event: content_block_delta", #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"вет"}}"#, "",
            "event: ping", #"data: {"type":"ping"}"#, "",
            "event: message_delta", #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#, "",
            "event: message_stop", #"data: {"type":"message_stop"}"#, "",
        ])
        #expect(decoded == [.text("При"), .text("вет"), .finished])
    }

    @Test func refusalAndErrorEventsThrow() {
        #expect(throws: ClaudeError.refused) {
            try events([#"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#, ""])
        }
        #expect(throws: ClaudeError.api(type: "overloaded_error", message: "Overloaded")) {
            try events([#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, ""])
        }
    }

    @Test func hintRequestUsesCachedSystemPromptAndFallback() throws {
        let opus = try requestJSON(model: .opus)
        #expect(opus["model"] as? String == "claude-opus-5-5")
        #expect(opus["stream"] as? Bool == true)
        #expect(opus["fallbacks"] as? String == "default")
        #expect((opus["output_config"] as? [String: Any])?["effort"] as? String == "low")
        #expect(opus["temperature"] == nil)
        let system = try #require(opus["system"] as? [[String: Any]])
        #expect((system[0]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        #expect((system[0]["text"] as? String)?.contains("Цена: 100 ₽") == true)

        let haiku = try requestJSON(model: .haiku)
        #expect(haiku["fallbacks"] == nil)
    }

    @Test func hintPromptCarriesTranscriptQuestionAndPreviousHints() {
        let prompt = ClaudeAssistantService.hintUserPrompt(HintRequest(
            trigger: .question("сколько стоит"),
            transcript: "Собеседник: сколько стоит",
            notes: "",
            previousHints: ["Назови\nцену"],
            model: .opus
        ))
        #expect(prompt.contains("<transcript>\nСобеседник: сколько стоит\n</transcript>"))
        #expect(prompt.contains("- Назови цену"))
        #expect(prompt.contains("«сколько стоит»"))
    }

    private func requestJSON(model: ClaudeModel) throws -> [String: Any] {
        let body = ClaudeMessagesRequest(
            model: model.rawValue,
            maxTokens: 4_000,
            system: [.text(ClaudeAssistantService.hintSystemPrompt(notes: "Цена: 100 ₽"), cached: true)],
            messages: [.init(role: "user", content: [.text("привет")])],
            outputConfig: .init(effort: "low"),
            fallbacks: model.supportsDefaultFallback ? "default" : nil
        )
        let data = try JSONEncoder().encode(body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@Suite @MainActor
struct MeetingModelTests {
    @Test func questionFromOtherSideTriggersHint() async throws {
        let (meeting, service, hints) = makeMeeting()
        await meeting.start()
        #expect(meeting.phase == .running)
        #expect(service.configuration?.capturesMicrophone == true)

        service.send(.segment(.init(speaker: .them, text: "какой у вас опыт", isFinal: false, timestamp: Date())))
        service.send(.segment(.init(speaker: .them, text: "какой у вас опыт с kubernetes", isFinal: true, timestamp: Date())))
        try await eventually { meeting.hints.first?.isStreaming == false }

        let request = try #require(hints.requests.first)
        #expect(request.trigger == .question("какой у вас опыт с kubernetes"))
        #expect(request.transcript == "Собеседник: какой у вас опыт с kubernetes")
        #expect(meeting.latestHint?.text == "Скажи про три года опыта.")
        await meeting.stop()
        #expect(service.stopped)
    }

    @Test func ownSpeechAndStatementsDoNotTriggerHints() async throws {
        let (meeting, service, hints) = makeMeeting()
        await meeting.start()
        service.send(.segment(.init(speaker: .me, text: "как вы оцениваете риски", isFinal: true, timestamp: Date())))
        service.send(.segment(.init(speaker: .them, text: "хорошо давайте дальше", isFinal: true, timestamp: Date())))
        try await Task.sleep(for: .milliseconds(80))
        #expect(hints.requests.isEmpty)
        await meeting.stop()
    }

    @Test func noHintAnswerIsDropped() async throws {
        let (meeting, service, hints) = makeMeeting()
        hints.reply = "—"
        await meeting.start()
        service.send(.segment(.init(speaker: .them, text: "почему так", isFinal: true, timestamp: Date())))
        try await eventually { hints.requests.count == 1 && !meeting.isHinting }
        #expect(meeting.hints.isEmpty)
        #expect(meeting.latestHint == nil)
        await meeting.stop()
    }

    @Test func manualModeWaitsForExplicitRequest() async throws {
        let (meeting, service, hints) = makeMeeting(mode: .manual)
        await meeting.start()
        service.send(.segment(.init(speaker: .them, text: "сколько это стоит", isFinal: true, timestamp: Date())))
        try await Task.sleep(for: .milliseconds(80))
        #expect(hints.requests.isEmpty)

        meeting.askNow()
        try await eventually { hints.requests.count == 1 }
        #expect(hints.requests.first?.trigger == .manual)
        await meeting.stop()
    }

    @Test func topicHintAfterEnoughSpeech() async throws {
        var timing = MeetingModel.Timing(questionDelay: .milliseconds(10))
        timing.topicWords = 5
        timing.topicInterval = 0
        let (meeting, service, hints) = makeMeeting(mode: .questionsAndTopic, timing: timing)
        meeting.notes = "Проект: миграция в облако"
        await meeting.start()
        service.send(.segment(.init(speaker: .them, text: "мы переносим сервис в облако на этой неделе", isFinal: true, timestamp: Date())))
        try await eventually { hints.requests.count == 1 }
        let request = try #require(hints.requests.first)
        #expect(request.trigger == .topic)
        #expect(request.notes == "Проект: миграция в облако")
        await meeting.stop()
    }

    @Test func failedStartShowsErrorAndStaysIdle() async {
        let (meeting, service, _) = makeMeeting()
        service.startError = MeetingError.microphoneDenied
        await meeting.start()
        #expect(meeting.phase == .idle)
        #expect(meeting.errorMessage?.contains("микрофон") == true)
    }

    @Test func endedStreamStopsMeeting() async throws {
        let (meeting, service, _) = makeMeeting()
        await meeting.start()
        service.fail(MeetingError.noDisplay)
        try await eventually { meeting.phase == .idle }
        #expect(meeting.errorMessage?.contains("Запись остановлена") == true)
    }

    private func makeMeeting(
        mode: HintMode = .questions,
        timing: MeetingModel.Timing = MeetingModel.Timing(questionDelay: .milliseconds(10))
    ) -> (MeetingModel, FakeMeetingService, ScriptedHints) {
        let service = FakeMeetingService()
        let hints = ScriptedHints()
        let meeting = MeetingModel(service: service, hintService: hints, timing: timing) {
            AssistantPreferences(hintMode: mode)
        }
        return (meeting, service, hints)
    }
}

@MainActor
final class FakeMeetingService: MeetingService {
    private var continuation: AsyncThrowingStream<MeetingEvent, Error>.Continuation?
    private(set) var configuration: MeetingConfiguration?
    private(set) var stopped = false
    var startError: Error?

    func start(_ configuration: MeetingConfiguration) async throws -> AsyncThrowingStream<MeetingEvent, Error> {
        if let startError { throw startError }
        self.configuration = configuration
        let (stream, continuation) = AsyncThrowingStream<MeetingEvent, Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    func stop() async {
        stopped = true
        continuation?.finish()
        continuation = nil
    }

    func send(_ event: MeetingEvent) {
        continuation?.yield(event)
    }

    func fail(_ error: Error) {
        continuation?.finish(throwing: error)
    }
}

final class ScriptedHints: HintService, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HintRequest] = []
    private var scripted = "Скажи про три года опыта."

    var requests: [HintRequest] { lock.withLock { recorded } }
    var reply: String {
        get { lock.withLock { scripted } }
        set { lock.withLock { scripted = newValue } }
    }

    func hint(for request: HintRequest) -> AsyncThrowingStream<String, Error> {
        let reply = lock.withLock {
            recorded.append(request)
            return scripted
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(reply)
            continuation.finish()
        }
    }
}
