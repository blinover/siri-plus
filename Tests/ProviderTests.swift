import Foundation
import Testing
@testable import SiriPlusCore

@Suite
struct PromptTests {
    private let hintRequest = HintRequest(
        trigger: .question("сколько стоит"),
        transcript: "Them: сколько стоит",
        notes: "Цена: 100 ₽",
        previousHints: ["Назови\nцену"],
        selection: ModelSelection()
    )

    @Test func chatAboutMeetingCarriesItsTranscriptAndSummary() {
        var meeting = MeetingRecord(
            startedAt: Date(),
            endedAt: Date().addingTimeInterval(1_800),
            turns: [TranscriptTurn(id: UUID(), speaker: .them, startedAt: Date(), updatedAt: Date(), finalText: "бюджет утвердили", volatileText: "")],
            notes: "Повестка: бюджет"
        )
        meeting.title = "Бюджет"
        meeting.summary = "- Бюджет утверждён"
        meeting.tasks = [MeetingTask(owner: "Анна", text: "письмо")]
        let message = ChatMessage(role: .user, text: "Что решили?")
        let plain = AssistantPrompts.chat(.init(messages: [message], replyStyle: .brief, selection: ModelSelection()))
        #expect(!plain.cacheSystem)
        #expect(!plain.system.contains("<meeting>"))

        let prompt = AssistantPrompts.chat(.init(messages: [message], replyStyle: .brief, selection: ModelSelection(), meeting: meeting))
        #expect(prompt.cacheSystem)
        for part in ["Title: Бюджет", "lasted 30 min", "- Бюджет утверждён", "- Анна: письмо", "Повестка: бюджет", "<transcript>\nThem: бюджет утвердили\n</transcript>"] {
            #expect(prompt.system.contains(part), "\(part)")
        }
    }

    @Test func hintPromptCarriesTranscriptNotesAndPreviousHints() {
        let prompt = AssistantPrompts.hint(hintRequest, language: "Russian")
        #expect(prompt.cacheSystem)
        #expect(prompt.effort == "low")
        #expect(prompt.system.contains("<materials>\nЦена: 100 ₽\n</materials>"))
        #expect(prompt.system.contains("if it is unclear, in Russian"))
        let user = prompt.turns[0].text
        #expect(user.contains("<transcript>\nThem: сколько стоит\n</transcript>"))
        #expect(user.contains("- Назови цену"))
        #expect(user.contains("\"сколько стоит\""))
    }

    @Test func chatPromptFollowsStyleAndKeepsImages() {
        let messages = [ChatMessage(role: .user, text: "Что это?", imageJPEG: Data([1])), ChatMessage(role: .assistant, text: "Окно")]
        let prompt = AssistantPrompts.chat(
            AssistantRequest(messages: messages, replyStyle: .detailed, selection: ModelSelection()),
            language: "English"
        )
        #expect(prompt.effort == "medium")
        #expect(prompt.system.contains("reply in English"))
        #expect(prompt.turns.map(\.role) == [.user, .assistant])
        #expect(prompt.turns[0].imageJPEG == Data([1]))
    }

    @Test func requestsRouteToTheChosenBackend() async throws {
        let backends = (RecordingBackend(name: "claudeAPI"), RecordingBackend(name: "claudeCode"),
                        RecordingBackend(name: "openAIAPI"), RecordingBackend(name: "chatGPT"))
        let service = CloudAssistantService(claudeAPI: backends.0, claudeCode: backends.1, openAIAPI: backends.2, chatGPT: backends.3)
        func run(_ selection: ModelSelection) async throws -> String {
            var text = ""
            for try await part in service.hint(for: HintRequest(trigger: .manual, transcript: "", notes: "", previousHints: [], selection: selection)) {
                text += part
            }
            return text
        }
        #expect(try await run(ModelSelection(provider: .claude, claudeModel: .sonnet, claudeAuth: .account)) == "claudeCode:sonnet")
        #expect(try await run(ModelSelection(provider: .claude, claudeModel: .sonnet, claudeAuth: .apiKey)) == "claudeAPI:claude-sonnet-5-5")
        #expect(try await run(ModelSelection(provider: .openAI, openAIModel: "gpt-6-luna", openAIAuth: .apiKey)) == "openAIAPI:gpt-6-luna")
        #expect(try await run(ModelSelection(provider: .openAI, openAIModel: "gpt-x", openAIAuth: .account)) == "chatGPT:gpt-x")
    }
}

