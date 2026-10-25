import SwiftUI

@main
struct SiriPlusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    @State private var overlay: HintOverlay
    @State private var callPrompt: CallPrompt
    @State private var updatePrompt: UpdatePrompt

    init() {
        let model = AppModel()
        let overlay = HintOverlay(model: model)
        model.showHintPanel = { overlay.show() }
        _model = StateObject(wrappedValue: model)
        _overlay = State(initialValue: overlay)
        _callPrompt = State(initialValue: CallPrompt(monitor: model.callMonitor))
        model.callMonitor.start()
        _updatePrompt = State(initialValue: UpdatePrompt(updates: model.updates))
        model.updates.start()
        AppDelegate.openURL = { url in
            switch url.host() {
            case "ask":
                overlay.show()
                if !model.voice.isListening { Task { await model.toggleDictation() } }
            case "meeting":
                model.selectedTab = .meeting
                overlay.showMainWindow()
                Task { await model.meeting.start() }
            case "updates":
                Task { await model.updates.check(userInitiated: true) }
            case "settings":
                model.selectedTab = .settings
                overlay.showMainWindow()
            default:
                overlay.showMainWindow()
            }
        }
    }

    var body: some Scene {
        // LSUIElement keeps the app out of the Dock; the menu bar item is its home.
        Window("Siri+", id: "assistant") {
            WorkspaceView(model: model)
        }
        .defaultSize(width: 880, height: 600)
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

    var body: some View {
        Button("Ask (⌃⌥Space)") {
            afterMenuCloses {
                overlay.show()
                if model.preferences.dictatesOnShortcut, !model.voice.isListening { Task { await model.toggleDictation() } }
            }
        }
        Button("New Conversation") {
            afterMenuCloses {
                model.newConversation()
                showWindow()
            }
        }
        Divider()
        switch meeting.phase {
        case .idle:
            Button("Start Meeting") {
                afterMenuCloses {
                    model.selectedTab = .meeting
                    showWindow()
                    meeting.refreshSources()
                    Task { await meeting.start() }
                }
            }
        case .starting:
            Text("Preparing speech recognition…")
        case .running:
            Button("Hint Now (⌃⌥Space)") { afterMenuCloses { meeting.askNow() } }
            Button("Show Hint Panel") { afterMenuCloses { overlay.show() } }
            Button("Stop Meeting") { afterMenuCloses { Task { await meeting.stop() } } }
        }
        Divider()
        if model.isModelReady {
            Text("\(model.preferences.provider.title) connected")
        } else {
            Text("Sign-in required")
        }
        Button("Check for Updates…") { afterMenuCloses { Task { await model.updates.check(userInitiated: true) } } }
        Button("Settings…") {
            afterMenuCloses {
                model.selectedTab = .settings
                showWindow()
            }
        }
        Divider()
        Button("Quit Siri+") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Menu actions run while the menu is still closing; windows opened or focused then lose focus
    /// as soon as it closes, which made every item need a second click.
    private func afterMenuCloses(_ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            action()
        }
    }

    /// Uses the menu bar label's `openWindow`: this menu's own one stops working once the menu has closed.
    private func showWindow() {
        overlay.showMainWindow()
    }
}

/// Receives siriplus:// links from the widget: "ask" opens the listening panel, "meeting" starts a meeting.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var openURL: ((URL) -> Void)?

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { Self.openURL?($0) }
    }
}
