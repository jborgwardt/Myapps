import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var testResult: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Ollama") {
                    TextField("Host", text: $app.settings.ollamaHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                    TextField("Port", value: $app.settings.ollamaPort, format: .number)
                        .keyboardType(.numberPad)
                    LabeledContent("URL", value: app.settings.ollamaBaseURL.absoluteString)
                    Button("Test connection") {
                        Task {
                            do {
                                let ok = try await app.ollama.health()
                                let models = try await app.ollama.listLocalModels()
                                testResult = ok ? "OK — \(models.count) models" : "Unreachable"
                            } catch {
                                testResult = error.localizedDescription
                            }
                        }
                    }
                    if let testResult {
                        Text(testResult).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Chatterbox") {
                    TextField(
                        "Optional HTTP endpoint (e.g. http://100.64.0.2:8000)",
                        text: Binding(
                            get: { app.settings.chatterboxEndpoint ?? "" },
                            set: { app.settings.chatterboxEndpoint = $0.isEmpty ? nil : $0 }
                        )
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    Text("When set, Chatterbox TTS posts to `/tts` with text + optional base64 voice prompt. Leave empty to use on-device downloaded weights.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("Chatterbox on GitHub", destination: URL(string: "https://github.com/resemble-ai/chatterbox")!)
                }

                Section("Speech") {
                    Picker("Default TTS", selection: $app.settings.ttsEngine) {
                        ForEach(TTSEngineKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    Toggle("Speak responses", isOn: $app.settings.speakResponses)
                    Button("Request mic + speech permission") {
                        Task { await app.speechRecognizer.requestAuthorization() }
                    }
                    LabeledContent("Speech auth", value: "\(app.speechRecognizer.authorizationStatus.rawValue)")
                }

                Section("About") {
                    Text("Ollama Voice talks to your Ollama host over Tailscale, downloads Piper/Kokoro/Chatterbox models for on-device speech, and clones voices for offline TTS. STT uses Apple’s on-device Speech framework.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
