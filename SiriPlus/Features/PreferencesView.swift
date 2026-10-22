import AppKit
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var screenAccess = CGPreflightScreenCaptureAccess()
    @State private var apiKey = ""

    var body: some View {
        Form {
            modelSection
            meetingSection
            conversationSection
            accessSection
            aboutSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task { await model.refreshAccounts() }
        .onAppear { screenAccess = CGPreflightScreenCaptureAccess() }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                screenAccess = CGPreflightScreenCaptureAccess()
                Task { await model.refreshAccounts() }
            }
        }
        .onChange(of: model.preferences.provider) { apiKey = "" }
    }

    // MARK: Sections

    private var modelSection: some View {
        Section {
            Picker("Provider", selection: $model.preferences.provider) {
                ForEach(AIProvider.allCases) { provider in
                    Text(verbatim: provider.title).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            switch model.preferences.provider {
            case .claude: claudeSettings
            case .openAI: chatGPTSettings
            }
        } header: {
            Label("Model", systemImage: "sparkles")
        } footer: {
            footnote("Only your messages, a screenshot you take, and the latest part of the meeting transcript (when a hint is needed) go to the cloud.")
        }
    }

    private var meetingSection: some View {
        Section {
            Picker("Hints", selection: $model.preferences.hintMode) {
                ForEach(HintMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Picker("Speech language", selection: $model.preferences.transcriptionLocale) {
                Text("System (\(systemLanguageName))").tag(AssistantPreferences.systemLocale)
                Text(verbatim: "English").tag("en-US")
                Text(verbatim: "Русский").tag("ru-RU")
            }
            Toggle("Recognize my voice too (microphone)", isOn: $model.preferences.capturesMicrophone)
        } header: {
            Label("Meeting", systemImage: "waveform")
        } footer: {
            footnote("Speech recognition runs on this Mac. ⌃⌥Space in any app asks for a hint. The hint panel is hidden from screen sharing.")
        }
    }

    private var conversationSection: some View {
        Section {
            Picker("Answer style", selection: $model.preferences.replyStyle) {
                ForEach(ReplyStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            Toggle("Show message time", isOn: $model.preferences.showTimestamps)
        } header: {
            Label("Conversation", systemImage: "text.bubble")
        } footer: {
            footnote("Conversation history and screenshots are not saved to disk.")
        }
    }

    private var accessSection: some View {
        Section {
            LabeledContent {
                HStack(spacing: 10) {
                    statusBadge(isOK: screenAccess, ok: String(localized: "Allowed"), missing: String(localized: "Permission required"))
                    Button("Open Settings") {
                        openPrivacySettings("Privacy_ScreenCapture", fallback: String(localized: "Screen & System Audio Recording"))
                    }
                    .buttonStyle(.glass)
                }
            } label: {
                Label("Screen & system audio recording", systemImage: "rectangle.dashed.badge.record")
            }
            LabeledContent {
                Button("Open Settings") {
                    openPrivacySettings("Privacy_Microphone", fallback: String(localized: "Microphone"))
                }
                .buttonStyle(.glass)
            } label: {
                Label("Microphone", systemImage: "mic")
            }
        } header: {
            HStack {
                Label("Screen and Audio Access", systemImage: "lock.shield")
                Spacer()
                Button("Check Again") { screenAccess = CGPreflightScreenCaptureAccess() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        } footer: {
            footnote("Needed for screenshots and for meeting audio. After granting it you may need to restart the app.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent {
                Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            } label: {
                Text(verbatim: "Siri+")
            }
            LabeledContent("Platform") { Text(verbatim: "macOS 26+") }
        } header: {
            Label("About", systemImage: "info.circle")
        } footer: {
            footnote("Siri+ lives in the menu bar and does not appear in the Dock. The “Open Assistant” action is available in Shortcuts and through Siri.")
        }
    }

    // MARK: Providers

    @ViewBuilder
    private var claudeSettings: some View {
        Picker("Sign-in", selection: $model.preferences.claudeAuth) {
            ForEach(AuthMethod.allCases) { method in
                Text(method.title).tag(method)
            }
        }
        if model.preferences.claudeAuth == .account {
            let status = model.accounts.claudeCode
            if !status.installed {
                LabeledContent {
                    Link("Install Claude Code", destination: URL(string: "https://code.claude.com/docs/en/setup")!)
                } label: {
                    accountLabel(String(localized: "Claude Code"), detail: String(localized: "Not installed"), ok: false)
                }
            } else if status.signedIn {
                accountLabel(
                    status.account ?? "Claude",
                    detail: status.subscription.map { $0.capitalized } ?? String(localized: "Requests use your Claude subscription limits through Claude Code."),
                    ok: true
                )
            } else {
                LabeledContent {
                    signInButton(String(localized: "Sign In to Claude")) { await model.signInToClaude() }
                } label: {
                    accountLabel(String(localized: "Claude account"), detail: String(localized: "Terminal opens with Claude Code’s sign-in; finish it in the browser. Siri+ notices when you are signed in."), ok: false)
                }
            }
        } else {
            keyField(for: .claude, hasKey: model.accounts.hasClaudeKey, prompt: "sk-ant-…",
                     link: URL(string: "https://platform.claude.com/settings/keys")!)
        }
        Picker("Model", selection: $model.preferences.model) {
            ForEach(ClaudeModel.allCases) { model in
                Text(model.title).tag(model)
            }
        }
    }

    @ViewBuilder
    private var chatGPTSettings: some View {
        Picker("Sign-in", selection: $model.preferences.openAIAuth) {
            ForEach(AuthMethod.allCases) { method in
                Text(method.title).tag(method)
            }
        }
        if model.preferences.openAIAuth == .account {
            if let email = model.accounts.chatGPTEmail {
                LabeledContent {
                    Button("Sign Out", role: .destructive) { Task { await model.signOutOfChatGPT() } }
                        .buttonStyle(.glass)
                } label: {
                    accountLabel(email, detail: String(localized: "Requests use your ChatGPT subscription limits."), ok: true)
                }
            } else {
                LabeledContent {
                    signInButton(String(localized: "Sign In to ChatGPT")) { await model.signInToChatGPT() }
                } label: {
                    accountLabel(String(localized: "ChatGPT account"), detail: String(localized: "The ChatGPT sign-in page opens in the browser."), ok: false)
                }
            }
            Picker("Model", selection: $model.preferences.openAIModel) {
                Text("Account default").tag("")
                ForEach(model.accounts.chatGPTModels) { option in
                    Text(verbatim: option.title).tag(option.id)
                }
            }
        } else {
            keyField(for: .openAI, hasKey: model.accounts.hasOpenAIKey, prompt: "sk-…",
                     link: URL(string: "https://platform.openai.com/api-keys")!)
            Picker("Model", selection: $model.preferences.openAIModel) {
                Text("Default (GPT-6.1 Sol)").tag("")
                ForEach(OpenAIModelOption.apiModels) { option in
                    Text(option.title).tag(option.id)
                }
            }
        }
    }

    // MARK: Building blocks

    private func accountLabel(_ title: String, detail: String, ok: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark")
                .font(.title2)
                .foregroundStyle(ok ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusBadge(isOK: Bool, ok: String, missing: String) -> some View {
        Label(isOK ? ok : missing, systemImage: isOK ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .foregroundStyle(isOK ? Color.green : Color.orange)
    }

    private func signInButton(_ title: String, action: @escaping () async -> Void) -> some View {
        HStack(spacing: 8) {
            if model.isSigningIn {
                ProgressView().controlSize(.small)
                Text("Waiting for sign-in…").foregroundStyle(.secondary)
            }
            Button(title) { Task { await action() } }
                .buttonStyle(.glassProminent)
                .disabled(model.isSigningIn)
        }
    }

    @ViewBuilder
    private func keyField(for provider: AIProvider, hasKey: Bool, prompt: String, link: URL) -> some View {
        if hasKey {
            LabeledContent {
                Button("Delete Key", role: .destructive) { model.deleteAPIKey(for: provider) }
                    .buttonStyle(.glass)
            } label: {
                accountLabel(String(localized: "API key"), detail: String(localized: "Saved in the keychain"), ok: true)
            }
        } else {
            LabeledContent {
                HStack(spacing: 8) {
                    SecureField("API key", text: $apiKey, prompt: Text(verbatim: prompt))
                        .labelsHidden()
                        .frame(minWidth: 200)
                    Button("Save Key") {
                        model.saveAPIKey(apiKey, for: provider)
                        apiKey = ""
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("API key")
                    Link("Get an API key", destination: link).font(.caption)
                }
            }
        }
    }

    private func footnote(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var systemLanguageName: String {
        let code = Locale(identifier: Locale.preferredLanguages.first ?? "en").language.languageCode?.identifier ?? "en"
        return Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code
    }

    private func openPrivacySettings(_ anchor: String, fallback: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"),
              NSWorkspace.shared.open(url) else {
            model.errorMessage = String(localized: "Open System Settings → Privacy & Security → \(fallback).")
            return
        }
    }
}
