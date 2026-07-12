import Foundation

/// A GGUF chat model stored on this device.
struct LocalLLMModel: Identifiable, Codable, Equatable {
    var id: String { fileName }
    var displayName: String
    var repoID: String?
    var fileName: String
    var byteSize: Int64
    var downloadedAt: Date
    /// chatml | llama3 | gemma | mistral — picked from repo/file name.
    var templateHint: String

    var localURL: URL { LocalLLMManager.modelsRoot.appendingPathComponent(fileName) }
    var displaySize: String { ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file) }
}

struct LocalLLMCatalogEntry: Identifiable {
    let id: String
    let displayName: String
    let repoID: String
    let detail: String
    let approxBytes: Int64

    var displaySize: String { ByteCountFormatter.string(fromByteCount: approxBytes, countStyle: .file) }
}

/// Downloads GGUF weights from Hugging Face into app storage and tracks them.
/// Nothing here needs a server — this is the fully local path.
@MainActor
final class LocalLLMManager: ObservableObject {
    @Published private(set) var installed: [LocalLLMModel] = []
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var statusMessage: [String: String] = [:]
    @Published var lastError: String?

    private var downloadTasks: [String: Task<Void, Never>] = [:]

    nonisolated static var modelsRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("LonelyBull/LLMModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var manifestURL: URL {
        Self.modelsRoot.appendingPathComponent("manifest.json")
    }

    /// Small, voice-friendly models that run well on an iPhone. Q4_K_M resolved at download time.
    static let curated: [LocalLLMCatalogEntry] = [
        LocalLLMCatalogEntry(
            id: "qwen2.5-coder-1.5b-abliterated",
            displayName: "Qwen2.5 Coder 1.5B abliterated",
            repoID: "bartowski/Qwen2.5-Coder-1.5B-Instruct-abliterated-GGUF",
            detail: "The suggested coding agent, running fully on-device. Uncensored, short spoken-friendly replies.",
            approxBytes: 1_120_000_000
        ),
        LocalLLMCatalogEntry(
            id: "llama-3.2-1b",
            displayName: "Llama 3.2 1B Instruct",
            repoID: "bartowski/Llama-3.2-1B-Instruct-GGUF",
            detail: "Fast general chat, good conversational tone for TTS.",
            approxBytes: 810_000_000
        ),
        LocalLLMCatalogEntry(
            id: "qwen3-0.6b",
            displayName: "Qwen3 0.6B",
            repoID: "unsloth/Qwen3-0.6B-GGUF",
            detail: "Tiny but capable; quickest replies on older phones.",
            approxBytes: 480_000_000
        ),
        LocalLLMCatalogEntry(
            id: "smollm2-135m",
            displayName: "SmolLM2 135M Instruct",
            repoID: "unsloth/SmolLM2-135M-Instruct-GGUF",
            detail: "~100 MB smoke-test model — instant download, instant replies.",
            approxBytes: 105_000_000
        )
    ]

    init() {
        loadManifest()
    }

    func isInstalled(fileNameContaining repoID: String) -> Bool {
        let stem = repoID.split(separator: "/").last.map(String.init)?.lowercased() ?? repoID.lowercased()
        let normalized = stem.replacingOccurrences(of: "-gguf", with: "")
        return installed.contains { $0.fileName.lowercased().contains(normalized) || ($0.repoID ?? "").lowercased() == repoID.lowercased() }
    }

    func installedModel(id: String) -> LocalLLMModel? {
        installed.first { $0.id == id }
    }

    func cancelDownload(key: String) {
        downloadTasks[key]?.cancel()
        downloadTasks[key] = nil
        progress[key] = nil
        statusMessage[key] = "Cancelled"
    }

    /// Download the preferred GGUF (Q4_K_M when available) from a HF repo.
    func download(repoID: String, key: String? = nil) {
        let key = key ?? repoID
        guard downloadTasks[key] == nil else { return }
        progress[key] = 0
        statusMessage[key] = "Resolving…"
        lastError = nil

        downloadTasks[key] = Task { [weak self] in
            guard let self else { return }
            do {
                let (fileName, size) = try await Self.resolveGGUF(repoID: repoID)
                try await self.fetch(repoID: repoID, fileName: fileName, expectedSize: size, key: key)
                self.statusMessage[key] = "Installed"
                self.progress[key] = nil
            } catch is CancellationError {
                self.statusMessage[key] = "Cancelled"
                self.progress[key] = nil
            } catch {
                self.lastError = "\(repoID): \(error.localizedDescription)"
                self.statusMessage[key] = "Failed"
                self.progress[key] = nil
            }
            self.downloadTasks[key] = nil
        }
    }

    func delete(_ model: LocalLLMModel) {
        try? FileManager.default.removeItem(at: model.localURL)
        installed.removeAll { $0.id == model.id }
        saveManifest()
    }

