import SwiftUI
import HaloCore

/// The native card shown when connecting an app: who is asking (Halo), what it
/// will be able to do, where sign-in happens, then progress and the result.
/// Never shows the callback address. Claims no verification Halo does not have.
struct ConnectCard: View {
    let spec: ConnectorSpec
    @Bindable var accounts: ConnectorAccounts
    let close: () -> Void

    private var phase: ConnectorAccounts.Phase { accounts.phase[spec.id] ?? .idle }
    private var ready: Bool { !spec.isConfiguredClient || accounts.configured.contains(spec.id) }

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                HaloMark(size: 44)
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                Text(String(spec.name.prefix(1)))
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 11))
            }
            Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            content.frame(maxWidth: .infinity, alignment: .leading)
            buttons
        }
        .padding(24)
        .frame(width: 400)
        .interactiveDismissDisabled(phase == .preparing || phase == .waitingForBrowser)
    }

    private var title: String {
        switch phase {
        case .connected: "\(spec.name) is connected"
        case .preparing, .waitingForBrowser: "Connecting to \(spec.name)…"
        case .failed: "Couldn't connect \(spec.name)"
        case .idle: "Connect \(spec.name) to Halo"
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .idle:
            VStack(alignment: .leading, spacing: 10) {
                Label("Halo can search and read your \(spec.name) data when you ask it to.", systemImage: "magnifyingglass")
                Label("Anything that creates, sends, changes, or deletes asks you first.", systemImage: "hand.raised")
                Label("Sign-in opens in your browser\(ConnectCard.host(spec).map { " at \($0)" } ?? ""). You'll come back here when you approve.", systemImage: "safari")
                if spec.id == "google" {
                    Text("Until Halo's Google app is verified, Google may show a warning that it hasn't verified this app. That warning comes from Google, not from Halo.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !ready {
                    Text("Add \(spec.name)'s OAuth client in Settings first (see docs/OAUTH_SETUP.md).").font(.caption).foregroundStyle(.orange)
                }
            }
            .font(.callout)
        case .preparing:
            progress("Preparing a secure sign-in…")
        case .waitingForBrowser:
            progress("Approve Halo in the \(spec.name) page that opened in your browser. This card updates when you're done.")
        case .connected:
            Label("Ask Halo about \(spec.name) anytime. You can disconnect it in Settings.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout).textSelection(.enabled)
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            switch phase {
            case .idle:
                Button("Not now") { close() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Continue in browser") { accounts.connect(spec) }
                    .keyboardShortcut(.defaultAction).disabled(!ready || accounts.connecting != nil)
            case .preparing, .waitingForBrowser:
                Spacer()
                Button("Cancel") { accounts.cancel() }.keyboardShortcut(.cancelAction)
            case .connected:
                Spacer()
                Button("Done") { close() }.keyboardShortcut(.defaultAction)
            case .failed:
                Button("Close") { close() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Try again") { accounts.connect(spec) }.keyboardShortcut(.defaultAction)
            }
        }
    }

    /// The sign-in site, so the user knows where they will be sent.
    static func host(_ spec: ConnectorSpec) -> String? {
        switch spec.auth {
        case .configuredOAuth(let authorize, _, _, _): URL(string: authorize)?.host
        case .discoveredOAuth: if case .hostedMCP(let url) = spec.route { URL(string: url)?.host?.split(separator: ".").suffix(2).joined(separator: ".") } else { nil }
        case .token: nil
        }
    }
}

/// Halo's mark: the same gradient orb as the sign-in return page.
struct HaloMark: View {
    var size: CGFloat
    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [Color(red: 0.65, green: 0.71, blue: 0.99), Color(red: 0.39, green: 0.40, blue: 0.95), Color(red: 0.26, green: 0.22, blue: 0.79)],
                                 center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.75))
            .frame(width: size, height: size)
    }
}
