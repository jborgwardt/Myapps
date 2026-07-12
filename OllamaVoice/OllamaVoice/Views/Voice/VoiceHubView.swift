import SwiftUI
import UniformTypeIdentifiers

struct VoiceHubView: View {
    @EnvironmentObject private var app: AppModel
    @State private var filter: TTSEngineKind? = nil
    @State private var cloneName = ""
    @State private var showImporter = false

    private var filteredCatalog: [SpeechModelCatalogItem] {
        let items = app.modelDownloads.catalog
        guard let filter else { return items }
        return items.filter { $0.engine == filter }
    }

    var body: some View {
        NavigationStack {
            List {
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
                        .buttonStyle(.borderedProminent)
                        .tint(app.voiceClones.isRecording ? .red : .accentColor)

                        Button("Import audio") { showImporter = true }
                    }
                    Text("Clones are stored on-device and used as Chatterbox/Kokoro reference prompts for offline TTS. STT uses Apple on-device Speech.")
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
                            .buttonStyle(.bordered)
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

                Section {
                    Picker("Filter", selection: $filter) {
                        Text("All").tag(Optional<TTSEngineKind>.none)
                        ForEach(TTSEngineKind.allCases.filter { $0 != .apple }) { kind in
                            Text(kind.title).tag(Optional(kind))
                        }
                    }
                    .pickerStyle(.segmented)

                    Button("Refresh Piper catalog from Hugging Face") {
                        Task { await app.modelDownloads.refreshPiperCatalog() }
                    }

                    ForEach(filteredCatalog) { item in
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
                                    .background(Color.white.opacity(0.08), in: Capsule())
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
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Download speech models")
                } footer: {
                    Text("Piper ONNX, Kokoro, and Chatterbox (https://github.com/resemble-ai/chatterbox) download into app storage for local/offline use. Apple Speech handles on-device STT.")
                }

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
}
