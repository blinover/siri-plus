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
        #expect(prompt.turns[0].images == [Data([1])])
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
        #expect(try await run(ModelSelection(provider: .claude, claudeModel: "sonnet", claudeAuth: .account)) == "claudeCode:sonnet")
        #expect(try await run(ModelSelection(provider: .claude, claudeModel: "claude-sonnet-5-5", claudeAuth: .apiKey)) == "claudeAPI:claude-sonnet-5-5")
        #expect(try await run(ModelSelection(provider: .openAI, openAIModel: "gpt-6-luna", openAIAuth: .apiKey)) == "openAIAPI:gpt-6-luna")
        #expect(try await run(ModelSelection(provider: .openAI, openAIModel: "gpt-x", openAIAuth: .account)) == "chatGPT:gpt-x")
    }

    @Test func effortFollowsSettingsAndWhatTheModelAccepts() async throws {
        let backend = RecordingBackend(name: "claudeCode", reportsEffort: true)
        let catalog = ModelCatalog()
        catalog.update([
            ModelOption(id: "opus", title: "Opus 5.5", efforts: ModelEffort.claudeLevels),
            ModelOption(id: "claude-opus-4-6", title: "Opus 4.6", efforts: ["low", "medium", "high", "max"]),
            ModelOption(id: "claude-haiku-4-5", title: "Haiku 4.5", efforts: []),
        ], for: .claudeCode)
        let service = CloudAssistantService(claudeAPI: backend, claudeCode: backend, openAIAPI: backend, chatGPT: backend, catalog: catalog)
        func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
            var text = ""
            for try await part in stream { text += part }
            return text
        }
        func chat(_ model: String, effort: String, style: ReplyStyle = .brief) async throws -> String {
            let selection = ModelSelection(claudeModel: model, claudeEffort: effort)
            return try await collect(service.reply(to: AssistantRequest(messages: [ChatMessage(role: .user, text: "?")], replyStyle: style, selection: selection)))
        }
        func hint(_ model: String, effort: String) async throws -> String {
            let request = HintRequest(trigger: .manual, transcript: "", notes: "", previousHints: [], selection: ModelSelection(claudeModel: model, claudeEffort: effort))
            return try await collect(service.hint(for: request))
        }
        #expect(try await chat("opus", effort: ModelEffort.automatic) == "claudeCode:opus:low")
        #expect(try await chat("opus", effort: ModelEffort.automatic, style: .detailed) == "claudeCode:opus:medium")
        #expect(try await chat("opus", effort: "max") == "claudeCode:opus:max")
        // Hints stay quick whatever is chosen.
        #expect(try await hint("opus", effort: "max") == "claudeCode:opus:low")
        // Opus 4.6 has no xhigh: the nearest lighter level is sent.
        #expect(try await chat("claude-opus-4-6", effort: "xhigh") == "claudeCode:claude-opus-4-6:high")
        // A model without effort gets none; an unlisted model gets the level as is.
        #expect(try await chat("claude-haiku-4-5", effort: "high") == "claudeCode:claude-haiku-4-5:none")
        #expect(try await chat("claude-new", effort: "xhigh") == "claudeCode:claude-new:xhigh")
    }

    @Test func effortResolutionPicksTheNearestSupportedLevel() {
        #expect(ModelEffort.resolve(chosen: "auto", preferred: "medium", isLive: false, supported: ["low", "high"]) == "low")
        #expect(ModelEffort.resolve(chosen: "max", preferred: "low", isLive: false, supported: ["minimal", "low", "medium", "high"]) == "high")
        #expect(ModelEffort.resolve(chosen: "max", preferred: "low", isLive: true, supported: ["minimal", "low"]) == "low")
        #expect(ModelEffort.resolve(chosen: "high", preferred: "low", isLive: false, supported: []) == nil)
        #expect(ModelEffort.resolve(chosen: "high", preferred: "low", isLive: false, supported: nil) == "high")
    }
}

