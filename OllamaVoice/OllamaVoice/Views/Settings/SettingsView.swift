import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var testResult: String?
    @State private var portText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Use Ollama backend", isOn: Binding(
                        get: { app.settings.isOllamaConfigured },
                        set: { enabled in
                            if enabled {
                                if app.settings.ollamaHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    app.settings.ollamaHost = "127.0.0.1"
                                }
                            } else {
                                app.settings.ollamaHost = ""
                                app.settings.selectedChatModel = nil
                            }
                        }
                    ))

                    if app.settings.isOllamaConfigured {
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

                        if let url = app.settings.ollamaBaseURL {
                            LabeledContent("URL", value: url.absoluteString)
                        }

                        Button("Test connection") {
                            Task { await testConnection() }
                        }
                        if let testResult {
                            Text(testResult)
                                .font(.caption)
                                .foregroundStyle(testResult.hasPrefix("OK") ? .green : .secondary)
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    Text("Ollama (optional)")
                } footer: {
                    Text("Off by default. Voice / STT / on-device model downloads work without any server. Turn this on only if you have an Ollama host to chat or pull into.")
                }

                Section("Suggested model") {
                    Text(AppSettings.suggestedCodingModel)
                        .font(.caption)
                        .textSelection(.enabled)
                    Text("Lightweight abliterated coding agent that also works well with spoken replies once Ollama is connected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                }

                Section("About") {
                    Text("Starts on Voice. Ollama is an optional backend you can wire up anytime.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")
                }
            }
            .navigationTitle("Settings")
            .onAppear { portText = String(app.settings.ollamaPort) }
            .onChange(of: app.settings.ollamaPort) { _, newValue in
                let rendered = String(newValue)
                if portText != rendered { portText = rendered }
            }
        }
    }

    private func testConnection() async {
        guard let url = app.settings.ollamaBaseURL else {
            testResult = "Enter a host first"
            return
        }
        testResult = "Testing \(url.absoluteString)…"
        await app.ollama.updateBaseURL(url)
        do {
            let ok = try await app.ollama.health()
            let models = try await app.ollama.listLocalModels()
            testResult = ok ? "OK — \(models.count) models" : "Unreachable"
        } catch {
            testResult = error.localizedDescription
        }
    }
}
