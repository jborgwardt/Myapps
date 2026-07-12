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

    private var cancellables = Set<AnyCancellable>()

    init() {
        let settings = AppSettings.load()
        self.settings = settings
        self.ollama = OllamaClient(baseURL: settings.ollamaBaseURL)
        self.speechRecognizer = SpeechRecognizer()
        self.modelDownloads = ModelDownloadManager()
        self.voiceClones = VoiceCloneManager()
        self.ttsManager = TTSManager(
            downloads: modelDownloads,
            voiceClones: voiceClones,
            settings: settings
        )

        $settings
            .map(\.ollamaBaseURL)
            .removeDuplicates()
            .sink { [weak self] url in
                Task { await self?.ollama.updateBaseURL(url) }
                AppSettings.save(self?.settings ?? settings)
            }
            .store(in: &cancellables)

        $settings
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

struct AppSettings: Codable, Equatable {
    var ollamaHost: String
    var ollamaPort: Int
    var selectedChatModel: String?
    var ttsEngine: TTSEngineKind
    var selectedPiperVoice: String?
    var selectedKokoroVoice: String?
    var selectedVoiceCloneID: UUID?
    var speakResponses: Bool
    var chatterboxEndpoint: String?

    static let defaultHost = "100.64.0.2"
    static let defaultPort = 11434

    var ollamaBaseURL: URL {
        URL(string: "http://\(ollamaHost):\(ollamaPort)")!
    }

    static func load() -> AppSettings {
        if let data = UserDefaults.standard.data(forKey: "app.settings"),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return decoded
        }
        return AppSettings(
            ollamaHost: defaultHost,
            ollamaPort: defaultPort,
            selectedChatModel: nil,
            ttsEngine: .apple,
            selectedPiperVoice: "en_US-amy-medium",
            selectedKokoroVoice: "af_heart",
            selectedVoiceCloneID: nil,
            speakResponses: true,
            chatterboxEndpoint: nil
        )
    }

    static func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "app.settings")
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
