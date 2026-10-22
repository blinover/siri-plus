import CryptoKit
import Foundation
import Network

struct ChatGPTTokens: Codable, Equatable, Sendable {
    var idToken: String
    var accessToken: String
    var refreshToken: String
    var accountID: String?

    /// Claims of the ID token: email and ChatGPT account id.
    var email: String? {
        Self.claims(idToken)?["email"] as? String
            ?? (Self.claims(idToken)?["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String
    }

    var resolvedAccountID: String? {
        accountID ?? (Self.claims(idToken)?["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String
    }

    func accessTokenExpires(within interval: TimeInterval, now: Date = Date()) -> Bool {
        guard let exp = Self.claims(accessToken)?["exp"] as? Double else { return false }
        return Date(timeIntervalSince1970: exp) <= now.addingTimeInterval(interval)
    }

    static func claims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Browser sign-in to a ChatGPT account (OAuth with PKCE and a loopback redirect),
/// following the public Codex client. Tokens live in the keychain.
actor ChatGPTAccount {
    enum Constants {
        static let issuer = URL(string: "https://auth.openai.com")!
        static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
        static let scopes = "openid profile email offline_access api.connectors.read api.connectors.invoke"
        static let loopbackPorts: [UInt16] = [1455, 1457]
        static let callbackPath = "/auth/callback"
        static let backend = URL(string: "https://chatgpt.com/backend-api/codex")!
        /// The backend offers models by the Codex protocol version it is told.
        static let clientVersion = "0.162.1"
        static let originator = "siri_plus"
    }

    private let store: any SecretStoring
    private let session: URLSession
    private var cachedTokens: ChatGPTTokens?
    private var cachedModels: [OpenAIModelOption]?

    init(store: any SecretStoring = KeychainStore(account: "chatgpt-oauth"), session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    var email: String? { (try? tokens())?.email }
    var isSignedIn: Bool { (try? tokens()) != nil }

    func signIn(openBrowser: @Sendable (URL) async -> Bool) async throws {
        let verifier = Self.randomURLSafe(bytes: 64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomURLSafe(bytes: 32)
        let server = try await LoopbackServer.start(ports: Constants.loopbackPorts, path: Constants.callbackPath)
        defer { server.stop() }
        let redirectURI = "http://localhost:\(server.port)\(Constants.callbackPath)"

        var components = URLComponents(url: Constants.issuer.appendingPathComponent("oauth/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: Constants.clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: Constants.scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
            .init(name: "originator", value: Constants.originator),
        ]
        guard await openBrowser(components.url!) else { throw OpenAIError.failed(String(localized: "Could not open the browser.")) }

        let query = try await server.waitForCallback(timeout: 300)
        guard query["error"] == nil, let code = query["code"], query["state"] == state else {
            throw OpenAIError.failed(String(localized: "ChatGPT sign-in could not be verified. Try again."))
        }
        let tokens = try await tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
            "client_id": Constants.clientID,
        ], previous: nil)
        try save(tokens)
    }

    func signOut() throws {
        cachedTokens = nil
        cachedModels = nil
        try store.delete()
    }

    /// A client for the ChatGPT backend with a fresh access token.
    func client() async throws -> ResponsesClient {
        var tokens = try tokens()
        if tokens.accessTokenExpires(within: 5 * 60) {
            tokens = try await refreshed(tokens)
        }
        var headers = [
            "Authorization": "Bearer \(tokens.accessToken)",
            "originator": Constants.originator,
            "version": Constants.clientVersion,
            "User-Agent": "SiriPlus/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")",
        ]
        if let account = tokens.resolvedAccountID { headers["ChatGPT-Account-ID"] = account }
        return ResponsesClient(endpoint: Constants.backend.appendingPathComponent("responses"), headers: headers, session: session)
    }

    func refresh() async throws {
        _ = try await refreshed(try tokens())
    }

    /// Models the account may use, as listed by the backend.
    func models() async throws -> [OpenAIModelOption] {
        if let cachedModels { return cachedModels }
        let client = try await client()
        var components = URLComponents(url: Constants.backend.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "client_version", value: Constants.clientVersion)]
        var request = URLRequest(url: components.url!)
        for (name, value) in client.headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = (object["models"] ?? object["data"]) as? [[String: Any]] else {
            throw OpenAIError.failed(String(localized: "Could not load the list of ChatGPT models."))
        }
        let models = list.compactMap { model -> OpenAIModelOption? in
            guard let slug = model["slug"] as? String ?? model["id"] as? String else { return nil }
            let visibility = (model["visibility"] as? String)?.lowercased()
            guard visibility != "hide", visibility != "hidden" else { return nil }
            return OpenAIModelOption(id: slug, title: model["display_name"] as? String ?? slug)
        }
        cachedModels = models
        return models
    }

    // MARK: Tokens

    private func tokens() throws -> ChatGPTTokens {
        if let cachedTokens { return cachedTokens }
        guard let json = try store.read(), let tokens = try? JSONDecoder().decode(ChatGPTTokens.self, from: Data(json.utf8)) else {
            throw OpenAIError.notSignedIn
        }
        cachedTokens = tokens
        return tokens
    }

    private func save(_ tokens: ChatGPTTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        try store.save(String(decoding: data, as: UTF8.self))
        cachedTokens = tokens
    }

    private func refreshed(_ tokens: ChatGPTTokens) async throws -> ChatGPTTokens {
        let updated = try await tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
            "client_id": Constants.clientID,
        ], previous: tokens)
        try save(updated)
        return updated
    }

    private func tokenRequest(_ values: [String: String], previous: ChatGPTTokens?) async throws -> ChatGPTTokens {
        var request = URLRequest(url: Constants.issuer.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncoded(values).utf8)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard status == 200 else {
            if previous != nil, status == 400 || status == 401 {
                // The refresh token expired or was revoked: a new sign-in is needed.
                try? signOut()
                throw OpenAIError.notSignedIn
            }
            throw OpenAIError.failed(String(localized: "ChatGPT sign-in failed (\(status))."))
        }
        // A refresh may omit tokens that did not change.
        guard let access = object["access_token"] as? String ?? previous?.accessToken,
              let id = object["id_token"] as? String ?? previous?.idToken,
              let refresh = object["refresh_token"] as? String ?? previous?.refreshToken else {
            throw OpenAIError.failed(String(localized: "ChatGPT sign-in returned incomplete tokens."))
        }
        return ChatGPTTokens(idToken: id, accessToken: access, refreshToken: refresh, accountID: object["account_id"] as? String ?? previous?.accountID)
    }

    static func formEncoded(_ values: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return values.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }

    private static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URLEncoded
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A one-shot HTTP server on 127.0.0.1 that receives the OAuth redirect.
final class LoopbackServer: @unchecked Sendable {
    let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.siriplus.oauth-callback")
    private let path: String
    private let lock = NSLock()
    private var callback: CheckedContinuation<[String: String], Error>?
    /// A result that arrived before anyone waited for it.
    private var early: Result<[String: String], Error>?

    private init(listener: NWListener, port: UInt16, path: String) {
        self.listener = listener
        self.port = port
        self.path = path
    }

    static func start(ports: [UInt16], path: String) async throws -> LoopbackServer {
        for port in ports {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            parameters.allowLocalEndpointReuse = true
            guard let listener = try? NWListener(using: parameters) else { continue }
            let server = LoopbackServer(listener: listener, port: port, path: path)
            if await server.becomeReady() { return server }
        }
        throw OpenAIError.failed(String(localized: "Ports 1455 and 1457 are busy, so the sign-in callback cannot be received. Close the app using them and try again."))
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.finish(.failure(OpenAIError.failed(String(localized: "ChatGPT sign-in timed out."))))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let early = lock.withLock {
                    if self.early == nil { callback = continuation }
                    return self.early
                }
                if let early { continuation.resume(with: early) }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    func stop() {
        listener.cancel()
        finish(.failure(CancellationError()))
    }

    private func becomeReady() async -> Bool {
        await withCheckedContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume(returning: true) }
                case .failed, .cancelled: once.run { continuation.resume(returning: false) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let requestLine = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first ?? ""
            let target = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let components = URLComponents(string: "http://localhost\(target)")
            guard components?.path == self.path else {
                self.respond(connection, status: "404 Not Found", body: "")
                return
            }
            var query: [String: String] = [:]
            for item in components?.queryItems ?? [] { query[item.name] = item.value }
            let succeeded = query["code"] != nil && query["error"] == nil
            let body = succeeded
                ? String(localized: "Signed in to Siri+. You can close this tab.")
                : String(localized: "Sign-in could not be completed. Return to Siri+ for details.")
            self.respond(connection, status: succeeded ? "200 OK" : "400 Bad Request",
                         body: "<!doctype html><meta charset=utf-8><title>Siri+</title><h2>\(body)</h2>")
            self.finish(.success(query))
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let payload = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(_ result: Result<[String: String], Error>) {
        let continuation = lock.withLock {
            defer { callback = nil }
            if callback == nil, early == nil { early = result }
            return callback
        }
        continuation?.resume(with: result)
    }
}

/// Runs a closure at most once, from any thread.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        let first = lock.withLock {
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
