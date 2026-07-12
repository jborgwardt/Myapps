import Foundation
import AVFoundation
import AudioToolbox

protocol TTSEngine: AnyObject {
    var kind: TTSEngineKind { get }
    func speak(_ text: String, voiceClone: VoiceProfile?) async throws
    func stop()
    var isSpeaking: Bool { get }
}

@MainActor
final class TTSManager: ObservableObject {
    @Published var engineKind: TTSEngineKind
    @Published var isSpeaking = false
    @Published var lastError: String?

    private let downloads: ModelDownloadManager
    private let voiceClones: VoiceCloneManager
    private var settings: AppSettings

    private lazy var appleEngine = AppleTTSEngine()
    private lazy var piperEngine = PiperTTSEngine(downloads: downloads)
    private lazy var kokoroEngine = KokoroTTSEngine(downloads: downloads)
    private lazy var chatterboxEngine = ChatterboxTTSEngine(downloads: downloads, voiceClones: voiceClones)

    init(downloads: ModelDownloadManager, voiceClones: VoiceCloneManager, settings: AppSettings) {
        self.downloads = downloads
        self.voiceClones = voiceClones
        self.settings = settings
        self.engineKind = settings.ttsEngine
    }

    func applySettings(_ settings: AppSettings) {
        self.settings = settings
        engineKind = settings.ttsEngine
        piperEngine.selectedVoiceID = settings.selectedPiperVoice
        kokoroEngine.selectedVoiceID = settings.selectedKokoroVoice
        chatterboxEngine.remoteEndpoint = settings.chatterboxEndpoint.flatMap(URL.init(string:))
    }

    func speak(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastError = nil
        isSpeaking = true
        defer { isSpeaking = false }

        let clone = settings.selectedVoiceCloneID.flatMap { id in
            voiceClones.profiles.first(where: { $0.id == id })
        }

        do {
            switch engineKind {
            case .apple:
                try await appleEngine.speak(trimmed, voiceClone: clone)
            case .piper:
                try await piperEngine.speak(trimmed, voiceClone: clone)
            case .kokoro:
                try await kokoroEngine.speak(trimmed, voiceClone: clone)
            case .chatterbox:
                try await chatterboxEngine.speak(trimmed, voiceClone: clone)
            }
        } catch {
            lastError = error.localizedDescription
            // Graceful fallback so chat replies still get spoken
            if engineKind != .apple {
                try? await appleEngine.speak(trimmed, voiceClone: nil)
            }
        }
    }

    func stop() {
        appleEngine.stop()
        piperEngine.stop()
        kokoroEngine.stop()
        chatterboxEngine.stop()
        isSpeaking = false
    }
}

@MainActor
final class AppleTTSEngine: NSObject, TTSEngine, AVSpeechSynthesizerDelegate {
    let kind: TTSEngineKind = .apple
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Error>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    func speak(_ text: String, voiceClone: VoiceProfile?) async throws {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        // Prefer a Personal Voice / cloned Apple voice when available
        if let personal = AVSpeechSynthesisVoice.speechVoices().first(where: {
            $0.voiceTraits.contains(.isPersonalVoice)
        }) {
            utterance.voice = personal
        } else if let en = AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = en
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.continuation = cont
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        continuation?.resume()
        continuation = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            continuation?.resume()
            continuation = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            continuation?.resume()
            continuation = nil
        }
    }
}
