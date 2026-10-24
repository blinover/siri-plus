import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(WorkspaceTab.allCases, selection: $model.selectedTab) { tab in
                Label(tab.title, systemImage: tab.symbol)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) { statusCapsule }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } detail: {
            Group {
                switch model.selectedTab ?? .assistant {
                case .assistant:
                    ChatView(model: model)
                case .meeting:
                    MeetingView(
                        meeting: model.meeting,
                        permissions: model.permissions,
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
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.smooth, value: model.errorMessage ?? model.meeting.errorMessage ?? model.history.errorMessage)
        }
        .frame(minWidth: 720, minHeight: 480)
        .tint(.indigo)
        .task { await model.refreshAccounts() }
    }

    /// One line: what the assistant is connected to, or that a meeting is being recorded.
    private var statusCapsule: some View {
        Group {
            if model.meeting.isRunning {
                Label("Meeting in progress", systemImage: "record.circle")
                    .foregroundStyle(.red)
            } else if model.isModelReady {
                Label("\(model.preferences.provider.title) connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Sign-in required", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular.tint(.orange.opacity(0.25)), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
