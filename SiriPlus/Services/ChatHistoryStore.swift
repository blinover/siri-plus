import Foundation

/// Keeps saved chats in one JSON file in Application Support. Nothing leaves the Mac.
struct ChatHistoryStore: Sendable {
    let url: URL

    init(url: URL = URL.applicationSupportDirectory.appending(path: "SiriPlus/chats.json")) {
        self.url = url
    }

    func load() throws -> [ChatConversation] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ChatConversation].self, from: Data(contentsOf: url))
    }

    func save(_ conversations: [ChatConversation]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(conversations).write(to: url, options: .atomic)
    }
}
