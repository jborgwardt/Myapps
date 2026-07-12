import Foundation

enum OllamaError: LocalizedError {
    case invalidURL
    case http(Int, String)
    case decoding(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid Ollama URL"
        case .http(let code, let body): "HTTP \(code): \(body)"
        case .decoding(let error): "Decode failed: \(error.localizedDescription)"
        case .transport(let error): "Network: \(error.localizedDescription)"
        }
    }
}

actor OllamaClient {
    private var baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func updateBaseURL(_ url: URL) {
        baseURL = url
    }

    func health() async throws -> Bool {
        let url = baseURL.appending(path: "/")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func listLocalModels() async throws -> [OllamaLocalModel] {
        let url = baseURL.appending(path: "api/tags")
        let (data, response) = try await session.data(from: url)
        try Self.throwIfNeeded(response, data: data)
        do {
            return try JSONDecoder().decode(OllamaTagList.self, from: data).models
        } catch {
            throw OllamaError.decoding(error)
        }
    }

    func deleteModel(name: String) async throws {
        let url = baseURL.appending(path: "api/delete")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
        let (data, response) = try await session.data(for: request)
        try Self.throwIfNeeded(response, data: data)
    }

    /// Pull a model, yielding progress updates.
    func pullModel(name: String) -> AsyncThrowingStream<OllamaPullStatus, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = baseURL.appending(path: "api/pull")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "name": name,
                        "stream": true
                    ])

                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw OllamaError.http(http.statusCode, "pull failed")
                    }

                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8), !data.isEmpty else { continue }
                        if let status = try? JSONDecoder().decode(OllamaPullStatus.self, from: data) {
                            continuation.yield(status)
                        }
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
                    let url = baseURL.appending(path: "api/chat")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let body = OllamaChatRequest(model: model, messages: messages, stream: true)
                    request.httpBody = try JSONEncoder().encode(body)

                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw OllamaError.http(http.statusCode, "chat failed")
                    }

                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8), !data.isEmpty else { continue }
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

    private static func throwIfNeeded(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OllamaError.http(http.statusCode, body)
        }
    }
}
