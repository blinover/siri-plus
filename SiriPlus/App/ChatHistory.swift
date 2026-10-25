import Combine
import Foundation

/// Saved chats, newest first, stored on this Mac and trimmed to the retention period in Settings.
@MainActor
final class ChatHistory: ObservableObject {
    @Published private(set) var conversations: [ChatConversation] = []
    @Published var errorMessage: String?

    private let store: ChatHistoryStore
    private let preferences: () -> AssistantPreferences
    /// False when an unreadable file could not be loaded: saving would overwrite it.
    private var canSave = true

    init(store: ChatHistoryStore, preferences: @escaping () -> AssistantPreferences) {
        self.store = store
        self.preferences = preferences
        do {
            conversations = try store.load().sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            canSave = false
            errorMessage = String(localized: "The chat history could not be read, so new chats are not saved. File: \(store.url.path)")
        }
        removeExpired()
    }

    func conversation(_ id: UUID) -> ChatConversation? {
        conversations.first { $0.id == id }
    }

    /// Saves the conversation and moves it to the top.
    func upsert(_ conversation: ChatConversation) {
        var conversation = conversation
        conversation.updatedAt = Date()
        conversations.removeAll { $0.id == conversation.id }
        conversations.insert(conversation, at: 0)
        save()
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        save()
    }

    /// Deletes chats untouched for longer than the retention period in Settings.
    func removeExpired(now: Date = Date()) {
        let days = preferences().historyRetentionDays
        guard days > 0, let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else { return }
        let before = conversations.count
        conversations.removeAll { $0.updatedAt < cutoff }
        if conversations.count != before { save() }
    }

    private func save() {
        guard canSave else { return }
        do {
            try store.save(conversations)
        } catch {
            errorMessage = String(localized: "The chat history was not saved. \(error.localizedDescription)")
        }
    }
}
