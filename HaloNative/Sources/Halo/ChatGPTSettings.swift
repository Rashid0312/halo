import SwiftUI
import AppKit

struct ChatGPTSettings: View {
    @Bindable var auth: ChatGPTAuth
    var body: some View {
        Section("Brain") {
            Picker("Provider", selection: $auth.provider) {
                Text("DeepSeek").tag("deepseek")
                Text("ChatGPT").tag("chatgpt").disabled(!auth.sharing)
            }
            if auth.signedIn {
                LabeledContent("ChatGPT account", value: auth.email)
                if auth.sharing {
                    if !auth.models.isEmpty {
                        Picker("ChatGPT model", selection: $auth.selectedModel) {
                            ForEach(auth.models) { Text($0.name).tag($0.id) }
                        }
                    }
                    Button("Refresh models") { Task { try? await auth.loadModels() } }
                }
                Button("Sign out of ChatGPT") { Task { await auth.signOut() } }
            }
            if auth.signingIn {
                HStack { ProgressView().controlSize(.small); Text("Waiting for ChatGPT sign-in…") }
                Button("Cancel sign-in") { auth.cancelSignIn() }
            } else {
                Button("Continue with ChatGPT") { auth.startSignIn() }
            }
            if !auth.status.isEmpty { Text(auth.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            Button("Manage ChatGPT usage") { NSWorkspace.shared.open(URL(string: "https://chatgpt.com/settings/usage")!) }
        }
        .task { if auth.sharing && auth.models.isEmpty { try? await auth.loadModels() } }
    }
}
