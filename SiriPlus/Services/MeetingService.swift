import AppKit
import AVFoundation
import ScreenCaptureKit
import Speech
import Synchronization

/// Where the other participants' voices come from.
struct MeetingAudioSource: Identifiable, Hashable, Sendable {
    /// Bundle identifier of the meeting app, or `system` for all system audio.
    let id: String
    let name: String

    static let system = MeetingAudioSource(id: "system", name: String(localized: "All system audio"))

    /// Apps made for calls. When one of them is running it is picked automatically.
    static let callApps: [String] = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.apple.FaceTime",
        "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark", "com.skype.skype",
        "ru.yandex.telemost", "ru.keepcoder.Telegram", "com.tdesktop.Telegram", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
        "net.whatsapp.WhatsApp", "com.vk.messenger",
    ]

    /// System audio first (works for any call), then call apps, then every other running app,
    /// e.g. a browser with Google Meet or Telemost.
    @MainActor
    static func available() -> [MeetingAudioSource] {
        let ownID = Bundle.main.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != ownID }
            .compactMap { app -> MeetingAudioSource? in
                guard let id = app.bundleIdentifier else { return nil }
                return MeetingAudioSource(id: id, name: app.localizedName ?? id)
            }
        let calls = apps.filter { callApps.contains($0.id) }
        let others = apps.filter { !callApps.contains($0.id) }.sorted { $0.name < $1.name }
        return [.system] + calls + others
    }

    /// The running call app if there is one, otherwise all system audio.
    @MainActor
    static func preferred(in sources: [MeetingAudioSource]) -> MeetingAudioSource {
        sources.first { callApps.contains($0.id) } ?? .system
    }
}

struct MeetingConfiguration: Sendable {
    let source: MeetingAudioSource
    /// Candidate languages; with several, each speaker's language is picked from their first sentences.
    let locales: [Locale]
    let capturesMicrophone: Bool
    /// Names and terms the recogniser should expect.
    var contextualStrings: [String] = []

    /// Words from the meeting materials worth hinting: names, product names, abbreviations, "k8s"-like terms.
    /// Ordinary lowercase words are left out, recognition handles them anyway.
    static func contextualStrings(from notes: String, limit: Int = 100) -> [String] {
        var seen: Set<String> = []
        var terms: [String] = []
        let words = notes.split { !$0.isLetter && !$0.isNumber && !"-+#.".contains($0) }
        for word in words {
            let word = word.trimmingCharacters(in: CharacterSet(charactersIn: "-.#+"))
            let hasLetter = word.contains(where: \.isLetter)
            guard word.count >= 2, hasLetter,
                  word.contains(where: \.isUppercase) || word.contains(where: \.isNumber),
                  seen.insert(word.lowercased()).inserted else { continue }
            terms.append(word)
            if terms.count == limit { break }
        }
        return terms
    }
}

enum MeetingEvent: Sendable {
    case segment(TranscriptSegment)
    /// Normalised input level 0...1 for the level meters.
    case level(Speaker, Float)
}

enum MeetingError: LocalizedError {
    case microphoneDenied
    case unsupportedLocale(String)
    case appNotRunning(String)
    case noDisplay
    case noAudioFormat

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            String(localized: "No microphone access. Allow it in System Settings → Privacy & Security → Microphone, or turn off your voice in Siri+ Settings.")
        case .unsupportedLocale(let locale):
            String(localized: "On-device speech recognition for \(locale) is not available on this Mac. Choose another language in Settings.")
        case .appNotRunning(let name):
            String(localized: "\(name) is not running. Start the call or choose “All system audio”.")
        case .noDisplay:
            String(localized: "No display was found for audio capture.")
        case .noAudioFormat:
            String(localized: "The speech recognition model did not report an audio format.")
        }
    }
}

/// Audio capture and transcription are owned by one session, so stopping it
/// also closes the audio stream and the recognisers.
@MainActor
protocol MeetingService: AnyObject {
    func start(_ configuration: MeetingConfiguration) async throws -> AsyncThrowingStream<MeetingEvent, Error>
    func stop() async
}

