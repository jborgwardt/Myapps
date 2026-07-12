import Foundation
import AVFoundation

enum SpeechModelError: LocalizedError {
    case notDownloaded(String)
    case missingFiles(String)
    case synthesisFailed(String)
    case remoteFailed(String)

    var errorDescription: String? {
        switch self {
        case .notDownloaded(let id): "Model not downloaded: \(id)"
        case .missingFiles(let detail): "Missing model files: \(detail)"
        case .synthesisFailed(let detail): "Synthesis failed: \(detail)"
        case .remoteFailed(let detail): "Remote TTS failed: \(detail)"
        }
    }
}

/// Piper ONNX voices — download from Hugging Face; playback uses generated WAV when a
/// local synthesizer binary/framework is present, otherwise falls back with a clear error
/// so the manager can use Apple TTS.
@MainActor
final class PiperTTSEngine: TTSEngine {
    let kind: TTSEngineKind = .piper
    var selectedVoiceID: String? = "en_US-amy-medium"
    private let downloads: ModelDownloadManager
    private var player: AVAudioPlayer?

    init(downloads: ModelDownloadManager) {
        self.downloads = downloads
    }

    var isSpeaking: Bool { player?.isPlaying == true }

    func speak(_ text: String, voiceClone: VoiceProfile?) async throws {
        guard let voiceID = selectedVoiceID else {
            throw SpeechModelError.notDownloaded("piper voice")
        }
        guard let model = downloads.installed.first(where: { $0.id == voiceID && $0.engine == .piper }) else {
            throw SpeechModelError.notDownloaded(voiceID)
        }

        let folder = model.localURL
        let onnx = try Self.findFile(in: folder, suffix: ".onnx")
        let config = try Self.findFile(in: folder, suffix: ".onnx.json")

        // Prefer on-device Piper via a small process/bridge when available (macOS Catalyst / future SPM).
        // For iOS we synthesize through the bundled PiperBridge which shells to onnxruntime when linked.
        let wavURL = try await PiperBridge.synthesize(
            text: text,
            modelURL: onnx,
            configURL: config,
            outputDirectory: FileManager.default.temporaryDirectory
        )
        try await play(wavURL)
    }

    func stop() {
        player?.stop()
        player = nil
    }

    private func play(_ url: URL) async throws {
        let player = try AVAudioPlayer(contentsOf: url)
        self.player = player
        player.prepareToPlay()
        player.play()
        while player.isPlaying {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private static func findFile(in folder: URL, suffix: String) throws -> URL {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        if suffix == ".onnx.json" {
            guard let json = files.first(where: { $0.lastPathComponent.hasSuffix(".onnx.json") }) else {
                throw SpeechModelError.missingFiles(folder.path)
            }
            return json
        }
        guard let onnx = files.first(where: { $0.pathExtension == "onnx" }) else {
            throw SpeechModelError.missingFiles(folder.path)
        }
        return onnx
    }
}

/// Bridge that attempts Piper synthesis. Without native onnxruntime linkage it writes a
/// marker and throws so callers fall back — download/catalog still works fully offline-ready.
enum PiperBridge {
    static func synthesize(text: String, modelURL: URL, configURL: URL, outputDirectory: URL) async throws -> URL {
        // When piper-objc / onnxruntime SPM is linked, replace this with native inference.
        // Until then, if a companion CLI exists (developer Mac), use it; else signal fallback.
        #if os(macOS)
        let cli = URL(fileURLWithPath: "/opt/homebrew/bin/piper")
        if FileManager.default.isExecutableFile(atPath: cli.path) {
            let out = outputDirectory.appendingPathComponent("piper-\(UUID().uuidString).wav")
            let process = Process()
            process.executableURL = cli
            process.arguments = ["--model", modelURL.path, "--config", configURL.path, "--output_file", out.path]
            let stdin = Pipe()
            process.standardInput = stdin
            try process.run()
            stdin.fileHandleForWriting.write(Data(text.utf8))
            try? stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            if process.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) {
                return out
            }
        }
        #endif
        throw SpeechModelError.synthesisFailed(
            "Piper model is installed at \(modelURL.lastPathComponent). Add piper-objc SPM for on-device ONNX inference, or keep Apple/Kokoro/Chatterbox selected."
        )
    }
}

@MainActor
final class KokoroTTSEngine: TTSEngine {
    let kind: TTSEngineKind = .kokoro
    var selectedVoiceID: String? = "af_heart"
    private let downloads: ModelDownloadManager
    private var player: AVAudioPlayer?

    init(downloads: ModelDownloadManager) {
        self.downloads = downloads
    }

    var isSpeaking: Bool { player?.isPlaying == true }

    func speak(_ text: String, voiceClone: VoiceProfile?) async throws {
        let voice = selectedVoiceID ?? "af_heart"
        guard let model = downloads.installed.first(where: { $0.engine == .kokoro && ($0.id == "kokoro-core" || $0.id == voice) })
                ?? downloads.installed.first(where: { $0.engine == .kokoro }) else {
            throw SpeechModelError.notDownloaded("kokoro")
        }

        // Core ML package directory — when mlmodelc/mlpackage present, run KokoroCoreMLRunner.
        let result = try await KokoroCoreMLRunner.synthesize(
            text: text,
            voiceID: voice,
            modelDirectory: model.localURL
        )
        let player = try AVAudioPlayer(contentsOf: result)
        self.player = player
        player.prepareToPlay()
        player.play()
        while player.isPlaying {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func stop() {
        player?.stop()
        player = nil
    }
}

enum KokoroCoreMLRunner {
    static func synthesize(text: String, voiceID: String, modelDirectory: URL) async throws -> URL {
        let fm = FileManager.default
        let packages = (try? fm.contentsOfDirectory(at: modelDirectory, includingPropertiesForKeys: nil)) ?? []
        let hasCoreML = packages.contains { $0.pathExtension == "mlpackage" || $0.pathExtension == "mlmodelc" }
        guard hasCoreML else {
            throw SpeechModelError.missingFiles("Kokoro Core ML packages in \(modelDirectory.lastPathComponent)")
        }

        // Full Core ML graph (duration → f0 → decoder) is large; integration point for
        // mattmireles/kokoro-coreml or mlalma/kokoro-ios once packages are on disk.
        // Voice embedding .npy/.bin for `voiceID` should live alongside.
        let voiceFile = modelDirectory.appendingPathComponent("voices/\(voiceID).bin")
        if !fm.fileExists(atPath: voiceFile.path) {
            let alt = modelDirectory.appendingPathComponent("\(voiceID).pt")
            if !fm.fileExists(atPath: alt.path) {
                throw SpeechModelError.missingFiles("voice embedding \(voiceID)")
            }
        }

        throw SpeechModelError.synthesisFailed(
            "Kokoro Core ML weights are present. Wire KokoroSwift/CoreML runner for Neural Engine inference (models ready at \(modelDirectory.path))."
        )
    }
}
