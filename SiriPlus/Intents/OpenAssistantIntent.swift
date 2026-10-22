import AppIntents

struct OpenAssistantIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Assistant"
    static let description = IntentDescription("Opens the Siri+ app.")
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct AssistantShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenAssistantIntent(),
            phrases: ["Open \(.applicationName)"],
            shortTitle: "Open Assistant",
            systemImageName: "sparkles"
        )
    }
}
