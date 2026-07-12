import Foundation

enum OllamaError: LocalizedError {
    case invalidURL
    case http(Int, String)
    case decoding(Error)
    case transport(Error)
    case pullFailed(String)
    case modelMissing(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid Ollama URL"
        case .http(let code, let body): "HTTP \(code): \(body)"
        case .decoding(let error): "Decode failed: \(error.localizedDescription)"
        case .transport(let error): "Network: \(error.localizedDescription)"
        case .pullFailed(let message): message
        case .modelMissing(let name): "Pull finished but “\(name)” is not on the host yet."
        }
    }
}

actor OllamaClient {
    private var baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            // Pulls can idle between layer chunks; keep the request alive.
            config.timeoutIntervalForRequest = 300
            config.timeoutIntervalForResource = 60 * 60 * 6
            config.waitsForConnectivity = true
            self.session = URLSession(configuration: config)
        }
    }

    func updateBaseURL(_ url: URL) {
        baseURL = url
    }

    func currentBaseURL() -> URL { baseURL }

    func health() async throws -> Bool {
        var request = URLRequest(url: endpoint(""))
        request.timeoutInterval = 8
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func listLocalModels() async throws -> [OllamaLocalModel] {
        let (data, response) = try await session.data(from: endpoint("api/tags"))
        try Self.throwIfNeeded(response, data: data)
        do {
            return try JSONDecoder().decode(OllamaTagList.self, from: data).models
        } catch {
            throw OllamaError.decoding(error)
        }
    }

    func deleteModel(name: String) async throws {
        var request = URLRequest(url: endpoint("api/delete"))
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": name, "name": name])
        let (data, response) = try await session.data(for: request)
        try Self.throwIfNeeded(response, data: data)
    }

    /// Pull a model, yielding progress updates. Throws if the stream reports an error.
    func pullModel(name: String) -> AsyncThrowingStream<OllamaPullStatus, Error> {
        let pullName = Self.normalizePullName(name)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    var request = URLRequest(url: endpoint("api/pull"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = 60 * 60 * 6
                    // Ollama accepts both keys depending on version.
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": pullName,
                        "name": pullName,
                        "stream": true
                    ])

                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw OllamaError.http(http.statusCode, "pull failed for \(pullName)")
                    }

                    var sawSuccess = false
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8), !data.isEmpty else { continue }

                        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let errorMessage = obj["error"] as? String,
                           !errorMessage.isEmpty {
                            throw OllamaError.pullFailed(errorMessage)
                        }

                        if let status = try? JSONDecoder().decode(OllamaPullStatus.self, from: data) {
                            if status.status?.lowercased() == "success" {
                                sawSuccess = true
                            }
                            continuation.yield(status)
                        }
                    }

                    // Some builds end the stream without an explicit success line — verify tags.
                    let models = try await listLocalModels()
                    let installed = models.contains { model in
                        Self.modelMatchesPull(localName: model.name, pullName: pullName)
                    }
                    if !installed && !sawSuccess {
                        throw OllamaError.modelMissing(pullName)
                    }
                    if !installed {
                        // Success claimed but name differs slightly — still warn.
                        throw OllamaError.modelMissing(pullName)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Streaming chat completions.
    func chat(
        model: String,
        messages: [OllamaChatMessage]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var request = URLRequest(url: endpoint("api/chat"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = 600
                    let body = OllamaChatRequest(model: model, messages: messages, stream: true)
                    request.httpBody = try JSONEncoder().encode(body)

                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw OllamaError.http(http.statusCode, "chat failed")
                    }

                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8), !data.isEmpty else { continue }
                        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let errorMessage = obj["error"] as? String {
                            throw OllamaError.pullFailed(errorMessage)
                        }
                        if let chunk = try? JSONDecoder().decode(OllamaChatChunk.self, from: data),
                           let content = chunk.message?.content,
                           !content.isEmpty {
                            continuation.yield(content)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func endpoint(_ path: String) -> URL {
        if path.isEmpty { return baseURL }
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return baseURL.appending(path: trimmed)
    }

    nonisolated static func normalizePullName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("https://") {
            name = String(name.dropFirst("https://".count))
        } else if name.hasPrefix("http://") {
            name = String(name.dropFirst("http://".count))
        }
        // This Ollama build often rejects bare hf.co host (realm mismatch). Prefer huggingface.co.
        if name.hasPrefix("hf.co/") {
            name = "huggingface.co/" + name.dropFirst("hf.co/".count)
        }
        return name
    }

    nonisolated static func modelMatchesPull(localName: String, pullName: String) -> Bool {
        if localName == pullName { return true }
        let local = localName.lowercased()
        let pull = pullName.lowercased()
        if local == pull { return true }
        // HF pulls may appear as huggingface.co/... or with a quant tag suffix.
        if local.hasPrefix(pull) || pull.hasPrefix(local.split(separator: ":").first.map(String.init) ?? pull) {
            return true
        }
        let pullCore = pull
            .replacingOccurrences(of: "huggingface.co/", with: "")
            .replacingOccurrences(of: "hf.co/", with: "")
        return local.contains(pullCore) || local.contains(pullCore.split(separator: ":").first.map(String.init) ?? pullCore)
    }

    private static func throwIfNeeded(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OllamaError.http(http.statusCode, body)
        }
    }
}
