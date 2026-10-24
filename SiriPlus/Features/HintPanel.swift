import AppKit
import Combine
import SwiftUI

/// The Siri-style side panel: meeting hints during a call, a quick question otherwise.
/// Also owns the global shortcut that summons it.
@MainActor
final class HintOverlay: NSObject, NSWindowDelegate {
    /// Width of the glass card.
    static let cardWidth: CGFloat = 360
    /// Gap between the card and the top and right edges of the screen, as macOS notifications and widgets keep.
    static let edgeInset: CGFloat = 8
    /// Transparent room left of and below the card for its glow; the other sides touch the screen edge.
    static let margin: CGFloat = 20

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

    /// The screen the user works on: the one under the pointer.
    private var activeScreen: NSRect? {
        let pointer = NSEvent.mouseLocation
        return (NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main)?.visibleFrame
    }

    /// The window sits in the top-right corner of the screen's usable area, so the card is
    /// `edgeInset` from both edges and no part of the window leaves the screen.
    private func frame(cardHeight: CGFloat, on screen: NSRect) -> NSRect {
        let width = Self.cardWidth + Self.margin + Self.edgeInset
        let height = min(cardHeight + Self.margin + Self.edgeInset, screen.height)
        return NSRect(x: screen.maxX - width, y: screen.maxY - height, width: width, height: height)
    }

    private var cardHeight: CGFloat = 120

    private static let anchorKey = "panel.topRight"
    /// Where the user dragged the panel: its window's top-right corner. Nil keeps it in the screen corner.
    private var anchor: NSPoint? {
        get { UserDefaults.standard.string(forKey: Self.anchorKey).map(NSPointFromString) }
        set { UserDefaults.standard.set(newValue.map(NSStringFromPoint), forKey: Self.anchorKey) }
    }
    /// True while the overlay itself moves the window, so only the user's drags change the anchor.
    private var isPlacing = false

