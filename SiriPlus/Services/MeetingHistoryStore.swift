import Foundation

/// Keeps finished meetings in one JSON file in Application Support. Nothing leaves the Mac.
struct MeetingHistoryStore: Sendable {
    let url: URL

    init(url: URL = URL.applicationSupportDirectory.appending(path: "SiriPlus/meetings.json")) {
        self.url = url
    }

    func load() throws -> [MeetingRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([MeetingRecord].self, from: Data(contentsOf: url))
    }

    func save(_ records: [MeetingRecord]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: url, options: .atomic)
    }

    /// Moves an unreadable file out of the way so the next save does not overwrite it.
    func setAside() throws -> URL {
        let backup = url.deletingLastPathComponent()
            .appending(path: "meetings-unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try FileManager.default.moveItem(at: url, to: backup)
        return backup
    }
}
