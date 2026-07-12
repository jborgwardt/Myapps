import Foundation
import AVFoundation
import Combine

@MainActor
final class VoiceCloneManager: ObservableObject {
    @Published private(set) var profiles: [VoiceProfile] = []
    @Published var isRecording = false
    @Published var lastError: String?

    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?

    nonisolated static var profilesDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("OllamaVoice/VoiceClones", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var manifestURL: URL {
        Self.profilesDirectory.appendingPathComponent("profiles.json")
    }

    init() {
        load()
    }

    func startRecording() {
        lastError = nil
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)

            let url = Self.profilesDirectory.appendingPathComponent("rec-\(UUID().uuidString).wav")
            recordingURL = url
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 24000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.record()
            isRecording = true
        } catch {
            lastError = error.localizedDescription
            isRecording = false
        }
    }

    func stopRecordingAndSave(name: String, engine: TTSEngineKind) {
        audioRecorder?.stop()
        isRecording = false
        guard let recordingURL else { return }

        let fileName = "\(UUID().uuidString).wav"
        let dest = Self.profilesDirectory.appendingPathComponent(fileName)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: recordingURL, to: dest)
            let profile = VoiceProfile(
                id: UUID(),
                name: name.isEmpty ? "Voice \(profiles.count + 1)" : name,
                createdAt: .now,
                referenceAudioRelativePath: fileName,
                engine: engine,
                notes: "Reference clip for offline TTS clone (\(engine.title))"
            )
            profiles.insert(profile, at: 0)
            save()
        } catch {
            lastError = error.localizedDescription
        }
        self.recordingURL = nil
        audioRecorder = nil
    }

    func delete(_ profile: VoiceProfile) {
        try? FileManager.default.removeItem(at: profile.referenceURL)
        profiles.removeAll { $0.id == profile.id }
        save()
    }

    func importAudio(from url: URL, name: String, engine: TTSEngineKind) {
        let fileName = "\(UUID().uuidString).\(url.pathExtension.isEmpty ? "wav" : url.pathExtension)"
        let dest = Self.profilesDirectory.appendingPathComponent(fileName)
        do {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: url, to: dest)
            let profile = VoiceProfile(
                id: UUID(),
                name: name,
                createdAt: .now,
                referenceAudioRelativePath: fileName,
                engine: engine,
                notes: "Imported reference audio"
            )
            profiles.insert(profile, at: 0)
            save()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([VoiceProfile].self, from: data) else {
            profiles = []
            return
        }
        profiles = decoded.filter { FileManager.default.fileExists(atPath: $0.referenceURL.path) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }
}
