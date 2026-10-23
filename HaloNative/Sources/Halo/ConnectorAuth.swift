import AppKit
import CryptoKit
import HaloCore
import Observation
import Security

/// A connector's saved sign-in, kept in Credentials as "connector.<id>"
/// (a file in development builds, the Keychain in release builds).
struct ConnectorCredential: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var clientId: String?
    /// Issued by dynamic registration; most servers issue none.
    var clientSecret: String?
    var tokenEndpoint: String?
    var resource: String?
}

/// An OAuth client the developer registered with a service that has no
/// dynamic registration (Slack, Google), kept as "connector.<id>.client".
struct ConnectorClient: Codable, Sendable {
    var clientId: String
    var clientSecret: String
    var redirectPort: UInt16?
}

/// Hands connector tokens to the connector layer, refreshing OAuth tokens
/// near expiry, one refresh at a time per connector.
actor ConnectorTokenStore: ConnectorTokenSource {
    static let shared = ConnectorTokenStore()
    private var refreshing: [String: Task<String, Error>] = [:]

    func token(for id: String, forceRefresh: Bool) async throws -> String? {
        guard let saved = Self.credential(id) else { return nil }
        guard saved.refreshToken != nil, saved.tokenEndpoint != nil else { return saved.accessToken }
        if !forceRefresh, (saved.expiresAt ?? .distantFuture).timeIntervalSinceNow > 60 { return saved.accessToken }
        if let task = refreshing[id] { return try await task.value }
        let task = Task { try await Self.refresh(id, saved) }
        refreshing[id] = task
        defer { refreshing[id] = nil }
        return try await task.value
    }

    func setting(_ name: String, for id: String) async -> String? {
        name == "client_id" ? Self.client(id)?.clientId : nil
    }

    // MARK: - Storage

    static func credential(_ id: String) -> ConnectorCredential? {
        if let data = try? Credentials.read(account: "connector.\(id)"), let saved = try? JSONDecoder().decode(ConnectorCredential.self, from: data) {
            return saved
        }
        // Development builds may take a pasted-token connector's token from the .env file.
        guard Credentials.isDevelopmentBuild, case .token = ConnectorSpec.spec(id)?.auth else { return nil }
        let token = Credentials.developmentEnvironmentValue("HALO_\(id.uppercased())_TOKEN")
        return token.isEmpty ? nil : ConnectorCredential(accessToken: token)
    }

    /// The provider's own branded OAuth client: saved in Settings (Credentials),
    /// else the client id from oauth.json with its secret from Credentials or,
    /// in development builds, the .env file.
    static func client(_ id: String) -> ConnectorClient? {
        if let data = try? Credentials.read(account: "connector.\(id).client"), let saved = try? JSONDecoder().decode(ConnectorClient.self, from: data) {
            return saved
        }
        let development = Credentials.isDevelopmentBuild
        func env(_ name: String) -> String { development ? Credentials.developmentEnvironmentValue("HALO_\(id.uppercased())_\(name)") : "" }
        let file = OAuthSettings.load().clients[id]
        let clientID = file?.clientId ?? env("CLIENT_ID")
        guard !clientID.isEmpty else { return nil }
        let secret = (try? Credentials.read(account: "connector.\(id).client-secret")).flatMap { $0.map { String(decoding: $0, as: UTF8.self) } } ?? env("CLIENT_SECRET")
        return ConnectorClient(clientId: clientID, clientSecret: secret, redirectPort: file?.redirectPort ?? UInt16(env("REDIRECT_PORT")))
    }

    static func save(_ id: String, _ credential: ConnectorCredential?) throws {
        try Credentials.write(account: "connector.\(id)", data: credential.map { try JSONEncoder().encode($0) })
    }

    static func saveClient(_ id: String, _ client: ConnectorClient?) throws {
        try Credentials.write(account: "connector.\(id).client", data: client.map { try JSONEncoder().encode($0) })
    }

    private static func refresh(_ id: String, _ saved: ConnectorCredential) async throws -> String {
        let name = ConnectorSpec.spec(id)?.name ?? id
        guard let refreshToken = saved.refreshToken, let endpoint = saved.tokenEndpoint.flatMap(URL.init(string:)) else {
            return saved.accessToken
        }
        var fields = ["grant_type": "refresh_token", "refresh_token": refreshToken]
        if let clientID = saved.clientId { fields["client_id"] = clientID }
        if let secret = saved.clientSecret ?? client(id)?.clientSecret, !secret.isEmpty { fields["client_secret"] = secret }
        if let resource = saved.resource { fields["resource"] = resource }
        let tokens: [String: Any]
        do { tokens = try await ConnectorOAuth.tokenRequest(endpoint, fields) }
        catch { throw ChatGPTFailure("\(name) sign-in expired. Reconnect \(name) in Halo Settings.") }
        guard let next = ConnectorOAuth.credential(tokens, previous: saved) else {
            throw ChatGPTFailure("\(name) returned incomplete credentials. Reconnect \(name) in Halo Settings.")
        }
        try save(id, next)
        return next.accessToken
    }
}

