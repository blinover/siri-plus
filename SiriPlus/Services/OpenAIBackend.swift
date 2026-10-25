import Foundation

enum OpenAIError: LocalizedError, Equatable {
    case missingAPIKey
    case notSignedIn
    case noModel
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: String(localized: "Add an API key in Settings.")
        case .notSignedIn: String(localized: "Sign in to your ChatGPT account in Settings.")
        case .noModel: String(localized: "Choose a ChatGPT model in Settings.")
        case .failed(let message): message
        }
    }
}

/// Request body for the Responses API, shared by the OpenAI API and the ChatGPT (Codex) backend.
struct ResponsesRequest: Encodable, Sendable {
    struct Content: Encodable, Sendable {
        let type: String
        var text: String?
        var imageURL: String?

        enum CodingKeys: String, CodingKey {
            case type, text
            case imageURL = "image_url"
        }
    }

    struct Message: Encodable, Sendable {
        var type = "message"
        let role: String
        let content: [Content]
    }

    struct Reasoning: Encodable, Sendable {
        let effort: String
    }

    let model: String
    let instructions: String
    let input: [Message]
    let reasoning: Reasoning
    var stream = true
    /// The ChatGPT backend requires responses not to be stored.
    var store = false

    init(prompt: PreparedPrompt, model: String) {
        self.model = model
        instructions = prompt.system
        reasoning = Reasoning(effort: prompt.effort)
        input = prompt.turns.map { turn in
            var content: [Content] = []
            if turn.role == .user {
                for image in turn.images {
                    content.append(Content(type: "input_image", imageURL: "data:image/jpeg;base64,\(image.base64EncodedString())"))
                }
                content.append(Content(type: "input_text", text: turn.text))
            } else {
                content.append(Content(type: "output_text", text: turn.text))
            }
            return Message(role: turn.role.rawValue, content: content)
        }
    }
}

/// Reads Responses API server-sent events.
struct ResponsesStreamDecoder {
    enum Event: Equatable {
        case text(String)
        case finished
    }

    mutating func consume(line: String) throws -> Event? {
        guard line.hasPrefix("data:") else { return nil }
        let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard data != "[DONE]",
              let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "response.output_text.delta", "response.refusal.delta":
            return (object["delta"] as? String).map(Event.text)
        case "response.completed", "response.incomplete":
            return .finished
        case "response.failed":
            let response = object["response"] as? [String: Any]
            let error = response?["error"] as? [String: Any]
            throw OpenAIError.failed(error?["message"] as? String ?? String(localized: "The model could not complete the request."))
        case "error":
            let nested = object["error"] as? [String: Any]
            throw OpenAIError.failed(object["message"] as? String ?? nested?["message"] as? String ?? String(localized: "The model could not complete the request."))
        default:
            return nil
        }
    }
}

struct ResponsesClient: Sendable {
    let endpoint: URL
    let headers: [String: String]
    var session: URLSession = .shared

    /// Streams text; throws `ClaudeError.http` for HTTP failures so 401 can trigger a token refresh.
    func streamText(_ body: ResponsesRequest, onText: @Sendable (String) -> Void) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeError.invalidResponse }
        guard http.statusCode == 200 else {
            var raw = Data()
            for try await byte in bytes { raw.append(byte) }
            throw ClaudeError.http(status: http.statusCode, message: ClaudeClient.errorMessage(from: raw))
        }
        var decoder = ResponsesStreamDecoder()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            switch try decoder.consume(line: line) {
            case .text(let text): onText(text)
            case .finished: return
            case nil: continue
            }
        }
    }
}

/// ChatGPT models through the OpenAI API with an API key.
struct OpenAIAPIBackend: ModelBackend {
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    let keyStore: any SecretStoring

    func stream(_ prompt: PreparedPrompt, model: String) -> AsyncThrowingStream<String, Error> {
        let keyStore = keyStore
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let key = try keyStore.read()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
                        throw OpenAIError.missingAPIKey
                    }
                    let model = model.isEmpty ? OpenAIModelOption.apiModels[1].id : model
                    let client = ResponsesClient(endpoint: Self.endpoint, headers: ["Authorization": "Bearer \(key)"])
                    try await client.streamText(ResponsesRequest(prompt: prompt, model: model)) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// ChatGPT models through the user's ChatGPT account, the same backend Codex uses.
struct ChatGPTAccountBackend: ModelBackend {
    let account: ChatGPTAccount

    func stream(_ prompt: PreparedPrompt, model: String) -> AsyncThrowingStream<String, Error> {
        let account = account
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var model = model
                    if model.isEmpty {
                        guard let first = try await account.models().first?.id else { throw OpenAIError.noModel }
                        model = first
                    }
                    let body = ResponsesRequest(prompt: prompt, model: model)
                    do {
                        try await account.client().streamText(body) { continuation.yield($0) }
                    } catch ClaudeError.http(status: 401, _) {
                        // The access token may have been revoked early; refresh once and retry.
                        try await account.refresh()
                        try await account.client().streamText(body) { continuation.yield($0) }
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
