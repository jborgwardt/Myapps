import Foundation

enum OllamaError: LocalizedError {
    case invalidURL
    case http(Int, String)
    case decoding(Error)
    case transport(Error)
    case pullFailed(String)
    case modelMissing(String)
    case cancelled
    case emptyModel

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid Ollama URL"
        case .http(let code, let body): "HTTP \(code): \(body)"
        case .decoding(let error): "Decode failed: \(error.localizedDescription)"
        case .transport(let error): "Network: \(error.localizedDescription)"
        case .pullFailed(let message): message
        case .modelMissing(let name): "Pull finished but “\(name)” is not on the host yet."
        case .cancelled: "Cancelled"
        case .emptyModel: "No model selected"
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
            config.timeoutIntervalForRequest = 300
            config.timeoutIntervalForResource = 60 * 60 * 6
            config.waitsForConnectivity = true
            config.httpMaximumConnectionsPerHost = 4
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
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch is CancellationError {
            throw OllamaError.cancelled
        } catch {
            throw OllamaError.transport(error)
        }
    }

    func listLocalModels() async throws -> [OllamaLocalModel] {
        do {
            let (data, response) = try await session.data(from: endpoint("api/tags"))
            try Self.throwIfNeeded(response, data: data)
            return try JSONDecoder().decode(OllamaTagList.self, from: data).models
        } catch let error as OllamaError {
            throw error
        } catch is CancellationError {
            throw OllamaError.cancelled
        } catch let error as DecodingError {
            throw OllamaError.decoding(error)
        } catch {
            throw OllamaError.transport(error)
        }
    }

    func deleteModel(name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var request = URLRequest(url: endpoint("api/delete"))
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": trimmed, "name": trimmed])
        let (data, response) = try await session.data(for: request)
        try Self.throwIfNeeded(response, data: data)
    }

    func pullModel(name: String) -> AsyncThrowingStream<OllamaPullStatus, Error> {
        let pullName = Self.normalizePullName(name)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !pullName.isEmpty else { throw OllamaError.emptyModel }

                    var request = URLRequest(url: endpoint("api/pull"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = 60 * 60 * 6
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": pullName,
                        "name": pullName,
                        "stream": true
                    ])

                    let (bytes, response) = try await session.bytes(for: request)
                    if Task.isCancelled { throw OllamaError.cancelled }
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw OllamaError.http(http.statusCode, "pull failed for \(pullName)")
                    }

                    var sawSuccess = false
                    for try await line in bytes.lines {
                        if Task.isCancelled { throw OllamaError.cancelled }
                        guard let data = line.data(using: .utf8), !data.isEmpty else { continue }

                        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let errorMessage = obj["error"] as? String,
                           !errorMessage.isEmpty {
                            throw OllamaError.pullFailed(errorMessage)
                        }

                        if let status = try? JSONDecoder().decode(OllamaPullStatus.self, from: data) {
                            if (status.status ?? "").lowercased() == "success" {
                                sawSuccess = true
                            }
                            continuation.yield(status)
                        }
                    }

                    let models = (try? await listLocalModels()) ?? []
                    let installed = models.contains {
                        Self.modelMatchesPull(localName: $0.name, pullName: pullName)
                    }
                    if !installed && !sawSuccess {
                        throw OllamaError.modelMissing(pullName)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func chat(
        model: String,
        messages: [OllamaChatMessage]
    ) -> AsyncThrowingStream<String, Error> {
        let modelName = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !modelName.isEmpty else { throw OllamaError.emptyModel }
                    guard !messages.isEmpty else {
                        continuation.finish()
                        return
                    }

                    var request = URLRequest(url: endpoint("api/chat"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = 600
                    let body = OllamaChatRequest(model: modelName, messages: messages, stream: true)
                    request.httpBody = try JSONEncoder().encode(body)

                    let (bytes, response) = try await session.bytes(for: request)
                    if Task.isCancelled { throw OllamaError.cancelled }
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw OllamaError.http(http.statusCode, "chat failed")
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled { throw OllamaError.cancelled }
                        guard let data = line.data(using: .utf8), !data.isEmpty else { continue }
                        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let errorMessage = obj["error"] as? String,
                           !errorMessage.isEmpty {
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
            continuation.onTermination = { @Sendable _ in
                task.cancel()
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
        guard !name.isEmpty else { return "" }
        if name.hasPrefix("https://") {
            name = String(name.dropFirst("https://".count))
        } else if name.hasPrefix("http://") {
            name = String(name.dropFirst("http://".count))
        }
        // Prefer huggingface.co — some Ollama builds reject bare hf.co (realm mismatch).
        if name.lowercased().hasPrefix("hf.co/") {
            name = "huggingface.co/" + name.dropFirst("hf.co/".count)
        }
        return name
    }

    nonisolated static func modelMatchesPull(localName: String, pullName: String) -> Bool {
        let local = localName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pull = normalizePullName(pullName).lowercased()
        guard !local.isEmpty, !pull.isEmpty else { return false }
        if local == pull { return true }

        let localBase = local.split(separator: ":").first.map(String.init) ?? local
        let pullBase = pull.split(separator: ":").first.map(String.init) ?? pull
        if localBase == pullBase { return true }

        let stripHost: (String) -> String = { value in
            value
                .replacingOccurrences(of: "huggingface.co/", with: "")
                .replacingOccurrences(of: "hf.co/", with: "")
        }
        let localCore = stripHost(localBase)
        let pullCore = stripHost(pullBase)
        if localCore == pullCore { return true }
        if local.contains(pullCore) || pull.contains(localCore) { return true }
        return false
    }

    private static func throwIfNeeded(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OllamaError.http(http.statusCode, body)
        }
    }
}