/// Connect and disconnect, for Settings. Sign-in uses the system browser with
/// PKCE. The provider returns to Halo's hosted HTTPS callback, which forwards to
/// halo://oauth/callback; without one configured, a one-time 127.0.0.1 callback.
@MainActor @Observable
final class ConnectorAccounts {
    /// What a Connect card shows for one service.
    enum Phase: Equatable {
        case idle, preparing, waitingForBrowser, connected
        case failed(String)
    }
    private(set) var phase: [String: Phase] = [:]
    private(set) var connected: Set<String> = []
    private(set) var configured: Set<String> = []
    private(set) var status: [String: String] = [:]
    private(set) var connecting: String?
    @ObservationIgnored private var signIn: Task<Void, Never>?
    @ObservationIgnored let manager: ConnectorManager

    init(manager: ConnectorManager) {
        self.manager = manager
        refreshState()
    }

    func refreshState() {
        connected = Set(ConnectorSpec.catalog.map(\.id).filter { ConnectorTokenStore.credential($0) != nil })
        configured = Set(ConnectorSpec.catalog.map(\.id).filter { ConnectorTokenStore.client($0) != nil })
    }

    func connect(_ spec: ConnectorSpec) {
        guard connecting == nil else { return }
        connecting = spec.id
        phase[spec.id] = .preparing
        status[spec.id] = nil
        signIn = Task {
            defer { connecting = nil; signIn = nil }
            do {
                let credential = try await ConnectorOAuth.signIn(spec) { [weak self] in self?.phase[spec.id] = .waitingForBrowser }
                try Task.checkCancellation()
                try ConnectorTokenStore.save(spec.id, credential)
                await manager.reset(spec.id)
                refreshState()
                phase[spec.id] = .connected
                status[spec.id] = "Connected"
            } catch is CancellationError {
                phase[spec.id] = .idle
                status[spec.id] = "Sign-in cancelled"
            } catch {
                phase[spec.id] = .failed(error.localizedDescription)
                status[spec.id] = error.localizedDescription
            }
        }
    }

    func cancel() { signIn?.cancel() }

    /// For --check-connect-card only: shows a card state without signing in.
    func preview(_ value: Phase, for spec: ConnectorSpec) { phase[spec.id] = value }

    /// Clears a finished card's state when it is closed.
    func dismissCard(_ spec: ConnectorSpec) {
        if connecting != spec.id { phase[spec.id] = .idle }
    }

    func saveToken(_ spec: ConnectorSpec, _ token: String) {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        do {
            try ConnectorTokenStore.save(spec.id, ConnectorCredential(accessToken: token))
            Task { await manager.reset(spec.id) }
            refreshState()
            status[spec.id] = "Saved"
        } catch { status[spec.id] = error.localizedDescription }
    }

