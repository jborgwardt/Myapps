import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var testResult: String?
    @State private var portText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Scheme", selection: $app.settings.ollamaScheme) {
                        ForEach(OllamaURLScheme.allCases) { scheme in
                            Text(scheme.title).tag(scheme)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("Host", text: $app.settings.ollamaHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)

                    TextField("Port", text: $portText)
                        .keyboardType(.numberPad)
                        .onChange(of: portText) { _, newValue in
                            let digits = newValue.filter(\.isNumber)
                            if digits != newValue { portText = digits }
                            if let port = Int(digits), (1...65535).contains(port) {
                                app.settings.ollamaPort = port
                            }
                        }

                    TextField("Path prefix (optional)", text: $app.settings.ollamaPathPrefix)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)

                    LabeledContent("URL", value: app.settings.ollamaBaseURL.absoluteString)

                    Button("Test connection") {
                        Task { await testConnection() }
                    }
                    if let testResult {
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(testResult.hasPrefix("OK") ? .green : .secondary)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Ollama")
                } footer: {
                    Text("Use HTTP for direct Tailscale/LAN Ollama. Switch to HTTPS if you front it with Caddy/NPM or another TLS proxy. Path prefix is for mounts like https://host/ollama.")
                }

                Section("Chatterbox") {
                    TextField(
                        "Optional endpoint (http:// or https://)",
                        text: Binding(
                            get: { app.settings.chatterboxEndpoint ?? "" },
                            set: { app.settings.chatterboxEndpoint = $0.isEmpty ? nil : $0 }
                        )
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
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
                    Text("Ollama Voice talks to your Ollama host over Tailscale or HTTPS, downloads Piper/Kokoro/Chatterbox models for on-device speech, and clones voices for offline TTS. STT uses Apple’s on-device Speech framework.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                portText = String(app.settings.ollamaPort)
            }
            .onChange(of: app.settings.ollamaPort) { _, newValue in
                let rendered = String(newValue)
                if portText != rendered { portText = rendered }
            }
        }
    }

    private func testConnection() async {
        testResult = "Testing \(app.settings.ollamaBaseURL.absoluteString)…"
        // Force client onto latest URL before probe
        await app.ollama.updateBaseURL(app.settings.ollamaBaseURL)
        do {
            let ok = try await app.ollama.health()
            let models = try await app.ollama.listLocalModels()
            testResult = ok
                ? "OK — \(models.count) models @ \(app.settings.ollamaBaseURL.absoluteString)"
                : "Unreachable"
        } catch {
            testResult = error.localizedDescription
        }
    }
}