    /// The frame for the current card height: at the user's spot if it is still on a screen,
    /// otherwise in the top-right corner of the screen under the pointer.
    private func placement() -> NSRect? {
        if let anchor, let screen = NSScreen.screens.first(where: { NSMouseInRect(NSPoint(x: anchor.x - 1, y: anchor.y - 1), $0.frame, false) })?.visibleFrame {
            var frame = frame(cardHeight: cardHeight, on: screen)
            frame.origin = NSPoint(x: anchor.x - frame.width, y: anchor.y - frame.height)
            // Keep the whole card on that screen.
            frame.origin.x = min(max(frame.origin.x, screen.minX), screen.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, screen.minY), screen.maxY - frame.height)
            return frame
        }
        return activeScreen.map { frame(cardHeight: cardHeight, on: $0) }
    }

    private func place(_ panel: NSPanel) {
        guard let frame = placement() else { return }
        isPlacing = true
        panel.setFrame(frame, display: true)
        isPlacing = false
    }

    /// Called by the view whenever the card's height changes; the top edge stays where it is.
    func fit(cardHeight: CGFloat) {
        self.cardHeight = cardHeight
        guard let panel, panel.isVisible else { return }
        place(panel)
    }

    func windowDidMove(_ notification: Notification) {
        guard !isPlacing, let panel else { return }
        anchor = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
    }

    /// Puts the panel back into the screen corner.
    func resetPosition() {
        anchor = nil
        if let panel, panel.isVisible { place(panel) }
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        // Placed at its final spot right away; only the opacity animates, so a size change
        // during the animation cannot leave the window shifted past the screen edge.
        place(panel)
        if !panel.isVisible { panel.alphaValue = 0 }
        if meeting.isRunning {
            panel.orderFrontRegardless()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
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
        if !meeting.isRunning, !model.isReplying, !model.voice.isListening { hide() }
    }

    private func hotKeyPressed() {
        if meeting.isRunning {
            meeting.askNow()
            show()
        } else if model.voice.isListening {
            // A second press ends the spoken command right away.
            Task { await model.toggleDictation() }
        } else if isVisible {
            hide()
        } else {
            show()
            if model.preferences.dictatesOnShortcut { Task { await model.toggleDictation() } }
        }
    }

    private func makePanel() -> SidePanel {
        let panel = SidePanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: Self.cardWidth + Self.margin + Self.edgeInset, height: 200)),
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
        let hosting = NSHostingView(rootView: SidePanelView(model: model, meeting: meeting, voice: model.voice, overlay: self))
        // The overlay sizes the window from the card's height; the hosting view must not resize it too.
        hosting.sizingOptions = []
        panel.contentView = hosting
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
    @ObservedObject var voice: VoiceInput
    let overlay: HintOverlay
    @State private var question = ""
    @FocusState private var isInputFocused: Bool

    private var isActive: Bool { meeting.isHinting || model.isReplying || voice.isListening }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if meeting.isRunning {
                meetingContent
            } else {
                askContent
            }
        }
        .padding(16)
        .frame(width: HintOverlay.cardWidth, alignment: .topLeading)
        .background(SiriBackground(isActive: isActive))
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { overlay.fit(cardHeight: $0) }
        .padding(.top, HintOverlay.edgeInset)
        .padding(.trailing, HintOverlay.edgeInset)
        .padding(.leading, HintOverlay.margin)
        .padding(.bottom, HintOverlay.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .onExitCommand { overlay.hide() }
        .onAppear { isInputFocused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            // The orb, the title and the empty space between them move the panel.
            HStack(spacing: 10) {
                SiriOrb(isActive: isActive)
                    .frame(width: 22, height: 22)
                Group {
                    if meeting.isRunning {
                        Text("Listening to the meeting")
                    } else {
                        Text(verbatim: "Siri+")
                    }
                }
                .font(.system(.headline, design: .rounded))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .onTapGesture(count: 2) { overlay.resetPosition() }
            .help("Drag to move. Double-click to put it back in the corner.")
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    Button { overlay.openApp() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .help("Open the Siri+ window")
                    Button { overlay.hide() } label: { Image(systemName: "xmark") }
                        .help("Hide (Esc)")
                }
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var meetingContent: some View {
        if let hint = meeting.latestHint {
            VStack(alignment: .leading, spacing: 8) {
                if let question = hint.question {
                    Text(verbatim: "“\(question)”")
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                answerText(hint.failure ?? hint.text, isFailure: hint.failure != nil)
            }
        } else {
            Text("I’ll suggest an answer when the other side asks a question.\n⌃⌥Space — hint now.")
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(.secondary)
        }
        HStack {
            Button("Hint Now", systemImage: "sparkles") { meeting.askNow() }
                .disabled(meeting.transcript.isEmpty)
            Spacer()
            Button("Stop", systemImage: "stop.fill") { Task { await meeting.stop() } }
        }
        .buttonStyle(.glass)
        .controlSize(.small)
    }

    @ViewBuilder
    private var askContent: some View {
        HStack(alignment: .top, spacing: 8) {
            if voice.isListening {
                // Recognized words appear as they are spoken; the part still changing is dimmed.
                Group {
                    if voice.dictation.isEmpty {
                        Text("Listening…").foregroundStyle(.secondary)
                    } else {
                        Text(liveDictation)
                    }
                }
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } else {
                TextField("Ask anything…", text: $question, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .lineLimit(1...4)
                    .focused($isInputFocused)
                    .onSubmit(submit)
                    .padding(.vertical, 4)
            }
            Button {
                Task { await model.toggleDictation() }
            } label: {
                Image(systemName: voice.isListening ? "waveform" : "mic.fill")
                    .symbolEffect(.variableColor.iterative, isActive: voice.isListening)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .tint(voice.isListening ? .red : nil)
            .help(voice.isListening ? String(localized: "Stop and send") : String(localized: "Dictate (⌃⌥Space)"))
        }
        if let error = voice.errorMessage {
            answerText(error, isFailure: true)
        }

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
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundStyle(isFailure ? Color.orange : Color.primary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var liveDictation: AttributedString {
        var volatile = AttributedString(voice.dictation.volatile)
        volatile.foregroundColor = .secondary
        let separator = voice.dictation.final.isEmpty || voice.dictation.volatile.isEmpty ? "" : " "
        return AttributedString(voice.dictation.final + separator) + volatile
    }

    private func submit() {
        let text = question
        guard model.send(text) != nil else { return }
        question = ""
    }
}

/// Liquid Glass card with Siri's animated rainbow edge while a reply is being written.
private struct SiriBackground: View {
    let isActive: Bool
    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        TimelineView(.animation(paused: !isActive)) { context in
            let angle = Angle.degrees(context.date.timeIntervalSinceReferenceDate * 90)
            let gradient = AngularGradient(colors: SiriColors.all, center: .center, angle: angle)
            ZStack {
                // Clear glass keeps what is behind the panel visible, like Siri's own answers.
                Color.clear.glassEffect(.clear, in: shape)
                shape.strokeBorder(gradient, lineWidth: isActive ? 3 : 1.2)
                    .blur(radius: isActive ? 6 : 0)
                    .opacity(isActive ? 0.9 : 0.5)
                shape.strokeBorder(gradient, lineWidth: isActive ? 1.5 : 0.8)
            }
        }
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
