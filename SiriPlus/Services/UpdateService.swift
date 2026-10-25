import CryptoKit
import Foundation

/// A published GitHub release of Siri+.
struct AppRelease: Decodable, Equatable, Sendable {
    struct Asset: Decodable, Equatable, Sendable {
        let name: String
        let url: URL

        enum CodingKeys: String, CodingKey {
            case name
            case url = "browser_download_url"
        }
    }

    let tag: String
    let notes: String
    let page: URL
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name"
        case notes = "body"
        case page = "html_url"
        case assets
    }

    init(tag: String, notes: String = "", page: URL, assets: [Asset]) {
        self.tag = tag
        self.notes = notes
        self.page = page
        self.assets = assets
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tag = try container.decode(String.self, forKey: .tag)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        page = try container.decode(URL.self, forKey: .page)
        assets = try container.decode([Asset].self, forKey: .assets)
    }

    var version: String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }

    /// The disk image for this Mac; releases are built for Apple silicon only.
    var diskImage: Asset? {
        #if arch(arm64)
        assets.first { $0.name.hasSuffix("-arm64.dmg") } ?? assets.first { $0.name.hasSuffix(".dmg") }
        #else
        nil
        #endif
    }

    var checksum: Asset? {
        diskImage.flatMap { image in assets.first { $0.name == image.name + ".sha256" } }
    }
}

enum AppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Compares dotted numeric versions: "0.10.0" is newer than "0.9.2"; a "-beta" suffix is ignored.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let lhs = parts(candidate), rhs = parts(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}

enum UpdateError: LocalizedError, Equatable {
    case noDiskImage
    case checksumMismatch
    case wrongApp
    case notWritable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noDiskImage: String(localized: "The release has no disk image for this Mac.")
        case .checksumMismatch: String(localized: "The downloaded update is damaged. Try again later.")
        case .wrongApp: String(localized: "The downloaded disk image does not contain this version of Siri+.")
        case .notWritable(let path): String(localized: "Siri+ cannot replace itself at \(path). Move Siri+ to the Applications folder, or install the update from the disk image.")
        case .failed(let message): message
        }
    }
}

protocol UpdateChecking: Sendable {
    /// The latest published release, or nil when the repository has none.
    func latestRelease() async throws -> AppRelease?
}

/// Where an update installation is, for the progress bar.
enum UpdateProgress: Equatable, Sendable {
    /// Bytes received so far and the total when the server reports it.
    case downloading(received: Int64, total: Int64?)
    case verifying
    case installing

    /// 0...1 while downloading with a known size; nil shows an indeterminate bar.
    var fraction: Double? {
        guard case .downloading(let received, let total?) = self, total > 0 else { return nil }
        return min(1, Double(received) / Double(total))
    }
}

protocol UpdateInstalling: Sendable {
    /// Downloads and verifies the release, then replaces the app after it quits. Returns when the app should quit.
    func prepare(_ release: AppRelease, progress: @escaping @Sendable (UpdateProgress) -> Void) async throws
}

/// Reads releases from GitHub; the repository comes from `SiriPlusUpdateRepository` in Info.plist.
struct GitHubUpdateChecker: UpdateChecking {
    var repository = Bundle.main.object(forInfoDictionaryKey: "SiriPlusUpdateRepository") as? String ?? "rtmo0/siri-plus"
    var session: URLSession = .shared

    func latestRelease() async throws -> AppRelease? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SiriPlus/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: return try JSONDecoder().decode(AppRelease.self, from: data)
        case 404: return nil
        case let status: throw UpdateError.failed(String(localized: "GitHub returned error \(status ?? 0) while checking for updates."))
        }
    }
}

/// Installs a release from its disk image. The app is unsigned, so the quarantine flag is removed
/// from the new copy; the SHA-256 published with the release guards against a damaged download.
struct DiskImageInstaller: UpdateInstalling {
    var session: URLSession = .shared
    var appURL = Bundle.main.bundleURL
    var bundleIdentifier = Bundle.main.bundleIdentifier

    func prepare(_ release: AppRelease, progress: @escaping @Sendable (UpdateProgress) -> Void) async throws {
        guard let image = release.diskImage else { throw UpdateError.noDiskImage }
        let parent = appURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else { throw UpdateError.notWritable(parent.path) }

        let work = FileManager.default.temporaryDirectory.appending(path: "siriplus-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let dmg = work.appending(path: image.name)
        progress(.downloading(received: 0, total: nil))
        try await ProgressDownload.run(from: image.url, to: dmg) { received, total in
            progress(.downloading(received: received, total: total))
        }

        progress(.verifying)
        if let checksum = release.checksum {
            let (data, _) = try await session.data(from: checksum.url)
            let expected = String(decoding: data, as: UTF8.self).split(separator: " ").first.map(String.init)?.lowercased()
            let actual = SHA256.hash(data: try Data(contentsOf: dmg)).map { String(format: "%02x", $0) }.joined()
            guard expected == actual else { throw UpdateError.checksumMismatch }
        }

        progress(.installing)
        let mount = work.appending(path: "mount")
        try await Self.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        let staged = work.appending(path: appURL.lastPathComponent)
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
            guard let app = contents.first(where: { Self.isApp($0, bundleIdentifier: bundleIdentifier, version: release.version) }) else {
                throw UpdateError.wrongApp
            }
            try await Self.run("/usr/bin/ditto", [app.path, staged.path])
        } catch {
            try? await Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            throw error
        }
        try? await Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])

        try launchReplacement(staged: staged, work: work)
    }

    static func isApp(_ url: URL, bundleIdentifier: String?, version: String) -> Bool {
        guard url.pathExtension == "app", let bundle = Bundle(url: url) else { return false }
        return bundle.bundleIdentifier == bundleIdentifier
            && bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version
    }

    /// Starts a script that waits for this process to quit, swaps the bundles and opens the new app.
    private func launchReplacement(staged: URL, work: URL) throws {
        let script = work.appending(path: "install.sh")
        try """
        #!/bin/sh
        pid="$1"; staged="$2"; dest="$3"; work="$4"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        rm -rf "$dest.old"
        if mv "$dest" "$dest.old" && ditto "$staged" "$dest"; then
            rm -rf "$dest.old"
        else
            rm -rf "$dest"; mv "$dest.old" "$dest"
        fi
        xattr -dr com.apple.quarantine "$dest" 2>/dev/null
        open "$dest"
        rm -rf "$work"

        """.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), staged.path, appURL.path, work.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    continuation.resume(throwing: UpdateError.failed(message.isEmpty ? "\(tool) failed." : message))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

/// A download that reports its progress; the async `URLSession.download` does not.
final class ProgressDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Int64, Int64?) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?

    private init(destination: URL, onProgress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    static func run(from url: URL, to destination: URL, onProgress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        let download = ProgressDownload(destination: destination, onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                download.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this method returns, so it is moved right here.
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
            moveError = UpdateError.failed(String(localized: "The update could not be downloaded (\(status))."))
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = error ?? moveError
        let continuation = continuation
        self.continuation = nil
        if let result { continuation?.resume(throwing: result) } else { continuation?.resume() }
    }
}
