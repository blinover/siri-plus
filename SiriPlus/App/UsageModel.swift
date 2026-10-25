import Combine
import Foundation

/// Subscription limits of the signed-in accounts: how much is left and when each window resets.
/// API keys have no such limits; they are billed per request.
@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var claude: AccountUsage?
    @Published private(set) var chatGPT: AccountUsage?
    @Published private(set) var claudeError: String?
    @Published private(set) var chatGPTError: String?
    @Published private(set) var isRefreshing = false

    private let fetchClaude: @Sendable () async throws -> AccountUsage
    private let fetchChatGPT: @Sendable () async throws -> AccountUsage
    private var schedule: Task<Void, Never>?
    private var lastRefresh = Date.distantPast

    init(
        fetchClaude: @escaping @Sendable () async throws -> AccountUsage,
        fetchChatGPT: @escaping @Sendable () async throws -> AccountUsage
    ) {
        self.fetchClaude = fetchClaude
        self.fetchChatGPT = fetchChatGPT
    }

    /// The limits of the provider in use, when it is signed in with an account.
    func usage(for selection: ModelSelection) -> AccountUsage? {
        switch (selection.provider, selection.claudeAuth, selection.openAIAuth) {
        case (.claude, .account, _): claude
        case (.openAI, _, .account): chatGPT
        default: nil
        }
    }

    /// Refreshes every five minutes while the app runs.
    func start(accounts: @escaping () -> (claude: Bool, chatGPT: Bool)) {
        guard schedule == nil else { return }
        schedule = Task { [weak self] in
            while !Task.isCancelled {
                let signedIn = accounts()
                await self?.refresh(claude: signedIn.claude, chatGPT: signedIn.chatGPT)
                try? await Task.sleep(for: .seconds(5 * 60))
            }
        }
    }

    /// Fetches the limits of the signed-in accounts; signed-out ones are cleared.
    func refresh(claude claudeSignedIn: Bool, chatGPT chatGPTSignedIn: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefresh = Date()
        }
        async let claudeResult = claudeSignedIn ? Self.result(fetchClaude) : nil
        async let chatGPTResult = chatGPTSignedIn ? Self.result(fetchChatGPT) : nil
        apply(await claudeResult, to: \.claude, error: \.claudeError, signedIn: claudeSignedIn)
        apply(await chatGPTResult, to: \.chatGPT, error: \.chatGPTError, signedIn: chatGPTSignedIn)
    }

    /// After a reply the numbers have moved; refreshes at most once a minute.
    func refreshSoon(claude: Bool, chatGPT: Bool) {
        guard Date().timeIntervalSince(lastRefresh) > 60 else { return }
        Task { await refresh(claude: claude, chatGPT: chatGPT) }
    }

    private func apply(
        _ result: Result<AccountUsage, Error>?,
        to usage: ReferenceWritableKeyPath<UsageModel, AccountUsage?>,
        error: ReferenceWritableKeyPath<UsageModel, String?>,
        signedIn: Bool
    ) {
        guard signedIn else {
            self[keyPath: usage] = nil
            self[keyPath: error] = nil
            return
        }
        switch result {
        case .success(let value):
            self[keyPath: usage] = value
            self[keyPath: error] = nil
        case .failure(let failure):
            // Keeps the last known numbers and says why they could not be refreshed.
            self[keyPath: error] = failure.localizedDescription
        case nil:
            break
        }
    }

    private static func result(_ fetch: @Sendable () async throws -> AccountUsage) async -> Result<AccountUsage, Error> {
        do { return .success(try await fetch()) } catch { return .failure(error) }
    }
}
