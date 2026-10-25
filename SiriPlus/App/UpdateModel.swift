import AppKit
import Combine

/// Looks for new releases on GitHub, offers them, and installs the one the user accepts.
@MainActor
final class UpdateModel: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        case installing(AppRelease)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// The release to offer in the prompt; nil once the user answered.
    @Published private(set) var offer: AppRelease?
    @Published private(set) var lastChecked: Date?
    /// A short message after a check the user asked for: up to date, or why it failed.
    @Published private(set) var notice: String?
    /// True while a check the user asked for runs, so the prompt can show it.
    @Published private(set) var isCheckingVisibly = false
    @Published private(set) var progress: UpdateProgress?

    private let checker: any UpdateChecking
    private let installer: any UpdateInstalling
    private let isAutomatic: () -> Bool
    private let defaults: UserDefaults
    private let currentVersion: String
    private let quit: @MainActor () -> Void
    private var schedule: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private let skippedKey = "updates.skippedVersion"

    init(
        checker: any UpdateChecking = GitHubUpdateChecker(),
        installer: any UpdateInstalling = DiskImageInstaller(),
        defaults: UserDefaults = .standard,
        currentVersion: String = AppVersion.current,
        quit: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) },
        isAutomatic: @escaping () -> Bool
    ) {
        self.checker = checker
        self.installer = installer
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.quit = quit
        self.isAutomatic = isAutomatic
    }

    var currentVersionText: String { currentVersion }

    /// Checks shortly after launch and then twice a day while automatic checks are on.
    func start() {
        guard schedule == nil else { return }
        schedule = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            while !Task.isCancelled {
                if let self, self.isAutomatic() { await self.check(userInitiated: false) }
                try? await Task.sleep(for: .seconds(12 * 60 * 60))
            }
        }
    }

    func check(userInitiated: Bool) async {
        if case .installing = state { return }
        state = .checking
        if userInitiated {
            notice = nil
            isCheckingVisibly = true
        }
        defer { isCheckingVisibly = false }
        do {
            let release = try await checker.latestRelease()
            lastChecked = Date()
            guard let release, release.diskImage != nil, AppVersion.isNewer(release.version, than: currentVersion) else {
                state = .upToDate
                if userInitiated { show(String(localized: "Siri+ \(currentVersion) is the latest version.")) }
                return
            }
            state = .available(release)
            // A version the user skipped is offered again only when asked for explicitly.
            if userInitiated || defaults.string(forKey: skippedKey) != release.version {
                offer = release
            }
        } catch {
            state = userInitiated ? .failed(error.localizedDescription) : .idle
            if userInitiated { show(error.localizedDescription) }
        }
    }

    func install() async {
        guard case .available(let release) = state else { return }
        offer = nil
        state = .installing(release)
        progress = .downloading(received: 0, total: nil)
        do {
            try await installer.prepare(release) { [weak self] step in
                Task { @MainActor in self?.progress = step }
            }
            quit()
        } catch {
            progress = nil
            state = .failed(error.localizedDescription)
            show(error.localizedDescription)
        }
    }

    func dismissNotice() {
        noticeTask?.cancel()
        notice = nil
    }

    private func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func later() {
        offer = nil
    }

    func skip() {
        if let offer { defaults.set(offer.version, forKey: skippedKey) }
        offer = nil
    }

    func openReleasePage() {
        switch state {
        case .available(let release), .installing(let release):
            NSWorkspace.shared.open(release.page)
        default:
            break
        }
    }
}
