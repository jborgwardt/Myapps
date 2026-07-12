import SwiftUI

struct ModelsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var local: [OllamaLocalModel] = []
    @State private var query = ""
    @State private var pulling: String?
    @State private var pullProgress: Double?
    @State private var pullStatus = ""
    @State private var errorText: String?
    @State private var pasteField = ""

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

    private var parsedPasteName: String? {
        OllamaPasteParser.modelName(from: pasteField)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField(
                        "Paste ollama run …, ollama.com link, or model name",
                        text: $pasteField,
                        axis: .vertical
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .lineLimit(1...4)

                    if let parsed = parsedPasteName {
                        LabeledContent("Will pull", value: parsed)
                            .font(.caption)
                    }

                    Button {
                        Task { await pullFromPaste() }
                    } label: {
                        if pulling != nil {
                            HStack {
                                ProgressView()
                                Text("Pulling…")
                            }
                        } else {
                            Text("Pull & save locally")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(parsedPasteName == nil || pulling != nil)

                    if let pulling {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(pulling).font(.caption).textSelection(.enabled)
                            if let pullProgress {
                                ProgressView(value: pullProgress)
                                Text("\(Int(pullProgress * 100))% · \(pullStatus)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                ProgressView()
                                Text(pullStatus)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let errorText {
                        Text(errorText)
                            .foregroundStyle(.red)
                            .font(.caption)
                            .textSelection(.enabled)
                    } else if pullStatus.lowercased().hasPrefix("saved") {
                        Text(pullStatus)
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                } header: {
                    Text("Paste run command or link")
                } footer: {
                    Text("Examples: `ollama run richardyoung/qwythos-9b-abliterated` · https://ollama.com/richardyoung/qwythos-9b-abliterated · llama3.2:3b")
                }

                Section("Installed on \(app.settings.ollamaHost)") {
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
                        TextField("Search Hugging Face (optional)", text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: query) { _, newValue in
                                scheduleSearch(newValue)
                            }
                        if isSearching { ProgressView() }
                    }

                    if let searchError {
                        Text(searchError).font(.caption).foregroundStyle(.red)
                    }

                    ForEach(hfHits) { hit in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(hit.modelID).font(.headline)
                            Text(hit.detail).font(.caption).foregroundStyle(.secondary)
                            Button("Pull & save locally") {
                                Task { await pullHF(hit) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(pulling != nil)
                        }
                    }
                } header: {
                    Text("Hugging Face → Ollama")
                }

                Section("Quick picks") {
                    ForEach(filteredCatalog) { entry in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(entry.name).font(.headline)
                                Text(entry.description).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Pull") {
                                Task { await pull(entry.name) }
                            }
                            .disabled(pulling != nil)
                        }
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
            do {
                hfHits = try await hf.searchLLMModels(query: trimmed)
                searchError = nil
            } catch {
                searchError = error.localizedDescription
                hfHits = []
            }
            isSearching = false
        }
    }

    private func pullFromPaste() async {
        guard let name = parsedPasteName else {
            errorText = "Couldn’t parse a model name from that text."
            return
        }
        await pull(name)
    }

    private func pullHF(_ hit: HuggingFaceLLMHit) async {
        do {
            pulling = hit.modelID
            pullStatus = "Resolving GGUF quant…"
            errorText = nil
            let name = try await hf.resolveOllamaPullName(for: hit)
            await pull(name)
        } catch {
            errorText = error.localizedDescription
            pulling = nil
        }
    }

    private func refresh() async {
        do {
            local = try await app.ollama.listLocalModels()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func pull(_ name: String) async {
        let trimmed = OllamaClient.normalizePullName(name)
        guard !trimmed.isEmpty else { return }
        pulling = trimmed
        pullProgress = nil
        pullStatus = "starting"
        errorText = nil
        do {
            await app.ollama.updateBaseURL(app.settings.ollamaBaseURL)
            for try await status in await app.ollama.pullModel(name: trimmed) {
                if let err = status.error, !err.isEmpty {
                    throw OllamaError.pullFailed(err)
                }
                pullStatus = status.status ?? pullStatus
                if let progress = status.progress {
                    pullProgress = progress
                }
            }
            await refresh()
            if let match = local.first(where: {
                OllamaClient.modelMatchesPull(localName: $0.name, pullName: trimmed)
            }) {
                app.settings.selectedChatModel = match.name
                pullStatus = "Saved \(match.name)"
                pasteField = ""
            } else {
                app.settings.selectedChatModel = trimmed
                pullStatus = "Saved \(trimmed)"
            }
        } catch {
            errorText = error.localizedDescription
            pullStatus = "Failed"
        }
        pulling = nil
        pullProgress = nil
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
