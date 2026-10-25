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
        #expect(transcript.recentText(characterLimit: 1_000) == "Them: вопрос\nMe: ответ\nMe: после паузы")
        #expect(transcript.recentText(characterLimit: 20) == "Me: после паузы")
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
        #expect(request.transcript == "Them: какой у вас опыт с kubernetes")
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
        // "Hint now" needs a transcript; under load the segment can arrive after a fixed delay.
        try await eventually { !meeting.transcript.isEmpty }
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

    @Test func namesAndTermsFromNotesGoToRecognition() async {
        let (meeting, service, _) = makeMeeting()
        meeting.notes = "Проект: перенос в Yandex Cloud, отвечает Анна Петрова. Кластер k8s, сроки Q4, бюджет 5 млн. Yandex снова."
        await meeting.start()
        #expect(service.configuration?.contextualStrings == ["Проект", "Yandex", "Cloud", "Анна", "Петрова", "Кластер", "k8s", "Q4"])
        await meeting.stop()
        #expect(MeetingConfiguration.contextualStrings(from: "один Два три Четыре", limit: 1) == ["Два"])
    }

    @Test func failedStartShowsErrorAndStaysIdle() async {
        let (meeting, service, _) = makeMeeting()
        service.startError = MeetingError.microphoneDenied
        await meeting.start()
        #expect(meeting.phase == .idle)
        #expect(meeting.errorMessage?.contains("microphone") == true)
    }

    @Test func endedStreamStopsMeeting() async throws {
        let (meeting, service, _) = makeMeeting()
        await meeting.start()
        service.fail(MeetingError.noDisplay)
        try await eventually { meeting.phase == .idle }
        #expect(meeting.errorMessage?.contains("Listening stopped") == true)
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

final class ScriptedHints: HintService, SummaryService, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HintRequest] = []
    private var scripted = "Скажи про три года опыта."
    private var recordedSummaries: [SummaryRequest] = []
    private var scriptedSummary = ""

    var requests: [HintRequest] { lock.withLock { recorded } }
    var reply: String {
        get { lock.withLock { scripted } }
        set { lock.withLock { scripted = newValue } }
    }
    var summaryRequests: [SummaryRequest] { lock.withLock { recordedSummaries } }
    var summaryReply: String {
        get { lock.withLock { scriptedSummary } }
        set { lock.withLock { scriptedSummary = newValue } }
    }

    func summary(for request: SummaryRequest) -> AsyncThrowingStream<String, Error> {
        let reply = lock.withLock {
            recordedSummaries.append(request)
            return scriptedSummary
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(reply)
            continuation.finish()
        }
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

@Suite
struct DictationTextTests {
    @Test func volatileWordsAreReplacedUntilFinal() {
        var text = DictationText()
        text.apply("открой", isFinal: false)
        text.apply("открой календарь", isFinal: false)
        #expect(text.text == "открой календарь")
        text.apply("открой календарь", isFinal: true)
        text.apply("на завтра", isFinal: false)
        #expect(text.final == "открой календарь")
        #expect(text.text == "открой календарь на завтра")
        text.apply("", isFinal: false)
        #expect(text.text == "открой календарь")
        #expect(!text.isEmpty)
    }
}

@Suite
struct DictationCandidateTests {
    @Test func picksTheLanguageWithHigherConfidence() {
        var english = DictationCandidate(), russian = DictationCandidate()
        english.apply("Critical in stretching", confidence: [0.5, 0.6, 0.7], isFinal: false)
        russian.apply("Открой календарь", confidence: [0.99, 0.98], isFinal: false)
        #expect(DictationCandidate.best(of: [english, russian])?.text.text == "Открой календарь")

        russian.apply("Открой календарь", confidence: [0.99, 0.98], isFinal: true)
        russian.apply("на завтра", confidence: [0.97], isFinal: false)
        #expect(DictationCandidate.best(of: [english, russian])?.text.text == "Открой календарь на завтра")
    }

    @Test func firstLanguageWinsWithoutConfidence() {
        var first = DictationCandidate(), second = DictationCandidate()
        first.apply("one", confidence: [], isFinal: false)
        second.apply("два", confidence: [], isFinal: false)
        #expect(DictationCandidate.best(of: [first, second])?.text.text == "one")
    }

    @Test func shownLanguageChangesOnlyWithAClearLead() {
        var english = DictationCandidate(), russian = DictationCandidate()
        english.apply("Previous", confidence: [0.95], isFinal: false)
        russian.apply("Привет", confidence: [0.93], isFinal: false)
        #expect(DictationCandidate.leader(of: [english, russian], current: nil) == 0)
        russian.apply("Привет", confidence: [0.97], isFinal: false)
        #expect(DictationCandidate.leader(of: [english, russian], current: 0) == 0)
        russian.apply("Привет", confidence: [0.99, 0.99], isFinal: false)
        english.apply("Previous", confidence: [0.6, 0.5], isFinal: false)
        #expect(DictationCandidate.leader(of: [english, russian], current: 0) == 1)
    }

    @Test @MainActor func chosenLanguageOverridesSystemLanguages() {
        #expect(AssistantPreferences(transcriptionLocale: "ru-RU").speechLocales.map(\.identifier) == ["ru-RU"])
        let automatic = AssistantPreferences().speechLocales
        #expect(!automatic.isEmpty && automatic.count <= SpeechLanguages.maximum)
    }

    @Test func keyboardLayoutsAddLanguages() {
        let locales = SpeechLanguages.candidates(preferred: ["en-US", "en-GB"], keyboard: ["en", "ru", "uk", "de"])
        #expect(locales.map(\.identifier) == ["en-US", "ru", "uk"])
        #expect(SpeechLanguages.candidates(preferred: [], keyboard: []).map(\.identifier) == ["en-US"])
    }
}

@Suite
struct LanguageLockTests {
    @Test func keepsTheClearlyMoreConfidentLanguage() {
        var lock = LanguageLock(count: 2)
        #expect(lock.apply(0, text: "Add", confidence: [0.3], isFinal: false) == [.segment("Add", isFinal: false)])
        #expect(lock.apply(1, text: "Открой", confidence: [0.9], isFinal: false) == [.segment("Открой", isFinal: false)])
        _ = lock.apply(0, text: "Nam after I need", confidence: [0.3, 0.4, 0.2, 0.3], isFinal: true)
        let outputs = lock.apply(1, text: "Напомни мне завтра", confidence: [0.95, 0.97, 0.96], isFinal: true)
        #expect(outputs == [.locked(1), .segment("Напомни мне завтра", isFinal: true), .segment("", isFinal: false)])
        #expect(lock.chosen == 1)
        #expect(lock.apply(0, text: "my Chitra", confidence: [0.2], isFinal: true).isEmpty)
        #expect(lock.apply(1, text: "позвонить маме", confidence: [0.9], isFinal: true) == [.segment("позвонить маме", isFinal: true)])
    }

    @Test func waitsForEveryLanguageToRateWords() {
        var lock = LanguageLock(count: 2)
        _ = lock.apply(1, text: "Да привет открой", confidence: [], isFinal: false)
        _ = lock.apply(0, text: "The previous is after", confidence: [0.61, 0.89, 0.6, 0.7], isFinal: true)
        #expect(lock.chosen == nil)
        _ = lock.apply(1, text: "Да привет открой календарь", confidence: [0.94, 0.98, 0.99, 0.98], isFinal: true)
        #expect(lock.chosen == 1)
    }

    @Test func waitsWhileLanguagesAreClose() {
        var lock = LanguageLock(count: 2)
        _ = lock.apply(0, text: "one two three", confidence: [0.9, 0.9, 0.9], isFinal: true)
        _ = lock.apply(1, text: "раз два три", confidence: [0.88, 0.88, 0.88], isFinal: true)
        #expect(lock.chosen == nil)
        let words = Array(repeating: "word", count: 9).joined(separator: " ")
        _ = lock.apply(0, text: words, confidence: Array(repeating: 0.9, count: 9), isFinal: true)
        #expect(lock.chosen == 0)
    }

    @Test func shortRepliesAreKeptWhenListeningEnds() {
        var lock = LanguageLock(count: 2)
        _ = lock.apply(0, text: "Previous", confidence: [0.5], isFinal: true)
        _ = lock.apply(1, text: "Привет", confidence: [0.96], isFinal: true)
        #expect(lock.chosen == nil)
        #expect(lock.finish() == [.segment("Привет", isFinal: true)])
        #expect(lock.finish().isEmpty)
    }

    @Test func singleLanguageNeedsNoChoice() {
        var lock = LanguageLock(count: 1)
        #expect(lock.chosen == 0)
        #expect(lock.apply(0, text: "Hello", confidence: [], isFinal: true) == [.segment("Hello", isFinal: true)])
    }
}
