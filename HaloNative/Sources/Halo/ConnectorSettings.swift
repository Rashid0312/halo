import SwiftUI
import HaloCore

struct ConnectorSettings: View {
    @Bindable var accounts: ConnectorAccounts
    @State private var tokens: [String: String] = [:]
    @State private var clientIDs: [String: String] = [:]
    @State private var secrets: [String: String] = [:]
    @State private var card: String?
    @State private var deleting: String?

    var body: some View {
        Section("Connected apps") {
            ForEach(ConnectorSpec.catalog, id: \.id) { spec in
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent(spec.name, value: accounts.connected.contains(spec.id) ? "Connected" : "Not connected")
                    controls(spec)
                    if let status = accounts.status[spec.id], !status.isEmpty {
                        Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            Text("Each app connects through its own free route: the service's own MCP server, an open-source server run on this Mac, or its API with your token. Anything that sends, posts, pays, or deletes asks first. WhatsApp and Spotify have no free route yet.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Delete this OAuth client?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let spec = deleting.flatMap(ConnectorSpec.spec) { accounts.deleteClient(spec) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Halo forgets the client ID and secret and signs out of \(deleting.flatMap(ConnectorSpec.spec)?.name ?? "this app"). The client still exists in the provider's console; delete it there too if you no longer need it.")
        }
        .sheet(isPresented: Binding(get: { card != nil }, set: { if !$0 { closeCard() } })) {
            if let spec = card.flatMap(ConnectorSpec.spec) {
                ConnectCard(spec: spec, accounts: accounts, close: closeCard)
            }
        }
    }

    private func closeCard() {
        if let spec = card.flatMap(ConnectorSpec.spec) { accounts.dismissCard(spec) }
        card = nil
    }

    @ViewBuilder private func controls(_ spec: ConnectorSpec) -> some View {
        let connected = accounts.connected.contains(spec.id)
        switch spec.auth {
        case .token(let label, let help):
            HStack {
                SecureField(label, text: binding($tokens, spec.id), prompt: Text("Paste \(label.lowercased())"))
                    .textFieldStyle(.roundedBorder).labelsHidden()
                Button("Save") { accounts.saveToken(spec, tokens[spec.id] ?? ""); tokens[spec.id] = "" }
                    .disabled((tokens[spec.id] ?? "").isEmpty)
                if connected { Button("Remove") { accounts.disconnect(spec) } }
            }
            Text(help).font(.caption2).foregroundStyle(.secondary)
        case .configuredOAuth:
            if !accounts.configured.contains(spec.id) {
                Text(setupHelp(spec)).font(.caption2).foregroundStyle(.secondary)
                TextField("OAuth client ID", text: binding($clientIDs, spec.id), prompt: Text("Paste client ID"))
                    .textFieldStyle(.roundedBorder).labelsHidden()
                SecureField("OAuth client secret", text: binding($secrets, spec.id), prompt: Text(spec.id == "slack" ? "Client secret (optional with PKCE)" : "Paste client secret"))
                    .textFieldStyle(.roundedBorder).labelsHidden()
                HStack {
                    if let url = setupURL(spec) { Link("Open \(spec.id == "google" ? "Google Cloud" : "Slack apps")…", destination: url) }
                    Spacer()
                    Button("Save OAuth client") {
                    accounts.saveClient(spec, id: clientIDs[spec.id] ?? "", secret: secrets[spec.id] ?? "", port: "")
                    secrets[spec.id] = ""
                }
                    .disabled((clientIDs[spec.id] ?? "").isEmpty)
                }
            }
            if accounts.configured.contains(spec.id) {
                HStack {
                    Text("OAuth client \(accounts.clientSummary(spec) ?? "")").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete…", role: .destructive) { deleting = spec.id }
                }
            }
            signInButtons(spec, connected: connected, ready: accounts.configured.contains(spec.id))
        case .discoveredOAuth:
            signInButtons(spec, connected: connected, ready: true)
        }
    }

    @ViewBuilder private func signInButtons(_ spec: ConnectorSpec, connected: Bool, ready: Bool) -> some View {
        HStack {
            if accounts.connecting == spec.id {
                ProgressView().controlSize(.small)
                Text("Connecting to \(spec.name)…").font(.caption).foregroundStyle(.secondary)
            } else {
                Button(connected ? "Reconnect…" : "Connect…") { card = spec.id }
                    .disabled(!ready || accounts.connecting != nil)
                if connected { Button("Disconnect") { accounts.disconnect(spec) } }
            }
        }
    }

    /// What to create before Connect works, for services without automatic registration.
    private func setupHelp(_ spec: ConnectorSpec) -> String {
        spec.id == "google"
            ? "One-time setup: in Google Cloud, create a project, enable the Gmail, Calendar, Drive and Sheets APIs, set the consent screen to External and add yourself as a user, then create an OAuth client of type Desktop app. Paste its ID and secret here. Full steps: docs/OAUTH_SETUP.md."
            : "One-time setup: create a Slack app named Halo for your workspace, add the redirect URL and user scopes from docs/OAUTH_SETUP.md, turn on PKCE, and paste its client ID here."
    }

    private func setupURL(_ spec: ConnectorSpec) -> URL? {
        spec.id == "google" ? URL(string: "https://console.cloud.google.com/auth/clients") : URL(string: "https://api.slack.com/apps")
    }

    private func binding(_ values: Binding<[String: String]>, _ key: String) -> Binding<String> {
        Binding(get: { values.wrappedValue[key] ?? "" }, set: { values.wrappedValue[key] = $0 })
    }
}
