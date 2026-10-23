import AppKit
import Combine

enum WorkspaceTab: String, CaseIterable, Identifiable {
    case assistant
    case meeting
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .assistant: String(localized: "Assistant")
        case .meeting: String(localized: "Meeting")
        case .history: String(localized: "History")
        case .settings: String(localized: "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .assistant: "sparkles"
        case .meeting: "waveform"
        case .history: "clock.arrow.circlepath"
        case .settings: "slider.horizontal.3"
        }
    }
}

/// Sign-in state of every way to reach a model, shown in Settings.
struct ProviderAccounts: Equatable {
    var claudeCode = ClaudeCodeStatus()
    var hasClaudeKey = false
    var chatGPTEmail: String?
    var hasOpenAIKey = false
    var chatGPTModels: [OpenAIModelOption] = []

    func isReady(_ selection: ModelSelection) -> Bool {
        switch (selection.provider, selection.claudeAuth, selection.openAIAuth) {
        case (.claude, .account, _): claudeCode.signedIn
        case (.claude, .apiKey, _): hasClaudeKey
        case (.openAI, _, .account): chatGPTEmail != nil
        case (.openAI, _, .apiKey): hasOpenAIKey
        }
    }
}

/// Credential sources the app model manages. Tests replace them with in-memory fakes.
struct Credentials {
    var claudeKey: any SecretStoring = KeychainStore(account: "anthropic-api-key")
    var openAIKey: any SecretStoring = KeychainStore(account: "openai-api-key")
    var chatGPT = ChatGPTAccount()
    var claudeCodeStatus: @Sendable () async -> ClaudeCodeStatus = { await ClaudeCodeBackend.status() }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedTab: WorkspaceTab? = .assistant
    @Published var draft = ""
    @Published var preferences: AssistantPreferences {
        didSet {
            preferencesStore.save(preferences)
            if preferences.historyRetentionDays != oldValue.historyRetentionDays { history.removeExpired() }
        }
    }
    @Published private(set) var messages: [ChatMessage] = []
    /// The finished meeting the current conversation is about.
    @Published private(set) var chatMeeting: MeetingRecord?
    /// Text of the reply being streamed; moved into `messages` when it ends.
    @Published private(set) var partialReply = ""
    @Published private(set) var isReplying = false
    @Published private(set) var isCapturing = false
    @Published private(set) var snapshot: ScreenSnapshot?
    @Published private(set) var accounts = ProviderAccounts()
    @Published private(set) var isSigningIn = false
    @Published var errorMessage: String?

    let meeting: MeetingModel
    let history: MeetingHistory
    let callMonitor: CallMonitor
    /// Shows the floating hint panel; set by the app scene.
    var showHintPanel: (() -> Void)?

    private let assistant: any AssistantService
    private let screenCapture: any ScreenCapturing
    private let preferencesStore: PreferencesStore
    private let credentials: Credentials
    private var replyTask: Task<Void, Never>?
    private var activeReplyID: UUID?
    private var captureID: UUID?
    private var meetingChanges: AnyCancellable?

