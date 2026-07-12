import SwiftUI
import UniformTypeIdentifiers

struct VoiceHubView: View {
    @EnvironmentObject private var app: AppModel
    @State private var filter: TTSEngineKind? = nil
    @State private var cloneName = ""
    @State private var showImporter = false

    @State private var hfQuery = ""
    @State private var hfHits: [HuggingFaceModelHit] = []
    @State private var piperHits: [SpeechModelCatalogItem] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?

    private let hf = HuggingFaceSearchService()

    private var filteredCatalog: [SpeechModelCatalogItem] {
        let items = app.modelDownloads.catalog
        guard let filter else { return items }
        return items.filter { $0.engine == filter }
    }

    var body: some View {
        NavigationStack {
            List {
                playbackSection.cursorRows()
                cloneSection.cursorRows()
                huggingFaceSearchSection.cursorRows()
                starterCatalogSection.cursorRows()
                installedSection.cursorRows()
            }
            .cursorScreen()
            .navigationTitle("Voice")
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio, .wav, .mpeg4Audio]) { result in
                if case .success(let url) = result {
                    app.voiceClones.importAudio(
                        from: url,
                        name: cloneName.isEmpty ? url.deletingPathExtension().lastPathComponent : cloneName,
                        engine: .chatterbox
                    )
                    cloneName = ""
                }
            }
        }
    }

    private var playbackSection: some View {
        Section {
            Picker("TTS engine", selection: $app.settings.ttsEngine) {
                ForEach(TTSEngineKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.inline)
            Text(app.settings.ttsEngine.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Speak chat replies", isOn: $app.settings.speakResponses)

            if app.settings.ttsEngine == .piper {
                Picker("Piper voice", selection: Binding(
                    get: { app.settings.selectedPiperVoice ?? "" },
                    set: { app.settings.selectedPiperVoice = $0 }
                )) {
                    ForEach(app.modelDownloads.installed.filter { $0.engine == .piper }) { m in
                        Text(m.displayName).tag(m.id)
                    }
                }
            }
            if app.settings.ttsEngine == .kokoro {
                Picker("Kokoro voice", selection: Binding(
                    get: { app.settings.selectedKokoroVoice ?? "af_heart" },
                    set: { app.settings.selectedKokoroVoice = $0 }
                )) {
                    Text("af_heart").tag("af_heart")
                    Text("af_bella").tag("af_bella")
                    ForEach(app.modelDownloads.installed.filter { $0.engine == .kokoro }) { m in
                        Text(m.displayName).tag(m.id)
                    }
                }
            }
        } header: {
            Text("Playback")
        }
    }

    private var cloneSection: some View {
        Section {
            TextField("Clone name", text: $cloneName)
            HStack {
                Button(app.voiceClones.isRecording ? "Stop & save" : "Record reference (10s+)") {
                    if app.voiceClones.isRecording {
                        app.voiceClones.stopRecordingAndSave(
                            name: cloneName,
                            engine: app.settings.ttsEngine == .apple ? .chatterbox : app.settings.ttsEngine
                        )
                        cloneName = ""
                    } else {
                        app.voiceClones.startRecording()
                    }
                }
                .glassProminentButton()
                .tint(app.voiceClones.isRecording ? .red : .accentColor)

                Button("Import audio") { showImporter = true }
                    .glassButton()
            }
            Text("Clones are stored on-device for Chatterbox-style offline TTS. STT uses Apple on-device Speech.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(app.voiceClones.profiles) { profile in
                HStack {
                    VStack(alignment: .leading) {
                        Text(profile.name).font(.headline)
                        Text("\(profile.engine.title) · \(profile.createdAt.formatted())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if app.settings.selectedVoiceCloneID == profile.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Button("Use") {
                        app.settings.selectedVoiceCloneID = profile.id
                        if profile.engine == .chatterbox {
                            app.settings.ttsEngine = .chatterbox
                        }
                    }
                    .glassButton()
                }
                .swipeActions {
                    Button(role: .destructive) {
                        if app.settings.selectedVoiceCloneID == profile.id {
                            app.settings.selectedVoiceCloneID = nil
                        }
                        app.voiceClones.delete(profile)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            Text("Voice clone (offline)")
        }
    }

    private var huggingFaceSearchSection: some View {
        Section {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Hugging Face (piper, kokoro, chatterbox…)", text: $hfQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: hfQuery) { _, newValue in
                        scheduleSearch(newValue)
                    }
                if isSearching {
                    ProgressView()
                }
                if !hfQuery.isEmpty {
                    Button {
                        hfQuery = ""
                        hfHits = []
                        piperHits = []
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

            if !piperHits.isEmpty {
                Text("Piper voices")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(piperHits.prefix(25)) { item in
                    catalogRow(item)
                }
            }

            if !hfHits.isEmpty {
                Text("Hugging Face models")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(hfHits) { hit in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(hit.displayName).font(.headline)
                            Spacer()
                            Text(hit.engineHint.title)
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(CursorTheme.surfaceHigh, in: Capsule())
                        }
                        Text(hit.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            if app.modelDownloads.isInstalled("hf:\(hit.modelID)") {
                                Text("Saved").foregroundStyle(.green).font(.caption)
                                Button("Remove") {
                                    app.modelDownloads.delete(id: "hf:\(hit.modelID)")
                                }
                            } else if let p = app.modelDownloads.progress["hf:\(hit.modelID)"] {
                                ProgressView(value: p)
                                Text(app.modelDownloads.statusMessage["hf:\(hit.modelID)"] ?? "")
                                    .font(.caption2)
                            } else {
                                Button("Download for on-device") {
                                    Task { await downloadHF(hit) }
                                }
                                .glassProminentButton()
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else if !isSearching && hfQuery.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
                        && piperHits.isEmpty && searchError == nil {
                Text("No on-device speech models found. Try “piper en”, “kokoro”, or “chatterbox”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Search on-device models (Hugging Face)")
        } footer: {
            Text("Searches Hugging Face TTS repos plus the official Piper voices.json catalog. Downloads land in app storage for offline use.")
        }
    }

    private var starterCatalogSection: some View {
        Section {
            Picker("Filter", selection: $filter) {
                Text("All").tag(Optional<TTSEngineKind>.none)
                ForEach(TTSEngineKind.allCases.filter { $0 != .apple }) { kind in
                    Text(kind.title).tag(Optional(kind))
                }
            }
            .pickerStyle(.segmented)

            Button("Load full Piper catalog") {
                Task { await app.modelDownloads.refreshPiperCatalog() }
            }

            ForEach(filteredCatalog) { item in
                catalogRow(item)
            }
        } header: {
            Text("Starter downloads")
        }
    }

    @ViewBuilder
    private var installedSection: some View {
        if !app.modelDownloads.installed.isEmpty {
            Section("Installed on this device") {
                ForEach(app.modelDownloads.installed) { model in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(model.displayName)
                            Text("\(model.engine.title) · \(model.displaySize)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Delete", role: .destructive) {
                            app.modelDownloads.delete(id: model.id)
                        }
                    }
                }
            }
        }
    }

    private func catalogRow(_ item: SpeechModelCatalogItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.displayName).font(.headline)
                Spacer()
                Text(item.displaySize).font(.caption2).foregroundStyle(.secondary)
            }
            Text(item.detail).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(item.engine.title)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(CursorTheme.surfaceHigh, in: Capsule())
                Spacer()
                if app.modelDownloads.isInstalled(item.id) {
                    Button("Remove") { app.modelDownloads.delete(id: item.id) }
                    Text("Saved").foregroundStyle(.green).font(.caption)
                } else if let p = app.modelDownloads.progress[item.id] {
                    ProgressView(value: p)
                    Text(app.modelDownloads.statusMessage[item.id] ?? "")
                        .font(.caption2)
                } else {
                    Button("Download") {
                        Task { await app.modelDownloads.download(item) }
                    }
                    .glassProminentButton()
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func scheduleSearch(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            hfHits = []
            piperHits = []
            searchError = nil
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await runSearch(trimmed)
        }
    }

    private func runSearch(_ query: String) async {
        isSearching = true
        searchError = nil
        do {
            async let repos = hf.searchSpeechModels(query: query)
            async let voices = hf.searchPiperVoices(query: query)
            let (r, v) = try await (repos, voices)
            guard !Task.isCancelled else { return }
            hfHits = r
            piperHits = v
        } catch {
            if !Task.isCancelled {
                searchError = error.localizedDescription
                hfHits = []
                piperHits = []
            }
        }
        isSearching = false
    }

    private func downloadHF(_ hit: HuggingFaceModelHit) async {
        do {
            let item = try await hf.catalogItem(for: hit)
            await app.modelDownloads.download(item)
            if hit.engineHint == .piper {
                app.settings.selectedPiperVoice = item.id
                app.settings.ttsEngine = .piper
            } else if hit.engineHint == .kokoro {
                app.settings.selectedKokoroVoice = item.id
                app.settings.ttsEngine = .kokoro
            } else if hit.engineHint == .chatterbox {
                app.settings.ttsEngine = .chatterbox
            }
        } catch {
            app.modelDownloads.lastError = error.localizedDescription
            searchError = "Could not prepare download: \(error.localizedDescription)"
        }
    }
}
