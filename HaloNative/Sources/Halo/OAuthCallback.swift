import AppKit

/// Receives halo://oauth/callback?state=…&code=… (or &error=…) from the browser
/// via application(_:open:) and hands it to the sign-in waiting on that state.
/// This is the last hop: providers redirect to Halo's hosted HTTPS callback
/// (infra/oauth-callback), which forwards here. Providers never see halo://.
/// A callback whose state no sign-in is waiting for is dropped. The code is
/// useless without that sign-in's PKCE verifier, which never leaves Halo.
@MainActor
final class OAuthCallbackRouter {
    static let shared = OAuthCallbackRouter()
    nonisolated static let scheme = "halo"
    nonisolated static let redirect = "halo://oauth/callback"
    private var waiting: [String: CheckedContinuation<URL, Error>] = [:]

    /// Waits up to five minutes for the callback carrying `state`.
    func wait(state: String, service: String) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                waiting[state] = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(300))
                    self?.finish(state, with: .failure(ChatGPTFailure("\(service) sign-in timed out. Try again.")))
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(state, with: .failure(CancellationError())) }
        }
    }

    /// True when `url` is an OAuth callback (handled or not), so the caller
    /// never treats it as anything else. Never logs the URL.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == Self.scheme, url.host == "oauth", url.path == "/callback" else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let states = items.filter { $0.name == "state" }.compactMap(\.value)
        guard states.count == 1, waiting[states[0]] != nil else { return true }
        finish(states[0], with: .success(url))
        // Bring Halo back in front of the browser so the user sees the result.
        NSApp.activate()
        return true
    }

    private func finish(_ state: String, with result: Result<URL, Error>) {
        waiting.removeValue(forKey: state)?.resume(with: result)
    }
}