    init(
        assistant: (any AssistantService & HintService & SummaryService)? = nil,
        meetingService: any MeetingService = LiveMeetingService(),
        screenCapture: any ScreenCapturing = ScreenCaptureService(),
        preferencesStore: PreferencesStore = PreferencesStore(),
        credentials: Credentials = Credentials(),
        historyStore: MeetingHistoryStore = MeetingHistoryStore(),
        microphoneUsage: any MicrophoneUsageSource = CoreAudioMicrophoneUsage(),
        meetingTiming: MeetingModel.Timing = MeetingModel.Timing()
    ) {
        let assistant = assistant ?? CloudAssistantService(
            claudeAPI: ClaudeAPIBackend(keyStore: credentials.claudeKey),
            claudeCode: ClaudeCodeBackend(),
            openAIAPI: OpenAIAPIBackend(keyStore: credentials.openAIKey),
            chatGPT: ChatGPTAccountBackend(account: credentials.chatGPT)
        )
        self.assistant = assistant
        self.screenCapture = screenCapture
        self.preferencesStore = preferencesStore
        self.credentials = credentials
        let preferences = preferencesStore.load()
        self.preferences = preferences
        var currentPreferences: () -> AssistantPreferences = { preferences }
        meeting = MeetingModel(service: meetingService, hintService: assistant, timing: meetingTiming) {
            currentPreferences()
        }
        history = MeetingHistory(store: historyStore, summaries: assistant) { currentPreferences() }
        callMonitor = CallMonitor(meeting: meeting, usage: microphoneUsage) { currentPreferences().offersMeetingStart }
        currentPreferences = { [unowned self] in self.preferences }
        accounts.hasClaudeKey = (try? credentials.claudeKey.read())?.isEmpty == false
        accounts.hasOpenAIKey = (try? credentials.openAIKey.read())?.isEmpty == false
        meeting.onFinish = { [history] in history.add($0) }
        // Views observing the app model also follow meeting and history state (menu bar icon, sidebar badge, errors).
        meetingChanges = meeting.objectWillChange.merge(with: history.objectWillChange)
            .sink { [weak self] in self?.objectWillChange.send() }
    }

    var isModelReady: Bool { accounts.isReady(preferences.selection) }

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
        let request = AssistantRequest(messages: messages, replyStyle: preferences.replyStyle, selection: preferences.selection, meeting: chatMeeting)
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
                self.errorMessage = String(localized: "No answer: \(failure.localizedDescription)")
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
        chatMeeting = nil
        draft = ""
        clearSnapshot()
        errorMessage = nil
        selectedTab = .assistant
    }

    /// Starts a new conversation about a finished meeting.
    func askAbout(_ meeting: MeetingRecord) {
        newConversation()
        chatMeeting = meeting
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
            errorMessage = String(localized: "No screenshot. Check Screen Recording access in macOS settings and try again. \(error.localizedDescription)")
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

    // MARK: Accounts

    /// Re-reads sign-in state: Claude Code status, ChatGPT tokens and its model list.
    func refreshAccounts() async {
        accounts.claudeCode = await credentials.claudeCodeStatus()
        accounts.chatGPTEmail = await credentials.chatGPT.isSignedIn ? (await credentials.chatGPT.email ?? "ChatGPT") : nil
        if accounts.chatGPTEmail != nil, accounts.chatGPTModels.isEmpty {
            accounts.chatGPTModels = (try? await credentials.chatGPT.models()) ?? []
        }
    }

    func saveAPIKey(_ key: String, for provider: AIProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try store(for: provider).save(trimmed)
            setHasKey(true, for: provider)
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "The key was not saved. \(error.localizedDescription)")
        }
    }

    func deleteAPIKey(for provider: AIProvider) {
        do {
            try store(for: provider).delete()
            setHasKey(false, for: provider)
        } catch {
            errorMessage = String(localized: "The key was not deleted. \(error.localizedDescription)")
        }
    }

    /// Opens Claude Code's browser sign-in in Terminal and waits until it reports success.
    func signInToClaude() async {
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await ClaudeCodeBackend.openSignIn()
            for _ in 0..<100 {
                try await Task.sleep(for: .seconds(3))
                accounts.claudeCode = await credentials.claudeCodeStatus()
                if accounts.claudeCode.signedIn { return }
            }
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signInToChatGPT() async {
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await credentials.chatGPT.signIn { url in await MainActor.run { NSWorkspace.shared.open(url) } }
            NSApplication.shared.activate()
            accounts.chatGPTModels = []
            await refreshAccounts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOutOfChatGPT() async {
        try? await credentials.chatGPT.signOut()
        accounts.chatGPTEmail = nil
        accounts.chatGPTModels = []
    }

    private func store(for provider: AIProvider) -> any SecretStoring {
        provider == .claude ? credentials.claudeKey : credentials.openAIKey
    }

    private func setHasKey(_ value: Bool, for provider: AIProvider) {
        if provider == .claude { accounts.hasClaudeKey = value } else { accounts.hasOpenAIKey = value }
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
