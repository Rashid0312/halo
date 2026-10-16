import AppKit
import CryptoKit
import Security
import Observation

struct ChatGPTFailure: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

@MainActor @Observable
final class ChatGPTAuth {
    struct Model: Identifiable, Sendable { let id: String; let name: String }
    private struct Session: Codable {
        var clientId: String
        var subject: String
        var email: String
        var idToken: String
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var scopes: [String]
    }
    var provider = UserDefaults.standard.string(forKey: "brainProvider") ?? "deepseek" {
        didSet { UserDefaults.standard.set(provider, forKey: "brainProvider"); onProviderChange?() }
    }
    var selectedModel = UserDefaults.standard.string(forKey: "chatgptModel") ?? "" {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "chatgptModel"); onProviderChange?() }
    }
    private(set) var models: [Model] = []
    private(set) var signingIn = false
    private(set) var status = ""
    private(set) var signedIn = false
    private(set) var sharing = false
    private(set) var email = ""
    @ObservationIgnored var onProviderChange: (() -> Void)?
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<String, Error>?
    @ObservationIgnored private var generation = UUID()
    private static let resource = "https://api.openai.com/v1"
    private static let issuer = "https://auth.openai.com"

    init() {
        if let data = try? Credentials.read(account: "chatgpt-session"), let saved = try? JSONDecoder().decode(Session.self, from: data) { session = saved }
        updateState()
        if !sharing { provider = "deepseek" }
    }

    func startSignIn() {
        guard !signingIn else { return }
        signingIn = true; status = "Opening ChatGPT sign-in…"
        let id = generation
        signInTask = Task {
            defer { signingIn = false; signInTask = nil }
            do {
                let callback = try OAuthLoopback()
                defer { callback.cancel() }
                let verifier = try Self.random(), state = try Self.random(), nonce = try Self.random()
                let previous = session
                var host = UserDefaults.standard.string(forKey: "chatgptHostID") ?? ""
                if host.isEmpty { host = "urn:uuid:" + UUID().uuidString; UserDefaults.standard.set(host, forKey: "chatgptHostID") }
                var fields = ["client_id": previous?.clientId ?? "dynamic_agent_client", "ext_agent_host_id": host,
                              "response_type": "code", "redirect_uri": callback.redirect.absoluteString,
                              "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
                              "resource": Self.resource, "state": state, "nonce": nonce,
                              "code_challenge_method": "S256", "code_challenge": Self.b64(Data(SHA256.hash(data: Data(verifier.utf8))))]
                if let previous {
                    fields["id_token_hint"] = previous.idToken
                    fields["login_hint"] = previous.email
                } else { fields["agent_name_hint"] = "Halo" }
                var url = URLComponents(string: Self.issuer + "/api/accounts/authorize")!
                url.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
                guard let browserURL = url.url, NSWorkspace.shared.open(browserURL) else { throw ChatGPTFailure("Could not open ChatGPT sign-in.") }
                let response = try await callback.wait(state: state)
                try Task.checkCancellation()
                let items = URLComponents(url: response, resolvingAgainstBaseURL: false)?.queryItems ?? []
                func field(_ name: String) -> String? { items.first { $0.name == name }?.value }
                if field("error") != nil { throw ChatGPTFailure("ChatGPT sign-in was declined or cancelled.") }
                guard let client = field("client_id") ?? previous?.clientId, client != "dynamic_agent_client",
                      previous == nil || client == previous?.clientId, let code = field("code"), !code.isEmpty else {
                    throw ChatGPTFailure("ChatGPT returned an incomplete or mismatched registration.")
                }
                let tokens = try await Self.tokenRequest(["grant_type": "authorization_code", "client_id": client, "code": code,
                                                         "code_verifier": verifier, "redirect_uri": callback.redirect.absoluteString, "resource": Self.resource])
                guard let idToken = tokens["id_token"] as? String else { throw ChatGPTFailure("ChatGPT did not return an identity token.") }
                let claims = try await Self.verify(idToken, client: client, nonce: nonce)
                guard let subject = claims["sub"] as? String, !subject.isEmpty,
                      previous == nil || previous?.subject == subject else { throw ChatGPTFailure("The signed-in account does not match this saved registration.") }
                try Task.checkCancellation()
                guard generation == id else { throw CancellationError() }
                let next = try Self.session(tokens, client: client, subject: subject, email: claims["email"] as? String ?? "", idToken: idToken)
                try save(next)
                refreshTask?.cancel(); refreshTask = nil
                generation = UUID()
                updateState()
                if sharing {
                    try await loadModels()
                    provider = "chatgpt"
                    status = "Connected to ChatGPT"
                } else { provider = "deepseek"; status = "Signed in, but ChatGPT plan usage was not granted. DeepSeek remains selected." }
            } catch is CancellationError { status = "Sign-in cancelled" }
            catch { status = error.localizedDescription }
        }
    }

    func cancelSignIn() { signInTask?.cancel() }

    func accessToken() async throws -> String {
        guard let saved = session, !saved.refreshToken.isEmpty, sharing else { throw ChatGPTFailure("Continue with ChatGPT in Halo Settings first.") }
        if saved.expiresAt.timeIntervalSinceNow > 120 { return saved.accessToken }
        if let refreshTask { return try await refreshTask.value }
        let id = generation
        let task = Task { () throws -> String in
            let tokens = try await Self.tokenRequest(["grant_type": "refresh_token", "client_id": saved.clientId,
                                                     "refresh_token": saved.refreshToken, "resource": Self.resource])
            try Task.checkCancellation()
            guard generation == id else { throw CancellationError() }
            let next = try Self.session(tokens, client: saved.clientId, subject: saved.subject, email: saved.email,
                                        idToken: tokens["id_token"] as? String ?? saved.idToken, previous: saved)
            try save(next); updateState()
            guard sharing else { throw ChatGPTFailure("ChatGPT plan usage is no longer enabled. Sign in again.") }
            return next.accessToken
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    func loadModels() async throws {
        let id = generation
        let token = try await accessToken()
        var request = URLRequest(url: URL(string: Self.resource + "/models")!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ChatGPTFailure("Could not load this account's ChatGPT models.") }
        guard generation == id else { throw CancellationError() }
        models = ((body["models"] ?? body["data"]) as? [[String: Any]] ?? []).compactMap { row in
            guard (row["visibility"] as? String ?? "list") == "list", let slug = (row["slug"] ?? row["id"]) as? String else { return nil }
            return Model(id: slug, name: row["display_name"] as? String ?? slug)
        }
        guard !models.isEmpty else { throw ChatGPTFailure("This ChatGPT account has no available models for Halo.") }
        if !models.contains(where: { $0.id == selectedModel }) { selectedModel = models[0].id }
    }

    func modelAndToken() async throws -> (String, String) {
        if models.isEmpty { try await loadModels() }
        return (selectedModel, try await accessToken())
    }

    func signOut() async {
        generation = UUID(); signInTask?.cancel(); refreshTask?.cancel()
        let old = session
        do { try Credentials.write(account: "chatgpt-session", data: nil) }
        catch { status = "Could not clear the saved ChatGPT sign-in."; return }
        session = nil; models = []; updateState(); provider = "deepseek"
        guard let old else { return }
        do {
            let request = Self.formRequest(path: "/api/accounts/oauth/revoke", fields: ["token": old.refreshToken, "token_type_hint": "refresh_token", "client_id": old.clientId])
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ChatGPTFailure("Revoke failed") }
            status = "Signed out of ChatGPT"
        } catch { status = "Signed out locally. Remote revocation was not confirmed; disconnect Halo in ChatGPT Settings if needed." }
    }

    private func save(_ value: Session) throws { try Credentials.write(account: "chatgpt-session", data: JSONEncoder().encode(value)); session = value }
    private func updateState() { signedIn = !(session?.refreshToken.isEmpty ?? true); sharing = signedIn && (session?.scopes.contains("chatgpt.tokens.use.direct") ?? false); email = signedIn ? session?.email ?? "" : "" }
    private static func session(_ t: [String: Any], client: String, subject: String, email: String, idToken: String, previous: Session? = nil) throws -> Session {
        guard let access = t["access_token"] as? String, !access.isEmpty,
              let refresh = t["refresh_token"] as? String ?? previous?.refreshToken, !refresh.isEmpty else { throw ChatGPTFailure("ChatGPT returned incomplete credentials. Sign in again.") }
        return Session(clientId: client, subject: subject, email: email, idToken: idToken, accessToken: access, refreshToken: refresh,
                       expiresAt: Date().addingTimeInterval(t["expires_in"] as? Double ?? 3600),
                       scopes: (t["scope"] as? String)?.split(separator: " ").map(String.init) ?? previous?.scopes ?? [])
    }
    private static func formRequest(path: String, fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: issuer + path)!)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents(); form.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        return request
    }
    private static func tokenRequest(_ fields: [String: String]) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: formRequest(path: "/api/accounts/oauth/token", fields: fields))
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (response as? HTTPURLResponse)?.statusCode == 200 else { throw ChatGPTFailure("ChatGPT authorization or refresh failed. Try signing in again.") }
        return body
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ChatGPTFailure("Could not create secure sign-in values.") }
        return b64(Data(bytes))
    }
    private static func b64(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    private static func decode(_ text: String) -> Data? { let s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"); return Data(base64Encoded: s + String(repeating: "=", count: (4 - s.count % 4) % 4)) }
    private static func der(_ tag: UInt8, _ data: Data) -> Data {
        let n = data.count
        let length: [UInt8] = n < 128 ? [UInt8(n)] : n < 256 ? [0x81, UInt8(n)] : [0x82, UInt8(n >> 8), UInt8(n & 255)]
        return Data([tag] + length) + data
    }
    private static func verify(_ jwt: String, client: String, nonce: String) async throws -> [String: Any] {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = decode(parts[0]), let claimsData = decode(parts[1]), let signature = decode(parts[2]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any], header["alg"] as? String == "RS256",
              let kid = header["kid"] as? String, let claims = try JSONSerialization.jsonObject(with: claimsData) as? [String: Any] else { throw ChatGPTFailure("Invalid ChatGPT identity token.") }
        let (data, response) = try await URLSession.shared.data(from: URL(string: issuer + "/.well-known/jwks.json")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let jwks = try JSONSerialization.jsonObject(with: data) as? [String: Any], let keys = jwks["keys"] as? [[String: Any]],
              let jwk = keys.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }),
              let ns = jwk["n"] as? String, let es = jwk["e"] as? String, var n = decode(ns), var e = decode(es), !n.isEmpty, !e.isEmpty else { throw ChatGPTFailure("Could not verify ChatGPT's signing key.") }
        if n[0] & 0x80 != 0 { n.insert(0, at: 0) }; if e[0] & 0x80 != 0 { e.insert(0, at: 0) }
        let keyData = der(0x30, der(0x02, n) + der(0x02, e))
        guard let key = SecKeyCreateWithData(keyData as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil),
              claims["iss"] as? String == issuer, claims["nonce"] as? String == nonce,
              let exp = claims["exp"] as? Double, exp > Date().timeIntervalSince1970 - 60 else { throw ChatGPTFailure("ChatGPT identity validation failed.") }
        let audience = claims["aud"] as? [String] ?? [claims["aud"] as? String ?? ""]
        guard audience.contains(client), audience.count == 1 || claims["azp"] as? String == client else { throw ChatGPTFailure("ChatGPT token belongs to a different app.") }
        return claims
    }
}
