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

    var title: String {
        self == .brief ? String(localized: "Brief") : String(localized: "Detailed")
    }
}

enum AIProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude
    case openAI

    var id: String { rawValue }
    var title: String { self == .claude ? "Claude" : "ChatGPT" }
}

enum ClaudeModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .opus: String(localized: "Claude Opus 5.5 — most accurate")
        case .sonnet: String(localized: "Claude Sonnet 5.5 — faster")
        case .haiku: String(localized: "Claude Haiku 5.5 — fastest and cheapest")
        }
    }

    /// Server-side refusal fallback ("default" form) is available for Opus and Sonnet only.
    var supportsDefaultFallback: Bool { self != .haiku }

    /// Model alias understood by Claude Code, which picks the newest model of the family.
    var cliAlias: String {
        switch self {
        case .opus: "opus"
        case .sonnet: "sonnet"
        case .haiku: "haiku"
        }
    }
}

/// A model offered for an OpenAI API key. A ChatGPT account lists its own models.
struct OpenAIModelOption: Identifiable, Hashable, Sendable {
    let id: String
    let title: String

    static let apiModels: [OpenAIModelOption] = [
        .init(id: "gpt-6-astra", title: String(localized: "GPT-6 Astra — most capable")),
        .init(id: "gpt-6.1-sol", title: String(localized: "GPT-6.1 Sol — balanced")),
        .init(id: "gpt-6-luna", title: String(localized: "GPT-6 Luna — fastest and cheapest")),
    ]
}

enum AuthMethod: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Browser sign-in to a Claude or ChatGPT account (subscription).
    case account
    case apiKey

    var id: String { rawValue }

    var title: String {
        self == .account ? String(localized: "Sign in with browser") : String(localized: "API key")
    }
}

/// Which cloud model answers, and how each provider is authenticated.
struct ModelSelection: Equatable, Sendable {
    var provider: AIProvider = .claude
    var claudeModel: ClaudeModel = .opus
    var claudeAuth: AuthMethod = .account
    /// Empty means the first model the ChatGPT account offers.
    var openAIModel = ""
    var openAIAuth: AuthMethod = .account
}

enum HintMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case questionsAndTopic
    case questions
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .questionsAndTopic: String(localized: "On questions and topic")
        case .questions: String(localized: "On questions only")
        case .manual: String(localized: "Only when asked")
        }
    }
}

struct AssistantPreferences: Codable, Equatable, Sendable {
    /// Speech recognition follows the system language unless a locale is chosen.
    static let systemLocale = "auto"

    var replyStyle: ReplyStyle = .brief
    var showTimestamps = true
    var provider: AIProvider = .claude
    var model: ClaudeModel = .opus
    var claudeAuth: AuthMethod = .account
    var openAIModel = ""
    var openAIAuth: AuthMethod = .account
    var hintMode: HintMode = .questionsAndTopic
    var transcriptionLocale = systemLocale
    var capturesMicrophone = true
    /// Meetings older than this many days are deleted from the history; 0 keeps them forever.
    var historyRetentionDays = 0
    /// Offers to start a meeting when a call app starts recording, and to stop it when the call ends.
    var offersMeetingStart = true

    init(
        replyStyle: ReplyStyle = .brief,
        showTimestamps: Bool = true,
        provider: AIProvider = .claude,
        model: ClaudeModel = .opus,
        claudeAuth: AuthMethod = .account,
        openAIModel: String = "",
        openAIAuth: AuthMethod = .account,
        hintMode: HintMode = .questionsAndTopic,
        transcriptionLocale: String = systemLocale,
        capturesMicrophone: Bool = true,
        historyRetentionDays: Int = 0,
        offersMeetingStart: Bool = true
    ) {
        self.replyStyle = replyStyle
        self.showTimestamps = showTimestamps
        self.provider = provider
        self.model = model
        self.claudeAuth = claudeAuth
        self.openAIModel = openAIModel
        self.openAIAuth = openAIAuth
        self.hintMode = hintMode
        self.transcriptionLocale = transcriptionLocale
        self.capturesMicrophone = capturesMicrophone
        self.historyRetentionDays = historyRetentionDays
        self.offersMeetingStart = offersMeetingStart
    }

    // Settings saved by older versions lack the newer keys; keep what is there.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AssistantPreferences()
        replyStyle = try container.decodeIfPresent(ReplyStyle.self, forKey: .replyStyle) ?? defaults.replyStyle
        showTimestamps = try container.decodeIfPresent(Bool.self, forKey: .showTimestamps) ?? defaults.showTimestamps
        provider = (try? container.decodeIfPresent(AIProvider.self, forKey: .provider)) ?? defaults.provider
        model = (try? container.decodeIfPresent(ClaudeModel.self, forKey: .model)) ?? defaults.model
        claudeAuth = (try? container.decodeIfPresent(AuthMethod.self, forKey: .claudeAuth)) ?? defaults.claudeAuth
        openAIModel = try container.decodeIfPresent(String.self, forKey: .openAIModel) ?? defaults.openAIModel
        openAIAuth = (try? container.decodeIfPresent(AuthMethod.self, forKey: .openAIAuth)) ?? defaults.openAIAuth
        hintMode = (try? container.decodeIfPresent(HintMode.self, forKey: .hintMode)) ?? defaults.hintMode
        transcriptionLocale = try container.decodeIfPresent(String.self, forKey: .transcriptionLocale) ?? defaults.transcriptionLocale
        capturesMicrophone = try container.decodeIfPresent(Bool.self, forKey: .capturesMicrophone) ?? defaults.capturesMicrophone
        historyRetentionDays = try container.decodeIfPresent(Int.self, forKey: .historyRetentionDays) ?? defaults.historyRetentionDays
        offersMeetingStart = try container.decodeIfPresent(Bool.self, forKey: .offersMeetingStart) ?? defaults.offersMeetingStart
    }

    var selection: ModelSelection {
        ModelSelection(provider: provider, claudeModel: model, claudeAuth: claudeAuth, openAIModel: openAIModel, openAIAuth: openAIAuth)
    }

    /// The locale for speech recognition: the chosen one, or the first system language.
    var speechLocale: Locale {
        guard transcriptionLocale == Self.systemLocale else { return Locale(identifier: transcriptionLocale) }
        return Locale(identifier: Locale.preferredLanguages.first ?? "en-US")
    }
}
