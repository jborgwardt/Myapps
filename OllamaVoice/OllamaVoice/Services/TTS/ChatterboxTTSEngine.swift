import Foundation
import AVFoundation

/// Chatterbox (Resemble AI) — https://github.com/resemble-ai/chatterbox
/// Supports: local Core ML / ONNX artifacts download, optional remote FastAPI endpoint,
/// and zero-shot voice cloning from a saved reference WAV.
@MainActor
final class ChatterboxTTSEngine: TTSEngine {
    let kind: TTSEngineKind = .chatterbox
    var remoteEndpoint: URL?
    private let downloads: ModelDownloadManager
    private let voiceClones: VoiceCloneManager
    private var player: AVAudioPlayer?

    init(downloads: ModelDownloadManager, voiceClones: VoiceCloneManager) {
        self.downloads = downloads
        self.voiceClones = voiceClones
    }

    var isSpeaking: Bool { player?.isPlaying == true }

    func speak(_ text: String, voiceClone: VoiceProfile?) async throws {
        // Prefer remote sidecar (e.g. panzer GPU/CPU chatterbox server) when configured
        if let endpoint = remoteEndpoint {
            let wav = try await synthesizeRemote(text: text, endpoint: endpoint, voiceClone: voiceClone)
            try await play(wav)
            return
        }

        guard let model = downloads.installed.first(where: { $0.engine == .chatterbox }) else {
            throw SpeechModelError.notDownloaded("chatterbox")
        }

        let wav = try await ChatterboxLocalRunner.synthesize(
            text: text,
            modelDirectory: model.localURL,
            referenceAudio: voiceClone?.referenceURL
        )
        try await play(wav)
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

    private func synthesizeRemote(text: String, endpoint: URL, voiceClone: VoiceProfile?) async throws -> URL {
        var request = URLRequest(url: endpoint.appending(path: "tts"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = ["text": text]
        if let voiceClone, let data = try? Data(contentsOf: voiceClone.referenceURL) {
            body["audio_prompt_b64"] = data.base64EncodedString()
            body["voice_name"] = voiceClone.name
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw SpeechModelError.remoteFailed(msg)
        }

        // Accept raw WAV bytes or JSON { "audio_b64": "..." }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("chatterbox-\(UUID().uuidString).wav")
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let b64 = json["audio_b64"] as? String,
           let decoded = Data(base64Encoded: b64) {
            try decoded.write(to: out)
        } else {
            try data.write(to: out)
        }
        return out
    }
}

enum ChatterboxLocalRunner {
    static func synthesize(text: String, modelDirectory: URL, referenceAudio: URL?) async throws -> URL {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: modelDirectory, includingPropertiesForKeys: nil)) ?? []
        let hasArtifacts = contents.contains {
            ["mlpackage", "mlmodelc", "onnx", "safetensors"].contains($0.pathExtension)
        }
        guard hasArtifacts else {
            throw SpeechModelError.missingFiles("Chatterbox artifacts in \(modelDirectory.path)")
        }

        // Integration point for Core ML hybrid pipeline (T3 prefill + ONNX decode) —
        // see huggingface.co/ebrinz/chatterbox-turbo-coreml
        if let referenceAudio, !fm.fileExists(atPath: referenceAudio.path) {
            throw SpeechModelError.missingFiles("voice clone reference audio")
        }

        throw SpeechModelError.synthesisFailed(
            "Chatterbox models downloaded. Enable Core ML/ONNX runtime or set a Chatterbox HTTP endpoint in Settings for synthesis. Ref: https://github.com/resemble-ai/chatterbox"
        )
    }
}
