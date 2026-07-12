import Foundation

@MainActor
final class ModelDownloadManager: ObservableObject {
    @Published private(set) var installed: [DownloadedSpeechModel] = []
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var statusMessage: [String: String] = [:]
    @Published var catalog: [SpeechModelCatalogItem] = SpeechModelCatalog.builtin
    @Published var lastError: String?

    nonisolated static var modelsRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("OllamaVoice/SpeechModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var manifestURL: URL {
        Self.modelsRoot.appendingPathComponent("manifest.json")
    }

    init() {
        loadManifest()
    }

    func refreshPiperCatalog() async {
        do {
            guard let url = URL(string: "https://huggingface.co/rhasspy/piper-voices/resolve/main/voices.json") else {
                lastError = "Bad Piper catalog URL"
                return
            }
            let (data, _) = try await URLSession.shared.data(from: url)
            let remote = try SpeechModelCatalog.parsePiperVoices(data)
            catalog = SpeechModelCatalog.builtin.filter { $0.engine != .piper } + remote
        } catch {
            lastError = "Piper catalog refresh failed: \(error.localizedDescription)"
        }
    }

    func isInstalled(_ id: String) -> Bool {
        installed.contains { $0.id == id }
    }

    func download(_ item: SpeechModelCatalogItem) async {
        progress[item.id] = 0
        statusMessage[item.id] = "Starting…"
        lastError = nil

        let dest = Self.modelsRoot.appendingPathComponent(item.installFolder, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            var totalBytes: Int64 = 0

            for (index, url) in item.downloadURLs.enumerated() {
                statusMessage[item.id] = "Downloading \(index + 1)/\(item.downloadURLs.count)…"
                let fileName = url.lastPathComponent.components(separatedBy: "?").first ?? url.lastPathComponent
                let target = dest.appendingPathComponent(fileName)

                let (temp, response) = try await URLSession.shared.download(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.moveItem(at: temp, to: target)
                let values = try target.resourceValues(forKeys: [.fileSizeKey])
                totalBytes += Int64(values.fileSize ?? 0)
                progress[item.id] = Double(index + 1) / Double(max(item.downloadURLs.count, 1))
            }

            let record = DownloadedSpeechModel(
                id: item.id,
                engine: item.engine,
                displayName: item.displayName,
                relativePath: item.installFolder,
                downloadedAt: .now,
                byteSize: totalBytes,
                metadata: [
                    "language": item.language,
                    "quality": item.quality
                ]
            )
            installed.removeAll { $0.id == item.id }
            installed.append(record)
            installed.sort { $0.displayName < $1.displayName }
            saveManifest()
            statusMessage[item.id] = "Installed"
            progress[item.id] = 1
        } catch {
            lastError = error.localizedDescription
            statusMessage[item.id] = "Failed"
            progress[item.id] = nil
        }
    }

    func delete(id: String) {
        guard let model = installed.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: model.localURL)
        installed.removeAll { $0.id == id }
        saveManifest()
        statusMessage[id] = nil
        progress[id] = nil
    }

    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([DownloadedSpeechModel].self, from: data) else {
            installed = []
            return
        }
        installed = decoded.filter { FileManager.default.fileExists(atPath: $0.localURL.path) }
    }

    private func saveManifest() {
        if let data = try? JSONEncoder().encode(installed) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }
}

enum SpeechModelCatalog {
    static let hfPiper = "https://huggingface.co/rhasspy/piper-voices/resolve/main"

    static var builtin: [SpeechModelCatalogItem] {
        piperStarter + kokoroStarter + chatterboxStarter
    }

    static let piperStarter: [SpeechModelCatalogItem] = [
        item(
            id: "en_US-amy-medium",
            engine: .piper,
            name: "Amy (US, medium)",
            detail: "Piper VITS ONNX — natural female US English",
            quality: "medium",
            language: "en_US",
            bytes: 63_000_000,
            files: [
                "\(hfPiper)/en/en_US/amy/medium/en_US-amy-medium.onnx",
                "\(hfPiper)/en/en_US/amy/medium/en_US-amy-medium.onnx.json"
            ],
            folder: "piper/en_US-amy-medium"
        ),
        item(
            id: "en_US-joe-medium",
            engine: .piper,
            name: "Joe (US, medium)",
            detail: "Piper VITS ONNX — male US English",
            quality: "medium",
            language: "en_US",
            bytes: 63_000_000,
            files: [
                "\(hfPiper)/en/en_US/joe/medium/en_US-joe-medium.onnx",
                "\(hfPiper)/en/en_US/joe/medium/en_US-joe-medium.onnx.json"
            ],
            folder: "piper/en_US-joe-medium"
        ),
        item(
            id: "en_US-lessac-high",
            engine: .piper,
            name: "Lessac (US, high)",
            detail: "Higher quality Piper voice",
            quality: "high",
            language: "en_US",
            bytes: 110_000_000,
            files: [
                "\(hfPiper)/en/en_US/lessac/high/en_US-lessac-high.onnx",
                "\(hfPiper)/en/en_US/lessac/high/en_US-lessac-high.onnx.json"
            ],
            folder: "piper/en_US-lessac-high"
        ),
        item(
            id: "en_GB-alan-medium",
            engine: .piper,
            name: "Alan (GB, medium)",
            detail: "British English Piper voice",
            quality: "medium",
            language: "en_GB",
            bytes: 63_000_000,
            files: [
                "\(hfPiper)/en/en_GB/alan/medium/en_GB-alan-medium.onnx",
                "\(hfPiper)/en/en_GB/alan/medium/en_GB-alan-medium.onnx.json"
            ],
            folder: "piper/en_GB-alan-medium"
        )
    ]

