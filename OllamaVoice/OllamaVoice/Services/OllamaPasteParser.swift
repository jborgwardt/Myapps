import Foundation

enum OllamaPasteParser {
    /// Extract an Ollama pull/run target from free text: commands, ollama.com links, or bare names.
    static func modelName(from raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Strip surrounding quotes / backticks
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'"))

        // ollama.com / ollama.ai URLs
        if let url = URL(string: text), let host = url.host?.lowercased(),
           host.contains("ollama.com") || host.contains("ollama.ai") {
            return fromOllamaURL(url)
        }
        // URL embedded in a longer string
        if let match = text.range(of: #"https?://(?:www\.)?ollama\.(?:com|ai)/[^\s]+"#, options: .regularExpression) {
            if let url = URL(string: String(text[match])) {
                return fromOllamaURL(url)
            }
        }

        // `ollama run foo/bar:tag` or `ollama pull foo`
        if let match = text.range(
            of: #"ollama\s+(?:run|pull)\s+([^\s]+)"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            let full = String(text[match])
            if let nameRange = full.range(of: #"([^\s]+)$"#, options: .regularExpression) {
                return sanitize(String(full[nameRange]))
            }
        }

        // Hugging Face / hf.co style already handled by normalizePullName later
        if text.lowercased().hasPrefix("hf.co/")
            || text.lowercased().hasPrefix("huggingface.co/")
            || text.lowercased().hasPrefix("http") {
            return sanitize(text)
        }

        // Bare model name: library/name or name:tag (must look like an id)
        if text.contains("/") || text.contains(":") || text.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil {
            // Avoid treating English sentences as model names
            if text.contains(" ") { return nil }
            return sanitize(text)
        }

        return nil
    }

    private static func fromOllamaURL(_ url: URL) -> String? {
        var parts = url.pathComponents.filter { $0 != "/" }
        // /library/llama3.2 → llama3.2
        if parts.first == "library" {
            parts = Array(parts.dropFirst())
        }
        guard !parts.isEmpty else { return nil }
        // /richardyoung/qwythos-9b-abliterated → richardyoung/qwythos-9b-abliterated
        var name = parts.joined(separator: "/")
        // Fragment or query tag support: ?tag=Q4_K_M unlikely; path may include :tag encoded
        if let tag = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "tag" })?.value {
            if !name.contains(":") { name += ":\(tag)" }
        }
        return sanitize(name)
    }

    private static func sanitize(_ name: String) -> String {
        var value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'/"))
        // Drop trailing slash leftovers
        while value.hasSuffix("/") { value.removeLast() }
        return value.isEmpty ? "" : value
    }
}
