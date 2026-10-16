import AppKit
import SwiftUI
import HaloCore

struct AppCatalogSettings: View {
    @Bindable var catalog: AppCatalog
    @State private var spokenName = ""
    @State private var selectedID = ""
    @State private var showApps = false

    var body: some View {
        Section("Apps on this Mac") {
            HStack {
                Text(catalog.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { Task { await catalog.refresh() } }.disabled(catalog.isRefreshing)
            }
            DisclosureGroup("Installed apps", isExpanded: $showApps) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(catalog.apps) { app in
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 20, height: 20)
                                Text(app.name)
                            }
                        }
                    }
                }.frame(maxHeight: 150)
            }
            TextField("What I say (for example, streamio)", text: $spokenName)
            Picker("Means this app", selection: $selectedID) {
                Text("Choose an installed app").tag("")
                ForEach(catalog.apps) { app in Text(app.name).tag(app.id) }
            }
            Button("Save spoken name") {
                catalog.saveAlias(spokenName, appID: selectedID)
                spokenName = ""
            }.disabled(spokenName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedID.isEmpty)
            ForEach(catalog.aliases.keys.sorted(), id: \.self) { name in
                HStack {
                    Text("\(name) → \(catalog.apps.first { $0.id == catalog.aliases[name] }?.name ?? "App no longer installed")").font(.caption)
                    Spacer()
                    Button("Remove") { catalog.removeAlias(name) }.font(.caption)
                }
            }
            Text("App names help recognition. If a name is uncertain, Mercy shows the actual apps to choose from.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