    func saveClient(_ spec: ConnectorSpec, id: String, secret: String, port: String) {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        do {
            try ConnectorTokenStore.saveClient(spec.id, ConnectorClient(clientId: id, clientSecret: secret.trimmingCharacters(in: .whitespacesAndNewlines),
                                                                        redirectPort: UInt16(port.trimmingCharacters(in: .whitespaces))))
            refreshState()
            status[spec.id] = "OAuth client saved"
        } catch { status[spec.id] = error.localizedDescription }
    }

    /// Deletes the saved OAuth client (id and secret) and the sign-in made
    /// with it, since its refresh token cannot work without the client.
    func deleteClient(_ spec: ConnectorSpec) {
        do {
            try ConnectorTokenStore.saveClient(spec.id, nil)
            try Credentials.write(account: "connector.\(spec.id).client-secret", data: nil)
            try ConnectorTokenStore.save(spec.id, nil)
            Task { await manager.reset(spec.id) }
            refreshState()
            status[spec.id] = configured.contains(spec.id)
                ? "Deleted from Halo. A client id is still set in oauth.json or the development .env file."
                : "OAuth client deleted"
        } catch { status[spec.id] = error.localizedDescription }
    }

    /// The saved client id with its middle hidden, to show which client is in use.
    func clientSummary(_ spec: ConnectorSpec) -> String? {
        guard let id = ConnectorTokenStore.client(spec.id)?.clientId else { return nil }
        return id.count > 16 ? "\(id.prefix(8))…\(id.suffix(6))" : id
    }

    func disconnect(_ spec: ConnectorSpec) {
        do {
            try ConnectorTokenStore.save(spec.id, nil)
            Task { await manager.reset(spec.id) }
            refreshState()
            status[spec.id] = connected.contains(spec.id) ? "Still connected through the development .env file" : "Disconnected"
        } catch { status[spec.id] = error.localizedDescription }
    }
}

/// OAuth 2.1 authorization code + PKCE for connectors. Hosted MCP servers are
/// found from their metadata and register Halo dynamically; Slack and Google
/// use the developer's own registered client.
enum ConnectorOAuth {
    struct Server {
        let authorize: URL
        let token: URL
        let registration: URL?
        let scopes: [String]
        let resource: String?
    }

