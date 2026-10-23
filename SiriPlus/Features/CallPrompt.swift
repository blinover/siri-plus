import AppKit
import Combine
import SwiftUI

/// A small glass panel under the menu bar offering to start or stop a meeting when a call begins or ends.
@MainActor
final class CallPrompt {
    private static let size = NSSize(width: 460, height: 76)

    private let monitor: CallMonitor
    private var panel: NSPanel?
    private var changes: AnyCancellable?

    init(monitor: CallMonitor) {
        self.monitor = monitor
        changes = monitor.$suggestion
            .removeDuplicates()
            .sink { [weak self] suggestion in
                if let suggestion { self?.show(suggestion) } else { self?.hide() }
            }
    }

    private func show(_ suggestion: CallMonitor.Suggestion) {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: CallPromptView(suggestion: suggestion, monitor: monitor))
        guard let screen = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: screen.midX - Self.size.width / 2, y: screen.maxY - Self.size.height - 8))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // The other participants should not see the assistant in a shared screen.
        panel.sharingType = .none
        return panel
    }
}

private struct CallPromptView: View {
    let suggestion: CallMonitor.Suggestion
    let monitor: CallMonitor

    private var appName: String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: suggestion.appID).first,
           let name = app.localizedName {
            return name
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: suggestion.appID) else { return suggestion.appID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private var icon: NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: suggestion.appID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                switch suggestion {
                case .start:
                    Text("Call in \(appName)").font(.headline)
                    Text("Start a meeting in Siri+?").font(.callout).foregroundStyle(.secondary)
                case .stop:
                    Text("The call in \(appName) has ended").font(.headline)
                    Text("Stop the meeting and save it to History?").font(.callout).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            Button("Not Now") { monitor.decline() }
                .buttonStyle(.glass)
            Group {
                switch suggestion {
                case .start: Button("Start") { Task { await monitor.accept() } }
                case .stop: Button("Stop") { Task { await monitor.accept() } }
                }
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(4)
    }
}