/// Captures audio with ScreenCaptureKit and transcribes it on device. Nothing leaves the Mac.
@MainActor
final class LiveMeetingService: MeetingService {
    private var capture: MeetingAudioCapture?
    /// Recognisers still listening: every candidate language until a speaker's language is chosen.
    private var channels: [ChannelTranscriber] = []
    private var routes: [Speaker: SpeakerRoute] = [:]
    private var locks: [Speaker: LanguageLock] = [:]
    private var resultTasks: [Task<Void, Never>] = []
    private var closing: [Task<Void, Never>] = []
    private var continuation: AsyncThrowingStream<MeetingEvent, Error>.Continuation?

    func start(_ configuration: MeetingConfiguration) async throws -> AsyncThrowingStream<MeetingEvent, Error> {
        await stop()
        let (events, continuation) = AsyncThrowingStream<MeetingEvent, Error>.makeStream()
        self.continuation = continuation
        do {
            if configuration.capturesMicrophone, !(await AVCaptureDevice.requestAccess(for: .audio)) {
                throw MeetingError.microphoneDenied
            }
            let locales = try await ChannelTranscriber.prepare(locales: configuration.locales)
            var speakers: [Speaker] = [.them]
            if configuration.capturesMicrophone { speakers.append(.me) }

            for speaker in speakers {
                var group: [ChannelTranscriber] = []
                for (index, locale) in locales.enumerated() {
                    let channel = try await ChannelTranscriber(speaker: speaker, locale: locale)
                    try await channel.start(contextualStrings: configuration.contextualStrings)
                    group.append(channel)
                    resultTasks.append(Task { [weak self] in
                        do {
                            for try await result in channel.results {
                                self?.receive(speaker, index, result)
                            }
                        } catch {
                            // A language dropped after the choice may end with an error; only the kept one counts.
                            if self?.isKept(speaker, index) ?? true { continuation.finish(throwing: error) }
                        }
                    })
                }
                channels += group
                routes[speaker] = SpeakerRoute(group)
                locks[speaker] = LanguageLock(count: group.count)
            }

            let routes = self.routes
            let meters = Dictionary(uniqueKeysWithValues: speakers.map { ($0, LevelMeter(speaker: $0, continuation: continuation)) })
            let capture = MeetingAudioCapture(
                onBuffer: { speaker, buffer in
                    meters[speaker]?.report(buffer)
                    routes[speaker]?.append(buffer)
                },
                onStop: { error in continuation.finish(throwing: error) }
            )
            try await capture.start(source: configuration.source, capturesMicrophone: configuration.capturesMicrophone)
            self.capture = capture
            return events
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        await capture?.stop()
        capture = nil
        // Finalising flushes the text still being recognised before the streams end.
        for channel in channels { await channel.finish() }
        for task in closing { await task.value }
        for task in resultTasks { await task.value }
        for (speaker, var lock) in locks {
            for case .segment(let text, let isFinal) in lock.finish() {
                continuation?.yield(.segment(TranscriptSegment(speaker: speaker, text: text, isFinal: isFinal, timestamp: Date())))
            }
        }
        channels = []
        routes = [:]
        locks = [:]
        closing = []
        resultTasks = []
        continuation?.finish()
        continuation = nil
    }

    private func receive(_ speaker: Speaker, _ index: Int, _ result: DictationTranscriber.Result) {
        guard var lock = locks[speaker] else { return }
        let outputs = lock.apply(
            index,
            text: String(result.text.characters),
            confidence: result.text.runs.compactMap(\.transcriptionConfidence),
            isFinal: result.isFinal
        )
        locks[speaker] = lock
        for output in outputs {
            switch output {
            case .segment(let text, let isFinal):
                continuation?.yield(.segment(TranscriptSegment(speaker: speaker, text: text, isFinal: isFinal, timestamp: Date())))
            case .locked(let kept):
                // The other languages stop listening; one recogniser per speaker is enough from here on.
                let dropped = routes[speaker]?.keep(kept) ?? []
                channels.removeAll { channel in dropped.contains { $0 === channel } }
                closing.append(Task {
                    for channel in dropped { await channel.finish() }
                })
            }
        }
    }

    private func isKept(_ speaker: Speaker, _ index: Int) -> Bool {
        locks[speaker]?.chosen.map { $0 == index } ?? true
    }
}

/// Picks one speaker's language. Every candidate language listens to the first sentences; once one is clearly
/// more confident, it is kept and the others stop. Until then the leading reading is shown as text still being
/// recognised, so nothing in a wrong language is ever fixed in the transcript.
struct LanguageLock: Sendable {
    enum Output: Equatable, Sendable {
        case segment(String, isFinal: Bool)
        case locked(Int)
    }

