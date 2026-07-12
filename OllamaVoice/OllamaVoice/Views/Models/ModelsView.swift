import SwiftUI

struct ModelsView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var puller = ModelPullController()
    @State private var local: [OllamaLocalModel] = []
    @State private var pasteField = AppSettings.suggestedCodingModel
    @State private var query = ""
    @State private var hfHits: [HuggingFaceLLMHit] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var listError: String?

    private let hf = HuggingFaceSearchService()

    private var parsedPasteName: String? {
        OllamaPasteParser.modelName(from: pasteField)
    }

    private var ollamaReady: Bool { app.settings.isOllamaConfigured }

    var body: some View {
        NavigationStack {
            List {
                if !ollamaReady {
                    Section {
                        Text("Ollama is optional. Voice works on-device without it. Add a host in Settings only if you want server-side chat/pulls.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Open Settings") { app.selectedTab = .settings }
                    } header: {
                        Text("No Ollama backend")
                    }
                }

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
                    .disabled(!ollamaReady || puller.isPulling)

                    if let parsed = parsedPasteName {
                        LabeledContent("Will pull", value: parsed)
                            .font(.caption)
                    }

                    Button {
                        guard let name = parsedPasteName else { return }
                        guard let url = app.settings.ollamaBaseURL else { return }
                        puller.pull(name: name, client: app.ollama, baseURL: url)
                    } label: {
                        Text(puller.isPulling ? "Pulling…" : "Pull & save to Ollama")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!ollamaReady || parsedPasteName == nil || puller.isPulling)

                    if puller.isPulling || puller.fraction != nil || !puller.statusText.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            if !puller.modelName.isEmpty {
                                Text(puller.modelName)
                                    .font(.caption)
                                    .textSelection(.enabled)
                            }
                            if let fraction = puller.fraction {
                                ProgressView(value: fraction)
                                    .progressViewStyle(.linear)
                            } else if puller.isPulling {
                                ProgressView()
                                    .progressViewStyle(.linear)
                            }
                            HStack {
                                Text(puller.statusText)
                                Spacer()
                                if let fraction = puller.fraction {
                                    Text("\(Int(fraction * 100))%")
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            if !puller.byteLabel.isEmpty {
                                Text(puller.byteLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if puller.isPulling {
                                Button("Cancel", role: .destructive) { puller.cancel() }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    if let error = puller.errorText ?? listError {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                            .textSelection(.enabled)
                    } else if puller.didSucceed {
                        Text(puller.statusText)
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                } header: {
                    Text("Pull to optional Ollama host")
                } footer: {
                    Text("Prefilled suggestion: lightweight abliterated coding model that pairs well with spoken replies. Paste any `ollama run …` or ollama.com link.")
                }

                if ollamaReady {
                    Section("Installed on \(app.settings.ollamaHost)") {
                        if local.isEmpty {
                            Text("Nothing installed on this host yet.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(local) { model in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(model.name).font(.headline)
                                    Text(model.displaySize).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Use") { app.settings.selectedChatModel = model.name }
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
                        Button("Pull suggested coding agent") {
                            pasteField = AppSettings.suggestedCodingModel
                            guard let url = app.settings.ollamaBaseURL else { return }
                            puller.pull(name: AppSettings.suggestedCodingModel, client: app.ollama, baseURL: url)
                        }
                        .disabled(puller.isPulling)

                        ForEach(OllamaCatalogEntry.curated) { entry in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(entry.name).font(.headline)
                                    Text(entry.description).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Pull") {
                                    guard let url = app.settings.ollamaBaseURL else { return }
                                    puller.pull(name: entry.name, client: app.ollama, baseURL: url)
                                }
                                .disabled(puller.isPulling)
                            }
                        }
                    } header: {
                        Text("Suggestions")
                    }

                    Section {
                        HStack {
                            TextField("Search Hugging Face GGUF", text: $query)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .onChange(of: query) { _, newValue in scheduleSearch(newValue) }
                            if isSearching { ProgressView() }
                        }
                        if let searchError { Text(searchError).font(.caption).foregroundStyle(.red) }
                        ForEach(hfHits.prefix(20)) { hit in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(hit.modelID).font(.subheadline)
                                Text(hit.detail).font(.caption2).foregroundStyle(.secondary)
                                Button("Pull") {
                                    Task { await pullHF(hit) }
                                }
                                .disabled(puller.isPulling)
                            }
                        }
                    } header: {
                        Text("Hugging Face (optional)")
                    }
                }
            }
            .navigationTitle("Models")
            .refreshable { await refresh() }
            .task { await refresh() }
            .onChange(of: puller.didSucceed) { _, ok in
                if ok {
                    Task { await refresh() }
                    if !puller.modelName.isEmpty {
                        app.settings.selectedChatModel = puller.modelName
                    }
                }
            }
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

    private func pullHF(_ hit: HuggingFaceLLMHit) async {
        guard let url = app.settings.ollamaBaseURL else { return }
        do {
            let name = try await hf.resolveOllamaPullName(for: hit)
            puller.pull(name: name, client: app.ollama, baseURL: url)
        } catch {
            listError = error.localizedDescription
        }
    }

    private func refresh() async {
        guard ollamaReady, let url = app.settings.ollamaBaseURL else {
            local = []
            return
        }
        do {
            await app.ollama.updateBaseURL(url)
            local = try await app.ollama.listLocalModels()
            listError = nil
        } catch {
            listError = error.localizedDescription
            local = []
        }
    }

    private func delete(_ name: String) async {
        do {
            try await app.ollama.deleteModel(name: name)
            await refresh()
        } catch {
            listError = error.localizedDescription
        }
    }
}
