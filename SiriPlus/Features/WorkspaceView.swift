import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.title2)
                        .foregroundStyle(.indigo)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Siri+").font(.title2.bold())
                        Text("Личный помощник").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 24)

                List(WorkspaceTab.allCases, selection: $model.selectedTab) { tab in
                    Label(tab.title, systemImage: tab.symbol)
                        .padding(.vertical, 6)
                        .tag(tab)
                }
                .listStyle(.sidebar)

                VStack(alignment: .leading, spacing: 6) {
                    if model.meeting.isRunning {
                        Label("Идёт созвон", systemImage: "record.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                    Label(model.hasAPIKey ? "Claude подключён" : "Нужен ключ API", systemImage: "circle.inset.filled")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(model.hasAPIKey ? Color.indigo : Color.orange)
                    Text("Речь распознаётся\nна этом Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if let error = model.errorMessage ?? model.meeting.errorMessage {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(error).textSelection(.enabled)
                        Spacer()
                        Button {
                            model.errorMessage = nil
                            model.meeting.errorMessage = nil
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Закрыть сообщение об ошибке")
                    }
                    .font(.callout)
                    .padding()
                    .background(.orange.opacity(0.12))
                }
                switch model.selectedTab ?? .assistant {
                case .assistant:
                    ChatView(model: model)
                case .meeting:
                    MeetingView(
                        meeting: model.meeting,
                        hasAPIKey: model.hasAPIKey,
                        showPanel: { model.showHintPanel?() },
                        openSettings: { model.selectedTab = .settings }
                    )
                case .settings:
                    PreferencesView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 820, minHeight: 600)
        .tint(.indigo)
    }
}
