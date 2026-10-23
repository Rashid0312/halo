import Foundation

/// Optional ~/Library/Application Support/<bundle id>/oauth.json: the hosted
/// OAuth callback, Halo's public branding for dynamic registration, and each
/// provider's own OAuth client id. Holds nothing secret; client secrets live
/// only in Credentials (see docs/OAUTH_SETUP.md).
///
///     {
///       "callbackURL": "https://auth.example.com/oauth/callback",
///       "branding": { "name": "Halo", "homepage": "https://…", "logo": "https://…/logo.png",
///                     "privacyPolicy": "https://…", "terms": "https://…", "supportEmail": "…" },
///       "clients": { "google": { "clientId": "….apps.googleusercontent.com" },
///                    "slack": { "clientId": "…" } }
///     }
struct OAuthSettings: Codable {
    struct Branding: Codable, Equatable {
        var name: String?
        var homepage: String?
        var logo: String?
        var privacyPolicy: String?
        var terms: String?
        var supportEmail: String?
    }

    struct Client: Codable {
        var clientId: String
        var redirectPort: UInt16?
        /// True for a client that only accepts loopback (a Google "Desktop app" client).
        var loopback: Bool?
    }

    /// The one place Halo's hosted callback is set. Providers send the user
    /// there; it forwards the code to halo://oauth/callback.
    var callbackURL: String?
    var branding = Branding()
    var clients: [String: Client] = [:]

    static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(Bundle.main.bundleIdentifier ?? "app.halo.native.dev")/oauth.json")
    }

    /// The redirect a provider should use: the hosted HTTPS callback once it is
    /// configured (oauth.json, or HALO_OAUTH_CALLBACK_URL in development
    /// builds), else nil, meaning a one-time 127.0.0.1 loopback.
    static func callback(for provider: String) -> String? {
        let settings = load()
        if settings.clients[provider]?.loopback == true { return nil }
        let value = settings.callbackURL ?? (Credentials.isDevelopmentBuild ? Credentials.developmentEnvironmentValue("HALO_OAUTH_CALLBACK_URL") : "")
        guard let url = URL(string: value), url.scheme == "https", url.host != nil, url.query == nil else { return nil }
        return value
    }

    /// Empty settings when the file is missing or unreadable.
    static func load() -> OAuthSettings {
        guard let data = try? Data(contentsOf: file) else { return OAuthSettings() }
        return (try? JSONDecoder().decode(OAuthSettings.self, from: data)) ?? OAuthSettings()
    }
}
