import SwiftUI

struct ModelsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var local: [OllamaLocalModel] = []
    @State private var query = ""
    @State private var pulling: String?
    @State private var pullProgress: Double?
    @State private var pullStatus = ""
    @State private var errorText: String?
    @State private var customName = ""

    private var filteredCatalog: [OllamaCatalogEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return OllamaCatalogEntry.curated }
        return OllamaCatalogEntry.curated.filter {
            $0.name.lowercased().contains(q)
                || $0.description.lowercased().contains(q)
                || $0.tags.contains(where: { $0.contains(q) })
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Pull any model name (e.g. llama3.2:3b)", text: $customName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Pull") {
                            Task { await pull(customName) }
                        }
                        .disabled(customName.isEmpty || pulling != nil)
                    }
                    if let pulling {
                        VStack(alignment: .leading) {
                            Text("Pulling \(pulling)…")
                            if let pullProgress {
                                ProgressView(value: pullProgress)
                            } else {
                                ProgressView()
                            }
                            Text(pullStatus).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let errorText {
                        Text(errorText).foregroundStyle(.red).font(.caption)
                    }
                } header: {
                    Text("Save to Ollama host")
                }

                Section("On \(app.settings.ollamaHost)") {
                    if local.isEmpty {
                        Text("No local models yet — pull one below.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(local) { model in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(model.name).font(.headline)
                                Text(model.displaySize).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Use") {
                                app.settings.selectedChatModel = model.name
                            }
                            .buttonStyle(.bordered)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await delete(model.name) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }

                Section("Browse & search") {
                    ForEach(filteredCatalog) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(entry.name).font(.headline)
                                Spacer()
                                Text(entry.sizeHint).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(entry.description).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                ForEach(entry.tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption2)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.white.opacity(0.08), in: Capsule())
                                }
                                Spacer()
                                Button(local.contains(where: { $0.name.hasPrefix(entry.name) }) ? "Saved" : "Pull & save") {
                                    Task { await pull(entry.name) }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(pulling != nil)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Models")
            .searchable(text: $query, prompt: "Search models")
            .refreshable { await refresh() }
            .task { await refresh() }
        }
    }

    private func refresh() async {
        do {
            local = try await app.ollama.listLocalModels()
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func pull(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pulling = trimmed
        pullProgress = nil
        pullStatus = "starting"
        errorText = nil
        do {
            for try await status in await app.ollama.pullModel(name: trimmed) {
                pullStatus = status.status ?? ""
                pullProgress = status.progress
            }
            await refresh()
            app.settings.selectedChatModel = trimmed
        } catch {
            errorText = error.localizedDescription
        }
        pulling = nil
    }

    private func delete(_ name: String) async {
        do {
            try await app.ollama.deleteModel(name: name)
            await refresh()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
