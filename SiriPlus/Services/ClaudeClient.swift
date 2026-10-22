import Foundation

enum ClaudeError: LocalizedError, Equatable {
    case missingAPIKey
    case http(status: Int, message: String)
    case api(type: String, message: String)
    case refused
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Добавьте ключ Claude API в Настройках."
        case .http(401, _):
            "Ключ Claude API не принят. Проверьте его в Настройках."
        case .http(429, _):
            "Превышен лимит запросов к Claude API. Подождите немного."
        case .http(let status, let message):
            "Claude API вернул ошибку \(status): \(message)"
        case .api(let type, let message):
            "Claude API: \(message) (\(type))"
        case .refused:
            "Модель отказалась отвечать на этот запрос."
        case .invalidResponse:
            "Не удалось прочитать ответ Claude API."
        }
    }
}

/// Request body for `POST /v1/messages`.
struct ClaudeMessagesRequest: Encodable, Sendable {
    struct CacheControl: Encodable, Sendable {
        var type = "ephemeral"
    }

    struct ContentBlock: Encodable, Sendable {
        struct ImageSource: Encodable, Sendable {
            var type = "base64"
            let mediaType: String
            let data: String

            enum CodingKeys: String, CodingKey {
                case type
                case mediaType = "media_type"
                case data
            }
        }

        let type: String
        var text: String?
        var source: ImageSource?
        var cacheControl: CacheControl?

        enum CodingKeys: String, CodingKey {
            case type, text, source
            case cacheControl = "cache_control"
        }

        static func text(_ text: String, cached: Bool = false) -> ContentBlock {
            ContentBlock(type: "text", text: text, cacheControl: cached ? CacheControl() : nil)
        }

        static func jpeg(_ data: Data) -> ContentBlock {
            ContentBlock(type: "image", source: ImageSource(mediaType: "image/jpeg", data: data.base64EncodedString()))
        }
    }

    struct Message: Encodable, Sendable {
        let role: String
        let content: [ContentBlock]
    }

    struct OutputConfig: Encodable, Sendable {
        let effort: String
    }

    let model: String
    let maxTokens: Int
    let system: [ContentBlock]
    let messages: [Message]
    let outputConfig: OutputConfig
    var fallbacks: String?
    var stream = true

    enum CodingKeys: String, CodingKey {
        case model, system, messages, fallbacks, stream
        case maxTokens = "max_tokens"
        case outputConfig = "output_config"
    }
}

/// Minimal Server-Sent Events reader for the Messages streaming format.
struct ClaudeStreamDecoder {
    enum Event: Equatable {
        case text(String)
        case finished
    }

    private var eventName: String?
    private var dataLines: [String] = []

    /// Feeds one line of the stream. Returns an event when a blank line completes one.
    mutating func consume(line: String) throws -> Event? {
        if line.isEmpty {
            defer { eventName = nil; dataLines = [] }
            guard !dataLines.isEmpty else { return nil }
            return try decode(dataLines.joined(separator: "\n"))
        }
        if line.hasPrefix("event:") {
            eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Flushes an event left without a trailing blank line.
    mutating func finish() throws -> Event? {
        try consume(line: "")
    }

    private func decode(_ data: String) throws -> Event? {
        guard let object = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
              let type = object["type"] as? String else {
            throw ClaudeError.invalidResponse
        }
        switch type {
        case "content_block_delta":
            let delta = object["delta"] as? [String: Any]
            guard delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String else { return nil }
            return .text(text)
        case "message_delta":
            let delta = object["delta"] as? [String: Any]
            if delta?["stop_reason"] as? String == "refusal" { throw ClaudeError.refused }
            return nil
        case "message_stop":
            return .finished
        case "error":
            let error = object["error"] as? [String: Any]
            throw ClaudeError.api(
                type: error?["type"] as? String ?? "error",
                message: error?["message"] as? String ?? "неизвестная ошибка"
            )
        default:
            // message_start, ping, content_block_start/stop (including thinking and
            // server-side fallback markers) carry no user-visible text.
            return nil
        }
    }
}

struct ClaudeClient: Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2026-10-21"
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    let apiKey: String
    var session: URLSession = .shared

    /// Streams text deltas of the reply.
    func streamText(_ body: ClaudeMessagesRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: Self.endpoint)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 120
                    request.setValue("application/json", forHTTPHeaderField: "content-type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
                    if body.fallbacks != nil {
                        request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
                    }
                    request.httpBody = try JSONEncoder().encode(body)

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw ClaudeError.invalidResponse }
                    guard http.statusCode == 200 else {
                        var raw = Data()
                        for try await byte in bytes { raw.append(byte) }
                        throw ClaudeError.http(status: http.statusCode, message: Self.errorMessage(from: raw))
                    }

                    var decoder = ClaudeStreamDecoder()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        _ = try decoder.consume(line: line)
                        // `lines` drops the blank separators, so each data line completes an event.
                        if line.hasPrefix("data:"), case .text(let text)? = try decoder.finish() {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(data: data.prefix(300), encoding: .utf8) ?? "пустой ответ"
    }
}
