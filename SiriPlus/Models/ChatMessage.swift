import Foundation

struct ChatMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    let text: String
    let createdAt: Date
    /// JPEG screenshot sent together with a user message.
    let imageJPEG: Data?

    init(role: Role, text: String, imageJPEG: Data? = nil) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.createdAt = Date()
        self.imageJPEG = imageJPEG
    }
}

enum ReplyStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case brief
    case detailed

    var id: String { rawValue }
    var title: String { self == .brief ? "Кратко" : "Подробно" }
}

enum ClaudeModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .opus: "Claude Opus 5.5 — точнее"
        case .sonnet: "Claude Sonnet 5.5 — быстрее"
        case .haiku: "Claude Haiku 5.5 — самый быстрый и дешёвый"
        }
    }

    /// Server-side refusal fallback ("default" form) is available for Opus and Sonnet only.
    var supportsDefaultFallback: Bool { self != .haiku }
}

enum HintMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case questionsAndTopic
    case questions
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .questionsAndTopic: "На вопросы и по теме"
        case .questions: "Только на вопросы"
        case .manual: "Только по запросу"
        }
    }
}

struct AssistantPreferences: Codable, Equatable, Sendable {
    var replyStyle: ReplyStyle = .brief
    var showTimestamps = true
    var model: ClaudeModel = .opus
    var hintMode: HintMode = .questionsAndTopic
    var transcriptionLocale = "ru-RU"
    var capturesMicrophone = true

    init(
        replyStyle: ReplyStyle = .brief,
        showTimestamps: Bool = true,
        model: ClaudeModel = .opus,
        hintMode: HintMode = .questionsAndTopic,
        transcriptionLocale: String = "ru-RU",
        capturesMicrophone: Bool = true
    ) {
        self.replyStyle = replyStyle
        self.showTimestamps = showTimestamps
        self.model = model
        self.hintMode = hintMode
        self.transcriptionLocale = transcriptionLocale
        self.capturesMicrophone = capturesMicrophone
    }

    // Settings saved by older versions lack the newer keys; keep what is there.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AssistantPreferences()
        replyStyle = try container.decodeIfPresent(ReplyStyle.self, forKey: .replyStyle) ?? defaults.replyStyle
        showTimestamps = try container.decodeIfPresent(Bool.self, forKey: .showTimestamps) ?? defaults.showTimestamps
        model = (try? container.decodeIfPresent(ClaudeModel.self, forKey: .model)) ?? defaults.model
        hintMode = (try? container.decodeIfPresent(HintMode.self, forKey: .hintMode)) ?? defaults.hintMode
        transcriptionLocale = try container.decodeIfPresent(String.self, forKey: .transcriptionLocale) ?? defaults.transcriptionLocale
        capturesMicrophone = try container.decodeIfPresent(Bool.self, forKey: .capturesMicrophone) ?? defaults.capturesMicrophone
    }
}
