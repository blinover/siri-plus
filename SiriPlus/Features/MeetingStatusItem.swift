import AppKit
import Combine

/// While a meeting runs: a red record mark and the elapsed time in the menu bar, next to ✦.
/// Hovering brings back the hint panel, which holds the hints and the Stop button; a click toggles it.
@MainActor
final class MeetingStatusItem: NSObject {
    private let meeting: MeetingModel
    private let overlay: HintOverlay
    private var item: NSStatusItem?
    private var timer: Timer?
    private var phaseChange: AnyCancellable?

    init(meeting: MeetingModel, overlay: HintOverlay) {
        self.meeting = meeting
        self.overlay = overlay
        super.init()
        phaseChange = meeting.$phase
            .removeDuplicates()
            .sink { [weak self] phase in
                if phase == .running { self?.install() } else { self?.remove() }
            }
    }

    private func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "SiriPlusMeeting"
        if let button = item.button {
            let symbol = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
            button.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(symbol)
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            button.setAccessibilityLabel(String(localized: "Siri+ is listening to the meeting"))
            button.target = self
            button.action = #selector(togglePanel)
            button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        self.item = item
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func remove() {
        timer?.invalidate()
        timer = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    private func tick() {
        guard let since = meeting.recordingSince else { return }
        item?.button?.title = " " + MeetingModel.elapsedText(Date().timeIntervalSince(since))
    }

    @objc private func togglePanel() {
        if overlay.isVisible { overlay.hide() } else { overlay.show() }
    }

    @objc func mouseEntered(with event: NSEvent) {
        if !overlay.isVisible { overlay.show() }
    }
}
