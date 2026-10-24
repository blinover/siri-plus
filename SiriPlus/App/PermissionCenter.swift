import AppKit
import AVFoundation
import Combine

/// Microphone and screen-audio access in one place. Asking through the system prompt is what puts
/// Siri+ into the Privacy & Security lists; without it the user has to add the app with "+".
@MainActor
final class PermissionCenter: ObservableObject {
    enum Status: Equatable {
        case granted
        /// Never asked: the system prompt can still be shown.
        case notAsked
        /// Refused or not yet switched on: only System Settings can change it.
        case denied
    }

    enum Kind {
        case microphone
        case screen

        var settingsAnchor: String {
            self == .microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        }
    }

    @Published private(set) var microphone: Status = .notAsked
    @Published private(set) var screen: Status = .notAsked

    private let defaults: UserDefaults
    private let screenAskedKey = "permissions.screenRequested"
    private var activation: AnyCancellable?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refresh()
        // Access changes in System Settings, so re-read it whenever the user comes back.
        activation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }
    }

    var allGranted: Bool { microphone == .granted && screen == .granted }

    /// What is missing, for a one-line explanation.
    var missingSummary: String? {
        switch (microphone == .granted, screen == .granted) {
        case (true, true): nil
        case (false, true): String(localized: "Siri+ needs microphone access")
        case (true, false): String(localized: "Siri+ needs screen audio access")
        case (false, false): String(localized: "Siri+ needs microphone and screen audio access")
        }
    }

    func status(of kind: Kind) -> Status { kind == .microphone ? microphone : screen }

    func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .notDetermined: microphone = .notAsked
        default: microphone = .denied
        }
        if CGPreflightScreenCaptureAccess() {
            screen = .granted
        } else {
            screen = defaults.bool(forKey: screenAskedKey) ? .denied : .notAsked
        }
    }

    /// Shows the system prompt when it still can; otherwise opens the right list in System Settings.
    func request(_ kind: Kind) async {
        switch (kind, status(of: kind)) {
        case (_, .granted):
            return
        case (.microphone, .notAsked):
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case (.screen, .notAsked):
            defaults.set(true, forKey: screenAskedKey)
            // Adds Siri+ to Screen & System Audio Recording and shows the system prompt.
            _ = CGRequestScreenCaptureAccess()
        case (.screen, .denied):
            // Registers this exact build in the list too: a rebuilt, ad-hoc signed app is a new app for macOS.
            _ = CGRequestScreenCaptureAccess()
            openSettings(kind)
        case (.microphone, .denied):
            openSettings(kind)
        }
        refresh()
    }

    /// Asks for everything that is missing, one after another.
    func requestMissing() async {
        if microphone != .granted { await request(.microphone) }
        if screen != .granted { await request(.screen) }
    }

    func openSettings(_ kind: Kind) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.settingsAnchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
