import AppKit
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
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
        .onAppear { model.permissions.refresh() }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                model.permissions.refresh()
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
            Toggle("Offer to start a meeting when a call begins", isOn: $model.preferences.offersMeetingStart)
                .help("A call is noticed when Zoom, Teams, Telemost, Telegram or another call app uses the microphone for 10 seconds; in a browser, start the meeting yourself.")
            Picker("Keep meetings in History", selection: $model.preferences.historyRetentionDays) {
                Text("Forever").tag(0)
                ForEach([7, 30, 90, 365], id: \.self) { days in
                    Text("\(days) days").tag(days)
                }
            }
        } header: {
            Label("Meeting", systemImage: "waveform")
        } footer: {
            footnote("Speech is recognized on this Mac. ⌃⌥Space in any app asks for a hint.")
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
            Toggle("Start dictation with ⌃⌥Space", isOn: $model.preferences.dictatesOnShortcut)
                .help("The shortcut opens the panel already listening; stop talking and the command is sent.")
        } header: {
            Label("Conversation", systemImage: "text.bubble")
        } footer: {
            footnote("Conversation history and screenshots are not saved to disk.")
        }
    }

    private var accessSection: some View {
        Section {
            permissionRow(.screen, title: String(localized: "Screen & system audio recording"), symbol: "rectangle.dashed.badge.record")
            permissionRow(.microphone, title: String(localized: "Microphone"), symbol: "mic")
        } header: {
            Label("Screen and Audio Access", systemImage: "lock.shield")
        } footer: {
            footnote("“Allow” shows the macOS prompt and adds Siri+ to the list in System Settings. After switching screen recording on, restart Siri+.")
        }
    }

    private func permissionRow(_ kind: PermissionCenter.Kind, title: String, symbol: String) -> some View {
        let status = model.permissions.status(of: kind)
        return LabeledContent {
            HStack(spacing: 8) {
                switch status {
                case .granted:
                    statusBadge(isOK: true, ok: String(localized: "Allowed"), missing: "")
                case .notAsked:
                    Button("Allow") { Task { await model.permissions.request(kind) } }
                        .buttonStyle(.glassProminent)
                case .denied:
                    statusBadge(isOK: false, ok: "", missing: String(localized: "Turned off"))
                    Button("Open Settings") { model.permissions.openSettings(kind) }
                        .buttonStyle(.glass)
                        .help("Switch Siri+ on in this list, then come back.")
                }
            }
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    updateStatus
                    Button("Check Now") { Task { await model.updates.check(userInitiated: true) } }
                        .buttonStyle(.glass)
                        .disabled(model.updates.state == .checking)
                }
            } label: {
                Label {
                    Text(verbatim: "Siri+ \(model.updates.currentVersionText)")
                } icon: {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 18, height: 18)
                }
            }
            Toggle("Check for updates automatically", isOn: $model.preferences.checksForUpdates)
        } header: {
            Label("Updates", systemImage: "arrow.down.circle")
        } footer: {
            footnote("New versions come from GitHub releases. Siri+ lives in the menu bar, not in the Dock.")
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch model.updates.state {
        case .checking:
            ProgressView().controlSize(.small)
        case .upToDate:
            statusBadge(isOK: true, ok: String(localized: "Up to date"), missing: "")
        case .available(let release):
            Button("Install \(release.version)") { Task { await model.updates.install() } }
                .buttonStyle(.glassProminent)
        case .installing:
            ProgressView().controlSize(.small)
        case .failed:
            statusBadge(isOK: false, ok: "", missing: String(localized: "Check failed"))
        case .idle:
            EmptyView()
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
}
