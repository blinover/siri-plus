import Combine
import Foundation

struct MeetingHint: Identifiable, Equatable, Sendable {
    enum Kind: Sendable {
        case question
        case topic
        case manual

        var title: String {
            switch self {
            case .question: String(localized: "Answer to a question")
            case .topic: String(localized: "On the topic")
            case .manual: String(localized: "On request")
            }
        }
    }

    let id: UUID
    let kind: Kind
    /// The question that triggered the hint, if any.
    let question: String?
    let createdAt: Date
    var text = ""
    var isStreaming = true
    var failure: String?

    /// The model answers "—" when no hint is needed.
    var isEmptyAnswer: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return trimmed.isEmpty
    }
}

@MainActor
final class MeetingModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case running
    }

    struct Timing {
        /// Wait after the other side stops talking before treating the text as a finished question.
        var questionDelay: Duration = .milliseconds(1_200)
        /// New words needed before an automatic topic hint.
        var topicWords = 70
        /// Minimum seconds between automatic topic hints.
        var topicInterval: TimeInterval = 45
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = Transcript()
    @Published private(set) var hints: [MeetingHint] = []
    @Published private(set) var levels: [Speaker: Float] = [:]
    @Published private(set) var sources: [MeetingAudioSource] = [.system]
    @Published var selectedSourceID = MeetingAudioSource.system.id
    @Published var notes = ""
    @Published var errorMessage: String?
    /// Receives every finished meeting that has a transcript.
    var onFinish: ((MeetingRecord) -> Void)?

    private let service: any MeetingService
    private let hintService: any HintService
    private let preferences: () -> AssistantPreferences
    private let timing: Timing
    private var eventsTask: Task<Void, Never>?
    private var questionTask: Task<Void, Never>?
    private var hintTask: Task<Void, Never>?
    private var activeHintID: UUID?
    /// Characters of each turn's final text already answered with a question hint.
    private var answeredLength: [UUID: Int] = [:]
    private var wordsAtLastHint = 0
    private var lastHintAt = Date.distantPast

    init(
        service: any MeetingService,
        hintService: any HintService,
        timing: Timing = Timing(),
        preferences: @escaping () -> AssistantPreferences
    ) {
        self.service = service
        self.hintService = hintService
        self.timing = timing
        self.preferences = preferences
    }

    var isRunning: Bool { phase == .running }
    var latestHint: MeetingHint? { hints.last { !$0.isEmptyAnswer || $0.failure != nil } }
    var isHinting: Bool { activeHintID != nil }

    func refreshSources() {
        sources = MeetingAudioSource.available()
        // Follow the running call app unless the user picked another app that is still running.
        if selectedSourceID == MeetingAudioSource.system.id || !sources.contains(where: { $0.id == selectedSourceID }) {
            selectedSourceID = MeetingAudioSource.preferred(in: sources).id
        }
    }

    func start() async {
        guard phase == .idle else { return }
        let settings = preferences()
        let source = sources.first { $0.id == selectedSourceID } ?? .system
        phase = .starting
        errorMessage = nil
        transcript = Transcript()
        hints = []
        levels = [:]
        answeredLength = [:]
        wordsAtLastHint = 0
        lastHintAt = Date()
        let startedAt = Date()

        do {
            let events = try await service.start(MeetingConfiguration(
                source: source,
                locale: settings.speechLocale,
                capturesMicrophone: settings.capturesMicrophone,
                contextualStrings: MeetingConfiguration.contextualStrings(from: notes)
            ))
            guard phase == .starting else {
                await service.stop()
                return
            }
            phase = .running
            eventsTask = Task { [weak self] in
                do {
                    for try await event in events {
                        self?.handle(event)
                    }
                } catch {
                    self?.errorMessage = String(localized: "Listening stopped: \(error.localizedDescription)")
                }
                await self?.stop()
                // The stream ends after stopping flushed the last recognised text, so the transcript is complete here.
                self?.archive(startedAt: startedAt)
            }
        } catch {
            phase = .idle
            errorMessage = error.localizedDescription
        }
    }

    func stop() async {
        guard phase != .idle else { return }
        phase = .idle
        questionTask?.cancel()
        questionTask = nil
        levels = [:]
        await service.stop()
        eventsTask = nil
    }

    /// Requests a hint right now, e.g. from the global shortcut.
    func askNow() {
        guard !transcript.isEmpty else { return }
        requestHint(.manual)
    }

    func clear() {
        guard phase == .idle else { return }
        cancelHint()
        transcript = Transcript()
        hints = []
        answeredLength = [:]
    }

    var transcriptText: String { transcript.recentText(characterLimit: .max, label: \.title) }

    private func archive(startedAt: Date) {
        // A meeting started again before the old stream ended has already replaced the transcript.
        guard phase == .idle, !transcript.isEmpty else { return }
        let turns = transcript.turns.map { turn in
            var turn = turn
            turn.finalText = turn.text
            turn.volatileText = ""
            return turn
        }
        onFinish?(MeetingRecord(startedAt: startedAt, endedAt: Date(), turns: turns, notes: notes))
    }

    private func handle(_ event: MeetingEvent) {
        switch event {
        case .level(let speaker, let level):
            levels[speaker] = level
        case .segment(let segment):
            guard let turn = transcript.apply(segment), segment.isFinal else { return }
            let mode = preferences().hintMode
            if segment.speaker == .them, mode != .manual {
                scheduleQuestionCheck(turnID: turn.id, chunk: segment.text)
            }
            if mode == .questionsAndTopic {
                considerTopicHint()
            }
        }
    }

    private func scheduleQuestionCheck(turnID: UUID, chunk: String) {
        questionTask?.cancel()
        questionTask = Task { [weak self, delay = timing.questionDelay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.checkForQuestion(turnID: turnID, chunk: chunk)
        }
    }

    private func checkForQuestion(turnID: UUID, chunk: String) {
        // Still speaking: the next final result reschedules the check.
        guard let turn = transcript.turns.first(where: { $0.id == turnID }), turn.volatileText.isEmpty else { return }
        let answered = answeredLength[turnID] ?? 0
        let unanswered = String(turn.finalText.dropFirst(answered)).trimmingCharacters(in: .whitespaces)
        guard !unanswered.isEmpty,
              QuestionDetector.isLikelyQuestion(chunk) || QuestionDetector.isLikelyQuestion(unanswered) else { return }
        answeredLength[turnID] = turn.finalText.count
        let words = unanswered.split(separator: " ")
        requestHint(.question(words.suffix(40).joined(separator: " ")))
    }

    private func considerTopicHint() {
        guard activeHintID == nil,
              transcript.finalWordCount - wordsAtLastHint >= timing.topicWords,
              Date().timeIntervalSince(lastHintAt) >= timing.topicInterval else { return }
        requestHint(.topic)
    }

    private func requestHint(_ trigger: HintRequest.Trigger) {
        let kind: MeetingHint.Kind
        let question: String?
        switch trigger {
        case .question(let text): (kind, question) = (.question, text)
        case .topic: (kind, question) = (.topic, nil)
        case .manual: (kind, question) = (.manual, nil)
        }
        // A newer question or an explicit request replaces the hint being written.
        cancelHint()

        let settings = preferences()
        let request = HintRequest(
            trigger: trigger,
            transcript: transcript.recentText(characterLimit: 6_000),
            notes: notes,
            previousHints: hints.filter { !$0.isEmptyAnswer && $0.failure == nil }.suffix(3).map(\.text),
            selection: settings.selection
        )
        let hint = MeetingHint(id: UUID(), kind: kind, question: question, createdAt: Date())
        hints.append(hint)
        activeHintID = hint.id
        wordsAtLastHint = transcript.finalWordCount
        lastHintAt = Date()

        hintTask = Task { [weak self, hintService] in
            do {
                for try await text in hintService.hint(for: request) {
                    self?.updateHint(hint.id) { $0.text += text }
                }
                self?.finishHint(hint.id, failure: nil)
            } catch is CancellationError {
                self?.finishHint(hint.id, failure: nil)
            } catch {
                self?.finishHint(hint.id, failure: error.localizedDescription)
            }
        }
    }

    private func cancelHint() {
        hintTask?.cancel()
        hintTask = nil
        if let activeHintID { finishHint(activeHintID, failure: nil) }
    }

    private func updateHint(_ id: UUID, _ change: (inout MeetingHint) -> Void) {
        guard let index = hints.firstIndex(where: { $0.id == id }) else { return }
        change(&hints[index])
    }

    private func finishHint(_ id: UUID, failure: String?) {
        if activeHintID == id { activeHintID = nil }
        guard let index = hints.firstIndex(where: { $0.id == id }) else { return }
        hints[index].isStreaming = false
        hints[index].failure = failure
        // Drop "no hint needed" answers and hints cancelled before any text arrived.
        if failure == nil, hints[index].isEmptyAnswer {
            hints.remove(at: index)
        }
    }
}