    /// `opened` runs once the consent page is open in the browser.
    @MainActor static func signIn(_ spec: ConnectorSpec, opened: @MainActor () -> Void = {}) async throws -> ConnectorCredential {
        let client = ConnectorTokenStore.client(spec.id)
        // The hosted HTTPS callback when configured (it forwards to halo://oauth/callback),
        // otherwise a one-time 127.0.0.1 callback so development still works.
        let hosted = OAuthSettings.callback(for: spec.id)
        let loopback = hosted == nil ? try OAuthLoopback(port: client?.redirectPort ?? 0, service: spec.name) : nil
        defer { loopback?.cancel() }
        let redirect = hosted ?? loopback!.redirect.absoluteString
        let server: Server, clientID: String, secret: String?
        var extra: [String: String] = [:]
        switch spec.auth {
        case .discoveredOAuth:
            guard case .hostedMCP(let url) = spec.route else { throw ChatGPTFailure("\(spec.name) has no sign-in address.") }
            server = try await discover(url)
            guard let endpoint = server.registration else {
                throw ChatGPTFailure("\(spec.name) does not offer automatic app registration.")
            }
            (clientID, secret) = try await registration(for: spec.id, endpoint: endpoint, redirect: redirect, scopes: server.scopes)
        case .configuredOAuth(let authorize, let token, let scopes, let parameters):
            guard let client else { throw ChatGPTFailure("Add your \(spec.name) OAuth client ID and secret first.") }
            server = Server(authorize: URL(string: authorize)!, token: URL(string: token)!, registration: nil, scopes: scopes, resource: nil)
            (clientID, secret) = (client.clientId, client.clientSecret.isEmpty ? nil : client.clientSecret)
            extra = parameters
        case .token:
            throw ChatGPTFailure("\(spec.name) uses a pasted token, not sign-in.")
        }

        let verifier = try random(), state = try random()
        var fields = ["response_type": "code", "client_id": clientID, "redirect_uri": redirect, "state": state,
                      "code_challenge": b64(Data(SHA256.hash(data: Data(verifier.utf8)))), "code_challenge_method": "S256"]
        if !server.scopes.isEmpty { fields["scope"] = server.scopes.joined(separator: " ") }
        if let resource = server.resource { fields["resource"] = resource }
        fields.merge(extra) { _, new in new }
        var url = URLComponents(url: server.authorize, resolvingAgainstBaseURL: false)!
        url.queryItems = (url.queryItems ?? []) + fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let browserURL = url.url, NSWorkspace.shared.open(browserURL) else { throw ChatGPTFailure("Could not open \(spec.name) sign-in.") }
        opened()

        let response: URL
        if let loopback { response = try await loopback.wait(state: state) }
        else { response = try await OAuthCallbackRouter.shared.wait(state: state, service: spec.name) }
        NSApp.activate()
        try Task.checkCancellation()
        let items = URLComponents(url: response, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if items.contains(where: { $0.name == "error" }) { throw ChatGPTFailure("\(spec.name) sign-in was declined or cancelled.") }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw ChatGPTFailure("\(spec.name) returned no authorization code.")
        }
        var exchange = ["grant_type": "authorization_code", "code": code, "redirect_uri": redirect, "client_id": clientID, "code_verifier": verifier]
        if let secret { exchange["client_secret"] = secret }
        if let resource = server.resource { exchange["resource"] = resource }
        let tokens = try await tokenRequest(server.token, exchange)
        guard var credential = credential(tokens, previous: nil) else { throw ChatGPTFailure("\(spec.name) returned incomplete credentials.") }
        credential.clientId = clientID
        credential.clientSecret = spec.isConfiguredClient ? nil : secret
        credential.tokenEndpoint = server.token.absoluteString
        credential.resource = server.resource
        return credential
    }