    static let kokoroStarter: [SpeechModelCatalogItem] = [
        item(
            id: "kokoro-core",
            engine: .kokoro,
            name: "Kokoro-82M Core ML",
            detail: "On-device Neural Engine TTS (mattmireles/kokoro-coreml starter)",
            quality: "high",
            language: "en",
            bytes: 180_000_000,
            files: [
                "https://huggingface.co/hexgrad/Kokoro-82M/resolve/main/kokoro-v1_0.pth",
                "https://huggingface.co/hexgrad/Kokoro-82M/resolve/main/config.json",
                "https://huggingface.co/hexgrad/Kokoro-82M/resolve/main/voices/af_heart.pt"
            ],
            folder: "kokoro/core"
        ),
        item(
            id: "af_heart",
            engine: .kokoro,
            name: "Kokoro voice: af_heart",
            detail: "Additional Kokoro speaker embedding",
            quality: "high",
            language: "en",
            bytes: 3_000_000,
            files: [
                "https://huggingface.co/hexgrad/Kokoro-82M/resolve/main/voices/af_heart.pt"
            ],
            folder: "kokoro/voices/af_heart"
        ),
        item(
            id: "af_bella",
            engine: .kokoro,
            name: "Kokoro voice: af_bella",
            detail: "Kokoro speaker embedding",
            quality: "high",
            language: "en",
            bytes: 3_000_000,
            files: [
                "https://huggingface.co/hexgrad/Kokoro-82M/resolve/main/voices/af_bella.pt"
            ],
            folder: "kokoro/voices/af_bella"
        )
    ]

    static let chatterboxStarter: [SpeechModelCatalogItem] = [
        item(
            id: "chatterbox-turbo",
            engine: .chatterbox,
            name: "Chatterbox Turbo",
            detail: "Resemble AI — realistic TTS + zero-shot clone (safetensors). Prefer Core ML build when available.",
            quality: "ultra",
            language: "en",
            bytes: 900_000_000,
            files: [
                "https://huggingface.co/ResembleAI/chatterbox-turbo/resolve/main/t3_cfg.safetensors",
                "https://huggingface.co/ResembleAI/chatterbox-turbo/resolve/main/s3gen.safetensors",
                "https://huggingface.co/ResembleAI/chatterbox-turbo/resolve/main/ve.safetensors",
                "https://huggingface.co/ResembleAI/chatterbox-turbo/resolve/main/conds.pt"
            ],
            folder: "chatterbox/turbo"
        ),
        item(
            id: "chatterbox-mtl",
            engine: .chatterbox,
            name: "Chatterbox Multilingual",
            detail: "23+ languages, voice cloning — large download",
            quality: "ultra",
            language: "multi",
            bytes: 2_000_000_000,
            files: [
                "https://huggingface.co/ResembleAI/chatterbox/resolve/main/t3_mtl23ls_v2.safetensors"
            ],
            folder: "chatterbox/mtl"
        )
    ]

    private static func item(
        id: String,
        engine: TTSEngineKind,
        name: String,
        detail: String,
        quality: String,
        language: String,
        bytes: Int64,
        files: [String],
        folder: String
    ) -> SpeechModelCatalogItem {
        SpeechModelCatalogItem(
            id: id,
            engine: engine,
            displayName: name,
            detail: detail,
            quality: quality,
            language: language,
            approximateBytes: bytes,
            downloadURLs: files.compactMap(URL.init(string:)),
            installFolder: folder
        )
    }

    static func parsePiperVoices(_ data: Data, languageFilter: Set<String>? = ["en", "de", "fr", "es", "it", "nl"]) throws -> [SpeechModelCatalogItem] {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var items: [SpeechModelCatalogItem] = []
        for (key, value) in json {
            guard let dict = value as? [String: Any],
                  let language = dict["language"] as? [String: Any],
                  let code = language["code"] as? String,
                  let quality = dict["quality"] as? String,
                  let name = dict["name"] as? String,
                  let files = dict["files"] as? [String: Any] else { continue }

            let family = (language["family"] as? String) ?? ""
            if let languageFilter, !languageFilter.contains(family) {
                continue
            }

            var urls: [URL] = []
            var size: Int64 = 0
            for (path, meta) in files {
                guard path.hasSuffix(".onnx") || path.hasSuffix(".onnx.json") else { continue }
                if let m = meta as? [String: Any] {
                    if let s = m["size_bytes"] as? Int64 {
                        size += s
                    } else if let s = m["size_bytes"] as? Int {
                        size += Int64(s)
                    }
                }
                if let u = URL(string: "\(hfPiper)/\(path)") {
                    urls.append(u)
                }
            }
            guard !urls.isEmpty else { continue }
            items.append(
                SpeechModelCatalogItem(
                    id: key,
                    engine: .piper,
                    displayName: "\(name) (\(code), \(quality))",
                    detail: "Piper voice \(key)",
                    quality: quality,
                    language: code,
                    approximateBytes: size,
                    downloadURLs: urls,
                    installFolder: "piper/\(key)"
                )
            )
        }
        return items.sorted { $0.displayName < $1.displayName }
    }
}
