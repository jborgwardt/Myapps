import Foundation
import SwiftUI
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var selectedTab: AppTab = .chat

    let ollama: OllamaClient
    let speechRecognizer: SpeechRecognizer
    let ttsManager: TTSManager
    let modelDownloads: ModelDownloadManager
    let voiceClones: VoiceCloneManager
    let localLLM: LocalLLMManager
    let localEngine: LocalChatEngine

    private var cancellables = Set<AnyCancellable>()

    init() {
        let settings = AppSettings.load()
        self.settings = settings
        // Voice-first by default; `-startTab chat` launch arg overrides (debug/screenshots).
        if let override = UserDefaults.standard.string(forKey: "startTab"),
           let tab = AppTab(rawValue: override) {
            self.selectedTab = tab
        } else {
            self.selectedTab = .voice
        }
        // Placeholder URL until the user configures an optional Ollama backend.
        let bootstrap = settings.ollamaBaseURL ?? URL(string: "http://127.0.0.1:\(AppSettings.defaultPort)")!
        self.ollama = OllamaClient(baseURL: bootstrap)
        self.speechRecognizer = SpeechRecognizer()
        self.modelDownloads = ModelDownloadManager()
        self.voiceClones = VoiceCloneManager()
        self.localLLM = LocalLLMManager()
        self.localEngine = LocalChatEngine()
        self.ttsManager = TTSManager(
            downloads: modelDownloads,
            voiceClones: voiceClones,
            settings: settings
        )

        $settings
            .map(\.ollamaBaseURL)
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] url in
                guard let url else { return }
                Task { await self?.ollama.updateBaseURL(url) }
            }
            .store(in: &cancellables)

        $settings
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] updated in
                guard let self else { return }
                AppSettings.save(updated)
                self.ttsManager.applySettings(updated)
            }
            .store(in: &cancellables)
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case chat, models, voice, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: "Chat"
        case .models: "Models"
        case .voice: "Voice"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .models: "cylinder.split.1x2"
        case .voice: "waveform.and.mic"
        case .settings: "gearshape"
        }
    }
}

enum OllamaURLScheme: String, Codable, CaseIterable, Identifiable {
    case http
    case https

    var id: String { rawValue }

    var title: String { rawValue.uppercased() }
}

struct AppSettings: Codable, Equatable {
    var ollamaScheme: OllamaURLScheme
    var ollamaHost: String
    var ollamaPort: Int
    /// Optional path prefix (e.g. `/ollama`) when behind a reverse proxy.
    var ollamaPathPrefix: String
    var selectedChatModel: String?
    var ttsEngine: TTSEngineKind
    var selectedPiperVoice: String?
    var selectedKokoroVoice: String?
    var selectedVoiceCloneID: UUID?
    var speakResponses: Bool
    var chatterboxEndpoint: String?

    /// Empty = Ollama disabled until the user opts in.
    static let defaultHost = ""
    static let defaultPort = 11434
    static let settingsSchemaKey = "app.settings.schema"
    static let currentSchema = 2

    /// Suggested lightweight abliterated coding model that also works well with spoken replies.
    static let suggestedCodingModel = "dagbs/qwen2.5-coder-1.5b-instruct-abliterated:latest"

    enum CodingKeys: String, CodingKey {
        case ollamaScheme, ollamaHost, ollamaPort, ollamaPathPrefix
        case selectedChatModel, ttsEngine, selectedPiperVoice, selectedKokoroVoice
        case selectedVoiceCloneID, speakResponses, chatterboxEndpoint
    }

