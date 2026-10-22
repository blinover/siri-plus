import AppKit
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var screenAccess = CGPreflightScreenCaptureAccess()
    @State private var apiKey = ""

    var body: some View {
        Form {
            Section("Claude API") {
                if model.hasAPIKey {
                    LabeledContent("Ключ", value: "Сохранён в связке ключей")
                    Button("Удалить ключ", role: .destructive) { model.deleteAPIKey() }
                } else {
                    SecureField("Ключ API", text: $apiKey, prompt: Text("sk-ant-…"))
                    Button("Сохранить ключ") {
                        model.saveAPIKey(apiKey)
                        apiKey = ""
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Link("Получить ключ в Claude Console", destination: URL(string: "https://platform.claude.com/settings/keys")!)
                        .font(.caption)
                }
                Picker("Модель", selection: $model.preferences.model) {
                    ForEach(ClaudeModel.allCases) { model in
                        Text(model.title).tag(model)
                    }
                }
                Text("В облако уходят только ваши сообщения, снимок экрана по кнопке и последний фрагмент расшифровки, когда нужна подсказка. Если модель откажется отвечать, Opus и Sonnet автоматически повторят запрос на резервной модели Anthropic.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Диалог") {
                Picker("Стиль ответа", selection: $model.preferences.replyStyle) {
                    ForEach(ReplyStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                Toggle("Показывать время сообщений", isOn: $model.preferences.showTimestamps)
                Text("История диалога и снимки не сохраняются на диск.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Созвон") {
                Picker("Подсказки", selection: $model.preferences.hintMode) {
                    ForEach(HintMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker("Язык речи", selection: $model.preferences.transcriptionLocale) {
                    Text("Русский").tag("ru-RU")
                    Text("English").tag("en-US")
                }
                Toggle("Распознавать и мой голос (микрофон)", isOn: $model.preferences.capturesMicrophone)
                Text("Распознавание речи работает на этом Mac. ⌃⌥Пробел в любом приложении — подсказать сейчас. Панель подсказок не видна при демонстрации экрана.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Доступ к экрану и звуку") {
                LabeledContent("Запись экрана и звука", value: screenAccess ? "Разрешено" : "Требуется разрешение")
                Text("Нужна для снимков экрана и для звука созвона. После выдачи разрешения может потребоваться перезапустить приложение.")
                    .foregroundStyle(.secondary)
                Button("Открыть настройки записи экрана") {
                    openPrivacySettings("Privacy_ScreenCapture", fallback: "Запись экрана и системного звука")
                }
                Button("Открыть настройки микрофона") {
                    openPrivacySettings("Privacy_Microphone", fallback: "Микрофон")
                }
                Button("Проверить снова") { screenAccess = CGPreflightScreenCaptureAccess() }
            }

            Section("Siri и Команды") {
                Text("Действие «Открыть помощника» доступно в «Командах» и через Siri.")
                Text("Siri+ живёт в строке меню и не показывается в Доке.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("О приложении") {
                LabeledContent("Siri+", value: "0.2.0")
                LabeledContent("Платформа", value: "macOS 26+")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Настройки")
        .onAppear { screenAccess = CGPreflightScreenCaptureAccess() }
        .onChange(of: scenePhase) {
            if scenePhase == .active { screenAccess = CGPreflightScreenCaptureAccess() }
        }
    }

    private func openPrivacySettings(_ anchor: String, fallback: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"),
              NSWorkspace.shared.open(url) else {
            model.errorMessage = "Откройте Системные настройки → Конфиденциальность и безопасность → \(fallback)."
            return
        }
    }
}
