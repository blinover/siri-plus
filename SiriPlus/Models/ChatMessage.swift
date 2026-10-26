import Foundation

struct ChatMessage: Identifiable, Equatable, Codable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    let text: String
    let createdAt: Date
    /// JPEG screenshot sent together with a user message.
    let imageJPEG: Data?
    /// Files the user attached to this message.
    let attachments: [ChatAttachment]

    init(role: Role, text: String, imageJPEG: Data? = nil, attachments: [ChatAttachment] = []) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.createdAt = Date()
        self.imageJPEG = imageJPEG
        self.attachments = attachments
    }

    /// Every picture that goes to the model with this message.
    var images: [Data] {
        (imageJPEG.map { [$0] } ?? []) + attachments.compactMap(\.imageData)
    }

    /// The typed text followed by the text of attached documents.
    var promptText: String {
        ([text] + attachments.compactMap(\.promptBlock)).joined(separator: "\n\n")
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
    /// A Claude Code model (an alias such as "opus" or a model ID) or, with an API key, a Claude API model ID.
    var claudeModel = "opus"
    var claudeAuth: AuthMethod = .account
    /// Empty means the first model the ChatGPT account offers.
    var openAIModel = ""
    var openAIAuth: AuthMethod = .account
    /// Effort chosen in Settings for each provider, or `ModelEffort.automatic`.
    var claudeEffort = ModelEffort.automatic
    var openAIEffort = ModelEffort.automatic
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
    /// The model Claude Code runs with a Claude account sign-in.
    var claudeModel = "opus"
    /// The model used with an Anthropic API key.
    var claudeAPIModel = "claude-opus-5-5"
    var claudeAuth: AuthMethod = .account
    var claudeEffort = ModelEffort.automatic
    var openAIModel = ""
    var openAIAuth: AuthMethod = .account
    var openAIEffort = ModelEffort.automatic
    var hintMode: HintMode = .questionsAndTopic
    var transcriptionLocale = systemLocale
    var capturesMicrophone = true
    /// Meetings older than this many days are deleted from the history; 0 keeps them forever.
    var historyRetentionDays = 0
    /// Offers to start a meeting when a call app starts recording, and to stop it when the call ends.
    var offersMeetingStart = true
    /// Looks for new versions on GitHub at launch and twice a day.
    var checksForUpdates = true
    /// ⌃⌥Space opens the panel already listening, as Siri does.
    var dictatesOnShortcut = true

    init(
        replyStyle: ReplyStyle = .brief,
        showTimestamps: Bool = true,
        provider: AIProvider = .claude,
        claudeModel: String = "opus",
        claudeAPIModel: String = "claude-opus-5-5",
        claudeAuth: AuthMethod = .account,
        claudeEffort: String = ModelEffort.automatic,
        openAIModel: String = "",
        openAIAuth: AuthMethod = .account,
        openAIEffort: String = ModelEffort.automatic,
        hintMode: HintMode = .questionsAndTopic,
        transcriptionLocale: String = systemLocale,
        capturesMicrophone: Bool = true,
        historyRetentionDays: Int = 0,
        offersMeetingStart: Bool = true,
        checksForUpdates: Bool = true,
        dictatesOnShortcut: Bool = true
    ) {
        self.replyStyle = replyStyle
        self.showTimestamps = showTimestamps
        self.provider = provider
        self.claudeModel = claudeModel
        self.claudeAPIModel = claudeAPIModel
        self.claudeAuth = claudeAuth
        self.claudeEffort = claudeEffort
        self.openAIModel = openAIModel
        self.openAIAuth = openAIAuth
        self.openAIEffort = openAIEffort
        self.hintMode = hintMode
        self.transcriptionLocale = transcriptionLocale
        self.capturesMicrophone = capturesMicrophone
        self.historyRetentionDays = historyRetentionDays
        self.offersMeetingStart = offersMeetingStart
        self.checksForUpdates = checksForUpdates
        self.dictatesOnShortcut = dictatesOnShortcut
    }

    // Settings saved by older versions lack the newer keys; keep what is there.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AssistantPreferences()
        replyStyle = try container.decodeIfPresent(ReplyStyle.self, forKey: .replyStyle) ?? defaults.replyStyle
        showTimestamps = try container.decodeIfPresent(Bool.self, forKey: .showTimestamps) ?? defaults.showTimestamps
        provider = (try? container.decodeIfPresent(AIProvider.self, forKey: .provider)) ?? defaults.provider
        // Siri+ 0.3 kept one Claude API model ID under "model" for both sign-in methods.
        let legacyModel = try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(String.self, forKey: .model)
        claudeModel = try container.decodeIfPresent(String.self, forKey: .claudeModel)
            ?? legacyModel.map(ModelOption.claudeCodeAlias(forLegacy:)) ?? defaults.claudeModel
        claudeAPIModel = try container.decodeIfPresent(String.self, forKey: .claudeAPIModel) ?? legacyModel ?? defaults.claudeAPIModel
        claudeAuth = (try? container.decodeIfPresent(AuthMethod.self, forKey: .claudeAuth)) ?? defaults.claudeAuth
        claudeEffort = try container.decodeIfPresent(String.self, forKey: .claudeEffort) ?? defaults.claudeEffort
        openAIModel = try container.decodeIfPresent(String.self, forKey: .openAIModel) ?? defaults.openAIModel
        openAIAuth = (try? container.decodeIfPresent(AuthMethod.self, forKey: .openAIAuth)) ?? defaults.openAIAuth
        openAIEffort = try container.decodeIfPresent(String.self, forKey: .openAIEffort) ?? defaults.openAIEffort
        hintMode = (try? container.decodeIfPresent(HintMode.self, forKey: .hintMode)) ?? defaults.hintMode
        transcriptionLocale = try container.decodeIfPresent(String.self, forKey: .transcriptionLocale) ?? defaults.transcriptionLocale
        capturesMicrophone = try container.decodeIfPresent(Bool.self, forKey: .capturesMicrophone) ?? defaults.capturesMicrophone
        historyRetentionDays = try container.decodeIfPresent(Int.self, forKey: .historyRetentionDays) ?? defaults.historyRetentionDays
        offersMeetingStart = try container.decodeIfPresent(Bool.self, forKey: .offersMeetingStart) ?? defaults.offersMeetingStart
        checksForUpdates = try container.decodeIfPresent(Bool.self, forKey: .checksForUpdates) ?? defaults.checksForUpdates
        dictatesOnShortcut = try container.decodeIfPresent(Bool.self, forKey: .dictatesOnShortcut) ?? defaults.dictatesOnShortcut
    }

    private enum LegacyKeys: String, CodingKey {
        case model
    }

    var selection: ModelSelection {
        ModelSelection(
            provider: provider,
            claudeModel: claudeAuth == .account ? claudeModel : claudeAPIModel,
            claudeAuth: claudeAuth,
            openAIModel: openAIModel,
            openAIAuth: openAIAuth,
            claudeEffort: claudeEffort,
            openAIEffort: openAIEffort
        )
    }

    /// The languages speech is recognized in: the chosen one, or every language this Mac's user likely speaks.
    var speechLocales: [Locale] {
        guard transcriptionLocale == Self.systemLocale else { return [Locale(identifier: transcriptionLocale)] }
        return SpeechLanguages.automatic()
    }
}
