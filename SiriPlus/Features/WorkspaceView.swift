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
            Group {
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
                case .history:
                    HistoryView(history: model.history, askAbout: model.askAbout)
                case .settings:
                    PreferencesView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Errors float over the content as tinted glass instead of pushing it down.
            .overlay(alignment: .top) {
                if let error = model.errorMessage ?? model.meeting.errorMessage ?? model.history.errorMessage {
                    errorBanner(error)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.smooth, value: model.errorMessage ?? model.meeting.errorMessage ?? model.history.errorMessage)
        }
        .frame(minWidth: 820, minHeight: 600)
        .tint(.indigo)
        .task { await model.refreshAccounts() }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(error)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.errorMessage = nil
                model.meeting.errorMessage = nil
                model.history.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .accessibilityLabel("Dismiss the error")
        }
        .font(.callout)
        .padding(14)
        .glassEffect(.regular.tint(.orange.opacity(0.25)), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