    // MARK: - Internals

    /// Pick a concrete .gguf file in the repo, preferring sane phone-sized quants.
    nonisolated static func resolveGGUF(repoID: String) async throws -> (fileName: String, size: Int64?) {
        let encoded = repoID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repoID
        guard let url = URL(string: "https://huggingface.co/api/models/\(encoded)?expand=siblings") else {
            throw URLError(.badURL)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let siblings = json["siblings"] as? [[String: Any]] ?? []
        let ggufs: [(String, Int64?)] = siblings.compactMap { row in
            guard let name = row["rfilename"] as? String, name.lowercased().hasSuffix(".gguf") else { return nil }
            // Skip multi-part shards (00001-of-0000N) — phones want single files.
            if name.lowercased().contains("-of-") { return nil }
            let size = (row["size"] as? Int).map(Int64.init) ?? (row["size"] as? Int64)
            return (name, size)
        }
        guard !ggufs.isEmpty else { throw URLError(.resourceUnavailable) }

        let preference = ["Q4_K_M", "Q4_K_S", "Q4_0", "Q5_K_M", "IQ4_XS", "Q3_K_M", "Q8_0", "Q6_K"]
        for quant in preference {
            if let match = ggufs.first(where: { $0.0.uppercased().contains(quant) && !$0.0.uppercased().contains("\(quant)_") }) {
                return match
            }
        }
        return ggufs.min { ($0.1 ?? .max) < ($1.1 ?? .max) } ?? ggufs[0]
    }

    private func fetch(repoID: String, fileName: String, expectedSize: Int64?, key: String) async throws {
        let encodedFile = fileName.split(separator: "/").map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        guard let url = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(encodedFile)") else {
            throw URLError(.badURL)
        }

        let flatName = (fileName as NSString).lastPathComponent
        let target = Self.modelsRoot.appendingPathComponent(flatName)
        let partial = Self.modelsRoot.appendingPathComponent(flatName + ".part")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: partial) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? handle.close() }

        statusMessage[key] = "Downloading \(flatName)…"

        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let total = http.expectedContentLength > 0 ? http.expectedContentLength : (expectedSize ?? 0)

        var received: Int64 = 0
        var buffer = Data(capacity: 1 << 20)
        var lastPublished = Date.distantPast

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                let now = Date()
                if now.timeIntervalSince(lastPublished) > 0.25 {
                    lastPublished = now
                    if total > 0 {
                        progress[key] = min(1, Double(received) / Double(total))
                        statusMessage[key] = "\(Self.bytesLabel(received)) / \(Self.bytesLabel(total))"
                    } else {
                        statusMessage[key] = Self.bytesLabel(received)
                    }
                    await Task.yield()
                }
            }
            if Task.isCancelled {
                try? handle.close()
                try? FileManager.default.removeItem(at: partial)
                throw CancellationError()
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        try handle.close()

        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: partial, to: target)

        let record = LocalLLMModel(
            displayName: Self.prettyName(from: flatName),
            repoID: repoID,
            fileName: flatName,
            byteSize: received,
            downloadedAt: .now,
            templateHint: Self.templateHint(repoID: repoID, fileName: flatName)
        )
        installed.removeAll { $0.fileName == flatName }
        installed.append(record)
        installed.sort { $0.displayName < $1.displayName }
        saveManifest()
        progress[key] = 1
    }

    nonisolated static func prettyName(from fileName: String) -> String {
        fileName
            .replacingOccurrences(of: ".gguf", with: "")
            .replacingOccurrences(of: "-", with: " ")
    }

    nonisolated static func templateHint(repoID: String, fileName: String) -> String {
        let blob = (repoID + " " + fileName).lowercased()
        if blob.contains("llama-3") || blob.contains("llama3") { return "llama3" }
        if blob.contains("gemma") { return "gemma" }
        if blob.contains("mistral") || blob.contains("mixtral") { return "mistral" }
        return "chatml"
    }

    nonisolated static func bytesLabel(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([LocalLLMModel].self, from: data) else {
            installed = rescanDisk()
            return
        }
        installed = decoded.filter { FileManager.default.fileExists(atPath: $0.localURL.path) }
        if installed.count != decoded.count { saveManifest() }
    }

    /// Recover from a lost manifest by listing *.gguf on disk.
    private func rescanDisk() -> [LocalLLMModel] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.modelsRoot, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.pathExtension.lowercased() == "gguf" }.map { url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return LocalLLMModel(
                displayName: Self.prettyName(from: url.lastPathComponent),
                repoID: nil,
                fileName: url.lastPathComponent,
                byteSize: size,
                downloadedAt: .now,
                templateHint: Self.templateHint(repoID: "", fileName: url.lastPathComponent)
            )
        }
    }

    private func saveManifest() {
        if let data = try? JSONEncoder().encode(installed) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }
}
