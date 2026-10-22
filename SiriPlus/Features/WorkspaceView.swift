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
                        Text(verbatim: "Siri+").font(.title2.bold())
                        Text("Personal assistant").font(.caption).foregroundStyle(.secondary)
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
                        Label("Meeting in progress", systemImage: "record.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                    Group {
                        if model.isModelReady {
                            Label("\(model.preferences.provider.title) connected", systemImage: "circle.inset.filled")
                                .foregroundStyle(.indigo)
                        } else {
                            Label("Sign-in required", systemImage: "circle.inset.filled")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    Text("Speech is recognized\non this Mac.")
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
                        .accessibilityLabel("Dismiss the error")
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
                        isModelReady: model.isModelReady,
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
        .task { await model.refreshAccounts() }
    }
}
