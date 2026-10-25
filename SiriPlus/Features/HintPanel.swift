import AppKit
import Combine
import SwiftUI

/// The Siri-style side panel: meeting hints during a call, a quick question otherwise.
/// Also owns the global shortcut that summons it.
@MainActor
final class HintOverlay: NSObject, NSWindowDelegate {
    /// Width of the glass card.
    static let cardWidth: CGFloat = 460
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
        shownAt = Date()
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
        showMainWindow()
    }

    /// Opens the main window, or brings it forward over every other app's windows.
    func showMainWindow() {
        NSApplication.shared.activate()
        openMainWindow?()
        // A window `openWindow` just created appears on a later run loop turn. macOS 26 may also refuse
        // to activate the app from a menu, so the window is ordered front regardless of activation.
        Task { @MainActor in
            for _ in 0..<10 {
                if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) && $0.isVisible }) {
                    // Briefly lifting the window above normal windows puts it on top of other apps;
                    // back at the normal level it stays in front.
                    window.level = .floating
                    window.orderFrontRegardless()
                    window.makeKeyAndOrderFront(nil)
                    NSApplication.shared.activate()
                    try? await Task.sleep(for: .milliseconds(300))
                    window.level = .normal
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// When the panel last appeared; focus settling right after that is not a click elsewhere.
    private var shownAt = Date.distantPast

    /// True while the file picker is open: the panel loses focus to it but must stay.
    private var isChoosingFiles = false

    func windowDidResignKey(_ notification: Notification) {
        // Like Spotlight, a quick question goes away on click elsewhere; meeting hints and a
        // conversation in progress stay.
        guard Date().timeIntervalSince(shownAt) > 0.6, !isChoosingFiles else { return }
        if !meeting.isRunning, !model.isReplying, !model.voice.isListening, model.messages.isEmpty { hide() }
    }

    /// Lets the user pick files to attach to the next question.
    func chooseFiles() {
        let picker = NSOpenPanel()
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = false
        picker.message = String(localized: "Choose images, PDFs, text, audio or video files for Siri+ to analyze.")
        isChoosingFiles = true
        NSApplication.shared.activate()
        let response = picker.runModal()
        isChoosingFiles = false
        if response == .OK { model.attach(picker.urls) }
        show()
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
    @State private var isDropTargeted = false
    @FocusState private var isInputFocused: Bool

    private var isActive: Bool { meeting.isHinting || model.isReplying || voice.isListening }

    /// The conversation grows with the chat up to most of the screen, then scrolls.
    private var maxConversationHeight: CGFloat {
        max(220, (NSScreen.main?.visibleFrame.height ?? 900) * 0.6)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if meeting.isRunning {
                meetingHeader
                meetingContent
            } else {
                inputRow
                attachmentsRow
                conversation
            }
        }
        .frame(width: HintOverlay.cardWidth, alignment: .topLeading)
        .background(PanelBackground(isActive: isActive, isDropTargeted: isDropTargeted))
        // Any empty part of the card moves the panel; controls and text keep their own clicks and drags.
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .gesture(WindowDragGesture())
        .dropDestination(for: URL.self) { urls, _ in
            model.attach(urls)
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { overlay.fit(cardHeight: $0) }
        .padding(.top, HintOverlay.edgeInset)
        .padding(.trailing, HintOverlay.edgeInset)
        .padding(.leading, HintOverlay.margin)
        .padding(.bottom, HintOverlay.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .onExitCommand { overlay.hide() }
        .onAppear { isInputFocused = true }
    }

    // MARK: Ask

    /// One line like Spotlight's: the orb moves the panel, then the question and its tools.
    private var inputRow: some View {
        HStack(alignment: .top, spacing: 10) {
            dragHandle
                .padding(.top, 2)
            Group {
                if voice.isListening {
                    // Recognized words appear as they are spoken; the part still changing is dimmed.
                    Group {
                        if voice.dictation.isEmpty {
                            Text("Listening…").foregroundStyle(.secondary)
                        } else {
                            Text(liveDictation)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    GrowingTextEditor(text: $question, placeholder: "Ask anything…", font: .system(size: 17), onSubmit: submit)
                        .focused($isInputFocused)
                }
            }
            .font(.system(size: 17, weight: .regular))

            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 4) {
                    toolButton(String(localized: "Attach Files"), symbol: "paperclip") { overlay.chooseFiles() }
                        .disabled(voice.isListening)
                    Button {
                        Task { await model.toggleDictation() }
                    } label: {
                        Image(systemName: voice.isListening ? "waveform" : "mic.fill")
                            .symbolEffect(.variableColor.iterative, isActive: voice.isListening)
                    }
                    .tint(voice.isListening ? .red : nil)
                    .help(voice.isListening ? String(localized: "Stop and send") : String(localized: "Dictate (⌃⌥Space)"))
                    if !model.messages.isEmpty {
                        toolButton(String(localized: "New Chat"), symbol: "square.and.pencil") { model.newConversation() }
                    }
                    toolButton(String(localized: "Open the Siri+ window"), symbol: "arrow.up.left.and.arrow.down.right") { overlay.openApp() }
                    toolButton(String(localized: "Hide (Esc)"), symbol: "xmark") { overlay.hide() }
                }
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func toolButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .help(title)
            .accessibilityLabel(title)
    }

    private var dragHandle: some View {
        SiriOrb(isActive: isActive)
            .frame(width: 22, height: 22)
            .contentShape(Circle())
            .onTapGesture(count: 2) { overlay.resetPosition() }
            .help("Drag to move. Double-click to put it back in the corner.")
    }

    @ViewBuilder
    private var attachmentsRow: some View {
        if !model.pendingAttachments.isEmpty || !model.processingAttachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.pendingAttachments) { attachment in
                        AttachmentChip(attachment: attachment) { model.removeAttachment(attachment.id) }
                    }
                    ForEach(model.processingAttachments, id: \.self) { ProcessingChip(name: $0) }
                }
                .padding(.horizontal, 14)
            }
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private var conversation: some View {
        if !model.messages.isEmpty || model.isReplying || voice.errorMessage != nil {
            Divider().padding(.horizontal, 14)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.messages) { message in
                            PanelMessage(message: message)
                        }
                        if model.isReplying {
                            if model.partialReply.isEmpty {
                                ProgressView().controlSize(.small).padding(.leading, 24)
                            } else {
                                PanelMessage(message: ChatMessage(role: .assistant, text: model.partialReply))
                            }
                        }
                        if let error = voice.errorMessage ?? model.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(14)
                }
                .frame(maxHeight: maxConversationHeight)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: model.messages.count) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: model.partialReply) { proxy.scrollTo("end", anchor: .bottom) }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private var liveDictation: AttributedString {
        var volatile = AttributedString(voice.dictation.volatile)
        volatile.foregroundColor = .secondary
        let separator = voice.dictation.final.isEmpty || voice.dictation.volatile.isEmpty ? "" : " "
        return AttributedString(voice.dictation.final + separator) + volatile
    }

    private func submit() {
        let typed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        // Attached files alone are a request too.
        let text = typed.isEmpty && !model.pendingAttachments.isEmpty ? String(localized: "Analyze the attached files.") : typed
        guard model.send(text) != nil else { return }
        question = ""
    }

    // MARK: Meeting

    private var meetingHeader: some View {
        HStack(spacing: 10) {
            dragHandle
            Text("Listening to the meeting")
                .font(.headline)
            Spacer(minLength: 0)
            Button { overlay.hide() } label: { Image(systemName: "xmark") }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .help("Hide (Esc)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var meetingContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let hint = meeting.latestHint {
                if let question = hint.question {
                    Text(verbatim: "“\(question)”")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                ScrollView {
                    Text(hint.failure ?? hint.text)
                        .font(.system(size: 15))
                        .foregroundStyle(hint.failure == nil ? Color.primary : Color.orange)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: maxConversationHeight)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("I’ll suggest an answer when the other side asks a question.\n⌃⌥Space — hint now.")
                    .font(.callout)
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
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }
}

/// One message in the panel: the user's on the right in a tinted bubble, Siri+'s on the left.
private struct PanelMessage: View {
    let message: ChatMessage

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(message.attachments) { attachment in
                        Label(attachment.name, systemImage: attachment.symbol)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if message.imageJPEG != nil {
                        Label("Screenshot", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(message.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.22), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.linearGradient(colors: [.blue, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .padding(.top, 2)
                Text(message.text)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Frosted Liquid Glass like Spotlight's; Siri's colors run along the edge only while it listens or answers.
private struct PanelBackground: View {
    let isActive: Bool
    let isDropTargeted: Bool
    private let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)

    var body: some View {
        TimelineView(.animation(paused: !isActive)) { context in
            let angle = Angle.degrees(context.date.timeIntervalSinceReferenceDate * 90)
            let gradient = AngularGradient(colors: SiriColors.all, center: .center, angle: angle)
            ZStack {
                Color.clear.glassEffect(.regular, in: shape)
                if isActive {
                    shape.strokeBorder(gradient, lineWidth: 3).blur(radius: 5).opacity(0.8)
                    shape.strokeBorder(gradient, lineWidth: 1.2)
                }
                if isDropTargeted {
                    shape.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }
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
