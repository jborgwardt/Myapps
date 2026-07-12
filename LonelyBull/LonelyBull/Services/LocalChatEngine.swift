import Foundation
import LLM

/// Runs GGUF chat models fully on-device via LLM.swift (llama.cpp, Metal on real hardware).
@MainActor
final class LocalChatEngine: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var loadedFileName: String?

    private var llm: LLM?

    static let systemPrompt = "You are LonelyBull, a concise on-device assistant. Answer briefly and conversationally; replies may be spoken aloud."

    enum LocalLLMError: LocalizedError {
        case loadFailed(String)
        case busy

        var errorDescription: String? {
            switch self {
            case .loadFailed(let name): "Could not load \(name). Delete and re-download it, or pick a smaller quant."
            case .busy: "The on-device model is still answering — stop it first."
            }
        }
    }

    func unload() {
        llm?.stop()
        llm = nil
        loadedFileName = nil
    }

    func stopGeneration() {
        llm?.stop()
    }

    /// Streams the reply. History (excluding the live user turn) is replayed into the model context.
    func stream(
        prompt: String,
        history: [ChatMessage],
        model: LocalLLMModel
    ) async throws -> AsyncStream<String> {
        let llm = try await ensureLoaded(model)

        llm.history = history
            .filter { $0.role != .system && !$0.isStreaming && !$0.content.isEmpty }
            .suffix(8)
            .map { (role: $0.role == .user ? .user : .bot, content: $0.content) }

        return AsyncStream { continuation in
            Task {
                await llm.respond(to: prompt) { stream in
                    var output = ""
                    for await delta in stream {
                        output += delta
                        continuation.yield(delta)
                    }
                    return output
                }
                continuation.finish()
            }
        }
    }

    private func ensureLoaded(_ model: LocalLLMModel) async throws -> LLM {
        if let llm, loadedFileName == model.fileName { return llm }

        // Swap models: free the old one before mapping the new one.
        unload()
        isLoading = true
        defer { isLoading = false }

        let url = model.localURL
        let template = Self.template(for: model.templateHint)
        let loaded = await Task.detached(priority: .userInitiated) { () -> LLM? in
            LLM(from: url, template: template, maxTokenCount: 2048)
        }.value

        guard let loaded else {
            throw LocalLLMError.loadFailed(model.displayName)
        }
        llm = loaded
        loadedFileName = model.fileName
        return loaded
    }

    static func template(for hint: String) -> Template {
        switch hint {
        case "llama3":
            return Template(
                prefix: "<|begin_of_text|>",
                system: ("<|start_header_id|>system<|end_header_id|>\n\n", "<|eot_id|>"),
                user: ("<|start_header_id|>user<|end_header_id|>\n\n", "<|eot_id|>"),
                bot: ("<|start_header_id|>assistant<|end_header_id|>\n\n", "<|eot_id|>"),
                stopSequence: "<|eot_id|>",
                systemPrompt: systemPrompt
            )
        case "gemma":
            return .gemma
        case "mistral":
            return .mistral
        default:
            return .chatML(systemPrompt)
        }
    }
}
