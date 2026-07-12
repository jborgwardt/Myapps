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
                onDeviceSection
                curatedLocalSection
                searchSection
                ollamaSections
            }
            .cursorScreen()
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

    // MARK: On this iPhone

    private var onDeviceSection: some View {
        Section {
            if app.localLLM.installed.isEmpty && activeDownloadKeys.isEmpty {
                Text("Nothing downloaded yet. Grab a starter below — chat then runs fully on this iPhone, offline, no server.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ForEach(app.localLLM.installed) { model in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.displayName).font(.headline)
                        Text("\(model.displaySize) · on-device")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if app.settings.selectedChatModel == AppSettings.localModelPrefix + model.fileName {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Use") {
                            app.settings.selectedChatModel = AppSettings.localModelPrefix + model.fileName
                            app.selectedTab = .chat
                        }
                        .glassButton()
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        if app.settings.selectedChatModel == AppSettings.localModelPrefix + model.fileName {
                            app.settings.selectedChatModel = nil
                        }
                        app.localLLM.delete(model)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

            ForEach(activeDownloadKeys, id: \.self) { key in
                downloadProgressRow(key: key)
            }

            if let error = app.localLLM.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        } header: {
            Text("On this iPhone")
        } footer: {
            Text("GGUF models run locally with llama.cpp (Metal). No Ollama, no network needed after download.")
        }
        .cursorRows()
    }

    private var activeDownloadKeys: [String] {
        app.localLLM.progress.keys.sorted()
    }

    private func downloadProgressRow(key: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(key.split(separator: "/").last.map(String.init) ?? key)
                .font(.caption)
                .lineLimit(1)
            ProgressView(value: app.localLLM.progress[key] ?? 0)
                .progressViewStyle(.linear)
            HStack {
                Text(app.localLLM.statusMessage[key] ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((app.localLLM.progress[key] ?? 0) * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Cancel", role: .destructive) {
                    app.localLLM.cancelDownload(key: key)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Curated starters

    private var curatedLocalSection: some View {
        Section {
            ForEach(LocalLLMManager.curated) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(entry.displayName).font(.headline)
                        Spacer()
                        Text("~\(entry.displaySize)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        if app.localLLM.isInstalled(fileNameContaining: entry.repoID) {
                            Text("Saved").font(.caption).foregroundStyle(.green)
                        } else if app.localLLM.progress[entry.repoID] != nil {
                            Text(app.localLLM.statusMessage[entry.repoID] ?? "Downloading…")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Download") {
                                app.localLLM.download(repoID: entry.repoID)
                            }
                            .glassProminentButton()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Get local models")
        } footer: {
            Text("Q4_K_M quants picked automatically. 1.5B and under is the sweet spot for phones.")
        }
        .cursorRows()
    }

    // MARK: Hugging Face search

    private var searchSection: some View {
        Section {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Hugging Face GGUF", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: query) { _, newValue in scheduleSearch(newValue) }
                if isSearching { ProgressView() }
            }
            if let searchError {
                Text(searchError).font(.caption).foregroundStyle(.red)
            }
            ForEach(hfHits.prefix(20)) { hit in
                VStack(alignment: .leading, spacing: 6) {
                    Text(hit.modelID).font(.subheadline)
                    Text(hit.detail).font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        if hit.isGGUF {
                            if app.localLLM.progress[hit.modelID] != nil {
                                Text(app.localLLM.statusMessage[hit.modelID] ?? "Downloading…")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                Button("Save to iPhone") {
                                    app.localLLM.download(repoID: hit.modelID)
                                }
                                .glassProminentButton()
                            }
                        }
                        Spacer()
                        if ollamaReady {
                            Button("Pull to Ollama") {
                                Task { await pullHF(hit) }
                            }
                            .glassButton()
                            .disabled(puller.isPulling)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Search Hugging Face")
        } footer: {
            Text("GGUF repos can be saved straight to this iPhone. Pulling to an Ollama host is optional.")
        }
        .cursorRows()
    }

    // MARK: Ollama (optional server)

    @ViewBuilder
    private var ollamaSections: some View {
        if !ollamaReady {
            Section {
                Text("Optional: connect an Ollama server to chat against bigger models on your own hardware.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Open Settings") { app.selectedTab = .settings }
                    .glassButton()
            } header: {
                Text("Ollama server (optional)")
            }
            .cursorRows()
        } else {
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
                .disabled(puller.isPulling)

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
                .glassProminentButton()
                .disabled(parsedPasteName == nil || puller.isPulling)

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
                Text("Pull to \(app.settings.ollamaHost)")
            } footer: {
                Text("Paste any `ollama run …` or ollama.com link.")
            }
            .cursorRows()

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
                            .glassButton()
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
            .cursorRows()

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
                        .glassButton()
                        .disabled(puller.isPulling)
                    }
                }
            } header: {
                Text("Server suggestions")
            }
            .cursorRows()
        }
    }

    // MARK: Logic

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
