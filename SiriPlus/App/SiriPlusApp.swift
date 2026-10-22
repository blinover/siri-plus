import SwiftUI

@main
struct SiriPlusApp: App {
    @StateObject private var model: AppModel
    @State private var overlay: HintOverlay

    init() {
        let model = AppModel()
        let overlay = HintOverlay(model: model)
        model.showHintPanel = { overlay.show() }
        _model = StateObject(wrappedValue: model)
        _overlay = State(initialValue: overlay)
    }

    var body: some Scene {
        // LSUIElement keeps the app out of the Dock; the menu bar item is its home.
        Window("Siri+", id: "assistant") {
            WorkspaceView(model: model)
        }
        .defaultSize(width: 1080, height: 760)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            AssistantMenu(model: model, meeting: model.meeting, overlay: overlay)
        } label: {
            MenuBarLabel(isRecording: model.meeting.isRunning, overlay: overlay)
        }
    }
}

private struct MenuBarLabel: View {
    let isRecording: Bool
    let overlay: HintOverlay
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: isRecording ? "waveform.circle.fill" : "sparkles")
            .accessibilityLabel(isRecording ? "Siri+ слушает созвон" : "Siri+")
            .onAppear {
                // The label lives as long as the app, so the shortcut can always open the window.
                overlay.openMainWindow = { openWindow(id: "assistant") }
            }
    }
}

private struct AssistantMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var meeting: MeetingModel
    let overlay: HintOverlay
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Спросить (⌃⌥Пробел)") { overlay.show() }
        Button("Открыть Siri+") { showWindow() }
        Button("Новый диалог") {
            model.newConversation()
            showWindow()
        }
        Divider()
        switch meeting.phase {
        case .idle:
            Button("Начать созвон") {
                model.selectedTab = .meeting
                showWindow()
                meeting.refreshSources()
                Task { await meeting.start() }
            }
        case .starting:
            Text("Готовлю распознавание…")
        case .running:
            Button("Подсказать сейчас (⌃⌥Пробел)") { meeting.askNow() }
            Button("Показать панель подсказок") { overlay.show() }
            Button("Остановить созвон") { Task { await meeting.stop() } }
        }
        Divider()
        Text(model.hasAPIKey ? "Claude подключён" : "Нужен ключ Claude API")
        Button("Настройки") {
            model.selectedTab = .settings
            showWindow()
        }
        Divider()
        Button("Завершить Siri+") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func showWindow() {
        openWindow(id: "assistant")
        NSApplication.shared.activate()
    }
}
