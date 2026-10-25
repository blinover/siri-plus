import Foundation
import Testing
@testable import SiriPlusCore

@Suite
struct UpdateTests {
    private let page = URL(string: "https://github.com/rtmo0/siri-plus/releases/tag/v0.3.0")!

    @Test(arguments: [
        ("0.2.0", "0.1.0", true), ("0.10.0", "0.9.2", true), ("1.0", "0.99.9", true), ("0.2.1", "0.2", true),
        ("0.1.0", "0.1.0", false), ("0.1.0", "0.2.0", false), ("0.2.0-beta", "0.2.0", false),
    ])
    func comparesVersions(_ candidate: String, _ current: String, _ newer: Bool) {
        #expect(AppVersion.isNewer(candidate, than: current) == newer)
    }

    @Test func decodesGitHubReleaseAndPicksDiskImage() throws {
        let json = #"""
        {"tag_name":"v0.3.0","body":"Notes","html_url":"https://github.com/rtmo0/siri-plus/releases/tag/v0.3.0",
         "assets":[
          {"name":"SiriPlus-0.3.0-arm64.dmg.sha256","browser_download_url":"https://example.com/a.sha256"},
          {"name":"SiriPlus-0.3.0-arm64.dmg","browser_download_url":"https://example.com/a.dmg"}]}
        """#
        let release = try JSONDecoder().decode(AppRelease.self, from: Data(json.utf8))
        #expect(release.version == "0.3.0")
        #expect(release.notes == "Notes")
        #expect(release.diskImage?.name == "SiriPlus-0.3.0-arm64.dmg")
        #expect(release.checksum?.name == "SiriPlus-0.3.0-arm64.dmg.sha256")
    }

    @Test @MainActor func offersNewerReleaseAndInstalls() async {
        let installer = RecordingInstaller()
        var quitCount = 0
        let updates = makeModel(release: release("0.3.0"), installer: installer) { quitCount += 1 }
        await updates.check(userInitiated: false)
        #expect(updates.offer?.version == "0.3.0")
        await updates.install()
        #expect(installer.prepared == ["0.3.0"])
        #expect(quitCount == 1)
        #expect(updates.offer == nil)
    }

    @Test @MainActor func upToDateShowsNoticeOnlyWhenAsked() async {
        let updates = makeModel(release: release("0.1.0"))
        await updates.check(userInitiated: false)
        #expect(updates.state == .upToDate)
        #expect(updates.notice == nil)
        await updates.check(userInitiated: true)
        #expect(updates.notice?.contains("0.1.0") == true)
    }

    @Test @MainActor func skippedVersionIsNotOfferedAutomatically() async throws {
        let defaults = try #require(UserDefaults(suiteName: "dev.siriplus.tests.\(UUID().uuidString)"))
        let updates = makeModel(release: release("0.3.0"), defaults: defaults)
        await updates.check(userInitiated: false)
        updates.skip()
        await updates.check(userInitiated: false)
        #expect(updates.offer == nil)
        #expect(updates.state == .available(release("0.3.0")))
        await updates.check(userInitiated: true)
        #expect(updates.offer?.version == "0.3.0")
    }

    @Test func progressFractionNeedsAKnownSize() {
        #expect(UpdateProgress.downloading(received: 50, total: 200).fraction == 0.25)
        #expect(UpdateProgress.downloading(received: 50, total: nil).fraction == nil)
        #expect(UpdateProgress.verifying.fraction == nil)
    }

    @Test @MainActor func failedInstallKeepsTheAppRunning() async {
        let installer = RecordingInstaller()
        installer.error = UpdateError.checksumMismatch
        var quitCount = 0
        let updates = makeModel(release: release("0.3.0"), installer: installer) { quitCount += 1 }
        await updates.check(userInitiated: false)
        await updates.install()
        #expect(quitCount == 0)
        #expect(updates.state == .failed(UpdateError.checksumMismatch.localizedDescription))
        #expect(updates.notice != nil)
    }

    private func release(_ version: String) -> AppRelease {
        AppRelease(tag: "v\(version)", page: page, assets: [.init(name: "SiriPlus-\(version)-arm64.dmg", url: page)])
    }

    @MainActor
    private func makeModel(
        release: AppRelease?,
        installer: RecordingInstaller = RecordingInstaller(),
        defaults: UserDefaults = UserDefaults(suiteName: "dev.siriplus.tests.\(UUID().uuidString)")!,
        quit: @escaping @MainActor () -> Void = {}
    ) -> UpdateModel {
        UpdateModel(checker: FixedChecker(release: release), installer: installer, defaults: defaults,
                    currentVersion: "0.1.0", quit: quit) { true }
    }
}

private struct FixedChecker: UpdateChecking {
    let release: AppRelease?
    func latestRelease() async throws -> AppRelease? { release }
}

private final class RecordingInstaller: UpdateInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var versions: [String] = []
    var error: Error?

    var prepared: [String] { lock.withLock { versions } }

    func prepare(_ release: AppRelease, progress: @escaping @Sendable (UpdateProgress) -> Void) async throws {
        lock.withLock { versions.append(release.version) }
        progress(.downloading(received: 50, total: 100))
        if let error { throw error }
    }
}
