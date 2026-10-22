import AppKit
import AVFoundation
import ScreenCaptureKit
import Speech

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
        "ru.yandex.telemost", "ru.keepcoder.Telegram", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
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
    let locale: Locale
    let capturesMicrophone: Bool
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
    private var channels: [ChannelTranscriber] = []
    private var resultTasks: [Task<Void, Never>] = []
    private var continuation: AsyncThrowingStream<MeetingEvent, Error>.Continuation?

    func start(_ configuration: MeetingConfiguration) async throws -> AsyncThrowingStream<MeetingEvent, Error> {
        await stop()
        let (events, continuation) = AsyncThrowingStream<MeetingEvent, Error>.makeStream()
        self.continuation = continuation
        do {
            if configuration.capturesMicrophone, !(await AVCaptureDevice.requestAccess(for: .audio)) {
                throw MeetingError.microphoneDenied
            }
            let locale = try await ChannelTranscriber.prepare(locale: configuration.locale)
            var speakers: [Speaker] = [.them]
            if configuration.capturesMicrophone { speakers.append(.me) }

            for speaker in speakers {
                let channel = try await ChannelTranscriber(speaker: speaker, locale: locale)
                try await channel.start()
                channels.append(channel)
                resultTasks.append(Task {
                    do {
                        for try await result in channel.results {
                            continuation.yield(.segment(TranscriptSegment(
                                speaker: speaker,
                                text: String(result.text.characters),
                                isFinal: result.isFinal,
                                timestamp: Date()
                            )))
                        }
                    } catch {
                        continuation.finish(throwing: error)
                    }
                })
            }

            let routes = Dictionary(uniqueKeysWithValues: channels.map { ($0.speaker, $0) })
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
        for task in resultTasks { await task.value }
        channels = []
        resultTasks = []
        continuation?.finish()
        continuation = nil
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
        return preset
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

    func start() async throws {
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

private extension CMSampleBuffer {
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
