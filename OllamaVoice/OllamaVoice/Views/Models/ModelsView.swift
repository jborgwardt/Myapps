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

    @State private var hfHits: [HuggingFaceLLMHit] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?

    private let hf = HuggingFaceSearchService()

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
                        TextField("Pull name or hf.co/org/repo", text: $customName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
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
                        Text(errorText).foregroundStyle(.red).font(.caption).textSelection(.enabled)
                    }
                } header: {
                    Text("Save to Ollama (\(app.settings.ollamaHost))")
                } footer: {
                    Text("Pulls install on your Ollama host for local chat. Hugging Face GGUF repos use `hf.co/org/model`.")
                }

                Section("Installed locally") {
                    if local.isEmpty {
                        Text("No models on the Ollama host yet.")
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

                Section {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search Hugging Face (llama, qwen, phi…)", text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: query) { _, newValue in
                                scheduleSearch(newValue)
                            }
                        if isSearching {
                            ProgressView()
                        }
                        if !query.isEmpty {
                            Button {
                                query = ""
                                hfHits = []
                                searchError = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let searchError {
                        Text(searchError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if !hfHits.isEmpty {
                        ForEach(hfHits) { hit in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(hit.modelID).font(.headline)
                                    Spacer()
                                    if hit.isGGUF {
                                        Text("GGUF")
                                            .font(.caption2)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Color.green.opacity(0.2), in: Capsule())
                                    }
                                }
                                Text(hit.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(hit.ollamaPullName)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                                HStack {
                                    Spacer()
                                    let already = local.contains {
                                        $0.name.contains(hit.modelID)
                                            || $0.name == hit.ollamaPullName
                                            || $0.name.hasPrefix("hf.co/\(hit.modelID)")
                                    }
                                    Button(already ? "Saved" : "Pull & save locally") {
                                        Task { await pull(hit.ollamaPullName) }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(pulling != nil || already)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } else if !isSearching,
                              query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2,
                              searchError == nil {
                        Text("No Hugging Face LLM hits yet. Try “llama 3.2”, “qwen2.5 7b”, or “phi3 gguf”.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Search Hugging Face → Ollama")
                } footer: {
                    Text("Live search on huggingface.co. GGUF repos pull straight into your local Ollama via `hf.co/…`.")
                }

                Section("Quick picks") {
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
            .refreshable { await refresh() }
            .task { await refresh() }
        }
    }

    private func scheduleSearch(_ raw: String) {
        searchTask?.cancel()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            hfHits = []
            searchError = nil
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await runHFSearch(trimmed)
        }
    }

    private func runHFSearch(_ query: String) async {
        isSearching = true
        searchError = nil
        do {
            let hits = try await hf.searchLLMModels(query: query)
            guard !Task.isCancelled else { return }
            hfHits = hits
        } catch {
            if !Task.isCancelled {
                searchError = error.localizedDescription
                hfHits = []
            }
        }
        isSearching = false
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
