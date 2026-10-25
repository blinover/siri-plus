import Foundation

enum Speaker: String, Codable, Sendable, Hashable {
    /// The user, captured from the microphone.
    case me
    /// Other participants, captured from the meeting app's audio.
    case them

    var title: String { self == .me ? String(localized: "Me") : String(localized: "Them") }
    /// Fixed English label for model prompts, independent of the interface language.
    var promptLabel: String { self == .me ? "Me" : "Them" }
}

/// One recognition result from a channel. Volatile results are replaced by later
/// ones; a final result fixes the text of the range recognised so far.
struct TranscriptSegment: Sendable, Equatable {
    let speaker: Speaker
    let text: String
    let isFinal: Bool
    let timestamp: Date
}

struct TranscriptTurn: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let speaker: Speaker
    let startedAt: Date
    var updatedAt: Date
    var finalText: String
    var volatileText: String

    var text: String { Transcript.join(finalText, volatileText) }
}

/// Groups recognition results into speaker turns for display and for the model prompt.
struct Transcript: Sendable {
    /// A pause longer than this starts a new turn even for the same speaker.
    static let turnGap: TimeInterval = 6
    /// Without headphones the microphone hears the speakers, so the other side comes back as "Me" within seconds.
    static let echoWindow: TimeInterval = 10

    private(set) var turns: [TranscriptTurn] = []

    var isEmpty: Bool { turns.isEmpty }

    /// Applies a segment and returns the turn it updated.
    @discardableResult
    mutating func apply(_ segment: TranscriptSegment) -> TranscriptTurn? {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if segment.speaker == .me, isEcho(of: text, at: segment.timestamp) {
            // Also forget the echo shown while it was being recognised.
            if let index = turns.lastIndex(where: { $0.speaker == .me && !$0.volatileText.isEmpty }) {
                turns[index].volatileText = ""
                if turns[index].text.isEmpty { turns.remove(at: index) }
            }
            return nil
        }
        let index = activeTurnIndex(for: segment)

        guard let index else {
            guard !text.isEmpty else { return nil }
            turns.append(TranscriptTurn(
                id: UUID(),
                speaker: segment.speaker,
                startedAt: segment.timestamp,
                updatedAt: segment.timestamp,
                finalText: segment.isFinal ? text : "",
                volatileText: segment.isFinal ? "" : text
            ))
            return turns.last
        }

        if segment.isFinal {
            turns[index].finalText = Self.join(turns[index].finalText, text)
            turns[index].volatileText = ""
        } else {
            turns[index].volatileText = text
        }
        turns[index].updatedAt = segment.timestamp
        if turns[index].text.isEmpty {
            turns.remove(at: index)
            return nil
        }
        return turns[index]
    }

    /// Plain-text transcript of the most recent turns, limited to roughly `characterLimit`.
    func recentText(characterLimit: Int, label: (Speaker) -> String = \.promptLabel) -> String {
        var lines: [String] = []
        var count = 0
        for turn in turns.reversed() {
            let line = "\(label(turn.speaker)): \(turn.text)"
            if count + line.count > characterLimit, !lines.isEmpty { break }
            lines.append(line)
            count += line.count + 1
        }
        return lines.reversed().joined(separator: "\n")
    }

    /// Words spoken by anyone in final text, used to pace topic hints.
    var finalWordCount: Int {
        turns.reduce(0) { $0 + $1.finalText.split(whereSeparator: \.isWhitespace).count }
    }

    /// Whether "Me" text repeats what the other side said moments ago: at least 70% of three or more words,
    /// counting words that differ by one letter ("Лена" and "Елена") as the same.
    func isEcho(of text: String, at time: Date) -> Bool {
        let words = Self.words(in: text)
        guard words.count >= 3 else { return false }
        let heard = Set(turns
            .filter { $0.speaker == .them && time.timeIntervalSince($0.updatedAt) < Self.echoWindow }
            .flatMap { Self.words(in: $0.text) })
        guard !heard.isEmpty else { return false }
        let repeated = words.filter { word in heard.contains(word) || heard.contains { Self.differByOneLetter($0, word) } }
        return Double(repeated.count) >= Double(words.count) * 0.7
    }

    private static func words(in text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// One substitution, insertion or deletion; short words such as "в" must match exactly.
    private static func differByOneLetter(_ a: String, _ b: String) -> Bool {
        let a = Array(a), b = Array(b)
        guard max(a.count, b.count) >= 3, abs(a.count - b.count) <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                i += 1; j += 1
                continue
            }
            edits += 1
            if edits > 1 { return false }
            if a.count > b.count { i += 1 } else if b.count > a.count { j += 1 } else { i += 1; j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) <= 1
    }

    private func activeTurnIndex(for segment: TranscriptSegment) -> Int? {
        // A turn still holding volatile text keeps receiving results for that range,
        // even if the other side has spoken since.
        if let index = turns.lastIndex(where: { $0.speaker == segment.speaker && !$0.volatileText.isEmpty }) {
            return index
        }
        if let last = turns.indices.last,
           turns[last].speaker == segment.speaker,
           segment.timestamp.timeIntervalSince(turns[last].updatedAt) < Self.turnGap {
            return last
        }
        return nil
    }

    static func join(_ first: String, _ second: String) -> String {
        [first, second].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Local, offline check for questions. On-device Russian recognition adds no
/// punctuation, so this looks for interrogative words instead of question marks.
enum QuestionDetector {
    private static let anywhere: Set<String> = [
        "почему", "зачем", "сколько", "ли", "отчего",
        "расскажите", "расскажи", "объясните", "объясни", "подскажите", "подскажи",
        "поясните", "поясни", "опишите", "опиши", "уточните", "покажите",
        "why", "explain", "describe",
    ]
    private static let atClauseStart: Set<String> = [
        "как", "какой", "какая", "какое", "какие", "каким", "какую", "каких", "какого", "каком",
        "что", "чего", "чем", "чему", "где", "куда", "откуда", "когда", "кто", "кого", "кому", "кем",
        "чей", "чья", "чьё", "чьи", "можете", "можно", "могли", "скажите", "скажи",
        "правильно", "верно", "согласны", "думаете", "считаете",
        "what", "how", "when", "where", "who", "which", "can", "could", "would", "do", "does", "did", "is", "are",
    ]

    private static let fillers: Set<String> = [
        "а", "и", "ну", "так", "вот", "ок", "окей", "хорошо", "ладно", "слушайте", "смотрите",
        "кстати", "пожалуйста", "коллеги", "and", "so", "ok", "okay", "well",
    ]

    static func isLikelyQuestion(_ text: String) -> Bool {
        if text.contains("?") { return true }
        let words = text.lowercased()
            .split { !$0.isLetter && $0 != "-" }
            .map(String.init)
        guard words.count >= 2 else { return false }
        if words.contains(where: anywhere.contains) { return true }
        // Without punctuation the clause start is unknown; recognition usually
        // finalises at pauses, so the first meaningful word of the chunk approximates it.
        guard let start = words.firstIndex(where: { !fillers.contains($0) }) else { return false }
        let opening = words[start...].prefix(2).joined(separator: " ")
        return atClauseStart.contains(words[start]) && !statementOpenings.contains(opening)
    }

    /// Common openings that start with an interrogative word but are not questions.
    private static let statementOpenings: Set<String> = [
        "что касается", "как бы", "как раз", "как говорится", "как минимум", "как правило",
        "как обычно", "как будто",
    ]
}
