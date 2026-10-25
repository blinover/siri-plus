import AVFoundation
import Combine
import Speech

/// Live dictation text: fixed words plus the part still being recognized.
struct DictationText: Equatable, Sendable {
    private(set) var final = ""
    private(set) var volatile = ""

    var text: String { Transcript.join(final, volatile) }
    var isEmpty: Bool { text.isEmpty }

    mutating func apply(_ text: String, isFinal: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            final = Transcript.join(final, trimmed)
            volatile = ""
        } else {
            volatile = trimmed
        }
    }
}

/// One language's reading of the same speech, with the recognizer's confidence in it.
struct DictationCandidate: Equatable, Sendable {
    var text = DictationText()
    private var finalConfidence: [Double] = []
    private var volatileConfidence: [Double] = []

    /// Whether the recognizer has rated any words yet. It rates only fixed words, not those still being recognized.
    var isRated: Bool { !finalConfidence.isEmpty || !volatileConfidence.isEmpty }

    /// Mean word confidence so far; a model listening to another language scores far lower.
    var score: Double {
        let all = finalConfidence + volatileConfidence
        return all.isEmpty ? 0 : all.reduce(0, +) / Double(all.count)
    }

    mutating func apply(_ text: String, confidence: [Double], isFinal: Bool) {
        self.text.apply(text, isFinal: isFinal)
        if isFinal {
            finalConfidence += confidence
            volatileConfidence = []
        } else {
            volatileConfidence = confidence
        }
    }

    /// The candidate the user most likely spoke: the highest confidence, the first language on a tie.
    static func best(of candidates: [DictationCandidate]) -> DictationCandidate? {
        bestIndex(of: candidates).map { candidates[$0] }
    }

    static func bestIndex(of candidates: [DictationCandidate]) -> Int? {
        candidates.indices.max { lhs, rhs in
            candidates[lhs].score == candidates[rhs].score ? lhs > rhs : candidates[lhs].score < candidates[rhs].score
        }
    }

    /// The candidate to show: the `current` one stays until another is more confident by `margin`,
    /// so the text does not jump between languages on every word.
    static func leader(of candidates: [DictationCandidate], current: Int?, margin: Double = 0.05) -> Int? {
        guard let best = bestIndex(of: candidates) else { return nil }
        guard let current, candidates.indices.contains(current) else { return best }
        return candidates[best].score > candidates[current].score + margin ? best : current
    }
}

/// Siri-style voice commands: listens to the microphone, recognizes speech on this Mac,
/// and hands the text over when the user stops talking.
@MainActor
final class VoiceInput: ObservableObject {
    struct Timing {
        /// Silence after speech that ends the command.
        var silence: TimeInterval = 1.5
        /// Listening stops without a word after this long.
        var noSpeech: TimeInterval = 10
        var maximum: TimeInterval = 60
    }

    @Published private(set) var isListening = false
    /// The most likely reading so far.
    @Published private(set) var dictation = DictationText()
    @Published var errorMessage: String?

    private let timing: Timing
    private var engine: AVAudioEngine?
    private var channels: [ChannelTranscriber] = []
    private var candidates: [DictationCandidate] = []
    private var leader: Int?
    private var results: [Task<Void, Never>] = []
    private var watchdog: Task<Void, Never>?
    private var lastChange = Date()
    private var startedAt = Date()
    private var onFinish: ((String) -> Void)?

    init(timing: Timing = Timing()) {
        self.timing = timing
    }

    /// Starts listening in every given language at once; `onFinish` receives the best reading
    /// when the user falls silent.
    func start(locales: [Locale], onFinish: @escaping (String) -> Void) async {
        guard !isListening else { return }
        errorMessage = nil
        dictation = DictationText()
        self.onFinish = onFinish
        isListening = true
        do {
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw MeetingError.microphoneDenied }
            let resolved = try await ChannelTranscriber.prepare(locales: locales)
            var channels: [ChannelTranscriber] = []
            for locale in resolved {
                let channel = try await ChannelTranscriber(speaker: .me, locale: locale)
                try await channel.start(contextualStrings: [])
                channels.append(channel)
            }
            guard isListening else {
                for channel in channels { await channel.finish() }
                return
            }
            self.channels = channels
            candidates = Array(repeating: DictationCandidate(), count: channels.count)
            leader = nil

            let engine = AVAudioEngine()
            Self.feed(engine.inputNode, to: channels)
            try engine.start()
            self.engine = engine

            startedAt = Date()
            lastChange = Date()
            results = channels.enumerated().map { index, channel in
                Task { [weak self] in
                    do {
                        for try await result in channel.results {
                            let confidence = result.text.runs.compactMap(\.transcriptionConfidence)
                            self?.receive(index, String(result.text.characters), confidence: confidence, isFinal: result.isFinal)
                        }
                    } catch {}
                }
            }
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    self?.checkSilence()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            await teardown()
            isListening = false
        }
    }

    /// Stops listening. With `deliver`, the recognized text goes to the caller as if the user fell silent.
    func stop(deliver: Bool) async {
        guard isListening else { return }
        isListening = false
        watchdog?.cancel()
        watchdog = nil
        await teardown()
        let text = dictation.text
        let handler = onFinish
        onFinish = nil
        if deliver, !text.isEmpty { handler?(text) }
    }

    private func receive(_ index: Int, _ text: String, confidence: [Double], isFinal: Bool) {
        guard isListening, candidates.indices.contains(index) else { return }
        candidates[index].apply(text, confidence: confidence, isFinal: isFinal)
        // Words still being recognized move the scores a lot; the shown language changes on them only with
        // a clear lead, fixed words settle it.
        leader = DictationCandidate.leader(of: candidates, current: isFinal ? nil : leader)
        let best = leader.map { candidates[$0].text } ?? DictationText()
        if best != dictation {
            dictation = best
            lastChange = Date()
        }
    }

    private func checkSilence(now: Date = Date()) {
        guard isListening else { return }
        let quiet = now.timeIntervalSince(lastChange)
        if !dictation.isEmpty, quiet >= timing.silence {
            Task { await stop(deliver: true) }
        } else if dictation.isEmpty, now.timeIntervalSince(startedAt) >= timing.noSpeech {
            Task { await stop(deliver: false) }
        } else if now.timeIntervalSince(startedAt) >= timing.maximum {
            Task { await stop(deliver: true) }
        }
    }

    /// Sends microphone buffers to the recognizers. AVAudioEngine calls the tap on its own audio queue,
    /// so the closure must not be isolated to the main actor (that traps at runtime); hence a nonisolated helper.
    nonisolated private static func feed(_ input: AVAudioInputNode, to channels: [ChannelTranscriber]) {
        input.installTap(onBus: 0, bufferSize: 2_048, format: input.outputFormat(forBus: 0)) { @Sendable buffer, _ in
            for channel in channels { channel.append(buffer) }
        }
    }

    /// Stops the microphone first, then lets the recognizers flush the last words.
    private func teardown() async {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        for channel in channels { await channel.finish() }
        for task in results { await task.value }
        results = []
        channels = []
    }
}