    /// Protected-resource metadata (RFC 9728), then the authorization
    /// server's metadata (RFC 8414, falling back to OpenID discovery).
    static func discover(_ resource: String) async throws -> Server {
        guard let url = URL(string: resource), let host = url.host else { throw ChatGPTFailure("Bad connector address.") }
        let origin = "\(url.scheme ?? "https")://\(host)\(url.port.map { ":\($0)" } ?? "")"
        let path = url.path == "/" ? "" : url.path
        var metadata: [String: Any] = [:]
        let base = origin + "/.well-known/oauth-protected-resource"
        for candidate in path.isEmpty ? [base] : [base + path, base] {
            if let found = try? await json(candidate) { metadata = found; break }
        }
        let issuer = (metadata["authorization_servers"] as? [String])?.first ?? origin
        guard let issuerURL = URL(string: issuer), let issuerHost = issuerURL.host else { throw ChatGPTFailure("Bad sign-in server address.") }
        let issuerOrigin = "\(issuerURL.scheme ?? "https")://\(issuerHost)\(issuerURL.port.map { ":\($0)" } ?? "")"
        let issuerPath = issuerURL.path == "/" ? "" : issuerURL.path
        var server: [String: Any]?
        for candidate in [issuerOrigin + "/.well-known/oauth-authorization-server" + issuerPath, issuer + "/.well-known/oauth-authorization-server",
                          issuerOrigin + "/.well-known/openid-configuration" + issuerPath, issuer + "/.well-known/openid-configuration"] {
            if let found = try? await json(candidate), found["authorization_endpoint"] != nil { server = found; break }
        }
        guard let server, let authorize = (server["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
              let token = (server["token_endpoint"] as? String).flatMap(URL.init(string:)) else {
            throw ChatGPTFailure("Could not find \(host)'s sign-in server.")
        }
        return Server(authorize: authorize, token: token, registration: (server["registration_endpoint"] as? String).flatMap(URL.init(string:)),
                      scopes: metadata["scopes_supported"] as? [String] ?? [], resource: metadata["resource"] as? String ?? resource)
    }

    /// A dynamic registration Halo made earlier, kept so the service lists one
    /// "Halo" app instead of a new one per sign-in.
    private struct Registration: Codable {
        let endpoint: String
        let redirect: String
        let branding: OAuthSettings.Branding
        let clientId: String
        let clientSecret: String?
    }

    /// Reuses the saved registration while the redirect and branding are
    /// unchanged. Loopback redirects change port every time, so those register anew.
    static func registration(for id: String, endpoint: URL, redirect: String, scopes: [String]) async throws -> (String, String?) {
        let account = "connector.\(id).registration", branding = OAuthSettings.load().branding
        let stable = redirect.hasPrefix("https://")
        if stable, let data = try? Credentials.read(account: account),
           let saved = try? JSONDecoder().decode(Registration.self, from: data),
           saved.endpoint == endpoint.absoluteString, saved.redirect == redirect, saved.branding == branding {
            return (saved.clientId, saved.clientSecret)
        }
        let (clientID, secret) = try await register(endpoint, redirect: redirect, scopes: scopes, branding: branding)
        if stable {
            let saved = Registration(endpoint: endpoint.absoluteString, redirect: redirect, branding: branding, clientId: clientID, clientSecret: secret)
            try? Credentials.write(account: account, data: JSONEncoder().encode(saved))
        }
        return (clientID, secret)
    }

    /// Dynamic client registration (RFC 7591) as a public native client named
    /// Halo, with the homepage, logo, and policy links from oauth.json when set.
    static func register(_ endpoint: URL, redirect: String, scopes: [String], branding: OAuthSettings.Branding) async throws -> (String, String?) {
        var body: [String: Any] = ["client_name": branding.name ?? "Halo", "redirect_uris": [redirect], "grant_types": ["authorization_code", "refresh_token"],
                                   "response_types": ["code"], "token_endpoint_auth_method": "none", "application_type": "native"]
        if !scopes.isEmpty { body["scope"] = scopes.joined(separator: " ") }
        for (key, value) in [("client_uri", branding.homepage), ("logo_uri", branding.logo), ("policy_uri", branding.privacyPolicy), ("tos_uri", branding.terms)] {
            if let value, value.hasPrefix("https://") { body[key] = value }
        }
        if let email = branding.supportEmail { body["contacts"] = [email] }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let clientID = object["client_id"] as? String else {
            throw ChatGPTFailure("The service refused to register Halo for sign-in.")
        }
        return (clientID, object["client_secret"] as? String)
    }

    static func tokenRequest(_ endpoint: URL, _ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var form = URLComponents(); form.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["ok"] as? Bool != false else {
            throw ChatGPTFailure("Sign-in or refresh failed. Try connecting again.")
        }
        return body
    }

    /// Reads a token response. Slack puts user tokens under authed_user.
    static func credential(_ tokens: [String: Any], previous: ConnectorCredential?) -> ConnectorCredential? {
        let user = tokens["authed_user"] as? [String: Any]
        guard let access = (tokens["access_token"] ?? user?["access_token"]) as? String, !access.isEmpty else { return nil }
        let expiresIn = ((tokens["expires_in"] ?? user?["expires_in"]) as? NSNumber)?.doubleValue
        var next = previous ?? ConnectorCredential(accessToken: access)
        next.accessToken = access
        next.refreshToken = (tokens["refresh_token"] ?? user?["refresh_token"]) as? String ?? previous?.refreshToken
        next.expiresAt = expiresIn.map { Date().addingTimeInterval($0) }
        return next
    }

    private static func json(_ address: String) async throws -> [String: Any] {
        guard let url = URL(string: address) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        return object
    }

    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ChatGPTFailure("Could not create secure sign-in values.") }
        return b64(Data(bytes))
    }

    private static func b64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

extension ConnectorSpec {
    var isConfiguredClient: Bool { if case .configuredOAuth = auth { true } else { false } }
    var usesPastedToken: Bool { if case .token = auth { true } else { false } }
}
