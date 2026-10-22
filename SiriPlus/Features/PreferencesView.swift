import AppKit
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var screenAccess = CGPreflightScreenCaptureAccess()
    @State private var apiKey = ""

    var body: some View {
        Form {
            Section("Model") {
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
                Text("Only your messages, a screenshot you take, and the latest part of the meeting transcript (when a hint is needed) go to the cloud.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Conversation") {
                Picker("Answer style", selection: $model.preferences.replyStyle) {
                    ForEach(ReplyStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                Toggle("Show message time", isOn: $model.preferences.showTimestamps)
                Text("Conversation history and screenshots are not saved to disk.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Meeting") {
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
                Text("Speech recognition runs on this Mac. ⌃⌥Space in any app asks for a hint. The hint panel is hidden from screen sharing.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Screen and Audio Access") {
                LabeledContent("Screen & system audio recording") {
                    if screenAccess {
                        Text("Allowed")
                    } else {
                        Text("Permission required")
                    }
                }
                Text("Needed for screenshots and for meeting audio. After granting it you may need to restart the app.")
                    .foregroundStyle(.secondary)
                Button("Open Screen Recording Settings") {
                    openPrivacySettings("Privacy_ScreenCapture", fallback: String(localized: "Screen & System Audio Recording"))
                }
                Button("Open Microphone Settings") {
                    openPrivacySettings("Privacy_Microphone", fallback: String(localized: "Microphone"))
                }
                Button("Check Again") { screenAccess = CGPreflightScreenCaptureAccess() }
            }

            Section("Siri and Shortcuts") {
                Text("The “Open Assistant” action is available in Shortcuts and through Siri.")
                Text("Siri+ lives in the menu bar and does not appear in the Dock.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent {
                    Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                } label: {
                    Text(verbatim: "Siri+")
                }
                LabeledContent("Platform") { Text(verbatim: "macOS 26+") }
            }
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
                LabeledContent("Claude Code") { Text("Not installed") }
                Text("Claude account sign-in works through the official Claude Code app. Install it, then click Sign In.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Install Claude Code", destination: URL(string: "https://code.claude.com/docs/en/setup")!)
            } else if status.signedIn {
                LabeledContent("Account") {
                    Text(verbatim: [status.account, status.subscription.map { $0.capitalized }].compactMap { $0 }.joined(separator: " · "))
                }
                Text("Requests use your Claude subscription limits through Claude Code.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                signInButton(String(localized: "Sign In to Claude")) { await model.signInToClaude() }
                Text("Terminal opens with Claude Code’s sign-in; finish it in the browser. Siri+ notices when you are signed in.")
                    .font(.caption).foregroundStyle(.secondary)
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
                LabeledContent("Account") { Text(verbatim: email) }
                Button("Sign Out", role: .destructive) { Task { await model.signOutOfChatGPT() } }
                Text("Requests use your ChatGPT subscription limits.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                signInButton(String(localized: "Sign In to ChatGPT")) { await model.signInToChatGPT() }
                Text("The ChatGPT sign-in page opens in the browser.")
                    .font(.caption).foregroundStyle(.secondary)
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

    private func signInButton(_ title: String, action: @escaping () async -> Void) -> some View {
        HStack {
            Button(title) { Task { await action() } }
                .disabled(model.isSigningIn)
            if model.isSigningIn {
                ProgressView().controlSize(.small)
                Text("Waiting for sign-in…").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func keyField(for provider: AIProvider, hasKey: Bool, prompt: String, link: URL) -> some View {
        if hasKey {
            LabeledContent("API key") { Text("Saved in the keychain") }
            Button("Delete Key", role: .destructive) { model.deleteAPIKey(for: provider) }
        } else {
            SecureField("API key", text: $apiKey, prompt: Text(verbatim: prompt))
            Button("Save Key") {
                model.saveAPIKey(apiKey, for: provider)
                apiKey = ""
            }
            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Link("Get an API key", destination: link)
                .font(.caption)
        }
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