    init(
        ollamaScheme: OllamaURLScheme,
        ollamaHost: String,
        ollamaPort: Int,
        ollamaPathPrefix: String,
        selectedChatModel: String?,
        ttsEngine: TTSEngineKind,
        selectedPiperVoice: String?,
        selectedKokoroVoice: String?,
        selectedVoiceCloneID: UUID?,
        speakResponses: Bool,
        chatterboxEndpoint: String?
    ) {
        self.ollamaScheme = ollamaScheme
        self.ollamaHost = ollamaHost
        self.ollamaPort = ollamaPort
        self.ollamaPathPrefix = ollamaPathPrefix
        self.selectedChatModel = selectedChatModel
        self.ttsEngine = ttsEngine
        self.selectedPiperVoice = selectedPiperVoice
        self.selectedKokoroVoice = selectedKokoroVoice
        self.selectedVoiceCloneID = selectedVoiceCloneID
        self.speakResponses = speakResponses
        self.chatterboxEndpoint = chatterboxEndpoint
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ollamaScheme = try c.decodeIfPresent(OllamaURLScheme.self, forKey: .ollamaScheme) ?? .http
        ollamaHost = try c.decodeIfPresent(String.self, forKey: .ollamaHost) ?? Self.defaultHost
        ollamaPort = try c.decodeIfPresent(Int.self, forKey: .ollamaPort) ?? Self.defaultPort
        ollamaPathPrefix = try c.decodeIfPresent(String.self, forKey: .ollamaPathPrefix) ?? ""
        selectedChatModel = try c.decodeIfPresent(String.self, forKey: .selectedChatModel)
        ttsEngine = try c.decodeIfPresent(TTSEngineKind.self, forKey: .ttsEngine) ?? .apple
        selectedPiperVoice = try c.decodeIfPresent(String.self, forKey: .selectedPiperVoice)
        selectedKokoroVoice = try c.decodeIfPresent(String.self, forKey: .selectedKokoroVoice)
        selectedVoiceCloneID = try c.decodeIfPresent(UUID.self, forKey: .selectedVoiceCloneID)
        speakResponses = try c.decodeIfPresent(Bool.self, forKey: .speakResponses) ?? true
        chatterboxEndpoint = try c.decodeIfPresent(String.self, forKey: .chatterboxEndpoint)
    }

    var isOllamaConfigured: Bool {
        !ollamaHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Prefix marking a model that runs on-device instead of via Ollama.
    static let localModelPrefix = "local:"

    var selectedModelIsLocal: Bool {
        selectedChatModel?.hasPrefix(Self.localModelPrefix) == true
    }

    var selectedLocalModelFileName: String? {
        guard let selectedChatModel, selectedChatModel.hasPrefix(Self.localModelPrefix) else { return nil }
        return String(selectedChatModel.dropFirst(Self.localModelPrefix.count))
    }

    var ollamaBaseURL: URL? {
        guard isOllamaConfigured else { return nil }
        let host = ollamaHost.trimmingCharacters(in: .whitespacesAndNewlines)
        var normalizedPrefix = ollamaPathPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedPrefix.isEmpty, !normalizedPrefix.hasPrefix("/") {
            normalizedPrefix = "/" + normalizedPrefix
        }
        if normalizedPrefix.hasSuffix("/") {
            normalizedPrefix.removeLast()
        }
        let port = (1...65535).contains(ollamaPort) ? ollamaPort : Self.defaultPort
        return URL(string: "\(ollamaScheme.rawValue)://\(host):\(port)\(normalizedPrefix)")
    }

    static func `default`() -> AppSettings {
        AppSettings(
            ollamaScheme: .http,
            ollamaHost: defaultHost,
            ollamaPort: defaultPort,
            ollamaPathPrefix: "",
            selectedChatModel: nil,
            ttsEngine: .apple,
            selectedPiperVoice: "en_US-amy-medium",
            selectedKokoroVoice: "af_heart",
            selectedVoiceCloneID: nil,
            speakResponses: true,
            chatterboxEndpoint: nil
        )
    }

    static func load() -> AppSettings {
        let storedSchema = UserDefaults.standard.integer(forKey: settingsSchemaKey)
        if let data = UserDefaults.standard.data(forKey: "app.settings"),
           var decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            // Schema 2: Ollama is optional — clear the old baked-in Tailscale default.
            if storedSchema < currentSchema, decoded.ollamaHost == "100.64.0.2" {
                decoded.ollamaHost = ""
                decoded.selectedChatModel = nil
            }
            UserDefaults.standard.set(currentSchema, forKey: settingsSchemaKey)
            return decoded
        }
        UserDefaults.standard.set(currentSchema, forKey: settingsSchemaKey)
        return .default()
    }

    static func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "app.settings")
            UserDefaults.standard.set(currentSchema, forKey: settingsSchemaKey)
        }
    }
}

enum TTSEngineKind: String, Codable, CaseIterable, Identifiable {
    case apple
    case piper
    case kokoro
    case chatterbox

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: "Apple Speech"
        case .piper: "Piper (on-device)"
        case .kokoro: "Kokoro (on-device)"
        case .chatterbox: "Chatterbox"
        }
    }

    var detail: String {
        switch self {
        case .apple: "Built-in AVSpeechSynthesizer + Personal Voice"
        case .piper: "Download ONNX voices from Hugging Face"
        case .kokoro: "Core ML Kokoro-82M voices"
        case .chatterbox: "Resemble AI — highest quality + voice clone"
        }
    }
}
