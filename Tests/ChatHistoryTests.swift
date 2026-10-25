import Foundation
import Testing
@testable import SiriPlusCore

@Suite @MainActor
struct ChatHistoryTests {
    private let storeURL = FileManager.default.temporaryDirectory.appending(path: "siriplus-chats-\(UUID().uuidString)/chats.json")

    private func makeModel(assistant: ControlledAssistant, history: MeetingHistoryStore? = nil) -> AppModel {
        AppModel(
            assistant: assistant,
            meetingService: FakeMeetingService(),
            screenCapture: StubScreenCapture(),
            preferencesStore: PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            credentials: .inMemory(),
            historyStore: history ?? MeetingHistoryStore(url: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")),
            chatStore: ChatHistoryStore(url: storeURL),
            microphoneUsage: NoMicrophoneUsage()
        )
    }

    @Test func chatsAreSavedAndReopened() async throws {
        let service = ControlledAssistant()
        let model = makeModel(assistant: service)
        let task = try #require(model.send("Как дела?"))
        await service.waitForRequest()
        service.complete("Отлично")
        await task.value

        let id = try #require(model.currentChatID)
        #expect(model.chats.conversations.first?.title == "Как дела?")
        #expect(model.chats.conversations.first?.messages.map(\.text) == ["Как дела?", "Отлично"])

        model.newConversation()
        #expect(model.messages.isEmpty)
        #expect(model.currentChatID == nil)

        model.openChat(id)
        #expect(model.messages.map(\.text) == ["Как дела?", "Отлично"])

        // A follow-up continues the same chat instead of starting a new one.
        let followUp = try #require(model.send("А погода?"))
        await service.waitForRequest()
        service.complete("Солнечно")
        await followUp.value
        #expect(model.chats.conversations.count == 1)
        #expect(model.chats.conversations.first?.messages.count == 4)
    }

    @Test func chatsSurviveRestartAndCanBeDeleted() async throws {
        let service = ControlledAssistant()
        let model = makeModel(assistant: service)
        let task = try #require(model.send("Сохрани меня"))
        await service.waitForRequest()
        service.complete("Сохранено")
        await task.value

        let reloaded = makeModel(assistant: ControlledAssistant())
        let saved = try #require(reloaded.chats.conversations.first)
        #expect(saved.messages.map(\.text) == ["Сохрани меня", "Сохранено"])

        reloaded.openChat(saved.id)
        reloaded.deleteChat(saved.id)
        #expect(reloaded.chats.conversations.isEmpty)
        #expect(reloaded.messages.isEmpty)
        #expect(makeModel(assistant: ControlledAssistant()).chats.conversations.isEmpty)
    }

    @Test func titlesAndSearch() {
        var conversation = ChatConversation()
        #expect(conversation.title == "New Chat")
        conversation.messages = [ChatMessage(role: .user, text: "Первая строка\nвторая"), ChatMessage(role: .assistant, text: "Ответ про Kubernetes")]
        #expect(conversation.title == "Первая строка")
        #expect(conversation.matches("kubernetes"))
        #expect(!conversation.matches("docker"))
        let long = ChatConversation(messages: [ChatMessage(role: .user, text: String(repeating: "а", count: 80))])
        #expect(long.title.count == 61)
    }

    @Test func expiredChatsAreRemoved() throws {
        let store = ChatHistoryStore(url: storeURL)
        var old = ChatConversation(messages: [ChatMessage(role: .user, text: "старый")])
        old.updatedAt = Date(timeIntervalSinceNow: -40 * 24 * 3600)
        try store.save([old])
        let history = ChatHistory(store: store) { AssistantPreferences(historyRetentionDays: 30) }
        #expect(history.conversations.isEmpty)
    }
}
