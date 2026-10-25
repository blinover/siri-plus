import AppKit
import Testing
@testable import SiriPlusCore

@Suite @MainActor
struct AppModelTests {
    @Test func clearedConversationDiscardsLateResponse() async throws {
        let service = ControlledAssistant()
        let model = makeModel(assistant: service)
        let task = try #require(model.send("Первый вопрос"))
        await service.waitForRequest()

        model.draft = "Неотправленный текст"
        model.newConversation()
        service.complete("Устаревший ответ")
        await task.value

        #expect(model.messages.isEmpty)
        #expect(model.draft.isEmpty)
        #expect(!model.isReplying)
        #expect(model.errorMessage == nil)
    }

    @Test func requestsCarryContextAndRejectConcurrentSubmission() async throws {
        let service = ControlledAssistant()
        let model = makeModel(assistant: service)
        #expect(model.send(" \n ") == nil)

        let first = try #require(model.send("  Вопрос  \n"))
        await service.waitForRequest()
        #expect(model.send("Дубликат") == nil)
        service.complete("Первый ответ")
        await first.value

        let second = try #require(model.send("Уточнение"))
        let request = await service.waitForRequest()
        #expect(request.messages.map(\.text) == ["Вопрос", "Первый ответ", "Уточнение"])
        #expect(request.selection.claudeModel == .opus)
        service.complete("Второй ответ")
        await second.value
        #expect(model.messages.count == 4)
    }

    @Test func conversationAboutMeetingCarriesItUntilNewConversation() async throws {
        let service = ControlledAssistant()
        let model = makeModel(assistant: service)
        let meeting = MeetingRecord(startedAt: Date(), endedAt: Date(), turns: [], notes: "")
        _ = model.send("Старый вопрос")
        await service.waitForRequest()
        service.complete("Ответ")

        model.askAbout(meeting)
        #expect(model.messages.isEmpty)
        #expect(model.selectedTab == .chat)
        let task = try #require(model.send("Что решили?"))
        #expect(await service.waitForRequest().meeting?.id == meeting.id)
        service.complete("Переезд в ноябре")
        await task.value

        model.newConversation()
        #expect(model.chatMeeting == nil)
    }

    @Test func stoppedReplyKeepsReceivedText() async throws {
        let service = ControlledAssistant()
        let model = makeModel(assistant: service)
        let task = try #require(model.send("Вопрос"))
        await service.waitForRequest()
        service.yield("Начало ответа")
        try await eventually { model.partialReply == "Начало ответа" }

        model.stopReply()
        await task.value
        #expect(model.messages.map(\.text) == ["Вопрос", "Начало ответа"])
        #expect(!model.isReplying)
    }

    @Test func failedReplyShowsError() async throws {
        let service = ControlledAssistant()
        let model = makeModel(assistant: service)
        let task = try #require(model.send("Вопрос"))
        await service.waitForRequest()
        service.fail(ClaudeError.missingAPIKey)
        await task.value
        #expect(model.errorMessage?.contains("API key") == true)
        #expect(model.messages.count == 1)
    }

    @Test func snapshotIsSentWithNextMessageOnly() async throws {
        let service = ControlledAssistant()
        let model = makeModel(assistant: service)
        await model.captureScreen()
        #expect(model.snapshot != nil)

        let task = try #require(model.send("Что на экране?"))
        let request = await service.waitForRequest()
        #expect(request.messages.last?.imageJPEG == Data([1, 2, 3]))
        #expect(model.snapshot == nil)
        service.complete("Окно Xcode")
        await task.value
    }

    @Test func captureFailureIsVisibleAndRetryRecovers() async {
        let screen = StubScreenCapture()
        screen.shouldFail = true
        let model = makeModel(screenCapture: screen)
        await model.captureScreen()
        #expect(model.errorMessage != nil)
        #expect(model.snapshot == nil)
        #expect(!model.isCapturing)

        screen.shouldFail = false
        await model.captureScreen()
        #expect(model.errorMessage == nil)
        #expect(model.snapshot != nil)
        model.newConversation()
        #expect(model.snapshot == nil)
    }

    @Test func apiKeysAreStoredPerProvider() throws {
        var credentials = Credentials.inMemory()
        let claude = MemorySecretStore(), openAI = MemorySecretStore()
        credentials.claudeKey = claude
        credentials.openAIKey = openAI
        let model = makeModel(credentials: credentials)
        model.preferences.claudeAuth = .apiKey
        #expect(!model.isModelReady)

        model.saveAPIKey("  sk-ant-test \n", for: .claude)
        #expect(model.accounts.hasClaudeKey)
        #expect(!model.accounts.hasOpenAIKey)
        #expect(try claude.read() == "sk-ant-test")
        #expect(model.isModelReady)

        model.preferences.provider = .openAI
        model.preferences.openAIAuth = .apiKey
        #expect(!model.isModelReady)
        model.saveAPIKey("sk-openai", for: .openAI)
        #expect(model.isModelReady)
        model.deleteAPIKey(for: .claude)
        #expect(try claude.read() == nil)
        #expect(try openAI.read() == "sk-openai")
    }

