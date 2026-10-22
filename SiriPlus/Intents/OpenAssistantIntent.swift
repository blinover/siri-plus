import AppIntents

struct OpenAssistantIntent: AppIntent {
    static let title: LocalizedStringResource = "Открыть помощника"
    static let description = IntentDescription("Открывает приложение Siri+.")
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct AssistantShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenAssistantIntent(),
            phrases: ["Открой \(.applicationName)", "Open \(.applicationName)"],
            shortTitle: "Открыть помощника",
            systemImageName: "sparkles"
        )
    }
}