@Suite
struct ClaudeAPITests {
    private func events(_ lines: [String]) throws -> [ClaudeStreamDecoder.Event] {
        var decoder = ClaudeStreamDecoder()
        var result: [ClaudeStreamDecoder.Event] = []
        for line in lines {
            if let event = try decoder.consume(line: line) { result.append(event) }
        }
        return result
    }

    @Test func decodesTextAndIgnoresOtherBlocks() throws {
        let decoded = try events([
            "event: message_start", #"data: {"type":"message_start","message":{"id":"msg_1"}}"#, "",
            "event: content_block_start", #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#, "",
            "event: content_block_delta", #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"При"}}"#, "",
            "event: content_block_delta", #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"вет"}}"#, "",
            "event: ping", #"data: {"type":"ping"}"#, "",
            "event: message_stop", #"data: {"type":"message_stop"}"#, "",
        ])
        #expect(decoded == [.text("При"), .text("вет"), .finished])
    }

    @Test func refusalAndErrorEventsThrow() {
        #expect(throws: ClaudeError.refused) {
            try events([#"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#, ""])
        }
        #expect(throws: ClaudeError.api(type: "overloaded_error", message: "Overloaded")) {
            try events([#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, ""])
        }
    }

    @Test func hintRequestUsesCachedSystemPromptAndFallback() throws {
        let prompt = AssistantPrompts.hint(HintRequest(trigger: .topic, transcript: "", notes: "Цена", previousHints: [], selection: ModelSelection()))
        let opus = try json(ClaudeAPIBackend.body(for: prompt, model: ClaudeModel.opus.rawValue))
        #expect(opus["model"] as? String == "claude-opus-5-5")
        #expect(opus["stream"] as? Bool == true)
        #expect(opus["fallbacks"] as? String == "default")
        #expect((opus["output_config"] as? [String: Any])?["effort"] as? String == "low")
        #expect(opus["temperature"] == nil)
        let system = try #require(opus["system"] as? [[String: Any]])
        #expect((system[0]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")

        let haiku = try json(ClaudeAPIBackend.body(for: prompt, model: ClaudeModel.haiku.rawValue))
        #expect(haiku["fallbacks"] == nil)
    }
}

@Suite
struct ClaudeCodeTests {
    @Test func streamsPartialTextAndIgnoresFinalDuplicate() {
        var decoder = ClaudeCodeStreamDecoder()
        let lines = [
            #"{"type":"system","subtype":"init"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Пар"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"иж"}}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Париж"}]}}"#,
            #"{"type":"result","subtype":"success","result":"Париж","is_error":false}"#,
        ]
        #expect(lines.compactMap { decoder.consume(line: $0) } == ["Пар", "иж"])
        #expect(decoder.resultError == nil)
    }

    @Test func usesResultWhenNoPartialTextAndReportsErrors() {
        var decoder = ClaudeCodeStreamDecoder()
        #expect(decoder.consume(line: #"{"type":"result","subtype":"success","result":"Да"}"#) == "Да")

        var failing = ClaudeCodeStreamDecoder()
        _ = failing.consume(line: #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Not logged in · Please run /login"}"#)
        #expect(failing.resultError == "Not logged in · Please run /login")
        #expect(ClaudeCodeBackend.normalize(failing.resultError!) == .notSignedIn)
    }

    @Test func inputTagsHistoryAndAttachesImages() throws {
        let prompt = PreparedPrompt(
            system: "s",
            turns: [.init(role: .user, text: "Что это?", imageJPEG: Data([1, 2])), .init(role: .assistant, text: "Окно"), .init(role: .user, text: "А это?")],
            effort: "low",
            maxTokens: 100
        )
        let object = try #require(JSONSerialization.jsonObject(with: ClaudeCodeBackend.input(for: prompt)) as? [String: Any])
        let message = try #require(object["message"] as? [String: Any])
        let content = try #require(message["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["image", "text", "text", "text"])
        #expect(content[1]["text"] as? String == "<user>\nЧто это?\n</user>")
        #expect(content[2]["text"] as? String == "<assistant>\nОкно\n</assistant>")

        let single = PreparedPrompt(system: "s", turns: [.init(role: .user, text: "Привет")], effort: "low", maxTokens: 100)
        let singleObject = try #require(JSONSerialization.jsonObject(with: ClaudeCodeBackend.input(for: single)) as? [String: Any])
        let singleContent = (singleObject["message"] as? [String: Any])?["content"] as? [[String: Any]]
        #expect(singleContent?.first?["text"] as? String == "Привет")
    }

    @Test func argumentsDisableToolsAndSessions() {
        let arguments = ClaudeCodeBackend.arguments(model: "haiku", effort: "low", systemPromptFile: "/tmp/p.txt")
        #expect(arguments.contains("--safe-mode"))
        #expect(arguments.contains("--no-session-persistence"))
        #expect(arguments[arguments.firstIndex(of: "--tools")! + 1] == "")
        #expect(arguments[arguments.firstIndex(of: "--model")! + 1] == "haiku")
        #expect(arguments[arguments.firstIndex(of: "--system-prompt-file")! + 1] == "/tmp/p.txt")
    }
}

@Suite
struct OpenAITests {
    @Test func decodesResponsesStream() throws {
        var decoder = ResponsesStreamDecoder()
        let lines = [
            "event: response.created", #"data: {"type":"response.created","response":{"id":"resp_1"}}"#, "",
            "event: response.output_text.delta", #"data: {"type":"response.output_text.delta","delta":"Hel"}"#,
            #"data: {"type":"response.output_text.delta","delta":"lo"}"#,
            #"data: {"type":"response.completed","response":{"id":"resp_1"}}"#,
        ]
        var events: [ResponsesStreamDecoder.Event] = []
        for line in lines {
            if let event = try decoder.consume(line: line) { events.append(event) }
        }
        #expect(events == [.text("Hel"), .text("lo"), .finished])
    }

    @Test func failedResponseThrowsItsMessage() {
        var decoder = ResponsesStreamDecoder()
        #expect(throws: OpenAIError.failed("Model overloaded")) {
            try decoder.consume(line: #"data: {"type":"response.failed","response":{"error":{"code":"server_error","message":"Model overloaded"}}}"#)
        }
        #expect(throws: OpenAIError.failed("Bad request")) {
            try decoder.consume(line: #"data: {"type":"error","message":"Bad request"}"#)
        }
    }

    @Test func requestUsesInstructionsAndTypedContent() throws {
        let prompt = PreparedPrompt(
            system: "Be brief.",
            turns: [.init(role: .user, text: "Что это?", imageJPEG: Data([1])), .init(role: .assistant, text: "Окно")],
            effort: "low",
            maxTokens: 100
        )
        let object = try json(ResponsesRequest(prompt: prompt, model: "gpt-6-luna"))
        #expect(object["model"] as? String == "gpt-6-luna")
        #expect(object["instructions"] as? String == "Be brief.")
        #expect(object["store"] as? Bool == false)
        #expect(object["stream"] as? Bool == true)
        #expect((object["reasoning"] as? [String: Any])?["effort"] as? String == "low")
        let input = try #require(object["input"] as? [[String: Any]])
        let first = try #require(input[0]["content"] as? [[String: Any]])
        #expect(first.map { $0["type"] as? String } == ["input_image", "input_text"])
        #expect(first[0]["image_url"] as? String == "data:image/jpeg;base64,AQ==")
        #expect((input[1]["content"] as? [[String: Any]])?.first?["type"] as? String == "output_text")
    }

    @Test func tokensExposeAccountAndExpiry() throws {
        func jwt(_ claims: [String: Any]) throws -> String {
            let payload = try JSONSerialization.data(withJSONObject: claims).base64URLEncoded
            return "e30.\(payload).sig"
        }
        let soon = Date().addingTimeInterval(60).timeIntervalSince1970
        let tokens = ChatGPTTokens(
            idToken: try jwt(["email": "me@example.com", "https://api.openai.com/auth": ["chatgpt_account_id": "acc_1"]]),
            accessToken: try jwt(["exp": soon]),
            refreshToken: "r"
        )
        #expect(tokens.email == "me@example.com")
        #expect(tokens.resolvedAccountID == "acc_1")
        #expect(tokens.accessTokenExpires(within: 5 * 60))
        #expect(!tokens.accessTokenExpires(within: 10))
    }

    @Test func formEncodingEscapesReservedCharacters() {
        #expect(ChatGPTAccount.formEncoded(["code": "a+b/c=d&e", "grant_type": "authorization_code"])
                == "code=a%2Bb%2Fc%3Dd%26e&grant_type=authorization_code")
    }

    @Test func accountBackendRequiresSignIn() async {
        let backend = ChatGPTAccountBackend(account: ChatGPTAccount(store: MemorySecretStore()))
        await #expect(throws: OpenAIError.notSignedIn) {
            for try await _ in backend.stream(PreparedPrompt(system: "", turns: [], effort: "low", maxTokens: 1), model: "gpt-x") {}
        }
    }
}

private func json(_ value: some Encodable) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
}

/// Answers with its name and the model it was asked for.
private struct RecordingBackend: ModelBackend {
    let name: String

    func stream(_ prompt: PreparedPrompt, model: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("\(name):\(model)")
            continuation.finish()
        }
    }
}
