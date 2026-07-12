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
        .init(id: "llama3.2", name: "llama3.2", description: "Meta Llama 3.2 — fast general chat", tags: ["chat", "meta"], sizeHint: "2B / 3B"),
        .init(id: "llama3.2:3b", name: "llama3.2:3b", description: "Llama 3.2 3B — good on Ryzen/iGPU hosts", tags: ["chat", "small"], sizeHint: "~2 GB"),
        .init(id: "llama3.1", name: "llama3.1", description: "Meta Llama 3.1", tags: ["chat", "meta"], sizeHint: "8B+"),
        .init(id: "mistral", name: "mistral", description: "Mistral 7B Instruct", tags: ["chat"], sizeHint: "~4 GB"),
        .init(id: "qwen2.5", name: "qwen2.5", description: "Qwen 2.5 — strong reasoning", tags: ["chat", "code"], sizeHint: "3B–72B"),
        .init(id: "qwen2.5:7b", name: "qwen2.5:7b", description: "Qwen 2.5 7B", tags: ["chat"], sizeHint: "~4.7 GB"),
        .init(id: "gemma2", name: "gemma2", description: "Google Gemma 2", tags: ["chat", "google"], sizeHint: "2B / 9B"),
        .init(id: "phi3", name: "phi3", description: "Microsoft Phi-3 Mini", tags: ["chat", "small"], sizeHint: "~2.2 GB"),
        .init(id: "deepseek-r1", name: "deepseek-r1", description: "DeepSeek R1 reasoning distillations", tags: ["reasoning"], sizeHint: "1.5B–70B"),
        .init(id: "deepseek-r1:8b", name: "deepseek-r1:8b", description: "DeepSeek R1 8B distill", tags: ["reasoning"], sizeHint: "~4.9 GB"),
        .init(id: "codellama", name: "codellama", description: "Code Llama", tags: ["code"], sizeHint: "7B+"),
        .init(id: "nomic-embed-text", name: "nomic-embed-text", description: "Embedding model", tags: ["embed"], sizeHint: "~274 MB"),
        .init(id: "llava", name: "llava", description: "Vision-language model", tags: ["vision"], sizeHint: "~4.5 GB"),
        .init(id: "moondream", name: "moondream", description: "Tiny vision model", tags: ["vision", "small"], sizeHint: "~1.7 GB"),
    ]
}
