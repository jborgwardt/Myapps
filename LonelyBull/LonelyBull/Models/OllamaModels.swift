import Foundation

struct OllamaTagList: Codable {
    let models: [OllamaLocalModel]
}

struct OllamaLocalModel: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let model: String?
    let modifiedAt: String?
    let size: Int64?
    let digest: String?
    let details: OllamaModelDetails?

    enum CodingKeys: String, CodingKey {
        case name, model, size, digest, details
        case modifiedAt = "modified_at"
    }

    var displaySize: String {
        guard let size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

struct OllamaModelDetails: Codable, Hashable {
    let format: String?
    let family: String?
    let parameterSize: String?
    let quantizationLevel: String?

    enum CodingKeys: String, CodingKey {
        case format, family
        case parameterSize = "parameter_size"
        case quantizationLevel = "quantization_level"
    }
}

struct OllamaChatRequest: Encodable {
    let model: String
    let messages: [OllamaChatMessage]
    let stream: Bool
}

struct OllamaChatMessage: Codable {
    let role: String
    let content: String
}

struct OllamaChatChunk: Decodable {
    let model: String?
    let message: OllamaChatMessage?
    let done: Bool?
}

struct OllamaPullStatus: Decodable {
    let status: String?
    let digest: String?
    let total: Int64?
    let completed: Int64?
    let error: String?

    var progress: Double? {
        guard let total, total > 0, let completed else { return nil }
        return min(1, Double(completed) / Double(total))
    }
}

/// Curated searchable catalog (Ollama library names). Live `/api/tags` covers installed models;
/// this list powers browse/search/pull for popular models offline.
struct OllamaCatalogEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let tags: [String]
    let sizeHint: String

    static let curated: [OllamaCatalogEntry] = [
        .init(
            id: "coder-ablit",
            name: AppSettings.suggestedCodingModel,
            description: "Lightweight abliterated Qwen2.5 coder (~1.5B) — good default for voice + coding",
            tags: ["code", "abliterated", "voice"],
            sizeHint: "~1–2 GB"
        ),
        .init(id: "llama3.2:1b", name: "llama3.2:1b", description: "Tiny Llama 3.2 for fast spoken chat", tags: ["chat", "small", "voice"], sizeHint: "~1.3 GB"),
        .init(id: "llama3.2:3b", name: "llama3.2:3b", description: "Llama 3.2 3B — still voice-friendly", tags: ["chat", "small"], sizeHint: "~2 GB"),
        .init(id: "phi3:mini", name: "phi3:mini", description: "Phi-3 Mini", tags: ["chat", "small"], sizeHint: "~2.2 GB"),
        .init(id: "qwen2.5:3b", name: "qwen2.5:3b", description: "Qwen 2.5 3B", tags: ["chat", "code"], sizeHint: "~2 GB"),
    ]
}