    /// Fixed words the leader needs before it can win, and its lead in mean confidence.
    static let minimumWords = 3
    static let margin = 0.05
    /// After this many fixed words the leader wins even by a hair.
    static let decisiveWords = 12
    /// A language that has rated nothing by then is out (it hears nothing it can recognise).
    static let walkoverWords = 40

    private(set) var candidates: [DictationCandidate]
    private(set) var chosen: Int?

    init(count: Int) {
        candidates = Array(repeating: DictationCandidate(), count: count)
        chosen = count == 1 ? 0 : nil
    }

    mutating func apply(_ index: Int, text: String, confidence: [Double], isFinal: Bool) -> [Output] {
        if let chosen { return index == chosen ? [.segment(text, isFinal: isFinal)] : [] }
        guard candidates.indices.contains(index) else { return [] }
        candidates[index].apply(text, confidence: confidence, isFinal: isFinal)

        guard let leader = DictationCandidate.bestIndex(of: candidates) else { return [] }
        let reading = candidates[leader].text
        let runnerUp = candidates.indices.filter { $0 != leader }.map { candidates[$0].score }.max() ?? 0
        let words = reading.final.split(whereSeparator: \.isWhitespace).count
        // Recognisers rate only fixed words, and each fixes them at its own pace: until every language has
        // rated some, an unrated one scores zero although it may be the right one.
        let everyoneRated = candidates.allSatisfy(\.isRated)
        let clearLead = words >= Self.minimumWords && candidates[leader].score - runnerUp >= Self.margin
        guard (everyoneRated && (clearLead || words >= Self.decisiveWords)) || words >= Self.walkoverWords else {
            // Without ratings, the reading with more words is the better guess to show: a recogniser hearing
            // a language it does not know drops most of them.
            let shown = everyoneRated ? reading : candidates.max { $0.text.text.count < $1.text.text.count }?.text ?? reading
            return [.segment(shown.text, isFinal: false)]
        }
        chosen = leader
        return [.locked(leader), .segment(reading.final, isFinal: true), .segment(reading.volatile, isFinal: false)]
    }

    /// When listening ends before a language was chosen (only short replies), the leading reading is kept.
    mutating func finish() -> [Output] {
        guard chosen == nil, let leader = DictationCandidate.bestIndex(of: candidates) else { return [] }
        chosen = leader
        return [.segment(candidates[leader].text.text, isFinal: true)]
    }
}

/// The recognisers one speaker's audio goes to. The capture queue reads it; the main actor narrows it to one.
private final class SpeakerRoute: Sendable {
    private let channels: Mutex<[ChannelTranscriber]>

    init(_ channels: [ChannelTranscriber]) {
        self.channels = Mutex(channels)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        for channel in channels.withLock({ $0 }) { channel.append(buffer) }
    }

    /// Keeps only the recogniser at `index` and returns the others.
    func keep(_ index: Int) -> [ChannelTranscriber] {
        channels.withLock { channels in
            guard channels.indices.contains(index) else { return [] }
            let dropped = channels.enumerated().filter { $0.offset != index }.map(\.element)
            channels = [channels[index]]
            return dropped
        }
    }
}

/// One on-device recogniser for one speaker channel.
final class ChannelTranscriber: @unchecked Sendable {
    let speaker: Speaker
    private let transcriber: DictationTranscriber
    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat
    private let inputSequence: AsyncStream<AnalyzerInput>
    private let input: AsyncStream<AnalyzerInput>.Continuation
    // Touched only from the capture queue of this channel.
    private var converter: AVAudioConverter?

    private static var preset: DictationTranscriber.Preset {
        var preset = DictationTranscriber.Preset.progressiveLongDictation
        preset.transcriptionOptions.insert(.punctuation)
        // Final results at short pauses let questions be detected sooner.
        preset.reportingOptions.insert(.frequentFinalization)
        // Per-word confidence lets dictation pick the language the user actually spoke.
        preset.attributeOptions.insert(.transcriptionConfidence)
        return preset
    }

