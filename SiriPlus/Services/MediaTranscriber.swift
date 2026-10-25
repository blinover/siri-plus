import AVFoundation
import Speech
import UniformTypeIdentifiers

enum MediaTranscriptionError: LocalizedError, Equatable {
    case noAudio(String)
    case unreadable(String)
    case noSpeech(String)

    var errorDescription: String? {
        switch self {
        case .noAudio(let name): String(localized: "\(name) has no sound to transcribe.")
        case .unreadable(let name): String(localized: "The sound in \(name) could not be read. Formats macOS plays, such as MP3, M4A, WAV, MP4 and MOV, are supported.")
        case .noSpeech(let name): String(localized: "No speech was recognized in \(name).")
        }
    }
}

/// Turns the sound of an audio or video file into text on this Mac: the audio track is decoded with
/// AVFoundation and recognized in every given language at once, keeping the most confident reading.
enum MediaTranscriber {
    static func isMedia(_ url: URL) -> Bool {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return type.conforms(to: .audiovisualContent)
    }

    /// The transcript and the locale it was recognized in.
    static func transcribe(_ url: URL, locales: [Locale]) async throws -> (text: String, locale: Locale) {
        let name = url.lastPathComponent
        guard (try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first) != nil else {
            throw MediaTranscriptionError.noAudio(name)
        }

        let resolved = try await ChannelTranscriber.prepare(locales: locales)

        var channels: [ChannelTranscriber] = []
        for locale in resolved {
            let channel = try await ChannelTranscriber(speaker: .them, locale: locale)
            try await channel.start(contextualStrings: [])
            channels.append(channel)
        }
        let collected = Candidates(count: channels.count)
        let readers = channels.enumerated().map { index, channel in
            Task {
                for try await result in channel.results where result.isFinal {
                    collected.apply(index, String(result.text.characters), result.text.runs.compactMap(\.transcriptionConfidence))
                }
            }
        }

        // Decoding is synchronous, so it runs off the caller's actor; AVFoundation objects stay inside the task.
        let recognizers = channels
        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                throw MediaTranscriptionError.noAudio(name)
            }
            try decode(track: track, asset: asset, name: name) { buffer in
                for channel in recognizers { channel.append(buffer) }
            }
        }.value

        for channel in channels { await channel.finish() }
        for reader in readers { _ = await reader.result }

        let candidates = collected.snapshot()
        guard let index = DictationCandidate.bestIndex(of: candidates), !candidates[index].text.isEmpty else {
            throw MediaTranscriptionError.noSpeech(name)
        }
        return (candidates[index].text.text, resolved[index])
    }

    /// Reads the audio track as 16 kHz mono floating-point PCM, whatever the container and codec.
    private static func decode(track: AVAssetTrack, asset: AVAsset, name: String, onBuffer: (AVAudioPCMBuffer) -> Void) throws {
        guard let reader = try? AVAssetReader(asset: asset) else { throw MediaTranscriptionError.unreadable(name) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 16_000,
        ])
        guard reader.canAdd(output) else { throw MediaTranscriptionError.unreadable(name) }
        reader.add(output)
        guard reader.startReading() else { throw MediaTranscriptionError.unreadable(name) }
        while let sample = output.copyNextSampleBuffer() {
            if let buffer = sample.pcmBuffer() { onBuffer(buffer) }
        }
        if reader.status == .failed { throw MediaTranscriptionError.unreadable(name) }
    }
}

/// Final results per language, filled from several recognizer tasks.
private final class Candidates: @unchecked Sendable {
    private let lock = NSLock()
    private var candidates: [DictationCandidate]

    init(count: Int) { candidates = Array(repeating: DictationCandidate(), count: count) }

    func apply(_ index: Int, _ text: String, _ confidence: [Double]) {
        lock.withLock { candidates[index].apply(text, confidence: confidence, isFinal: true) }
    }

    func snapshot() -> [DictationCandidate] { lock.withLock { candidates } }
}
