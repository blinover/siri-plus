import Foundation

struct AssistantRequest: Sendable {
    let messages: [ChatMessage]
    let replyStyle: ReplyStyle
    let selection: ModelSelection
}

protocol AssistantService: Sendable {
    /// Streams the reply as text fragments.
    func reply(to request: AssistantRequest) -> AsyncThrowingStream<String, Error>
}

struct HintRequest: Sendable, Equatable {
    enum Trigger: Sendable, Equatable {
        case question(String)
        case topic
        case manual
    }

    let trigger: Trigger
    let transcript: String
    let notes: String
    let previousHints: [String]
    let selection: ModelSelection
}

protocol HintService: Sendable {
    /// Streams a short meeting hint. A reply of "—" means no hint is needed.
    func hint(for request: HintRequest) -> AsyncThrowingStream<String, Error>
}

/// A provider-neutral prompt: every backend turns it into its own wire format.
struct PreparedPrompt: Sendable, Equatable {
    struct Turn: Sendable, Equatable {
        let role: ChatMessage.Role
        let text: String
        var imageJPEG: Data?
    }

    let system: String
    let turns: [Turn]
    /// "low" or "medium"; hints use "low" for speed.
    let effort: String
    let maxTokens: Int
    /// The system prompt stays the same for a whole meeting and is worth caching.
    var cacheSystem = false
}

/// One way of reaching a model: Claude API, Claude Code, OpenAI API or a ChatGPT account.
protocol ModelBackend: Sendable {
    func stream(_ prompt: PreparedPrompt, model: String) -> AsyncThrowingStream<String, Error>
}

enum AssistantPrompts {
    /// English name of the first system language, used when the conversation language is unclear.
    static var systemLanguageName: String {
        let code = Locale(identifier: Locale.preferredLanguages.first ?? "en").language.languageCode?.identifier ?? "en"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }

    static func chat(_ request: AssistantRequest, language: String = systemLanguageName) -> PreparedPrompt {
        let style = request.replyStyle == .brief
            ? "Be brief: one to four sentences or a short list."
            : "Answer thoroughly and in a structured way, with examples when they help."
        let system = """
        You are Siri+, the user's personal assistant on their Mac. Reply in the language the user writes in; if it is unclear, reply in \(language). \(style)
        If a screenshot is attached to a message, it shows the user's screen at the moment of the question: rely on what is visible on it.
        """
        return PreparedPrompt(
            system: system,
            turns: request.messages.map { .init(role: $0.role, text: $0.text, imageJPEG: $0.imageJPEG) },
            effort: request.replyStyle == .brief ? "low" : "medium",
            maxTokens: 32_000
        )
    }

    static func hint(_ request: HintRequest, language: String = systemLanguageName) -> PreparedPrompt {
        PreparedPrompt(
            system: hintSystem(notes: request.notes, language: language),
            turns: [.init(role: .user, text: hintUser(request))],
            effort: "low",
            maxTokens: 4_000,
            cacheSystem: true
        )
    }

    static func hintSystem(notes: String, language: String = systemLanguageName) -> String {
        var prompt = """
        You are the user's discreet assistant during a work call in Zoom, Teams or a similar app. The user glances at your hint while listening to the other side, so they have two or three seconds to read it.

        How to answer:
        - In the language of the conversation (if it is unclear, in \(language)), very briefly: at most three bullet points, one line each.
        - Get straight to the point: what to answer or say. No preamble, do not restate the question.
        - When it fits, give something concrete: a fact, a number, an argument, or a clarifying question to ask.
        - The transcript is automatic and has no punctuation; it contains recognition errors, so reconstruct the meaning from context. "Me" is the user, "Them" are the other participants.
        - Do not invent facts about the user, their company or project that are not in the materials. If facts are missing, suggest how to phrase a general answer.
        - If no hint is needed right now (no question and nothing to add on the topic), reply with the single character "—".
        """
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            prompt += "\n\nThe user's materials for this meeting:\n<materials>\n\(trimmed)\n</materials>"
        }
        return prompt
    }

    static func hintUser(_ request: HintRequest) -> String {
        var prompt = "<transcript>\n\(request.transcript)\n</transcript>\n\n"
        if !request.previousHints.isEmpty {
            prompt += "Already suggested, do not repeat:\n"
            prompt += request.previousHints.map { "- \($0.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n")
            prompt += "\n\n"
        }
        switch request.trigger {
        case .question(let question):
            prompt += "The other side seems to have asked: \"\(question)\". Suggest what to answer."
        case .topic:
            prompt += "Give a hint on the current topic: what would be useful to say, ask or clarify."
        case .manual:
            prompt += "The user asks for a hint right now. Help answer the latest question or continue the current topic."
        }
        return prompt
    }
}

/// Routes requests to the backend chosen in settings.
struct CloudAssistantService: AssistantService, HintService {
    let claudeAPI: any ModelBackend
    let claudeCode: any ModelBackend
    let openAIAPI: any ModelBackend
    let chatGPT: any ModelBackend

    func reply(to request: AssistantRequest) -> AsyncThrowingStream<String, Error> {
        route(AssistantPrompts.chat(request), selection: request.selection)
    }

    func hint(for request: HintRequest) -> AsyncThrowingStream<String, Error> {
        route(AssistantPrompts.hint(request), selection: request.selection)
    }

    private func route(_ prompt: PreparedPrompt, selection: ModelSelection) -> AsyncThrowingStream<String, Error> {
        switch (selection.provider, selection.claudeAuth, selection.openAIAuth) {
        case (.claude, .apiKey, _):
            claudeAPI.stream(prompt, model: selection.claudeModel.rawValue)
        case (.claude, .account, _):
            claudeCode.stream(prompt, model: selection.claudeModel.cliAlias)
        case (.openAI, _, .apiKey):
            openAIAPI.stream(prompt, model: selection.openAIModel)
        case (.openAI, _, .account):
            chatGPT.stream(prompt, model: selection.openAIModel)
        }
    }
}
