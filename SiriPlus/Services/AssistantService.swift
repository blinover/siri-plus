import Foundation

struct AssistantRequest: Sendable {
    let messages: [ChatMessage]
    let replyStyle: ReplyStyle
    let model: ClaudeModel
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
    let model: ClaudeModel
}

protocol HintService: Sendable {
    /// Streams a short meeting hint. A reply of "—" means no hint is needed.
    func hint(for request: HintRequest) -> AsyncThrowingStream<String, Error>
}

/// Sends chat and hint requests to Claude. Only this type talks to the network.
struct ClaudeAssistantService: AssistantService, HintService {
    let keyStore: any SecretStoring

    init(keyStore: any SecretStoring = KeychainStore()) {
        self.keyStore = keyStore
    }

    func reply(to request: AssistantRequest) -> AsyncThrowingStream<String, Error> {
        let style = request.replyStyle == .brief
            ? "Отвечай кратко: 1–4 предложения или короткий список."
            : "Отвечай подробно и структурированно, с примерами, если они помогают."
        let system = """
        Ты — Siri+, личный помощник пользователя на Mac. Отвечай на языке пользователя, по умолчанию по-русски. \(style)
        Если к сообщению приложен снимок экрана, это экран пользователя в момент вопроса: опирайся на то, что на нём видно.
        """
        let messages = request.messages.map { message in
            var content: [ClaudeMessagesRequest.ContentBlock] = []
            if let image = message.imageJPEG { content.append(.jpeg(image)) }
            content.append(.text(message.text))
            return ClaudeMessagesRequest.Message(role: message.role.rawValue, content: content)
        }
        return stream(ClaudeMessagesRequest(
            model: request.model.rawValue,
            maxTokens: 32_000,
            system: [.text(system)],
            messages: messages,
            outputConfig: .init(effort: request.replyStyle == .brief ? "low" : "medium"),
            fallbacks: request.model.supportsDefaultFallback ? "default" : nil
        ))
    }

    func hint(for request: HintRequest) -> AsyncThrowingStream<String, Error> {
        stream(ClaudeMessagesRequest(
            model: request.model.rawValue,
            maxTokens: 4_000,
            // Instructions and notes stay the same for the whole meeting, so they are cached.
            system: [.text(Self.hintSystemPrompt(notes: request.notes), cached: true)],
            messages: [.init(role: "user", content: [.text(Self.hintUserPrompt(request))])],
            outputConfig: .init(effort: "low"),
            fallbacks: request.model.supportsDefaultFallback ? "default" : nil
        ))
    }

    static func hintSystemPrompt(notes: String) -> String {
        var prompt = """
        Ты — незаметный помощник пользователя во время рабочего созвона в Zoom или Teams. Пользователь читает подсказку краем глаза, пока слушает собеседника, поэтому у него 2–3 секунды.

        Как отвечать:
        - На языке разговора, очень коротко: не больше трёх пунктов, каждый в одну строку.
        - Сразу суть: что ответить или сказать. Без вступлений и без пересказа вопроса.
        - Когда уместно, дай конкретику: факт, цифру, аргумент или уточняющий вопрос собеседнику.
        - Расшифровка автоматическая и без знаков препинания, в ней бывают ошибки распознавания: восстанавливай смысл по контексту. «Я» — пользователь, «Собеседник» — другие участники.
        - Не придумывай факты о пользователе, его компании и проекте, которых нет в материалах. Если их не хватает, предложи, как сформулировать ответ в общем виде.
        - Если подсказка сейчас не нужна — нет вопроса и нечего добавить по теме, — ответь одним символом «—».
        """
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            prompt += "\n\nМатериалы пользователя к встрече:\n<materials>\n\(trimmed)\n</materials>"
        }
        return prompt
    }

    static func hintUserPrompt(_ request: HintRequest) -> String {
        var prompt = "<transcript>\n\(request.transcript)\n</transcript>\n\n"
        if !request.previousHints.isEmpty {
            prompt += "Уже подсказано, не повторяй:\n"
            prompt += request.previousHints.map { "- \($0.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n")
            prompt += "\n\n"
        }
        switch request.trigger {
        case .question(let question):
            prompt += "Собеседник, похоже, задал вопрос: «\(question)». Подскажи, что ответить."
        case .topic:
            prompt += "Подскажи по текущей теме разговора: что полезно сказать, спросить или уточнить."
        case .manual:
            prompt += "Пользователь просит подсказку прямо сейчас. Помоги ответить на последний вопрос или продолжить текущую тему."
        }
        return prompt
    }

    private func stream(_ body: ClaudeMessagesRequest) -> AsyncThrowingStream<String, Error> {
        let keyStore = keyStore
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let key = try keyStore.read()?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !key.isEmpty else {
                        throw ClaudeError.missingAPIKey
                    }
                    for try await text in ClaudeClient(apiKey: key).streamText(body) {
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
