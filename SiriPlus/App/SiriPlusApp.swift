import SwiftUI

@main
struct SiriPlusApp: App {
    @StateObject private var model: AppModel
    @State private var overlay: HintOverlay
    @State private var callPrompt: CallPrompt

    init() {
        let model = AppModel()
        let overlay = HintOverlay(model: model)
        model.showHintPanel = { overlay.show() }
        _model = StateObject(wrappedValue: model)
        _overlay = State(initialValue: overlay)
        _callPrompt = State(initialValue: CallPrompt(monitor: model.callMonitor))
        model.callMonitor.start()
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
            .accessibilityLabel(isRecording ? String(localized: "Siri+ is listening to the meeting") : "Siri+")
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
        Button("Ask (⌃⌥Space)") { overlay.show() }
        Button("Open Siri+") { showWindow() }
        Button("New Conversation") {
            model.newConversation()
            showWindow()
        }
        Divider()
        switch meeting.phase {
        case .idle:
            Button("Start Meeting") {
                model.selectedTab = .meeting
                showWindow()
                meeting.refreshSources()
                Task { await meeting.start() }
            }
        case .starting:
            Text("Preparing speech recognition…")
        case .running:
            Button("Hint Now (⌃⌥Space)") { meeting.askNow() }
            Button("Show Hint Panel") { overlay.show() }
            Button("Stop Meeting") { Task { await meeting.stop() } }
        }
        Divider()
        if model.isModelReady {
            Text("\(model.preferences.provider.title) connected")
        } else {
            Text("Sign-in required")
        }
        Button("Settings…") {
            model.selectedTab = .settings
            showWindow()
        }
        Divider()
        Button("Quit Siri+") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func showWindow() {
        openWindow(id: "assistant")
        NSApplication.shared.activate()
    }
}