    /// Resolves every locale this Mac can recognise, one per model, installing models as needed.
    /// Fails only when none of them is available.
    static func prepare(locales: [Locale]) async throws -> [Locale] {
        var resolved: [Locale] = []
        for locale in locales {
            guard let supported = try? await prepare(locale: locale),
                  !resolved.contains(where: { $0.identifier == supported.identifier }) else { continue }
            resolved.append(supported)
        }
        guard !resolved.isEmpty else {
            throw MeetingError.unsupportedLocale(locales.map(\.identifier).joined(separator: ", "))
        }
        return resolved
    }

    /// Resolves the locale and installs its on-device model if needed.
    static func prepare(locale: Locale) async throws -> Locale {
        guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            throw MeetingError.unsupportedLocale(locale.identifier)
        }
        let module = DictationTranscriber(locale: supported, preset: preset)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        return supported
    }

    init(speaker: Speaker, locale: Locale) async throws {
        self.speaker = speaker
        transcriber = DictationTranscriber(locale: locale, preset: Self.preset)
        analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw MeetingError.noAudioFormat
        }
        self.format = format
        (inputSequence, input) = AsyncStream<AnalyzerInput>.makeStream()
    }

    var results: some AsyncSequence<DictationTranscriber.Result, Error> { transcriber.results }

    func start(contextualStrings: [String]) async throws {
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            // Only a hint: recognition works without it, so a failure must not stop the meeting.
            try? await analyzer.setContext(context)
        }
        try await analyzer.start(inputSequence: inputSequence)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    func finish() async {
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var delivered = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if delivered {
                // Keep the converter's resampling state for the next buffer.
                inputStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

/// Reports a throttled RMS level for one channel. Used from that channel's capture queue only.
private final class LevelMeter: @unchecked Sendable {
    private let speaker: Speaker
    private let continuation: AsyncThrowingStream<MeetingEvent, Error>.Continuation
    private var lastReport = Date.distantPast

    init(speaker: Speaker, continuation: AsyncThrowingStream<MeetingEvent, Error>.Continuation) {
        self.speaker = speaker
        self.continuation = continuation
    }

    func report(_ buffer: AVAudioPCMBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastReport) > 0.1,
              let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        lastReport = now
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        // Map roughly -50...0 dBFS to 0...1.
        let decibels = 20 * log10(max(rms, 0.000_01))
        continuation.yield(.level(speaker, min(max((decibels + 50) / 50, 0), 1)))
    }
}

/// Captures the meeting app's audio and, optionally, the microphone through one ScreenCaptureKit stream.
/// Not AVAudioEngine voice processing: it cancels echo, but Teams and Zoom then get silence from the microphone.
final class MeetingAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let onBuffer: @Sendable (Speaker, AVAudioPCMBuffer) -> Void
    private let onStop: @Sendable (Error) -> Void
    private let audioQueue = DispatchQueue(label: "dev.siriplus.capture.them")
    private let microphoneQueue = DispatchQueue(label: "dev.siriplus.capture.me")
    private let screenQueue = DispatchQueue(label: "dev.siriplus.capture.screen")
    private var stream: SCStream?

    init(onBuffer: @escaping @Sendable (Speaker, AVAudioPCMBuffer) -> Void, onStop: @escaping @Sendable (Error) -> Void) {
        self.onBuffer = onBuffer
        self.onStop = onStop
    }

    func start(source: MeetingAudioSource, capturesMicrophone: Bool) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw MeetingError.noDisplay
        }

        let filter: SCContentFilter
        if source == .system {
            let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
        } else {
            // Browsers and Teams play call audio from helper processes with derived bundle identifiers.
            let applications = content.applications.filter {
                $0.bundleIdentifier == source.id || $0.bundleIdentifier.hasPrefix(source.id + ".")
            }
            guard !applications.isEmpty else { throw MeetingError.appNotRunning(source.name) }
            filter = SCContentFilter(display: display, including: applications, exceptingWindows: [])
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        configuration.captureMicrophone = capturesMicrophone
        // Video is required by the stream but unused: keep it tiny and rare.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        if capturesMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: microphoneQueue)
        }
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let speaker: Speaker
        switch type {
        case .audio: speaker = .them
        case .microphone: speaker = .me
        default: return
        }
        guard sampleBuffer.isValid, let buffer = sampleBuffer.pcmBuffer() else { return }
        onBuffer(speaker, buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }
}

extension CMSampleBuffer {
    func pcmBuffer() -> AVAudioPCMBuffer? {
        guard let description = formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
