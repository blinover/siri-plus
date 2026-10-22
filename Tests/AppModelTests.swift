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
        #expect(request.model == .opus)
        service.complete("Второй ответ")
        await second.value
        #expect(model.messages.count == 4)
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
        #expect(model.errorMessage?.contains("ключ") == true)
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

    @Test func apiKeyIsStoredAndRemoved() throws {
        let keys = MemorySecretStore()
        let model = makeModel(keyStore: keys)
        #expect(!model.hasAPIKey)
        model.saveAPIKey("  sk-ant-test \n")
        #expect(model.hasAPIKey)
        #expect(try keys.read() == "sk-ant-test")
        model.deleteAPIKey()
        #expect(!model.hasAPIKey)
        #expect(try keys.read() == nil)
    }

    @Test func preferencesPersistAndCorruptDataFallsBack() throws {
        let suite = "dev.siriplus.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferencesStore(defaults: defaults)
        let preferences = AssistantPreferences(replyStyle: .detailed, showTimestamps: false, model: .haiku, hintMode: .manual)
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
        #expect(loaded.hintMode == .questionsAndTopic)
    }

    private func makeModel(
        assistant: any AssistantService & HintService = ControlledAssistant(),
        screenCapture: any ScreenCapturing = StubScreenCapture(),
        keyStore: any SecretStoring = MemorySecretStore()
    ) -> AppModel {
        AppModel(
            assistant: assistant,
            meetingService: FakeMeetingService(),
            screenCapture: screenCapture,
            preferencesStore: PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            keyStore: keyStore
        )
    }
}

/// Lets a test decide when and how each reply ends.
final class ControlledAssistant: AssistantService, HintService, @unchecked Sendable {
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
