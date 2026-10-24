import AVFoundation
import Combine

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

/// Siri-style voice commands: listens to the microphone, recognizes speech on this Mac,
/// and hands the text over when the user stops talking.
@MainActor
final class VoiceInput: ObservableObject {
    struct Timing {
        /// Silence after speech that ends the command.
        var silence: TimeInterval = 1.5
        /// Listening stops without a word after this long.
        var noSpeech: TimeInterval = 8
        var maximum: TimeInterval = 60
    }

    @Published private(set) var isListening = false
    @Published private(set) var dictation = DictationText()
    @Published var errorMessage: String?

    private let timing: Timing
    private var engine: AVAudioEngine?
    private var channel: ChannelTranscriber?
    private var results: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var lastChange = Date()
    private var startedAt = Date()
    private var onFinish: ((String) -> Void)?

    init(timing: Timing = Timing()) {
        self.timing = timing
    }

    /// Starts listening; `onFinish` receives the text when the user falls silent.
    func start(locale: Locale, onFinish: @escaping (String) -> Void) async {
        guard !isListening else { return }
        errorMessage = nil
        dictation = DictationText()
        self.onFinish = onFinish
        isListening = true
        do {
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw MeetingError.microphoneDenied }
            let resolved = try await ChannelTranscriber.prepare(locale: locale)
            let channel = try await ChannelTranscriber(speaker: .me, locale: resolved)
            try await channel.start(contextualStrings: [])
            guard isListening else {
                await channel.finish()
                return
            }
            self.channel = channel

            let engine = AVAudioEngine()
            Self.feed(engine.inputNode, to: channel)
            try engine.start()
            self.engine = engine

            startedAt = Date()
            lastChange = Date()
            results = Task { [weak self] in
                do {
                    for try await result in channel.results {
                        self?.receive(String(result.text.characters), isFinal: result.isFinal)
                    }
                } catch {}
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

    private func receive(_ text: String, isFinal: Bool) {
        guard isListening else { return }
        let before = dictation
        dictation.apply(text, isFinal: isFinal)
        if dictation != before { lastChange = Date() }
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

    /// Sends microphone buffers to the recognizer. AVAudioEngine calls the tap on its own audio queue,
    /// so the closure must not be isolated to the main actor (that traps at runtime); hence a nonisolated helper.
    nonisolated private static func feed(_ input: AVAudioInputNode, to channel: ChannelTranscriber) {
        input.installTap(onBus: 0, bufferSize: 2_048, format: input.outputFormat(forBus: 0)) { @Sendable buffer, _ in
            channel.append(buffer)
        }
    }

    /// Stops the microphone first, then lets the recognizer flush the last words into `dictation`.
    private func teardown() async {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        if let channel {
            await channel.finish()
        }
        await results?.value
        results = nil
        channel = nil
    }
}
