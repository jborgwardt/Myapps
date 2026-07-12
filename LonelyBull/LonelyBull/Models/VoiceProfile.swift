import Foundation

struct VoiceProfile: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var createdAt: Date
    var referenceAudioRelativePath: String
    var engine: TTSEngineKind
    var notes: String

    var referenceURL: URL {
        VoiceCloneManager.profilesDirectory.appendingPathComponent(referenceAudioRelativePath)
    }
}

struct DownloadedSpeechModel: Identifiable, Codable, Equatable, Hashable {
    let id: String
    var engine: TTSEngineKind
    var displayName: String
    var relativePath: String
    var downloadedAt: Date
    var byteSize: Int64
    var metadata: [String: String]

    var localURL: URL {
        ModelDownloadManager.modelsRoot.appendingPathComponent(relativePath)
    }

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }
}

struct SpeechModelCatalogItem: Identifiable, Hashable {
    let id: String
    let engine: TTSEngineKind
    let displayName: String
    let detail: String
    let quality: String
    let language: String
    let approximateBytes: Int64
    let downloadURLs: [URL]
    /// Relative folder under Application Support/SpeechModels
    let installFolder: String

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: approximateBytes, countStyle: .file)
    }
}
