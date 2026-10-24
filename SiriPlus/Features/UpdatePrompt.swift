import AppKit
import Combine
import SwiftUI

/// A glass panel under the menu bar offering a new version; it stays while the update installs.
@MainActor
final class UpdatePrompt {
    private static let size = NSSize(width: 440, height: 76)

    private let updates: UpdateModel
    private var panel: NSPanel?
    private var changes: AnyCancellable?

    init(updates: UpdateModel) {
        self.updates = updates
        changes = updates.$offer.combineLatest(updates.$state, updates.$notice)
            .map { offer, state, notice -> Bool in
                if case .installing = state { return true }
                return offer != nil || notice != nil
            }
            .removeDuplicates()
            .sink { [weak self] visible in visible ? self?.show() : self?.hide() }
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        guard let screen = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: screen.maxX - Self.size.width - 12, y: screen.maxY - Self.size.height - 8))
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
        panel.sharingType = .none
        let hosting = NSHostingView(rootView: UpdatePromptView(updates: updates).frame(width: Self.size.width, height: Self.size.height))
        // Left to itself the hosting view shrinks the window to the content's ideal size, an empty sliver.
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }
}

private struct UpdatePromptView: View {
    @ObservedObject var updates: UpdateModel

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                switch updates.state {
                case .installing(let release):
                    Text("Installing Siri+ \(release.version)…").font(.headline)
                    Text("Siri+ will restart by itself.").font(.callout).foregroundStyle(.secondary)
                default:
                    if let offer = updates.offer {
                        Text("Siri+ \(offer.version) is available").font(.headline)
                        Text("You have \(updates.currentVersionText).").font(.callout).foregroundStyle(.secondary)
                    } else if let notice = updates.notice {
                        Text("Software Update").font(.headline)
                        Text(notice).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if case .installing = updates.state {
                ProgressView().controlSize(.small)
            } else if updates.offer == nil {
                Button("OK") { updates.dismissNotice() }
                    .buttonStyle(.glass)
            } else {
                Menu {
                    Button("Release Notes") { updates.openReleasePage() }
                    Button("Skip This Version") { updates.skip() }
                } label: {
                    Text("Later")
                } primaryAction: {
                    updates.later()
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .fixedSize()
                Button("Install") { Task { await updates.install() } }
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(4)
    }
}
