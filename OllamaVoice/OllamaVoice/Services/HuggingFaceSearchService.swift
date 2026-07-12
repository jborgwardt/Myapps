import Foundation

struct HuggingFaceModelHit: Identifiable, Hashable {
    var id: String { modelID }
    let modelID: String
    let pipelineTag: String?
    let downloads: Int
    let likes: Int
    let tags: [String]
    let engineHint: TTSEngineKind

    var displayName: String { modelID }
    var detail: String {
        var parts: [String] = []
        if let pipelineTag, !pipelineTag.isEmpty { parts.append(pipelineTag) }
        parts.append(engineHint.title)
        if downloads > 0 { parts.append("\(downloads.formatted()) downloads") }
        return parts.joined(separator: " · ")
    }
}

struct HuggingFaceRepoFile: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let size: Int64?
}

actor HuggingFaceSearchService {
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    func searchSpeechModels(query: String, limit: Int = 30) async throws -> [HuggingFaceModelHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        // Prefer TTS pipeline; also run a broader search so Piper/Kokoro repos without tags still appear.
        async let tagged = search(query: trimmed, pipelineTag: "text-to-speech", limit: limit)
        async let broad = search(query: trimmed, pipelineTag: nil, limit: limit)
        let merged = try await tagged + broad
        var seen = Set<String>()
        return merged.filter { seen.insert($0.modelID).inserted }
            .sorted { $0.downloads > $1.downloads }
    }

    func searchPiperVoices(query: String) async throws -> [SpeechModelCatalogItem] {
        let url = URL(string: "https://huggingface.co/rhasspy/piper-voices/resolve/main/voices.json")!
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let all = try SpeechModelCatalog.parsePiperVoices(data, languageFilter: nil)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return Array(all.prefix(40)) }
        return all.filter {
            $0.id.lowercased().contains(q)
                || $0.displayName.lowercased().contains(q)
                || $0.language.lowercased().contains(q)
                || $0.detail.lowercased().contains(q)
        }
    }

    func listDownloadableFiles(modelID: String) async throws -> [HuggingFaceRepoFile] {
        var components = URLComponents(string: "https://huggingface.co/api/models/\(modelID)")!
        components.queryItems = [URLQueryItem(name: "expand", value: "siblings")]
        let (data, response) = try await session.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let siblings = json["siblings"] as? [[String: Any]] ?? []
        return siblings.compactMap { row in
            guard let path = row["rfilename"] as? String else { return nil }
            let size = (row["size"] as? Int).map(Int64.init)
                ?? (row["size"] as? Int64)
            return HuggingFaceRepoFile(path: path, size: size)
        }
    }

    /// Build a catalog item from a HF repo, picking speech-relevant files.
    func catalogItem(for hit: HuggingFaceModelHit, maxFiles: Int = 12) async throws -> SpeechModelCatalogItem {
        let files = try await listDownloadableFiles(modelID: hit.modelID)
        let selected = Self.selectSpeechFiles(files, engine: hit.engineHint)
        let urls = selected.prefix(maxFiles).compactMap { file -> URL? in
            let encoded = file.path.split(separator: "/").map {
                $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
            }.joined(separator: "/")
            return URL(string: "https://huggingface.co/\(hit.modelID)/resolve/main/\(encoded)")
        }
        guard !urls.isEmpty else {
            throw URLError(.resourceUnavailable)
        }
        let bytes = selected.prefix(maxFiles).compactMap(\.size).reduce(0, +)
        let safeID = hit.modelID.replacingOccurrences(of: "/", with: "__")
        return SpeechModelCatalogItem(
            id: "hf:\(hit.modelID)",
            engine: hit.engineHint,
            displayName: hit.modelID,
            detail: hit.detail,
            quality: "hf",
            language: Self.guessLanguage(tags: hit.tags),
            approximateBytes: bytes > 0 ? bytes : 50_000_000,
            downloadURLs: Array(urls),
            installFolder: "huggingface/\(safeID)"
        )
    }

    private func search(query: String, pipelineTag: String?, limit: Int) async throws -> [HuggingFaceModelHit] {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1")
        ]
        if let pipelineTag {
            items.append(URLQueryItem(name: "pipeline_tag", value: pipelineTag))
        }
        components.queryItems = items

        let (data, response) = try await session.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = (row["modelId"] as? String) ?? (row["id"] as? String) else { return nil }
            let tags = row["tags"] as? [String] ?? []
            let pipeline = row["pipeline_tag"] as? String
            let blob = (id + " " + tags.joined(separator: " ") + " " + (pipeline ?? "")).lowercased()
            // Keep speech-related hits for on-device use
            let speechRelated =
                pipeline == "text-to-speech"
                || blob.contains("tts")
                || blob.contains("piper")
                || blob.contains("kokoro")
                || blob.contains("chatterbox")
                || blob.contains("speech")
                || tags.contains("onnx")
                || tags.contains("coreml")
            guard speechRelated else { return nil }
            return HuggingFaceModelHit(
                modelID: id,
                pipelineTag: pipeline,
                downloads: row["downloads"] as? Int ?? 0,
                likes: row["likes"] as? Int ?? 0,
                tags: tags,
                engineHint: Self.guessEngine(id: id, tags: tags, pipeline: pipeline)
            )
        }
    }

    nonisolated static func guessEngine(id: String, tags: [String], pipeline: String?) -> TTSEngineKind {
        let blob = (id + " " + tags.joined(separator: " ")).lowercased()
        if blob.contains("chatterbox") || blob.contains("resemble") { return .chatterbox }
        if blob.contains("kokoro") { return .kokoro }
        if blob.contains("piper") || tags.contains("onnx") { return .piper }
        return .piper
    }

    nonisolated static func guessLanguage(tags: [String]) -> String {
        let lang = tags.first { $0.count == 2 || $0.contains("_") && $0.count <= 5 }
        return lang ?? "multi"
    }

    nonisolated static func selectSpeechFiles(_ files: [HuggingFaceRepoFile], engine: TTSEngineKind) -> [HuggingFaceRepoFile] {
        let preferredExt: Set<String>
        switch engine {
        case .piper:
            preferredExt = ["onnx", "json"]
        case .kokoro:
            preferredExt = ["mlpackage", "mlmodelc", "mlmodel", "pt", "pth", "safetensors", "json", "bin", "npz"]
        case .chatterbox:
            preferredExt = ["safetensors", "pt", "pth", "onnx", "mlpackage", "json", "txt"]
        case .apple:
            preferredExt = ["json"]
        }

        let filtered = files.filter { file in
            let name = file.path.lowercased()
            if name.hasPrefix(".") || name.contains("readme") || name.hasSuffix(".md") || name.hasSuffix(".gitattributes") {
                return false
            }
            let ext = URL(fileURLWithPath: file.path).pathExtension.lowercased()
            if preferredExt.contains(ext) { return true }
            if name.hasSuffix(".onnx.json") { return true }
            if name.contains("voice") && (ext == "pt" || ext == "bin" || ext == "npy") { return true }
            return false
        }

        // Prefer smaller starter sets; sort onnx models first for piper
        return filtered.sorted { a, b in
            let ae = URL(fileURLWithPath: a.path).pathExtension.lowercased()
            let be = URL(fileURLWithPath: b.path).pathExtension.lowercased()
            let score: (String) -> Int = { ext in
                switch ext {
                case "onnx": return 0
                case "json": return 1
                case "safetensors": return 2
                case "mlpackage", "mlmodelc": return 3
                default: return 4
                }
            }
            if score(ae) != score(be) { return score(ae) < score(be) }
            return (a.size ?? .max) < (b.size ?? .max)
        }
    }
}
