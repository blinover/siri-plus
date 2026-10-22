import AppKit
import Combine

enum WorkspaceTab: String, CaseIterable, Identifiable {
    case assistant
    case meeting
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .assistant: "Помощник"
        case .meeting: "Созвон"
        case .settings: "Настройки"
        }
    }

    var symbol: String {
        switch self {
        case .assistant: "sparkles"
        case .meeting: "waveform"
        case .settings: "slider.horizontal.3"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedTab: WorkspaceTab? = .assistant
    @Published var draft = ""
    @Published var preferences: AssistantPreferences {
        didSet { preferencesStore.save(preferences) }
    }
    @Published private(set) var messages: [ChatMessage] = []
    /// Text of the reply being streamed; moved into `messages` when it ends.
    @Published private(set) var partialReply = ""
    @Published private(set) var isReplying = false
    @Published private(set) var isCapturing = false
    @Published private(set) var snapshot: ScreenSnapshot?
    @Published private(set) var hasAPIKey = false
    @Published var errorMessage: String?

    let meeting: MeetingModel
    /// Shows the floating hint panel; set by the app scene.
    var showHintPanel: (() -> Void)?

    private let assistant: any AssistantService
    private let screenCapture: any ScreenCapturing
    private let preferencesStore: PreferencesStore
    private let keyStore: any SecretStoring
    private var replyTask: Task<Void, Never>?
    private var activeReplyID: UUID?
    private var captureID: UUID?
    private var meetingChanges: AnyCancellable?

    init(
        assistant: any AssistantService & HintService = ClaudeAssistantService(),
        meetingService: any MeetingService = LiveMeetingService(),
        screenCapture: any ScreenCapturing = ScreenCaptureService(),
        preferencesStore: PreferencesStore = PreferencesStore(),
        keyStore: any SecretStoring = KeychainStore(),
        meetingTiming: MeetingModel.Timing = MeetingModel.Timing()
    ) {
        self.assistant = assistant
        self.screenCapture = screenCapture
        self.preferencesStore = preferencesStore
        self.keyStore = keyStore
        let preferences = preferencesStore.load()
        self.preferences = preferences
        var currentPreferences: () -> AssistantPreferences = { preferences }
        meeting = MeetingModel(service: meetingService, hintService: assistant, timing: meetingTiming) {
            currentPreferences()
        }
        currentPreferences = { [unowned self] in self.preferences }
        hasAPIKey = (try? keyStore.read())?.isEmpty == false
        // Views observing the app model also follow meeting state (menu bar icon, sidebar badge).
        meetingChanges = meeting.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    @discardableResult
    func send(_ text: String) -> Task<Void, Never>? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isReplying else { return nil }

        errorMessage = nil
        messages.append(ChatMessage(role: .user, text: trimmed, imageJPEG: snapshot?.jpegData))
        clearSnapshot()
        isReplying = true
        partialReply = ""
        let requestID = UUID()
        activeReplyID = requestID
        let request = AssistantRequest(messages: messages, replyStyle: preferences.replyStyle, model: preferences.model)
        replyTask = Task { [weak self, assistant] in
            var failure: Error?
            do {
                for try await fragment in assistant.reply(to: request) {
                    guard let self, self.activeReplyID == requestID else { return }
                    self.partialReply += fragment
                }
            } catch {
                failure = error
            }
            guard let self, self.activeReplyID == requestID else { return }
            if let failure, !(failure is CancellationError) {
                self.errorMessage = "Ответ не получен: \(failure.localizedDescription)"
            }
            self.finishReply()
        }
        return replyTask
    }

    func stopReply() {
        replyTask?.cancel()
        finishReply()
    }

    func newConversation() {
        stopReply()
        messages = []
        draft = ""
        clearSnapshot()
        errorMessage = nil
        selectedTab = .assistant
    }

    func captureScreen() async {
        guard !isCapturing else { return }
        let id = UUID()
        captureID = id
        isCapturing = true
        errorMessage = nil
        do {
            let captured = try await screenCapture.captureMainDisplay()
            guard captureID == id else { return }
            snapshot = captured
        } catch {
            guard captureID == id else { return }
            errorMessage = "Снимок не получен. Проверьте доступ к записи экрана в настройках macOS и повторите попытку. \(error.localizedDescription)"
        }
        guard captureID == id else { return }
        isCapturing = false
        captureID = nil
    }

    func clearSnapshot() {
        captureID = nil
        isCapturing = false
        snapshot = nil
    }

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try keyStore.save(trimmed)
            hasAPIKey = true
            errorMessage = nil
        } catch {
            errorMessage = "Ключ не сохранён. \(error.localizedDescription)"
        }
    }

    func deleteAPIKey() {
        do {
            try keyStore.delete()
            hasAPIKey = false
        } catch {
            errorMessage = "Ключ не удалён. \(error.localizedDescription)"
        }
    }

    private func finishReply() {
        // Keep whatever already arrived, including a reply stopped by the user.
        let text = partialReply.trimmingCharacters(in: .whitespacesAndNewlines)
        if activeReplyID != nil, !text.isEmpty {
            messages.append(ChatMessage(role: .assistant, text: text))
        }
        partialReply = ""
        isReplying = false
        activeReplyID = nil
        replyTask = nil
    }
}