    @Test func accountsReflectClaudeCodeSignIn() async {
        var credentials = Credentials.inMemory()
        credentials.claudeCodeStatus = { ClaudeCodeStatus(installed: true, signedIn: true, account: "me@example.com", subscription: "pro") }
        let model = makeModel(credentials: credentials)
        #expect(!model.isModelReady)
        await model.refreshAccounts()
        #expect(model.accounts.claudeCode.account == "me@example.com")
        #expect(model.isModelReady)
        #expect(model.accounts.chatGPTEmail == nil)
    }

    @Test func preferencesPersistAndCorruptDataFallsBack() throws {
        let suite = "dev.siriplus.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferencesStore(defaults: defaults)
        let preferences = AssistantPreferences(
            replyStyle: .detailed, showTimestamps: false, provider: .openAI, model: .haiku,
            claudeAuth: .apiKey, openAIModel: "gpt-6-luna", hintMode: .manual, transcriptionLocale: "en-US"
        )
        store.save(preferences)
        #expect(PreferencesStore(defaults: defaults).load() == preferences)

        defaults.set(Data("broken".utf8), forKey: "assistant.preferences.v1")
        #expect(store.load() == AssistantPreferences())
    }

    @Test func preferencesFromOlderVersionKeepTheirValues() throws {
        let suite = "dev.siriplus.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"replyStyle":"detailed","showTimestamps":false}"#.utf8), forKey: "assistant.preferences.v1")
        let loaded = PreferencesStore(defaults: defaults).load()
        #expect(loaded.replyStyle == .detailed)
        #expect(!loaded.showTimestamps)
        #expect(loaded.model == .opus)
        #expect(loaded.claudeAuth == .account)
        #expect(loaded.hintMode == .questionsAndTopic)
        #expect(loaded.transcriptionLocale == AssistantPreferences.systemLocale)
    }

    private func makeModel(
        assistant: any AssistantService & HintService & SummaryService = ControlledAssistant(),
        screenCapture: any ScreenCapturing = StubScreenCapture(),
        credentials: Credentials = .inMemory()
    ) -> AppModel {
        AppModel(
            assistant: assistant,
            meetingService: FakeMeetingService(),
            screenCapture: screenCapture,
            preferencesStore: PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            credentials: credentials,
            historyStore: MeetingHistoryStore(url: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")),
            chatStore: ChatHistoryStore(url: FileManager.default.temporaryDirectory.appending(path: "chats-\(UUID().uuidString).json")),
            microphoneUsage: NoMicrophoneUsage()
        )
    }
}

/// Lets a test decide when and how each reply ends.
final class ControlledAssistant: AssistantService, HintService, SummaryService, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private var pendingRequest: AssistantRequest?
    private var observer: CheckedContinuation<AssistantRequest, Never>?

    func reply(to request: AssistantRequest) -> AsyncThrowingStream<String, Error> {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let observer = lock.withLock {
            self.continuation = continuation
            self.pendingRequest = request
            defer { self.observer = nil }
            return self.observer
        }
        observer?.resume(returning: request)
        return stream
    }

    func hint(for request: HintRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func summary(for request: SummaryRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    @discardableResult
    func waitForRequest() async -> AssistantRequest {
        await withCheckedContinuation { observer in
            let pending = lock.withLock {
                if pendingRequest == nil { self.observer = observer }
                return pendingRequest
            }
            if let pending { observer.resume(returning: pending) }
        }
    }

    func yield(_ text: String) {
        _ = lock.withLock { continuation }?.yield(text)
    }

    func complete(_ text: String) {
        let continuation = lock.withLock {
            defer { self.continuation = nil; pendingRequest = nil }
            return self.continuation
        }
        continuation?.yield(text)
        continuation?.finish()
    }

    func fail(_ error: Error) {
        let continuation = lock.withLock {
            defer { self.continuation = nil; pendingRequest = nil }
            return self.continuation
        }
        continuation?.finish(throwing: error)
    }
}

extension Credentials {
    /// No keychain, no Claude Code process: everything signed out.
    static func inMemory() -> Credentials {
        Credentials(
            claudeKey: MemorySecretStore(),
            openAIKey: MemorySecretStore(),
            chatGPT: ChatGPTAccount(store: MemorySecretStore()),
            claudeCodeStatus: { ClaudeCodeStatus() },
            claudeUsage: { throw ClaudeCodeError.notInstalled }
        )
    }
}

final class MemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(_ value: String? = nil) { self.value = value }
    func read() throws -> String? { lock.withLock { value } }
    func save(_ value: String) throws { lock.withLock { self.value = value } }
    func delete() throws { lock.withLock { value = nil } }
}

@MainActor
final class StubScreenCapture: ScreenCapturing {
    var shouldFail = false

    func captureMainDisplay() async throws -> ScreenSnapshot {
        if shouldFail { throw ScreenCaptureError.noDisplay }
        return ScreenSnapshot(image: NSImage(size: NSSize(width: 8, height: 8)), createdAt: Date(), jpegData: Data([1, 2, 3]))
    }
}

@MainActor
func eventually(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else {
            Issue.record("Condition not met in time")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}
