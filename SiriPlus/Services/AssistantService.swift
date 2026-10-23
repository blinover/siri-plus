import Foundation

struct AssistantRequest: Sendable {
    let messages: [ChatMessage]
    let replyStyle: ReplyStyle
    let selection: ModelSelection
    /// A finished meeting the conversation is about.
    var meeting: MeetingRecord?
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

struct SummaryRequest: Sendable, Equatable {
    let transcript: String
    let notes: String
    let selection: ModelSelection
}

protocol SummaryService: Sendable {
    /// Streams the title, participants, summary and tasks of a finished meeting, parsed by `MeetingSummary`.
    func summary(for request: SummaryRequest) -> AsyncThrowingStream<String, Error>
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
        var system = """
        You are Siri+, the user's personal assistant on their Mac. Reply in the language the user writes in; if it is unclear, reply in \(language). \(style)
        If a screenshot is attached to a message, it shows the user's screen at the moment of the question: rely on what is visible on it.
        """
        if let meeting = request.meeting {
            system += "\n\n" + meetingContext(meeting)
        }
        return PreparedPrompt(
            system: system,
            turns: request.messages.map { .init(role: $0.role, text: $0.text, imageJPEG: $0.imageJPEG) },
            effort: request.replyStyle == .brief ? "low" : "medium",
            maxTokens: 32_000,
            // The transcript is resent with every question about the meeting.
            cacheSystem: request.meeting != nil
        )
    }

    static func meetingContext(_ meeting: MeetingRecord) -> String {
        var lines = [
            "The user asks about a finished work call. Answer from its transcript and summary below; if they do not contain the answer, say so instead of guessing. The transcript is automatic, has no punctuation and contains recognition errors. \"Me\" is the user, \"Them\" are the other participants.",
            "<meeting>",
            "Title: \(meeting.displayTitle)",
            "Started: \(meeting.startedAt.formatted(.iso8601)), lasted \(Int(meeting.endedAt.timeIntervalSince(meeting.startedAt) / 60)) min",
        ]
        if !meeting.participants.isEmpty { lines.append("Participants: \(meeting.participants.joined(separator: ", "))") }
        if !meeting.summary.isEmpty { lines.append("Summary:\n\(meeting.summary)") }
        if !meeting.tasks.isEmpty { lines.append("Tasks:\n" + meeting.tasks.map { "- \($0.line)" }.joined(separator: "\n")) }
        let notes = meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { lines.append("The user's materials for the meeting:\n\(notes)") }
        lines += ["<transcript>", meeting.promptTranscript, "</transcript>", "</meeting>"]
        return lines.joined(separator: "\n")
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

    static func summary(_ request: SummaryRequest, language: String = systemLanguageName) -> PreparedPrompt {
        var system = """
        You summarize a finished work call from its automatic transcript. The transcript has no punctuation and contains recognition errors, so reconstruct the meaning from context. "Me" is the user, "Them" are the other participants.

        Write in the language of the conversation (if it is unclear, in \(language)). Reply exactly in this format, without Markdown headings:
        TITLE: three to seven words naming what the meeting was about
        PARTICIPANTS: names of the people who spoke or were addressed, comma-separated, or "—" if no names are known
        SUMMARY:
        three to seven short bullet points starting with "- ": what was discussed and what was decided
        TASKS:
        one line per agreed action item: "- owner | what to do | deadline", with "—" for an unknown owner or deadline; a single "—" if there are no action items

        Do not invent facts or names that are not in the transcript or the materials.
        """
        let notes = request.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            system += "\n\nThe user's materials for this meeting:\n<materials>\n\(notes)\n</materials>"
        }
        return PreparedPrompt(
            system: system,
            turns: [.init(role: .user, text: "<transcript>\n\(request.transcript)\n</transcript>")],
            effort: "low",
            maxTokens: 4_000
        )
    }
}

/// Routes requests to the backend chosen in settings.
struct CloudAssistantService: AssistantService, HintService, SummaryService {
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

    func summary(for request: SummaryRequest) -> AsyncThrowingStream<String, Error> {
        route(AssistantPrompts.summary(request), selection: request.selection)
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
