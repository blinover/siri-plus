import AppKit
import Foundation

enum ClaudeCodeError: LocalizedError, Equatable {
    case notInstalled
    case notSignedIn
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            String(localized: "Claude Code is not installed. Install it from code.claude.com, then sign in in Settings.")
        case .notSignedIn:
            String(localized: "Sign in to your Claude account in Settings.")
        case .failed(let message):
            message
        }
    }
}

struct ClaudeCodeStatus: Equatable, Sendable {
    var installed = false
    var signedIn = false
    var account: String?
    var subscription: String?
}

/// Claude through the official Claude Code CLI, signed in to the user's Claude account
/// in the browser. The CLI keeps the credentials; this app never sees them.
struct ClaudeCodeBackend: ModelBackend {
    func stream(_ prompt: PreparedPrompt, model: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let executable = await Self.locate() else { throw ClaudeCodeError.notInstalled }
                    try await Self.run(executable: executable, prompt: prompt, model: model) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Installation and sign-in

    static func locate() async -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        if let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: path)
        }
        // Apps started from Finder get a minimal PATH; ask the login shell.
        let result = await runCommand(URL(fileURLWithPath: "/bin/zsh"), ["-lc", "command -v claude"])
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.status == 0 && FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    static func status() async -> ClaudeCodeStatus {
        guard let executable = await locate() else { return ClaudeCodeStatus() }
        let result = await runCommand(executable, ["auth", "status"])
        var status = ClaudeCodeStatus(installed: true)
        guard let object = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any] else { return status }
        let method = object["authMethod"] as? String
        // An API key in Claude Code would bill the API instead of the subscription.
        status.signedIn = object["loggedIn"] as? Bool == true && method != "api_key" && method != "api_key_helper" && method != "none"
        status.account = object["email"] as? String
        status.subscription = object["subscriptionType"] as? String
        return status
    }

    /// Opens `claude auth login` in Terminal; it needs an interactive terminal for its prompts.
    static func openSignIn() async throws {
        guard let executable = await locate() else { throw ClaudeCodeError.notInstalled }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("siriplus-claude-login.command")
        let quoted = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let contents = """
        #!/bin/zsh
        unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
        \(quoted) auth login --claudeai
        echo
        echo "Siri+: you can close this window."

        """
        try contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        guard NSWorkspace.shared.open(script) else { throw ClaudeCodeError.failed(String(localized: "Could not open Terminal.")) }
    }

    /// Subscription limits from Claude Code's `/usage` report; it sends no request to the model.
    static func usage() async throws -> AccountUsage {
        guard let executable = await locate() else { throw ClaudeCodeError.notInstalled }
        let result = await runCommand(executable, ["-p", "/usage", "--output-format", "json", "--safe-mode", "--tools", "", "--no-session-persistence"])
        guard let object = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
              object["is_error"] as? Bool != true, let report = object["result"] as? String else {
            throw ClaudeCodeError.failed(String(localized: "Claude Code did not report the account limits."))
        }
        return AccountUsage(plan: await status().subscription, limits: UsageParser.claude(report: report), fetchedAt: Date())
    }

    // MARK: Requests

    static func arguments(model: String, effort: String, systemPromptFile: String) -> [String] {
        [
            "-p", "--safe-mode",
            "--tools", "",
            "--permission-prompts", "none",
            "--max-turns", "1",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose", "--include-partial-messages",
            "--no-session-persistence",
            "--model", model,
            "--effort", effort,
            "--system-prompt-file", systemPromptFile,
        ]
    }

    /// The whole conversation as one stream-json user message.
    static func input(for prompt: PreparedPrompt) throws -> Data {
        var content: [[String: Any]] = []
        let single = prompt.turns.count == 1
        for turn in prompt.turns {
            for image in turn.images {
                content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image.base64EncodedString()]])
            }
            // History is tagged by role so the model can tell its earlier replies from the user's.
            let text = single ? turn.text : "<\(turn.role.rawValue)>\n\(turn.text)\n</\(turn.role.rawValue)>"
            content.append(["type": "text", "text": text])
        }
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": content],
            "parent_tool_use_id": NSNull(),
            "session_id": "",
        ]
        return try JSONSerialization.data(withJSONObject: message) + Data("\n".utf8)
    }

    private static func run(
        executable: URL,
        prompt: PreparedPrompt,
        model: String,
        onText: @escaping @Sendable (String) -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("siriplus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        // A file keeps meeting notes out of the process list.
        let systemFile = directory.appendingPathComponent("system-prompt.txt")
        try Data(prompt.system.utf8).write(to: systemFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: systemFile.path)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(model: model, effort: prompt.effort, systemPromptFile: systemFile.path)
        process.environment = signInEnvironment()
        process.currentDirectoryURL = directory
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        try await withTaskCancellationHandler {
            input.fileHandleForWriting.write(try Self.input(for: prompt))
            try input.fileHandleForWriting.close()

            var decoder = ClaudeCodeStreamDecoder()
            for try await line in output.fileHandleForReading.bytes.lines {
                if let text = decoder.consume(line: line) { onText(text) }
            }
            process.waitUntilExit()
            try Task.checkCancellation()
            if let error = decoder.resultError {
                throw Self.normalize(error)
            }
            if process.terminationStatus != 0 {
                let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw Self.normalize(stderr.isEmpty ? "Claude Code exited with code \(process.terminationStatus)." : stderr)
            }
        } onCancel: {
            process.terminate()
        }
    }

    static func normalize(_ message: String) -> ClaudeCodeError {
        let text = message.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()
        if lowered.contains("not logged in") || lowered.contains("/login") || lowered.contains("not authenticated") {
            return .notSignedIn
        }
        if lowered.contains("usage limit") || lowered.contains("rate limit") || lowered.contains("limit reached") {
            return .failed(String(localized: "The Claude account usage limit is reached. Try later or choose another model."))
        }
        return .failed(String(text.prefix(1_000)))
    }

    private static func signInEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // Keys in the environment would bill the API instead of the signed-in subscription.
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"] {
            environment.removeValue(forKey: key)
        }
        return environment
    }

    private static func runCommand(_ executable: URL, _ arguments: [String]) async -> (status: Int32, stdout: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = signInEnvironment()
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (process.terminationStatus, String(data: data, encoding: .utf8) ?? ""))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: (-1, ""))
            }
        }
    }
}

/// Reads Claude Code's `stream-json` output: partial text deltas, then a final `result`.
struct ClaudeCodeStreamDecoder {
    private var sawPartialText = false
    private(set) var resultError: String?

    /// Returns new reply text carried by the line, if any.
    mutating func consume(line: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        switch object["type"] as? String {
        case "stream_event":
            let event = object["event"] as? [String: Any]
            let delta = event?["delta"] as? [String: Any]
            guard event?["type"] as? String == "content_block_delta",
                  delta?["type"] as? String == "text_delta",
                  let text = delta?["text"] as? String else { return nil }
            sawPartialText = true
            return text
        case "result":
            if object["is_error"] as? Bool == true || (object["subtype"] as? String).map({ $0 != "success" }) == true {
                resultError = (object["result"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? String(localized: "Claude Code could not complete the request.")
                return nil
            }
            // Without partial messages the whole reply arrives only here.
            guard !sawPartialText, let text = object["result"] as? String else { return nil }
            sawPartialText = true
            return text
        default:
            return nil
        }
    }
}
