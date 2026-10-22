import AppKit
import Combine
import SwiftUI

/// The Siri-style side panel: meeting hints during a call, a quick question otherwise.
/// Also owns the global shortcut that summons it.
@MainActor
final class HintOverlay: NSObject, NSWindowDelegate {
    static let size = NSSize(width: 400, height: 560)

    private let model: AppModel
    private let meeting: MeetingModel
    private var panel: SidePanel?
    private var hotKey: GlobalHotKey?
    private var phaseChange: AnyCancellable?
    /// Opens the main window; provided by a SwiftUI view that has `openWindow`.
    var openMainWindow: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        meeting = model.meeting
        super.init()
        hotKey = GlobalHotKey { [weak self] in self?.hotKeyPressed() }
        phaseChange = meeting.$phase
            .removeDuplicates()
            .sink { [weak self] phase in
                if phase == .running { self?.show() }
            }
    }

    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let target = NSPoint(x: screen.maxX - Self.size.width - 12, y: screen.maxY - Self.size.height - 12)
        if !panel.isVisible {
            // Slide in from the right edge, as Siri does.
            panel.setFrameOrigin(NSPoint(x: target.x + 40, y: target.y))
            panel.alphaValue = 0
        }
        if meeting.isRunning {
            panel.orderFrontRegardless()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(target)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
            panel.animator().setFrameOrigin(NSPoint(x: panel.frame.minX + 40, y: panel.frame.minY))
        } completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }

    func openApp() {
        hide()
        openMainWindow?()
        NSApplication.shared.activate()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Like Spotlight, a quick question goes away on click elsewhere; meeting hints stay.
        if !meeting.isRunning, !model.isReplying { hide() }
    }

    private func hotKeyPressed() {
        if meeting.isRunning {
            meeting.askNow()
            show()
        } else if isVisible {
            hide()
        } else {
            show()
        }
    }

    private func makePanel() -> SidePanel {
        let panel = SidePanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Keep hints out of screen sharing and recordings.
        panel.sharingType = .none
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: SidePanelView(model: model, meeting: meeting, overlay: self))
        return panel
    }
}

/// A borderless panel that can take keyboard input without activating the app.
final class SidePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct SidePanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var meeting: MeetingModel
    let overlay: HintOverlay
    @State private var question = ""
    @FocusState private var isInputFocused: Bool

    private var isActive: Bool { meeting.isHinting || model.isReplying }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if meeting.isRunning {
                meetingContent
            } else {
                askContent
            }
        }
        .padding(20)
        .frame(width: HintOverlay.size.width - 24, alignment: .topLeading)
        .background(SiriBackground(isActive: isActive))
        .padding(12)
        .frame(width: HintOverlay.size.width, height: HintOverlay.size.height, alignment: .topTrailing)
        .onExitCommand { overlay.hide() }
        .onAppear { isInputFocused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            SiriOrb(isActive: isActive)
                .frame(width: 26, height: 26)
            Text(meeting.isRunning ? "Слушаю созвон" : "Siri+")
                .font(.system(.headline, design: .rounded))
            Spacer()
            Button { overlay.openApp() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Открыть окно Siri+")
            Button { overlay.hide() } label: { Image(systemName: "xmark") }
                .help("Скрыть (Esc)")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var meetingContent: some View {
        if let hint = meeting.latestHint {
            VStack(alignment: .leading, spacing: 8) {
                if let question = hint.question {
                    Text("«\(question)»")
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                answerText(hint.failure ?? hint.text, isFailure: hint.failure != nil)
            }
        } else {
            Text("Подскажу, когда собеседник задаст вопрос.\n⌃⌥Пробел — подсказать сейчас.")
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(.secondary)
        }
        HStack {
            Button("Подсказать", systemImage: "sparkles") { meeting.askNow() }
                .disabled(meeting.transcript.isEmpty)
            Spacer()
            Button("Стоп", systemImage: "stop.fill") { Task { await meeting.stop() } }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private var askContent: some View {
        TextField("Спроси что-нибудь…", text: $question, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 17, weight: .medium, design: .rounded))
            .lineLimit(1...4)
            .focused($isInputFocused)
            .onSubmit(submit)

        if model.isReplying || model.messages.last?.role == .assistant {
            if let asked = model.messages.last(where: { $0.role == .user }) {
                Text(asked.text)
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if model.isReplying, model.partialReply.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                answerText(model.isReplying ? model.partialReply : model.messages.last?.text ?? "", isFailure: false)
            }
        }
        if let error = model.errorMessage {
            answerText(error, isFailure: true)
        }
    }

    private func answerText(_ text: String, isFailure: Bool) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 17, weight: .regular, design: .rounded))
                .foregroundStyle(isFailure ? Color.orange : Color.primary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func submit() {
        let text = question
        guard model.send(text) != nil else { return }
        question = ""
    }
}

/// Translucent rounded card with Siri's animated rainbow edge while a reply is being written.
private struct SiriBackground: View {
    let isActive: Bool
    private let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

    var body: some View {
        TimelineView(.animation(paused: !isActive)) { context in
            let angle = Angle.degrees(context.date.timeIntervalSinceReferenceDate * 90)
            let gradient = AngularGradient(colors: SiriColors.all, center: .center, angle: angle)
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.strokeBorder(gradient, lineWidth: isActive ? 3 : 1.2)
                    .blur(radius: isActive ? 6 : 0)
                    .opacity(isActive ? 0.9 : 0.5)
                shape.strokeBorder(gradient, lineWidth: isActive ? 1.5 : 0.8)
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .animation(.easeInOut(duration: 0.3), value: isActive)
    }
}

private struct SiriOrb: View {
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(paused: !isActive)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Circle()
                .fill(AngularGradient(colors: SiriColors.all, center: .center, angle: .degrees(time * 120)))
                .overlay(Circle().fill(.white.opacity(0.25)).blur(radius: 4).padding(6))
                .scaleEffect(isActive ? 1 + 0.08 * sin(time * 6) : 1)
        }
    }
}

private enum SiriColors {
    static let all: [Color] = [
        Color(red: 0.20, green: 0.55, blue: 1.00),
        Color(red: 0.55, green: 0.35, blue: 1.00),
        Color(red: 1.00, green: 0.30, blue: 0.60),
        Color(red: 1.00, green: 0.60, blue: 0.20),
        Color(red: 0.20, green: 0.80, blue: 0.90),
        Color(red: 0.20, green: 0.55, blue: 1.00),
    ]
}