@Suite
struct ModelListTests {
    @Test func claudeCodeListsItsModelsWithEfforts() throws {
        let line = #"{"type":"control_response","response":{"subtype":"success","request_id":"siriplus-models","response":{"models":[{"value":"default","displayName":"Default (recommended)","description":"Opus 5.5 · Best for everyday, complex tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},{"value":"claude-opus-4-6","displayName":"Opus 4.6","supportsEffort":true,"supportedEffortLevels":["low","medium","high","max"]},{"value":"claude-haiku-4-5-20251001","displayName":"Haiku 4.5"},{"value":"default","displayName":"Duplicate"}]}}}"#
        let models = try #require(try ClaudeCodeBackend.parseModels(controlResponse: line))
        #expect(models.map(\.id) == ["default", "claude-opus-4-6", "claude-haiku-4-5-20251001"])
        #expect(models[0].title == "Default (recommended)")
        #expect(models[0].detail == "Opus 5.5 · Best for everyday, complex tasks")
        #expect(models[1].efforts == ["low", "medium", "high", "max"])
        #expect(models[2].efforts == [])
        #expect(try ClaudeCodeBackend.parseModels(controlResponse: #"{"type":"system","subtype":"init"}"#) == nil)
        #expect(throws: ClaudeCodeError.failed("Not logged in")) {
            try ClaudeCodeBackend.parseModels(controlResponse: #"{"type":"control_response","response":{"subtype":"error","request_id":"siriplus-models","error":"Not logged in"}}"#)
        }
    }

    @Test func claudeAPIListsModelsWithEffortCapabilities() throws {
        let data = Data(#"""
        {"data":[
          {"id":"claude-opus-5-5","display_name":"Claude Opus 5.5","capabilities":{"effort":{"supported":true,"low":{"supported":true},"medium":{"supported":true},"high":{"supported":true},"xhigh":{"supported":true},"max":{"supported":true}}}},
          {"id":"claude-haiku-4-5","display_name":"Claude Haiku 4.5","capabilities":{"effort":{"supported":false,"low":{"supported":false}}}},
          {"id":"claude-old","display_name":"Old"}
        ],"has_more":false}
        """#.utf8)
        let models = try ClaudeClient.parseModels(data)
        #expect(models.map(\.title) == ["Claude Opus 5.5", "Claude Haiku 4.5", "Old"])
        #expect(models[0].efforts == ModelEffort.claudeLevels)
        #expect(models[1].efforts == [])
        #expect(models[2].efforts == nil)
    }

    @Test func chatGPTListsVisibleModelsWithReasoningLevels() {
        let models = ChatGPTAccount.parseModels([
            ["slug": "gpt-x", "display_name": "GPT X", "supported_reasoning_levels": [["effort": "low"], ["effort": "medium"], ["effort": "xhigh"]]],
            ["slug": "gpt-hidden", "visibility": "hide"],
            ["slug": "gpt-plain"],
        ])
        #expect(models.map(\.id) == ["gpt-x", "gpt-plain"])
        #expect(models[0].efforts == ["low", "medium", "xhigh"])
        #expect(models[1].efforts == nil)
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
        let opus = try json(ClaudeAPIBackend.body(for: prompt, model: "claude-opus-5-5"))
        #expect(opus["model"] as? String == "claude-opus-5-5")
        #expect(opus["stream"] as? Bool == true)
        #expect(opus["fallbacks"] as? String == "default")
        #expect((opus["output_config"] as? [String: Any])?["effort"] as? String == "low")
        #expect(opus["temperature"] == nil)
        let system = try #require(opus["system"] as? [[String: Any]])
        #expect((system[0]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")

        let haiku = try json(ClaudeAPIBackend.body(for: prompt, model: "claude-haiku-5-5"))
        #expect(haiku["fallbacks"] == nil)

        var noEffort = prompt
        noEffort.effort = nil
        #expect(try json(ClaudeAPIBackend.body(for: noEffort, model: "claude-haiku-4-5"))["output_config"] == nil)
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
            turns: [.init(role: .user, text: "Что это?", images: [Data([1, 2])]), .init(role: .assistant, text: "Окно"), .init(role: .user, text: "А это?")],
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
        #expect(arguments[arguments.firstIndex(of: "--effort")! + 1] == "low")
        #expect(!ClaudeCodeBackend.arguments(model: "haiku", effort: nil, systemPromptFile: "/tmp/p.txt").contains("--effort"))
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
            turns: [.init(role: .user, text: "Что это?", images: [Data([1])]), .init(role: .assistant, text: "Окно")],
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

        var noEffort = prompt
        noEffort.effort = nil
        #expect(try json(ResponsesRequest(prompt: noEffort, model: "gpt-plain"))["reasoning"] == nil)
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

/// Answers with its name, the model it was asked for and, when asked, the effort it got.
private struct RecordingBackend: ModelBackend {
    let name: String
    var reportsEffort = false

    func stream(_ prompt: PreparedPrompt, model: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(reportsEffort ? "\(name):\(model):\(prompt.effort ?? "none")" : "\(name):\(model)")
            continuation.finish()
        }
    }
}
