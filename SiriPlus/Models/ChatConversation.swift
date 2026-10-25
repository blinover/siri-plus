import Foundation

/// A saved chat: its messages and, for display, a title from the first question.
struct ChatConversation: Identifiable, Equatable, Codable, Sendable {
    var id = UUID()
    var createdAt = Date()
    var updatedAt = Date()
    var messages: [ChatMessage] = []
    /// The finished meeting this chat asks about, if any.
    var meetingID: UUID?

    var title: String {
        let first = messages.first { $0.role == .user }
        let text = first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard !line.isEmpty else { return first?.attachments.first?.name ?? String(localized: "New Chat") }
        return line.count > 60 ? String(line.prefix(60)) + "…" : line
    }

    /// Case- and diacritic-insensitive search over the messages.
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return messages.contains { $0.text.localizedStandardContains(query) }
    }
}
